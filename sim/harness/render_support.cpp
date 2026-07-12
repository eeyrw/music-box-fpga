#include "render_support.h"

#include "midi_parser.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <map>
#include <stdexcept>

namespace render {
namespace {

constexpr int kMidiDrumChannel = 9;
constexpr int kSf2PercussionBank = 128;

bool is_no_matching_zone_error(const std::runtime_error& e) {
  return std::string(e.what()) == "no SF2 zone matches key/velocity";
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
                   int sample_rate, int samples, int events) {
  std::ofstream f(path);
  if (!f) throw std::runtime_error("failed to open " + path);
  f << "{\n  \"output_sample_rate\": " << sample_rate
    << ",\n  \"output_samples\": " << samples
    << ",\n  \"event_count\": " << events << ",\n  \"regions\": [\n";
  for (size_t i = 0; i < regions.size(); ++i) {
    const auto& r = regions[i];
    f << "    {\"key\": " << r.key << ", \"program\": " << r.program
      << ", \"bank\": " << r.bank << ", \"preset\": \"" << r.preset
      << "\", \"instrument\": \"" << r.instrument << "\", \"sample_left\": \""
      << r.sample_left << "\", \"stereo\": " << (r.stereo ? "true" : "false")
      << ", \"base_addr\": " << r.base_addr << ", \"length\": " << r.length
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
    if (a.on != b.on) return !a.on;
    return a.note < b.note;
  });

  std::map<std::array<int, 4>, std::vector<int>> region_by_key;
  int forced_inst = args.instrument.empty() ? -1 : select_instrument(sf2, args.instrument);
  std::vector<NoteEvent> expanded_events;
  int playable_note_ons = 0;

  for (auto& e : events) {
    if (!e.on) {
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

  if (std::none_of(wave_memory.begin(), wave_memory.end(), [](int16_t v) { return v != 0; })) {
    throw std::runtime_error("selected SF2 regions produced an all-zero wave memory image");
  }

  for (auto& e : events) {
    e.sample = std::max(0, std::min(sample_count, int(std::round(e.time_seconds * args.sample_rate))));
  }
  std::sort(events.begin(), events.end(), [](const NoteEvent& a, const NoteEvent& b) {
    if (a.sample != b.sample) return a.sample < b.sample;
    if (a.on != b.on) return !a.on;
    return a.note < b.note;
  });
}

McuModel::McuModel(VoiceControlSink& sink, const std::vector<Region>& regions)
    : sink_(sink), regions_(regions) {}

void McuModel::handle_event(const NoteEvent& event) {
  if (event.on) note_on(event);
  else note_off(event.channel, event.note);
}

void McuModel::envelope_tick() {
  for (int v = 0; v < kNumVoices; ++v) {
    int next = voices_[v].level;
    if (voices_[v].state == ENV_DELAY) {
      if (voices_[v].ticks_remaining > 0) --voices_[v].ticks_remaining;
      if (voices_[v].ticks_remaining == 0) voices_[v].state = ENV_ATTACK;
    } else if (voices_[v].state == ENV_ATTACK) {
      next = voices_[v].level + regions_.at(voices_[v].region).attack_step;
      if (next >= voices_[v].target) {
        next = voices_[v].target;
        voices_[v].ticks_remaining = regions_.at(voices_[v].region).hold_ticks;
        voices_[v].state = voices_[v].ticks_remaining > 0 ? ENV_HOLD : ENV_DECAY;
      }
    } else if (voices_[v].state == ENV_HOLD) {
      if (voices_[v].ticks_remaining > 0) --voices_[v].ticks_remaining;
      if (voices_[v].ticks_remaining == 0) voices_[v].state = ENV_DECAY;
    } else if (voices_[v].state == ENV_DECAY) {
      next = voices_[v].level - regions_.at(voices_[v].region).decay_step;
      if (next <= voices_[v].sustain) {
        next = voices_[v].sustain;
        voices_[v].state = ENV_SUSTAIN;
      }
    } else if (voices_[v].state == ENV_RELEASE) {
      next = voices_[v].level - regions_.at(voices_[v].region).release_step;
      if (next <= 0) {
        next = 0;
        voices_[v].state = ENV_SILENT;
        sink_.commit_voice(v, 0, 0, regions_.front());
      }
    }

    if (voices_[v].state != ENV_SILENT || voices_[v].level != 0) {
      voices_[v].level = clamp_q15(next);
      sink_.set_envelope(v, voices_[v].level);
    }
  }
}

void McuModel::note_off(int channel, int note) {
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel && voices_[v].note == (note & 0x7f)) {
      voices_[v].state = ENV_RELEASE;
      sink_.release_voice(v, regions_.at(voices_[v].region));
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
        voices_[v].state = ENV_RELEASE;
        sink_.release_voice(v, regions_.at(voices_[v].region));
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

  sink_.set_envelope(slot, 0);
  sink_.commit_voice(slot, 1, event.phase_inc, r);
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

}  // namespace render
