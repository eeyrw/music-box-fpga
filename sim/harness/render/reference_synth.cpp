#include "reference_synth.h"

#include "generated/dsp_lut.h"

#include <algorithm>

namespace render {
namespace {

uint64_t abs_magnitude(int64_t value) {
  return value < 0 ? uint64_t(-(value + 1)) + 1u : uint64_t(value);
}

void update_max_abs(uint64_t& maximum, int64_t value) {
  maximum = std::max(maximum, abs_magnitude(value));
}

void update_max(uint64_t& maximum, uint64_t value) {
  maximum = std::max(maximum, value);
}

}  // namespace

ReferenceSynth::ReferenceSynth(const std::vector<int16_t>& memory, RenderDiagnostics* diagnostics)
    : memory_(memory),
      voices_(kNumVoices),
      envelopes_(kNumVoices),
      diagnostics_(diagnostics) {}

void ReferenceSynth::write_command_words(CommandWordView words) {
  if (words.empty()) return;
  const uint8_t opcode = uint8_t(words[0] >> 24);
  const size_t payload_words = size_t(words[0] & 0xffu);
  const uint8_t flags = uint8_t((words[0] >> 8) & 0x3fu);
  const bool voice_opcode = opcode == 0x10 ||
      (opcode >= 0x13 && opcode <= 0x18);
  const int voice = voice_opcode ? int((words[0] >> 14) & 0x3ffu) : 0;
  if (voice < 0 || voice >= kNumVoices || words.size() != payload_words + 1) return;

  const bool has_loop = (flags & 3u) != 0;
  const bool has_filter = (flags & 4u) != 0;
  const bool has_envelope = (flags & 8u) != 0;
  const size_t expected_start_words = 5u + (has_loop ? 2u : 0u) +
      (has_filter ? 3u : 0u) + (has_envelope ? 6u : 0u);
  if (opcode == 0x10 && (flags & 0x30u) == 0 && (flags & 3u) != 3u &&
      payload_words == expected_start_words) {
    VoiceConfig v{};
    v.valid = true;
    v.enable = true;
    v.released = false;
    v.generation = uint16_t(words[1]);
    v.loop_mode = int(flags & 3u);
    v.base_addr = words[2];
    v.length = words[3] & kPhaseFrameMask;
    size_t index = 4;
    if (has_loop) {
      v.loop_start = words[index++] & kPhaseFrameMask;
      v.loop_end = words[index++] & kPhaseFrameMask;
    } else {
      v.loop_end = v.length;
    }
    v.phase = 0;
    v.phase_inc = words[index++];
    v.gain_l = int16_t(words[index] & 0xffffu);
    v.gain_r = int16_t(words[index++] >> 16);
    if (has_filter) {
      v.filter_b0 = int16_t(words[index] & 0xffffu);
      v.filter_b1 = int16_t(words[index++] >> 16);
      v.filter_b2 = int16_t(words[index] & 0xffffu);
      v.filter_a1 = int16_t(words[index++] >> 16);
      v.filter_a2 = int16_t(words[index] & 0xffffu);
      v.filter_enable = (words[index++] & 0x00010000u) != 0;
    }
    v.valid = v.length != 0 &&
              (v.loop_mode == 0 ||
               (v.loop_start < v.loop_end && v.loop_end <= v.length));
    if (!v.valid) return;
    v.envelope = 0;
    voices_[voice] = v;
    EnvelopeState e{};
    if (has_envelope) {
      e.delay_samples = words[index++] & 0x00ffffffu;
      e.attack_step = words[index++];
      e.hold_samples = words[index++] & 0x00ffffffu;
      e.decay_step = words[index++];
      e.sustain_cb = words[index++];
      e.release_step = words[index++];
    }
    e.stage = e.delay_samples != 0 ? EnvelopeState::kDelay : EnvelopeState::kAttack;
    if (e.delay_samples == 0 && e.attack_step == 0) {
      e.attack_level = 0xffffffffu;
      e.stage = e.hold_samples != 0 ? EnvelopeState::kHold :
                ((e.sustain_cb != 0 && e.decay_step != 0) ?
                 EnvelopeState::kDecay : EnvelopeState::kSustain);
      if (e.stage == EnvelopeState::kSustain) e.attenuation_cb = e.sustain_cb;
    }
    envelopes_[voice] = e;
    return;
  }

  VoiceConfig& v = voices_[voice];
  if (!v.enable || payload_words == 0 || v.generation != uint16_t(words[1])) return;
  if (opcode == 0x13 && payload_words == 7) {
    EnvelopeState& e = envelopes_[voice];
    e.delay_samples = words[2] & 0x00ffffffu;
    e.attack_step = words[3];
    e.hold_samples = words[4] & 0x00ffffffu;
    e.decay_step = words[5];
    e.sustain_cb = words[6];
    e.release_step = words[7];
    if (e.stage == EnvelopeState::kDelay && e.elapsed >= e.delay_samples)
      e.stage = EnvelopeState::kAttack;
    if (e.stage == EnvelopeState::kHold && e.elapsed >= e.hold_samples)
      e.stage = (e.sustain_cb != 0 && e.decay_step != 0) ?
                EnvelopeState::kDecay : EnvelopeState::kSustain;
    if (e.stage == EnvelopeState::kSustain) {
      if (e.decay_step != 0)
        e.stage = EnvelopeState::kDecay;
      else
        e.attenuation_cb = e.sustain_cb;
    }
  } else if (opcode == 0x14) {
    EnvelopeState& e = envelopes_[voice];
    e.release_step = words[2];
    if (e.release_step == 0) {
      e.attenuation_cb = dsp_lut::kEnvCbSilenceQ12_20;
    } else if (e.stage == EnvelopeState::kAttack) {
      e.attenuation_cb = q15_to_cb(int16_t((e.attack_level >> 17) & 0x7fffu));
    } else if (e.stage == EnvelopeState::kHold) {
      e.attenuation_cb = 0;
    } else if (e.stage == EnvelopeState::kDelay) {
      e.attenuation_cb = dsp_lut::kEnvCbSilenceQ12_20;
    }
    e.elapsed = 0;
    e.stage = EnvelopeState::kRelease;
    v.released = true;
    if (e.release_step == 0) v.enable = false;
  } else if (opcode == 0x15) {
    v.enable = false;
  } else if (opcode == 0x16) {
    v.gain_l = int16_t(words[2] & 0xffffu);
    v.gain_r = int16_t(words[2] >> 16);
  } else if (opcode == 0x17) {
    v.filter_b0 = int16_t(words[2] & 0xffffu);
    v.filter_b1 = int16_t(words[2] >> 16);
    v.filter_b2 = int16_t(words[3] & 0xffffu);
    v.filter_a1 = int16_t(words[3] >> 16);
    v.filter_a2 = int16_t(words[4] & 0xffffu);
    v.filter_enable = (words[4] & 0x00010000u) != 0;
  } else if (opcode == 0x18) {
    v.phase_inc = words[2];
  }
}

int16_t ReferenceSynth::cb_to_q15(uint32_t cb_q12_20) {
  if (cb_q12_20 >= dsp_lut::kEnvCbSilenceQ12_20) return 0;
  uint32_t octave = 0;
  if (cb_q12_20 >= dsp_lut::kEnvCbOctaveQ12_20[16]) {
    octave = 16;
  } else {
    if (cb_q12_20 >= dsp_lut::kEnvCbOctaveQ12_20[8]) octave = 8;
    if (cb_q12_20 >= dsp_lut::kEnvCbOctaveQ12_20[octave + 4]) octave += 4;
    if (cb_q12_20 >= dsp_lut::kEnvCbOctaveQ12_20[octave + 2]) octave += 2;
    if (cb_q12_20 >= dsp_lut::kEnvCbOctaveQ12_20[octave + 1]) octave += 1;
  }
  uint32_t residual = cb_q12_20 - dsp_lut::kEnvCbOctaveQ12_20[octave];
  uint32_t index =
      (residual + (1u << (dsp_lut::kEnvCbToQ15ResidualIndexShift - 1u))) >>
      dsp_lut::kEnvCbToQ15ResidualIndexShift;
  uint32_t scaled = dsp_lut::kEnvCbToQ15Mantissa.at(index) >> octave;
  return int16_t((scaled + (1u << (dsp_lut::kEnvCbToQ15GuardBits - 1u))) >>
                 dsp_lut::kEnvCbToQ15GuardBits);
}

uint32_t ReferenceSynth::q15_to_cb(int16_t level) {
  if (level >= int16_t(0x7fff)) return 0;
  if (level <= 0) return dsp_lut::kEnvCbSilenceQ12_20;
  uint32_t magnitude = uint16_t(level);
  uint32_t leading_zeros = 0;
  for (int bit = 14; bit >= 0; --bit) {
    if ((magnitude & (1u << bit)) != 0) {
      leading_zeros = uint32_t(14 - bit);
      break;
    }
  }
  uint32_t normalized = magnitude << leading_zeros;
  uint32_t index =
      (normalized >> (14u - dsp_lut::kEnvQ15ToCbMantissaBits)) &
      ((1u << dsp_lut::kEnvQ15ToCbMantissaBits) - 1u);
  return dsp_lut::kEnvCbOctaveQ12_20.at(leading_zeros) +
         dsp_lut::kEnvQ15ToCbMantissa.at(index);
}

int16_t ReferenceSynth::envelope_level(const VoiceConfig& voice, const EnvelopeState& e) {
  if (!voice.enable || e.stage == EnvelopeState::kDelay) return 0;
  if (e.stage == EnvelopeState::kAttack)
    return int16_t((e.attack_level >> 17) & 0x7fffu);
  if (e.stage == EnvelopeState::kHold) return int16_t(0x7fff);
  return cb_to_q15(e.attenuation_cb);
}

void ReferenceSynth::advance_envelope(VoiceConfig& v, EnvelopeState& e) {
  constexpr uint32_t kSilence = dsp_lut::kEnvCbSilenceQ12_20;
  switch (e.stage) {
    case EnvelopeState::kDelay:
      if (++e.elapsed >= e.delay_samples) {
        e.elapsed = 0;
        e.stage = EnvelopeState::kAttack;
        if (e.attack_step == 0) {
          e.attack_level = 0xffffffffu;
          e.stage = e.hold_samples != 0 ? EnvelopeState::kHold :
                    ((e.sustain_cb != 0 && e.decay_step != 0) ?
                     EnvelopeState::kDecay : EnvelopeState::kSustain);
          if (e.stage == EnvelopeState::kSustain) e.attenuation_cb = e.sustain_cb;
        }
      }
      break;
    case EnvelopeState::kAttack: {
      uint64_t next = uint64_t(e.attack_level) + e.attack_step;
      if (next >= 0xffffffffu) {
        e.attack_level = 0xffffffffu;
        e.elapsed = 0;
        e.stage = e.hold_samples != 0 ? EnvelopeState::kHold :
                  ((e.sustain_cb != 0 && e.decay_step != 0) ?
                   EnvelopeState::kDecay : EnvelopeState::kSustain);
        if (e.stage == EnvelopeState::kSustain) e.attenuation_cb = e.sustain_cb;
      } else {
        e.attack_level = uint32_t(next);
      }
      break;
    }
    case EnvelopeState::kHold:
      if (++e.elapsed >= e.hold_samples) {
        e.elapsed = 0;
        e.stage = (e.sustain_cb != 0 && e.decay_step != 0) ?
                  EnvelopeState::kDecay : EnvelopeState::kSustain;
        if (e.stage == EnvelopeState::kSustain) e.attenuation_cb = e.sustain_cb;
      }
      break;
    case EnvelopeState::kDecay: {
      if (e.attenuation_cb < e.sustain_cb) {
        uint64_t next = uint64_t(e.attenuation_cb) + e.decay_step;
        if (next >= e.sustain_cb) {
          e.attenuation_cb = e.sustain_cb;
          e.stage = EnvelopeState::kSustain;
        } else {
          e.attenuation_cb = uint32_t(next);
        }
      } else if (e.attenuation_cb > e.sustain_cb) {
        uint32_t distance = e.attenuation_cb - e.sustain_cb;
        if (distance <= e.decay_step) {
          e.attenuation_cb = e.sustain_cb;
          e.stage = EnvelopeState::kSustain;
        } else {
          e.attenuation_cb -= e.decay_step;
        }
      } else {
        e.stage = EnvelopeState::kSustain;
      }
      break;
    }
    case EnvelopeState::kSustain:
      e.attenuation_cb = e.sustain_cb;
      break;
    case EnvelopeState::kRelease: {
      uint64_t next = uint64_t(e.attenuation_cb) + e.release_step;
      if (next >= kSilence) {
        e.attenuation_cb = kSilence;
        v.enable = false;
      } else {
        e.attenuation_cb = uint32_t(next);
      }
      break;
    }
  }
  v.envelope = envelope_level(v, e);
}

std::pair<int32_t, int32_t> ReferenceSynth::render_mix() {
  int32_t accum_l = 0;
  int32_t accum_r = 0;
  const bool detailed = diagnostics_ && diagnostics_->detailed_enabled;
  bool frame_filter_y_saturated = false;
  bool frame_filter_state_saturated = false;
  bool frame_contribution_saturated = false;
  bool frame_mix_saturated = false;
  uint64_t filter_y_saturations = 0;
  uint64_t filter_state_saturations = 0;
  uint64_t contribution_saturations = 0;
  uint64_t mix_saturations = 0;

  for (int voice = 0; voice < int(voices_.size()); ++voice) {
    VoiceConfig& v = voices_[voice];
    int16_t envelope_before = detailed ? v.envelope : 0;
    if (v.enable) advance_envelope(v, envelopes_[voice]);
    const bool silent_delay = envelopes_[voice].stage == EnvelopeState::kDelay;
    if (detailed && v.envelope != envelope_before) {
      diagnostics_->audible_envelope_updates += 1;
      uint32_t jump = uint32_t(std::abs(int(v.envelope) - int(envelope_before)));
      if (jump > diagnostics_->max_audible_envelope_jump) {
        diagnostics_->max_audible_envelope_jump = jump;
        diagnostics_->max_audible_envelope_jump_voice = voice;
        diagnostics_->max_audible_envelope_jump_frame = diagnostics_->frames;
      }
    }
    bool loop_active = (v.loop_mode == 1) || ((v.loop_mode == 2) && !v.released);
    bool done_l = (v.loop_mode == 0 || !loop_active) && ((v.phase >> kPhaseFracBits) >= v.length);
    bool done_r = !v.stereo || ((v.loop_mode == 0 || !loop_active) && ((v.phase_r >> kPhaseFracBits) >= v.length_r));
    bool voice_done = done_l && done_r;
    if (!v.enable || !v.valid || voice_done) continue;

    uint32_t frame_0 = done_l ? v.length - 1 : ((v.phase >> kPhaseFracBits) & kPhaseFrameMask);
    uint32_t frame_1 = frame_0;
    if (!done_l && loop_active) {
      frame_1 = ((frame_0 + 1) >= v.loop_end) ? v.loop_start : frame_0 + 1;
    } else if (!done_l) {
      frame_1 = ((frame_0 + 1) >= v.length) ? frame_0 : frame_0 + 1;
    }
    uint32_t frame_r0 = 0;
    uint32_t frame_r1 = 0;
    if (v.stereo) {
      frame_r0 = done_r ? v.length_r - 1 : ((v.phase_r >> kPhaseFracBits) & kPhaseFrameMask);
      frame_r1 = frame_r0;
      if (!done_r && loop_active) {
        frame_r1 = ((frame_r0 + 1) >= v.loop_end_r) ? v.loop_start_r : frame_r0 + 1;
      } else if (!done_r) {
        frame_r1 = ((frame_r0 + 1) >= v.length_r) ? frame_r0 : frame_r0 + 1;
      }
    } else {
      frame_r0 = frame_0;
      frame_r1 = frame_1;
    }
    uint32_t fraction = v.phase & kPhaseFracMask;

    uint64_t phase_sum = uint64_t(v.phase) + uint64_t(v.phase_inc);
    uint64_t loop_end_phase = uint64_t(v.loop_end) << kPhaseFracBits;
    uint32_t loop_length_phase = uint32_t(v.loop_end - v.loop_start) << kPhaseFracBits;
    if (loop_active && phase_sum >= loop_end_phase)
      v.phase = uint32_t(phase_sum) - loop_length_phase;
    else
      v.phase = uint32_t(phase_sum);
    if (v.stereo) {
      uint64_t phase_r_sum = uint64_t(v.phase_r) + uint64_t(v.phase_inc);
      uint64_t loop_end_phase_r = uint64_t(v.loop_end_r) << kPhaseFracBits;
      uint32_t loop_length_phase_r = uint32_t(v.loop_end_r - v.loop_start_r) << kPhaseFracBits;
      if (loop_active && phase_r_sum >= loop_end_phase_r)
        v.phase_r = uint32_t(phase_r_sum) - loop_length_phase_r;
      else
        v.phase_r = uint32_t(phase_r_sum);
    }

    if (silent_delay) continue;

    int16_t raw_l0 = read_word(v.base_addr + uint32_t(frame_0));
    int16_t raw_l1 = read_word(v.base_addr + uint32_t(frame_1));
    int16_t raw_r0 = v.stereo ? read_word(v.base_addr_r + uint32_t(frame_r0)) : raw_l0;
    int16_t raw_r1 = v.stereo ? read_word(v.base_addr_r + uint32_t(frame_r1)) : raw_l1;

    int16_t interp_l = interpolate(raw_l0, raw_l1, fraction);
    int16_t interp_r = interpolate(raw_r0, raw_r1, fraction);
    bool filter_l_y_saturated = false;
    bool filter_l_state_saturated = false;
    bool filter_r_y_saturated = false;
    bool filter_r_state_saturated = false;
    int64_t filter_l_y_input = 0;
    int64_t filter_r_y_input = 0;
    uint64_t filter_l_state_input = 0;
    uint64_t filter_r_state_input = 0;
    int32_t filter_l = v.filter_enable ? biquad(interp_l, v.filter_z1_l, v.filter_z2_l, v,
                                                detailed ? &filter_l_y_saturated : nullptr,
                                                detailed ? &filter_l_state_saturated : nullptr,
                                                detailed ? &filter_l_y_input : nullptr,
                                                detailed ? &filter_l_state_input : nullptr) : interp_l;
    int32_t filter_r = v.filter_enable ? biquad(interp_r, v.filter_z1_r, v.filter_z2_r, v,
                                                detailed ? &filter_r_y_saturated : nullptr,
                                                detailed ? &filter_r_state_saturated : nullptr,
                                                detailed ? &filter_r_y_input : nullptr,
                                                detailed ? &filter_r_state_input : nullptr) : interp_r;
    if (detailed) {
      if (filter_l_y_saturated || filter_r_y_saturated) frame_filter_y_saturated = true;
      if (filter_l_state_saturated || filter_r_state_saturated) frame_filter_state_saturated = true;
      if (filter_l_y_saturated) filter_y_saturations += 1;
      if (filter_r_y_saturated) filter_y_saturations += 1;
      if (filter_l_state_saturated) filter_state_saturations += 1;
      if (filter_r_state_saturated) filter_state_saturations += 1;
    }
    if (detailed && v.filter_enable) {
      update_max_abs(diagnostics_->max_abs_filter_y_input, filter_l_y_input);
      update_max_abs(diagnostics_->max_abs_filter_y_input, filter_r_y_input);
      update_max(diagnostics_->max_abs_filter_state_input, filter_l_state_input);
      update_max(diagnostics_->max_abs_filter_state_input, filter_r_state_input);
    }
    bool contribution_l_saturated = false;
    bool contribution_r_saturated = false;
    int32_t contribution_l_input = 0;
    int32_t contribution_r_input = 0;
    accum_l += apply_output_gain(filter_l, v.gain_l, v.envelope,
                                 detailed ? &contribution_l_saturated : nullptr,
                                 detailed ? &contribution_l_input : nullptr);
    accum_r += apply_output_gain(filter_r, v.gain_r, v.envelope,
                                 detailed ? &contribution_r_saturated : nullptr,
                                 detailed ? &contribution_r_input : nullptr);
    if (detailed) {
      if (contribution_l_saturated || contribution_r_saturated) frame_contribution_saturated = true;
      if (contribution_l_saturated) contribution_saturations += 1;
      if (contribution_r_saturated) contribution_saturations += 1;
      update_max_abs(diagnostics_->max_abs_voice_contribution_input_l, contribution_l_input);
      update_max_abs(diagnostics_->max_abs_voice_contribution_input_r, contribution_r_input);
    }
  }

  bool mix_l_saturated = false;
  bool mix_r_saturated = false;
  if (detailed) {
    update_max_abs(diagnostics_->max_abs_mix_input_l, accum_l);
    update_max_abs(diagnostics_->max_abs_mix_input_r, accum_r);
  }
  if (detailed) {
    (void)saturate(accum_l, &mix_l_saturated);
    (void)saturate(accum_r, &mix_r_saturated);
  }
  if (detailed) {
    if (mix_l_saturated || mix_r_saturated) frame_mix_saturated = true;
    if (mix_l_saturated) mix_saturations += 1;
    if (mix_r_saturated) mix_saturations += 1;
  }

  if (diagnostics_) {
    diagnostics_->frames += 1;
    if (detailed) {
      if (frame_filter_y_saturated) diagnostics_->filter_y_saturated_frames += 1;
      diagnostics_->filter_y_saturations += filter_y_saturations;
      if (frame_filter_state_saturated) diagnostics_->filter_state_saturated_frames += 1;
      diagnostics_->filter_state_saturations += filter_state_saturations;
      if (frame_contribution_saturated) diagnostics_->contribution_saturated_frames += 1;
      diagnostics_->contribution_saturations += contribution_saturations;
      if (frame_mix_saturated) diagnostics_->mix_saturated_frames += 1;
      diagnostics_->mix_saturations += mix_saturations;
    }
  }
  sample_counter_ += 1;
  return {accum_l, accum_r};
}

std::pair<int16_t, int16_t> ReferenceSynth::render_sample() {
  const auto mix = render_mix();
  return {saturate(mix.first), saturate(mix.second)};
}

int16_t ReferenceSynth::interpolate(int16_t sample_0, int16_t sample_1, uint32_t fraction) {
  int32_t difference = int32_t(sample_1) - int32_t(sample_0);
  int64_t product = int64_t(difference) * int64_t(fraction);
  int32_t scaled_difference = int32_t(product >> kPhaseFracBits);
  return int16_t(int32_t(sample_0) + scaled_difference);
}

int16_t ReferenceSynth::apply_gain(int32_t sample, int16_t gain, bool* saturated) {
  int64_t product = int64_t(sample) * int64_t(gain);
  return saturate(product >> 15, saturated);
}

int16_t ReferenceSynth::apply_output_gain(int32_t sample, int16_t gain, int16_t envelope,
                                          bool* saturated, int32_t* saturated_input) {
  if (envelope == int16_t(0x7fff)) {
    int64_t product = int64_t(sample) * int64_t(gain);
    int32_t value = int32_t(product >> 15);
    if (saturated_input) *saturated_input = value;
    return saturate(value, saturated);
  }
  int64_t product = int64_t(sample) * int64_t(gain) * int64_t(envelope);
  int32_t value = int32_t(product >> 30);
  if (saturated_input) *saturated_input = value;
  return saturate(value, saturated);
}

int16_t ReferenceSynth::saturate(int32_t value, bool* saturated) {
  if (value > 32767) {
    if (saturated) *saturated = true;
    return int16_t(0x7fff);
  }
  if (value < -32768) {
    if (saturated) *saturated = true;
    return int16_t(0x8000);
  }
  return int16_t(value);
}

int32_t ReferenceSynth::saturate_i20(int64_t value, bool* saturated) {
  constexpr int64_t kMax = (int64_t(1) << 19) - 1;
  constexpr int64_t kMin = -(int64_t(1) << 19);
  if (value > kMax) {
    if (saturated) *saturated = true;
    return int32_t(kMax);
  }
  if (value < kMin) {
    if (saturated) *saturated = true;
    return int32_t(kMin);
  }
  return int32_t(value);
}

int64_t ReferenceSynth::saturate_filter_state(int64_t value, bool* saturated) {
  constexpr int64_t kMax = (int64_t(1) << 33) - 1;
  constexpr int64_t kMin = -(int64_t(1) << 33);
  if (value > kMax) {
    if (saturated) *saturated = true;
    return kMax;
  }
  if (value < kMin) {
    if (saturated) *saturated = true;
    return kMin;
  }
  return value;
}

int32_t ReferenceSynth::biquad(int16_t sample, int64_t& z1, int64_t& z2, const VoiceConfig& v,
                               bool* y_saturated, bool* state_saturated, int64_t* y_input,
                               uint64_t* state_input) {
  int64_t y_q14 = int64_t(v.filter_b0) * int64_t(sample) + z1;
  int64_t y_shift = y_q14 >> 14;
  if (y_input) *y_input = y_shift;
  int32_t y = saturate_i20(y_shift, y_saturated);
  int64_t next_z1 = int64_t(v.filter_b1) * sample - int64_t(v.filter_a1) * y + z2;
  int64_t next_z2 = int64_t(v.filter_b2) * sample - int64_t(v.filter_a2) * y;
  if (state_input) *state_input = std::max(abs_magnitude(next_z1), abs_magnitude(next_z2));
  z1 = saturate_filter_state(next_z1, state_saturated);
  z2 = saturate_filter_state(next_z2, state_saturated);
  return y;
}

int16_t ReferenceSynth::read_word(uint32_t address) const {
  return address < memory_.size() ? memory_[address] : 0;
}

}  // namespace render
