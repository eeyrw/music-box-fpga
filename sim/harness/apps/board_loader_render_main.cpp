#include "board_loader_render_harness.h"
#include "board_loader_render_utils.h"
#include "fanout_sink.h"
#include "memory_profile.h"
#include "midi_parser.h"
#include "reference_synth.h"
#include "render_interrupt.h"
#include "render_support.h"
#include "sf2_loader.h"

#include <verilated.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  try {
    render::install_interrupt_handler();
    Verilated::commandArgs(argc, argv);
    render::Args args = render::parse_args(argc, argv);
    int sample_count = std::max(1, int(std::round(args.seconds * args.sample_rate)));
    int adsr_tick_samples = render::envelope_tick_samples(args);

    render::Sf2Data sf2 = render::load_sf2(args.sf2);
    std::vector<uint8_t> sf2_bytes = render::read_file_bytes(args.sf2);
    std::vector<uint8_t> sd_image = render::make_raw_sd_image(sf2_bytes, 1);
    std::vector<render::NoteEvent> events = args.midi.empty() ? render::default_melody()
                                                              : render::parse_midi(args.midi);

    std::string wav_path = args.out_dir + "/out.wav";
    render::MemoryProfile memory_profile = render::parse_memory_profile(args.memory_profile);
    render::BoardLoaderRenderHarness board(sd_image, sf2_bytes.size(), wav_path, args.sample_rate, memory_profile);
    board.load_from_sd();
    if (render::interrupt_requested()) {
      std::cout << "INTERRUPTED: board loader render stopped during SD load, wav=" << wav_path << "\n";
      return 130;
    }

    const auto& loaded = board.ddr_bytes();
    if (loaded.size() < sf2_bytes.size()) {
      throw std::runtime_error("DDR image shorter than source SF2 bytes");
    }
    auto mismatch = std::mismatch(sf2_bytes.begin(), sf2_bytes.end(), loaded.begin());
    if (mismatch.first != sf2_bytes.end()) {
      size_t index = size_t(mismatch.first - sf2_bytes.begin());
      throw std::runtime_error("DDR image loaded by SD native RTL does not match source SF2 bytes at byte " +
                               std::to_string(index) + " expected=" + std::to_string(int(*mismatch.first)) +
                               " got=" + std::to_string(int(*mismatch.second)));
    }
    std::vector<int16_t> wave_memory = render::words_from_bytes(loaded, sf2_bytes.size());

    std::vector<render::Region> regions;
    render::prepare_events_and_regions(args, sf2, sample_count, adsr_tick_samples, events, regions, wave_memory);
    render::RenderDiagnostics diagnostics;
    render::ReferenceSynth reference(wave_memory, &diagnostics);
    board.reset_core();
    render::FanoutSink control(board, reference);
    render::McuModel mcu(control, regions, &diagnostics);

    size_t event_index = 0;
    int next_adsr_sample = 0;
    int mismatches = 0;
    int produced = 0;
    for (; produced < sample_count && !render::interrupt_requested(); ++produced) {
      while (event_index < events.size() && events[event_index].sample <= produced) {
        mcu.handle_event(events[event_index++]);
      }
      while (produced >= next_adsr_sample) {
        mcu.envelope_tick();
        next_adsr_sample += adsr_tick_samples;
      }
      auto ref = reference.render_sample();
      auto got = board.request_sample(produced);
      if (got != ref) {
        ++mismatches;
        if (mismatches <= 10) {
          std::cerr << "sample " << produced << " mismatch RTL L=" << got.first
                    << " R=" << got.second << " reference L=" << ref.first
                    << " R=" << ref.second << "\n";
        }
      }
    }

    if (!render::interrupt_requested() && board.nonzero_output_words() == 0) {
      throw std::runtime_error("board loader render produced all-zero PCM");
    }
    if (!render::interrupt_requested() && mismatches != 0) {
      throw std::runtime_error("board loader render found " + std::to_string(mismatches) +
                               " RTL/reference mismatches");
    }

    const auto& reg = board.register_write_stats();
    std::string extra = "  \"render_target\": \"render-board-loader\""
        ",\n  \"rtl_top\": \"board_loader_render_tops\""
        ",\n" + render::render_input_json_fields(args, adsr_tick_samples) +
        ",\n" + render::memory_profile_json_field(args) +
        ",\n  \"loader_cycles\": " + std::to_string(board.loader_cycles()) +
        ",\n  \"sd_image_bytes\": " + std::to_string(sd_image.size()) +
        ",\n  \"sf2_size_bytes\": " + std::to_string(sf2_bytes.size()) +
        ",\n  \"loaded_words\": " + std::to_string(wave_memory.size()) +
        ",\n  \"interrupted\": " + std::string(render::interrupt_requested() ? "true" : "false") +
        ",\n  \"nonzero_output_words\": " + std::to_string(board.nonzero_output_words()) +
        ",\n  \"memory_responses\": " + std::to_string(board.memory_responses()) +
        ",\n  \"register_writes_total\": " + std::to_string(reg.total) +
        ",\n" + render::diagnostics_json_fields(diagnostics) +
        ",\n  \"wav_path\": " + render::json_string(wav_path);
    render::write_summary(args.out_dir + "/board_loader_render_config.json", regions,
                          args.sample_rate, produced, int(events.size()), extra);

    if (render::interrupt_requested()) {
      std::cout << "INTERRUPTED: board loader render wrote " << produced
                << " of " << sample_count << " stereo samples to " << wav_path
                << ", mismatches_seen=" << mismatches << "\n";
      return 130;
    }

    std::cout << "PASS: board loader render loaded " << sf2_bytes.size()
              << " SF2 bytes from raw SD image, matched " << sample_count
              << " RTL/reference stereo samples, wav=" << wav_path << "\n";
    std::cout << "loader_cycles=" << board.loader_cycles()
              << " regions=" << regions.size()
              << " events=" << events.size()
              << " nonzero_output_words=" << board.nonzero_output_words()
              << " memory_responses=" << board.memory_responses()
              << " register_writes=" << reg.total << "\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-board-loader failed: " << e.what() << "\n";
    return 1;
  }
}
