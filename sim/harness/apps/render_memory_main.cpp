#include "midi_parser.h"
#include "render_interrupt.h"
#include "render_support.h"
#include "rtl_harness.h"
#include "sf2_loader.h"

#include <verilated.h>

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <stdexcept>

namespace render {
namespace {

void write_memory_stats(const std::string& path, const MemoryStats& stats,
                        const RenderDiagnostics& diagnostics) {
  std::ofstream f(path);
  if (!f) throw std::runtime_error("failed to open " + path);
  double avg_latency = stats.responses == 0 ? 0.0 : (double(stats.response_latency_sum) / double(stats.responses));
  f << "{\n"
    << "  \"profile\": \"" << stats.profile << "\",\n"
    << "  \"line_words\": " << stats.line_words << ",\n"
    << "  \"random_latency_cycles\": " << stats.random_latency_cycles << ",\n"
    << "  \"sequential_latency_cycles\": " << stats.sequential_latency_cycles << ",\n"
    << "  \"ready_gap_cycles\": " << stats.ready_gap_cycles << ",\n"
    << "  \"external_line_requests\": " << stats.external_line_requests << ",\n"
    << "  \"sequential_line_requests\": " << stats.sequential_line_requests << ",\n"
    << "  \"responses\": " << stats.responses << ",\n"
    << "  \"avg_response_latency_cycles\": " << avg_latency << ",\n"
    << "  \"max_response_latency_cycles\": " << stats.response_latency_max << ",\n"
    << "  \"register_writes_total\": " << stats.register_writes.total << ",\n"
    << "  \"register_writes_envelope\": " << stats.register_writes.envelope << ",\n"
    << "  \"register_writes_gain_runtime\": " << stats.register_writes.gain_runtime << ",\n"
    << "  \"register_writes_phase_inc_runtime\": " << stats.register_writes.phase_inc_runtime << ",\n"
    << "  \"register_writes_filter\": " << stats.register_writes.filter << ",\n"
    << "  \"register_writes_commit\": " << stats.register_writes.commit << ",\n"
    << "  \"register_writes_release\": " << stats.register_writes.release << ",\n"
    << "  \"register_writes_config\": " << stats.register_writes.config << ",\n"
    << diagnostics_json_fields(diagnostics) << "\n"
    << "}\n";
}

}  // namespace
}  // namespace render

int main(int argc, char** argv) {
  try {
    render::install_interrupt_handler();
    Verilated::commandArgs(argc, argv);
    render::Args args = render::parse_args(argc, argv);
    int sample_count = std::max(1, int(std::round(args.seconds * args.sample_rate)));
    int adsr_tick_samples = render::envelope_tick_samples(args);

    render::Sf2Data sf2 = render::load_sf2(args.sf2);
    std::vector<render::NoteEvent> events = args.midi.empty() ? render::default_melody()
                                                              : render::parse_midi(args.midi);
    std::vector<int16_t> wave_memory = sf2.file_words;
    std::vector<render::Region> regions;
    render::prepare_events_and_regions(args, sf2, sample_count, adsr_tick_samples, events, regions, wave_memory);

    std::string wav_path = args.out_dir + "/out.wav";
    render::write_summary(args.out_dir + "/midi_render_config.json", regions, args.sample_rate,
                          sample_count, int(events.size()),
                          "  \"render_target\": \"render-memory\""
                          ",\n  \"rtl_top\": \"wavetable_cached_render_core\""
                          ",\n" + render::render_input_json_fields(args, adsr_tick_samples));

    render::MemoryProfile memory_profile = render::parse_memory_profile(args.memory_profile);
    render::RtlHarness rtl(wave_memory, wav_path, args.sample_rate, memory_profile);
    rtl.reset();
    render::RenderDiagnostics diagnostics;
    render::McuModel mcu(rtl, regions, &diagnostics);

    size_t event_index = 0;
    int next_adsr_sample = 0;
    int produced = 0;
    for (; produced < sample_count && !render::interrupt_requested(); ++produced) {
      while (event_index < events.size() && events[event_index].sample <= produced) {
        mcu.handle_event(events[event_index++]);
      }
      while (produced >= next_adsr_sample) {
        mcu.envelope_tick();
        next_adsr_sample += adsr_tick_samples;
      }
      rtl.request_sample(produced);
    }

    if (!render::interrupt_requested() && rtl.nonzero_output_words() == 0) {
      throw std::runtime_error("render produced all-zero PCM; increase SECONDS if the MIDI starts later, or inspect event/region mapping");
    }

    render::MemoryStats stats = rtl.memory_stats();
    if (render::interrupt_requested()) {
      std::cout << "INTERRUPTED: C++ harness rendered " << produced << " of "
                << sample_count << " MIDI-driven stereo samples to " << wav_path << "\n";
      render::write_memory_stats(args.out_dir + "/memory_stats.json", stats, diagnostics);
      rtl.print_memory_stats();
      return 130;
    }

    std::cout << "PASS: C++ harness rendered " << sample_count << " MIDI-driven stereo samples to " << wav_path << "\n";
    std::cout << "regions=" << regions.size() << " wave_words=" << wave_memory.size() << " events=" << events.size()
              << " nonzero_output_words=" << rtl.nonzero_output_words()
              << " register_writes=" << stats.register_writes.total
              << " filter_writes=" << stats.register_writes.filter << "\n";
    render::write_memory_stats(args.out_dir + "/memory_stats.json", stats, diagnostics);
    rtl.print_memory_stats();
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-memory failed: " << e.what() << "\n";
    return 1;
  }
}
