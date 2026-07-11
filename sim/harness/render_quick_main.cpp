#include "midi_parser.h"
#include "quick_rtl_harness.h"
#include "reference_synth.h"
#include "render_support.h"
#include "sf2_loader.h"

#include <verilated.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>

namespace render {
namespace {

class FanoutSink : public VoiceControlSink {
 public:
  FanoutSink(VoiceControlSink& a, VoiceControlSink& b) : a_(a), b_(b) {}

  void set_envelope(int voice, int level) override {
    a_.set_envelope(voice, level);
    b_.set_envelope(voice, level);
  }

  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override {
    a_.commit_voice(voice, enable, phase_inc, region);
    b_.commit_voice(voice, enable, phase_inc, region);
  }

  void release_voice(int voice, const Region& region) override {
    a_.release_voice(voice, region);
    b_.release_voice(voice, region);
  }

 private:
  VoiceControlSink& a_;
  VoiceControlSink& b_;
};

int abs_diff(int16_t a, int16_t b) {
  return std::abs(int(a) - int(b));
}

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
    render::write_summary(args.out_dir + "/quick_render_config.json", regions, args.sample_rate,
                          sample_count, int(events.size()));

    render::ReferenceSynth reference(wave_memory);
    render::QuickRtlHarness rtl(wave_memory);
    rtl.reset();
    render::FanoutSink control(reference, rtl);
    render::McuModel mcu(control, regions);

    size_t event_index = 0;
    int next_adsr_sample = 0;
    int mismatches = 0;
    int max_diff_l = 0;
    int max_diff_r = 0;
    int nonzero_words = 0;

    for (int produced = 0; produced < sample_count; ++produced) {
      while (event_index < events.size() && events[event_index].sample <= produced) {
        mcu.handle_event(events[event_index++]);
      }
      while (produced >= next_adsr_sample) {
        mcu.envelope_tick();
        next_adsr_sample += adsr_tick_samples;
      }

      auto ref = reference.render_sample();
      auto got = rtl.request_sample(produced);
      if (got.first != 0) ++nonzero_words;
      if (got.second != 0) ++nonzero_words;

      if (got != ref) {
        ++mismatches;
        max_diff_l = std::max(max_diff_l, render::abs_diff(got.first, ref.first));
        max_diff_r = std::max(max_diff_r, render::abs_diff(got.second, ref.second));
        if (mismatches <= 10) {
          std::cerr << "sample " << produced << " mismatch: RTL L=" << got.first
                    << " R=" << got.second << " reference L=" << ref.first
                    << " R=" << ref.second << "\n";
        }
      }
    }

    if (nonzero_words == 0) {
      throw std::runtime_error("quick render produced all-zero RTL PCM; increase SECONDS or inspect event/region mapping");
    }
    if (mismatches != 0) {
      throw std::runtime_error("quick render found " + std::to_string(mismatches) +
                               " RTL/reference mismatches, max_diff_l=" + std::to_string(max_diff_l) +
                               " max_diff_r=" + std::to_string(max_diff_r));
    }

    std::cout << "PASS: quick RTL/reference render matched " << sample_count
              << " stereo samples, regions=" << regions.size()
              << " wave_words=" << wave_memory.size()
              << " events=" << events.size()
              << " nonzero_output_words=" << nonzero_words << "\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-quick failed: " << e.what() << "\n";
    return 1;
  }
}
