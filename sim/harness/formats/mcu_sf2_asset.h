#pragma once

#include "sf2_loader.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace render {

constexpr uint16_t kMcuSf2AssetFormatVersion = 1;
constexpr size_t kMcuSf2AssetHeaderSize = 96;
constexpr size_t kMcuSf2AssetImageCrcOffset = 36;
constexpr size_t kMcuSf2AssetSectionDirectoryOffset = 96;
constexpr size_t kMcuSf2AssetSectionEntrySize = 16;

enum class McuSf2AssetSection : uint16_t {
  kPresets = 1,
  kCandidates = 2,
  kGenerators = 3,
  kModulators = 4,
  kSamples = 5,
};

struct McuSf2AssetProfile {
  std::string id;
  uint32_t command_interface_version = 0;
  uint32_t sample_rate = 0;
  uint32_t control_tick_samples = 0;
};

const McuSf2AssetProfile& reference_mcu_sf2_asset_profile();

uint32_t mcu_sf2_asset_image_crc(const uint8_t* data, size_t size);
std::vector<uint8_t> build_mcu_sf2_asset(const Sf2Data& sf2,
                                         uint64_t source_size_bytes,
                                         const McuSf2AssetProfile& profile =
                                             reference_mcu_sf2_asset_profile());

class McuSf2AssetView {
 public:
  McuSf2AssetView(const uint8_t* data, size_t size,
                  const McuSf2AssetProfile& profile =
                      reference_mcu_sf2_asset_profile());

  uint64_t source_size_bytes() const { return source_size_bytes_; }
  uint32_t source_crc32() const { return source_crc32_; }
  uint32_t sample_word_offset() const { return sample_word_offset_; }
  uint32_t sample_word_count() const { return sample_word_count_; }

  size_t preset_count() const;
  size_t candidate_count() const;
  size_t generator_count() const;
  size_t modulator_count() const;
  size_t sample_count() const;

  Sf2SemanticPreset preset(size_t index) const;
  Sf2SemanticCandidate candidate(size_t index) const;
  Sf2SemanticGenerator generator(size_t index) const;
  Sf2Modulator modulator(size_t index) const;
  Sf2SemanticSample sample(size_t index) const;

  bool matches_source(const Sf2Data& sf2, uint64_t source_size_bytes) const;

 private:
  struct SectionView {
    const uint8_t* data = nullptr;
    uint32_t count = 0;
    uint32_t stride = 0;
  };

  const SectionView& section(McuSf2AssetSection type) const;
  const uint8_t* record(const SectionView& section, size_t index) const;

  const uint8_t* data_ = nullptr;
  size_t size_ = 0;
  std::array<SectionView, 5> sections_{};
  uint64_t source_size_bytes_ = 0;
  uint32_t source_crc32_ = 0;
  uint32_t sample_word_offset_ = 0;
  uint32_t sample_word_count_ = 0;
};

}  // namespace render
