#pragma once

#include "mcu_sf2_modulation.h"
#include "sf2_loader.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
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
  kPresetDispatch = 6,
  kKeyDispatch = 7,
  kVelocitySpans = 8,
  kLayerReferences = 9,
  kMonoDescriptors = 10,
  kStartWords = 11,
  kCandidatePrograms = 12,
  kModulationPrograms = 13,
  kModulationTerms = 14,
  kSourceCurves = 15,
};

struct McuSf2PresetDispatch {
  uint16_t program = 0;
  uint16_t bank = 0;
  uint32_t semantic_preset = 0;
  uint32_t first_key = 0;
};

struct McuSf2KeyDispatch {
  uint32_t first_span = 0;
  uint16_t span_count = 0;
};

struct McuSf2VelocitySpan {
  uint8_t velocity_low = 1;
  uint8_t velocity_high = 127;
  uint16_t layer_count = 0;
  uint32_t first_layer = 0;
};

struct McuSf2MonoDescriptor {
  uint32_t semantic_candidate = 0;
  uint32_t first_start_word = 0;
  uint8_t start_word_count = 0;
  uint8_t key = 0;
  uint8_t exclusive_class = 0;
  int8_t effective_velocity = -1;
  uint16_t base_gain = 0;
  int16_t pan = 0;
};

enum class McuSf2ModulationFamily : uint8_t {
  kGain = 0,
  kPitch = 1,
  kFilter = 2,
};

struct McuSf2CandidatePrograms {
  uint32_t gain = UINT32_MAX;
  uint32_t pitch = UINT32_MAX;
  uint32_t filter = UINT32_MAX;
};

struct McuSf2ModulationProgram {
  uint32_t first_term = 0;
  uint16_t term_count = 0;
  uint16_t note_static_term_count = 0;
  uint16_t dependencies = 0;
  McuSf2ModulationFamily family = McuSf2ModulationFamily::kGain;
};

struct McuSf2AssetProfile {
  std::string id;
  uint32_t command_interface_version = 0;
  uint32_t sample_rate = 0;
  uint32_t control_tick_samples = 0;
};

struct McuSf2AssetSelection {
  // Empty means every playable preset. Entries are (bank, program).
  std::vector<std::pair<uint16_t, uint16_t>> presets;
};

const McuSf2AssetProfile& reference_mcu_sf2_asset_profile();

uint32_t mcu_sf2_asset_image_crc(const uint8_t* data, size_t size);
std::vector<uint8_t> build_mcu_sf2_asset(const Sf2Data& sf2,
                                         uint64_t source_size_bytes,
                                         const McuSf2AssetProfile& profile =
                                             reference_mcu_sf2_asset_profile(),
                                         const McuSf2AssetSelection& selection = {});

class McuSf2AssetView {
 public:
  McuSf2AssetView(const uint8_t* data, size_t size,
                  const McuSf2AssetProfile& profile =
                      reference_mcu_sf2_asset_profile());

  uint64_t source_size_bytes() const { return source_size_bytes_; }
  uint32_t source_crc32() const { return source_crc32_; }
  uint32_t sample_word_offset() const { return sample_word_offset_; }
  uint32_t sample_word_count() const { return sample_word_count_; }
  uint32_t selection_crc32() const { return selection_crc32_; }
  uint32_t selected_preset_count() const { return selected_preset_count_; }

  size_t preset_count() const;
  size_t candidate_count() const;
  size_t generator_count() const;
  size_t modulator_count() const;
  size_t sample_count() const;
  bool has_dispatch() const { return has_dispatch_; }
  size_t preset_dispatch_count() const;
  size_t key_dispatch_count() const;
  size_t velocity_span_count() const;
  size_t layer_reference_count() const;
  size_t mono_descriptor_count() const;
  size_t start_word_count() const;
  bool has_modulation_programs() const { return has_modulation_programs_; }
  size_t candidate_program_count() const;
  size_t modulation_program_count() const;
  size_t modulation_term_count() const;
  size_t source_curve_value_count() const;

  Sf2SemanticPreset preset(size_t index) const;
  Sf2SemanticCandidate candidate(size_t index) const;
  Sf2SemanticGenerator generator(size_t index) const;
  Sf2Modulator modulator(size_t index) const;
  Sf2SemanticSample sample(size_t index) const;
  McuSf2PresetDispatch preset_dispatch(size_t index) const;
  McuSf2KeyDispatch key_dispatch(size_t index) const;
  McuSf2VelocitySpan velocity_span(size_t index) const;
  uint32_t layer_reference(size_t index) const;
  McuSf2MonoDescriptor mono_descriptor(size_t index) const;
  uint32_t start_word(size_t index) const;
  McuSf2CandidatePrograms candidate_programs(size_t index) const;
  McuSf2ModulationProgram modulation_program(size_t index) const;
  McuSf2ModulationTerm modulation_term(size_t index) const;
  int32_t source_curve_value(size_t index) const;

  int32_t find_preset_dispatch(int program, int bank) const;
  McuSf2VelocitySpan find_velocity_span(size_t preset_dispatch_index,
                                        int key, int velocity) const;

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
  std::array<SectionView, 15> sections_{};
  uint64_t source_size_bytes_ = 0;
  uint32_t source_crc32_ = 0;
  uint32_t sample_word_offset_ = 0;
  uint32_t sample_word_count_ = 0;
  uint32_t selection_crc32_ = 0;
  uint32_t selected_preset_count_ = 0;
  bool has_dispatch_ = false;
  bool has_modulation_programs_ = false;
};

}  // namespace render
