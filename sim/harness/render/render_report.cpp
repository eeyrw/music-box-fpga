#include "render_support.h"

#include <fstream>
#include <sstream>
#include <stdexcept>

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

void write_modulator_source_json(std::ostream& out, uint16_t source) {
  out << "{\"raw\": " << source
      << ", \"hex\": " << json_string_impl(hex16(source))
      << ", \"name\": " << json_string_impl(modulator_source_name(source))
      << ", \"cc\": " << ((source & 0x0080u) ? "true" : "false")
      << ", \"index\": " << (source & 0x007fu)
      << ", \"direction\": " << json_string_impl(((source >> 8) & 1u) ? "negative" : "positive")
      << ", \"polarity\": " << json_string_impl(((source >> 9) & 1u) ? "bipolar" : "unipolar")
      << ", \"type\": " << ((source >> 10) & 0x3fu) << "}";
}

void write_modulation_json(std::ostream& out, const Region& r) {
  out << "{\"generators\": {"
      << "\"mod_lfo\": {\"delay_ticks\": " << r.mod_lfo_delay_ticks
      << ", \"step\": " << r.mod_lfo_step
      << ", \"to_pitch\": " << r.mod_lfo_to_pitch
      << ", \"to_filter_fc\": " << r.mod_lfo_to_filter_fc
      << ", \"to_volume\": " << r.mod_lfo_to_volume
      << "}, \"vib_lfo\": {\"delay_ticks\": " << r.vib_lfo_delay_ticks
      << ", \"step\": " << r.vib_lfo_step
      << ", \"to_pitch\": " << r.vib_lfo_to_pitch
      << "}, \"mod_env\": {\"delay_ticks\": " << r.mod_env_delay_ticks
      << ", \"hold_ticks\": " << r.mod_env_hold_ticks
      << ", \"sustain_level\": " << r.mod_env_sustain_level
      << ", \"attack_ticks\": " << r.mod_env_attack_ticks
      << ", \"decay_ticks\": " << r.mod_env_decay_ticks
      << ", \"release_ticks\": " << r.mod_env_release_ticks
      << ", \"attack_sub_tick\": " << (r.mod_env_attack_sub_tick ? "true" : "false")
      << ", \"attack_step\": " << r.mod_env_attack_step
      << ", \"decay_step\": " << r.mod_env_decay_step
      << ", \"release_step\": " << r.mod_env_release_step
      << ", \"to_pitch\": " << r.mod_env_to_pitch
      << ", \"to_filter_fc\": " << r.mod_env_to_filter_fc
      << "}}, \"modulators\": [";
  for (size_t i = 0; i < r.modulators.size(); ++i) {
    const auto& mod = r.modulators[i];
    out << "{\"src\": ";
    write_modulator_source_json(out, mod.src);
    out << ", \"dest\": {\"raw\": " << mod.dest
        << ", \"name\": " << json_string_impl(generator_name(mod.dest))
        << "}, \"amount\": " << mod.amount << ", \"amount_src\": ";
    write_modulator_source_json(out, mod.amount_src);
    out << ", \"transform\": {\"raw\": " << mod.transform
        << ", \"name\": " << json_string_impl(modulator_transform_name(mod.transform)) << "}}";
    if (i + 1 < r.modulators.size()) out << ", ";
  }
  out << "]}";
}

}  // namespace

std::string json_string(const std::string& value) { return json_string_impl(value); }

void write_summary(const std::string& path, const std::vector<Region>& regions,
                   int sample_rate, int samples, int events,
                   const std::string& extra_fields) {
  std::ofstream f(path);
  if (!f) throw std::runtime_error("failed to open " + path);
  int mono_regions = 0;
  int linked_stereo_regions = 0;
  int hard_pan_stereo_regions = 0;
  for (const auto& r : regions) {
    if (r.stereo_source == "linked_sample") ++linked_stereo_regions;
    else if (r.stereo_source == "hard_pan_unlinked") ++hard_pan_stereo_regions;
    else ++mono_regions;
  }
  f << "{\n  \"output_sample_rate\": " << sample_rate
    << ",\n  \"output_samples\": " << samples
    << ",\n  \"event_count\": " << events;
  if (!extra_fields.empty()) f << ",\n" << extra_fields;
  f << ",\n  \"sf2_loader\": {\"mono_regions\": " << mono_regions
    << ", \"linked_stereo_regions\": " << linked_stereo_regions
    << ", \"hard_pan_stereo_regions\": " << hard_pan_stereo_regions << "}"
    << ",\n  \"regions\": [\n";
  for (size_t i = 0; i < regions.size(); ++i) {
    const auto& r = regions[i];
    f << "    {\"key\": " << r.key
      << ", \"program\": " << r.program << ", \"bank\": " << r.bank
      << ", \"preset\": " << json_string(r.preset)
      << ", \"instrument\": " << json_string(r.instrument)
      << ", \"stereo\": " << (r.stereo ? "true" : "false")
      << ", \"stereo_source\": " << json_string(r.stereo_source)
      << ", \"left\": {\"sample\": " << json_string(r.sample_left)
      << ", \"base_addr\": " << r.base_addr << ", \"length\": " << r.length
      << ", \"loop_start\": " << r.loop_start << ", \"loop_end\": " << r.loop_end
      << "}, \"right\": {\"sample\": " << json_string(r.sample_right)
      << ", \"base_addr\": " << r.base_addr_r << ", \"length\": " << r.length_r
      << ", \"loop_start\": " << r.loop_start_r << ", \"loop_end\": " << r.loop_end_r
      << "}, \"pitch\": {\"phase_inc\": " << r.phase_inc
      << "}, \"gain\": {\"pan\": " << r.pan << ", \"base_gain\": " << r.base_gain
      << ", \"base_gain_l\": " << r.base_gain_l << ", \"base_gain_r\": " << r.base_gain_r
      << ", \"left\": " << r.gain_l << ", \"right\": " << r.gain_r
      << "}, \"volume_envelope\": {\"delay_samples\": " << r.volume_envelope.delay_samples
      << ", \"attack_samples\": " << r.volume_envelope.attack_samples
      << ", \"hold_samples\": " << r.volume_envelope.hold_samples
      << ", \"decay_samples\": " << r.volume_envelope.decay_samples
      << ", \"sustain_cb_q12_20\": " << r.volume_envelope.sustain_cb_q12_20
      << ", \"release_samples\": " << r.volume_envelope.release_samples
      << ", \"policy_delay_ticks\": " << r.delay_ticks
      << ", \"policy_attack_ticks\": " << r.attack_ticks
      << ", \"policy_hold_ticks\": " << r.hold_ticks
      << ", \"policy_decay_ticks\": " << r.decay_ticks
      << ", \"policy_release_ticks\": " << r.release_ticks
      << "}, \"filter\": {\"enable\": " << (r.filter_enable ? "true" : "false")
      << ", \"b0\": " << r.filter_b0 << ", \"b1\": " << r.filter_b1
      << ", \"b2\": " << r.filter_b2 << ", \"a1\": " << r.filter_a1
      << ", \"a2\": " << r.filter_a2 << "}, \"loop_mode\": " << r.loop_mode
      << ", \"modulation\": ";
    write_modulation_json(f, r);
    f << "}" << (i + 1 < regions.size() ? "," : "") << "\n";
  }
  f << "  ]\n}\n";
}

std::string diagnostics_json_fields(const RenderDiagnostics& d) {
  std::ostringstream s;
  s << "  \"diagnostics_detailed_enabled\": " << (d.detailed_enabled ? "true" : "false")
    << ",\n  \"diagnostics_frames\": " << d.frames
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
    << ",\n  \"diagnostics_max_audible_envelope_jump_frame\": " << d.max_audible_envelope_jump_frame;
  return s.str();
}

}  // namespace render
