#include "render_support.h"

#include <array>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <tuple>

namespace render {
namespace {

constexpr uint16_t kGenModLfoToPitch = 5;
constexpr uint16_t kGenVibLfoToPitch = 6;
constexpr uint16_t kGenModEnvToPitch = 7;
constexpr uint16_t kGenInitialFilterFc = 8;
constexpr uint16_t kGenModLfoToFilterFc = 10;
constexpr uint16_t kGenModEnvToFilterFc = 11;
constexpr uint16_t kGenModLfoToVolume = 13;
constexpr uint16_t kGenChorusEffectsSend = 15;
constexpr uint16_t kGenReverbEffectsSend = 16;
constexpr uint16_t kGenPan = 17;
constexpr uint16_t kGenInitialAttenuation = 48;
constexpr uint16_t kGenCoarseTune = 51;
constexpr uint16_t kGenFineTune = 52;

std::string json_string_impl(const std::string& value) {
  std::ostringstream out;
  out << '"';
  for (unsigned char c : value) {
    switch (c) {
      case '"': out << "\\\""; break;
      case '\\': out << "\\\\"; break;
      case '\b': out << "\\b"; break;
      case '\f': out << "\\f"; break;
      case '\n': out << "\\n"; break;
      case '\r': out << "\\r"; break;
      case '\t': out << "\\t"; break;
      default:
        if (c < 0x20) {
          constexpr char hex[] = "0123456789abcdef";
          out << "\\u00" << hex[c >> 4] << hex[c & 0x0f];
        } else {
          out << char(c);
        }
        break;
    }
  }
  out << '"';
  return out.str();
}

std::string hex16(uint16_t value) {
  constexpr char hex[] = "0123456789abcdef";
  std::string out = "0x0000";
  for (int i = 0; i < 4; ++i) {
    out[5 - i] = hex[value & 0x0f];
    value >>= 4;
  }
  return out;
}

const char* generator_name(uint16_t dest) {
  switch (dest) {
    case 0: return "pitch";
    case kGenModLfoToPitch: return "modLfoToPitch";
    case kGenVibLfoToPitch: return "vibLfoToPitch";
    case kGenModEnvToPitch: return "modEnvToPitch";
    case kGenInitialFilterFc: return "initialFilterFc";
    case kGenModLfoToFilterFc: return "modLfoToFilterFc";
    case kGenModEnvToFilterFc: return "modEnvToFilterFc";
    case kGenModLfoToVolume: return "modLfoToVolume";
    case kGenChorusEffectsSend: return "chorusEffectsSend";
    case kGenReverbEffectsSend: return "reverbEffectsSend";
    case kGenPan: return "pan";
    case kGenInitialAttenuation: return "initialAttenuation";
    case kGenCoarseTune: return "coarseTune";
    case kGenFineTune: return "fineTune";
    default: return "unknown";
  }
}

const char* modulator_source_name(uint16_t source) {
  switch (source) {
    case 0x0000: return "none";
    case 0x0502: return "noteOnVelocity";
    case 0x0102: return "noteOnVelocityFilter";
    case 0x000d: return "channelPressure";
    case 0x0081: return "cc1ModWheel";
    case 0x0587: return "cc7Volume";
    case 0x028a: return "cc10Pan";
    case 0x058b: return "cc11Expression";
    case 0x00db: return "cc91ReverbSend";
    case 0x00dd: return "cc93ChorusSend";
    case 0x020e: return "pitchWheel";
    case 0x0010: return "pitchWheelSensitivity";
    case 0x000a: return "keyPressure";
    default:
      if ((source & 0x0080u) == 0u) {
        int index = source & 0x007fu;
        if (index == 2) return "noteOnVelocity";
        if (index == 3) return "noteOnKey";
      }
      return "unknown";
  }
}

const char* modulator_transform_name(uint16_t transform) {
  if (transform == 0) return "linear";
  if (transform == 2) return "absoluteValue";
  return "unknown";
}

void write_modulator_source_descriptor(std::ostream& out, uint16_t source) {
  out << "{\"raw\": " << source
      << ", \"hex\": " << json_string_impl(hex16(source))
      << ", \"name\": " << json_string_impl(modulator_source_name(source))
      << ", \"cc\": " << ((source & 0x0080u) ? "true" : "false")
      << ", \"index\": " << (source & 0x007fu)
      << ", \"direction\": " << json_string_impl(((source >> 8) & 1u) ? "negative" : "positive")
      << ", \"polarity\": " << json_string_impl(((source >> 9) & 1u) ? "bipolar" : "unipolar")
      << ", \"type\": " << ((source >> 10) & 0x3fu) << "}";
}

using EnvelopeKey = std::array<int64_t, 11>;
using GeneratorKey = std::array<int64_t, 20>;
using ModulatorKey = std::array<int64_t, 5>;
using ModulatorSetKey = std::vector<ModulatorKey>;
using ModulationKey = std::pair<GeneratorKey, size_t>;
using SampleWindowKey = std::array<uint64_t, 5>;

template <typename T>
size_t intern(const T& value, std::map<T, size_t>& ids, std::vector<T>& values) {
  auto found = ids.find(value);
  if (found != ids.end()) return found->second;
  size_t id = values.size();
  ids.emplace(value, id);
  values.push_back(value);
  return id;
}

EnvelopeKey envelope_key(const Region& r) {
  return {r.volume_envelope.delay_samples, r.volume_envelope.attack_samples,
          r.volume_envelope.hold_samples, r.volume_envelope.decay_samples,
          r.volume_envelope.sustain_cb_q12_20, r.volume_envelope.release_samples,
          r.delay_ticks, r.attack_ticks, r.hold_ticks, r.decay_ticks,
          r.release_ticks};
}

GeneratorKey generator_key(const Region& r) {
  return {r.mod_lfo_delay_ticks, r.mod_lfo_step, r.mod_lfo_to_pitch,
          r.mod_lfo_to_filter_fc, r.mod_lfo_to_volume,
          r.vib_lfo_delay_ticks, r.vib_lfo_step, r.vib_lfo_to_pitch,
          r.mod_env_delay_ticks, r.mod_env_hold_ticks, r.mod_env_sustain_level,
          r.mod_env_attack_ticks, r.mod_env_decay_ticks, r.mod_env_release_ticks,
          r.mod_env_attack_sub_tick ? 1 : 0, r.mod_env_attack_step,
          r.mod_env_decay_step, r.mod_env_release_step, r.mod_env_to_pitch,
          r.mod_env_to_filter_fc};
}

ModulatorSetKey modulator_set_key(const Region& r) {
  ModulatorSetKey key;
  for (const auto& group : r.modulators_by_destination) {
    for (const auto& mod : group.second) {
      key.push_back({mod.src, mod.dest, mod.amount, mod.amount_src, mod.transform});
    }
  }
  return key;
}

void write_envelope(std::ostream& out, const EnvelopeKey& e) {
  out << "{\"delay_samples\": " << e[0] << ", \"attack_samples\": " << e[1]
      << ", \"hold_samples\": " << e[2] << ", \"decay_samples\": " << e[3]
      << ", \"sustain_cb_q12_20\": " << e[4] << ", \"release_samples\": " << e[5]
      << ", \"policy_delay_ticks\": " << e[6] << ", \"policy_attack_ticks\": " << e[7]
      << ", \"policy_hold_ticks\": " << e[8] << ", \"policy_decay_ticks\": " << e[9]
      << ", \"policy_release_ticks\": " << e[10] << "}";
}

void write_generators(std::ostream& out, const GeneratorKey& g) {
  out << "{\"mod_lfo\": {\"delay_ticks\": " << g[0] << ", \"step\": " << g[1]
      << ", \"to_pitch\": " << g[2] << ", \"to_filter_fc\": " << g[3]
      << ", \"to_volume\": " << g[4]
      << "}, \"vib_lfo\": {\"delay_ticks\": " << g[5] << ", \"step\": " << g[6]
      << ", \"to_pitch\": " << g[7]
      << "}, \"mod_env\": {\"delay_ticks\": " << g[8]
      << ", \"hold_ticks\": " << g[9] << ", \"sustain_level\": " << g[10]
      << ", \"attack_ticks\": " << g[11] << ", \"decay_ticks\": " << g[12]
      << ", \"release_ticks\": " << g[13]
      << ", \"attack_sub_tick\": " << (g[14] ? "true" : "false")
      << ", \"attack_step\": " << g[15] << ", \"decay_step\": " << g[16]
      << ", \"release_step\": " << g[17] << ", \"to_pitch\": " << g[18]
      << ", \"to_filter_fc\": " << g[19] << "}}";
}

struct RegionRefs {
  size_t preset = 0;
  size_t instrument = 0;
  size_t sample_window = 0;
  size_t envelope = 0;
  size_t modulation = 0;
};

struct ReportCatalog {
  std::vector<std::string> presets;
  std::vector<std::string> instruments;
  std::vector<std::string> samples;
  std::vector<SampleWindowKey> sample_windows;
  std::vector<EnvelopeKey> envelopes;
  std::vector<ModulatorSetKey> modulator_sets;
  std::vector<ModulationKey> modulations;
  std::vector<RegionRefs> region_refs;
  std::set<uint16_t> sources;
  std::set<uint16_t> destinations;
  std::set<uint16_t> transforms;
};

ReportCatalog build_catalog(const std::vector<Region>& regions) {
  ReportCatalog catalog;
  std::map<std::string, size_t> preset_ids;
  std::map<std::string, size_t> instrument_ids;
  std::map<std::string, size_t> sample_ids;
  std::map<SampleWindowKey, size_t> window_ids;
  std::map<EnvelopeKey, size_t> envelope_ids;
  std::map<ModulatorSetKey, size_t> modulator_set_ids;
  std::map<ModulationKey, size_t> modulation_ids;
  catalog.region_refs.reserve(regions.size());
  for (const auto& r : regions) {
    RegionRefs refs;
    refs.preset = intern(r.preset, preset_ids, catalog.presets);
    refs.instrument = intern(r.instrument, instrument_ids, catalog.instruments);
    size_t sample = intern(r.sample_left, sample_ids, catalog.samples);
    SampleWindowKey window = {sample, r.base_addr, r.length, r.loop_start, r.loop_end};
    refs.sample_window = intern(window, window_ids, catalog.sample_windows);
    refs.envelope = intern(envelope_key(r), envelope_ids, catalog.envelopes);
    ModulatorSetKey modulator_set = modulator_set_key(r);
    size_t modulator_set_id = intern(modulator_set, modulator_set_ids, catalog.modulator_sets);
    refs.modulation = intern(ModulationKey{generator_key(r), modulator_set_id},
                             modulation_ids, catalog.modulations);
    for (const auto& group : r.modulators_by_destination) {
      for (const auto& mod : group.second) {
        catalog.sources.insert(mod.src);
        catalog.sources.insert(mod.amount_src);
        catalog.destinations.insert(mod.dest);
        catalog.transforms.insert(mod.transform);
      }
    }
    catalog.region_refs.push_back(refs);
  }
  return catalog;
}

}  // namespace

std::string json_string(const std::string& value) { return json_string_impl(value); }

void write_summary(const std::string& path, const std::vector<Region>& regions,
                   int sample_rate, int samples, int events,
                   const std::string& extra_fields) {
  std::ofstream f(path);
  if (!f) throw std::runtime_error("failed to open " + path);
  ReportCatalog catalog = build_catalog(regions);
  f << "{\n  \"report_schema_version\": 3"
    << ",\n  \"output_sample_rate\": " << sample_rate
    << ",\n  \"output_samples\": " << samples
    << ",\n  \"event_count\": " << events;
  if (!extra_fields.empty()) f << ",\n" << extra_fields;
  f << ",\n  \"sf2_loader\": {\"region_count\": " << regions.size() << "}"
    << ",\n  \"catalogs\": {\n"
    << "    \"presets\": [";
  for (size_t i = 0; i < catalog.presets.size(); ++i) {
    if (i != 0) f << ", ";
    f << json_string(catalog.presets[i]);
  }
  f << "],\n    \"instruments\": [";
  for (size_t i = 0; i < catalog.instruments.size(); ++i) {
    if (i != 0) f << ", ";
    f << json_string(catalog.instruments[i]);
  }
  f << "],\n    \"samples\": [";
  for (size_t i = 0; i < catalog.samples.size(); ++i) {
    if (i != 0) f << ", ";
    f << json_string(catalog.samples[i]);
  }
  f << "],\n    \"sample_windows\": [\n";
  for (size_t i = 0; i < catalog.sample_windows.size(); ++i) {
    const auto& w = catalog.sample_windows[i];
    f << "      {\"sample\": " << w[0] << ", \"base_addr\": " << w[1]
      << ", \"length\": " << w[2] << ", \"loop_start\": " << w[3]
      << ", \"loop_end\": " << w[4] << "}"
      << (i + 1 < catalog.sample_windows.size() ? "," : "") << "\n";
  }
  f << "    ],\n    \"volume_envelopes\": [\n";
  for (size_t i = 0; i < catalog.envelopes.size(); ++i) {
    f << "      ";
    write_envelope(f, catalog.envelopes[i]);
    f << (i + 1 < catalog.envelopes.size() ? "," : "") << "\n";
  }
  f << "    ],\n    \"modulator_sources\": [";
  size_t item = 0;
  for (uint16_t source : catalog.sources) {
    if (item++ != 0) f << ", ";
    write_modulator_source_descriptor(f, source);
  }
  f << "],\n    \"generator_destinations\": [";
  item = 0;
  for (uint16_t destination : catalog.destinations) {
    if (item++ != 0) f << ", ";
    f << "{\"raw\": " << destination << ", \"name\": "
      << json_string(generator_name(destination)) << "}";
  }
  f << "],\n    \"modulator_transforms\": [";
  item = 0;
  for (uint16_t transform : catalog.transforms) {
    if (item++ != 0) f << ", ";
    f << "{\"raw\": " << transform << ", \"name\": "
      << json_string(modulator_transform_name(transform)) << "}";
  }
  f << "],\n    \"modulator_sets\": [\n";
  for (size_t i = 0; i < catalog.modulator_sets.size(); ++i) {
    f << "      [";
    const auto& set = catalog.modulator_sets[i];
    for (size_t j = 0; j < set.size(); ++j) {
      const auto& mod = set[j];
      if (j != 0) f << ", ";
      f << "{\"src\": " << mod[0] << ", \"dest\": " << mod[1]
        << ", \"amount\": " << mod[2] << ", \"amount_src\": " << mod[3]
        << ", \"transform\": " << mod[4] << "}";
    }
    f << "]" << (i + 1 < catalog.modulator_sets.size() ? "," : "") << "\n";
  }
  f << "    ],\n    \"modulation_profiles\": [\n";
  for (size_t i = 0; i < catalog.modulations.size(); ++i) {
    f << "      {\"generators\": ";
    write_generators(f, catalog.modulations[i].first);
    f << ", \"modulator_set\": " << catalog.modulations[i].second << "}"
      << (i + 1 < catalog.modulations.size() ? "," : "") << "\n";
  }
  f << "    ]\n  },\n  \"regions\": [\n";
  for (size_t i = 0; i < regions.size(); ++i) {
    const auto& r = regions[i];
    const auto& refs = catalog.region_refs[i];
    f << "    {\"key\": " << r.key
      << ", \"program\": " << r.program << ", \"bank\": " << r.bank
      << ", \"preset\": " << refs.preset
      << ", \"instrument\": " << refs.instrument
      << ", \"sample_window\": " << refs.sample_window
      << ", \"phase_inc\": " << r.phase_inc
      << ", \"gain\": {\"pan\": " << r.pan << ", \"base_gain\": " << r.base_gain
      << ", \"base_gain_l\": " << r.base_gain_l << ", \"base_gain_r\": " << r.base_gain_r
      << ", \"left\": " << r.gain_l << ", \"right\": " << r.gain_r
      << "}, \"volume_envelope\": " << refs.envelope
      << ", \"filter\": {\"enable\": " << (r.filter_enable ? "true" : "false")
      << ", \"b0\": " << r.filter_b0 << ", \"b1\": " << r.filter_b1
      << ", \"b2\": " << r.filter_b2 << ", \"a1\": " << r.filter_a1
      << ", \"a2\": " << r.filter_a2 << "}, \"loop_mode\": " << r.loop_mode
      << ", \"modulation\": " << refs.modulation
      << "}" << (i + 1 < regions.size() ? "," : "") << "\n";
  }
  f << "  ]\n}\n";
}

std::string diagnostics_json_fields(const RenderDiagnostics& d) {
  std::ostringstream s;
  s << "  \"diagnostics_detailed_enabled\": " << (d.detailed_enabled ? "true" : "false")
    << ",\n  \"diagnostics_frames\": " << d.frames
    << ",\n  \"diagnostics_compressor_enabled\": "
    << (d.compressor_enabled ? "true" : "false")
    << ",\n  \"diagnostics_compressor_primed\": "
    << (d.compressor_primed ? "true" : "false")
    << ",\n  \"diagnostics_compressor_active\": "
    << (d.compressor_active ? "true" : "false")
    << ",\n  \"diagnostics_compressor_delay_level\": " << d.compressor_delay_level
    << ",\n  \"diagnostics_compressor_gain_reduction_cb_q12_20\": "
    << d.compressor_gain_reduction_cb_q12_20
    << ",\n  \"diagnostics_compressor_target_gain_reduction_cb_q12_20\": "
    << d.compressor_target_gain_reduction_cb_q12_20
    << ",\n  \"diagnostics_compressor_detector_peak\": " << d.compressor_detector_peak
    << ",\n  \"diagnostics_compressor_max_gain_reduction_cb_q12_20\": "
    << d.compressor_max_gain_reduction_cb_q12_20
    << ",\n  \"diagnostics_compressor_max_detector_peak\": "
    << d.compressor_max_detector_peak
    << ",\n  \"diagnostics_compressor_input_frame_count\": "
    << d.compressor_input_frame_count
    << ",\n  \"diagnostics_compressor_output_frame_count\": "
    << d.compressor_output_frame_count
    << ",\n  \"diagnostics_compressor_compressed_frame_count\": "
    << d.compressor_compressed_frame_count
    << ",\n  \"diagnostics_compressor_saturation_count\": "
    << d.compressor_saturation_count
    << ",\n  \"diagnostics_filter_y_saturated_frames\": " << d.filter_y_saturated_frames
    << ",\n  \"diagnostics_filter_y_saturations\": " << d.filter_y_saturations
    << ",\n  \"diagnostics_filter_state_saturated_frames\": " << d.filter_state_saturated_frames
    << ",\n  \"diagnostics_filter_state_saturations\": " << d.filter_state_saturations
    << ",\n  \"diagnostics_contribution_saturated_frames\": " << d.contribution_saturated_frames
    << ",\n  \"diagnostics_contribution_saturations\": " << d.contribution_saturations
    << ",\n  \"diagnostics_mix_saturated_frames\": " << d.mix_saturated_frames
    << ",\n  \"diagnostics_mix_saturations\": " << d.mix_saturations
    << ",\n  \"diagnostics_max_abs_filter_y_input\": " << d.max_abs_filter_y_input
    << ",\n  \"diagnostics_max_abs_filter_state_input\": " << d.max_abs_filter_state_input
    << ",\n  \"diagnostics_max_abs_voice_contribution_input_l\": " << d.max_abs_voice_contribution_input_l
    << ",\n  \"diagnostics_max_abs_voice_contribution_input_r\": " << d.max_abs_voice_contribution_input_r
    << ",\n  \"diagnostics_max_abs_mix_input_l\": " << d.max_abs_mix_input_l
    << ",\n  \"diagnostics_max_abs_mix_input_r\": " << d.max_abs_mix_input_r
    << ",\n  \"diagnostics_voice_steals\": " << d.voice_steals
    << ",\n  \"diagnostics_max_voice_steal_score\": " << d.max_voice_steal_score
    << ",\n  \"diagnostics_max_voice_steal_level\": " << d.max_voice_steal_level
    << ",\n  \"diagnostics_max_voice_steal_gain_l\": " << d.max_voice_steal_gain_l
    << ",\n  \"diagnostics_max_voice_steal_gain_r\": " << d.max_voice_steal_gain_r
    << ",\n  \"diagnostics_max_voice_steal_voice\": " << d.max_voice_steal_voice
    << ",\n  \"diagnostics_max_voice_steal_tick\": " << d.max_voice_steal_tick
    << ",\n  \"diagnostics_runtime_gain_updates\": " << d.runtime_gain_updates
    << ",\n  \"diagnostics_runtime_phase_updates\": " << d.runtime_phase_updates
    << ",\n  \"diagnostics_runtime_filter_updates\": " << d.runtime_filter_updates
    << ",\n  \"diagnostics_audible_envelope_updates\": " << d.audible_envelope_updates
    << ",\n  \"diagnostics_max_runtime_gain_jump_l\": " << d.max_runtime_gain_jump_l
    << ",\n  \"diagnostics_max_runtime_gain_jump_r\": " << d.max_runtime_gain_jump_r
    << ",\n  \"diagnostics_max_runtime_phase_inc_jump\": " << d.max_runtime_phase_inc_jump
    << ",\n  \"diagnostics_max_runtime_filter_coeff_jump\": " << d.max_runtime_filter_coeff_jump
    << ",\n  \"diagnostics_max_audible_envelope_jump\": " << d.max_audible_envelope_jump
    << ",\n  \"diagnostics_max_audible_envelope_jump_voice\": " << d.max_audible_envelope_jump_voice
    << ",\n  \"diagnostics_max_audible_envelope_jump_frame\": " << d.max_audible_envelope_jump_frame
    << ",\n  \"control_tick_count\": " << d.control_tick_count
    << ",\n  \"control_tick_total_ns\": " << d.control_tick_total_ns
    << ",\n  \"control_tick_max_ns\": " << d.control_tick_max_ns
    << ",\n  \"control_active_voices\": " << d.control_active_voices
    << ",\n  \"control_max_active_voices\": " << d.control_max_active_voices
    << ",\n  \"control_modulator_evaluations\": " << d.control_modulator_evaluations
    << ",\n  \"control_dirty_group_evaluations\": " << d.control_dirty_group_evaluations
    << ",\n  \"control_emitted_commands\": " << d.control_emitted_commands;
  return s.str();
}

}  // namespace render
