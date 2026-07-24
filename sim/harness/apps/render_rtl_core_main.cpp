#include "command_control.h"
#include "midi_parser.h"
#include "core_rtl_harness.h"
#include "reference_synth.h"
#include "render_interrupt.h"
#include "render_support.h"
#include "sf2_loader.h"
#include "wav_writer.h"

#include <verilated.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <sstream>

namespace render {
namespace {

int abs_diff(int16_t a, int16_t b) {
  return std::abs(int(a) - int(b));
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
    render::RenderDiagnostics diagnostics;
    diagnostics.detailed_enabled = args.detailed_diagnostics;
    render::ReferenceSynth reference(wave_memory, &diagnostics);
    render::CoreRtlHarness rtl(wave_memory);
    rtl.reset();
    render::CommandFanout command_stream(reference, rtl);
    render::CommandVoiceControl control(command_stream);
    render::McuModel mcu(control, regions, &diagnostics);
    render::RenderTimeline timeline(inputs.events, inputs.control_tick_samples, mcu);

    int mismatches = 0;
    int max_diff_l = 0;
    int max_diff_r = 0;
    int nonzero_words = 0;
    std::string wav_path = args.out_dir + "/out.wav";
    render::WavWriter wav(wav_path, args.sample_rate);

    int produced = 0;
    for (; produced < inputs.sample_count && !render::interrupt_requested(); ++produced) {
      timeline.advance_to(produced);

      auto ref = reference.render_sample();
      auto got = rtl.request_sample(produced);
      wav.write_stereo(got.first, got.second);
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

    if (!render::interrupt_requested() && nonzero_words == 0) {
      throw std::runtime_error("RTL core render produced all-zero PCM; increase SECONDS or inspect event/region mapping");
    }
    if (!render::interrupt_requested() && mismatches != 0) {
      throw std::runtime_error("RTL core render found " + std::to_string(mismatches) +
                               " RTL/reference mismatches, max_diff_l=" + std::to_string(max_diff_l) +
                               " max_diff_r=" + std::to_string(max_diff_r));
    }

    double avg_render_cycles = inputs.sample_count == 0
                                   ? 0.0
                                   : double(rtl.render_cycles_sum()) / double(inputs.sample_count);
    auto avg = [&inputs](uint64_t value) {
      return inputs.sample_count == 0 ? 0.0 : double(value) / double(inputs.sample_count);
    };

    std::ostringstream stats;
    stats << "  \"render_target\": \"render-rtl-core\""
          << ",\n  \"rtl_top\": \"wavetable_render_core\""
          << ",\n" << render::render_input_json_fields(args, inputs.control_tick_samples)
          << ",\n  \"rtl_total_cycles\": " << rtl.total_cycles()
          << ",\n  \"rtl_total_memory_reads\": " << rtl.total_memory_reads()
          << ",\n  \"rtl_render_cycles_sum\": " << rtl.render_cycles_sum()
          << ",\n  \"rtl_avg_render_cycles\": " << avg_render_cycles
          << ",\n  \"rtl_max_render_cycles\": " << rtl.max_render_cycles()
          << ",\n  \"rtl_render_memory_reads_sum\": " << rtl.render_memory_reads_sum()
          << ",\n  \"rtl_avg_render_memory_reads\": " << avg(rtl.render_memory_reads_sum())
          << ",\n  \"rtl_max_render_memory_reads\": " << rtl.max_render_memory_reads()
          << ",\n  \"rtl_avg_enabled_voices\": " << avg(rtl.enabled_voice_sum())
          << ",\n  \"rtl_max_enabled_voices\": " << rtl.max_enabled_voices()
          << ",\n  \"rtl_avg_audible_voices\": " << avg(rtl.audible_voice_sum())
          << ",\n  \"rtl_max_audible_voices\": " << rtl.max_audible_voices()
          << ",\n  \"rtl_avg_filtered_voices\": " << avg(rtl.filtered_voice_sum())
          << ",\n  \"rtl_max_filtered_voices\": " << rtl.max_filtered_voices()
          << ",\n  \"rtl_avg_stereo_voices\": " << avg(rtl.stereo_voice_sum())
          << ",\n  \"rtl_max_stereo_voices\": " << rtl.max_stereo_voices()
          << ",\n" << render::diagnostics_json_fields(diagnostics)
          << ",\n  \"interrupted\": " << (render::interrupt_requested() ? "true" : "false")
          << ",\n  \"wav_path\": " << render::json_string(wav_path);
    render::write_summary(args.out_dir + "/rtl_core_render_config.json", regions, args.sample_rate,
                          produced, int(inputs.events.size()), stats.str());

    if (render::interrupt_requested()) {
      std::cout << "INTERRUPTED: RTL core/reference render wrote " << produced
                << " of " << inputs.sample_count << " stereo samples to " << wav_path
                << ", mismatches_seen=" << mismatches << "\n";
      return 130;
    }

    std::cout << "PASS: RTL core/reference render matched " << inputs.sample_count
              << " stereo samples, regions=" << regions.size()
              << " wave_words=" << wave_memory.size()
              << " events=" << inputs.events.size()
              << " nonzero_output_words=" << nonzero_words
              << " rtl_total_cycles=" << rtl.total_cycles()
              << " rtl_avg_render_cycles=" << avg_render_cycles
              << " rtl_max_render_cycles=" << rtl.max_render_cycles()
              << " rtl_avg_memory_reads=" << avg(rtl.render_memory_reads_sum())
              << " rtl_max_memory_reads=" << rtl.max_render_memory_reads()
              << " rtl_max_enabled_voices=" << rtl.max_enabled_voices()
              << " rtl_max_filtered_voices=" << rtl.max_filtered_voices()
              << " wav=" << wav_path << "\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-rtl-core failed: " << e.what() << "\n";
    return 1;
  }
}
