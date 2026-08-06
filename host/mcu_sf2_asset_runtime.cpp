#include "host/mcu_sf2_asset_runtime.h"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace host {
namespace {

constexpr uint8_t kStartOpcode = 0x10;
constexpr uint8_t kReleaseOpcode = 0x14;
constexpr uint8_t kStopOpcode = 0x15;
constexpr uint8_t kGainOpcode = 0x16;
constexpr uint8_t kPitchOpcode = 0x18;
constexpr uint8_t kFilterOpcode = 0x17;
constexpr uint8_t kGainGroup = 1u << 0;
constexpr uint8_t kPitchGroup = 1u << 1;
constexpr uint8_t kFilterGroup = 1u << 2;
constexpr uint8_t kEnvDelay = 1;
constexpr uint8_t kEnvAttack = 2;
constexpr uint8_t kEnvHold = 3;
constexpr uint8_t kEnvDecay = 4;
constexpr uint8_t kEnvSustain = 5;
constexpr uint8_t kEnvRelease = 6;

uint32_t pack_gains(uint16_t left, uint16_t right) {
  return (uint32_t(right) << 16) | left;
}

int64_t multiply_q16(int64_t a, int64_t b) {
  const int64_t product = a * b;
  const int64_t bias = product >= 0 ? int64_t(1) << 15 : -(int64_t(1) << 15);
  return (product + bias) / (int64_t(1) << 16);
}

int32_t lfo_q16(uint32_t phase) {
  const int32_t x = int32_t(phase & 0xffffu);
  if (x < 16384) return x * 4;
  if (x < 49152) return 131072 - x * 4;
  return x * 4 - 262144;
}

uint16_t linear_level(uint16_t start, uint16_t target,
                      uint32_t tick, uint32_t ticks) {
  if (tick >= ticks) return target;
  const int64_t delta = int64_t(target) - start;
  return uint16_t(std::max<int64_t>(0, std::min<int64_t>(
      render::kQ15Full, int64_t(start) +
      (delta * std::max<uint32_t>(1, tick) + int64_t(ticks) / 2) /
          std::max<uint32_t>(1, ticks))));
}

bool same_filter(const render::FilterConfig& a, const render::FilterConfig& b) {
  return a.enable == b.enable && a.b0 == b.b0 && a.b1 == b.b1 &&
         a.b2 == b.b2 && a.a1 == b.a1 && a.a2 == b.a2;
}

}  // namespace

McuSf2AssetRuntime::McuSf2AssetRuntime(
    const render::McuSf2AssetView& asset, render::CommandWordSink& commands,
    uint16_t voice_capacity)
    : asset_(asset), commands_(commands), voice_capacity_(voice_capacity) {
  if (voice_capacity_ == 0 || voice_capacity_ > render::kNumVoices ||
      voice_capacity_ > 1024) {
    throw std::invalid_argument("invalid MCU SF2 runtime voice capacity");
  }
  for (auto& channel : channels_) {
    channel.sources.cc[7] = 127;
    channel.sources.cc[10] = 64;
    channel.sources.cc[11] = 127;
  }
  for (uint16_t index = 0; index < voice_capacity_; ++index) {
    free_stack_[index] = uint16_t(voice_capacity_ - 1 - index);
  }
  free_count_ = voice_capacity_;
}

void McuSf2AssetRuntime::mark_exclusive(uint16_t voice, bool active) {
  const uint8_t exclusive_class = voices_[voice].exclusive_class;
  if (exclusive_class == 0) return;
  uint64_t& word = exclusive_voices_[exclusive_class][voice / 64];
  const uint64_t mask = uint64_t(1) << (voice % 64);
  if (active) word |= mask;
  else word &= ~mask;
}

void McuSf2AssetRuntime::reclaim_voice(uint16_t voice) {
  if (voices_[voice].stage == VoiceStage::kFree) return;
  mark_exclusive(voice, false);
  voices_[voice].stage = VoiceStage::kFree;
  free_stack_[free_count_++] = voice;
  --stats_.active_voices;
}

void McuSf2AssetRuntime::emit_short(uint8_t opcode, uint16_t voice,
                                    uint16_t generation, uint32_t value,
                                    bool has_value) {
  render::FixedCommand command;
  command.push_back((uint32_t(opcode) << 24) | (uint32_t(voice) << 14) |
                    uint32_t(has_value ? 2 : 1));
  command.push_back(generation);
  if (has_value) command.push_back(value);
  commands_.write_command_words(command.view());
}

void McuSf2AssetRuntime::stop_voice(uint16_t voice) {
  if (voices_[voice].stage == VoiceStage::kFree) return;
  emit_short(kStopOpcode, voice, voices_[voice].generation);
  ++stats_.stopped_voices;
  reclaim_voice(voice);
}

void McuSf2AssetRuntime::release_voice(uint16_t voice) {
  VoiceState& state = voices_[voice];
  if (state.stage == VoiceStage::kFree || state.stage == VoiceStage::kReleased) return;
  if (state.release_samples == 0) {
    stop_voice(voice);
    return;
  }
  emit_short(kReleaseOpcode, voice, state.generation, state.release_step, true);
  state.stage = VoiceStage::kReleased;
  state.mod_env_stage = kEnvRelease;
  state.mod_env_stage_tick = 0;
  state.mod_env_release_start = state.mod_env_level;
  ++stats_.released_voices;
}

uint16_t McuSf2AssetRuntime::allocate_voice() {
  if (free_count_ != 0) return free_stack_[--free_count_];
  uint16_t victim = 0;
  bool found = false;
  for (uint16_t voice = 0; voice < voice_capacity_; ++voice) {
    if (!found ||
        (voices_[voice].stage == VoiceStage::kReleased &&
         voices_[victim].stage != VoiceStage::kReleased) ||
        (voices_[voice].stage == voices_[victim].stage &&
         voices_[voice].allocation_stamp < voices_[victim].allocation_stamp)) {
      victim = voice;
      found = true;
    }
  }
  stop_voice(victim);
  --free_count_;
  ++stats_.stolen_voices;
  return free_stack_[free_count_];
}

int64_t McuSf2AssetRuntime::destination_sum_q16(
    uint32_t candidate, uint32_t program_index, uint16_t destination,
    uint8_t channel, uint8_t note, uint8_t velocity,
    bool include_note_sources) const {
  if (program_index == UINT32_MAX) return 0;
  const auto program = asset_.modulation_program(program_index);
  const render::McuFixedVoiceSources voice{note, velocity};
  int64_t sum = 0;
  for (uint32_t index = 0; index < program.term_count; ++index) {
    const auto term = asset_.modulation_term(program.first_term + index);
    if (term.destination != destination) continue;
    if (!include_note_sources &&
        (term.dependencies & render::kMcuDependencyNote) != 0) {
      continue;
    }
    sum += render::mcu_sf2_evaluate_term_q16(
        term, channels_[channel].sources, voice);
  }
  (void)candidate;
  return sum;
}

void McuSf2AssetRuntime::refresh_voice(uint16_t voice, uint8_t destination_groups) {
  VoiceState& state = voices_[voice];
  if (state.stage == VoiceStage::kFree) return;
  const auto programs = asset_.candidate_programs(state.candidate);
  const auto& config = state.runtime_config;
  const uint8_t velocity = state.effective_velocity >= 0
      ? uint8_t(state.effective_velocity) : state.velocity;
  const int32_t mod_lfo = state.mod_lfo_wait_ticks == 0
      ? lfo_q16(state.mod_lfo_phase) : 0;
  const int32_t vib_lfo = state.vib_lfo_wait_ticks == 0
      ? lfo_q16(state.vib_lfo_phase) : 0;
  const int32_t env_q16 = int32_t((int64_t(state.mod_env_level) *
      render::kMcuModulationOne + render::kQ15Full / 2) / render::kQ15Full);

  if ((destination_groups & kPitchGroup) != 0) {
    int64_t pitch_q16 = destination_sum_q16(
        state.candidate, programs.pitch, 0, state.channel,
        state.note, velocity);
    pitch_q16 += multiply_q16(mod_lfo,
        int64_t(config.mod_lfo_to_pitch) * render::kMcuModulationOne +
        destination_sum_q16(state.candidate, programs.pitch, 5,
                            state.channel, state.note, velocity));
    pitch_q16 += multiply_q16(vib_lfo,
        int64_t(config.vib_lfo_to_pitch) * render::kMcuModulationOne +
        destination_sum_q16(state.candidate, programs.pitch, 6,
                            state.channel, state.note, velocity));
    pitch_q16 += multiply_q16(env_q16,
        int64_t(config.mod_env_to_pitch) * render::kMcuModulationOne +
        destination_sum_q16(state.candidate, programs.pitch, 7,
                            state.channel, state.note, velocity));
    const uint32_t phase = render::mcu_sf2_phase_increment(
        state.base_phase_increment, pitch_q16);
    if (phase != state.phase_increment) {
      emit_short(kPitchOpcode, voice, state.generation, phase, true);
      state.phase_increment = phase;
      ++stats_.controller_voice_updates;
    }
  }

  if ((destination_groups & kGainGroup) != 0) {
    state.tremolo_attenuation_q16 = int32_t(-multiply_q16(
        mod_lfo, int64_t(config.mod_lfo_to_volume) * render::kMcuModulationOne +
        destination_sum_q16(state.candidate, programs.gain, 13,
                            state.channel, state.note, velocity)));
    const int64_t attenuation = destination_sum_q16(
        state.candidate, programs.gain, 48, state.channel,
        state.note, velocity, false) + state.tremolo_attenuation_q16 +
        (channels_[state.channel].soft
             ? int64_t(30) * render::kMcuModulationOne : 0);
    const int64_t pan = destination_sum_q16(
        state.candidate, programs.gain, 17, state.channel,
        state.note, velocity, false);
    const auto gains = render::mcu_sf2_mono_gains(
        state.base_gain, state.pan, attenuation, pan);
    if (uint16_t(gains.first) != state.gain_l ||
        uint16_t(gains.second) != state.gain_r) {
      emit_short(kGainOpcode, voice, state.generation,
                 pack_gains(uint16_t(gains.first), uint16_t(gains.second)), true);
      state.gain_l = uint16_t(gains.first);
      state.gain_r = uint16_t(gains.second);
      ++stats_.controller_voice_updates;
    }
  }

  if ((destination_groups & kFilterGroup) != 0) {
    int64_t cutoff_q16 = int64_t(config.initial_filter_fc) *
                             render::kMcuModulationOne +
        destination_sum_q16(state.candidate, programs.filter, 8,
                            state.channel, state.note, velocity);
    cutoff_q16 += multiply_q16(mod_lfo,
        int64_t(config.mod_lfo_to_filter_fc) * render::kMcuModulationOne +
        destination_sum_q16(state.candidate, programs.filter, 10,
                            state.channel, state.note, velocity));
    cutoff_q16 += multiply_q16(env_q16,
        int64_t(config.mod_env_to_filter_fc) * render::kMcuModulationOne +
        destination_sum_q16(state.candidate, programs.filter, 11,
                            state.channel, state.note, velocity));
    const int cutoff = int((cutoff_q16 + (cutoff_q16 >= 0 ? 32768 : -32768)) /
                           render::kMcuModulationOne);
    const auto filter = render::mcu_sf2_filter_config(
        cutoff, config.initial_filter_q, int(asset_.sample_rate()));
    if (!state.filter_valid || !same_filter(filter, state.filter)) {
      render::FixedCommand command;
      command.push_back((uint32_t(kFilterOpcode) << 24) |
                        (uint32_t(voice) << 14) | 4u);
      command.push_back(state.generation);
      command.push_back((uint32_t(uint16_t(filter.b1)) << 16) |
                        uint16_t(filter.b0));
      command.push_back((uint32_t(uint16_t(filter.a1)) << 16) |
                        uint16_t(filter.b2));
      command.push_back(uint32_t(uint16_t(filter.a2)) |
                        (filter.enable ? 0x00010000u : 0));
      commands_.write_command_words(command.view());
      state.filter = filter;
      state.filter_valid = true;
      ++stats_.controller_voice_updates;
    }
  }
}

void McuSf2AssetRuntime::advance_modulation(uint16_t voice) {
  VoiceState& state = voices_[voice];
  if (state.stage == VoiceStage::kFree) return;
  const auto& config = state.runtime_config;
  if (state.mod_env_stage == kEnvDelay) {
    if (state.mod_env_wait_ticks != 0) --state.mod_env_wait_ticks;
    if (state.mod_env_wait_ticks == 0) state.mod_env_stage = kEnvAttack;
  } else if (state.mod_env_stage == kEnvAttack) {
    ++state.mod_env_stage_tick;
    state.mod_env_level = linear_level(
        0, render::kQ15Full, state.mod_env_stage_tick,
        config.mod_env_attack_ticks);
    if (state.mod_env_stage_tick >= config.mod_env_attack_ticks) {
      state.mod_env_level = render::kQ15Full;
      state.mod_env_stage_tick = 0;
      state.mod_env_wait_ticks = config.mod_env_hold_ticks;
      state.mod_env_stage = state.mod_env_wait_ticks != 0 ? kEnvHold : kEnvDecay;
    }
  } else if (state.mod_env_stage == kEnvHold) {
    if (state.mod_env_wait_ticks != 0) --state.mod_env_wait_ticks;
    if (state.mod_env_wait_ticks == 0) state.mod_env_stage = kEnvDecay;
  } else if (state.mod_env_stage == kEnvDecay) {
    ++state.mod_env_stage_tick;
    state.mod_env_level = linear_level(
        render::kQ15Full, config.mod_env_sustain_level,
        state.mod_env_stage_tick, config.mod_env_decay_ticks);
    if (state.mod_env_stage_tick >= config.mod_env_decay_ticks) {
      state.mod_env_level = config.mod_env_sustain_level;
      state.mod_env_stage_tick = 0;
      state.mod_env_stage = kEnvSustain;
    }
  } else if (state.mod_env_stage == kEnvRelease) {
    ++state.mod_env_stage_tick;
    state.mod_env_level = linear_level(
        state.mod_env_release_start, 0, state.mod_env_stage_tick,
        config.mod_env_release_ticks);
  }

  uint8_t groups = kGainGroup | kPitchGroup;
  if ((control_tick_index_ % 4) == 0) groups |= kFilterGroup;
  refresh_voice(voice, groups);
  if (state.mod_lfo_wait_ticks != 0) --state.mod_lfo_wait_ticks;
  else state.mod_lfo_phase += config.mod_lfo_step;
  if (state.vib_lfo_wait_ticks != 0) --state.vib_lfo_wait_ticks;
  else state.vib_lfo_phase += config.vib_lfo_step;
}

void McuSf2AssetRuntime::release_exclusive(uint8_t exclusive_class,
                                           uint32_t preset_index) {
  if (exclusive_class == 0) return;
  const auto bits = exclusive_voices_[exclusive_class];
  for (size_t word = 0; word < bits.size(); ++word) {
    uint64_t pending = bits[word];
    while (pending != 0) {
      const unsigned bit = unsigned(__builtin_ctzll(pending));
      const uint16_t voice = uint16_t(word * 64 + bit);
      pending &= pending - 1;
      if (voice < voice_capacity_ &&
          voices_[voice].preset_index == preset_index) {
        release_voice(voice);
      }
    }
  }
}


uint16_t McuSf2AssetRuntime::note_on(uint8_t channel, uint16_t program,
                                    uint16_t bank, uint8_t note,
                                    uint8_t velocity) {
  channel &= 0x0f;
  note &= 0x7f;
  velocity &= 0x7f;
  if (velocity == 0) {
    note_off(channel, note);
    return 0;
  }
  ++stats_.note_ons;
  const int32_t preset_index = asset_.find_preset(program, bank);
  if (preset_index < 0) {
    ++stats_.unmapped_notes;
    return 0;
  }
  const auto preset = asset_.preset(size_t(preset_index));
  std::array<uint32_t, 4> matched{};
  uint16_t matched_count = 0;
  for (uint32_t local = 0; local < preset.zone_count; ++local) {
    const uint32_t zone_index = preset.first_zone + local;
    const auto zone = asset_.zone(zone_index);
    if (note < zone.key_low || note > zone.key_high ||
        velocity < zone.velocity_low || velocity > zone.velocity_high) continue;
    if (matched_count == matched.size()) {
      throw std::runtime_error("compact Note On exceeds four layers");
    }
    matched[matched_count++] = zone_index;
  }
  if (matched_count == 0) {
    ++stats_.unmapped_notes;
    return 0;
  }
  std::array<render::Region, 4> regions{};
  std::array<bool, 128> exclusive_classes{};
  for (uint16_t layer = 0; layer < matched_count; ++layer) {
    regions[layer] = asset_.materialize_zone(matched[layer], note);
    const int exclusive = regions[layer].exclusive_class;
    if (exclusive > 0) exclusive_classes[size_t(exclusive)] = true;
  }
  for (uint16_t exclusive = 1; exclusive < exclusive_classes.size(); ++exclusive) {
    if (exclusive_classes[exclusive]) {
      release_exclusive(uint8_t(exclusive), uint32_t(preset_index));
    }
  }
  const uint64_t note_instance = ++next_note_instance_;
  for (uint16_t layer = 0; layer < matched_count; ++layer) {
    auto& region = regions[layer];
    const uint16_t voice = allocate_voice();
    VoiceState& state = voices_[voice];
    const uint16_t previous_generation = state.generation;
    state = {};
    state.stage = VoiceStage::kActive;
    state.channel = channel;
    state.note = note;
    state.velocity = velocity;
    state.exclusive_class = uint8_t(region.exclusive_class);
    state.generation = uint16_t(previous_generation + 1u);
    if (state.generation == 0) state.generation = 1;
    state.preset_index = uint32_t(preset_index);
    state.candidate = matched[layer];
    state.runtime_config = render::mcu_sf2_runtime_config(region);
    state.release_samples = region.volume_envelope.release_samples;
    state.release_step = render::envelope_release_step(region);
    state.note_instance = note_instance;
    state.allocation_stamp = ++allocation_stamp_;
    state.base_gain = uint16_t(region.base_gain);
    state.pan = int16_t(region.pan);
    state.effective_velocity = int8_t(region.effective_velocity);
    state.mod_lfo_wait_ticks = state.runtime_config.mod_lfo_delay_ticks;
    state.vib_lfo_wait_ticks = state.runtime_config.vib_lfo_delay_ticks;
    state.mod_env_wait_ticks = state.runtime_config.mod_env_delay_ticks;
    state.mod_env_stage = state.mod_env_wait_ticks != 0 ? kEnvDelay : kEnvAttack;
    if (state.runtime_config.mod_env_delay_ticks == 0 &&
        state.runtime_config.mod_env_attack_sub_tick) {
      state.mod_env_level = render::kQ15Full;
      state.mod_env_wait_ticks = state.runtime_config.mod_env_hold_ticks;
      state.mod_env_stage = state.mod_env_wait_ticks != 0 ? kEnvHold : kEnvDecay;
    }
    const uint8_t effective_velocity = region.effective_velocity >= 0
        ? uint8_t(region.effective_velocity) : velocity;
    const auto programs = asset_.candidate_programs(matched[layer]);
    const int64_t pitch_q16 = destination_sum_q16(
        matched[layer], programs.pitch, 0, channel, note, effective_velocity);
    state.base_phase_increment = region.phase_inc;
    state.phase_increment = render::mcu_sf2_phase_increment(region.phase_inc, pitch_q16);
    const int64_t attenuation_q16 = destination_sum_q16(
        matched[layer], programs.gain, 48, channel, note,
        effective_velocity, false) +
        (channels_[channel].soft ? int64_t(30) * render::kMcuModulationOne : 0);
    const int64_t pan_q16 = destination_sum_q16(
        matched[layer], programs.gain, 17, channel, note,
        effective_velocity, false);
    const auto gains = render::mcu_sf2_mono_gains(
        region.base_gain, region.pan, attenuation_q16, pan_q16);
    state.gain_l = uint16_t(gains.first);
    state.gain_r = uint16_t(gains.second);
    region.gain_l = state.gain_l;
    region.gain_r = state.gain_r;
    const auto command = render::build_voice_start_command(
        voice, state.generation, state.phase_increment, region);
    state.filter = {region.filter_enable, region.filter_b0, region.filter_b1,
                    region.filter_b2, region.filter_a1, region.filter_a2};
    state.filter_valid = true;
    mark_exclusive(voice, true);
    ++stats_.active_voices;
    stats_.maximum_active_voices = std::max(stats_.maximum_active_voices,
                                            stats_.active_voices);
    commands_.write_command_words(command.view());
    ++stats_.started_voices;
  }
  return matched_count;
}

void McuSf2AssetRuntime::note_off(uint8_t channel, uint8_t note) {
  channel &= 0x0f;
  note &= 0x7f;
  ++stats_.note_offs;
  uint64_t instance = std::numeric_limits<uint64_t>::max();
  for (uint16_t voice = 0; voice < voice_capacity_; ++voice) {
    const auto& state = voices_[voice];
    if (state.stage == VoiceStage::kActive && state.channel == channel &&
        state.note == note) {
      instance = std::min(instance, state.note_instance);
    }
  }
  if (instance == std::numeric_limits<uint64_t>::max()) return;
  for (uint16_t voice = 0; voice < voice_capacity_; ++voice) {
    auto& state = voices_[voice];
    if (state.stage != VoiceStage::kActive || state.channel != channel ||
        state.note_instance != instance) continue;
    if (channels_[channel].sustain) state.stage = VoiceStage::kSustainHeld;
    else release_voice(voice);
  }
}

void McuSf2AssetRuntime::control_change(uint8_t channel, uint8_t controller,
                                        uint8_t value) {
  channel &= 0x0f;
  controller &= 0x7f;
  value &= 0x7f;
  ChannelState& state = channels_[channel];
  state.sources.cc[controller] = value;
  if (controller == 64) {
    const bool sustain = value >= 64;
    if (state.sustain && !sustain) {
      for (uint16_t voice = 0; voice < voice_capacity_; ++voice) {
        if (voices_[voice].stage == VoiceStage::kSustainHeld &&
            voices_[voice].channel == channel) release_voice(voice);
      }
    }
    state.sustain = sustain;
  } else if (controller == 67) {
    state.soft = value >= 64;
  } else if (controller == 120) {
    all_sound_off(channel);
    return;
  }
  for (uint16_t voice = 0; voice < voice_capacity_; ++voice) {
    if (voices_[voice].stage != VoiceStage::kFree &&
        voices_[voice].channel == channel) refresh_voice(voice);
  }
}

void McuSf2AssetRuntime::pitch_bend(uint8_t channel, int16_t value) {
  channel &= 0x0f;
  channels_[channel].sources.pitch_bend =
      int16_t(std::max(-8192, std::min(8191, int(value))));
  for (uint16_t voice = 0; voice < voice_capacity_; ++voice) {
    if (voices_[voice].stage != VoiceStage::kFree &&
        voices_[voice].channel == channel) refresh_voice(voice);
  }
}

void McuSf2AssetRuntime::channel_pressure(uint8_t channel, uint8_t value) {
  channel &= 0x0f;
  channels_[channel].sources.channel_pressure = value & 0x7f;
  for (uint16_t voice = 0; voice < voice_capacity_; ++voice) {
    if (voices_[voice].stage != VoiceStage::kFree &&
        voices_[voice].channel == channel) refresh_voice(voice);
  }
}

void McuSf2AssetRuntime::key_pressure(uint8_t channel, uint8_t note,
                                     uint8_t value) {
  channel &= 0x0f;
  note &= 0x7f;
  channels_[channel].sources.key_pressure[note] = value & 0x7f;
  for (uint16_t voice = 0; voice < voice_capacity_; ++voice) {
    if (voices_[voice].stage != VoiceStage::kFree &&
        voices_[voice].channel == channel && voices_[voice].note == note) {
      refresh_voice(voice);
    }
  }
}

void McuSf2AssetRuntime::advance_samples(uint32_t samples) {
  for (uint16_t voice = 0; voice < voice_capacity_; ++voice) {
    VoiceState& state = voices_[voice];
    if (state.stage == VoiceStage::kFree) continue;
    advance_modulation(voice);
    if (state.stage == VoiceStage::kReleased) {
      if (samples >= state.release_samples) reclaim_voice(voice);
      else state.release_samples -= samples;
    }
  }
  ++control_tick_index_;
}

void McuSf2AssetRuntime::all_sound_off(uint8_t channel) {
  channel &= 0x0f;
  for (uint16_t voice = 0; voice < voice_capacity_; ++voice) {
    if (voices_[voice].stage != VoiceStage::kFree &&
        voices_[voice].channel == channel) stop_voice(voice);
  }
}

}  // namespace host
