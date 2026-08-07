#include "mcu_sf2_asset.h"
#include "command_control.h"
#include "../../../mcu/msf2.h"

#include <cstdint>
#include <cmath>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

class LatestCommandSink : public render::CommandWordSink {
 public:
  void write_command_words(render::CommandWordView words) override {
    latest.assign(words.begin(), words.end());
  }
  std::vector<uint32_t> latest;
};

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

int discard_c_command(void*, const uint32_t*, uint8_t) {
  return 0;
}

template <typename Action>
void require_failure(Action action, const char* message) {
  try {
    action();
  } catch (const std::exception&) {
    return;
  }
  throw std::runtime_error(message);
}

void write_u32(std::vector<uint8_t>& data, size_t offset, uint32_t value) {
  for (int byte = 0; byte < 4; ++byte) {
    data.at(offset + size_t(byte)) = uint8_t(value >> (8 * byte));
  }
}

void write_u64(std::vector<uint8_t>& data, size_t offset, uint64_t value) {
  write_u32(data, offset, uint32_t(value));
  write_u32(data, offset + 4, uint32_t(value >> 32));
}

uint32_t read_u32(const std::vector<uint8_t>& data, size_t offset) {
  return uint32_t(data.at(offset)) | (uint32_t(data.at(offset + 1)) << 8) |
         (uint32_t(data.at(offset + 2)) << 16) |
         (uint32_t(data.at(offset + 3)) << 24);
}

uint64_t read_u64(const std::vector<uint8_t>& data, size_t offset) {
  return uint64_t(read_u32(data, offset)) |
         (uint64_t(read_u32(data, offset + 4)) << 32);
}

void refresh_crc(std::vector<uint8_t>& data) {
  write_u32(data, render::kMcuSf2AssetImageCrcOffset, 0);
  write_u32(data, render::kMcuSf2AssetImageCrcOffset,
            render::mcu_sf2_asset_image_crc(data.data(), data.size()));
}


void compare_compact(const render::Sf2Data& sf2,
                     const render::Sf2SemanticData& semantic,
                     const render::McuSf2AssetView& view) {
  require(view.preset_count() == semantic.presets.size(), "compact preset count mismatch");
  require(view.zone_count() == semantic.candidates.size(), "compact zone count mismatch");
  for (size_t preset_index = 0; preset_index < view.preset_count(); ++preset_index) {
    const auto preset = view.preset(preset_index);
    const auto& expected_preset = semantic.presets[preset_index];
    require(preset.program == expected_preset.program && preset.bank == expected_preset.bank &&
                preset.first_zone == expected_preset.first_candidate &&
                preset.zone_count == expected_preset.candidate_count,
            "compact preset mismatch");
    require(view.find_preset(preset.program, preset.bank) == int32_t(preset_index),
            "compact preset lookup mismatch");
    for (int key = 0; key < 128; ++key) {
      for (int velocity = 1; velocity < 128; ++velocity) {
        std::vector<uint32_t> expected;
        std::vector<uint32_t> actual;
        for (uint32_t local = 0; local < preset.zone_count; ++local) {
          const uint32_t index = preset.first_zone + local;
          const auto& candidate = semantic.candidates[index];
          const auto zone = view.zone(index);
          if (key >= candidate.key_low && key <= candidate.key_high &&
              velocity >= candidate.velocity_low && velocity <= candidate.velocity_high) {
            expected.push_back(index);
          }
          if (key >= zone.key_low && key <= zone.key_high &&
              velocity >= zone.velocity_low && velocity <= zone.velocity_high) {
            actual.push_back(index);
          }
        }
        require(actual == expected, "compact zone selection mismatch");
      }
    }
  }

  LatestCommandSink oracle_sink;
  LatestCommandSink compact_sink;
  render::CommandVoiceControl oracle_control(oracle_sink);
  render::CommandVoiceControl compact_control(compact_sink);
  for (size_t preset_index = 0; preset_index < view.preset_count(); ++preset_index) {
    const auto preset = view.preset(preset_index);
    for (uint32_t local = 0; local < preset.zone_count; ++local) {
      const uint32_t zone_index = preset.first_zone + local;
      const auto zone = view.zone(zone_index);
      for (int key = zone.key_low; key <= zone.key_high; ++key) {
        const auto oracle = render::make_region_for_compiled_candidate(
            sf2, preset_index, local, key,
            int(render::reference_mcu_sf2_asset_profile().sample_rate),
            int(render::reference_mcu_sf2_asset_profile().control_tick_samples));
        const auto compact = view.materialize_zone(zone_index, key);
        const int voice = int(zone_index % render::kNumVoices);
        oracle_control.start_voice(voice, oracle.phase_inc, oracle);
        compact_control.start_voice(voice, compact.phase_inc, compact);
        require(oracle_sink.latest.size() == compact_sink.latest.size(),
                "compact START length mismatch");
        oracle_sink.latest[0] &= ~(0x3ffu << 14);
        compact_sink.latest[0] &= ~(0x3ffu << 14);
        oracle_sink.latest[1] = compact_sink.latest[1] = 1;
        require(oracle_sink.latest == compact_sink.latest,
                "compact START materialization mismatch");
      }
    }
  }
}

void compare_pure_c(const std::vector<uint8_t>& image,
                    const render::McuSf2AssetView& oracle) {
  msf2_view view{};
  require(msf2_view_init(&view, image.data(), image.size()) == MSF2_OK,
          "pure-C reader rejected valid compact image");
  {
    msf2_runtime runtime{};
    msf2_channel_state channels[MSF2_CHANNEL_COUNT]{};
    std::vector<msf2_voice_state> voices(MSF2_MAX_VOICE_COUNT + 1u);
    std::vector<uint16_t> free_stack(MSF2_MAX_VOICE_COUNT + 1u);
    require(msf2_runtime_init(&runtime, &view, channels, voices.data(),
                              free_stack.data(), MSF2_MAX_VOICE_COUNT,
                              discard_c_command, nullptr) == MSF2_OK,
            "pure-C runtime rejected the FPGA's 512-voice capacity");
    require(msf2_runtime_init(&runtime, &view, channels, voices.data(),
                              free_stack.data(), MSF2_MAX_VOICE_COUNT + 1u,
                              discard_c_command, nullptr) == MSF2_ERR_ARGUMENT,
            "pure-C runtime accepted a capacity above the FPGA protocol");
  }
  require(msf2_preset_count(&view) == oracle.preset_count() &&
              msf2_zone_count(&view) == oracle.zone_count(),
          "pure-C compact counts mismatch");
  for (uint32_t preset_index = 0; preset_index < msf2_preset_count(&view);
       ++preset_index) {
    msf2_preset preset{};
    require(msf2_get_preset(&view, preset_index, &preset) == MSF2_OK,
            "pure-C preset read failed");
    const auto expected = oracle.preset(preset_index);
    require(preset.program == expected.program && preset.bank == expected.bank &&
                preset.first_zone == expected.first_zone &&
                preset.zone_count == expected.zone_count,
            "pure-C preset mismatch");
    require(msf2_find_preset(&view, preset.program, preset.bank) ==
                int32_t(preset_index),
            "pure-C preset lookup mismatch");
    for (int key = 0; key < 128; ++key) {
      for (int velocity = 0; velocity < 128; ++velocity) {
        std::vector<uint32_t> wanted;
        for (uint32_t local = 0; local < preset.zone_count; ++local) {
          const uint32_t zone_index = preset.first_zone + local;
          const auto zone = oracle.zone(zone_index);
          if (key >= zone.key_low && key <= zone.key_high &&
              velocity >= zone.velocity_low && velocity <= zone.velocity_high) {
            wanted.push_back(zone_index);
          }
        }
        msf2_layers layers{};
        const msf2_result result = msf2_collect_layers(
            &view, preset_index, uint8_t(key), uint8_t(velocity), &layers);
        if (wanted.size() > MSF2_MAX_LAYERS) {
          require(result == MSF2_ERR_CAPACITY,
                  "pure-C layer overflow was not bounded");
          continue;
        }
        require(result == MSF2_OK && layers.count == wanted.size(),
                "pure-C layer selection count mismatch");
        for (size_t index = 0; index < wanted.size(); ++index) {
          require(layers.zone_index[index] == wanted[index],
                  "pure-C layer order mismatch");
        }
      }
    }
  }
  for (uint32_t zone_index = 0; zone_index < msf2_zone_count(&view); ++zone_index) {
    msf2_zone zone{};
    uint16_t amounts[MSF2_GENERATOR_COUNT]{};
    uint64_t presence = 0;
    require(msf2_get_zone(&view, zone_index, &zone) == MSF2_OK &&
                msf2_decode_generators(&view, zone_index, amounts, &presence) == MSF2_OK,
            "pure-C zone decode failed");
    const auto expected = oracle.zone(zone_index);
    require(zone.key_low == expected.key_low && zone.key_high == expected.key_high &&
                zone.velocity_low == expected.velocity_low &&
                zone.velocity_high == expected.velocity_high &&
                zone.sample_index == expected.sample_index &&
                presence == expected.generator_presence,
            "pure-C zone mismatch");
    uint32_t packed = 0;
    for (uint32_t oper = 0; oper < MSF2_GENERATOR_COUNT; ++oper) {
      if ((presence & (uint64_t(1) << oper)) == 0) continue;
      require(amounts[oper] == oracle.generator_amount(expected.first_generator + packed),
              "pure-C generator amount mismatch");
      ++packed;
    }
    msf2_sample sample{};
    require(msf2_get_sample(&view, zone.sample_index, &sample) == MSF2_OK,
            "pure-C sample read failed");
    const auto expected_sample = oracle.sample(zone.sample_index);
    require(sample.start == expected_sample.start && sample.end == expected_sample.end &&
                sample.loop_start == expected_sample.start_loop &&
                sample.loop_end == expected_sample.end_loop &&
                sample.sample_rate == expected_sample.sample_rate &&
                sample.original_pitch == expected_sample.original_pitch &&
                sample.pitch_correction == expected_sample.pitch_correction,
            "pure-C sample mismatch");
    for (int key = zone.key_low; key <= zone.key_high; ++key) {
      msf2_note_params params{};
      require(msf2_materialize_note(&view, zone_index, uint8_t(key), &params) == MSF2_OK,
              "pure-C note materialization failed");
      const auto expected_note = oracle.materialize_zone(zone_index, key);
      require(params.base_addr == expected_note.base_addr &&
                  params.length == expected_note.length &&
                  params.loop_start == expected_note.loop_start &&
                  params.loop_end == expected_note.loop_end &&
                  params.loop_mode == expected_note.loop_mode,
              "pure-C sample window mismatch");
      require(std::abs(int64_t(params.phase_inc) - expected_note.phase_inc) <= 1,
              "pure-C phase increment exceeds one-LSB error");
      require(std::abs(int(params.gain_l) - expected_note.gain_l) <= 1 &&
                  std::abs(int(params.gain_r) - expected_note.gain_r) <= 1,
              "pure-C gain/pan exceeds one-LSB error");
      require(bool(params.filter_enable) == expected_note.filter_enable &&
                  std::abs(int(params.filter_b0) - expected_note.filter_b0) <= 1 &&
                  std::abs(int(params.filter_b1) - expected_note.filter_b1) <= 1 &&
                  std::abs(int(params.filter_b2) - expected_note.filter_b2) <= 1 &&
                  std::abs(int(params.filter_a1) - expected_note.filter_a1) <= 1 &&
                  std::abs(int(params.filter_a2) - expected_note.filter_a2) <= 1,
              "pure-C filter exceeds one-LSB error");
      const auto& envelope = expected_note.volume_envelope;
      const auto duration_close = [](uint32_t actual, uint32_t wanted) {
        const int64_t tolerance = std::max<int64_t>(1, (int64_t(wanted) + 499999) / 500000);
        return std::abs(int64_t(actual) - wanted) <= tolerance;
      };
      if (!(duration_close(params.delay_samples, envelope.delay_samples) &&
            duration_close(params.attack_samples, envelope.attack_samples) &&
            duration_close(params.hold_samples, envelope.hold_samples) &&
            duration_close(params.decay_samples, envelope.decay_samples) &&
            params.sustain_cb_q12_20 == envelope.sustain_cb_q12_20 &&
            duration_close(params.release_samples, envelope.release_samples))) {
        throw std::runtime_error(
            "pure-C volume envelope exceeds numeric error contract at zone/key " +
            std::to_string(zone_index) + "/" + std::to_string(key) + " C=" +
            std::to_string(params.delay_samples) + "," +
            std::to_string(params.attack_samples) + "," +
            std::to_string(params.hold_samples) + "," +
            std::to_string(params.decay_samples) + "," +
            std::to_string(params.release_samples) + " oracle=" +
            std::to_string(envelope.delay_samples) + "," +
            std::to_string(envelope.attack_samples) + "," +
            std::to_string(envelope.hold_samples) + "," +
            std::to_string(envelope.decay_samples) + "," +
            std::to_string(envelope.release_samples));
      }
      uint32_t start_words[17]{};
      uint8_t start_word_count = 0;
      // Exercise the last protocol-valid voice ID as well as ordinary IDs.
      // The RP2040 firmware defaults to all 512 FPGA mono voices.
      const uint16_t voice = zone_index == 0u ?
          uint16_t(MSF2_MAX_VOICE_COUNT - 1u) :
          uint16_t(zone_index % render::kNumVoices);
      auto packed_note = expected_note;
      packed_note.phase_inc = params.phase_inc;
      packed_note.gain_l = params.gain_l;
      packed_note.gain_r = params.gain_r;
      packed_note.filter_enable = params.filter_enable != 0;
      packed_note.filter_b0 = params.filter_b0;
      packed_note.filter_b1 = params.filter_b1;
      packed_note.filter_b2 = params.filter_b2;
      packed_note.filter_a1 = params.filter_a1;
      packed_note.filter_a2 = params.filter_a2;
      packed_note.volume_envelope = {
          params.delay_samples, params.attack_samples, params.hold_samples,
          params.decay_samples, params.sustain_cb_q12_20, params.release_samples};
      const auto expected_start = render::build_voice_start_command(
          voice, 7u, params.phase_inc, packed_note);
      require(msf2_pack_start(voice, 7u, &params, start_words,
                              &start_word_count) == MSF2_OK &&
                  start_word_count == expected_start.length &&
                  std::equal(start_words, start_words + start_word_count,
                             expected_start.words.begin()),
              "pure-C START framing mismatch");
      if (zone_index == 0u && key == zone.key_low) {
        require(msf2_pack_start(MSF2_MAX_VOICE_COUNT, 7u, &params,
                                start_words, &start_word_count) ==
                    MSF2_ERR_ARGUMENT,
                "pure-C START accepted voice ID 512");
      }
    }
  }
}

double curve_reference(uint8_t curve, int value) {
  auto concave = [](int input) {
    if (input <= 0) return 0.0;
    if (input >= 127) return 1.0;
    return (-400.0 / 960.0) * std::log10(double(127 - input) / 127.0);
  };
  auto convex = [&](int input) {
    if (input <= 0) return 0.0;
    if (input >= 127) return 1.0;
    return 1.0 - (-400.0 / 960.0) * std::log10(double(input) / 127.0);
  };
  const int type = curve & 3;
  const bool bipolar = (curve & 4u) != 0;
  const int directed = (curve & 8u) != 0 ? 127 - value : value;
  const double x = double(directed) / 128.0;
  if (!bipolar) {
    if (type == 1) return std::min(concave(directed), 127.0 / 128.0);
    if (type == 2) return std::min(convex(directed), 127.0 / 128.0);
    if (type == 3) return x >= 0.5 ? 1.0 : 0.0;
    return x;
  }
  const double v = -1.0 + 2.0 * x;
  if (type == 3) return v >= 0.0 ? 1.0 : -1.0;
  if (type == 0) return v;
  const int magnitude = int(std::round(std::abs(v) * 128.0));
  const double shaped = type == 1 ? concave(magnitude) : convex(magnitude);
  return std::copysign(v >= 0.0 ? std::min(shaped, 127.0 / 128.0) : shaped, v);
}

bool destination_in_family(uint16_t destination, int family) {
  if (family == 0) return destination == 13 || destination == 17 || destination == 48;
  if (family == 1) return destination == 0 || destination == 5 ||
                          destination == 6 || destination == 7;
  return destination == 8 || destination == 10 || destination == 11;
}

void compare_modulation(const render::Sf2SemanticData& semantic,
                        const render::McuSf2AssetView& view) {
  require(view.candidate_program_count() == semantic.candidates.size(),
          "candidate modulation reference count mismatch");
  int maximum_curve_error = 0;
  int maximum_curve = 0;
  int maximum_curve_value = 0;
  for (uint8_t curve = 0; curve < render::kMcuSourceCurveCount; ++curve) {
    for (uint8_t value = 0; value < render::kMcuSourceCurveSize; ++value) {
      const int32_t expected = int32_t(std::llround(
          curve_reference(curve, value) * render::kMcuModulationOne));
      const int32_t runtime = render::mcu_sf2_source_curve_q16(curve, value);
      const int error = int(std::abs(int64_t(runtime) - expected));
      if (error > maximum_curve_error) {
        maximum_curve_error = error;
        maximum_curve = curve;
        maximum_curve_value = value;
      }
    }
  }
  if (maximum_curve_error > 1) {
    throw std::runtime_error("Q16.16 source curve exceeds one-LSB error at curve " +
                             std::to_string(maximum_curve) + " value " +
                             std::to_string(maximum_curve_value) + ": " +
                             std::to_string(maximum_curve_error));
  }

  for (size_t candidate_index = 0; candidate_index < semantic.candidates.size();
       ++candidate_index) {
    const auto& candidate = semantic.candidates[candidate_index];
    const auto references = view.candidate_programs(candidate_index);
    const uint32_t programs[3] = {references.gain, references.pitch, references.filter};
    for (int family = 0; family < 3; ++family) {
      std::vector<render::McuSf2ModulationTerm> expected;
      for (uint32_t index = 0; index < candidate.modulator_count; ++index) {
        const auto& mod = semantic.modulators[candidate.first_modulator + index];
        if (mod.amount == 0 || !destination_in_family(mod.dest, family)) continue;
        expected.push_back({mod.src, mod.dest, int16_t(mod.amount), mod.amount_src,
                            mod.transform,
                            uint16_t(render::mcu_sf2_source_dependencies(mod.src) |
                                     render::mcu_sf2_source_dependencies(mod.amount_src))});
      }
      std::stable_partition(expected.begin(), expected.end(), [](const auto& term) {
        return (term.dependencies & ~render::kMcuDependencyNote) == 0;
      });
      if (expected.empty()) {
        require(programs[family] == UINT32_MAX, "empty modulation family has a program");
        continue;
      }
      require(programs[family] < view.modulation_program_count(),
              "modulation family program is missing");
      const auto program = view.modulation_program(programs[family]);
      require(int(program.family) == family && program.term_count == expected.size(),
              "modulation family shape mismatch");
      uint16_t dependencies = 0;
      for (size_t index = 0; index < expected.size(); ++index) {
        const auto actual = view.modulation_term(program.first_term + index);
        const auto& wanted = expected[index];
        require(actual.source == wanted.source &&
                    actual.destination == wanted.destination &&
                    actual.amount == wanted.amount &&
                    actual.amount_source == wanted.amount_source &&
                    actual.transform == wanted.transform &&
                    actual.dependencies == wanted.dependencies,
                "compiled modulation term mismatch");
        dependencies |= actual.dependencies;
      }
      require(program.dependencies == dependencies,
              "compiled modulation dependency mismatch");
    }
  }

  render::McuFixedChannelState channel;
  render::McuFixedVoiceSources voice;
  for (uint8_t curve = 0; curve < render::kMcuSourceCurveCount; ++curve) {
    const uint16_t source = uint16_t(0x0081u | (uint16_t(curve & 3u) << 10) |
                                     ((curve & 4u) ? 0x0200u : 0) |
                                     ((curve & 8u) ? 0x0100u : 0));
    for (int value = 0; value < 128; ++value) {
      channel.cc[1] = uint8_t(value);
      const render::McuSf2ModulationTerm term{source, 0, 12700, 0, 0,
                                              render::kMcuDependencyCc};
      const int64_t actual = render::mcu_sf2_evaluate_term_q16(term, channel, voice);
      const int64_t expected = int64_t(std::llround(
          12700.0 * curve_reference(curve, value) * render::kMcuModulationOne));
      require(std::abs(int64_t(actual) - expected) <= 12700,
              "fixed modulation term exceeds source-quantization error contract");
    }
  }
  channel.cc[1] = 0;
  const render::McuSf2ModulationTerm positive_limit{
      0x0281, 0, INT16_MIN, 0, 0, render::kMcuDependencyCc};
  require(render::mcu_sf2_evaluate_term_q16(positive_limit, channel, voice) ==
              int64_t(32768) * render::kMcuModulationOne,
          "fixed modulation term clipped the positive Q16.16 boundary");
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 2) throw std::runtime_error("usage: mcu_sf2_asset_test <soundfont.sf2>");
    const uint64_t source_size = std::filesystem::file_size(argv[1]);
    render::Sf2Data sf2 = render::load_sf2(argv[1]);
    const render::Sf2SemanticData semantic = render::compile_sf2_semantics(sf2);
    const std::vector<uint8_t> image_a = render::build_mcu_sf2_asset(sf2, source_size);
    const std::vector<uint8_t> image_b = render::build_mcu_sf2_asset(sf2, source_size);
    require(image_a == image_b, "MCU SF2 asset generation is not deterministic");

    const render::McuSf2AssetView view(image_a.data(), image_a.size());
    require(view.matches_source(sf2, source_size), "asset does not match source SF2");
    require(view.sample_word_offset() == sf2.smpl_word_offset &&
                view.sample_word_count() == sf2.smpl_word_count,
            "sample span mismatch");
    compare_compact(sf2, semantic, view);
    compare_modulation(semantic, view);
    compare_pure_c(image_a, view);
    require(view.find_preset(127, 16383) == -1,
            "missing sparse preset lookup did not fail");

    require(semantic.presets.size() >= 2, "fixture needs multiple presets for pruning test");
    render::McuSf2AssetSelection subset;
    subset.presets.emplace_back(semantic.presets[0].bank, semantic.presets[0].program);
    const std::vector<uint8_t> subset_image = render::build_mcu_sf2_asset(
        sf2, source_size, render::reference_mcu_sf2_asset_profile(), subset);
    const render::McuSf2AssetView subset_view(subset_image.data(), subset_image.size());
    require(subset_view.preset_count() == 1 &&
                subset_view.selected_preset_count() == 1 &&
                subset_view.selection_crc32() != 0,
            "preset subset was not recorded");
    require(subset_view.find_preset(semantic.presets[0].program,
                                    semantic.presets[0].bank) == 0,
            "selected preset is not dispatchable");
    require(subset_view.find_preset(semantic.presets[1].program,
                                    semantic.presets[1].bank) == -1,
            "unselected preset remained dispatchable");
    require(subset_view.candidate_program_count() < view.candidate_program_count() &&
                subset_view.zone_count() < view.zone_count() &&
                subset_image.size() < image_a.size(),
            "preset subset did not prune reachable metadata");

    render::McuSf2AssetSelection duplicate = subset;
    duplicate.presets.push_back(duplicate.presets.front());
    require_failure([&] {
      (void)render::build_mcu_sf2_asset(
          sf2, source_size, render::reference_mcu_sf2_asset_profile(), duplicate);
    }, "duplicate preset selection was accepted");

    require_failure([&] {
      render::McuSf2AssetView truncated(image_a.data(), image_a.size() - 1);
      (void)truncated;
    }, "truncated image was accepted");

    std::vector<uint8_t> old_version = image_a;
    old_version[4] = 1;
    old_version[5] = 0;
    require_failure([&] {
      render::McuSf2AssetView invalid(old_version.data(), old_version.size());
      (void)invalid;
    }, "obsolete MCU SF2 asset version was accepted");

    std::vector<uint8_t> bad_crc = image_a;
    bad_crc.back() ^= 0x80;
    msf2_view bad_c_view{};
    require(msf2_view_init(&bad_c_view, bad_crc.data(), bad_crc.size()) == MSF2_ERR_CRC,
            "pure-C reader accepted bad image CRC");
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_crc.data(), bad_crc.size());
      (void)invalid;
    }, "bad image CRC was accepted");

    std::vector<uint8_t> bad_section = image_a;
    write_u32(bad_section, render::kMcuSf2AssetSectionDirectoryOffset + 4, 1);
    refresh_crc(bad_section);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_section.data(), bad_section.size());
      (void)invalid;
    }, "misaligned section was accepted");

    std::vector<uint8_t> bad_reference = image_a;
    write_u32(bad_reference, render::kMcuSf2AssetSectionDirectoryOffset + 8, 0);
    refresh_crc(bad_reference);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_reference.data(), bad_reference.size());
      (void)invalid;
    }, "invalid cross-section reference was accepted");

    std::vector<uint8_t> bad_zone = image_a;
    const size_t zone_section_entry = render::kMcuSf2AssetSectionDirectoryOffset +
        render::kMcuSf2AssetSectionEntrySize;
    const uint32_t first_zone_offset = read_u32(bad_zone, zone_section_entry + 4);
    bad_zone.at(first_zone_offset + 10) = 0xff;
    bad_zone.at(first_zone_offset + 11) = 0xff;
    refresh_crc(bad_zone);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_zone.data(), bad_zone.size());
      (void)invalid;
    }, "invalid zone sample reference was accepted");

    std::vector<uint8_t> bad_presence = image_a;
    uint64_t presence = read_u64(bad_presence, first_zone_offset + 12);
    require(presence != 0, "fixture first zone needs a generator presence bit");
    presence &= presence - 1;
    presence |= uint64_t(1) << 63;
    write_u64(bad_presence, first_zone_offset + 12, presence);
    refresh_crc(bad_presence);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_presence.data(), bad_presence.size());
      (void)invalid;
    }, "reserved generator presence bit was accepted");

    std::vector<uint8_t> bad_key_range = image_a;
    bad_key_range.at(first_zone_offset + 1) = 128;
    refresh_crc(bad_key_range);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_key_range.data(), bad_key_range.size());
      (void)invalid;
    }, "out-of-range zone key was accepted");

    std::vector<uint8_t> bad_sample_rate = image_a;
    const size_t sample_section_entry = render::kMcuSf2AssetSectionDirectoryOffset +
        3 * render::kMcuSf2AssetSectionEntrySize;
    const uint32_t first_sample_offset =
        read_u32(bad_sample_rate, sample_section_entry + 4);
    write_u32(bad_sample_rate, first_sample_offset + 16, 0);
    refresh_crc(bad_sample_rate);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_sample_rate.data(), bad_sample_rate.size());
      (void)invalid;
    }, "zero compact sample rate was accepted");

    std::vector<uint8_t> bad_program = image_a;
    const size_t candidate_program_section_entry =
        render::kMcuSf2AssetSectionDirectoryOffset +
        4 * render::kMcuSf2AssetSectionEntrySize;
    const uint32_t candidate_program_offset =
        read_u32(bad_program, candidate_program_section_entry + 4);
    write_u32(bad_program, candidate_program_offset,
              uint32_t(view.modulation_program_count()));
    refresh_crc(bad_program);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_program.data(), bad_program.size());
      (void)invalid;
    }, "invalid modulation program reference was accepted");

    std::vector<uint8_t> bad_program_reserved = image_a;
    const size_t modulation_program_section_entry =
        render::kMcuSf2AssetSectionDirectoryOffset +
        5 * render::kMcuSf2AssetSectionEntrySize;
    const uint32_t modulation_program_offset =
        read_u32(bad_program_reserved, modulation_program_section_entry + 4);
    bad_program_reserved.at(modulation_program_offset + 11) = 1;
    refresh_crc(bad_program_reserved);
    require_failure([&] {
      render::McuSf2AssetView invalid(
          bad_program_reserved.data(), bad_program_reserved.size());
      (void)invalid;
    }, "nonzero modulation program reserved byte was accepted");

    std::vector<uint8_t> bad_transform = image_a;
    const size_t modulation_term_section_entry =
        render::kMcuSf2AssetSectionDirectoryOffset +
        6 * render::kMcuSf2AssetSectionEntrySize;
    const uint32_t modulation_term_offset =
        read_u32(bad_transform, modulation_term_section_entry + 4);
    bad_transform.at(modulation_term_offset + 8) = 1;
    refresh_crc(bad_transform);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_transform.data(), bad_transform.size());
      (void)invalid;
    }, "unsupported modulation transform was accepted");

    std::vector<uint8_t> bad_reserved = image_a;
    bad_reserved.at(12) = 1;
    refresh_crc(bad_reserved);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_reserved.data(), bad_reserved.size());
      (void)invalid;
    }, "nonzero command-interface legacy field was accepted");

    render::McuSf2AssetProfile wrong_profile = render::reference_mcu_sf2_asset_profile();
    ++wrong_profile.control_tick_samples;
    require_failure([&] {
      render::McuSf2AssetView invalid(image_a.data(), image_a.size(), wrong_profile);
      (void)invalid;
    }, "wrong output profile was accepted");

    sf2.file_words.at(0) ^= 1;
    require(!view.matches_source(sf2, source_size), "source mismatch was not detected");

    std::cout << "PASS: MCU SF2 compact-v2 image is deterministic, equivalent, "
                 "and validated\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "mcu_sf2_asset_test failed: " << error.what() << '\n';
    return 1;
  }
}
