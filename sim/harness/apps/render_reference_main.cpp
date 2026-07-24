#include "command_control.h"
#include "midi_parser.h"
#include "reference_synth.h"
#include "render_interrupt.h"
#include "render_support.h"
#include "sf2_loader.h"
#include "wav_writer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>

int main(int argc, char** argv) {
  try {
    render::install_interrupt_handler();
    render::Args args = render::parse_args(argc, argv);

    using Clock = std::chrono::steady_clock;
    auto elapsed_ms = [](Clock::time_point start, Clock::time_point end) {
      return std::chrono::duration<double, std::milli>(end - start).count();
    };
    const auto total_start = Clock::now();
    render::RenderPreparationTiming preparation_timing;
    render::RenderInputs inputs = render::load_render_inputs(args, &preparation_timing);
    std::vector<int16_t> wave_memory = render::take_sf2_wave_memory(inputs);
    std::vector<render::Region> regions;
    render::prepare_render_regions(args, inputs, wave_memory, regions, &preparation_timing);

    render::RenderDiagnostics diagnostics;
    diagnostics.detailed_enabled = args.detailed_diagnostics;
    render::ReferenceSynth reference(wave_memory, &diagnostics);
    render::CommandVoiceControl control(reference);
    render::McuModel mcu(control, regions, &diagnostics);
    render::RenderTimeline timeline(inputs.events, inputs.control_tick_samples, mcu);

    int nonzero_words = 0;
    std::string wav_path = args.out_dir + "/out.wav";
    render::WavWriter wav(wav_path, args.sample_rate);

    const auto render_start = Clock::now();
    int produced = 0;
    for (; produced < inputs.sample_count && !render::interrupt_requested(); ++produced) {
      timeline.advance_to(produced);

      auto sample = reference.render_sample();
      wav.write_stereo(sample.first, sample.second);
      if (sample.first != 0) ++nonzero_words;
      if (sample.second != 0) ++nonzero_words;
    }
    const auto render_end = Clock::now();

    const double sf2_load_ms = preparation_timing.sf2_load_ms;
    const double event_parse_ms = preparation_timing.event_parse_ms;
    const double prepare_ms = preparation_timing.region_prepare_ms;
    const double render_ms = elapsed_ms(render_start, render_end);
    const double total_ms = elapsed_ms(total_start, render_end);

    if (!render::interrupt_requested() && nonzero_words == 0) {
      throw std::runtime_error("reference render produced all-zero PCM; increase SECONDS or inspect event/region mapping");
    }

    std::ostringstream stats;
    stats << "  \"render_target\": \"render-reference\""
          << ",\n  \"algorithm\": \"cpp_reference_synth\""
          << ",\n" << render::render_input_json_fields(args, inputs.control_tick_samples)
          << ",\n" << render::diagnostics_json_fields(diagnostics)
          << ",\n  \"timing_sf2_load_ms\": " << sf2_load_ms
          << ",\n  \"timing_event_parse_ms\": " << event_parse_ms
          << ",\n  \"timing_prepare_ms\": " << prepare_ms
          << ",\n  \"timing_render_ms\": " << render_ms
          << ",\n  \"timing_total_ms\": " << total_ms
          << ",\n  \"interrupted\": " << (render::interrupt_requested() ? "true" : "false")
          << ",\n  \"nonzero_output_words\": " << nonzero_words
          << ",\n  \"wav_path\": " << render::json_string(wav_path);
    render::write_summary(args.out_dir + "/reference_render_config.json", regions, args.sample_rate,
                          produced, int(inputs.events.size()), stats.str());

    if (render::interrupt_requested()) {
      std::cout << "INTERRUPTED: C++ reference render wrote " << produced
                << " of " << inputs.sample_count << " stereo samples to " << wav_path << "\n";
      return 130;
    }

    std::cout << "PASS: C++ reference render produced " << inputs.sample_count
              << " stereo samples, regions=" << regions.size()
              << " wave_words=" << wave_memory.size()
              << " events=" << inputs.events.size()
              << " nonzero_output_words=" << nonzero_words
              << " wav=" << wav_path << "\n";
    std::cout << std::fixed << std::setprecision(3)
              << "TIMING: sf2_load_ms=" << sf2_load_ms
              << " event_parse_ms=" << event_parse_ms
              << " prepare_ms=" << prepare_ms
              << " render_ms=" << render_ms
              << " total_ms=" << total_ms << "\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-reference failed: " << e.what() << "\n";
    return 1;
  }
}
