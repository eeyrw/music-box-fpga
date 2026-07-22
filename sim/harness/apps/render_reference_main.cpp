#include "midi_parser.h"
#include "reference_synth.h"
#include "render_interrupt.h"
#include "render_support.h"
#include "sf2_loader.h"
#include "wav_writer.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <sstream>
#include <stdexcept>

int main(int argc, char** argv) {
  try {
    render::install_interrupt_handler();
    render::Args args = render::parse_args(argc, argv);
    int sample_count = std::max(1, int(std::round(args.seconds * args.sample_rate)));
    int adsr_tick_samples = std::max(1, int(std::round(args.adsr_tick_ms * args.sample_rate / 1000.0)));

    render::Sf2Data sf2 = render::load_sf2(args.sf2);
    std::vector<render::NoteEvent> events = args.midi.empty() ? render::default_melody()
                                                              : render::parse_midi(args.midi);
    std::vector<int16_t> wave_memory = sf2.file_words;
    std::vector<render::Region> regions;
    render::prepare_events_and_regions(args, sf2, sample_count, adsr_tick_samples, events, regions, wave_memory);

    render::RenderDiagnostics diagnostics;
    render::ReferenceSynth reference(wave_memory, &diagnostics);
    render::McuModel mcu(reference, regions, &diagnostics);

    size_t event_index = 0;
    int next_adsr_sample = 0;
    int nonzero_words = 0;
    std::string wav_path = args.out_dir + "/out.wav";
    render::WavWriter wav(wav_path, args.sample_rate);

    int produced = 0;
    for (; produced < sample_count && !render::interrupt_requested(); ++produced) {
      while (event_index < events.size() && events[event_index].sample <= produced) {
        mcu.handle_event(events[event_index++]);
      }
      while (produced >= next_adsr_sample) {
        mcu.envelope_tick();
        next_adsr_sample += adsr_tick_samples;
      }

      auto sample = reference.render_sample();
      wav.write_stereo(sample.first, sample.second);
      if (sample.first != 0) ++nonzero_words;
      if (sample.second != 0) ++nonzero_words;
    }

    if (!render::interrupt_requested() && nonzero_words == 0) {
      throw std::runtime_error("reference render produced all-zero PCM; increase SECONDS or inspect event/region mapping");
    }

    std::ostringstream stats;
    stats << "  \"render_target\": \"render-reference\""
          << ",\n  \"algorithm\": \"cpp_reference_synth\""
          << ",\n" << render::render_input_json_fields(args, adsr_tick_samples)
          << ",\n" << render::diagnostics_json_fields(diagnostics)
          << ",\n  \"interrupted\": " << (render::interrupt_requested() ? "true" : "false")
          << ",\n  \"nonzero_output_words\": " << nonzero_words
          << ",\n  \"wav_path\": " << render::json_string(wav_path);
    render::write_summary(args.out_dir + "/reference_render_config.json", regions, args.sample_rate,
                          produced, int(events.size()), stats.str());

    if (render::interrupt_requested()) {
      std::cout << "INTERRUPTED: C++ reference render wrote " << produced
                << " of " << sample_count << " stereo samples to " << wav_path << "\n";
      return 130;
    }

    std::cout << "PASS: C++ reference render produced " << sample_count
              << " stereo samples, regions=" << regions.size()
              << " wave_words=" << wave_memory.size()
              << " events=" << events.size()
              << " nonzero_output_words=" << nonzero_words
              << " wav=" << wav_path << "\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-reference failed: " << e.what() << "\n";
    return 1;
  }
}
