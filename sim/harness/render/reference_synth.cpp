#include "reference_synth.h"

#include "generated/envelope_lut.h"

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
      prepared_(kNumVoices),
      prepared_seq_(kNumVoices),
      prepared_valid_(kNumVoices),
      voices_(kNumVoices),
      envelopes_(kNumVoices),
      diagnostics_(diagnostics) {}

void ReferenceSynth::write_command_words(const std::vector<uint32_t>& words) {
  if (words.empty()) return;
  const uint8_t opcode = uint8_t(words[0] >> 24);
  const int voice = int((words[0] >> 16) & 0xffu);
  const uint8_t seq = uint8_t(words[0] >> 8);
  const size_t payload_words = size_t(words[0] & 0xffu);
  if (voice < 0 || voice >= kNumVoices || words.size() != payload_words + 1) return;

  if (opcode == 0x10 || opcode == 0x11) {
    const bool stereo = opcode == 0x11;
    VoiceConfig p{};
    p.valid = true;
    p.stereo = stereo;
    p.base_addr = words[1];
    size_t i = 2;
    if (stereo) p.base_addr_r = words[i++];
    p.length = words[i++] & kPhaseFrameMask;
    if (stereo) p.length_r = words[i++] & kPhaseFrameMask;
    p.loop_start = words[i++] & kPhaseFrameMask;
    if (stereo) p.loop_start_r = words[i++] & kPhaseFrameMask;
    p.loop_end = words[i++] & kPhaseFrameMask;
    if (stereo) p.loop_end_r = words[i++] & kPhaseFrameMask;
    p.phase = words[i++];
    p.phase_r = p.phase;
    p.loop_mode = int(words[i++] & 3u);
    p.filter_b0 = int16_t(words[i] & 0xffffu);
    p.filter_b1 = int16_t(words[i++] >> 16);
    p.filter_b2 = int16_t(words[i] & 0xffffu);
    p.filter_a1 = int16_t(words[i++] >> 16);
    p.filter_a2 = int16_t(words[i] & 0xffffu);
    p.filter_enable = (words[i] & 0x00010000u) != 0;
    p.valid = p.length != 0 && (!stereo || p.length_r != 0) &&
              (p.loop_mode == 0 ||
               ((p.loop_start < p.loop_end && p.loop_end <= p.length) &&
                (!stereo || (p.loop_start_r < p.loop_end_r && p.loop_end_r <= p.length_r))));
    prepared_[voice] = p;
    prepared_seq_[voice] = seq;
    prepared_valid_[voice] = p.valid;
    return;
  }

  if (opcode == 0x12) {
    if (!prepared_valid_[voice] || prepared_seq_[voice] != seq) return;
    VoiceConfig v = prepared_[voice];
    v.enable = true;
    v.released = false;
    v.seq = seq;
    v.phase_inc = words[2];
    v.gain_l = int16_t(words[1] & 0xffffu);
    v.gain_r = int16_t(words[1] >> 16);
    v.envelope = 0;
    voices_[voice] = v;
    EnvelopeState e{};
    e.delay_samples = words[3] & 0x00ffffffu;
    e.attack_step = words[4];
    e.hold_samples = words[5] & 0x00ffffffu;
    e.decay_step = words[6];
    e.sustain_cb = words[7];
    e.release_step = words[8];
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
  if (!v.enable || v.seq != seq) return;
  if (opcode == 0x13) {
    EnvelopeState& e = envelopes_[voice];
    const uint32_t mask = words[1];
    size_t i = 2;
    if (mask & (1u << 0)) {
      e.delay_samples = words[i++] & 0x00ffffffu;
      if (e.stage == EnvelopeState::kDelay && e.elapsed >= e.delay_samples)
        e.stage = EnvelopeState::kAttack;
    }
    if (mask & (1u << 1)) e.attack_step = words[i++];
    if (mask & (1u << 2)) {
      e.hold_samples = words[i++] & 0x00ffffffu;
      if (e.stage == EnvelopeState::kHold && e.elapsed >= e.hold_samples) {
        e.stage = (e.sustain_cb != 0 && e.decay_step != 0) ?
                  EnvelopeState::kDecay : EnvelopeState::kSustain;
        if (e.stage == EnvelopeState::kSustain) e.attenuation_cb = e.sustain_cb;
      }
    }
    if (mask & (1u << 3)) e.decay_step = words[i++];
    if (mask & (1u << 4)) {
      e.sustain_cb = words[i++];
      if (e.stage == EnvelopeState::kSustain) {
        if (e.decay_step != 0)
          e.stage = EnvelopeState::kDecay;
        else
          e.attenuation_cb = e.sustain_cb;
      }
    }
    if (mask & (1u << 5)) e.release_step = words[i++];
  } else if (opcode == 0x14) {
    EnvelopeState& e = envelopes_[voice];
    e.release_step = words[1];
    e.attenuation_cb = e.release_step == 0 ? (960u << 20) :
                                               q15_to_cb(envelope_level(v, e));
    e.elapsed = 0;
    e.stage = EnvelopeState::kRelease;
    v.released = true;
    if (e.release_step == 0) v.enable = false;
  } else if (opcode == 0x15) {
    v.enable = false;
  } else if (opcode == 0x16) {
    v.gain_l = int16_t(words[1] & 0xffffu);
    v.gain_r = int16_t(words[1] >> 16);
    v.phase_inc = words[2];
  } else if (opcode == 0x17) {
    v.filter_b0 = int16_t(words[1] & 0xffffu);
    v.filter_b1 = int16_t(words[1] >> 16);
    v.filter_b2 = int16_t(words[2] & 0xffffu);
    v.filter_a1 = int16_t(words[2] >> 16);
    v.filter_a2 = int16_t(words[3] & 0xffffu);
    v.filter_enable = (words[3] & 0x00010000u) != 0;
  }
}

int16_t ReferenceSynth::cb_to_q15(uint32_t cb_q12_20) {
  if (cb_q12_20 >= (960u << 20)) return 0;
  uint32_t cb_q8_8 = cb_q12_20 >> 12;
  uint32_t index = cb_q8_8 >> 10;
  uint32_t fraction = cb_q8_8 & 0x3ffu;
  uint32_t low = uint16_t(envelope_lut::kCbToQ15.at(index));
  uint32_t high = uint16_t(envelope_lut::kCbToQ15.at(index + 1));
  uint32_t delta = low - high;
  uint32_t interp = low - ((delta * fraction + 512u) >> 10);
  return int16_t(interp);
}

uint32_t ReferenceSynth::q15_to_cb(int16_t level) {
  if (level >= int16_t(0x7fff)) return 0;
  if (level <= 0) return 960u << 20;
  for (uint32_t index = 0; index + 1 < envelope_lut::kCbToQ15.size(); ++index) {
    uint32_t high = uint16_t(envelope_lut::kCbToQ15[index]);
    uint32_t low = uint16_t(envelope_lut::kCbToQ15[index + 1]);
    if (uint16_t(level) <= high && uint16_t(level) > low) {
      uint32_t delta = high - low;
      uint32_t distance = high - uint16_t(level);
      return (index * 4u << 20) +
             uint32_t((uint64_t(distance) * (4u << 20)) / delta);
    }
  }
  return 960u << 20;
}

int16_t ReferenceSynth::envelope_level(const VoiceConfig& voice, const EnvelopeState& e) {
  if (!voice.enable || e.stage == EnvelopeState::kDelay) return 0;
  if (e.stage == EnvelopeState::kAttack)
    return int16_t((e.attack_level >> 17) & 0x7fffu);
  if (e.stage == EnvelopeState::kHold) return int16_t(0x7fff);
  return cb_to_q15(e.attenuation_cb);
}

void ReferenceSynth::advance_envelope(VoiceConfig& v, EnvelopeState& e) {
  constexpr uint32_t kSilence = 960u << 20;
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
      uint64_t next = uint64_t(e.attenuation_cb) + e.decay_step;
      if (next >= e.sustain_cb) {
        e.attenuation_cb = e.sustain_cb;
        e.stage = EnvelopeState::kSustain;
      } else {
        e.attenuation_cb = uint32_t(next);
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

std::pair<int16_t, int16_t> ReferenceSynth::render_sample() {
  int32_t accum_l = 0;
  int32_t accum_r = 0;
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
    if (v.enable) advance_envelope(v, envelopes_[voice]);
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
                                                &filter_l_y_saturated, &filter_l_state_saturated,
                                                &filter_l_y_input, &filter_l_state_input) : interp_l;
    int32_t filter_r = v.filter_enable ? biquad(interp_r, v.filter_z1_r, v.filter_z2_r, v,
                                                &filter_r_y_saturated, &filter_r_state_saturated,
                                                &filter_r_y_input, &filter_r_state_input) : interp_r;
    if (filter_l_y_saturated || filter_r_y_saturated) frame_filter_y_saturated = true;
    if (filter_l_state_saturated || filter_r_state_saturated) frame_filter_state_saturated = true;
    if (filter_l_y_saturated) filter_y_saturations += 1;
    if (filter_r_y_saturated) filter_y_saturations += 1;
    if (filter_l_state_saturated) filter_state_saturations += 1;
    if (filter_r_state_saturated) filter_state_saturations += 1;
    if (diagnostics_ && v.filter_enable) {
      update_max_abs(diagnostics_->max_abs_filter_y_input, filter_l_y_input);
      update_max_abs(diagnostics_->max_abs_filter_y_input, filter_r_y_input);
      update_max(diagnostics_->max_abs_filter_state_input, filter_l_state_input);
      update_max(diagnostics_->max_abs_filter_state_input, filter_r_state_input);
    }
    bool contribution_l_saturated = false;
    bool contribution_r_saturated = false;
    int32_t contribution_l_input = 0;
    int32_t contribution_r_input = 0;
    accum_l += apply_output_gain(filter_l, v.gain_l, v.envelope, &contribution_l_saturated,
                                 &contribution_l_input);
    accum_r += apply_output_gain(filter_r, v.gain_r, v.envelope, &contribution_r_saturated,
                                 &contribution_r_input);
    if (contribution_l_saturated || contribution_r_saturated) frame_contribution_saturated = true;
    if (contribution_l_saturated) contribution_saturations += 1;
    if (contribution_r_saturated) contribution_saturations += 1;
    if (diagnostics_) {
      update_max_abs(diagnostics_->max_abs_voice_contribution_input_l, contribution_l_input);
      update_max_abs(diagnostics_->max_abs_voice_contribution_input_r, contribution_r_input);
    }
  }

  bool mix_l_saturated = false;
  bool mix_r_saturated = false;
  if (diagnostics_) {
    update_max_abs(diagnostics_->max_abs_mix_input_l, accum_l);
    update_max_abs(diagnostics_->max_abs_mix_input_r, accum_r);
  }
  auto out = std::make_pair(saturate(accum_l, &mix_l_saturated), saturate(accum_r, &mix_r_saturated));
  if (mix_l_saturated || mix_r_saturated) frame_mix_saturated = true;
  if (mix_l_saturated) mix_saturations += 1;
  if (mix_r_saturated) mix_saturations += 1;

  if (diagnostics_) {
    diagnostics_->frames += 1;
    if (frame_filter_y_saturated) diagnostics_->filter_y_saturated_frames += 1;
    diagnostics_->filter_y_saturations += filter_y_saturations;
    if (frame_filter_state_saturated) diagnostics_->filter_state_saturated_frames += 1;
    diagnostics_->filter_state_saturations += filter_state_saturations;
    if (frame_contribution_saturated) diagnostics_->contribution_saturated_frames += 1;
    diagnostics_->contribution_saturations += contribution_saturations;
    if (frame_mix_saturated) diagnostics_->mix_saturated_frames += 1;
    diagnostics_->mix_saturations += mix_saturations;
  }
  sample_counter_ += 1;
  return out;
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
  bool local_y_saturated = false;
  int32_t y = saturate_i20(y_shift, &local_y_saturated);
  int64_t next_z1 = int64_t(v.filter_b1) * sample - int64_t(v.filter_a1) * y + z2;
  int64_t next_z2 = int64_t(v.filter_b2) * sample - int64_t(v.filter_a2) * y;
  if (state_input) *state_input = std::max(abs_magnitude(next_z1), abs_magnitude(next_z2));
  bool local_state_saturated = false;
  z1 = saturate_filter_state(next_z1, &local_state_saturated);
  z2 = saturate_filter_state(next_z2, &local_state_saturated);
  if (local_y_saturated && y_saturated) *y_saturated = true;
  if (local_state_saturated && state_saturated) *state_saturated = true;
  return y;
}

int16_t ReferenceSynth::read_word(uint32_t address) const {
  return address < memory_.size() ? memory_[address] : 0;
}

}  // namespace render
