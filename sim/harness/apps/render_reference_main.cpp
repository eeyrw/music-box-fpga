#include "command_control.h"
#include "midi_parser.h"
#include "lookahead_compressor_model.h"
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
    render::LookaheadCompressorModel compressor(48, &diagnostics);
    render::CommandFanout command_stream(reference, compressor);
    render::CommandVoiceControl control(command_stream);
    render::CommandAudioControl audio_control(command_stream);
    if (args.compressor_threshold_cb < 0.0 || args.compressor_threshold_cb > 1000.0 ||
        args.compressor_ratio < 1.0 || args.compressor_attack_ms < 0.0 ||
        args.compressor_release_ms < 0.0 || args.master_volume < 0.0 ||
        args.master_volume > 1.0) {
      throw std::runtime_error("invalid compressor or master-volume argument");
    }
    auto cb_q12_20 = [](double cb) {
      return uint32_t(std::llround(cb * double(uint32_t{1} << 20)));
    };
    auto step_for_ms = [&](double milliseconds) {
      if (milliseconds == 0.0) return uint32_t{0};
      const uint64_t frames = std::max<uint64_t>(
          1, uint64_t(std::llround(milliseconds * args.sample_rate / 1000.0)));
      const uint64_t distance = uint64_t{1000} << 20;
      return uint32_t((distance + frames - 1) / frames);
    };
    render::CompressorCommandConfig compressor_config;
    compressor_config.enable = args.compressor_enable;
    compressor_config.threshold_cb_q12_20 = cb_q12_20(args.compressor_threshold_cb);
    compressor_config.ratio_slope_q0_16 = uint16_t(std::clamp<int64_t>(
        std::llround((1.0 - 1.0 / args.compressor_ratio) * 65536.0), 0, 65535));
    compressor_config.attack_step_cb_q12_20 = step_for_ms(args.compressor_attack_ms);
    compressor_config.release_step_cb_q12_20 = step_for_ms(args.compressor_release_ms);
    audio_control.configure_compressor(compressor_config);
    audio_control.set_master_volume(int(std::llround(args.master_volume * 32767.0)));
    const bool use_output_dynamics = args.compressor_enable || args.master_volume != 1.0;
    render::McuModel mcu(control, regions, &diagnostics);
    render::RenderTimeline timeline(inputs.events, inputs.control_tick_samples, mcu);

    int nonzero_words = 0;
    std::string wav_path = args.out_dir + "/out.wav";
    render::WavWriter wav(wav_path, args.sample_rate);

    const auto render_start = Clock::now();
    int produced = 0;
    int input_frame = 0;
    while (produced < inputs.sample_count && !render::interrupt_requested()) {
      timeline.advance_to(input_frame);

      std::pair<int16_t, int16_t> sample;
      if (use_output_dynamics) {
        const auto mix = reference.render_mix();
        const auto compressed = compressor.process_frame(mix.first, mix.second);
        input_frame++;
        if (!compressed) continue;
        sample = *compressed;
      } else {
        sample = reference.render_sample();
        input_frame++;
      }
      wav.write_stereo(sample.first, sample.second);
      if (sample.first != 0) ++nonzero_words;
      if (sample.second != 0) ++nonzero_words;
      produced++;
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
          << ",\n  \"algorithm\": \"cpp_reference_synth"
          << (use_output_dynamics ? "_lookahead_compressor\"" : "\"")
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
