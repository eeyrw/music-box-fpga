#include "fanout_sink.h"
#include "midi_parser.h"
#include "quick_rtl_harness.h"
#include "reference_synth.h"
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
    Verilated::commandArgs(argc, argv);
    render::Args args = render::parse_args(argc, argv);
    int sample_count = std::max(1, int(std::round(args.seconds * args.sample_rate)));
    int adsr_tick_samples = std::max(1, int(std::round(args.adsr_tick_ms * args.sample_rate / 1000.0)));

    render::Sf2Data sf2 = render::load_sf2(args.sf2);
    std::vector<render::NoteEvent> events = args.midi.empty() ? render::default_melody()
                                                              : render::parse_midi(args.midi);
    std::vector<int16_t> wave_memory = sf2.file_words;
    std::vector<render::Region> regions;
    render::prepare_events_and_regions(args, sf2, sample_count, adsr_tick_samples, events, regions, wave_memory);
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
    std::string wav_path = args.out_dir + "/out.wav";
    render::WavWriter wav(wav_path, args.sample_rate);

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

    if (nonzero_words == 0) {
      throw std::runtime_error("quick render produced all-zero RTL PCM; increase SECONDS or inspect event/region mapping");
    }
    if (mismatches != 0) {
      throw std::runtime_error("quick render found " + std::to_string(mismatches) +
                               " RTL/reference mismatches, max_diff_l=" + std::to_string(max_diff_l) +
                               " max_diff_r=" + std::to_string(max_diff_r));
    }

    double avg_render_cycles = sample_count == 0
                                   ? 0.0
                                   : double(rtl.render_cycles_sum()) / double(sample_count);
    auto avg = [sample_count](uint64_t value) {
      return sample_count == 0 ? 0.0 : double(value) / double(sample_count);
    };

    std::ostringstream stats;
    const auto& reg = rtl.register_write_stats();
    stats << "  \"rtl_total_cycles\": " << rtl.total_cycles()
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
          << ",\n  \"register_writes_total\": " << reg.total
          << ",\n  \"register_writes_envelope\": " << reg.envelope
          << ",\n  \"register_writes_gain_runtime\": " << reg.gain_runtime
          << ",\n  \"register_writes_phase_inc_runtime\": " << reg.phase_inc_runtime
          << ",\n  \"register_writes_filter\": " << reg.filter
          << ",\n  \"register_writes_commit\": " << reg.commit
          << ",\n  \"register_writes_release\": " << reg.release
          << ",\n  \"register_writes_config\": " << reg.config
          << ",\n  \"wav_path\": \"" << wav_path << "\"";
    render::write_summary(args.out_dir + "/quick_render_config.json", regions, args.sample_rate,
                          sample_count, int(events.size()), stats.str());

    std::cout << "PASS: quick RTL/reference render matched " << sample_count
              << " stereo samples, regions=" << regions.size()
              << " wave_words=" << wave_memory.size()
              << " events=" << events.size()
              << " nonzero_output_words=" << nonzero_words
              << " rtl_total_cycles=" << rtl.total_cycles()
              << " rtl_avg_render_cycles=" << avg_render_cycles
              << " rtl_max_render_cycles=" << rtl.max_render_cycles()
              << " rtl_avg_memory_reads=" << avg(rtl.render_memory_reads_sum())
              << " rtl_max_memory_reads=" << rtl.max_render_memory_reads()
              << " rtl_max_enabled_voices=" << rtl.max_enabled_voices()
              << " rtl_max_filtered_voices=" << rtl.max_filtered_voices()
              << " register_writes=" << reg.total
              << " filter_writes=" << reg.filter
              << " wav=" << wav_path << "\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-quick failed: " << e.what() << "\n";
    return 1;
  }
}
