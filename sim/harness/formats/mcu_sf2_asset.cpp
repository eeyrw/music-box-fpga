#include "mcu_sf2_asset.h"

#include "generated/mcu_asset_profile.h"
#include "generated/register_map.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>

namespace render {
namespace {

constexpr uint32_t kAssetFlagSourceCrc32 = 1u;
constexpr uint32_t kPresetStride = 16;
constexpr uint32_t kCandidateStride = 24;
constexpr uint32_t kGeneratorStride = 4;
constexpr uint32_t kModulatorStride = 10;
constexpr uint32_t kSampleStride = 28;
constexpr size_t kSectionCount = 5;

uint16_t read_u16(const uint8_t* data) {
  return uint16_t(data[0]) | (uint16_t(data[1]) << 8);
}

uint32_t read_u32(const uint8_t* data) {
  return uint32_t(data[0]) | (uint32_t(data[1]) << 8) |
         (uint32_t(data[2]) << 16) | (uint32_t(data[3]) << 24);
}

uint64_t read_u64(const uint8_t* data) {
  return uint64_t(read_u32(data)) | (uint64_t(read_u32(data + 4)) << 32);
}

void write_u16(std::vector<uint8_t>& data, size_t offset, uint16_t value) {
  data.at(offset) = uint8_t(value);
  data.at(offset + 1) = uint8_t(value >> 8);
}

void write_u32(std::vector<uint8_t>& data, size_t offset, uint32_t value) {
  for (int byte = 0; byte < 4; ++byte) data.at(offset + size_t(byte)) = uint8_t(value >> (8 * byte));
}

void write_u64(std::vector<uint8_t>& data, size_t offset, uint64_t value) {
  write_u32(data, offset, uint32_t(value));
  write_u32(data, offset + 4, uint32_t(value >> 32));
}

void append_u16(std::vector<uint8_t>& data, uint16_t value) {
  data.push_back(uint8_t(value));
  data.push_back(uint8_t(value >> 8));
}

void append_u32(std::vector<uint8_t>& data, uint32_t value) {
  for (int byte = 0; byte < 4; ++byte) data.push_back(uint8_t(value >> (8 * byte)));
}

uint32_t crc32_update(uint32_t crc, uint8_t value) {
  static const std::array<uint32_t, 256> table = [] {
    std::array<uint32_t, 256> values{};
    for (uint32_t index = 0; index < values.size(); ++index) {
      uint32_t entry = index;
      for (int bit = 0; bit < 8; ++bit) {
        entry = (entry >> 1) ^ ((entry & 1u) != 0 ? 0xedb88320u : 0u);
      }
      values[index] = entry;
    }
    return values;
  }();
  return (crc >> 8) ^ table[(crc ^ value) & 0xffu];
}

uint32_t crc32_bytes(const uint8_t* data, size_t size) {
  uint32_t crc = 0xffffffffu;
  for (size_t index = 0; index < size; ++index) crc = crc32_update(crc, data[index]);
  return crc ^ 0xffffffffu;
}

uint32_t crc32_string(const std::string& value) {
  return crc32_bytes(reinterpret_cast<const uint8_t*>(value.data()), value.size());
}

uint32_t sf2_source_crc32(const Sf2Data& sf2, uint64_t source_size_bytes) {
  if (source_size_bytes > uint64_t(sf2.file_words.size()) * 2u) {
    throw std::runtime_error("SF2 source size exceeds retained word image");
  }
  uint32_t crc = 0xffffffffu;
  for (uint64_t byte = 0; byte < source_size_bytes; ++byte) {
    const uint16_t word = uint16_t(sf2.file_words.at(size_t(byte / 2)));
    crc = crc32_update(crc, uint8_t(word >> ((byte & 1u) * 8u)));
  }
  return crc ^ 0xffffffffu;
}

uint32_t checked_u32(size_t value, const char* label) {
  if (value > std::numeric_limits<uint32_t>::max()) {
    throw std::runtime_error(std::string(label) + " exceeds 32-bit asset format");
  }
  return uint32_t(value);
}

struct SectionBuild {
  McuSf2AssetSection type;
  uint32_t stride;
  uint32_t offset = 0;
  uint32_t count = 0;
};

void align_four(std::vector<uint8_t>& data) {
  while ((data.size() & 3u) != 0) data.push_back(0);
}

void validate_range(uint32_t first, uint32_t count, uint32_t total, const char* label) {
  if (uint64_t(first) + count > total) {
    throw std::runtime_error(std::string(label) + " range exceeds referenced section");
  }
}

}  // namespace

const McuSf2AssetProfile& reference_mcu_sf2_asset_profile() {
  static const McuSf2AssetProfile profile = {
      mcu_asset_profile::kId, mcu_asset_profile::kCommandInterfaceVersion,
      mcu_asset_profile::kOutputSampleRate, mcu_asset_profile::kControlTickSamples};
  if (profile.command_interface_version != regs::kVersionValue) {
    throw std::runtime_error("generated MCU asset profile interface mismatch");
  }
  return profile;
}

uint32_t mcu_sf2_asset_image_crc(const uint8_t* data, size_t size) {
  if (data == nullptr || size < kMcuSf2AssetImageCrcOffset + 4) {
    throw std::runtime_error("MCU SF2 asset is too short for CRC");
  }
  uint32_t crc = 0xffffffffu;
  for (size_t index = 0; index < size; ++index) {
    const uint8_t value = index >= kMcuSf2AssetImageCrcOffset &&
                                  index < kMcuSf2AssetImageCrcOffset + 4
                              ? 0
                              : data[index];
    crc = crc32_update(crc, value);
  }
  return crc ^ 0xffffffffu;
}

std::vector<uint8_t> build_mcu_sf2_asset(const Sf2Data& sf2,
                                         uint64_t source_size_bytes,
                                         const McuSf2AssetProfile& profile) {
  if (profile.id.empty() || profile.command_interface_version == 0 ||
      profile.sample_rate == 0 || profile.control_tick_samples == 0) {
    throw std::runtime_error("invalid MCU SF2 asset profile");
  }
  const Sf2SemanticData semantic = compile_sf2_semantics(sf2);
  std::vector<uint8_t> image(kMcuSf2AssetHeaderSize +
                             kSectionCount * kMcuSf2AssetSectionEntrySize, 0);
  std::array<SectionBuild, kSectionCount> sections{{
      {McuSf2AssetSection::kPresets, kPresetStride},
      {McuSf2AssetSection::kCandidates, kCandidateStride},
      {McuSf2AssetSection::kGenerators, kGeneratorStride},
      {McuSf2AssetSection::kModulators, kModulatorStride},
      {McuSf2AssetSection::kSamples, kSampleStride},
  }};

  auto start_section = [&](size_t section, size_t count) {
    align_four(image);
    sections[section].offset = checked_u32(image.size(), "section offset");
    sections[section].count = checked_u32(count, "section count");
  };

  start_section(0, semantic.presets.size());
  for (const auto& preset : semantic.presets) {
    append_u16(image, preset.program);
    append_u16(image, preset.bank);
    append_u32(image, preset.first_candidate);
    append_u32(image, preset.candidate_count);
    append_u32(image, 0);
  }

  start_section(1, semantic.candidates.size());
  for (const auto& candidate : semantic.candidates) {
    image.push_back(candidate.key_low);
    image.push_back(candidate.key_high);
    image.push_back(candidate.velocity_low);
    image.push_back(candidate.velocity_high);
    append_u32(image, candidate.instrument);
    append_u32(image, candidate.first_generator);
    append_u32(image, candidate.generator_count);
    append_u32(image, candidate.first_modulator);
    append_u32(image, candidate.modulator_count);
  }

  start_section(2, semantic.generators.size());
  for (const auto& generator : semantic.generators) {
    append_u16(image, generator.oper);
    append_u16(image, generator.amount);
  }

  start_section(3, semantic.modulators.size());
  for (const auto& modulator : semantic.modulators) {
    append_u16(image, modulator.src);
    append_u16(image, modulator.dest);
    append_u16(image, uint16_t(modulator.amount));
    append_u16(image, modulator.amount_src);
    append_u16(image, modulator.transform);
  }

  start_section(4, semantic.samples.size());
  for (const auto& sample : semantic.samples) {
    append_u32(image, sample.start);
    append_u32(image, sample.end);
    append_u32(image, sample.start_loop);
    append_u32(image, sample.end_loop);
    append_u32(image, sample.sample_rate);
    image.push_back(sample.original_pitch);
    image.push_back(uint8_t(sample.pitch_correction));
    append_u16(image, sample.sample_link);
    append_u16(image, sample.sample_type);
    append_u16(image, 0);
  }
  align_four(image);

  if (image.size() > std::numeric_limits<uint32_t>::max()) {
    throw std::runtime_error("MCU SF2 asset exceeds 32-bit image size");
  }
  std::memcpy(image.data(), "MSF2", 4);
  write_u16(image, 4, kMcuSf2AssetFormatVersion);
  write_u16(image, 6, uint16_t(kMcuSf2AssetHeaderSize));
  write_u32(image, 8, uint32_t(image.size()));
  write_u32(image, 12, profile.command_interface_version);
  write_u32(image, 16, profile.sample_rate);
  write_u32(image, 20, profile.control_tick_samples);
  write_u64(image, 24, source_size_bytes);
  write_u32(image, 32, sf2_source_crc32(sf2, source_size_bytes));
  write_u32(image, 40, uint32_t(kMcuSf2AssetSectionDirectoryOffset));
  write_u16(image, 44, uint16_t(kSectionCount));
  write_u32(image, 48, sf2.smpl_word_offset);
  write_u32(image, 52, sf2.smpl_word_count);
  write_u32(image, 56, crc32_string(profile.id));
  write_u32(image, 60, kAssetFlagSourceCrc32);

  for (size_t index = 0; index < sections.size(); ++index) {
    const size_t offset = kMcuSf2AssetSectionDirectoryOffset +
                          index * kMcuSf2AssetSectionEntrySize;
    write_u16(image, offset, uint16_t(sections[index].type));
    write_u16(image, offset + 2, 1);
    write_u32(image, offset + 4, sections[index].offset);
    write_u32(image, offset + 8, sections[index].count);
    write_u32(image, offset + 12, sections[index].stride);
  }
  write_u32(image, kMcuSf2AssetImageCrcOffset,
            mcu_sf2_asset_image_crc(image.data(), image.size()));
  return image;
}

McuSf2AssetView::McuSf2AssetView(const uint8_t* data, size_t size,
                                 const McuSf2AssetProfile& profile)
    : data_(data), size_(size) {
  if (data == nullptr || size < kMcuSf2AssetHeaderSize) {
    throw std::runtime_error("MCU SF2 asset header is truncated");
  }
  if (std::memcmp(data, "MSF2", 4) != 0) throw std::runtime_error("bad MCU SF2 asset magic");
  if (read_u16(data + 4) != kMcuSf2AssetFormatVersion) {
    throw std::runtime_error("unsupported MCU SF2 asset version");
  }
  if (read_u16(data + 6) != kMcuSf2AssetHeaderSize || read_u32(data + 8) != size) {
    throw std::runtime_error("MCU SF2 asset size/header mismatch");
  }
  if (read_u32(data + 12) != profile.command_interface_version ||
      read_u32(data + 16) != profile.sample_rate ||
      read_u32(data + 20) != profile.control_tick_samples ||
      read_u32(data + 56) != crc32_string(profile.id)) {
    throw std::runtime_error("MCU SF2 asset profile mismatch");
  }
  if (read_u32(data + kMcuSf2AssetImageCrcOffset) !=
      mcu_sf2_asset_image_crc(data, size)) {
    throw std::runtime_error("MCU SF2 asset CRC mismatch");
  }
  if (read_u32(data + 60) != kAssetFlagSourceCrc32) {
    throw std::runtime_error("unsupported MCU SF2 asset flags");
  }

  source_size_bytes_ = read_u64(data + 24);
  source_crc32_ = read_u32(data + 32);
  sample_word_offset_ = read_u32(data + 48);
  sample_word_count_ = read_u32(data + 52);
  if (uint64_t(sample_word_offset_) * 2u + uint64_t(sample_word_count_) * 2u >
      source_size_bytes_) {
    throw std::runtime_error("MCU SF2 asset sample span exceeds source image");
  }
  const uint32_t directory_offset = read_u32(data + 40);
  const uint16_t section_count = read_u16(data + 44);
  if (directory_offset != kMcuSf2AssetSectionDirectoryOffset ||
      section_count != kSectionCount ||
      uint64_t(directory_offset) + uint64_t(section_count) * kMcuSf2AssetSectionEntrySize > size) {
    throw std::runtime_error("invalid MCU SF2 asset section directory");
  }

  const std::array<uint32_t, kSectionCount> expected_strides = {
      kPresetStride, kCandidateStride, kGeneratorStride, kModulatorStride, kSampleStride};
  uint64_t previous_end = kMcuSf2AssetHeaderSize +
                          kSectionCount * kMcuSf2AssetSectionEntrySize;
  std::array<bool, kSectionCount> seen{};
  for (size_t index = 0; index < section_count; ++index) {
    const uint8_t* entry = data + directory_offset + index * kMcuSf2AssetSectionEntrySize;
    const uint16_t raw_type = read_u16(entry);
    const uint16_t flags = read_u16(entry + 2);
    const uint32_t offset = read_u32(entry + 4);
    const uint32_t count = read_u32(entry + 8);
    const uint32_t stride = read_u32(entry + 12);
    if (raw_type == 0 || raw_type > kSectionCount || seen[raw_type - 1] || flags != 1) {
      throw std::runtime_error("invalid or duplicate MCU SF2 asset section type");
    }
    const size_t slot = raw_type - 1;
    if (stride != expected_strides[slot] || (offset & 3u) != 0) {
      throw std::runtime_error("invalid MCU SF2 asset section stride/alignment");
    }
    const uint64_t end = uint64_t(offset) + uint64_t(count) * stride;
    if (offset < previous_end || end > size) {
      throw std::runtime_error("overlapping or out-of-bounds MCU SF2 asset section");
    }
    sections_[slot] = {data + offset, count, stride};
    seen[slot] = true;
    previous_end = end;
  }
  if (std::find(seen.begin(), seen.end(), false) != seen.end()) {
    throw std::runtime_error("missing required MCU SF2 asset section");
  }

  for (size_t index = 0; index < preset_count(); ++index) {
    const auto value = preset(index);
    validate_range(value.first_candidate, value.candidate_count,
                   uint32_t(candidate_count()), "preset candidate");
  }
  for (size_t index = 0; index < candidate_count(); ++index) {
    const auto value = candidate(index);
    if (value.key_low > value.key_high || value.velocity_low > value.velocity_high) {
      throw std::runtime_error("invalid MCU SF2 asset candidate range");
    }
    validate_range(value.first_generator, value.generator_count,
                   uint32_t(generator_count()), "candidate generator");
    validate_range(value.first_modulator, value.modulator_count,
                   uint32_t(modulator_count()), "candidate modulator");
  }
  for (size_t index = 0; index < sample_count(); ++index) {
    const auto value = sample(index);
    if (value.start > value.end || value.end > sample_word_count_ ||
        value.start_loop > value.end_loop || value.end_loop > value.end) {
      throw std::runtime_error("invalid MCU SF2 asset sample bounds");
    }
  }
}

const McuSf2AssetView::SectionView& McuSf2AssetView::section(McuSf2AssetSection type) const {
  return sections_.at(size_t(uint16_t(type) - 1));
}

const uint8_t* McuSf2AssetView::record(const SectionView& value, size_t index) const {
  if (index >= value.count) throw std::out_of_range("MCU SF2 asset record index");
  return value.data + index * value.stride;
}

size_t McuSf2AssetView::preset_count() const { return section(McuSf2AssetSection::kPresets).count; }
size_t McuSf2AssetView::candidate_count() const { return section(McuSf2AssetSection::kCandidates).count; }
size_t McuSf2AssetView::generator_count() const { return section(McuSf2AssetSection::kGenerators).count; }
size_t McuSf2AssetView::modulator_count() const { return section(McuSf2AssetSection::kModulators).count; }
size_t McuSf2AssetView::sample_count() const { return section(McuSf2AssetSection::kSamples).count; }

Sf2SemanticPreset McuSf2AssetView::preset(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kPresets), index);
  return {read_u16(value), read_u16(value + 2), read_u32(value + 4), read_u32(value + 8)};
}

Sf2SemanticCandidate McuSf2AssetView::candidate(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kCandidates), index);
  return {value[0], value[1], value[2], value[3], read_u32(value + 4),
          read_u32(value + 8), read_u32(value + 12), read_u32(value + 16),
          read_u32(value + 20)};
}

Sf2SemanticGenerator McuSf2AssetView::generator(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kGenerators), index);
  return {read_u16(value), read_u16(value + 2)};
}

Sf2Modulator McuSf2AssetView::modulator(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kModulators), index);
  return {read_u16(value), read_u16(value + 2), int16_t(read_u16(value + 4)),
          read_u16(value + 6), read_u16(value + 8)};
}

Sf2SemanticSample McuSf2AssetView::sample(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kSamples), index);
  return {read_u32(value), read_u32(value + 4), read_u32(value + 8),
          read_u32(value + 12), read_u32(value + 16), value[20], int8_t(value[21]),
          read_u16(value + 22), read_u16(value + 24)};
}

bool McuSf2AssetView::matches_source(const Sf2Data& sf2, uint64_t source_size_bytes) const {
  return source_size_bytes == source_size_bytes_ &&
         sf2_source_crc32(sf2, source_size_bytes) == source_crc32_ &&
         sf2.smpl_word_offset == sample_word_offset_ &&
         sf2.smpl_word_count == sample_word_count_;
}

}  // namespace render
