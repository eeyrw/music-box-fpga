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
constexpr uint32_t kPresetStride = 16;
constexpr uint32_t kCandidateStride = 24;
constexpr uint32_t kGeneratorStride = 4;
constexpr uint32_t kModulatorStride = 10;
constexpr uint32_t kSampleStride = 28;
constexpr uint32_t kPresetDispatchStride = 12;
constexpr uint32_t kKeyDispatchStride = 8;
constexpr uint32_t kVelocitySpanStride = 8;
constexpr uint32_t kLayerReferenceStride = 4;
constexpr uint32_t kMonoDescriptorStride = 20;
constexpr uint32_t kStartWordStride = 4;
constexpr uint32_t kCandidateProgramsStride = 12;
constexpr uint32_t kModulationProgramStride = 12;
constexpr uint32_t kModulationTermStride = 12;
constexpr uint32_t kSourceCurveStride = 4;
constexpr size_t kSemanticSectionCount = 5;
constexpr size_t kDispatchSectionCount = 11;
constexpr size_t kKnownSectionCount = 15;
constexpr uint16_t kGeneratorSampleId = 53;

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

struct DispatchBuild {
  std::vector<McuSf2PresetDispatch> presets;
  std::vector<McuSf2KeyDispatch> keys;
  std::vector<McuSf2VelocitySpan> spans;
  std::vector<uint32_t> layers;
  std::vector<McuSf2MonoDescriptor> descriptors;
  std::vector<uint32_t> start_words;
};

struct SelectedSemanticBuild {
  Sf2SemanticData semantic;
  std::vector<uint32_t> source_presets;
  std::vector<std::vector<uint32_t>> source_candidates;
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
    result.source_presets.reserve(source.presets.size());
    result.source_candidates.reserve(source.presets.size());
    for (uint32_t preset = 0; preset < source.presets.size(); ++preset) {
      result.source_presets.push_back(preset);
      std::vector<uint32_t> candidates;
      candidates.reserve(source.presets[preset].candidate_count);
      for (uint32_t local = 0; local < source.presets[preset].candidate_count; ++local) {
        candidates.push_back(local);
      }
      result.source_candidates.push_back(std::move(candidates));
    }
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
    result.source_presets.push_back(source_preset);
    result.source_candidates.emplace_back();
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
      result.source_candidates.back().push_back(local);
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

uint32_t pack_pair(int high, int low) {
  return (uint32_t(uint16_t(high)) << 16) | uint32_t(uint16_t(low));
}

uint32_t ceil_step(uint64_t distance, uint32_t duration) {
  if (duration == 0) return 0;
  return uint32_t(std::min<uint64_t>(0xffffffffu,
                                    (distance + duration - 1u) / duration));
}

std::vector<uint32_t> start_template(const Region& region) {
  constexpr uint32_t kSilenceCbQ12_20 = 1000u << 20;
  const auto& env = region.volume_envelope;
  const bool has_loop = region.loop_mode != 0;
  const bool has_filter = region.filter_enable;
  const bool has_envelope = env.delay_samples != 0 || env.attack_samples != 0 ||
      env.hold_samples != 0 || env.decay_samples != 0 ||
      env.sustain_cb_q12_20 != 0 || env.release_samples != 0;
  uint8_t flags = uint8_t(region.loop_mode & 3);
  if (has_filter) flags |= 1u << 2;
  if (has_envelope) flags |= 1u << 3;

  std::vector<uint32_t> words;
  words.reserve(17);
  words.push_back(0);
  words.push_back(1);  // Voice zero and generation one are patchable template values.
  words.push_back(region.base_addr);
  words.push_back(region.length);
  if (has_loop) {
    words.push_back(region.loop_start);
    words.push_back(region.loop_end);
  }
  words.push_back(region.phase_inc);
  words.push_back(pack_pair(region.gain_r, region.gain_l));
  if (has_filter) {
    words.push_back(pack_pair(region.filter_b1, region.filter_b0));
    words.push_back(pack_pair(region.filter_a1, region.filter_b2));
    words.push_back(uint32_t(uint16_t(region.filter_a2)) | 0x00010000u);
  }
  if (has_envelope) {
    words.push_back(env.delay_samples);
    words.push_back(ceil_step(0xffffffffu, env.attack_samples));
    words.push_back(env.hold_samples);
    words.push_back(ceil_step(env.sustain_cb_q12_20, env.decay_samples));
    words.push_back(env.sustain_cb_q12_20);
    words.push_back(ceil_step(kSilenceCbQ12_20, env.release_samples));
  }
  words[0] = (0x10u << 24) | (uint32_t(flags) << 8) | uint32_t(words.size() - 1);
  return words;
}

DispatchBuild build_dispatch(const Sf2Data& sf2, const Sf2SemanticData& semantic,
                             const std::vector<uint32_t>& source_presets,
                             const std::vector<std::vector<uint32_t>>& source_candidates,
                             const McuSf2AssetProfile& profile) {
  DispatchBuild result;
  std::map<std::vector<uint32_t>, uint32_t> interned_start_templates;
  std::map<std::pair<uint16_t, uint16_t>, uint32_t> preset_index;
  for (uint32_t index = 0; index < semantic.presets.size(); ++index) {
    const auto& preset = semantic.presets[index];
    preset_index.emplace(std::make_pair(preset.bank, preset.program), index);
  }

  for (const auto& entry : preset_index) {
    const uint32_t semantic_preset_index = entry.second;
    const auto& preset = semantic.presets.at(semantic_preset_index);
    McuSf2PresetDispatch dispatch;
    dispatch.program = preset.program;
    dispatch.bank = preset.bank;
    dispatch.semantic_preset = semantic_preset_index;
    dispatch.first_key = checked_u32(result.keys.size(), "key dispatch offset");
    result.presets.push_back(dispatch);

    for (int key = 0; key < 128; ++key) {
      struct CandidateLayer {
        const Sf2SemanticCandidate* candidate = nullptr;
        uint32_t descriptor = 0;
      };
      std::vector<CandidateLayer> candidates;
      std::array<bool, 129> breakpoints{};
      breakpoints[1] = true;
      breakpoints[128] = true;
      for (uint32_t local = 0; local < preset.candidate_count; ++local) {
        const uint32_t global = preset.first_candidate + local;
        const auto& candidate = semantic.candidates.at(global);
        if (key < candidate.key_low || key > candidate.key_high ||
            candidate.velocity_high < 1) {
          continue;
        }
        const Region region = make_region_for_compiled_candidate(
            sf2, source_presets.at(semantic_preset_index),
            source_candidates.at(semantic_preset_index).at(local), key,
            int(profile.sample_rate), int(profile.control_tick_samples));
        const std::vector<uint32_t> words = start_template(region);
        McuSf2MonoDescriptor descriptor;
        descriptor.semantic_candidate = global;
        auto interned = interned_start_templates.find(words);
        if (interned == interned_start_templates.end()) {
          const uint32_t offset = checked_u32(result.start_words.size(),
                                              "START word offset");
          result.start_words.insert(result.start_words.end(), words.begin(), words.end());
          interned = interned_start_templates.emplace(words, offset).first;
        }
        descriptor.first_start_word = interned->second;
        descriptor.start_word_count = uint8_t(words.size());
        descriptor.key = uint8_t(key);
        descriptor.exclusive_class = uint8_t(region.exclusive_class);
        descriptor.effective_velocity = int8_t(region.effective_velocity);
        descriptor.base_gain = uint16_t(region.base_gain);
        descriptor.pan = int16_t(region.pan);
        const uint32_t descriptor_index = checked_u32(result.descriptors.size(),
                                                      "mono descriptor index");
        result.descriptors.push_back(descriptor);
        candidates.push_back({&candidate, descriptor_index});
        breakpoints[std::max<int>(1, candidate.velocity_low)] = true;
        if (candidate.velocity_high < 127) {
          breakpoints[size_t(candidate.velocity_high + 1)] = true;
        }
      }

      McuSf2KeyDispatch key_dispatch;
      key_dispatch.first_span = checked_u32(result.spans.size(), "velocity span offset");
      std::vector<uint32_t> previous_layers;
      for (int low = 1; low < 128;) {
        int next = low + 1;
        while (next < 128 && !breakpoints[size_t(next)]) ++next;
        std::vector<uint32_t> selected;
        for (const auto& candidate : candidates) {
          if (low >= candidate.candidate->velocity_low &&
              low <= candidate.candidate->velocity_high) {
            selected.push_back(candidate.descriptor);
          }
        }
        if (!result.spans.empty() && key_dispatch.span_count != 0 &&
            selected == previous_layers) {
          result.spans.back().velocity_high = uint8_t(next - 1);
        } else {
          McuSf2VelocitySpan span;
          span.velocity_low = uint8_t(low);
          span.velocity_high = uint8_t(next - 1);
          span.first_layer = checked_u32(result.layers.size(), "layer reference offset");
          if (selected.size() > std::numeric_limits<uint16_t>::max()) {
            throw std::runtime_error("velocity span exceeds 16-bit layer count");
          }
          span.layer_count = uint16_t(selected.size());
          result.layers.insert(result.layers.end(), selected.begin(), selected.end());
          result.spans.push_back(span);
          ++key_dispatch.span_count;
          previous_layers = std::move(selected);
        }
        low = next;
      }
      result.keys.push_back(key_dispatch);
    }
  }
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
  const DispatchBuild dispatch = build_dispatch(
      sf2, semantic, selected.source_presets, selected.source_candidates, profile);
  const ModulationBuild modulation = build_modulation(semantic);
  std::vector<uint8_t> image(kMcuSf2AssetHeaderSize +
                             kKnownSectionCount * kMcuSf2AssetSectionEntrySize, 0);
  std::array<SectionBuild, kKnownSectionCount> sections{{
      {McuSf2AssetSection::kPresets, kPresetStride, 1},
      {McuSf2AssetSection::kCandidates, kCandidateStride, 1},
      {McuSf2AssetSection::kGenerators, kGeneratorStride, 1},
      {McuSf2AssetSection::kModulators, kModulatorStride, 1},
      {McuSf2AssetSection::kSamples, kSampleStride, 1},
      {McuSf2AssetSection::kPresetDispatch, kPresetDispatchStride, 0},
      {McuSf2AssetSection::kKeyDispatch, kKeyDispatchStride, 0},
      {McuSf2AssetSection::kVelocitySpans, kVelocitySpanStride, 0},
      {McuSf2AssetSection::kLayerReferences, kLayerReferenceStride, 0},
      {McuSf2AssetSection::kMonoDescriptors, kMonoDescriptorStride, 0},
      {McuSf2AssetSection::kStartWords, kStartWordStride, 0},
      {McuSf2AssetSection::kCandidatePrograms, kCandidateProgramsStride, 0},
      {McuSf2AssetSection::kModulationPrograms, kModulationProgramStride, 0},
      {McuSf2AssetSection::kModulationTerms, kModulationTermStride, 0},
      {McuSf2AssetSection::kSourceCurves, kSourceCurveStride, 0},
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

  start_section(5, dispatch.presets.size());
  for (const auto& preset : dispatch.presets) {
    append_u16(image, preset.program);
    append_u16(image, preset.bank);
    append_u32(image, preset.semantic_preset);
    append_u32(image, preset.first_key);
  }

  start_section(6, dispatch.keys.size());
  for (const auto& key : dispatch.keys) {
    append_u32(image, key.first_span);
    append_u16(image, key.span_count);
    append_u16(image, 0);
  }

  start_section(7, dispatch.spans.size());
  for (const auto& span : dispatch.spans) {
    image.push_back(span.velocity_low);
    image.push_back(span.velocity_high);
    append_u16(image, span.layer_count);
    append_u32(image, span.first_layer);
  }

  start_section(8, dispatch.layers.size());
  for (uint32_t descriptor : dispatch.layers) append_u32(image, descriptor);

  start_section(9, dispatch.descriptors.size());
  for (const auto& descriptor : dispatch.descriptors) {
    append_u32(image, descriptor.semantic_candidate);
    append_u32(image, descriptor.first_start_word);
    image.push_back(descriptor.start_word_count);
    image.push_back(descriptor.key);
    image.push_back(descriptor.exclusive_class);
    image.push_back(uint8_t(descriptor.effective_velocity));
    append_u16(image, descriptor.base_gain);
    append_u16(image, uint16_t(descriptor.pan));
    append_u32(image, 0);
  }

  start_section(10, dispatch.start_words.size());
  for (uint32_t word : dispatch.start_words) append_u32(image, word);

  start_section(11, modulation.candidates.size());
  for (const auto& candidate : modulation.candidates) {
    append_u32(image, candidate.gain);
    append_u32(image, candidate.pitch);
    append_u32(image, candidate.filter);
  }

  start_section(12, modulation.programs.size());
  for (const auto& program : modulation.programs) {
    append_u32(image, program.first_term);
    append_u16(image, program.term_count);
    append_u16(image, program.note_static_term_count);
    append_u16(image, program.dependencies);
    image.push_back(uint8_t(program.family));
    image.push_back(0);
  }

  start_section(13, modulation.terms.size());
  for (const auto& term : modulation.terms) {
    append_u16(image, term.source);
    append_u16(image, term.destination);
    append_u16(image, uint16_t(term.amount));
    append_u16(image, term.amount_source);
    append_u16(image, term.transform);
    append_u16(image, term.dependencies);
  }

  start_section(14, kMcuSourceCurveCount * kMcuSourceCurveSize);
  for (uint8_t curve = 0; curve < kMcuSourceCurveCount; ++curve) {
    for (uint8_t value = 0; value < kMcuSourceCurveSize; ++value) {
      append_u32(image, uint32_t(mcu_sf2_source_curve_q16(curve, value)));
    }
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
  write_u16(image, 44, uint16_t(kKnownSectionCount));
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
  selection_crc32_ = read_u32(data + 64);
  selected_preset_count_ = read_u32(data + 68);
  if (uint64_t(sample_word_offset_) * 2u + uint64_t(sample_word_count_) * 2u >
      source_size_bytes_) {
    throw std::runtime_error("MCU SF2 asset sample span exceeds source image");
  }
  const uint32_t directory_offset = read_u32(data + 40);
  const uint16_t section_count = read_u16(data + 44);
  if (directory_offset != kMcuSf2AssetSectionDirectoryOffset ||
      section_count < kSemanticSectionCount ||
      uint64_t(directory_offset) + uint64_t(section_count) * kMcuSf2AssetSectionEntrySize > size) {
    throw std::runtime_error("invalid MCU SF2 asset section directory");
  }

  const std::array<uint32_t, kKnownSectionCount> expected_strides = {
      kPresetStride, kCandidateStride, kGeneratorStride, kModulatorStride,
      kSampleStride, kPresetDispatchStride, kKeyDispatchStride,
      kVelocitySpanStride, kLayerReferenceStride, kMonoDescriptorStride,
      kStartWordStride, kCandidateProgramsStride, kModulationProgramStride,
      kModulationTermStride, kSourceCurveStride};
  uint64_t previous_end = kMcuSf2AssetHeaderSize +
                          uint64_t(section_count) * kMcuSf2AssetSectionEntrySize;
  std::array<bool, kKnownSectionCount> seen{};
  for (size_t index = 0; index < section_count; ++index) {
    const uint8_t* entry = data + directory_offset + index * kMcuSf2AssetSectionEntrySize;
    const uint16_t raw_type = read_u16(entry);
    const uint16_t flags = read_u16(entry + 2);
    const uint32_t offset = read_u32(entry + 4);
    const uint32_t count = read_u32(entry + 8);
    const uint32_t stride = read_u32(entry + 12);
    if (raw_type == 0 || flags > 1 || stride == 0 || (offset & 3u) != 0) {
      throw std::runtime_error("invalid MCU SF2 asset section stride/alignment");
    }
    const uint64_t end = uint64_t(offset) + uint64_t(count) * stride;
    if (offset < previous_end || end > size) {
      throw std::runtime_error("overlapping or out-of-bounds MCU SF2 asset section");
    }
    if (raw_type <= kKnownSectionCount) {
      const size_t slot = raw_type - 1;
      if (seen[slot] || stride != expected_strides[slot]) {
        throw std::runtime_error("invalid or duplicate MCU SF2 asset section type");
      }
      if ((slot < kSemanticSectionCount && flags != 1) ||
          (slot >= kSemanticSectionCount && flags != 0)) {
        throw std::runtime_error("invalid MCU SF2 asset section requirement flag");
      }
      sections_[slot] = {data + offset, count, stride};
      seen[slot] = true;
    } else if (flags != 0) {
      throw std::runtime_error("unknown required MCU SF2 asset section");
    }
    previous_end = end;
  }
  if (std::find(seen.begin(), seen.begin() + kSemanticSectionCount, false) !=
      seen.begin() + kSemanticSectionCount) {
    throw std::runtime_error("missing required MCU SF2 asset section");
  }
  const bool any_dispatch = std::find(seen.begin() + kSemanticSectionCount,
                                      seen.begin() + kDispatchSectionCount, true) !=
                            seen.begin() + kDispatchSectionCount;
  const bool all_dispatch = std::find(seen.begin() + kSemanticSectionCount,
                                      seen.begin() + kDispatchSectionCount, false) ==
                            seen.begin() + kDispatchSectionCount;
  if (any_dispatch != all_dispatch) {
    throw std::runtime_error("incomplete MCU SF2 asset dispatch sections");
  }
  has_dispatch_ = all_dispatch;
  const bool any_modulation = std::find(seen.begin() + kDispatchSectionCount,
                                        seen.end(), true) != seen.end();
  const bool all_modulation = std::find(seen.begin() + kDispatchSectionCount,
                                        seen.end(), false) == seen.end();
  if (any_modulation != all_modulation || (all_modulation && !has_dispatch_)) {
    throw std::runtime_error("incomplete MCU SF2 asset modulation sections");
  }
  has_modulation_programs_ = all_modulation;

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
  if (has_dispatch_) {
    if (selected_preset_count_ != preset_count() ||
        selected_preset_count_ != preset_dispatch_count()) {
      throw std::runtime_error("MCU SF2 selected preset count mismatch");
    }
    if (key_dispatch_count() != preset_dispatch_count() * 128u) {
      throw std::runtime_error("MCU SF2 key dispatch count mismatch");
    }
    for (size_t index = 0; index < preset_dispatch_count(); ++index) {
      const auto value = preset_dispatch(index);
      if (value.semantic_preset >= preset_count() || value.first_key != index * 128u) {
        throw std::runtime_error("invalid MCU SF2 preset dispatch reference");
      }
      if (index != 0) {
        const auto previous = preset_dispatch(index - 1);
        if (std::make_pair(value.bank, value.program) <=
            std::make_pair(previous.bank, previous.program)) {
          throw std::runtime_error("MCU SF2 preset dispatch is not sorted");
        }
      }
    }
    for (size_t index = 0; index < key_dispatch_count(); ++index) {
      const auto key = key_dispatch(index);
      validate_range(key.first_span, key.span_count,
                     uint32_t(velocity_span_count()), "key velocity span");
      if (key.span_count == 0) throw std::runtime_error("key has no velocity spans");
      int expected_low = 1;
      for (uint32_t span_index = 0; span_index < key.span_count; ++span_index) {
        const auto span = velocity_span(key.first_span + span_index);
        if (span.velocity_low != expected_low || span.velocity_low > span.velocity_high) {
          throw std::runtime_error("velocity spans are not contiguous");
        }
        validate_range(span.first_layer, span.layer_count,
                       uint32_t(layer_reference_count()), "velocity layer");
        expected_low = int(span.velocity_high) + 1;
      }
      if (expected_low != 128) throw std::runtime_error("velocity spans do not cover 1..127");
    }
    for (size_t index = 0; index < layer_reference_count(); ++index) {
      if (layer_reference(index) >= mono_descriptor_count()) {
        throw std::runtime_error("layer references invalid mono descriptor");
      }
    }
    for (size_t index = 0; index < mono_descriptor_count(); ++index) {
      const auto descriptor = mono_descriptor(index);
      if (descriptor.semantic_candidate >= candidate_count() ||
          descriptor.key > 127 || descriptor.start_word_count < 6 ||
          descriptor.start_word_count > 17) {
        throw std::runtime_error("invalid mono descriptor");
      }
      validate_range(descriptor.first_start_word, descriptor.start_word_count,
                     uint32_t(start_word_count()), "descriptor START words");
      const uint32_t header = start_word(descriptor.first_start_word);
      if (uint8_t(header >> 24) != 0x10 || ((header >> 14) & 0x3ffu) != 0 ||
          uint8_t(header) != descriptor.start_word_count - 1 ||
          start_word(descriptor.first_start_word + 1) != 1) {
        throw std::runtime_error("invalid mono descriptor START template");
      }
    }
  }
  if (has_modulation_programs_) {
    if (candidate_program_count() != candidate_count() ||
        source_curve_value_count() != kMcuSourceCurveCount * kMcuSourceCurveSize) {
      throw std::runtime_error("MCU SF2 modulation table count mismatch");
    }
    for (size_t index = 0; index < candidate_program_count(); ++index) {
      const auto references = candidate_programs(index);
      for (uint32_t program : {references.gain, references.pitch, references.filter}) {
        if (program != UINT32_MAX && program >= modulation_program_count()) {
          throw std::runtime_error("candidate references invalid modulation program");
        }
      }
    }
    for (size_t index = 0; index < modulation_program_count(); ++index) {
      const auto program = modulation_program(index);
      if (uint8_t(program.family) > uint8_t(McuSf2ModulationFamily::kFilter) ||
          program.note_static_term_count > program.term_count) {
        throw std::runtime_error("invalid MCU SF2 modulation program");
      }
      validate_range(program.first_term, program.term_count,
                     uint32_t(modulation_term_count()), "modulation program terms");
      uint16_t observed_dependencies = 0;
      for (uint32_t term = 0; term < program.term_count; ++term) {
        const auto value = modulation_term(program.first_term + term);
        observed_dependencies |= value.dependencies;
        if (term < program.note_static_term_count &&
            (value.dependencies & ~kMcuDependencyNote) != 0) {
          throw std::runtime_error("live modulation term is in note-static prefix");
        }
      }
      if (observed_dependencies != program.dependencies) {
        throw std::runtime_error("modulation dependency mask mismatch");
      }
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
size_t McuSf2AssetView::preset_dispatch_count() const { return section(McuSf2AssetSection::kPresetDispatch).count; }
size_t McuSf2AssetView::key_dispatch_count() const { return section(McuSf2AssetSection::kKeyDispatch).count; }
size_t McuSf2AssetView::velocity_span_count() const { return section(McuSf2AssetSection::kVelocitySpans).count; }
size_t McuSf2AssetView::layer_reference_count() const { return section(McuSf2AssetSection::kLayerReferences).count; }
size_t McuSf2AssetView::mono_descriptor_count() const { return section(McuSf2AssetSection::kMonoDescriptors).count; }
size_t McuSf2AssetView::start_word_count() const { return section(McuSf2AssetSection::kStartWords).count; }
size_t McuSf2AssetView::candidate_program_count() const { return section(McuSf2AssetSection::kCandidatePrograms).count; }
size_t McuSf2AssetView::modulation_program_count() const { return section(McuSf2AssetSection::kModulationPrograms).count; }
size_t McuSf2AssetView::modulation_term_count() const { return section(McuSf2AssetSection::kModulationTerms).count; }
size_t McuSf2AssetView::source_curve_value_count() const { return section(McuSf2AssetSection::kSourceCurves).count; }

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

McuSf2PresetDispatch McuSf2AssetView::preset_dispatch(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kPresetDispatch), index);
  return {read_u16(value), read_u16(value + 2), read_u32(value + 4),
          read_u32(value + 8)};
}

McuSf2KeyDispatch McuSf2AssetView::key_dispatch(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kKeyDispatch), index);
  return {read_u32(value), read_u16(value + 4)};
}

McuSf2VelocitySpan McuSf2AssetView::velocity_span(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kVelocitySpans), index);
  return {value[0], value[1], read_u16(value + 2), read_u32(value + 4)};
}

uint32_t McuSf2AssetView::layer_reference(size_t index) const {
  return read_u32(record(section(McuSf2AssetSection::kLayerReferences), index));
}

McuSf2MonoDescriptor McuSf2AssetView::mono_descriptor(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kMonoDescriptors), index);
  return {read_u32(value), read_u32(value + 4), value[8], value[9], value[10],
          int8_t(value[11]), read_u16(value + 12), int16_t(read_u16(value + 14))};
}

uint32_t McuSf2AssetView::start_word(size_t index) const {
  return read_u32(record(section(McuSf2AssetSection::kStartWords), index));
}

McuSf2CandidatePrograms McuSf2AssetView::candidate_programs(size_t index) const {
  const uint8_t* value = record(section(McuSf2AssetSection::kCandidatePrograms), index);
  return {read_u32(value), read_u32(value + 4), read_u32(value + 8)};
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

int32_t McuSf2AssetView::source_curve_value(size_t index) const {
  return int32_t(read_u32(record(section(McuSf2AssetSection::kSourceCurves), index)));
}

int32_t McuSf2AssetView::find_preset_dispatch(int program, int bank) const {
  if (!has_dispatch_ || program < 0 || program > 127 || bank < 0 || bank > 16383) return -1;
  const auto wanted = std::make_pair(uint16_t(bank), uint16_t(program));
  size_t low = 0;
  size_t high = preset_dispatch_count();
  while (low < high) {
    const size_t middle = low + (high - low) / 2;
    const auto value = preset_dispatch(middle);
    const auto key = std::make_pair(value.bank, value.program);
    if (key < wanted) low = middle + 1;
    else high = middle;
  }
  if (low == preset_dispatch_count()) return -1;
  const auto value = preset_dispatch(low);
  return std::make_pair(value.bank, value.program) == wanted ? int32_t(low) : -1;
}

McuSf2VelocitySpan McuSf2AssetView::find_velocity_span(
    size_t preset_dispatch_index, int key, int velocity) const {
  if (!has_dispatch_ || preset_dispatch_index >= preset_dispatch_count() ||
      key < 0 || key > 127 || velocity < 1 || velocity > 127) {
    throw std::out_of_range("MCU SF2 dispatch lookup");
  }
  const auto preset = preset_dispatch(preset_dispatch_index);
  const auto key_value = key_dispatch(preset.first_key + uint32_t(key));
  for (uint32_t index = 0; index < key_value.span_count; ++index) {
    const auto span = velocity_span(key_value.first_span + index);
    if (velocity >= span.velocity_low && velocity <= span.velocity_high) return span;
  }
  throw std::runtime_error("validated MCU SF2 dispatch has no velocity span");
}

bool McuSf2AssetView::matches_source(const Sf2Data& sf2, uint64_t source_size_bytes) const {
  return source_size_bytes == source_size_bytes_ &&
         sf2_source_crc32(sf2, source_size_bytes) == source_crc32_ &&
         sf2.smpl_word_offset == sample_word_offset_ &&
         sf2.smpl_word_count == sample_word_count_;
}

}  // namespace render
