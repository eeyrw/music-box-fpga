#include "command_control.h"
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
  double avg_render_cycles = stats.render_frames == 0 ? 0.0 :
                             (double(stats.render_cycle_sum) / double(stats.render_frames));
  f << "{\n"
    << "  \"profile\": \"" << stats.profile << "\",\n"
    << "  \"line_words\": " << stats.line_words << ",\n"
    << "  \"random_latency_cycles\": " << stats.random_latency_cycles << ",\n"
    << "  \"sequential_latency_cycles\": " << stats.sequential_latency_cycles << ",\n"
    << "  \"ready_gap_cycles\": " << stats.ready_gap_cycles << ",\n"
    << "  \"external_line_requests\": " << stats.external_line_requests << ",\n"
    << "  \"sequential_line_requests\": " << stats.sequential_line_requests << ",\n"
    << "  \"responses\": " << stats.responses << ",\n"
    << "  \"cache_demand_hits\": " << stats.cache_demand_hits << ",\n"
    << "  \"cache_demand_misses\": " << stats.cache_demand_misses << ",\n"
    << "  \"cache_line_fills\": " << stats.cache_line_fills << ",\n"
    << "  \"cache_same_line_endpoint_hits\": " << stats.cache_same_line_endpoint_hits << ",\n"
    << "  \"cache_replacements\": " << stats.cache_replacements << ",\n"
    << "  \"prefetch_issued\": " << stats.prefetch_issued << ",\n"
    << "  \"prefetch_filled\": " << stats.prefetch_filled << ",\n"
    << "  \"prefetch_used\": " << stats.prefetch_used << ",\n"
    << "  \"prefetch_dropped\": " << stats.prefetch_dropped << ",\n"
    << "  \"prefetch_late\": " << stats.prefetch_late << ",\n"
    << "  \"render_frames\": " << stats.render_frames << ",\n"
    << "  \"last_render_cycles\": " << stats.last_render_cycles << ",\n"
    << "  \"avg_render_cycles\": " << avg_render_cycles << ",\n"
    << "  \"max_render_cycles\": " << stats.max_render_cycles << ",\n"
    << "  \"deadline_misses\": " << stats.deadline_misses << ",\n"
    << "  \"over_budget_frames\": " << stats.over_budget_frames << ",\n"
    << "  \"max_over_budget_cycles\": " << stats.max_over_budget_cycles << ",\n"
    << "  \"endpoint_cross_line_pairs\": " << stats.endpoint_cross_line_pairs << ",\n"
    << "  \"endpoint_fetch_slot_pressure_cycles\": " << stats.endpoint_fetch_slot_pressure_cycles << ",\n"
    << "  \"endpoint_memory_stall_cycles\": " << stats.endpoint_memory_stall_cycles << ",\n"
    << "  \"endpoint_fetch_slot_max_occupancy\": " << int(stats.endpoint_fetch_slot_max_occupancy) << ",\n"
    << "  \"endpoint_word_req_max_occupancy\": " << int(stats.endpoint_word_req_max_occupancy) << ",\n"
    << "  \"endpoint_rsp_meta_max_occupancy\": " << int(stats.endpoint_rsp_meta_max_occupancy) << ",\n"
    << "  \"dsp_context_queue_max_occupancy\": " << int(stats.dsp_context_queue_max_occupancy) << ",\n"
    << "  \"dsp_ready_no_context_cycles\": " << stats.dsp_ready_no_context_cycles << ",\n"
    << "  \"avg_response_latency_cycles\": " << avg_latency << ",\n"
    << "  \"max_response_latency_cycles\": " << stats.response_latency_max << ",\n"
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
    render::RenderInputs inputs = render::load_render_inputs(args);
    std::vector<int16_t> wave_memory = render::take_sf2_wave_memory(inputs);
    std::vector<render::Region> regions;
    render::prepare_render_regions(args, inputs, wave_memory, regions);

    std::string wav_path = args.out_dir + "/out.wav";
    render::write_summary(args.out_dir + "/midi_render_config.json", regions, args.sample_rate,
                          inputs.sample_count, int(inputs.events.size()),
                          "  \"render_target\": \"render-memory\""
                          ",\n  \"rtl_top\": \"wavetable_cached_render_core\""
                          ",\n" + render::render_input_json_fields(args, inputs.control_tick_samples) +
                          ",\n" + render::memory_profile_json_field(args));

    render::MemoryProfile memory_profile = render::parse_memory_profile(args.memory_profile);
    render::RtlHarness rtl(wave_memory, wav_path, args.sample_rate, memory_profile);
    rtl.reset();
    render::RenderDiagnostics diagnostics;
    diagnostics.detailed_enabled = args.detailed_diagnostics;
    render::CommandVoiceControl control(rtl);
    render::McuModel mcu(control, regions, &diagnostics);
    render::RenderTimeline timeline(inputs.events, inputs.control_tick_samples, mcu);

    int produced = 0;
    for (; produced < inputs.sample_count && !render::interrupt_requested(); ++produced) {
      timeline.advance_to(produced);
      rtl.request_sample(produced);
    }

    if (!render::interrupt_requested() && rtl.nonzero_output_words() == 0) {
      throw std::runtime_error("render produced all-zero PCM; increase SECONDS if the MIDI starts later, or inspect event/region mapping");
    }

    render::MemoryStats stats = rtl.memory_stats();
    if (render::interrupt_requested()) {
      std::cout << "INTERRUPTED: C++ harness rendered " << produced << " of "
                << inputs.sample_count << " MIDI-driven stereo samples to " << wav_path << "\n";
      render::write_memory_stats(args.out_dir + "/memory_stats.json", stats, diagnostics);
      rtl.print_memory_stats();
      return 130;
    }

    std::cout << "PASS: C++ harness rendered " << inputs.sample_count << " MIDI-driven stereo samples to " << wav_path << "\n";
    std::cout << "regions=" << regions.size() << " wave_words=" << wave_memory.size() << " events=" << inputs.events.size()
              << " nonzero_output_words=" << rtl.nonzero_output_words() << "\n";
    render::write_memory_stats(args.out_dir + "/memory_stats.json", stats, diagnostics);
    rtl.print_memory_stats();
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-memory failed: " << e.what() << "\n";
    return 1;
  }
}
