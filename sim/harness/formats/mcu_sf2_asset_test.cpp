#include "mcu_sf2_asset.h"
#include "command_control.h"

#include <cstdint>
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

uint32_t read_u32(const std::vector<uint8_t>& data, size_t offset) {
  return uint32_t(data.at(offset)) | (uint32_t(data.at(offset + 1)) << 8) |
         (uint32_t(data.at(offset + 2)) << 16) |
         (uint32_t(data.at(offset + 3)) << 24);
}

void refresh_crc(std::vector<uint8_t>& data) {
  write_u32(data, render::kMcuSf2AssetImageCrcOffset, 0);
  write_u32(data, render::kMcuSf2AssetImageCrcOffset,
            render::mcu_sf2_asset_image_crc(data.data(), data.size()));
}

void compare_semantics(const render::Sf2SemanticData& expected,
                       const render::McuSf2AssetView& actual) {
  require(actual.preset_count() == expected.presets.size(), "preset count mismatch");
  require(actual.candidate_count() == expected.candidates.size(), "candidate count mismatch");
  require(actual.generator_count() == expected.generators.size(), "generator count mismatch");
  require(actual.modulator_count() == expected.modulators.size(), "modulator count mismatch");
  require(actual.sample_count() == expected.samples.size(), "sample count mismatch");

  for (size_t index = 0; index < expected.presets.size(); ++index) {
    const auto a = actual.preset(index);
    const auto& e = expected.presets[index];
    require(a.program == e.program && a.bank == e.bank &&
                a.first_candidate == e.first_candidate &&
                a.candidate_count == e.candidate_count,
            "preset record mismatch");
  }
  for (size_t index = 0; index < expected.candidates.size(); ++index) {
    const auto a = actual.candidate(index);
    const auto& e = expected.candidates[index];
    require(a.key_low == e.key_low && a.key_high == e.key_high &&
                a.velocity_low == e.velocity_low &&
                a.velocity_high == e.velocity_high &&
                a.instrument == e.instrument &&
                a.first_generator == e.first_generator &&
                a.generator_count == e.generator_count &&
                a.first_modulator == e.first_modulator &&
                a.modulator_count == e.modulator_count,
            "candidate record mismatch");
  }
  for (size_t index = 0; index < expected.generators.size(); ++index) {
    const auto a = actual.generator(index);
    const auto& e = expected.generators[index];
    require(a.oper == e.oper && a.amount == e.amount, "generator record mismatch");
  }
  for (size_t index = 0; index < expected.modulators.size(); ++index) {
    const auto a = actual.modulator(index);
    const auto& e = expected.modulators[index];
    require(a.src == e.src && a.dest == e.dest && a.amount == e.amount &&
                a.amount_src == e.amount_src && a.transform == e.transform,
            "modulator record mismatch");
  }
  for (size_t index = 0; index < expected.samples.size(); ++index) {
    const auto a = actual.sample(index);
    const auto& e = expected.samples[index];
    require(a.start == e.start && a.end == e.end &&
                a.start_loop == e.start_loop && a.end_loop == e.end_loop &&
                a.sample_rate == e.sample_rate &&
                a.original_pitch == e.original_pitch &&
                a.pitch_correction == e.pitch_correction &&
                a.sample_link == e.sample_link && a.sample_type == e.sample_type,
            "sample record mismatch");
  }
}

void compare_dispatch(const render::Sf2Data& sf2,
                      const render::Sf2SemanticData& semantic,
                      const render::McuSf2AssetView& view) {
  require(view.has_dispatch(), "asset has no direct dispatch tables");
  require(view.key_dispatch_count() == view.preset_dispatch_count() * 128u,
          "direct key table size mismatch");

  for (size_t dispatch_index = 0; dispatch_index < view.preset_dispatch_count();
       ++dispatch_index) {
    const auto dispatch = view.preset_dispatch(dispatch_index);
    require(view.find_preset_dispatch(dispatch.program, dispatch.bank) ==
                int32_t(dispatch_index),
            "sparse preset lookup mismatch");
    const auto& preset = semantic.presets.at(dispatch.semantic_preset);
    for (int key = 0; key < 128; ++key) {
      for (int velocity = 1; velocity < 128; ++velocity) {
        std::vector<uint32_t> expected_candidates;
        for (uint32_t local = 0; local < preset.candidate_count; ++local) {
          const uint32_t candidate_index = preset.first_candidate + local;
          const auto& candidate = semantic.candidates.at(candidate_index);
          if (key >= candidate.key_low && key <= candidate.key_high &&
              velocity >= candidate.velocity_low &&
              velocity <= candidate.velocity_high) {
            expected_candidates.push_back(candidate_index);
          }
        }
        const auto span = view.find_velocity_span(dispatch_index, key, velocity);
        require(span.layer_count == expected_candidates.size(),
                "velocity dispatch layer count mismatch");
        for (uint32_t layer = 0; layer < span.layer_count; ++layer) {
          const uint32_t descriptor_index =
              view.layer_reference(span.first_layer + layer);
          const auto descriptor = view.mono_descriptor(descriptor_index);
          require(descriptor.semantic_candidate == expected_candidates[layer] &&
                      descriptor.key == key,
                  "velocity dispatch layer ordering mismatch");
        }
      }
    }
  }

  std::vector<uint32_t> candidate_preset(semantic.candidates.size());
  std::vector<uint32_t> candidate_local(semantic.candidates.size());
  for (size_t preset_index = 0; preset_index < semantic.presets.size(); ++preset_index) {
    const auto& preset = semantic.presets[preset_index];
    for (uint32_t local = 0; local < preset.candidate_count; ++local) {
      candidate_preset[preset.first_candidate + local] = uint32_t(preset_index);
      candidate_local[preset.first_candidate + local] = local;
    }
  }

  LatestCommandSink sink;
  render::CommandVoiceControl control(sink);
  for (size_t index = 0; index < view.mono_descriptor_count(); ++index) {
    const auto descriptor = view.mono_descriptor(index);
    const render::Region region = render::make_region_for_compiled_candidate(
        sf2, candidate_preset.at(descriptor.semantic_candidate),
        candidate_local.at(descriptor.semantic_candidate), descriptor.key,
        int(render::reference_mcu_sf2_asset_profile().sample_rate),
        int(render::reference_mcu_sf2_asset_profile().control_tick_samples));
    const int voice = int(index % render::kNumVoices);
    control.start_voice(voice, region.phase_inc, region);
    require(sink.latest.size() == descriptor.start_word_count,
            "START template word count mismatch");
    sink.latest[0] &= ~(0x3ffu << 14);
    sink.latest[1] = 1;
    for (uint32_t word = 0; word < descriptor.start_word_count; ++word) {
      require(sink.latest[word] ==
                  view.start_word(descriptor.first_start_word + word),
              "START template word mismatch");
    }
    require(descriptor.base_gain == region.base_gain && descriptor.pan == region.pan &&
                descriptor.exclusive_class == region.exclusive_class &&
                descriptor.effective_velocity == region.effective_velocity,
            "mono descriptor policy field mismatch");
  }
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
    compare_semantics(semantic, view);
    compare_dispatch(sf2, semantic, view);
    require(view.find_preset_dispatch(127, 16383) == -1,
            "missing sparse preset lookup did not fail");

    require(semantic.presets.size() >= 2, "fixture needs multiple presets for pruning test");
    render::McuSf2AssetSelection subset;
    subset.presets.emplace_back(semantic.presets[0].bank, semantic.presets[0].program);
    const std::vector<uint8_t> subset_image = render::build_mcu_sf2_asset(
        sf2, source_size, render::reference_mcu_sf2_asset_profile(), subset);
    const render::McuSf2AssetView subset_view(subset_image.data(), subset_image.size());
    require(subset_view.preset_count() == 1 && subset_view.preset_dispatch_count() == 1 &&
                subset_view.selected_preset_count() == 1 &&
                subset_view.selection_crc32() != 0,
            "preset subset was not recorded");
    require(subset_view.find_preset_dispatch(semantic.presets[0].program,
                                             semantic.presets[0].bank) == 0,
            "selected preset is not dispatchable");
    require(subset_view.find_preset_dispatch(semantic.presets[1].program,
                                             semantic.presets[1].bank) == -1,
            "unselected preset remained dispatchable");
    require(subset_view.candidate_count() < view.candidate_count() &&
                subset_view.generator_count() < view.generator_count() &&
                subset_view.modulator_count() < view.modulator_count() &&
                subset_view.sample_count() <= view.sample_count() &&
                subset_image.size() < image_a.size(),
            "preset subset did not prune reachable metadata");
    for (size_t candidate_index = 0; candidate_index < subset_view.candidate_count();
         ++candidate_index) {
      const auto candidate = subset_view.candidate(candidate_index);
      for (uint32_t generator_index = 0; generator_index < candidate.generator_count;
           ++generator_index) {
        const auto generator = subset_view.generator(candidate.first_generator + generator_index);
        if (generator.oper == 53) {
          require(generator.amount < subset_view.sample_count(),
                  "pruned sample reference was not remapped");
        }
      }
    }

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

    std::vector<uint8_t> bad_crc = image_a;
    bad_crc.back() ^= 0x80;
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
    const size_t first_candidate_entry = render::kMcuSf2AssetSectionDirectoryOffset +
        render::kMcuSf2AssetSectionEntrySize;
    write_u32(bad_reference, first_candidate_entry + 8, 0);
    refresh_crc(bad_reference);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_reference.data(), bad_reference.size());
      (void)invalid;
    }, "invalid cross-section reference was accepted");

    std::vector<uint8_t> bad_layer = image_a;
    const size_t layer_section_entry = render::kMcuSf2AssetSectionDirectoryOffset +
        8 * render::kMcuSf2AssetSectionEntrySize;
    const uint32_t first_layer_offset = read_u32(bad_layer, layer_section_entry + 4);
    write_u32(bad_layer, first_layer_offset, uint32_t(view.mono_descriptor_count()));
    refresh_crc(bad_layer);
    require_failure([&] {
      render::McuSf2AssetView invalid(bad_layer.data(), bad_layer.size());
      (void)invalid;
    }, "invalid layer descriptor reference was accepted");

    render::McuSf2AssetProfile wrong_profile = render::reference_mcu_sf2_asset_profile();
    ++wrong_profile.control_tick_samples;
    require_failure([&] {
      render::McuSf2AssetView invalid(image_a.data(), image_a.size(), wrong_profile);
      (void)invalid;
    }, "wrong output profile was accepted");

    sf2.file_words.at(0) ^= 1;
    require(!view.matches_source(sf2, source_size), "source mismatch was not detected");

    std::cout << "PASS: MCU SF2 semantic image and direct dispatch are deterministic, "
                 "equivalent, and validated\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "mcu_sf2_asset_test failed: " << error.what() << '\n';
    return 1;
  }
}
