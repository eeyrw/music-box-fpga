#include "render_support.h"

#include "midi_parser.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <limits>
#include <map>
#include <stdexcept>

namespace render {
namespace {

constexpr int kMidiDrumChannel = 9;
constexpr int kSf2PercussionBank = 128;

bool is_no_matching_zone_error(const std::runtime_error& e) {
  return std::string(e.what()) == "no SF2 zone matches key/velocity";
}

int event_priority(const NoteEvent& e) {
  if (e.type != NoteEvent::EVENT_NOTE) return 0;
  return e.on ? 2 : 1;
}

int curved_attack(int target, int tick, int ticks) {
  double x = double(std::max(1, tick)) / double(std::max(1, ticks));
  return clamp_q15(int(std::round(double(target) * x * x)));
}

int curved_decay(int start, int target, int tick, int ticks) {
  double x = double(std::max(1, tick)) / double(std::max(1, ticks));
  double remain = (1.0 - x) * (1.0 - x);
  return clamp_q15(int(std::round(double(target) + double(start - target) * remain)));
}

int curved_release(int start, int tick, int ticks) {
  double x = double(std::max(1, tick)) / double(std::max(1, ticks));
  double remain = (1.0 - x) * (1.0 - x);
  return clamp_q15(int(std::round(double(start) * remain)));
}

}  // namespace

Args parse_args(int argc, char** argv) {
  Args args;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto need = [&](const char* name) -> std::string {
      if (i + 1 >= argc) throw std::runtime_error(std::string("missing value for ") + name);
      return argv[++i];
    };
    if (a == "--sf2") args.sf2 = need("--sf2");
    else if (a == "--midi") args.midi = need("--midi");
    else if (a == "--instrument") args.instrument = need("--instrument");
    else if (a == "--key") args.key = std::stoi(need("--key"));
    else if (a == "--seconds") args.seconds = std::stod(need("--seconds"));
    else if (a == "--sample-rate") args.sample_rate = std::stoi(need("--sample-rate"));
    else if (a == "--adsr-tick-ms") args.adsr_tick_ms = std::stod(need("--adsr-tick-ms"));
    else if (a == "--memory-profile") args.memory_profile = need("--memory-profile");
    else if (a == "--out-dir") args.out_dir = need("--out-dir");
    else throw std::runtime_error("unknown argument: " + a);
  }
  return args;
}

void write_summary(const std::string& path, const std::vector<Region>& regions,
                   int sample_rate, int samples, int events,
                   const std::string& extra_fields) {
  std::ofstream f(path);
  if (!f) throw std::runtime_error("failed to open " + path);
  f << "{\n  \"output_sample_rate\": " << sample_rate
    << ",\n  \"output_samples\": " << samples
    << ",\n  \"event_count\": " << events;
  if (!extra_fields.empty()) f << ",\n" << extra_fields;
  f << ",\n  \"regions\": [\n";
  for (size_t i = 0; i < regions.size(); ++i) {
    const auto& r = regions[i];
    f << "    {\"key\": " << r.key << ", \"program\": " << r.program
      << ", \"bank\": " << r.bank << ", \"preset\": \"" << r.preset
      << "\", \"instrument\": \"" << r.instrument << "\", \"sample_left\": \""
      << r.sample_left << "\", \"stereo\": " << (r.stereo ? "true" : "false")
      << ", \"base_addr\": " << r.base_addr
      << ", \"base_addr_r\": " << r.base_addr_r << ", \"length\": " << r.length
      << ", \"loop_start\": " << r.loop_start << ", \"loop_end\": " << r.loop_end
      << ", \"phase_inc\": " << r.phase_inc
      << ", \"filter_enable\": " << (r.filter_enable ? "true" : "false")
      << ", \"filter_b0\": " << r.filter_b0
      << ", \"filter_b1\": " << r.filter_b1
      << ", \"filter_b2\": " << r.filter_b2
      << ", \"filter_a1\": " << r.filter_a1
      << ", \"filter_a2\": " << r.filter_a2 << "}"
      << (i + 1 < regions.size() ? "," : "") << "\n";
  }
  f << "  ]\n}\n";
}

void prepare_events_and_regions(const Args& args, const Sf2Data& sf2, int sample_count,
                                int adsr_tick_samples, std::vector<NoteEvent>& events,
                                std::vector<Region>& regions,
                                std::vector<int16_t>& wave_memory) {
  double render_seconds = double(sample_count) / double(args.sample_rate);
  events.erase(std::remove_if(events.begin(), events.end(), [&](const NoteEvent& e) {
                 return e.time_seconds >= render_seconds;
               }), events.end());
  if (events.empty()) throw std::runtime_error("no MIDI events fall inside the requested render window");

  std::sort(events.begin(), events.end(), [](const NoteEvent& a, const NoteEvent& b) {
    if (a.time_seconds != b.time_seconds) return a.time_seconds < b.time_seconds;
    if (event_priority(a) != event_priority(b)) return event_priority(a) < event_priority(b);
    if (a.on != b.on) return !a.on;
    return a.note < b.note;
  });

  std::map<std::array<int, 4>, std::vector<int>> region_by_key;
  int forced_inst = args.instrument.empty() ? -1 : select_instrument(sf2, args.instrument);
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
      std::vector<Region> made;
      try {
        made = forced_inst >= 0
          ? make_regions_for_instrument(sf2, forced_inst, key, velocity, args.sample_rate, adsr_tick_samples, wave_memory)
          : make_regions_for_preset(sf2, program, bank, key, velocity, args.sample_rate, adsr_tick_samples, wave_memory);
      } catch (const std::runtime_error& ex) {
        if (!is_no_matching_zone_error(ex)) throw;
      }
      std::vector<int> indices;
      for (auto& r : made) {
        indices.push_back(int(regions.size()));
        regions.push_back(r);
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
    uint32_t last_r = r.base_addr_r + (r.length ? r.length - 1 : 0);
    if (r.length != 0 && (last_l >= wave_memory.size() || (r.stereo && last_r >= wave_memory.size()))) {
      throw std::runtime_error("selected SF2 region points outside the wave memory image");
    }
  }

  for (auto& e : events) {
    e.sample = std::max(0, std::min(sample_count, int(std::round(e.time_seconds * args.sample_rate))));
  }
  std::sort(events.begin(), events.end(), [](const NoteEvent& a, const NoteEvent& b) {
    if (a.sample != b.sample) return a.sample < b.sample;
    if (event_priority(a) != event_priority(b)) return event_priority(a) < event_priority(b);
    if (a.on != b.on) return !a.on;
    return a.note < b.note;
  });
}

McuModel::McuModel(VoiceControlSink& sink, const std::vector<Region>& regions)
    : sink_(sink), regions_(regions) {}

void McuModel::handle_event(const NoteEvent& event) {
  if (event.type == NoteEvent::EVENT_CONTROL) control_change(event);
  else if (event.type == NoteEvent::EVENT_PITCH_BEND) pitch_bend(event);
  else if (event.type == NoteEvent::EVENT_NOTE && event.on) note_on(event);
  else if (event.type == NoteEvent::EVENT_NOTE) note_off(event.channel, event.note);
}

void McuModel::envelope_tick() {
  for (int v = 0; v < kNumVoices; ++v) {
    int next = voices_[v].level;
    if (voices_[v].state == ENV_DELAY) {
      if (voices_[v].ticks_remaining > 0) --voices_[v].ticks_remaining;
      if (voices_[v].ticks_remaining == 0) voices_[v].state = ENV_ATTACK;
    } else if (voices_[v].state == ENV_ATTACK) {
      const Region& r = regions_.at(voices_[v].region);
      voices_[v].env_stage_tick += 1;
      next = curved_attack(voices_[v].target, voices_[v].env_stage_tick, r.attack_ticks);
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
      next = curved_decay(voices_[v].target, voices_[v].sustain, voices_[v].env_stage_tick, r.decay_ticks);
      if (voices_[v].env_stage_tick >= r.decay_ticks) {
        next = voices_[v].sustain;
        voices_[v].env_stage_tick = 0;
        voices_[v].state = ENV_SUSTAIN;
      }
    } else if (voices_[v].state == ENV_RELEASE) {
      const Region& r = regions_.at(voices_[v].region);
      voices_[v].env_stage_tick += 1;
      next = curved_release(voices_[v].release_start, voices_[v].env_stage_tick, r.release_ticks);
      if (voices_[v].env_stage_tick >= r.release_ticks) {
        next = 0;
        voices_[v].state = ENV_SILENT;
        voices_[v].sustain_held = false;
        voices_[v].mod_env_state = ENV_SILENT;
        sink_.commit_voice(v, 0, 0, regions_.front());
      }
    }

    if (voices_[v].state != ENV_SILENT || voices_[v].level != 0) {
      voices_[v].level = clamp_q15(next);
      sink_.set_envelope(v, voices_[v].level);
      update_voice_modulation(v);
    }
  }
}

void McuModel::control_change(const NoteEvent& event) {
  int channel = event.channel & 0x0f;
  int value = std::max(0, std::min(127, event.value));
  switch (event.controller & 0x7f) {
    case 7:
      channels_[channel].volume = value;
      update_channel_controls(channel);
      break;
    case 10:
      channels_[channel].pan = value;
      update_channel_controls(channel);
      break;
    case 11:
      channels_[channel].expression = value;
      update_channel_controls(channel);
      break;
    case 64:
      if (value >= 64) {
        channels_[channel].sustain = true;
      } else {
        channels_[channel].sustain = false;
        for (int v = 0; v < kNumVoices; ++v) {
          if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel && voices_[v].sustain_held) {
            voices_[v].sustain_held = false;
            release_voice(v);
          }
        }
      }
      break;
    case 120:
      for (int v = 0; v < kNumVoices; ++v) {
        if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel) {
          voices_[v].state = ENV_SILENT;
          voices_[v].level = 0;
          voices_[v].sustain_held = false;
          voices_[v].mod_env_state = ENV_SILENT;
          sink_.set_envelope(v, 0);
          sink_.commit_voice(v, 0, 0, regions_.front());
        }
      }
      break;
    case 123:
      for (int v = 0; v < kNumVoices; ++v) {
        if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel) release_voice(v);
      }
      break;
    default:
      break;
  }
}

void McuModel::pitch_bend(const NoteEvent& event) {
  int channel = event.channel & 0x0f;
  channels_[channel].pitch_bend = std::max(-8192, std::min(8191, event.pitch_bend));
  update_channel_controls(channel);
}

void McuModel::update_channel_controls(int channel) {
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel) update_voice_controls(v);
  }
}

void McuModel::update_voice_controls(int voice) {
  const VoiceState& state = voices_.at(voice);
  const Region& r = regions_.at(state.region);
  const ChannelState& c = channels_.at(state.channel & 0x0f);
  sink_.set_gain(voice, scale_gain(r.gain_l, c.volume, c.expression, c.pan, false),
                 scale_gain(r.gain_r, c.volume, c.expression, c.pan, true));
  update_voice_modulation(voice);
}

void McuModel::update_voice_modulation(int voice) {
  VoiceState& state = voices_.at(voice);
  if (state.state == ENV_SILENT) return;
  const Region& r = regions_.at(state.region);
  const ChannelState& c = channels_.at(state.channel & 0x0f);

  if (state.mod_lfo_wait_ticks > 0) --state.mod_lfo_wait_ticks;
  else state.mod_lfo_phase += r.mod_lfo_step;
  if (state.vib_lfo_wait_ticks > 0) --state.vib_lfo_wait_ticks;
  else state.vib_lfo_phase += r.vib_lfo_step;

  int mod_next = state.mod_env_level;
  if (state.mod_env_state == ENV_DELAY) {
    if (state.mod_env_ticks_remaining > 0) --state.mod_env_ticks_remaining;
    if (state.mod_env_ticks_remaining == 0) state.mod_env_state = ENV_ATTACK;
  } else if (state.mod_env_state == ENV_ATTACK) {
    state.mod_env_stage_tick += 1;
    mod_next = curved_attack(kQ15Full, state.mod_env_stage_tick, r.mod_env_attack_ticks);
    if (state.mod_env_stage_tick >= r.mod_env_attack_ticks) {
      mod_next = kQ15Full;
      state.mod_env_ticks_remaining = r.mod_env_hold_ticks;
      state.mod_env_stage_tick = 0;
      state.mod_env_state = state.mod_env_ticks_remaining > 0 ? ENV_HOLD : ENV_DECAY;
    }
  } else if (state.mod_env_state == ENV_HOLD) {
    if (state.mod_env_ticks_remaining > 0) --state.mod_env_ticks_remaining;
    if (state.mod_env_ticks_remaining == 0) state.mod_env_state = ENV_DECAY;
  } else if (state.mod_env_state == ENV_DECAY) {
    state.mod_env_stage_tick += 1;
    mod_next = curved_decay(kQ15Full, r.mod_env_sustain_level, state.mod_env_stage_tick, r.mod_env_decay_ticks);
    if (state.mod_env_stage_tick >= r.mod_env_decay_ticks) {
      mod_next = r.mod_env_sustain_level;
      state.mod_env_stage_tick = 0;
      state.mod_env_state = ENV_SUSTAIN;
    }
  } else if (state.mod_env_state == ENV_RELEASE) {
    state.mod_env_stage_tick += 1;
    mod_next = curved_release(state.mod_env_release_start, state.mod_env_stage_tick, r.mod_env_release_ticks);
    if (state.mod_env_stage_tick >= r.mod_env_release_ticks) {
      mod_next = 0;
      state.mod_env_state = ENV_SILENT;
    }
  }
  state.mod_env_level = clamp_q15(mod_next);

  auto lfo_value = [](uint32_t phase) {
    return std::sin((double(phase & 0xffffu) / 65536.0) * 2.0 * 3.14159265358979323846);
  };
  double mod_lfo = state.mod_lfo_wait_ticks > 0 ? 0.0 : lfo_value(state.mod_lfo_phase);
  double vib_lfo = state.vib_lfo_wait_ticks > 0 ? 0.0 : lfo_value(state.vib_lfo_phase);
  double env = double(state.mod_env_level) / double(kQ15Full);

  double pitch_cents = 200.0 * double(std::max(-8192, std::min(8191, c.pitch_bend))) / 8192.0;
  pitch_cents += mod_lfo * double(r.mod_lfo_to_pitch);
  pitch_cents += vib_lfo * double(r.vib_lfo_to_pitch);
  pitch_cents += env * double(r.mod_env_to_pitch);
  sink_.set_phase_inc(voice, modulated_phase_inc(r.phase_inc, pitch_cents));

  double filter_cents = double(r.initial_filter_fc) + mod_lfo * double(r.mod_lfo_to_filter_fc) +
                        env * double(r.mod_env_to_filter_fc);
  sink_.set_filter(voice, filter_for(int(std::round(filter_cents)), r.initial_filter_q, r.output_sample_rate));
}

void McuModel::release_voice(int voice) {
  voices_[voice].state = ENV_RELEASE;
  voices_[voice].env_stage_tick = 0;
  voices_[voice].release_start = voices_[voice].level;
  voices_[voice].mod_env_state = ENV_RELEASE;
  voices_[voice].mod_env_stage_tick = 0;
  voices_[voice].mod_env_release_start = voices_[voice].mod_env_level;
  voices_[voice].sustain_held = false;
  sink_.release_voice(voice, regions_.at(voices_[voice].region));
}

void McuModel::note_off(int channel, int note) {
  channel &= 0x0f;
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel && voices_[v].note == (note & 0x7f)) {
      if (channels_[channel].sustain) voices_[v].sustain_held = true;
      else release_voice(v);
    }
  }
}

void McuModel::note_on(const NoteEvent& event) {
  if (event.velocity == 0) {
    note_off(event.channel, event.note);
    return;
  }

  int slot = first_free_or_oldest_slot();
  alloc_stamp_ = (alloc_stamp_ + 1) & 0xff;
  if (alloc_stamp_ == 0) alloc_stamp_ = 1;

  const Region& r = regions_.at(event.region);
  if (r.exclusive_class > 0) {
    for (int v = 0; v < kNumVoices; ++v) {
      if (voices_[v].state != ENV_SILENT && voices_[v].channel == event.channel &&
          regions_.at(voices_[v].region).exclusive_class == r.exclusive_class) {
        release_voice(v);
      }
    }
  }
  voices_[slot].note = event.note & 0x7f;
  voices_[slot].channel = event.channel;
  voices_[slot].region = event.region;
  voices_[slot].state = r.delay_ticks > 0 ? ENV_DELAY : ENV_ATTACK;
  voices_[slot].level = 0;
  voices_[slot].target = velocity_target(r.effective_velocity >= 0 ? r.effective_velocity : event.velocity);
  voices_[slot].sustain = (voices_[slot].target * r.sustain_level) / kQ15Full;
  voices_[slot].stamp = alloc_stamp_;
  voices_[slot].ticks_remaining = r.delay_ticks;
  voices_[slot].env_stage_tick = 0;
  voices_[slot].release_start = 0;
  voices_[slot].sustain_held = false;
  voices_[slot].mod_lfo_phase = 0;
  voices_[slot].vib_lfo_phase = 0;
  voices_[slot].mod_lfo_wait_ticks = r.mod_lfo_delay_ticks;
  voices_[slot].vib_lfo_wait_ticks = r.vib_lfo_delay_ticks;
  voices_[slot].mod_env_state = r.mod_env_delay_ticks > 0 ? ENV_DELAY : ENV_ATTACK;
  voices_[slot].mod_env_level = 0;
  voices_[slot].mod_env_ticks_remaining = r.mod_env_delay_ticks;
  voices_[slot].mod_env_stage_tick = 0;
  voices_[slot].mod_env_release_start = 0;

  sink_.set_envelope(slot, 0);
  uint32_t phase_inc = bend_phase_inc(event.phase_inc, channels_[event.channel & 0x0f].pitch_bend);
  sink_.commit_voice(slot, 1, phase_inc, r);
  update_voice_controls(slot);
}

int McuModel::first_free_or_oldest_slot() const {
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state == ENV_SILENT) return v;
  }
  int best = 0;
  for (int v = 1; v < kNumVoices; ++v) {
    if (((voices_[v].stamp - voices_[best].stamp) & 0xff) >= 128) best = v;
  }
  return best;
}

int McuModel::scale_gain(int gain, int volume, int expression, int pan, bool right) {
  double level = double(std::max(0, std::min(127, volume))) / 127.0;
  level *= double(std::max(0, std::min(127, expression))) / 127.0;
  int p = std::max(0, std::min(127, pan));
  double pan_scale = right ? (p >= 64 ? 1.0 : double(p) / 64.0)
                           : (p <= 64 ? 1.0 : double(127 - p) / 63.0);
  return clamp_q15(int(std::round(double(gain) * level * pan_scale)));
}

uint32_t McuModel::bend_phase_inc(uint32_t base_phase_inc, int bend) {
  double cents = 200.0 * double(std::max(-8192, std::min(8191, bend))) / 8192.0;
  return modulated_phase_inc(base_phase_inc, cents);
}

uint32_t McuModel::modulated_phase_inc(uint32_t base_phase_inc, double cents) {
  double raw = double(base_phase_inc) * std::pow(2.0, cents / 1200.0);
  if (raw < 1.0) return 1;
  if (raw > double(UINT32_MAX)) return UINT32_MAX;
  return uint32_t(std::round(raw));
}

int q4_28(double value) {
  double raw = std::round(value * 268435456.0);
  if (raw > double(std::numeric_limits<int32_t>::max())) return std::numeric_limits<int32_t>::max();
  if (raw < double(std::numeric_limits<int32_t>::min())) return std::numeric_limits<int32_t>::min();
  return int(raw);
}

FilterConfig McuModel::filter_for(int cutoff_cents, int resonance_cb, int sample_rate) {
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
  filter.b0 = q4_28(((1.0 - cos_w) * 0.5) / a0);
  filter.b1 = q4_28((1.0 - cos_w) / a0);
  filter.b2 = q4_28(((1.0 - cos_w) * 0.5) / a0);
  filter.a1 = q4_28((-2.0 * cos_w) / a0);
  filter.a2 = q4_28((1.0 - alpha) / a0);
  return filter;
}

}  // namespace render
