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

constexpr uint16_t kMcuSf2AssetFormatVersion = 2;
constexpr size_t kMcuSf2AssetHeaderSize = 96;
constexpr size_t kMcuSf2AssetImageCrcOffset = 36;
constexpr size_t kMcuSf2AssetSectionDirectoryOffset = 96;
constexpr size_t kMcuSf2AssetSectionEntrySize = 16;

enum class McuSf2AssetSection : uint16_t {
  kPresets = 1,
  kZones = 2,
  kGenerators = 3,
  kSamples = 4,
  kCandidatePrograms = 5,
  kModulationPrograms = 6,
  kModulationTerms = 7,
};

struct McuSf2Preset {
  uint16_t program = 0;
  uint16_t bank = 0;
  uint32_t first_zone = 0;
  uint32_t zone_count = 0;
};

struct McuSf2Zone {
  uint8_t key_low = 0;
  uint8_t key_high = 127;
  uint8_t velocity_low = 0;
  uint8_t velocity_high = 127;
  uint32_t first_generator = 0;
  uint16_t generator_count = 0;
  uint16_t sample_index = 0;
  uint64_t generator_presence = 0;
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

struct McuSf2RuntimeConfig {
  uint32_t mod_lfo_delay_ticks = 0;
  uint32_t mod_lfo_step = 0;
  uint32_t vib_lfo_delay_ticks = 0;
  uint32_t vib_lfo_step = 0;
  int16_t mod_lfo_to_pitch = 0;
  int16_t vib_lfo_to_pitch = 0;
  int16_t mod_env_to_pitch = 0;
  int16_t mod_lfo_to_filter_fc = 0;
  int16_t mod_env_to_filter_fc = 0;
  int16_t mod_lfo_to_volume = 0;
  int16_t initial_filter_fc = 13500;
  int16_t initial_filter_q = 0;
  uint32_t mod_env_delay_ticks = 0;
  uint32_t mod_env_hold_ticks = 0;
  uint32_t mod_env_attack_ticks = 1;
  uint32_t mod_env_decay_ticks = 1;
  uint32_t mod_env_release_ticks = 1;
  uint16_t mod_env_sustain_level = render::kQ15Full;
  bool mod_env_attack_sub_tick = false;
};

struct McuSf2AssetProfile {
  std::string id;
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
  uint32_t sample_rate() const { return sample_rate_; }
  uint32_t selection_crc32() const { return selection_crc32_; }
  uint32_t selected_preset_count() const { return selected_preset_count_; }

  size_t preset_count() const;
  size_t zone_count() const;
  size_t generator_count() const;
  size_t sample_count() const;
  size_t candidate_program_count() const;
  size_t modulation_program_count() const;
  size_t modulation_term_count() const;
  size_t section_bytes(McuSf2AssetSection type) const;

  McuSf2Preset preset(size_t index) const;
  McuSf2Zone zone(size_t index) const;
  uint16_t generator_amount(size_t index) const;
  Sf2SemanticSample sample(size_t index) const;
  McuSf2CandidatePrograms candidate_programs(size_t index) const;
  McuSf2ModulationProgram modulation_program(size_t index) const;
  McuSf2ModulationTerm modulation_term(size_t index) const;

  int32_t find_preset(int program, int bank) const;
  Region materialize_zone(size_t zone_index, int key) const;

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
  std::array<SectionView, 7> sections_{};
  uint64_t source_size_bytes_ = 0;
  uint32_t source_crc32_ = 0;
  uint32_t sample_word_offset_ = 0;
  uint32_t sample_word_count_ = 0;
  uint32_t sample_rate_ = 0;
  uint32_t control_tick_samples_ = 0;
  uint32_t selection_crc32_ = 0;
  uint32_t selected_preset_count_ = 0;
};

McuSf2RuntimeConfig mcu_sf2_runtime_config(const Region& region);

}  // namespace render
