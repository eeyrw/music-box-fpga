#include "mcu_sf2_asset.h"

#include <cstdint>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

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

    render::McuSf2AssetProfile wrong_profile = render::reference_mcu_sf2_asset_profile();
    ++wrong_profile.control_tick_samples;
    require_failure([&] {
      render::McuSf2AssetView invalid(image_a.data(), image_a.size(), wrong_profile);
      (void)invalid;
    }, "wrong output profile was accepted");

    sf2.file_words.at(0) ^= 1;
    require(!view.matches_source(sf2, source_size), "source mismatch was not detected");

    std::cout << "PASS: MCU SF2 semantic image deterministic, equivalent, and validated\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "mcu_sf2_asset_test failed: " << error.what() << '\n';
    return 1;
  }
}
