#include "midi_parser.h"
#include "rtl_harness.h"
#include "sf2_loader.h"

#include <verilated.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>

namespace render {
namespace {

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
      << ", \"phase_inc\": " << r.phase_inc << "}"
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

  std::map<std::array<int, 4>, int> region_by_key;
  int forced_inst = args.instrument.empty() ? -1 : select_instrument(sf2, args.instrument);

  for (auto& e : events) {
    if (!e.on) continue;
    int key = std::max(0, std::min(127, e.note));
    int velocity = std::max(1, std::min(127, e.velocity));
    int program = std::max(0, std::min(127, e.program));
    int bank = e.channel == 9 ? 0 : std::max(0, std::min(16383, e.bank));

    // Region identity includes velocity because SF2 instrument zones can be
    // velocity-split. Channel 10 percussion currently falls back to bank 0.
    std::array<int, 4> region_key = {forced_inst >= 0 ? forced_inst : program, bank, key, velocity};
    auto it = region_by_key.find(region_key);
    if (it == region_by_key.end()) {
      Region r = forced_inst >= 0
        ? make_region_for_instrument(sf2, forced_inst, key, velocity, args.sample_rate, adsr_tick_samples, wave_memory)
        : make_region_for_preset(sf2, program, bank, key, velocity, args.sample_rate, adsr_tick_samples, wave_memory);
      int idx = int(regions.size());
      regions.push_back(r);
      region_by_key[region_key] = idx;
      it = region_by_key.find(region_key);
    }
    e.region = it->second;
    e.phase_inc = regions[e.region].phase_inc;
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

class McuModel {
 public:
  McuModel(RtlHarness& rtl, const std::vector<Region>& regions) : rtl_(rtl), regions_(regions) {}

  void handle_event(const NoteEvent& event) {
    if (event.on) note_on(event);
    else note_off(event.channel, event.note);
  }

  void envelope_tick() {
    for (int v = 0; v < kNumVoices; ++v) {
      int next = voices_[v].level;
      if (voices_[v].state == ENV_ATTACK) {
        next = voices_[v].level + regions_.at(voices_[v].region).attack_step;
        if (next >= voices_[v].target) {
          next = voices_[v].target;
          voices_[v].state = ENV_DECAY;
        }
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
          rtl_.commit_voice(v, 0, 0, regions_.front());
        }
      }

      if (voices_[v].state != ENV_SILENT || voices_[v].level != 0) {
        voices_[v].level = clamp_q15(next);
        rtl_.set_envelope(v, voices_[v].level);
      }
    }
  }

 private:
  void note_off(int channel, int note) {
    for (int v = 0; v < kNumVoices; ++v) {
      if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel && voices_[v].note == (note & 0x7f)) {
        voices_[v].state = ENV_RELEASE;
        rtl_.release_voice(v, regions_.at(voices_[v].region));
      }
    }
  }

  void note_on(const NoteEvent& event) {
    if (event.velocity == 0) {
      note_off(event.channel, event.note);
      return;
    }

    int slot = first_free_or_oldest_slot();
    alloc_stamp_ = (alloc_stamp_ + 1) & 0xff;
    if (alloc_stamp_ == 0) alloc_stamp_ = 1;

    const Region& r = regions_.at(event.region);
    voices_[slot].note = event.note & 0x7f;
    voices_[slot].channel = event.channel;
    voices_[slot].region = event.region;
    voices_[slot].state = ENV_ATTACK;
    voices_[slot].level = 0;
    voices_[slot].target = velocity_target(event.velocity);
    voices_[slot].sustain = (voices_[slot].target * r.sustain_level) / kQ15Full;
    voices_[slot].stamp = alloc_stamp_;

    // Firmware-visible order: set runtime envelope first, then commit the full
    // shadow voice config so phase reload happens exactly once at Note On.
    rtl_.set_envelope(slot, 0);
    rtl_.commit_voice(slot, 1, event.phase_inc, r);
  }

  int first_free_or_oldest_slot() const {
    for (int v = 0; v < kNumVoices; ++v) {
      if (voices_[v].state == ENV_SILENT) return v;
    }
    int best = 0;
    for (int v = 1; v < kNumVoices; ++v) {
      if (((voices_[v].stamp - voices_[best].stamp) & 0xff) >= 128) best = v;
    }
    return best;
  }

  RtlHarness& rtl_;
  const std::vector<Region>& regions_;
  std::array<VoiceState, kNumVoices> voices_{};
  int alloc_stamp_ = 0;
};

}  // namespace
}  // namespace render

int main(int argc, char** argv) {
  try {
    Verilated::commandArgs(argc, argv);
    render::Args args = render::parse_args(argc, argv);
    int sample_count = std::max(1, int(std::round(args.seconds * args.sample_rate)));
    int adsr_tick_samples = std::max(1, int(std::round(args.adsr_tick_ms * args.sample_rate / 1000.0)));

    render::Sf2Data sf2 = render::load_sf2(args.sf2);
    std::vector<render::NoteEvent> events = args.midi.empty() ? render::default_melody()
                                                              : render::parse_midi(args.midi);
    std::vector<int16_t> wave_memory;
    std::vector<render::Region> regions;
    render::prepare_events_and_regions(args, sf2, sample_count, adsr_tick_samples, events, regions, wave_memory);

    std::string wav_path = args.out_dir + "/out.wav";
    render::write_summary(args.out_dir + "/midi_render_config.json", regions, args.sample_rate, sample_count, int(events.size()));

    render::RtlHarness rtl(wave_memory, wav_path, args.sample_rate);
    rtl.reset();
    render::McuModel mcu(rtl, regions);

    size_t event_index = 0;
    int next_adsr_sample = 0;
    for (int produced = 0; produced < sample_count; ++produced) {
      while (event_index < events.size() && events[event_index].sample <= produced) {
        mcu.handle_event(events[event_index++]);
      }
      while (produced >= next_adsr_sample) {
        mcu.envelope_tick();
        next_adsr_sample += adsr_tick_samples;
      }
      rtl.request_sample(produced);
    }

    if (rtl.nonzero_output_words() == 0) {
      throw std::runtime_error("render produced all-zero PCM; increase SECONDS if the MIDI starts later, or inspect event/region mapping");
    }

    std::cout << "PASS: C++ harness rendered " << sample_count << " MIDI-driven stereo samples to " << wav_path << "\n";
    std::cout << "regions=" << regions.size() << " wave_words=" << wave_memory.size() << " events=" << events.size()
              << " nonzero_output_words=" << rtl.nonzero_output_words() << "\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-midi failed: " << e.what() << "\n";
    return 1;
  }
}
