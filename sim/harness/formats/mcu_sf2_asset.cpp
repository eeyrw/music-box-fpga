#include "mcu_sf2_asset.h"

#include "generated/mcu_asset_profile.h"
#include "generated/register_map.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <map>
#include <stdexcept>
#include <string>

namespace render {
namespace {

constexpr uint32_t kAssetFlagSourceCrc32 = 1u;
constexpr uint32_t kCandidateProgramsStride = 3;
constexpr uint32_t kModulationProgramStride = 12;
constexpr uint32_t kModulationTermStride = 12;
constexpr uint16_t kGeneratorKeyRange = 43;
constexpr uint16_t kGeneratorVelocityRange = 44;
constexpr uint16_t kGeneratorSampleId = 53;
constexpr uint16_t kDefinedDependencyMask = 0x001fu;
constexpr uint64_t kValidGeneratorPresence =
    ((uint64_t(1) << 61) - 1) &
    ~(uint64_t(1) << kGeneratorKeyRange) &
    ~(uint64_t(1) << kGeneratorVelocityRange) &
    ~(uint64_t(1) << kGeneratorSampleId);

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
  uint16_t flags = 0;
  uint32_t offset = 0;
  uint32_t count = 0;
};


struct SelectedSemanticBuild {
  Sf2SemanticData semantic;
  uint32_t selection_crc32 = 0;
};

struct ModulationBuild {
  std::vector<McuSf2CandidatePrograms> candidates;
  std::vector<McuSf2ModulationProgram> programs;
  std::vector<McuSf2ModulationTerm> terms;
};

bool destination_in_family(uint16_t destination, McuSf2ModulationFamily family) {
  switch (family) {
    case McuSf2ModulationFamily::kGain:
      return destination == 13 || destination == 17 || destination == 48;
    case McuSf2ModulationFamily::kPitch:
      return destination == 0 || destination == 5 || destination == 6 || destination == 7;
    case McuSf2ModulationFamily::kFilter:
      return destination == 8 || destination == 10 || destination == 11;
  }
  return false;
}

std::vector<int64_t> modulation_program_key(
    McuSf2ModulationFamily family, const std::vector<McuSf2ModulationTerm>& terms) {
  std::vector<int64_t> key;
  key.reserve(1 + terms.size() * 3);
  key.push_back(int64_t(family));
  for (const auto& term : terms) {
    key.push_back(int64_t(term.source) | (int64_t(term.destination) << 16) |
                  (int64_t(uint16_t(term.amount)) << 32));
    key.push_back(int64_t(term.amount_source) | (int64_t(term.transform) << 16) |
                  (int64_t(term.dependencies) << 32));
  }
  return key;
}

ModulationBuild build_modulation(const Sf2SemanticData& semantic) {
  ModulationBuild result;
  std::map<std::vector<int64_t>, uint32_t> interned;
  result.candidates.reserve(semantic.candidates.size());
  for (const auto& candidate : semantic.candidates) {
    McuSf2CandidatePrograms references;
    for (int raw_family = 0; raw_family < 3; ++raw_family) {
      const auto family = McuSf2ModulationFamily(raw_family);
      std::vector<McuSf2ModulationTerm> terms;
      for (uint32_t index = 0; index < candidate.modulator_count; ++index) {
        const auto& source = semantic.modulators.at(candidate.first_modulator + index);
        if (source.amount == 0 || !destination_in_family(source.dest, family)) continue;
        McuSf2ModulationTerm term;
        term.source = source.src;
        term.destination = source.dest;
        term.amount = int16_t(source.amount);
        term.amount_source = source.amount_src;
        term.transform = source.transform;
        term.dependencies = mcu_sf2_source_dependencies(term.source) |
                            mcu_sf2_source_dependencies(term.amount_source);
        terms.push_back(term);
      }
      std::stable_partition(terms.begin(), terms.end(), [](const auto& term) {
        return (term.dependencies & ~kMcuDependencyNote) == 0;
      });
      if (terms.empty()) continue;
      const auto key = modulation_program_key(family, terms);
      auto found = interned.find(key);
      uint32_t program_index = 0;
      if (found != interned.end()) {
        program_index = found->second;
      } else {
        McuSf2ModulationProgram program;
        program.first_term = checked_u32(result.terms.size(), "modulation term offset");
        program.term_count = uint16_t(terms.size());
        program.note_static_term_count = uint16_t(std::count_if(
            terms.begin(), terms.end(), [](const auto& term) {
              return (term.dependencies & ~kMcuDependencyNote) == 0;
            }));
        for (const auto& term : terms) program.dependencies |= term.dependencies;
        program.family = family;
        program_index = checked_u32(result.programs.size(), "modulation program index");
        result.programs.push_back(program);
        result.terms.insert(result.terms.end(), terms.begin(), terms.end());
        interned.emplace(key, program_index);
      }
      if (family == McuSf2ModulationFamily::kGain) references.gain = program_index;
      else if (family == McuSf2ModulationFamily::kPitch) references.pitch = program_index;
      else references.filter = program_index;
    }
    result.candidates.push_back(references);
  }
  return result;
}

SelectedSemanticBuild select_semantics(const Sf2Data& sf2,
                                       const Sf2SemanticData& source,
                                       const McuSf2AssetSelection& requested) {
  std::vector<std::pair<uint16_t, uint16_t>> selected = requested.presets;
  std::sort(selected.begin(), selected.end());
  if (std::adjacent_find(selected.begin(), selected.end()) != selected.end()) {
    throw std::runtime_error("duplicate MCU SF2 preset selection");
  }

  SelectedSemanticBuild result;
  uint32_t selection_crc = 0xffffffffu;
  for (const auto& entry : selected) {
    selection_crc = crc32_update(selection_crc, uint8_t(entry.first));
    selection_crc = crc32_update(selection_crc, uint8_t(entry.first >> 8));
    selection_crc = crc32_update(selection_crc, uint8_t(entry.second));
    selection_crc = crc32_update(selection_crc, uint8_t(entry.second >> 8));
  }
  result.selection_crc32 = selected.empty() ? 0 : selection_crc ^ 0xffffffffu;

  if (selected.empty()) {
    result.semantic = source;
    return result;
  }

  std::vector<bool> retained_samples(source.samples.size());
  for (uint32_t source_preset = 0; source_preset < source.presets.size(); ++source_preset) {
    const auto& input_preset = source.presets[source_preset];
    const auto key = std::make_pair(input_preset.bank, input_preset.program);
    if (!std::binary_search(selected.begin(), selected.end(), key)) continue;

    Sf2SemanticPreset output_preset = input_preset;
    output_preset.first_candidate = checked_u32(result.semantic.candidates.size(),
                                                "selected candidate offset");
    output_preset.candidate_count = 0;
    for (uint32_t local = 0; local < input_preset.candidate_count; ++local) {
      const uint32_t source_candidate = input_preset.first_candidate + local;
      const auto& input_candidate = source.candidates.at(source_candidate);
      Sf2SemanticCandidate output_candidate = input_candidate;
      output_candidate.first_generator = checked_u32(result.semantic.generators.size(),
                                                      "selected generator offset");
      for (uint32_t index = 0; index < input_candidate.generator_count; ++index) {
        const auto generator = source.generators.at(input_candidate.first_generator + index);
        result.semantic.generators.push_back(generator);
        if (generator.oper == kGeneratorSampleId && generator.amount < retained_samples.size()) {
          retained_samples[generator.amount] = true;
        }
      }
      output_candidate.first_modulator = checked_u32(result.semantic.modulators.size(),
                                                      "selected modulator offset");
      result.semantic.modulators.insert(
          result.semantic.modulators.end(),
          source.modulators.begin() + input_candidate.first_modulator,
          source.modulators.begin() + input_candidate.first_modulator +
              input_candidate.modulator_count);
      result.semantic.candidates.push_back(output_candidate);
      ++output_preset.candidate_count;
    }
    result.semantic.presets.push_back(output_preset);
  }
  if (result.semantic.presets.size() != selected.size()) {
    throw std::runtime_error("MCU SF2 preset selection contains a missing bank/program");
  }

  for (size_t index = 0; index < retained_samples.size(); ++index) {
    if (retained_samples[index]) {
      const uint16_t link = source.samples[index].sample_link;
      if (link < retained_samples.size()) retained_samples[link] = true;
    }
  }
  std::vector<uint16_t> sample_remap(source.samples.size(), UINT16_MAX);
  for (size_t index = 0; index < source.samples.size(); ++index) {
    if (!retained_samples[index]) continue;
    sample_remap[index] = uint16_t(result.semantic.samples.size());
    result.semantic.samples.push_back(source.samples[index]);
  }
  for (auto& sample : result.semantic.samples) {
    sample.sample_link = sample.sample_link < sample_remap.size() &&
                                 sample_remap[sample.sample_link] != UINT16_MAX
                             ? sample_remap[sample.sample_link]
                             : 0;
  }
  for (auto& generator : result.semantic.generators) {
    if (generator.oper != kGeneratorSampleId) continue;
    if (generator.amount >= sample_remap.size() || sample_remap[generator.amount] == UINT16_MAX) {
      throw std::runtime_error("selected candidate has no retained sample");
    }
    generator.amount = sample_remap[generator.amount];
  }
  (void)sf2;
  return result;
}

void align_four(std::vector<uint8_t>& data) {
  while ((data.size() & 3u) != 0) data.push_back(0);
}

void validate_range(uint32_t first, uint32_t count, uint32_t total, const char* label) {
  if (uint64_t(first) + count > total) {
    throw std::runtime_error(std::string(label) + " range exceeds referenced section");
  }
}

}  // namespace

McuSf2RuntimeConfig mcu_sf2_runtime_config(const Region& region) {
  McuSf2RuntimeConfig config;
  config.mod_lfo_delay_ticks = uint32_t(region.mod_lfo_delay_ticks);
  config.mod_lfo_step = region.mod_lfo_step;
  config.vib_lfo_delay_ticks = uint32_t(region.vib_lfo_delay_ticks);
  config.vib_lfo_step = region.vib_lfo_step;
  config.mod_lfo_to_pitch = int16_t(region.mod_lfo_to_pitch);
  config.vib_lfo_to_pitch = int16_t(region.vib_lfo_to_pitch);
  config.mod_env_to_pitch = int16_t(region.mod_env_to_pitch);
  config.mod_lfo_to_filter_fc = int16_t(region.mod_lfo_to_filter_fc);
  config.mod_env_to_filter_fc = int16_t(region.mod_env_to_filter_fc);
  config.mod_lfo_to_volume = int16_t(region.mod_lfo_to_volume);
  config.initial_filter_fc = int16_t(region.initial_filter_fc);
  config.initial_filter_q = int16_t(region.initial_filter_q);
  config.mod_env_delay_ticks = uint32_t(region.mod_env_delay_ticks);
  config.mod_env_hold_ticks = uint32_t(region.mod_env_hold_ticks);
  config.mod_env_attack_ticks = uint32_t(region.mod_env_attack_ticks);
  config.mod_env_decay_ticks = uint32_t(region.mod_env_decay_ticks);
  config.mod_env_release_ticks = uint32_t(region.mod_env_release_ticks);
  config.mod_env_sustain_level = uint16_t(region.mod_env_sustain_level);
  config.mod_env_attack_sub_tick = region.mod_env_attack_sub_tick;
  return config;
}

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
                                         const McuSf2AssetProfile& profile,
                                         const McuSf2AssetSelection& selection) {
  if (profile.id.empty() || profile.command_interface_version == 0 ||
      profile.sample_rate == 0 || profile.control_tick_samples == 0) {
    throw std::runtime_error("invalid MCU SF2 asset profile");
  }
  const Sf2SemanticData full_semantic = compile_sf2_semantics(sf2);
  const SelectedSemanticBuild selected = select_semantics(sf2, full_semantic, selection);
  const Sf2SemanticData& semantic = selected.semantic;
  const ModulationBuild modulation = build_modulation(semantic);
  constexpr size_t section_count = 7;
  std::vector<uint8_t> image(kMcuSf2AssetHeaderSize +
                             section_count * kMcuSf2AssetSectionEntrySize, 0);
  std::array<SectionBuild, section_count> sections{{
      {McuSf2AssetSection::kPresets, 12, 1},
      {McuSf2AssetSection::kZones, 20, 1},
      {McuSf2AssetSection::kGenerators, 2, 1},
      {McuSf2AssetSection::kSamples, 22, 1},
      {McuSf2AssetSection::kCandidatePrograms, kCandidateProgramsStride, 1},
      {McuSf2AssetSection::kModulationPrograms, kModulationProgramStride, 1},
      {McuSf2AssetSection::kModulationTerms, kModulationTermStride, 1},
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
  }

  std::vector<uint16_t> compact_generator_amounts;
  compact_generator_amounts.reserve(semantic.generators.size());
  start_section(1, semantic.candidates.size());
  for (uint32_t candidate_index = 0; candidate_index < semantic.candidates.size();
       ++candidate_index) {
    const auto& candidate = semantic.candidates[candidate_index];
    uint16_t sample_index = UINT16_MAX;
    uint64_t generator_presence = 0;
    const uint32_t first_generator = checked_u32(
        compact_generator_amounts.size(), "compact generator offset");
    for (uint32_t index = 0; index < candidate.generator_count; ++index) {
      const auto& generator = semantic.generators.at(candidate.first_generator + index);
      if (generator.oper == kGeneratorSampleId) sample_index = generator.amount;
      if (generator.oper == kGeneratorSampleId ||
          generator.oper == kGeneratorKeyRange ||
          generator.oper == kGeneratorVelocityRange) {
        continue;
      }
      if (generator.oper >= 61 || (generator_presence & (uint64_t(1) << generator.oper))) {
        throw std::runtime_error("compact zone has invalid generator operators");
      }
      generator_presence |= uint64_t(1) << generator.oper;
      compact_generator_amounts.push_back(generator.amount);
    }
    const uint32_t generator_count = checked_u32(
        compact_generator_amounts.size() - first_generator,
        "compact zone generator count");
    if (sample_index >= semantic.samples.size() || generator_count > 61) {
      throw std::runtime_error("compact zone has invalid sample or generator count");
    }
    image.push_back(candidate.key_low);
    image.push_back(candidate.key_high);
    image.push_back(candidate.velocity_low);
    image.push_back(candidate.velocity_high);
    append_u32(image, first_generator);
    append_u16(image, uint16_t(generator_count));
    append_u16(image, sample_index);
    append_u32(image, uint32_t(generator_presence));
    append_u32(image, uint32_t(generator_presence >> 32));
  }

  start_section(2, compact_generator_amounts.size());
  for (uint16_t amount : compact_generator_amounts) {
    append_u16(image, amount);
  }

  start_section(3, semantic.samples.size());
  for (const auto& sample : semantic.samples) {
    append_u32(image, sample.start);
    append_u32(image, sample.end);
    append_u32(image, sample.start_loop);
    append_u32(image, sample.end_loop);
    append_u32(image, sample.sample_rate);
    image.push_back(sample.original_pitch);
    image.push_back(uint8_t(sample.pitch_correction));
  }

  start_section(4, modulation.candidates.size());
  if (modulation.programs.size() > UINT8_MAX) {
    throw std::runtime_error("compact modulation program count exceeds 8-bit IDs");
  }
  for (const auto& candidate : modulation.candidates) {
    for (uint32_t program : {candidate.gain, candidate.pitch, candidate.filter}) {
      if (program != UINT32_MAX && program >= UINT8_MAX) {
        throw std::runtime_error("compact modulation program ID exceeds 8 bits");
      }
      image.push_back(program == UINT32_MAX ? UINT8_MAX : uint8_t(program));
    }
  }

  start_section(5, modulation.programs.size());
  for (const auto& program : modulation.programs) {
    append_u32(image, program.first_term);
    append_u16(image, program.term_count);
    append_u16(image, program.note_static_term_count);
    append_u16(image, program.dependencies);
    image.push_back(uint8_t(program.family));
    image.push_back(0);
  }

  start_section(6, modulation.terms.size());
  for (const auto& term : modulation.terms) {
    append_u16(image, term.source);
    append_u16(image, term.destination);
    append_u16(image, uint16_t(term.amount));
    append_u16(image, term.amount_source);
    append_u16(image, term.transform);
    append_u16(image, term.dependencies);
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
  write_u16(image, 44, uint16_t(section_count));
  write_u32(image, 48, sf2.smpl_word_offset);
  write_u32(image, 52, sf2.smpl_word_count);
  write_u32(image, 56, crc32_string(profile.id));
  write_u32(image, 60, kAssetFlagSourceCrc32);
  write_u32(image, 64, selected.selection_crc32);
  write_u32(image, 68, checked_u32(semantic.presets.size(), "selected preset count"));

  for (size_t index = 0; index < sections.size(); ++index) {
    const size_t offset = kMcuSf2AssetSectionDirectoryOffset +
                          index * kMcuSf2AssetSectionEntrySize;
    write_u16(image, offset, uint16_t(sections[index].type));
    write_u16(image, offset + 2, sections[index].flags);
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
    : data_(data), size_(size), sample_rate_(profile.sample_rate),
      control_tick_samples_(profile.control_tick_samples) {
  constexpr std::array<uint32_t, 7> strides = {12, 20, 2, 22, 3, 12, 12};
  if (data == nullptr || size < kMcuSf2AssetHeaderSize ||
      std::memcmp(data, "MSF2", 4) != 0 ||
      read_u16(data + 4) != kMcuSf2AssetFormatVersion ||
      read_u16(data + 6) != kMcuSf2AssetHeaderSize || read_u32(data + 8) != size) {
    throw std::runtime_error("invalid MCU SF2 compact asset header");
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
  source_size_bytes_ = read_u64(data + 24);
  source_crc32_ = read_u32(data + 32);
  sample_word_offset_ = read_u32(data + 48);
  sample_word_count_ = read_u32(data + 52);
  selection_crc32_ = read_u32(data + 64);
  selected_preset_count_ = read_u32(data + 68);
  if (uint64_t(sample_word_offset_) * 2u + uint64_t(sample_word_count_) * 2u >
      source_size_bytes_) {
    throw std::runtime_error("MCU SF2 sample span exceeds source image");
  }
  const uint32_t directory_offset = read_u32(data + 40);
  const uint16_t section_count = read_u16(data + 44);
  if (read_u32(data + 60) != kAssetFlagSourceCrc32 ||
      directory_offset != kMcuSf2AssetSectionDirectoryOffset || section_count != 7 ||
      uint64_t(directory_offset) + 7u * kMcuSf2AssetSectionEntrySize > size) {
    throw std::runtime_error("invalid MCU SF2 compact section directory");
  }
  uint64_t previous_end = kMcuSf2AssetHeaderSize +
                          7u * kMcuSf2AssetSectionEntrySize;
  for (size_t index = 0; index < 7; ++index) {
    const uint8_t* entry = data + directory_offset + index * kMcuSf2AssetSectionEntrySize;
    const uint32_t offset = read_u32(entry + 4);
    const uint32_t count = read_u32(entry + 8);
    const uint32_t stride = read_u32(entry + 12);
    const uint64_t end = uint64_t(offset) + uint64_t(count) * stride;
    if (read_u16(entry) != index + 1 || read_u16(entry + 2) != 1 ||
        stride != strides[index] || (offset & 3u) != 0 ||
        offset < previous_end || end > size) {
      throw std::runtime_error("invalid MCU SF2 compact section");
    }
    sections_[index] = {data + offset, count, stride};
    previous_end = end;
  }
  if (selected_preset_count_ != preset_count() ||
      candidate_program_count() != zone_count()) {
    throw std::runtime_error("MCU SF2 compact count mismatch");
  }
  for (size_t index = 0; index < preset_count(); ++index) {
    const auto value = preset(index);
    if (value.program > 127 || value.bank > 16383) {
      throw std::runtime_error("invalid compact preset identity");
    }
    validate_range(value.first_zone, value.zone_count, uint32_t(zone_count()),
                   "preset zones");
  }
  for (size_t index = 0; index < zone_count(); ++index) {
    const auto value = zone(index);
    if (value.key_low > value.key_high || value.key_high > 127 ||
        value.velocity_low > value.velocity_high || value.velocity_high > 127 ||
        value.generator_count > 61 || value.sample_index >= sample_count() ||
        (value.generator_presence & ~kValidGeneratorPresence) != 0 ||
        __builtin_popcountll(value.generator_presence) != value.generator_count) {
      throw std::runtime_error("invalid compact zone");
    }
    validate_range(value.first_generator, value.generator_count,
                   uint32_t(generator_count()), "zone generators");
  }
  for (size_t index = 0; index < sample_count(); ++index) {
    const auto value = sample(index);
    if (value.start > value.end || value.end > sample_word_count_ ||
        value.start_loop < value.start || value.start_loop > value.end_loop ||
        value.end_loop > value.end || value.sample_rate == 0) {
      throw std::runtime_error("invalid compact sample");
    }
  }
  for (size_t index = 0; index < candidate_program_count(); ++index) {
    const auto refs = candidate_programs(index);
    for (uint32_t program : {refs.gain, refs.pitch, refs.filter}) {
      if (program != UINT32_MAX && program >= modulation_program_count()) {
        throw std::runtime_error("invalid compact modulation reference");
      }
    }
  }
  for (size_t index = 0; index < modulation_program_count(); ++index) {
    const auto program = modulation_program(index);
    const uint8_t* raw = record(section(McuSf2AssetSection::kModulationPrograms), index);
    if (uint8_t(program.family) > uint8_t(McuSf2ModulationFamily::kFilter) ||
        program.note_static_term_count > program.term_count || raw[11] != 0 ||
        (program.dependencies & ~kDefinedDependencyMask) != 0) {
      throw std::runtime_error("invalid compact modulation program");
    }
    validate_range(program.first_term, program.term_count,
                   uint32_t(modulation_term_count()), "modulation program terms");
    uint16_t observed_dependencies = 0;
    for (uint32_t local = 0; local < program.term_count; ++local) {
      const auto term = modulation_term(program.first_term + local);
      const uint16_t expected_dependencies = uint16_t(
          mcu_sf2_source_dependencies(term.source) |
          mcu_sf2_source_dependencies(term.amount_source));
      if (!destination_in_family(term.destination, program.family) ||
          (term.transform != 0 && term.transform != 2) ||
          (term.dependencies & ~kDefinedDependencyMask) != 0 ||
          term.dependencies != expected_dependencies ||
          (local < program.note_static_term_count &&
           (term.dependencies & ~kMcuDependencyNote) != 0)) {
        throw std::runtime_error("invalid compact modulation term");
      }
      observed_dependencies |= term.dependencies;
    }
    if (observed_dependencies != program.dependencies) {
      throw std::runtime_error("compact modulation dependency mismatch");
    }
  }
  return;
}

const McuSf2AssetView::SectionView& McuSf2AssetView::section(McuSf2AssetSection type) const {
  return sections_.at(size_t(uint16_t(type) - 1));
}

const uint8_t* McuSf2AssetView::record(const SectionView& value, size_t index) const {
  if (index >= value.count) throw std::out_of_range("MCU SF2 asset record index");
  return value.data + index * value.stride;
}


size_t McuSf2AssetView::preset_count() const {
  return section(McuSf2AssetSection::kPresets).count;
}
size_t McuSf2AssetView::zone_count() const {
  return section(McuSf2AssetSection::kZones).count;
}
size_t McuSf2AssetView::generator_count() const {
  return section(McuSf2AssetSection::kGenerators).count;
}
size_t McuSf2AssetView::sample_count() const {
  return section(McuSf2AssetSection::kSamples).count;
}
size_t McuSf2AssetView::candidate_program_count() const {
  return section(McuSf2AssetSection::kCandidatePrograms).count;
}
size_t McuSf2AssetView::modulation_program_count() const {
  return section(McuSf2AssetSection::kModulationPrograms).count;
}
size_t McuSf2AssetView::modulation_term_count() const {
  return section(McuSf2AssetSection::kModulationTerms).count;
}
size_t McuSf2AssetView::section_bytes(McuSf2AssetSection type) const {
  const auto& value = section(type);
  return size_t(value.count) * value.stride;
}
McuSf2Preset McuSf2AssetView::preset(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kPresets), index);
  return {read_u16(value), read_u16(value + 2), read_u32(value + 4),
          read_u32(value + 8)};
}
McuSf2Zone McuSf2AssetView::zone(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kZones), index);
  return {value[0], value[1], value[2], value[3], read_u32(value + 4),
          read_u16(value + 8), read_u16(value + 10), read_u64(value + 12)};
}
uint16_t McuSf2AssetView::generator_amount(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kGenerators), index);
  return read_u16(value);
}
Sf2SemanticSample McuSf2AssetView::sample(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kSamples), index);
  return {read_u32(value), read_u32(value + 4), read_u32(value + 8),
          read_u32(value + 12), read_u32(value + 16), value[20], int8_t(value[21]),
          0, 1};
}
McuSf2CandidatePrograms McuSf2AssetView::candidate_programs(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kCandidatePrograms), index);
  const auto decode = [](uint8_t program) {
    return program == UINT8_MAX ? UINT32_MAX : uint32_t(program);
  };
  return {decode(value[0]), decode(value[1]), decode(value[2])};
}
McuSf2ModulationProgram McuSf2AssetView::modulation_program(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kModulationPrograms), index);
  return {read_u32(value), read_u16(value + 4), read_u16(value + 6),
          read_u16(value + 8), McuSf2ModulationFamily(value[10])};
}
McuSf2ModulationTerm McuSf2AssetView::modulation_term(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kModulationTerms), index);
  return {read_u16(value), read_u16(value + 2), int16_t(read_u16(value + 4)),
          read_u16(value + 6), read_u16(value + 8), read_u16(value + 10)};
}
int32_t McuSf2AssetView::find_preset(int program, int bank) const {
  if (program < 0 || program > 127 || bank < 0 || bank > 16383) return -1;
  for (size_t index = 0; index < preset_count(); ++index) {
    const auto value = preset(index);
    if (value.program == program && value.bank == bank) return int32_t(index);
  }
  return -1;
}
Region McuSf2AssetView::materialize_zone(size_t zone_index, int key) const {
  const auto value = zone(zone_index);
  std::array<Sf2SemanticGenerator, 61> generators{};
  uint32_t amount_index = 0;
  for (uint16_t oper = 0; oper < 61; ++oper) {
    if ((value.generator_presence & (uint64_t(1) << oper)) == 0) continue;
    generators[amount_index] = {
        oper, generator_amount(value.first_generator + amount_index)};
    ++amount_index;
  }
  return materialize_sf2_region(generators.data(), value.generator_count,
                                sample(value.sample_index), sample_word_offset_,
                                sample_word_count_, key, int(sample_rate_),
                                int(control_tick_samples_));
}

bool McuSf2AssetView::matches_source(const Sf2Data& sf2, uint64_t source_size_bytes) const {
  return source_size_bytes == source_size_bytes_ &&
         sf2_source_crc32(sf2, source_size_bytes) == source_crc32_ &&
         sf2.smpl_word_offset == sample_word_offset_ &&
         sf2.smpl_word_count == sample_word_count_;
}

}  // namespace render
