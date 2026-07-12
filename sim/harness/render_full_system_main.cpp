#include "full_system_harness.h"
#include "midi_parser.h"
#include "render_support.h"
#include "sf2_loader.h"

#include <verilated.h>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace render {
namespace {

void write_full_system_stats(const std::string& path, const FullSystemStats& stats) {
  std::ofstream f(path);
  if (!f) throw std::runtime_error("failed to open " + path);
  f << "{\n"
    << "  \"frames\": " << stats.frames << ",\n"
    << "  \"nonzero_output_words\": " << stats.nonzero_output_words << ",\n"
    << "  \"underruns\": " << stats.underruns << ",\n"
    << "  \"sample_drops\": " << stats.sample_drops << ",\n"
    << "  \"render_deadline_misses\": " << stats.render_deadline_misses << ",\n"
    << "  \"max_render_latency_cycles\": " << stats.max_render_latency_cycles << ",\n"
    << "  \"memory_hits\": " << stats.memory_hits << ",\n"
    << "  \"memory_misses\": " << stats.memory_misses << ",\n"
    << "  \"memory_responses\": " << stats.memory_responses << ",\n"
    << "  \"external_line_requests\": " << stats.external_line_requests << ",\n"
    << "  \"sequential_line_requests\": " << stats.sequential_line_requests << "\n"
    << "}\n";
}

}  // namespace
}  // namespace render

int main(int argc, char** argv) {
  try {
    Verilated::commandArgs(argc, argv);
    render::Args args = render::parse_args(argc, argv);
    if (args.sample_rate != 48000) {
      throw std::runtime_error("render-full-system currently requires --sample-rate 48000 because wavetable_core_system uses a fixed 49.152 MHz / 48 kHz audio clock");
    }
    int sample_count = std::max(1, int(std::round(args.seconds * args.sample_rate)));
    int adsr_tick_samples = std::max(1, int(std::round(args.adsr_tick_ms * args.sample_rate / 1000.0)));

    render::Sf2Data sf2 = render::load_sf2(args.sf2);
    std::vector<render::NoteEvent> events = args.midi.empty() ? render::default_melody()
                                                              : render::parse_midi(args.midi);
    std::vector<int16_t> wave_memory;
    std::vector<render::Region> regions;
    render::prepare_events_and_regions(args, sf2, sample_count, adsr_tick_samples, events, regions, wave_memory);
    render::write_summary(args.out_dir + "/full_system_render_config.json", regions, args.sample_rate,
                          sample_count, int(events.size()));

    std::string wav_path = args.out_dir + "/out.wav";
    render::FullSystemHarness full_system(wave_memory, wav_path, args.sample_rate);
    full_system.reset();
    render::McuModel mcu(full_system, regions);

    size_t event_index = 0;
    int next_adsr_sample = 0;
    while (full_system.frames() < uint64_t(sample_count)) {
      uint64_t frame = full_system.frames();
      while (event_index < events.size() && uint64_t(events[event_index].sample) <= frame) {
        mcu.handle_event(events[event_index++]);
      }
      while (frame >= uint64_t(next_adsr_sample)) {
        mcu.envelope_tick();
        next_adsr_sample += adsr_tick_samples;
      }
      full_system.run_until_frames(frame + 1);
    }

    render::FullSystemStats stats = full_system.stats();
    render::write_full_system_stats(args.out_dir + "/full_system_stats.json", stats);
    if (stats.nonzero_output_words == 0) {
      throw std::runtime_error("full-system render produced all-zero I2S PCM; increase SECONDS or inspect event/region mapping");
    }

    std::cout << "PASS: full-system harness captured " << stats.frames
              << " I2S stereo frames to " << wav_path << "\n";
    std::cout << "regions=" << regions.size() << " wave_words=" << wave_memory.size()
              << " events=" << events.size()
              << " nonzero_output_words=" << stats.nonzero_output_words
              << " underruns=" << stats.underruns
              << " sample_drops=" << stats.sample_drops
              << " render_deadline_misses=" << stats.render_deadline_misses
              << " max_render_latency_cycles=" << stats.max_render_latency_cycles
              << " memory_hits=" << stats.memory_hits
              << " memory_misses=" << stats.memory_misses << "\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-full-system failed: " << e.what() << "\n";
    return 1;
  }
}
