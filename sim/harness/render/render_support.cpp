#include "render_support.h"

#include "command_control.h"
#include "midi_parser.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <limits>
#include <map>
#include <stdexcept>

namespace render {
namespace {

constexpr int kMidiDrumChannel = 9;
constexpr int kSf2PercussionBank = 128;
constexpr uint16_t kGenModLfoToPitch = 5;
constexpr uint16_t kGenVibLfoToPitch = 6;
constexpr uint16_t kGenModEnvToPitch = 7;
constexpr uint16_t kGenInitialFilterFc = 8;
constexpr uint16_t kGenModLfoToFilterFc = 10;
constexpr uint16_t kGenModEnvToFilterFc = 11;
constexpr uint16_t kGenModLfoToVolume = 13;
constexpr uint16_t kGenChorusEffectsSend = 15;
constexpr uint16_t kGenReverbEffectsSend = 16;
constexpr uint16_t kGenPan = 17;
constexpr uint16_t kGenCoarseTune = 51;
constexpr uint16_t kGenFineTune = 52;
constexpr uint16_t kGenInitialAttenuation = 48;
constexpr uint16_t kModSrcNone = 0x0000;
constexpr uint16_t kModSrcNoteOnVelocity = 0x0502;
constexpr uint16_t kModSrcNoteOnVelocityFilter = 0x0102;
constexpr uint16_t kModSrcChannelPressure = 0x000d;
constexpr uint16_t kModSrcCc1 = 0x0081;
constexpr uint16_t kModSrcCc7 = 0x0587;
constexpr uint16_t kModSrcCc10 = 0x028a;
constexpr uint16_t kModSrcCc11 = 0x058b;
constexpr uint16_t kModSrcCc91 = 0x00db;
constexpr uint16_t kModSrcCc93 = 0x00dd;
constexpr uint16_t kModSrcPitchWheel = 0x020e;
constexpr uint16_t kModSrcPitchWheelSensitivity = 0x0010;
constexpr uint16_t kTransformLinear = 0;
constexpr uint16_t kTransformAbsoluteValue = 2;
constexpr uint8_t kDirtyGain = 1u << 0;
constexpr uint8_t kDirtyPitch = 1u << 1;
constexpr uint8_t kDirtyFilter = 1u << 2;
constexpr uint8_t kDirtyAll = kDirtyGain | kDirtyPitch | kDirtyFilter;

int64_t integer_to_q16(int value) {
  return int64_t(value) * kMcuModulationOne;
}

int64_t multiply_q16(int64_t a, int64_t b) {
  const int64_t product = a * b;
  const int64_t bias = product >= 0 ? int64_t(1) << 15 : -(int64_t(1) << 15);
  return (product + bias) / (int64_t(1) << 16);
}

int round_q16_to_int(int64_t value) {
  const int64_t bias = value >= 0 ? int64_t(1) << 15 : -(int64_t(1) << 15);
  return int((value + bias) / (int64_t(1) << 16));
}

double q16_to_double(int64_t value) {
  return double(value) / double(kMcuModulationOne);
}

bool is_no_matching_zone_error(const std::runtime_error& e) {
  return std::string(e.what()) == "no SF2 zone matches key/velocity";
}

int linear_ramp(int start, int target, int tick, int ticks) {
  double x = double(std::max(1, tick)) / double(std::max(1, ticks));
  return clamp_q15(int(std::round(double(start) + double(target - start) * x)));
}

int db_decay(int start, int target, int tick, int ticks) {
  if (tick >= ticks) return clamp_q15(target);
  if (start <= 0) return clamp_q15(target);
  double x = double(std::max(1, tick)) / double(std::max(1, ticks));
  double s = double(std::max(1, start));
  double t = double(std::max(1, target));
  return clamp_q15(int(std::round(s * std::pow(t / s, x))));
}

int linear_release(int start, int tick, int ticks) {
  return linear_ramp(start, 0, tick, ticks);
}

const std::vector<Sf2Modulator>& fallback_default_modulators() {
  static const std::vector<Sf2Modulator> mods = {
      {kModSrcNoteOnVelocity, kGenInitialAttenuation, 960, kModSrcNone, kTransformLinear},
      {kModSrcNoteOnVelocityFilter, kGenInitialFilterFc, -2400, kModSrcNone, kTransformLinear},
      {kModSrcChannelPressure, kGenVibLfoToPitch, 50, kModSrcNone, kTransformLinear},
      {kModSrcCc1, kGenVibLfoToPitch, 50, kModSrcNone, kTransformLinear},
      {kModSrcCc7, kGenInitialAttenuation, 960, kModSrcNone, kTransformLinear},
      {kModSrcCc10, kGenPan, 500, kModSrcNone, kTransformLinear},
      {kModSrcCc11, kGenInitialAttenuation, 960, kModSrcNone, kTransformLinear},
      {kModSrcPitchWheel, 0, 12700, kModSrcPitchWheelSensitivity, kTransformLinear},
  };
  return mods;
}

bool is_note_on_source(uint16_t source) {
  if (source & 0x0080u) return false;
  int index = source & 0x007fu;
  return index == 2 || index == 3;
}

bool is_realtime_source(uint16_t source) {
  if (source == kModSrcNone) return false;
  if (source & 0x0080u) return true;
  int index = source & 0x007fu;
  return index == 10 || index == 13 || index == 14 || index == 16;
}

bool same_filter_config(const FilterConfig& a, const FilterConfig& b) {
  return a.enable == b.enable && a.b0 == b.b0 && a.b1 == b.b1 &&
         a.b2 == b.b2 && a.a1 == b.a1 && a.a2 == b.a2;
}

bool same_runtime_gain(int gain_l, int gain_r, int last_gain_l, int last_gain_r) {
  return gain_l == last_gain_l && gain_r == last_gain_r;
}

}  // namespace

void prepare_events_and_regions(const Args& args, const Sf2Data& sf2, int sample_count,
                                int control_tick_samples, std::vector<NoteEvent>& events,
                                std::vector<Region>& regions,
                                std::vector<int16_t>& wave_memory) {
  double render_seconds = double(sample_count) / double(args.sample_rate);
  double start_seconds = std::max(0.0, args.start_seconds);
  double end_seconds = start_seconds + render_seconds;
  std::stable_sort(events.begin(), events.end(), [](const NoteEvent& a, const NoteEvent& b) {
    return a.time_seconds < b.time_seconds;
  });

  std::array<std::deque<uint64_t>, 16 * 128> pending_notes;
  uint64_t next_note_instance = 0;
  for (NoteEvent& event : events) {
    if (event.type != NoteEvent::EVENT_NOTE) continue;
    auto& pending = pending_notes[(event.channel & 0x0f) * 128 + (event.note & 0x7f)];
    if (event.on && event.velocity != 0) {
      event.note_instance = ++next_note_instance;
      pending.push_back(event.note_instance);
    } else if (!pending.empty()) {
      event.note_instance = pending.front();
      pending.pop_front();
    } else {
      // Keep an unmatched Note Off from releasing an unrelated older voice.
      event.note_instance = ++next_note_instance;
    }
  }

  std::vector<NoteEvent> windowed_events;
  windowed_events.reserve(events.size());
  for (NoteEvent e : events) {
    if (e.time_seconds < start_seconds) {
      if (e.type != NoteEvent::EVENT_NOTE) {
        e.time_seconds = 0.0;
        windowed_events.push_back(e);
      }
      continue;
    }
    if (e.time_seconds >= end_seconds) continue;
    e.time_seconds -= start_seconds;
    windowed_events.push_back(e);
  }
  events.swap(windowed_events);
  if (events.empty()) throw std::runtime_error("no MIDI events fall inside the requested render window");

  std::map<std::array<int, 4>, std::vector<int>> region_by_key;
  int forced_inst = args.instrument.empty() ? -1 : select_instrument(sf2, args.instrument);
  Sf2RegionCache compiled_regions(sf2, args.sample_rate, control_tick_samples);
  std::vector<NoteEvent> expanded_events;
  int playable_note_ons = 0;

  for (auto& e : events) {
    if (e.type != NoteEvent::EVENT_NOTE || !e.on) {
      expanded_events.push_back(e);
      continue;
    }
    int key = std::max(0, std::min(127, e.note));
    int velocity = std::max(1, std::min(127, e.velocity));
    int program = std::max(0, std::min(127, e.program));
    int bank = e.channel == kMidiDrumChannel ? kSf2PercussionBank : std::max(0, std::min(16383, e.bank));
    std::array<int, 4> region_key = {forced_inst >= 0 ? forced_inst : program, bank, key, velocity};
    auto it = region_by_key.find(region_key);
    if (it == region_by_key.end()) {
      std::shared_ptr<const std::vector<Region>> made;
      try {
        made = forced_inst >= 0
          ? compiled_regions.regions_for_instrument(forced_inst, key, velocity)
          : compiled_regions.regions_for_preset(program, bank, key, velocity);
      } catch (const std::runtime_error& ex) {
        if (!is_no_matching_zone_error(ex)) throw;
      }
      std::vector<int> indices;
      if (made) {
        for (const auto& made_region : *made) {
          Region r = made_region;
          r.control_tick_samples = control_tick_samples;
          indices.push_back(int(regions.size()));
          regions.push_back(std::move(r));
        }
      }
      region_by_key[region_key] = indices;
      it = region_by_key.find(region_key);
    }
    if (it->second.empty()) continue;
    for (int idx : it->second) {
      NoteEvent layered = e;
      layered.region = idx;
      layered.phase_inc = regions[layered.region].phase_inc;
      expanded_events.push_back(layered);
      ++playable_note_ons;
    }
  }
  events.swap(expanded_events);

  if (playable_note_ons == 0) {
    throw std::runtime_error("no playable MIDI note-on events matched the selected SF2 regions");
  }

  for (const auto& r : regions) {
    uint32_t last_l = r.base_addr + (r.length ? r.length - 1 : 0);
    uint32_t last_r = r.base_addr_r + (r.length_r ? r.length_r - 1 : 0);
    if (r.length != 0 && (last_l >= wave_memory.size() ||
        (r.stereo && (r.length_r == 0 || last_r >= wave_memory.size())))) {
      throw std::runtime_error("selected SF2 region points outside the wave memory image");
    }
  }

  for (auto& e : events) {
    e.sample = std::max(0, std::min(sample_count, int(std::round(e.time_seconds * args.sample_rate))));
  }
  std::stable_sort(events.begin(), events.end(), [](const NoteEvent& a, const NoteEvent& b) {
    return a.sample < b.sample;
  });
}

McuModel::McuModel(VoiceCommandSink& sink, const std::vector<Region>& regions,
                   RenderDiagnostics* diagnostics, ControlUpdateRates update_rates)
    : sink_(sink), regions_(regions), diagnostics_(diagnostics),
      update_rates_(update_rates) {
  if (update_rates_.gain_ticks == 0 || update_rates_.pitch_ticks == 0 ||
      update_rates_.filter_ticks == 0) {
    throw std::invalid_argument("control update rates must be nonzero");
  }
  active_positions_.fill(-1);
  for (auto& channel : channels_) {
    channel.fixed_sources.cc[7] = 127;
    channel.fixed_sources.cc[10] = 64;
    channel.fixed_sources.cc[11] = 127;
  }
}

void McuModel::activate_voice(int voice) {
  if (active_positions_[voice] >= 0) return;
  active_positions_[voice] = active_voice_count_;
  active_voices_[active_voice_count_++] = voice;
  if (diagnostics_) {
    diagnostics_->control_active_voices = uint32_t(active_voice_count_);
    diagnostics_->control_max_active_voices = std::max(
        diagnostics_->control_max_active_voices, uint32_t(active_voice_count_));
  }
}

void McuModel::deactivate_voice(int voice) {
  const int position = active_positions_[voice];
  if (position < 0) return;
  const int replacement = active_voices_[--active_voice_count_];
  active_voices_[position] = replacement;
  active_positions_[replacement] = position;
  active_positions_[voice] = -1;
  if (diagnostics_) diagnostics_->control_active_voices = uint32_t(active_voice_count_);
}

void McuModel::consume_voice_completions(
    const std::vector<VoiceCompletion>& completions, uint32_t sample) {
  current_sample_ = sample;
  for (const VoiceCompletion& completion : completions) {
    if (completion.voice >= kNumVoices || completion.reason > 2) {
      throw std::runtime_error("invalid FPGA voice completion");
    }
    VoiceState& voice = voices_[completion.voice];
    if (voice.state == ENV_SILENT ||
        voice.generation != completion.generation) {
      continue;
    }
    voice.state = ENV_SILENT;
    voice.level = 0;
    voice.sustain_held = false;
    voice.sostenuto_held = false;
    voice.mod_env_state = ENV_SILENT;
    deactivate_voice(completion.voice);
  }
}

void McuModel::record_emitted_commands(uint64_t count) {
  if (diagnostics_) diagnostics_->control_emitted_commands += count;
}

void McuModel::handle_event(const NoteEvent& event) {
  if (event.type == NoteEvent::EVENT_CONTROL) control_change(event);
  else if (event.type == NoteEvent::EVENT_PITCH_BEND) pitch_bend(event);
  else if (event.type == NoteEvent::EVENT_CHANNEL_PRESSURE) channel_pressure(event);
  else if (event.type == NoteEvent::EVENT_KEY_PRESSURE) key_pressure(event);
  else if (event.type == NoteEvent::EVENT_NOTE && event.on) note_on(event);
  else if (event.type == NoteEvent::EVENT_NOTE) note_off(event.channel, event.note, event.note_instance);
}

bool McuModel::region_in_use(int region) const {
  for (int index = 0; index < active_voice_count_; ++index) {
    if (voices_[active_voices_[index]].region == region) return true;
  }
  return false;
}

void McuModel::control_tick() {
  const auto tick_start = std::chrono::steady_clock::now();
  int active_index = 0;
  while (active_index < active_voice_count_) {
    const int v = active_voices_[active_index];
    if (voices_[v].state == ENV_RELEASE) {
      ++active_index;
      continue;
    }
    int next = voices_[v].level;
    if (voices_[v].state == ENV_DELAY) {
      if (voices_[v].ticks_remaining > 0) --voices_[v].ticks_remaining;
      if (voices_[v].ticks_remaining == 0) voices_[v].state = ENV_ATTACK;
    } else if (voices_[v].state == ENV_ATTACK) {
      const Region& r = regions_.at(voices_[v].region);
      voices_[v].env_stage_tick += 1;
      next = linear_ramp(0, voices_[v].target, voices_[v].env_stage_tick, r.attack_ticks);
      if (voices_[v].env_stage_tick >= r.attack_ticks) {
        next = voices_[v].target;
        voices_[v].ticks_remaining = r.hold_ticks;
        voices_[v].env_stage_tick = 0;
        voices_[v].state = voices_[v].ticks_remaining > 0 ? ENV_HOLD : ENV_DECAY;
      }
    } else if (voices_[v].state == ENV_HOLD) {
      if (voices_[v].ticks_remaining > 0) --voices_[v].ticks_remaining;
      if (voices_[v].ticks_remaining == 0) voices_[v].state = ENV_DECAY;
    } else if (voices_[v].state == ENV_DECAY) {
      const Region& r = regions_.at(voices_[v].region);
      voices_[v].env_stage_tick += 1;
      next = db_decay(voices_[v].target, voices_[v].sustain, voices_[v].env_stage_tick, r.decay_ticks);
      if (voices_[v].env_stage_tick >= r.decay_ticks) {
        next = voices_[v].sustain;
        voices_[v].env_stage_tick = 0;
        voices_[v].state = ENV_SUSTAIN;
      }
    }

    if (voices_[v].state != ENV_SILENT || voices_[v].level != 0) {
      voices_[v].level = clamp_q15(next);
      uint8_t periodic_groups = 0;
      if ((control_tick_index_ % update_rates_.gain_ticks) == 0) periodic_groups |= kDirtyGain;
      if ((control_tick_index_ % update_rates_.pitch_ticks) == 0) periodic_groups |= kDirtyPitch;
      if ((control_tick_index_ % update_rates_.filter_ticks) == 0) periodic_groups |= kDirtyFilter;
      update_voice_modulation(v, periodic_groups, true);
    }
    ++active_index;
  }
  control_tick_index_ += 1;
  if (diagnostics_) {
    const uint64_t elapsed = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - tick_start).count());
    diagnostics_->control_tick_count += 1;
    diagnostics_->control_tick_total_ns += elapsed;
    diagnostics_->control_tick_max_ns = std::max(diagnostics_->control_tick_max_ns, elapsed);
    diagnostics_->control_active_voices = uint32_t(active_voice_count_);
    diagnostics_->control_max_active_voices = std::max(
        diagnostics_->control_max_active_voices, uint32_t(active_voice_count_));
  }
}

void McuModel::control_change(const NoteEvent& event) {
  int channel = event.channel & 0x0f;
  int value = std::max(0, std::min(127, event.value));
  channels_[channel].cc[event.controller & 0x7f] = value;
  channels_[channel].fixed_sources.cc[event.controller & 0x7f] = uint8_t(value);
  switch (event.controller & 0x7f) {
    case 1:
      channels_[channel].modulation = value;
      update_channel_controls(channel);
      break;
    case 7:
      channels_[channel].volume = value;
      update_channel_controls(channel, kDirtyGain);
      break;
    case 10:
      channels_[channel].pan = value;
      update_channel_controls(channel, kDirtyGain);
      break;
    case 11:
      channels_[channel].expression = value;
      update_channel_controls(channel, kDirtyGain);
      break;
    case 67:
      channels_[channel].soft = value >= 64;
      update_channel_controls(channel, kDirtyGain);
      break;
    case 66:
      if (value >= 64 && !channels_[channel].sostenuto) {
        channels_[channel].sostenuto = true;
        for (int v = 0; v < kNumVoices; ++v) {
          if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel && !voices_[v].key_released) {
            voices_[v].sostenuto_held = true;
          }
        }
      } else if (value < 64 && channels_[channel].sostenuto) {
        channels_[channel].sostenuto = false;
        for (int v = 0; v < kNumVoices; ++v) {
          if (voices_[v].channel == channel) voices_[v].sostenuto_held = false;
        }
        release_deferred_pedal_voices(channel);
      }
      break;
    case 98:
      channels_[channel].nrpn_generator = value < 100 ? channels_[channel].nrpn_base + value : -1;
      if (value == 100) channels_[channel].nrpn_base = 100;
      else if (value == 101) channels_[channel].nrpn_base = 1000;
      else if (value == 102) channels_[channel].nrpn_base = 10000;
      else if (value < 100) channels_[channel].nrpn_base = 0;
      channels_[channel].data_entry_is_nrpn = true;
      break;
    case 99:
      channels_[channel].nrpn_msb = value;
      channels_[channel].data_entry_is_nrpn = true;
      if (value != 120) channels_[channel].nrpn_generator = -1;
      break;
    case 100:
      channels_[channel].rpn_lsb = value;
      channels_[channel].data_entry_is_nrpn = false;
      break;
    case 101:
      channels_[channel].rpn_msb = value;
      channels_[channel].data_entry_is_nrpn = false;
      break;
    case 6:
      apply_data_entry(channel, value);
      break;
    case 38:
      channels_[channel].data_entry_lsb = value;
      if (!channels_[channel].data_entry_is_nrpn && channels_[channel].rpn_msb == 0 &&
          (channels_[channel].rpn_lsb == 0 || channels_[channel].rpn_lsb == 1)) {
        apply_data_entry(channel, channels_[channel].cc[6]);
      }
      break;
    case 64:
      if (value >= 64) {
        channels_[channel].sustain = true;
      } else {
        channels_[channel].sustain = false;
        release_deferred_pedal_voices(channel);
      }
      break;
    case 120:
      for (int v = 0; v < kNumVoices; ++v) {
        if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel) {
          voices_[v].state = ENV_SILENT;
          voices_[v].level = 0;
          voices_[v].sustain_held = false;
          voices_[v].sostenuto_held = false;
          voices_[v].mod_env_state = ENV_SILENT;
          sink_.stop_voice(v);
          record_emitted_commands();
          deactivate_voice(v);
        }
      }
      break;
    case 121:
      reset_controllers(channel);
      update_channel_controls(channel);
      release_deferred_pedal_voices(channel);
      break;
    case 123:
    case 124:
    case 125:
    case 126:
    case 127:
      all_notes_off(channel);
      break;
    default:
      break;
  }
}

void McuModel::channel_pressure(const NoteEvent& event) {
  int channel = event.channel & 0x0f;
  channels_[channel].channel_pressure = std::max(0, std::min(127, event.value));
  channels_[channel].fixed_sources.channel_pressure =
      uint8_t(channels_[channel].channel_pressure);
  update_channel_controls(channel);
}

void McuModel::key_pressure(const NoteEvent& event) {
  int channel = event.channel & 0x0f;
  int note = event.note & 0x7f;
  channels_[channel].key_pressure[note] = std::max(0, std::min(127, event.value));
  channels_[channel].fixed_sources.key_pressure[note] =
      uint8_t(channels_[channel].key_pressure[note]);
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel && voices_[v].note == note) {
      update_voice_controls(v);
    }
  }
}

void McuModel::pitch_bend(const NoteEvent& event) {
  int channel = event.channel & 0x0f;
  channels_[channel].pitch_bend = std::max(-8192, std::min(8191, event.pitch_bend));
  channels_[channel].fixed_sources.pitch_bend = int16_t(channels_[channel].pitch_bend);
  update_channel_controls(channel, kDirtyPitch);
}

void McuModel::release_deferred_pedal_voices(int channel) {
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state == ENV_SILENT || voices_[v].channel != channel || !voices_[v].key_released) continue;
    if (channels_[channel].sustain || voices_[v].sostenuto_held) continue;
    voices_[v].sustain_held = false;
    release_voice(v);
  }
}

void McuModel::all_notes_off(int channel) {
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state == ENV_SILENT || voices_[v].channel != channel || voices_[v].key_released) continue;
    voices_[v].key_released = true;
    if (channels_[channel].sustain) voices_[v].sustain_held = true;
    if (channels_[channel].sustain || voices_[v].sostenuto_held) continue;
    release_voice(v);
  }
}

void McuModel::apply_data_entry(int channel, int msb_value) {
  ChannelState& c = channels_[channel];
  int data14 = (std::max(0, std::min(127, msb_value)) << 7) |
               std::max(0, std::min(127, c.data_entry_lsb));
  if (c.data_entry_is_nrpn && c.nrpn_msb == 120 && c.nrpn_generator >= 0 &&
      c.nrpn_generator < int(c.generator_offsets_q16.size())) {
    auto range = [](int generator) -> int {
      switch (generator) {
        case kGenInitialFilterFc:
        case kGenModLfoToPitch:
        case kGenVibLfoToPitch:
        case kGenModEnvToPitch:
        case kGenModLfoToFilterFc:
        case kGenModEnvToFilterFc:
          return 6000;
        case kGenModLfoToVolume:
          return 1920;
        case kGenPan:
          return 1000;
        case kGenInitialAttenuation:
          return 1440;
        case kGenCoarseTune:
          return 240;
        case kGenFineTune:
          return 198;
        default:
          return 0;
      }
    };
    const int span = range(c.nrpn_generator);
    if (span > 0) {
      c.generator_offsets_q16[c.nrpn_generator] = int32_t(
          (int64_t(data14 - 0x2000) * span * kMcuModulationOne) / 8192);
      update_channel_controls(channel);
    }
    return;
  }

  if (!c.data_entry_is_nrpn && c.rpn_msb == 0 && c.rpn_lsb == 0) {
    c.pitch_bend_range_semitones = std::max(0, std::min(127, msb_value));
    c.pitch_bend_range_cents = c.data_entry_lsb;
    c.fixed_sources.pitch_bend_range_semitones = uint8_t(c.pitch_bend_range_semitones);
    c.fixed_sources.pitch_bend_range_cents = uint8_t(c.pitch_bend_range_cents);
    update_channel_controls(channel);
  } else if (!c.data_entry_is_nrpn && c.rpn_msb == 0 && c.rpn_lsb == 1) {
    c.generator_offsets_q16[kGenFineTune] = int32_t(
        (int64_t(data14 - 8192) * 100 * kMcuModulationOne) / 8192);
    update_channel_controls(channel);
  } else if (!c.data_entry_is_nrpn && c.rpn_msb == 0 && c.rpn_lsb == 2) {
    c.generator_offsets_q16[kGenCoarseTune] = int32_t(integer_to_q16(
        (std::max(0, std::min(127, msb_value)) - 64) * 100));
    update_channel_controls(channel);
  }
}

void McuModel::reset_controllers(int channel) {
  ChannelState& c = channels_[channel];
  c.cc.fill(0);
  c.key_pressure.fill(0);
  c.generator_offsets_q16.fill(0);
  c.fixed_sources = {};
  c.fixed_sources.cc[7] = 127;
  c.fixed_sources.cc[10] = 64;
  c.fixed_sources.cc[11] = 127;
  c.volume = 127;
  c.expression = 127;
  c.pan = 64;
  c.pitch_bend = 0;
  c.modulation = 0;
  c.channel_pressure = 0;
  c.rpn_msb = 127;
  c.rpn_lsb = 127;
  c.nrpn_msb = 127;
  c.nrpn_base = 0;
  c.nrpn_generator = -1;
  c.data_entry_lsb = 0;
  c.pitch_bend_range_semitones = 2;
  c.pitch_bend_range_cents = 0;
  c.sustain = false;
  c.soft = false;
  c.sostenuto = false;
  c.data_entry_is_nrpn = false;
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].channel == channel) {
      voices_[v].sustain_held = false;
      voices_[v].sostenuto_held = false;
    }
  }
}

void McuModel::record_runtime_gain_update(int voice, int gain_l, int gain_r) {
  if (diagnostics_ && diagnostics_->detailed_enabled) {
    diagnostics_->runtime_gain_updates += 1;
    if (runtime_gain_valid_[voice]) {
      auto diff = [](int a, int b) {
        return uint32_t(std::abs(int64_t(a) - int64_t(b)));
      };
      diagnostics_->max_runtime_gain_jump_l = std::max(diagnostics_->max_runtime_gain_jump_l,
                                                       diff(gain_l, last_runtime_gain_l_[voice]));
      diagnostics_->max_runtime_gain_jump_r = std::max(diagnostics_->max_runtime_gain_jump_r,
                                                       diff(gain_r, last_runtime_gain_r_[voice]));
    }
  }
  runtime_gain_valid_[voice] = true;
  last_runtime_gain_l_[voice] = gain_l;
  last_runtime_gain_r_[voice] = gain_r;
}

void McuModel::record_runtime_phase_update(int voice, uint32_t phase_inc) {
  if (diagnostics_ && diagnostics_->detailed_enabled) {
    diagnostics_->runtime_phase_updates += 1;
    if (runtime_phase_valid_[voice]) {
      uint32_t jump = phase_inc >= last_runtime_phase_inc_[voice]
                          ? phase_inc - last_runtime_phase_inc_[voice]
                          : last_runtime_phase_inc_[voice] - phase_inc;
      diagnostics_->max_runtime_phase_inc_jump = std::max(diagnostics_->max_runtime_phase_inc_jump, jump);
    }
  }
  runtime_phase_valid_[voice] = true;
  last_runtime_phase_inc_[voice] = phase_inc;
}

void McuModel::record_runtime_filter_update(int voice, const FilterConfig& filter) {
  if (diagnostics_ && diagnostics_->detailed_enabled) {
    diagnostics_->runtime_filter_updates += 1;
    if (runtime_filter_valid_[voice]) {
      const FilterConfig& last = last_runtime_filter_[voice];
      auto diff = [](int a, int b) {
        return uint32_t(std::abs(int64_t(a) - int64_t(b)));
      };
      uint32_t max_jump = 0;
      max_jump = std::max(max_jump, diff(filter.b0, last.b0));
      max_jump = std::max(max_jump, diff(filter.b1, last.b1));
      max_jump = std::max(max_jump, diff(filter.b2, last.b2));
      max_jump = std::max(max_jump, diff(filter.a1, last.a1));
      max_jump = std::max(max_jump, diff(filter.a2, last.a2));
      if (filter.enable != last.enable) max_jump = std::max(max_jump, uint32_t(1));
      diagnostics_->max_runtime_filter_coeff_jump = std::max(diagnostics_->max_runtime_filter_coeff_jump,
                                                             max_jump);
    }
  }
  runtime_filter_valid_[voice] = true;
  last_runtime_filter_[voice] = filter;
}

void McuModel::update_channel_controls(int channel, uint8_t dirty_groups) {
  for (int index = 0; index < active_voice_count_; ++index) {
    const int voice = active_voices_[index];
    if (voices_[voice].channel == channel) update_voice_controls(voice, dirty_groups);
  }
}

void McuModel::update_voice_controls(int voice, uint8_t dirty_groups) {
  update_voice_modulation(voice, dirty_groups, false);
}

void McuModel::update_voice_modulation(int voice, uint8_t dirty_groups,
                                       bool advance_modulation) {
  VoiceState& state = voices_.at(voice);
  if (state.state == ENV_SILENT) return;
  const Region& r = regions_.at(state.region);
  const ChannelState& c = channels_.at(state.channel & 0x0f);

  int mod_next = state.mod_env_level;
  if (advance_modulation && state.mod_env_state == ENV_DELAY) {
    if (state.mod_env_ticks_remaining > 0) --state.mod_env_ticks_remaining;
    if (state.mod_env_ticks_remaining == 0) state.mod_env_state = ENV_ATTACK;
  } else if (advance_modulation && state.mod_env_state == ENV_ATTACK) {
    state.mod_env_stage_tick += 1;
    mod_next = linear_ramp(0, kQ15Full, state.mod_env_stage_tick, r.mod_env_attack_ticks);
    if (state.mod_env_stage_tick >= r.mod_env_attack_ticks) {
      mod_next = kQ15Full;
      state.mod_env_ticks_remaining = r.mod_env_hold_ticks;
      state.mod_env_stage_tick = 0;
      state.mod_env_state = state.mod_env_ticks_remaining > 0 ? ENV_HOLD : ENV_DECAY;
    }
  } else if (advance_modulation && state.mod_env_state == ENV_HOLD) {
    if (state.mod_env_ticks_remaining > 0) --state.mod_env_ticks_remaining;
    if (state.mod_env_ticks_remaining == 0) state.mod_env_state = ENV_DECAY;
  } else if (advance_modulation && state.mod_env_state == ENV_DECAY) {
    state.mod_env_stage_tick += 1;
    mod_next = linear_ramp(kQ15Full, r.mod_env_sustain_level, state.mod_env_stage_tick, r.mod_env_decay_ticks);
    if (state.mod_env_stage_tick >= r.mod_env_decay_ticks) {
      mod_next = r.mod_env_sustain_level;
      state.mod_env_stage_tick = 0;
      state.mod_env_state = ENV_SUSTAIN;
    }
  } else if (advance_modulation && state.mod_env_state == ENV_RELEASE) {
    state.mod_env_stage_tick += 1;
    mod_next = linear_release(state.mod_env_release_start, state.mod_env_stage_tick, r.mod_env_release_ticks);
    if (state.mod_env_stage_tick >= r.mod_env_release_ticks) {
      mod_next = 0;
      state.mod_env_state = ENV_SILENT;
    }
  }
  state.mod_env_level = clamp_q15(mod_next);

  auto lfo_value_q16 = [](uint32_t phase) -> int32_t {
    const int32_t x = int32_t(phase & 0xffffu);
    if (x < 16384) return x * 4;
    if (x < 49152) return 131072 - x * 4;
    return x * 4 - 262144;
  };
  const int32_t mod_lfo_q16 = state.mod_lfo_wait_ticks > 0
                                  ? 0 : lfo_value_q16(state.mod_lfo_phase);
  const int32_t vib_lfo_q16 = state.vib_lfo_wait_ticks > 0
                                  ? 0 : lfo_value_q16(state.vib_lfo_phase);
  const int32_t env_q16 = int32_t((int64_t(state.mod_env_level) *
                                   kMcuModulationOne + kQ15Full / 2) / kQ15Full);

  if (diagnostics_) {
    diagnostics_->control_dirty_group_evaluations +=
        uint64_t((dirty_groups & kDirtyGain) != 0) +
        uint64_t((dirty_groups & kDirtyPitch) != 0) +
        uint64_t((dirty_groups & kDirtyFilter) != 0);
  }

  bool phase_changed = false;
  uint32_t phase_inc = runtime_phase_valid_[voice] ? last_runtime_phase_inc_[voice]
                                                   : r.phase_inc;
  if ((dirty_groups & kDirtyPitch) != 0) {
    int64_t pitch_q16 = c.generator_offsets_q16[kGenFineTune] +
                        c.generator_offsets_q16[kGenCoarseTune] +
                        modulator_sum_q16(r, state, c, 0);
    pitch_q16 += multiply_q16(mod_lfo_q16,
        integer_to_q16(r.mod_lfo_to_pitch) +
        c.generator_offsets_q16[kGenModLfoToPitch] +
        modulator_sum_q16(r, state, c, kGenModLfoToPitch));
    pitch_q16 += multiply_q16(vib_lfo_q16,
        integer_to_q16(r.vib_lfo_to_pitch) +
        modulator_sum_q16(r, state, c, kGenVibLfoToPitch));
    pitch_q16 += multiply_q16(env_q16,
        integer_to_q16(r.mod_env_to_pitch) +
        modulator_sum_q16(r, state, c, kGenModEnvToPitch));
    phase_inc = modulated_phase_inc(r.phase_inc, q16_to_double(pitch_q16));
    phase_changed = !runtime_phase_valid_[voice] || phase_inc != last_runtime_phase_inc_[voice];
  }

  if ((dirty_groups & kDirtyFilter) != 0) {
    int64_t filter_q16 = integer_to_q16(r.initial_filter_fc) +
                         c.generator_offsets_q16[kGenInitialFilterFc] +
                         modulator_sum_q16(r, state, c, kGenInitialFilterFc);
    filter_q16 += multiply_q16(mod_lfo_q16,
        integer_to_q16(r.mod_lfo_to_filter_fc) +
        c.generator_offsets_q16[kGenModLfoToFilterFc] +
        modulator_sum_q16(r, state, c, kGenModLfoToFilterFc));
    filter_q16 += multiply_q16(env_q16,
        integer_to_q16(r.mod_env_to_filter_fc) +
        c.generator_offsets_q16[kGenModEnvToFilterFc] +
        modulator_sum_q16(r, state, c, kGenModEnvToFilterFc));
    FilterConfig filter = filter_for(round_q16_to_int(filter_q16), r.initial_filter_q,
                                     r.output_sample_rate);
    if (!runtime_filter_valid_[voice] || !same_filter_config(filter, last_runtime_filter_[voice])) {
      record_runtime_filter_update(voice, filter);
      sink_.update_filter(voice, filter);
      record_emitted_commands();
    }
  }

  std::pair<int, int> gains = {last_runtime_gain_l_[voice], last_runtime_gain_r_[voice]};
  bool gain_changed = false;
  if ((dirty_groups & kDirtyGain) != 0) {
    state.tremolo_attenuation_cb_q16 = int32_t(-multiply_q16(
        mod_lfo_q16, integer_to_q16(r.mod_lfo_to_volume) +
        c.generator_offsets_q16[kGenModLfoToVolume] +
        modulator_sum_q16(r, state, c, kGenModLfoToVolume)));
    gains = runtime_gains(r, state, c);
    gain_changed = !runtime_gain_valid_[voice] ||
        !same_runtime_gain(gains.first, gains.second,
                           last_runtime_gain_l_[voice], last_runtime_gain_r_[voice]);
  }
  if (phase_changed || gain_changed) {
    if (phase_changed) record_runtime_phase_update(voice, phase_inc);
    if (gain_changed)
    record_runtime_gain_update(voice, gains.first, gains.second);
    sink_.update_gain_phase(voice, gains.first, gains.second, phase_inc);
    record_emitted_commands(uint64_t(phase_changed) + uint64_t(gain_changed));
  }

  if (advance_modulation) {
    if (state.mod_lfo_wait_ticks > 0) --state.mod_lfo_wait_ticks;
    else state.mod_lfo_phase += r.mod_lfo_step;
    if (state.vib_lfo_wait_ticks > 0) --state.vib_lfo_wait_ticks;
    else state.vib_lfo_phase += r.vib_lfo_step;
  }
}

void McuModel::release_voice(int voice) {
  voices_[voice].state = ENV_RELEASE;
  voices_[voice].env_stage_tick = 0;
  voices_[voice].release_start = voices_[voice].level;
  voices_[voice].mod_env_state = ENV_RELEASE;
  voices_[voice].mod_env_stage_tick = 0;
  voices_[voice].mod_env_release_start = voices_[voice].mod_env_level;
  voices_[voice].sustain_held = false;
  const Region& region = regions_.at(voices_[voice].region);
  sink_.release_voice(voice, envelope_release_step(region));
  record_emitted_commands();
}

void McuModel::note_off(int channel, int note, uint64_t note_instance) {
  channel &= 0x0f;
  if (note_instance == 0) {
    for (int v = 0; v < kNumVoices; ++v) {
      if (voices_[v].state == ENV_SILENT || voices_[v].channel != channel ||
          voices_[v].note != (note & 0x7f) || voices_[v].key_released) continue;
      if (note_instance == 0 || voices_[v].note_instance < note_instance) {
        note_instance = voices_[v].note_instance;
      }
    }
  }
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel &&
        voices_[v].note == (note & 0x7f) && !voices_[v].key_released &&
        voices_[v].note_instance == note_instance) {
      voices_[v].key_released = true;
      if (channels_[channel].sustain) voices_[v].sustain_held = true;
      if (voices_[v].sostenuto_held) {
        continue;
      }
      if (channels_[channel].sustain) continue;
      else release_voice(v);
    }
  }
}

void McuModel::note_on(const NoteEvent& event) {
  if (event.velocity == 0) {
    note_off(event.channel, event.note, event.note_instance);
    return;
  }

  uint64_t note_instance = event.note_instance;
  if (note_instance == 0) note_instance = ++next_note_instance_;
  else next_note_instance_ = std::max(next_note_instance_, note_instance);

  int slot = first_free_or_steal_slot();
  if (voices_[slot].state != ENV_SILENT && diagnostics_) {
    const VoiceState& stolen = voices_[slot];
    const Region& stolen_region = regions_.at(stolen.region);
    const ChannelState& stolen_channel = channels_[stolen.channel & 0x0f];
    const auto gains = runtime_gains(stolen_region, stolen, stolen_channel);
    const uint32_t level = uint32_t(std::max(0, stolen.level));
    const uint32_t gain_l = uint32_t(std::max(0, gains.first));
    const uint32_t gain_r = uint32_t(std::max(0, gains.second));
    const uint64_t score = uint64_t(level) * uint64_t(std::max(gain_l, gain_r));
    diagnostics_->voice_steals += 1;
    if (score >= diagnostics_->max_voice_steal_score) {
      diagnostics_->max_voice_steal_score = score;
      diagnostics_->max_voice_steal_level = level;
      diagnostics_->max_voice_steal_gain_l = gain_l;
      diagnostics_->max_voice_steal_gain_r = gain_r;
      diagnostics_->max_voice_steal_voice = slot;
      diagnostics_->max_voice_steal_tick = control_tick_index_;
    }
  }
  alloc_stamp_ = (alloc_stamp_ + 1) & 0xff;
  if (alloc_stamp_ == 0) alloc_stamp_ = 1;

  Region r = regions_.at(event.region);
  if (r.exclusive_class > 0) {
    for (int v = 0; v < kNumVoices; ++v) {
      const Region& active = regions_.at(voices_[v].region);
      if (voices_[v].state != ENV_SILENT && active.exclusive_class == r.exclusive_class &&
          active.program == r.program && active.bank == r.bank && active.preset == r.preset) {
        release_voice(v);
      }
    }
  }
  voices_[slot].note = event.note & 0x7f;
  runtime_gain_valid_[slot] = false;
  runtime_phase_valid_[slot] = false;
  runtime_filter_valid_[slot] = false;
  voices_[slot].channel = event.channel;
  voices_[slot].region = event.region;
  voices_[slot].state = r.delay_ticks > 0 ? ENV_DELAY : ENV_ATTACK;
  voices_[slot].level = 0;
  voices_[slot].velocity = r.effective_velocity >= 0 ? r.effective_velocity : event.velocity;
  voices_[slot].stamp = alloc_stamp_;
  voices_[slot].ticks_remaining = r.delay_ticks;
  voices_[slot].env_stage_tick = 0;
  voices_[slot].release_start = 0;
  voices_[slot].sustain_held = false;
  voices_[slot].sostenuto_held = false;
  voices_[slot].key_released = false;
  voices_[slot].note_instance = note_instance;
  voices_[slot].generation = uint16_t(voices_[slot].generation + 1u);
  if (voices_[slot].generation == 0) voices_[slot].generation = 1;
  voices_[slot].tremolo_attenuation_cb_q16 = 0;
  voices_[slot].mod_lfo_phase = 0;
  voices_[slot].vib_lfo_phase = 0;
  voices_[slot].mod_lfo_wait_ticks = r.mod_lfo_delay_ticks;
  voices_[slot].vib_lfo_wait_ticks = r.vib_lfo_delay_ticks;
  voices_[slot].mod_env_state = r.mod_env_delay_ticks > 0 ? ENV_DELAY : ENV_ATTACK;
  voices_[slot].mod_env_level = 0;
  voices_[slot].mod_env_ticks_remaining = r.mod_env_delay_ticks;
  voices_[slot].mod_env_stage_tick = 0;
  voices_[slot].mod_env_release_start = 0;
  // Note/velocity attenuation is already represented in runtime_gains(). Keep
  // the policy envelope normalized so voice-steal scoring does not apply it twice.
  voices_[slot].target = kQ15Full;
  voices_[slot].sustain = r.sustain_level;
  activate_voice(slot);
  if (r.mod_env_delay_ticks == 0 && r.mod_env_attack_sub_tick) {
    voices_[slot].mod_env_level = kQ15Full;
    voices_[slot].mod_env_ticks_remaining = r.mod_env_hold_ticks;
    voices_[slot].mod_env_stage_tick = 0;
    voices_[slot].mod_env_state = r.mod_env_hold_ticks > 0 ? ENV_HOLD : ENV_DECAY;
  }
  const ChannelState& channel = channels_[event.channel & 0x0f];
  const int32_t initial_env_q16 = int32_t(
      (int64_t(voices_[slot].mod_env_level) * kMcuModulationOne +
       kQ15Full / 2) / kQ15Full);
  int64_t initial_pitch_q16 =
      channel.generator_offsets_q16[kGenFineTune] +
      channel.generator_offsets_q16[kGenCoarseTune] +
      modulator_sum_q16(r, voices_[slot], channel, 0);
  initial_pitch_q16 += multiply_q16(
      initial_env_q16,
      integer_to_q16(r.mod_env_to_pitch) +
          modulator_sum_q16(r, voices_[slot], channel, kGenModEnvToPitch));
  uint32_t phase_inc = modulated_phase_inc(event.phase_inc,
                                            q16_to_double(initial_pitch_q16));
  auto initial_gains = runtime_gains(r, voices_[slot], channel);
  r.gain_l = initial_gains.first;
  r.gain_r = initial_gains.second;
  int64_t initial_filter_q16 = integer_to_q16(r.initial_filter_fc) +
      channel.generator_offsets_q16[kGenInitialFilterFc] +
      modulator_sum_q16(r, voices_[slot], channel, kGenInitialFilterFc);
  initial_filter_q16 += multiply_q16(
      initial_env_q16,
      integer_to_q16(r.mod_env_to_filter_fc) +
          channel.generator_offsets_q16[kGenModEnvToFilterFc] +
          modulator_sum_q16(r, voices_[slot], channel,
                            kGenModEnvToFilterFc));
  const FilterConfig initial_filter = filter_for(
      round_q16_to_int(initial_filter_q16), r.initial_filter_q,
      r.output_sample_rate);
  r.filter_enable = initial_filter.enable;
  r.filter_b0 = initial_filter.b0;
  r.filter_b1 = initial_filter.b1;
  r.filter_b2 = initial_filter.b2;
  r.filter_a1 = initial_filter.a1;
  r.filter_a2 = initial_filter.a2;
  sink_.start_voice(slot, phase_inc, r);
  record_emitted_commands();
  runtime_gain_valid_[slot] = true;
  last_runtime_gain_l_[slot] = r.gain_l;
  last_runtime_gain_r_[slot] = r.gain_r;
  runtime_phase_valid_[slot] = true;
  last_runtime_phase_inc_[slot] = phase_inc;
  runtime_filter_valid_[slot] = true;
  last_runtime_filter_[slot] = {r.filter_enable, r.filter_b0, r.filter_b1,
                                r.filter_b2, r.filter_a1, r.filter_a2};
}

int McuModel::first_free_or_steal_slot() {
  for (int v = 0; v < kNumVoices; ++v) {
    if (active_positions_[v] < 0) return v;
  }
  auto steal_score = [&](int v) -> uint64_t {
    const VoiceState& voice = voices_[v];
    const Region& region = regions_.at(voice.region);
    const ChannelState& channel = channels_[voice.channel & 0x0f];
    const auto gains = runtime_gains(region, voice, channel);
    const uint32_t gain = static_cast<uint32_t>(std::max(gains.first, gains.second));
    const uint32_t level = static_cast<uint32_t>(std::max(0, voice.level));
    return static_cast<uint64_t>(level) * gain;
  };
  int best = 0;
  for (int v = 1; v < kNumVoices; ++v) {
    bool v_released = voices_[v].state == ENV_RELEASE || voices_[v].key_released;
    bool best_released = voices_[best].state == ENV_RELEASE || voices_[best].key_released;
    if (v_released != best_released) {
      if (v_released) best = v;
      continue;
    }
    const uint64_t v_score = steal_score(v);
    const uint64_t best_score = steal_score(best);
    if (v_score != best_score) {
      if (v_score < best_score) best = v;
      continue;
    }
    if (((voices_[v].stamp - voices_[best].stamp) & 0xff) >= 128) best = v;
  }
  return best;
}

std::pair<int, int> McuModel::runtime_gains(const Region& region, const VoiceState& voice,
                                            const ChannelState& channel) {
  int64_t attenuation_q16 = modulator_sum_q16(
      region, voice, channel, kGenInitialAttenuation, false, true);
  attenuation_q16 += channel.generator_offsets_q16[kGenInitialAttenuation] +
                     voice.tremolo_attenuation_cb_q16;
  if (channel.soft) attenuation_q16 += integer_to_q16(30);
  const double level = attenuation_gain(q16_to_double(attenuation_q16));
  const int total_pan = std::max(-500, std::min(500, round_q16_to_int(
      integer_to_q16(region.pan) + channel.generator_offsets_q16[kGenPan] +
      modulator_sum_q16(region, voice, channel, kGenPan, false, true))));
  int base_left = region.stereo ? region.base_gain_l : region.base_gain;
  int base_right = region.stereo ? region.base_gain_r : region.base_gain;
  int scaled_left = clamp_q15(int(std::round(double(base_left) * level)));
  int scaled_right = clamp_q15(int(std::round(double(base_right) * level)));
  // Collapsed stereo regions are already hard-routed left/right, so normalize
  // their centered balance to unity. Mono follows FluidSynth's pan law exactly.
  return equal_power_pan_gains(scaled_left, scaled_right, total_pan, region.stereo);
}

int64_t McuModel::modulator_sum_q16(const Region& region, const VoiceState& voice,
                                   const ChannelState& channel, uint16_t dest,
                                   bool include_note_sources,
                                   bool include_realtime_sources) {
  const std::vector<Sf2Modulator>* mods = nullptr;
  if (!region.modulators_by_destination.empty()) {
    auto found = region.modulators_by_destination.find(dest);
    if (found == region.modulators_by_destination.end()) return 0;
    mods = &found->second;
  } else {
    mods = &fallback_default_modulators();
  }
  int64_t sum_q16 = 0;
  const McuFixedVoiceSources fixed_voice{
      uint8_t(std::max(0, std::min(127, voice.note))),
      uint8_t(std::max(1, std::min(127, voice.velocity)))};
  for (const auto& mod : *mods) {
    if (mod.dest != dest) continue;
    if (!include_note_sources && (is_note_on_source(mod.src) || is_note_on_source(mod.amount_src))) continue;
    if (!include_realtime_sources && (is_realtime_source(mod.src) || is_realtime_source(mod.amount_src))) continue;
    const McuSf2ModulationTerm term{
        mod.src, mod.dest, int16_t(mod.amount), mod.amount_src, mod.transform,
        uint16_t(mcu_sf2_source_dependencies(mod.src) |
                 mcu_sf2_source_dependencies(mod.amount_src))};
    sum_q16 += mcu_sf2_evaluate_term_q16(term, channel.fixed_sources, fixed_voice);
    if (diagnostics_) diagnostics_->control_modulator_evaluations += 1;
  }
  return sum_q16;
}

uint32_t McuModel::modulated_phase_inc(uint32_t base_phase_inc, double cents) {
  return mcu_sf2_phase_increment(
      base_phase_inc, int64_t(std::llround(cents * kMcuModulationOne)));
}

int q2_14(double value) {
  double raw = std::round(value * 16384.0);
  if (raw > double(std::numeric_limits<int16_t>::max())) return std::numeric_limits<int16_t>::max();
  if (raw < double(std::numeric_limits<int16_t>::min())) return std::numeric_limits<int16_t>::min();
  return int(raw);
}

FilterConfig calculate_filter(int cutoff_cents, int resonance_cb, int sample_rate) {
  cutoff_cents = std::max(1500, std::min(13500, cutoff_cents));
  double cutoff_hz = 8.176 * std::pow(2.0, double(cutoff_cents) / 1200.0);
  double nyquist = double(sample_rate) * 0.5;
  FilterConfig filter;
  if (cutoff_hz >= nyquist * 0.97) return filter;
  resonance_cb = std::max(0, std::min(960, resonance_cb));
  double q = std::max(0.5, std::pow(10.0, double(resonance_cb) / 200.0) * 0.7071067811865476);
  double omega = 2.0 * 3.14159265358979323846 * cutoff_hz / double(sample_rate);
  double sin_w = std::sin(omega);
  double cos_w = std::cos(omega);
  double alpha = sin_w / (2.0 * q);
  double a0 = 1.0 + alpha;
  filter.enable = true;
  filter.b0 = q2_14(((1.0 - cos_w) * 0.5) / a0);
  filter.b1 = q2_14((1.0 - cos_w) / a0);
  filter.b2 = q2_14(((1.0 - cos_w) * 0.5) / a0);
  filter.a1 = q2_14((-2.0 * cos_w) / a0);
  filter.a2 = q2_14((1.0 - alpha) / a0);
  return filter;
}

FilterConfig McuModel::filter_for(int cutoff_cents, int resonance_cb, int sample_rate) {
  cutoff_cents = std::max(1500, std::min(13500, cutoff_cents));
  resonance_cb = std::max(0, std::min(960, resonance_cb));
  const int quantized_cutoff = cutoff_cents;
  const int quantized_resonance = ((resonance_cb + 1) / 2) * 2;
  struct CacheEntry {
    int cutoff = 0;
    int resonance = 0;
    int sample_rate = 0;
    bool valid = false;
    FilterConfig filter;
  };
  static thread_local std::array<CacheEntry, 4096> cache{};
  const uint32_t hash = uint32_t(quantized_cutoff) * 2654435761u ^
                        uint32_t(quantized_resonance) * 2246822519u ^
                        uint32_t(sample_rate);
  CacheEntry& entry = cache[hash & (cache.size() - 1)];
  if (!entry.valid || entry.cutoff != quantized_cutoff ||
      entry.resonance != quantized_resonance || entry.sample_rate != sample_rate) {
    entry.cutoff = quantized_cutoff;
    entry.resonance = quantized_resonance;
    entry.sample_rate = sample_rate;
    entry.filter = calculate_filter(quantized_cutoff, quantized_resonance, sample_rate);
    entry.valid = true;
  }
  return entry.filter;
}

ControlMathValidation validate_control_math_approximations() {
  ControlMathValidation result;
  for (int quarter_cent = -96000; quarter_cent <= 96000; ++quarter_cent) {
    const double cents = double(quarter_cent) * 0.25;
    const double exact = std::pow(2.0, cents / 1200.0);
    const double approximate = mcu_sf2_pitch_ratio(
        int64_t(std::llround(cents * kMcuModulationOne)));
    result.max_pitch_ratio_error = std::max(
        result.max_pitch_ratio_error, std::abs(exact - approximate));
    const uint32_t exact_phase = uint32_t(std::round(256.0 * exact));
    const uint32_t approximate_phase = uint32_t(std::round(256.0 * approximate));
    result.max_phase_increment_error = std::max(
        result.max_phase_increment_error,
        exact_phase > approximate_phase ? exact_phase - approximate_phase
                                        : approximate_phase - exact_phase);
  }
  for (int eighth_cb = -16000; eighth_cb <= 32000; ++eighth_cb) {
    const double cb = double(eighth_cb) * 0.125;
    const double exact = std::pow(10.0, -cb / 200.0);
    result.max_attenuation_gain_error = std::max(
        result.max_attenuation_gain_error,
        std::abs(exact - attenuation_gain(cb)) / exact);
  }
  for (int sample_rate : {44100, 48000, 96000}) {
    for (int cutoff = 1500; cutoff <= 13500; cutoff += 7) {
      for (int resonance = 0; resonance <= 960; resonance += 13) {
        const FilterConfig exact = calculate_filter(cutoff, resonance, sample_rate);
        const FilterConfig approximate = calculate_filter(
            cutoff, ((resonance + 1) / 2) * 2, sample_rate);
        const int differences[] = {
            std::abs(exact.b0 - approximate.b0), std::abs(exact.b1 - approximate.b1),
            std::abs(exact.b2 - approximate.b2), std::abs(exact.a1 - approximate.a1),
            std::abs(exact.a2 - approximate.a2)};
        for (int difference : differences) {
          result.max_filter_coefficient_error = std::max(
              result.max_filter_coefficient_error, uint32_t(difference));
        }
      }
    }
  }
  return result;
}

}  // namespace render
