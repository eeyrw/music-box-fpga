#include "render_support.h"

#include "midi_parser.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <map>
#include <sstream>
#include <stdexcept>

namespace render {
namespace {

constexpr int kMidiDrumChannel = 9;
constexpr int kSf2PercussionBank = 128;
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
constexpr uint16_t kGenCoarseTune = 51;
constexpr uint16_t kGenFineTune = 52;
constexpr uint16_t kGenInitialAttenuation = 48;
constexpr uint16_t kModSrcNone = 0x0000;
constexpr uint16_t kModSrcNoteOnVelocity = 0x0502;
constexpr uint16_t kModSrcNoteOnVelocityFilter = 0x0102;
constexpr uint16_t kModSrcChannelPressure = 0x000d;
constexpr uint16_t kModSrcCc1 = 0x0081;
constexpr uint16_t kModSrcCc7 = 0x0587;
constexpr uint16_t kModSrcCc10 = 0x028a;
constexpr uint16_t kModSrcCc11 = 0x058b;
constexpr uint16_t kModSrcCc91 = 0x00db;
constexpr uint16_t kModSrcCc93 = 0x00dd;
constexpr uint16_t kModSrcPitchWheel = 0x020e;
constexpr uint16_t kModSrcPitchWheelSensitivity = 0x0010;
constexpr uint16_t kTransformLinear = 0;
constexpr uint16_t kTransformAbsoluteValue = 2;

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
    case kModSrcNone: return "none";
    case kModSrcNoteOnVelocity: return "noteOnVelocity";
    case kModSrcNoteOnVelocityFilter: return "noteOnVelocityFilter";
    case kModSrcChannelPressure: return "channelPressure";
    case kModSrcCc1: return "cc1ModWheel";
    case kModSrcCc7: return "cc7Volume";
    case kModSrcCc10: return "cc10Pan";
    case kModSrcCc11: return "cc11Expression";
    case kModSrcCc91: return "cc91ReverbSend";
    case kModSrcCc93: return "cc93ChorusSend";
    case kModSrcPitchWheel: return "pitchWheel";
    case kModSrcPitchWheelSensitivity: return "pitchWheelSensitivity";
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
  switch (transform) {
    case kTransformLinear: return "linear";
    case kTransformAbsoluteValue: return "absoluteValue";
    default: return "unknown";
  }
}

void write_modulator_source_json(std::ostream& out, uint16_t source) {
  out << "{\"raw\": " << source
      << ", \"hex\": " << json_string_impl(hex16(source))
      << ", \"name\": " << json_string_impl(modulator_source_name(source))
      << ", \"cc\": " << ((source & 0x0080u) ? "true" : "false")
      << ", \"index\": " << (source & 0x007fu)
      << ", \"direction\": " << json_string_impl(((source >> 8) & 1u) ? "negative" : "positive")
      << ", \"polarity\": " << json_string_impl(((source >> 9) & 1u) ? "bipolar" : "unipolar")
      << ", \"type\": " << ((source >> 10) & 0x3fu)
      << "}";
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
        << "}, \"amount\": " << mod.amount
        << ", \"amount_src\": ";
    write_modulator_source_json(out, mod.amount_src);
    out << ", \"transform\": {\"raw\": " << mod.transform
        << ", \"name\": " << json_string_impl(modulator_transform_name(mod.transform))
        << "}}";
    if (i + 1 < r.modulators.size()) out << ", ";
  }
  out << "]}";
}
bool is_no_matching_zone_error(const std::runtime_error& e) {
  return std::string(e.what()) == "no SF2 zone matches key/velocity";
}

int event_priority(const NoteEvent& e) {
  if (e.type != NoteEvent::EVENT_NOTE) return 0;
  return e.on ? 2 : 1;
}

int linear_ramp(int start, int target, int tick, int ticks) {
  double x = double(std::max(1, tick)) / double(std::max(1, ticks));
  return clamp_q15(int(std::round(double(start) + double(target - start) * x)));
}

int db_decay(int start, int target, int tick, int ticks) {
  if (tick >= ticks) return clamp_q15(target);
  if (start <= 0) return clamp_q15(target);
  double x = double(std::max(1, tick)) / double(std::max(1, ticks));
  double s = double(std::max(1, start));
  double t = double(std::max(1, target));
  return clamp_q15(int(std::round(s * std::pow(t / s, x))));
}

int db_release(int start, int tick, int ticks) {
  if (tick >= ticks) return 0;
  if (start <= 0) return 0;
  double x = double(std::max(1, tick)) / double(std::max(1, ticks));
  return clamp_q15(int(std::round(double(start) * std::pow(1.0 / double(std::max(1, start)), x))));
}

int linear_release(int start, int tick, int ticks) {
  return linear_ramp(start, 0, tick, ticks);
}

const std::vector<Sf2Modulator>& fallback_default_modulators() {
  static const std::vector<Sf2Modulator> mods = {
      {kModSrcNoteOnVelocity, kGenInitialAttenuation, 960, kModSrcNone, kTransformLinear},
      {kModSrcNoteOnVelocityFilter, kGenInitialFilterFc, -2400, kModSrcNone, kTransformLinear},
      {kModSrcChannelPressure, kGenVibLfoToPitch, 50, kModSrcNone, kTransformLinear},
      {kModSrcCc1, kGenVibLfoToPitch, 50, kModSrcNone, kTransformLinear},
      {kModSrcCc7, kGenInitialAttenuation, 960, kModSrcNone, kTransformLinear},
      {kModSrcCc10, kGenPan, 1000, kModSrcNone, kTransformLinear},
      {kModSrcCc11, kGenInitialAttenuation, 960, kModSrcNone, kTransformLinear},
      {kModSrcPitchWheel, 0, 12700, kModSrcPitchWheelSensitivity, kTransformLinear},
  };
  return mods;
}

bool is_note_on_source(uint16_t source) {
  if (source & 0x0080u) return false;
  int index = source & 0x007fu;
  return index == 2 || index == 3;
}

bool is_realtime_source(uint16_t source) {
  if (source == kModSrcNone) return false;
  if (source & 0x0080u) return true;
  int index = source & 0x007fu;
  return index == 10 || index == 13 || index == 14 || index == 16;
}

constexpr int kVelCbSize = 128;
constexpr double kPeakAttenuation = 960.0;
constexpr double kSourceClamp = 127.0 / 128.0;

const std::array<double, kVelCbSize>& concave_tab() {
  static const std::array<double, kVelCbSize> tab = [] {
    std::array<double, kVelCbSize> t{};
    for (int i = 0; i < kVelCbSize; ++i) {
      if (i == 0)
        t[i] = 0.0;
      else if (i == kVelCbSize - 1)
        t[i] = 1.0;
      else
        t[i] = (-200.0 * 2.0 / kPeakAttenuation) *
               std::log10(double((kVelCbSize - 1) - i) / double(kVelCbSize - 1));
    }
    return t;
  }();
  return tab;
}

const std::array<double, kVelCbSize>& convex_tab() {
  static const std::array<double, kVelCbSize> tab = [] {
    std::array<double, kVelCbSize> t{};
    for (int i = 0; i < kVelCbSize; ++i) {
      if (i == 0)
        t[i] = 0.0;
      else if (i == kVelCbSize - 1)
        t[i] = 1.0;
      else
        t[i] = 1.0 - (-200.0 * 2.0 / kPeakAttenuation) *
                         std::log10(double(i) / double(kVelCbSize - 1));
    }
    return t;
  }();
  return tab;
}

double curve_lookup(const std::array<double, kVelCbSize>& tab, double val) {
  if (val <= 0.0) return 0.0;
  if (val >= double(kVelCbSize - 1)) return tab[kVelCbSize - 1];
  int i = int(val);
  return tab[i] + (tab[i + 1] - tab[i]) * (val - double(i));
}

double concave_unit(double x) { return curve_lookup(concave_tab(), double(kVelCbSize) * x); }
double convex_unit(double x) { return curve_lookup(convex_tab(), double(kVelCbSize) * x); }

double shape_unipolar(double x, int type) {
  x = std::max(0.0, std::min(1.0, x));
  switch (type) {
    case 1:
      return std::min(concave_unit(x), kSourceClamp);
    case 2:
      return std::min(convex_unit(x), kSourceClamp);
    case 3:
      return x >= 0.5 ? 1.0 : 0.0;
    default:
      return x;
  }
}

double shape_bipolar(double v, int type) {
  v = std::max(-1.0, std::min(1.0, v));
  switch (type) {
    case 1:
      return v >= 0.0 ? std::min(concave_unit(v), kSourceClamp) : -concave_unit(-v);
    case 2:
      return v >= 0.0 ? std::min(convex_unit(v), kSourceClamp) : -convex_unit(-v);
    case 3:
      return v >= 0.0 ? 1.0 : -1.0;
    default:
      return v;
  }
}

int attenuation_to_q15(double attenuation_cb) {
  if (attenuation_cb <= 0.0) return kQ15Full;
  int level = int(std::round(double(kQ15Full) * std::pow(10.0, -attenuation_cb / 200.0)));
  return clamp_q15(level);
}

bool same_filter_config(const FilterConfig& a, const FilterConfig& b) {
  return a.enable == b.enable && a.b0 == b.b0 && a.b1 == b.b1 &&
         a.b2 == b.b2 && a.a1 == b.a1 && a.a2 == b.a2;
}

bool same_runtime_gain(int gain_l, int gain_r, int last_gain_l, int last_gain_r) {
  return gain_l == last_gain_l && gain_r == last_gain_r;
}

}  // namespace

std::string json_string(const std::string& value) {
  return json_string_impl(value);
}

std::string render_input_json_fields(const Args& args, int adsr_tick_samples) {
  std::ostringstream s;
  s << "  \"sf2_path\": " << json_string_impl(args.sf2)
    << ",\n  \"midi_path\": ";
  if (args.midi.empty())
    s << "null";
  else
    s << json_string_impl(args.midi);
  s << ",\n  \"uses_default_melody\": " << (args.midi.empty() ? "true" : "false")
    << ",\n  \"instrument_override\": ";
  if (args.instrument.empty())
    s << "null";
  else
    s << json_string_impl(args.instrument);
  s << ",\n  \"key\": " << args.key
    << ",\n  \"requested_seconds\": " << args.seconds
    << ",\n  \"adsr_tick_ms\": " << args.adsr_tick_ms
    << ",\n  \"adsr_tick_samples\": " << adsr_tick_samples
    << ",\n  \"render_num_voices\": " << kNumVoices
    << ",\n  \"memory_profile\": " << json_string_impl(args.memory_profile);
  return s.str();
}

Args parse_args(int argc, char** argv) {
  Args args;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto need = [&](const char* name) -> std::string {
      if (i + 1 >= argc) throw std::runtime_error(std::string("missing value for ") + name);
      return argv[++i];
    };
    if (a == "--sf2") args.sf2 = need("--sf2");
    else if (a == "--midi") args.midi = need("--midi");
    else if (a == "--instrument") args.instrument = need("--instrument");
    else if (a == "--key") args.key = std::stoi(need("--key"));
    else if (a == "--seconds") args.seconds = std::stod(need("--seconds"));
    else if (a == "--sample-rate") args.sample_rate = std::stoi(need("--sample-rate"));
    else if (a == "--adsr-tick-ms") args.adsr_tick_ms = std::stod(need("--adsr-tick-ms"));
    else if (a == "--memory-profile") args.memory_profile = need("--memory-profile");
    else if (a == "--out-dir") args.out_dir = need("--out-dir");
    else throw std::runtime_error("unknown argument: " + a);
  }
  return args;
}

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
  f << ",\n  \"sf2_loader\": {"
    << "\"mono_regions\": " << mono_regions
    << ", \"linked_stereo_regions\": " << linked_stereo_regions
    << ", \"hard_pan_stereo_regions\": " << hard_pan_stereo_regions
    << "}";
  f << ",\n  \"regions\": [\n";
  for (size_t i = 0; i < regions.size(); ++i) {
    const auto& r = regions[i];
    f << "    {\"key\": " << r.key
      << ", \"program\": " << r.program
      << ", \"bank\": " << r.bank
      << ", \"preset\": " << json_string(r.preset)
      << ", \"instrument\": " << json_string(r.instrument)
      << ", \"stereo\": " << (r.stereo ? "true" : "false")
      << ", \"stereo_source\": " << json_string(r.stereo_source)
      << ", \"left\": {\"sample\": " << json_string(r.sample_left)
      << ", \"base_addr\": " << r.base_addr
      << ", \"length\": " << r.length
      << ", \"loop_start\": " << r.loop_start
      << ", \"loop_end\": " << r.loop_end
      << "}, \"right\": {\"sample\": " << json_string(r.sample_right)
      << ", \"base_addr\": " << r.base_addr_r
      << ", \"length\": " << r.length_r
      << ", \"loop_start\": " << r.loop_start_r
      << ", \"loop_end\": " << r.loop_end_r
      << "}, \"pitch\": {\"phase_inc\": " << r.phase_inc
      << "}, \"gain\": {\"pan\": " << r.pan
      << ", \"base_gain\": " << r.base_gain
      << ", \"base_gain_l\": " << r.base_gain_l
      << ", \"base_gain_r\": " << r.base_gain_r
      << ", \"left\": " << r.gain_l
      << ", \"right\": " << r.gain_r
      << ", \"initial_envelope\": " << r.initial_envelope
      << "}, \"volume_envelope\": {\"delay_ticks\": " << r.delay_ticks
      << ", \"hold_ticks\": " << r.hold_ticks
      << ", \"sustain_level\": " << r.sustain_level
      << ", \"attack_ticks\": " << r.attack_ticks
      << ", \"decay_ticks\": " << r.decay_ticks
      << ", \"release_ticks\": " << r.release_ticks
      << ", \"attack_step\": " << r.attack_step
      << ", \"decay_step\": " << r.decay_step
      << ", \"release_step\": " << r.release_step
      << "}, \"filter\": {\"enable\": " << (r.filter_enable ? "true" : "false")
      << ", \"b0\": " << r.filter_b0
      << ", \"b1\": " << r.filter_b1
      << ", \"b2\": " << r.filter_b2
      << ", \"a1\": " << r.filter_a1
      << ", \"a2\": " << r.filter_a2
      << "}, \"loop_mode\": " << r.loop_mode
      << ", \"modulation\": ";
    write_modulation_json(f, r);
    f << "}"
      << (i + 1 < regions.size() ? "," : "") << "\n";
  }
  f << "  ]\n}\n";
}

std::string diagnostics_json_fields(const RenderDiagnostics& d) {
  std::ostringstream s;
  s << "  \"diagnostics_frames\": " << d.frames
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
    << ",\n  \"diagnostics_runtime_envelope_updates\": " << d.runtime_envelope_updates
    << ",\n  \"diagnostics_runtime_gain_updates\": " << d.runtime_gain_updates
    << ",\n  \"diagnostics_runtime_phase_updates\": " << d.runtime_phase_updates
    << ",\n  \"diagnostics_runtime_filter_updates\": " << d.runtime_filter_updates
    << ",\n  \"diagnostics_max_runtime_envelope_jump\": " << d.max_runtime_envelope_jump
    << ",\n  \"diagnostics_max_runtime_envelope_jump_voice\": " << d.max_runtime_envelope_jump_voice
    << ",\n  \"diagnostics_max_runtime_envelope_jump_tick\": " << d.max_runtime_envelope_jump_tick
    << ",\n  \"diagnostics_max_runtime_gain_jump_l\": " << d.max_runtime_gain_jump_l
    << ",\n  \"diagnostics_max_runtime_gain_jump_r\": " << d.max_runtime_gain_jump_r
    << ",\n  \"diagnostics_max_runtime_phase_inc_jump\": " << d.max_runtime_phase_inc_jump
    << ",\n  \"diagnostics_max_runtime_filter_coeff_jump\": " << d.max_runtime_filter_coeff_jump;
  return s.str();
}

void prepare_events_and_regions(const Args& args, const Sf2Data& sf2, int sample_count,
                                int adsr_tick_samples, std::vector<NoteEvent>& events,
                                std::vector<Region>& regions,
                                std::vector<int16_t>& wave_memory) {
  double render_seconds = double(sample_count) / double(args.sample_rate);
  events.erase(std::remove_if(events.begin(), events.end(), [&](const NoteEvent& e) {
                 return e.time_seconds >= render_seconds;
               }), events.end());
  if (events.empty()) throw std::runtime_error("no MIDI events fall inside the requested render window");

  std::sort(events.begin(), events.end(), [](const NoteEvent& a, const NoteEvent& b) {
    if (a.time_seconds != b.time_seconds) return a.time_seconds < b.time_seconds;
    if (event_priority(a) != event_priority(b)) return event_priority(a) < event_priority(b);
    if (a.on != b.on) return !a.on;
    return a.note < b.note;
  });

  std::map<std::array<int, 4>, std::vector<int>> region_by_key;
  int forced_inst = args.instrument.empty() ? -1 : select_instrument(sf2, args.instrument);
  std::vector<NoteEvent> expanded_events;
  int playable_note_ons = 0;

  for (auto& e : events) {
    if (e.type != NoteEvent::EVENT_NOTE || !e.on) {
      expanded_events.push_back(e);
      continue;
    }
    int key = std::max(0, std::min(127, e.note));
    int velocity = std::max(1, std::min(127, e.velocity));
    int program = std::max(0, std::min(127, e.program));
    int bank = e.channel == kMidiDrumChannel ? kSf2PercussionBank : std::max(0, std::min(16383, e.bank));
    std::array<int, 4> region_key = {forced_inst >= 0 ? forced_inst : program, bank, key, velocity};
    auto it = region_by_key.find(region_key);
    if (it == region_by_key.end()) {
      std::vector<Region> made;
      try {
        made = forced_inst >= 0
          ? make_regions_for_instrument(sf2, forced_inst, key, velocity, args.sample_rate, adsr_tick_samples, wave_memory)
          : make_regions_for_preset(sf2, program, bank, key, velocity, args.sample_rate, adsr_tick_samples, wave_memory);
      } catch (const std::runtime_error& ex) {
        if (!is_no_matching_zone_error(ex)) throw;
      }
      std::vector<int> indices;
      for (auto& r : made) {
        indices.push_back(int(regions.size()));
        regions.push_back(r);
      }
      region_by_key[region_key] = indices;
      it = region_by_key.find(region_key);
    }
    if (it->second.empty()) continue;
    for (int idx : it->second) {
      NoteEvent layered = e;
      layered.region = idx;
      layered.phase_inc = regions[layered.region].phase_inc;
      expanded_events.push_back(layered);
      ++playable_note_ons;
    }
  }
  events.swap(expanded_events);

  if (playable_note_ons == 0) {
    throw std::runtime_error("no playable MIDI note-on events matched the selected SF2 regions");
  }

  for (const auto& r : regions) {
    uint32_t last_l = r.base_addr + (r.length ? r.length - 1 : 0);
    uint32_t last_r = r.base_addr_r + (r.length_r ? r.length_r - 1 : 0);
    if (r.length != 0 && (last_l >= wave_memory.size() ||
        (r.stereo && (r.length_r == 0 || last_r >= wave_memory.size())))) {
      throw std::runtime_error("selected SF2 region points outside the wave memory image");
    }
  }

  for (auto& e : events) {
    e.sample = std::max(0, std::min(sample_count, int(std::round(e.time_seconds * args.sample_rate))));
  }
  std::sort(events.begin(), events.end(), [](const NoteEvent& a, const NoteEvent& b) {
    if (a.sample != b.sample) return a.sample < b.sample;
    if (event_priority(a) != event_priority(b)) return event_priority(a) < event_priority(b);
    if (a.on != b.on) return !a.on;
    return a.note < b.note;
  });
}

McuModel::McuModel(VoiceControlSink& sink, const std::vector<Region>& regions,
                   RenderDiagnostics* diagnostics)
    : sink_(sink), regions_(regions), diagnostics_(diagnostics) {}

void McuModel::handle_event(const NoteEvent& event) {
  if (event.type == NoteEvent::EVENT_CONTROL) control_change(event);
  else if (event.type == NoteEvent::EVENT_PITCH_BEND) pitch_bend(event);
  else if (event.type == NoteEvent::EVENT_CHANNEL_PRESSURE) channel_pressure(event);
  else if (event.type == NoteEvent::EVENT_KEY_PRESSURE) key_pressure(event);
  else if (event.type == NoteEvent::EVENT_NOTE && event.on) note_on(event);
  else if (event.type == NoteEvent::EVENT_NOTE) note_off(event.channel, event.note);
}

void McuModel::envelope_tick() {
  for (int v = 0; v < kNumVoices; ++v) {
    int next = voices_[v].level;
    if (voices_[v].state == ENV_DELAY) {
      if (voices_[v].ticks_remaining > 0) --voices_[v].ticks_remaining;
      if (voices_[v].ticks_remaining == 0) voices_[v].state = ENV_ATTACK;
    } else if (voices_[v].state == ENV_ATTACK) {
      const Region& r = regions_.at(voices_[v].region);
      voices_[v].env_stage_tick += 1;
      next = linear_ramp(0, voices_[v].target, voices_[v].env_stage_tick, r.attack_ticks);
      if (voices_[v].env_stage_tick >= r.attack_ticks) {
        next = voices_[v].target;
        voices_[v].ticks_remaining = r.hold_ticks;
        voices_[v].env_stage_tick = 0;
        voices_[v].state = voices_[v].ticks_remaining > 0 ? ENV_HOLD : ENV_DECAY;
      }
    } else if (voices_[v].state == ENV_HOLD) {
      if (voices_[v].ticks_remaining > 0) --voices_[v].ticks_remaining;
      if (voices_[v].ticks_remaining == 0) voices_[v].state = ENV_DECAY;
    } else if (voices_[v].state == ENV_DECAY) {
      const Region& r = regions_.at(voices_[v].region);
      voices_[v].env_stage_tick += 1;
      next = db_decay(voices_[v].target, voices_[v].sustain, voices_[v].env_stage_tick, r.decay_ticks);
      if (voices_[v].env_stage_tick >= r.decay_ticks) {
        next = voices_[v].sustain;
        voices_[v].env_stage_tick = 0;
        voices_[v].state = ENV_SUSTAIN;
      }
    } else if (voices_[v].state == ENV_RELEASE) {
      const Region& r = regions_.at(voices_[v].region);
      voices_[v].env_stage_tick += 1;
      next = db_release(voices_[v].release_start, voices_[v].env_stage_tick, r.release_ticks);
      if (voices_[v].env_stage_tick >= r.release_ticks) {
        next = 0;
        voices_[v].state = ENV_SILENT;
        voices_[v].sustain_held = false;
        voices_[v].mod_env_state = ENV_SILENT;
        sink_.commit_voice(v, 0, 0, regions_.front());
      }
    }

    if (voices_[v].state != ENV_SILENT || voices_[v].level != 0) {
      voices_[v].level = clamp_q15(next);
      record_runtime_envelope_update(v, voices_[v].level);
      sink_.set_envelope(v, voices_[v].level);
      update_voice_modulation(v);
    }
  }
  envelope_tick_index_ += 1;
}

void McuModel::control_change(const NoteEvent& event) {
  int channel = event.channel & 0x0f;
  int value = std::max(0, std::min(127, event.value));
  channels_[channel].cc[event.controller & 0x7f] = value;
  switch (event.controller & 0x7f) {
    case 1:
      channels_[channel].modulation = value;
      update_channel_controls(channel);
      break;
    case 7:
      channels_[channel].volume = value;
      update_channel_controls(channel);
      break;
    case 10:
      channels_[channel].pan = value;
      update_channel_controls(channel);
      break;
    case 11:
      channels_[channel].expression = value;
      update_channel_controls(channel);
      break;
    case 66:
      channels_[channel].soft = value >= 64;
      update_channel_controls(channel);
      break;
    case 67:
      if (value >= 64 && !channels_[channel].sostenuto) {
        channels_[channel].sostenuto = true;
        for (int v = 0; v < kNumVoices; ++v) {
          if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel && !voices_[v].key_released) {
            voices_[v].sostenuto_held = true;
          }
        }
      } else if (value < 64 && channels_[channel].sostenuto) {
        channels_[channel].sostenuto = false;
        for (int v = 0; v < kNumVoices; ++v) {
          if (voices_[v].channel == channel) voices_[v].sostenuto_held = false;
        }
        release_deferred_pedal_voices(channel);
      }
      break;
    case 98:
      channels_[channel].nrpn_generator = value < 100 ? channels_[channel].nrpn_base + value : -1;
      if (value == 100) channels_[channel].nrpn_base = 100;
      else if (value == 101) channels_[channel].nrpn_base = 1000;
      else if (value == 102) channels_[channel].nrpn_base = 10000;
      else if (value < 100) channels_[channel].nrpn_base = 0;
      channels_[channel].data_entry_is_nrpn = true;
      break;
    case 99:
      channels_[channel].nrpn_msb = value;
      channels_[channel].data_entry_is_nrpn = true;
      if (value != 120) channels_[channel].nrpn_generator = -1;
      break;
    case 100:
      channels_[channel].rpn_lsb = value;
      channels_[channel].data_entry_is_nrpn = false;
      break;
    case 101:
      channels_[channel].rpn_msb = value;
      channels_[channel].data_entry_is_nrpn = false;
      break;
    case 6:
      apply_data_entry_msb(channel, value);
      break;
    case 38:
      channels_[channel].data_entry_lsb = value;
      break;
    case 64:
      if (value >= 64) {
        channels_[channel].sustain = true;
      } else {
        channels_[channel].sustain = false;
        release_deferred_pedal_voices(channel);
      }
      break;
    case 120:
      for (int v = 0; v < kNumVoices; ++v) {
        if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel) {
          voices_[v].state = ENV_SILENT;
          voices_[v].level = 0;
          voices_[v].sustain_held = false;
          voices_[v].sostenuto_held = false;
          voices_[v].mod_env_state = ENV_SILENT;
          record_runtime_envelope_update(v, 0);
          sink_.set_envelope(v, 0);
          sink_.commit_voice(v, 0, 0, regions_.front());
        }
      }
      break;
    case 121:
      reset_controllers(channel);
      update_channel_controls(channel);
      release_deferred_pedal_voices(channel);
      break;
    case 123:
      for (int v = 0; v < kNumVoices; ++v) {
        if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel) release_voice(v);
      }
      break;
    default:
      break;
  }
}

void McuModel::channel_pressure(const NoteEvent& event) {
  int channel = event.channel & 0x0f;
  channels_[channel].channel_pressure = std::max(0, std::min(127, event.value));
  update_channel_controls(channel);
}

void McuModel::key_pressure(const NoteEvent& event) {
  int channel = event.channel & 0x0f;
  int note = event.note & 0x7f;
  channels_[channel].key_pressure[note] = std::max(0, std::min(127, event.value));
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel && voices_[v].note == note) {
      update_voice_controls(v);
    }
  }
}

void McuModel::pitch_bend(const NoteEvent& event) {
  int channel = event.channel & 0x0f;
  channels_[channel].pitch_bend = std::max(-8192, std::min(8191, event.pitch_bend));
  update_channel_controls(channel);
}

void McuModel::release_deferred_pedal_voices(int channel) {
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state == ENV_SILENT || voices_[v].channel != channel || !voices_[v].key_released) continue;
    if (channels_[channel].sustain || voices_[v].sostenuto_held) continue;
    voices_[v].sustain_held = false;
    release_voice(v);
  }
}

void McuModel::apply_data_entry_msb(int channel, int value) {
  ChannelState& c = channels_[channel];
  int data14 = (std::max(0, std::min(127, value)) << 7) | std::max(0, std::min(127, c.data_entry_lsb));
  if (c.data_entry_is_nrpn && c.nrpn_msb == 120 && c.nrpn_generator >= 0 &&
      c.nrpn_generator < int(c.generator_offsets.size())) {
    double centered = double(data14 - 0x2000) / 8192.0;
    auto range = [](int generator) -> double {
      switch (generator) {
        case kGenInitialFilterFc:
        case kGenModLfoToPitch:
        case kGenVibLfoToPitch:
        case kGenModEnvToPitch:
        case kGenModLfoToFilterFc:
        case kGenModEnvToFilterFc:
          return 6000.0;
        case kGenModLfoToVolume:
          return 1920.0;
        case kGenPan:
          return 1000.0;
        case kGenInitialAttenuation:
          return 1440.0;
        case kGenCoarseTune:
          return 240.0;
        case kGenFineTune:
          return 198.0;
        default:
          return 0.0;
      }
    };
    double span = range(c.nrpn_generator);
    if (span > 0.0) {
      c.generator_offsets[c.nrpn_generator] = centered * span;
      update_channel_controls(channel);
    }
    return;
  }

  if (!c.data_entry_is_nrpn && c.rpn_msb == 0 && c.rpn_lsb == 0) {
    c.pitch_bend_range_semitones = std::max(0, std::min(127, value));
    c.pitch_bend_range_cents = c.data_entry_lsb;
    update_channel_controls(channel);
  } else if (!c.data_entry_is_nrpn && c.rpn_msb == 0 && c.rpn_lsb == 1) {
    c.generator_offsets[kGenFineTune] = (double(data14) - 8192.0) * 100.0 / 8192.0;
    update_channel_controls(channel);
  } else if (!c.data_entry_is_nrpn && c.rpn_msb == 0 && c.rpn_lsb == 2) {
    c.generator_offsets[kGenCoarseTune] = double(std::max(0, std::min(127, value)) - 64) * 100.0;
    update_channel_controls(channel);
  }
}

void McuModel::reset_controllers(int channel) {
  ChannelState& c = channels_[channel];
  c.cc.fill(0);
  c.key_pressure.fill(0);
  c.generator_offsets.fill(0.0);
  c.volume = 127;
  c.expression = 127;
  c.pan = 64;
  c.pitch_bend = 0;
  c.modulation = 0;
  c.channel_pressure = 0;
  c.rpn_msb = 127;
  c.rpn_lsb = 127;
  c.nrpn_msb = 127;
  c.nrpn_base = 0;
  c.nrpn_generator = -1;
  c.data_entry_lsb = 0;
  c.pitch_bend_range_semitones = 2;
  c.pitch_bend_range_cents = 0;
  c.sustain = false;
  c.soft = false;
  c.sostenuto = false;
  c.data_entry_is_nrpn = false;
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].channel == channel) {
      voices_[v].sustain_held = false;
      voices_[v].sostenuto_held = false;
    }
  }
}

void McuModel::record_runtime_gain_update(int voice, int gain_l, int gain_r) {
  if (diagnostics_) {
    diagnostics_->runtime_gain_updates += 1;
    if (runtime_gain_valid_[voice]) {
      auto diff = [](int a, int b) {
        return uint32_t(std::abs(int64_t(a) - int64_t(b)));
      };
      diagnostics_->max_runtime_gain_jump_l = std::max(diagnostics_->max_runtime_gain_jump_l,
                                                       diff(gain_l, last_runtime_gain_l_[voice]));
      diagnostics_->max_runtime_gain_jump_r = std::max(diagnostics_->max_runtime_gain_jump_r,
                                                       diff(gain_r, last_runtime_gain_r_[voice]));
    }
  }
  runtime_gain_valid_[voice] = true;
  last_runtime_gain_l_[voice] = gain_l;
  last_runtime_gain_r_[voice] = gain_r;
}

void McuModel::record_runtime_phase_update(int voice, uint32_t phase_inc) {
  if (diagnostics_) {
    diagnostics_->runtime_phase_updates += 1;
    if (runtime_phase_valid_[voice]) {
      uint32_t jump = phase_inc >= last_runtime_phase_inc_[voice]
                          ? phase_inc - last_runtime_phase_inc_[voice]
                          : last_runtime_phase_inc_[voice] - phase_inc;
      diagnostics_->max_runtime_phase_inc_jump = std::max(diagnostics_->max_runtime_phase_inc_jump, jump);
    }
  }
  runtime_phase_valid_[voice] = true;
  last_runtime_phase_inc_[voice] = phase_inc;
}

void McuModel::record_runtime_filter_update(int voice, const FilterConfig& filter) {
  if (diagnostics_) {
    diagnostics_->runtime_filter_updates += 1;
    if (runtime_filter_valid_[voice]) {
      const FilterConfig& last = last_runtime_filter_[voice];
      auto diff = [](int a, int b) {
        return uint32_t(std::abs(int64_t(a) - int64_t(b)));
      };
      uint32_t max_jump = 0;
      max_jump = std::max(max_jump, diff(filter.b0, last.b0));
      max_jump = std::max(max_jump, diff(filter.b1, last.b1));
      max_jump = std::max(max_jump, diff(filter.b2, last.b2));
      max_jump = std::max(max_jump, diff(filter.a1, last.a1));
      max_jump = std::max(max_jump, diff(filter.a2, last.a2));
      if (filter.enable != last.enable) max_jump = std::max(max_jump, uint32_t(1));
      diagnostics_->max_runtime_filter_coeff_jump = std::max(diagnostics_->max_runtime_filter_coeff_jump,
                                                             max_jump);
    }
  }
  runtime_filter_valid_[voice] = true;
  last_runtime_filter_[voice] = filter;
}

void McuModel::update_channel_controls(int channel) {
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel) update_voice_controls(v);
  }
}

void McuModel::update_voice_controls(int voice) {
  const VoiceState& state = voices_.at(voice);
  const Region& r = regions_.at(state.region);
  const ChannelState& c = channels_.at(state.channel & 0x0f);
  auto gains = runtime_gains(r, state, c);
  if (!runtime_gain_valid_[voice] ||
      !same_runtime_gain(gains.first, gains.second, last_runtime_gain_l_[voice], last_runtime_gain_r_[voice])) {
    record_runtime_gain_update(voice, gains.first, gains.second);
    sink_.set_gain(voice, gains.first, gains.second);
  }
  update_voice_modulation(voice);
}

void McuModel::update_voice_modulation(int voice) {
  VoiceState& state = voices_.at(voice);
  if (state.state == ENV_SILENT) return;
  const Region& r = regions_.at(state.region);
  const ChannelState& c = channels_.at(state.channel & 0x0f);

  int mod_next = state.mod_env_level;
  if (state.mod_env_state == ENV_DELAY) {
    if (state.mod_env_ticks_remaining > 0) --state.mod_env_ticks_remaining;
    if (state.mod_env_ticks_remaining == 0) state.mod_env_state = ENV_ATTACK;
  } else if (state.mod_env_state == ENV_ATTACK) {
    state.mod_env_stage_tick += 1;
    mod_next = linear_ramp(0, kQ15Full, state.mod_env_stage_tick, r.mod_env_attack_ticks);
    if (state.mod_env_stage_tick >= r.mod_env_attack_ticks) {
      mod_next = kQ15Full;
      state.mod_env_ticks_remaining = r.mod_env_hold_ticks;
      state.mod_env_stage_tick = 0;
      state.mod_env_state = state.mod_env_ticks_remaining > 0 ? ENV_HOLD : ENV_DECAY;
    }
  } else if (state.mod_env_state == ENV_HOLD) {
    if (state.mod_env_ticks_remaining > 0) --state.mod_env_ticks_remaining;
    if (state.mod_env_ticks_remaining == 0) state.mod_env_state = ENV_DECAY;
  } else if (state.mod_env_state == ENV_DECAY) {
    state.mod_env_stage_tick += 1;
    mod_next = linear_ramp(kQ15Full, r.mod_env_sustain_level, state.mod_env_stage_tick, r.mod_env_decay_ticks);
    if (state.mod_env_stage_tick >= r.mod_env_decay_ticks) {
      mod_next = r.mod_env_sustain_level;
      state.mod_env_stage_tick = 0;
      state.mod_env_state = ENV_SUSTAIN;
    }
  } else if (state.mod_env_state == ENV_RELEASE) {
    state.mod_env_stage_tick += 1;
    mod_next = linear_release(state.mod_env_release_start, state.mod_env_stage_tick, r.mod_env_release_ticks);
    if (state.mod_env_stage_tick >= r.mod_env_release_ticks) {
      mod_next = 0;
      state.mod_env_state = ENV_SILENT;
    }
  }
  state.mod_env_level = clamp_q15(mod_next);

  auto lfo_value = [](uint32_t phase) {
    double x = double(phase & 0xffffu) / 65536.0;
    if (x < 0.25) return x * 4.0;
    if (x < 0.75) return 2.0 - x * 4.0;
    return x * 4.0 - 4.0;
  };
  double mod_lfo = state.mod_lfo_wait_ticks > 0 ? 0.0 : lfo_value(state.mod_lfo_phase);
  double vib_lfo = state.vib_lfo_wait_ticks > 0 ? 0.0 : lfo_value(state.vib_lfo_phase);
  double env = double(state.mod_env_level) / double(kQ15Full);

  double pitch_cents = c.generator_offsets[kGenFineTune] + c.generator_offsets[kGenCoarseTune] +
                       modulator_sum(r, state, c, 0);
  pitch_cents += mod_lfo * (double(r.mod_lfo_to_pitch) + c.generator_offsets[kGenModLfoToPitch] +
                            modulator_sum(r, state, c, kGenModLfoToPitch));
  pitch_cents += vib_lfo * (double(r.vib_lfo_to_pitch) + modulator_sum(r, state, c, kGenVibLfoToPitch));
  pitch_cents += env * (double(r.mod_env_to_pitch) + modulator_sum(r, state, c, kGenModEnvToPitch));
  uint32_t phase_inc = modulated_phase_inc(r.phase_inc, pitch_cents);
  if (!runtime_phase_valid_[voice] || phase_inc != last_runtime_phase_inc_[voice]) {
    record_runtime_phase_update(voice, phase_inc);
    sink_.set_phase_inc(voice, phase_inc);
  }

  double filter_cents = double(r.initial_filter_fc) + c.generator_offsets[kGenInitialFilterFc] +
                        modulator_sum(r, state, c, kGenInitialFilterFc) +
                        mod_lfo * (double(r.mod_lfo_to_filter_fc) +
                                   c.generator_offsets[kGenModLfoToFilterFc] +
                                   modulator_sum(r, state, c, kGenModLfoToFilterFc)) +
                        env * (double(r.mod_env_to_filter_fc) +
                               c.generator_offsets[kGenModEnvToFilterFc] +
                               modulator_sum(r, state, c, kGenModEnvToFilterFc));
  FilterConfig filter = filter_for(int(std::round(filter_cents)), r.initial_filter_q, r.output_sample_rate);
  if (!runtime_filter_valid_[voice] || !same_filter_config(filter, last_runtime_filter_[voice])) {
    record_runtime_filter_update(voice, filter);
    sink_.set_filter(voice, filter);
  }
  state.tremolo_attenuation_cb = -mod_lfo * (double(r.mod_lfo_to_volume) +
                                            c.generator_offsets[kGenModLfoToVolume] +
                                            modulator_sum(r, state, c, kGenModLfoToVolume));
  auto gains = runtime_gains(r, state, c);
  if (!runtime_gain_valid_[voice] ||
      !same_runtime_gain(gains.first, gains.second, last_runtime_gain_l_[voice], last_runtime_gain_r_[voice])) {
    record_runtime_gain_update(voice, gains.first, gains.second);
    sink_.set_gain(voice, gains.first, gains.second);
  }

  if (state.mod_lfo_wait_ticks > 0) --state.mod_lfo_wait_ticks;
  else state.mod_lfo_phase += r.mod_lfo_step;
  if (state.vib_lfo_wait_ticks > 0) --state.vib_lfo_wait_ticks;
  else state.vib_lfo_phase += r.vib_lfo_step;
}

void McuModel::prime_runtime_envelope_level(int voice, int level) {
  runtime_envelope_valid_[voice] = true;
  last_runtime_envelope_level_[voice] = clamp_q15(level);
}

void McuModel::record_runtime_envelope_update(int voice, int level) {
  level = clamp_q15(level);
  if (diagnostics_) {
    diagnostics_->runtime_envelope_updates += 1;
    if (runtime_envelope_valid_[voice]) {
      uint32_t jump = level >= last_runtime_envelope_level_[voice]
                          ? uint32_t(level - last_runtime_envelope_level_[voice])
                          : uint32_t(last_runtime_envelope_level_[voice] - level);
      if (jump > diagnostics_->max_runtime_envelope_jump) {
        diagnostics_->max_runtime_envelope_jump = jump;
        diagnostics_->max_runtime_envelope_jump_voice = voice;
        diagnostics_->max_runtime_envelope_jump_tick = envelope_tick_index_;
      }
    }
  }
  runtime_envelope_valid_[voice] = true;
  last_runtime_envelope_level_[voice] = level;
}

void McuModel::release_voice(int voice) {
  voices_[voice].state = ENV_RELEASE;
  voices_[voice].env_stage_tick = 0;
  voices_[voice].release_start = voices_[voice].level;
  voices_[voice].mod_env_state = ENV_RELEASE;
  voices_[voice].mod_env_stage_tick = 0;
  voices_[voice].mod_env_release_start = voices_[voice].mod_env_level;
  voices_[voice].sustain_held = false;
  sink_.release_voice(voice, regions_.at(voices_[voice].region));
}

void McuModel::note_off(int channel, int note) {
  channel &= 0x0f;
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state != ENV_SILENT && voices_[v].channel == channel && voices_[v].note == (note & 0x7f)) {
      voices_[v].key_released = true;
      if (channels_[channel].sustain) voices_[v].sustain_held = true;
      if (voices_[v].sostenuto_held) {
        continue;
      }
      if (channels_[channel].sustain) continue;
      else release_voice(v);
    }
  }
}

void McuModel::note_on(const NoteEvent& event) {
  if (event.velocity == 0) {
    note_off(event.channel, event.note);
    return;
  }

  int slot = first_free_or_steal_slot();
  if (voices_[slot].state != ENV_SILENT && diagnostics_) diagnostics_->voice_steals += 1;
  alloc_stamp_ = (alloc_stamp_ + 1) & 0xff;
  if (alloc_stamp_ == 0) alloc_stamp_ = 1;

  Region r = regions_.at(event.region);
  if (r.exclusive_class > 0) {
    for (int v = 0; v < kNumVoices; ++v) {
      const Region& active = regions_.at(voices_[v].region);
      if (voices_[v].state != ENV_SILENT && active.exclusive_class == r.exclusive_class &&
          active.program == r.program && active.bank == r.bank && active.preset == r.preset) {
        release_voice(v);
      }
    }
  }
  voices_[slot].note = event.note & 0x7f;
  runtime_envelope_valid_[slot] = false;
  runtime_gain_valid_[slot] = false;
  runtime_phase_valid_[slot] = false;
  runtime_filter_valid_[slot] = false;
  voices_[slot].channel = event.channel;
  voices_[slot].region = event.region;
  voices_[slot].state = r.delay_ticks > 0 ? ENV_DELAY : ENV_ATTACK;
  voices_[slot].level = 0;
  r.initial_envelope = voices_[slot].level;
  voices_[slot].velocity = r.effective_velocity >= 0 ? r.effective_velocity : event.velocity;
  voices_[slot].stamp = alloc_stamp_;
  voices_[slot].ticks_remaining = r.delay_ticks;
  voices_[slot].env_stage_tick = 0;
  voices_[slot].release_start = 0;
  voices_[slot].sustain_held = false;
  voices_[slot].sostenuto_held = false;
  voices_[slot].key_released = false;
  voices_[slot].tremolo_attenuation_cb = 0.0;
  voices_[slot].mod_lfo_phase = 0;
  voices_[slot].vib_lfo_phase = 0;
  voices_[slot].mod_lfo_wait_ticks = r.mod_lfo_delay_ticks;
  voices_[slot].vib_lfo_wait_ticks = r.vib_lfo_delay_ticks;
  voices_[slot].mod_env_state = r.mod_env_delay_ticks > 0 ? ENV_DELAY : ENV_ATTACK;
  voices_[slot].mod_env_level = 0;
  voices_[slot].mod_env_ticks_remaining = r.mod_env_delay_ticks;
  voices_[slot].mod_env_stage_tick = 0;
  voices_[slot].mod_env_release_start = 0;
  double note_attenuation = modulator_sum(r, voices_[slot], channels_[event.channel & 0x0f],
                                          kGenInitialAttenuation, true, false);
  voices_[slot].target = attenuation_to_q15(note_attenuation);
  voices_[slot].sustain = (voices_[slot].target * r.sustain_level) / kQ15Full;
  prime_runtime_envelope_level(slot, r.initial_envelope);

  const ChannelState& channel = channels_[event.channel & 0x0f];
  uint32_t phase_inc = modulated_phase_inc(event.phase_inc,
      channel.generator_offsets[kGenFineTune] + channel.generator_offsets[kGenCoarseTune] +
      modulator_sum(r, voices_[slot], channel, 0));
  sink_.commit_voice(slot, 1, phase_inc, r);
  update_voice_controls(slot);
}

int McuModel::first_free_or_steal_slot() const {
  for (int v = 0; v < kNumVoices; ++v) {
    if (voices_[v].state == ENV_SILENT) return v;
  }
  auto steal_score = [&](int v) -> uint64_t {
    const VoiceState& voice = voices_[v];
    const Region& region = regions_.at(voice.region);
    const ChannelState& channel = channels_[voice.channel & 0x0f];
    const auto gains = runtime_gains(region, voice, channel);
    const uint32_t gain = static_cast<uint32_t>(std::max(gains.first, gains.second));
    const uint32_t level = static_cast<uint32_t>(std::max(0, voice.level));
    return static_cast<uint64_t>(level) * gain;
  };
  int best = 0;
  for (int v = 1; v < kNumVoices; ++v) {
    bool v_released = voices_[v].state == ENV_RELEASE || voices_[v].key_released;
    bool best_released = voices_[best].state == ENV_RELEASE || voices_[best].key_released;
    if (v_released != best_released) {
      if (v_released) best = v;
      continue;
    }
    const uint64_t v_score = steal_score(v);
    const uint64_t best_score = steal_score(best);
    if (v_score != best_score) {
      if (v_score < best_score) best = v;
      continue;
    }
    if (((voices_[v].stamp - voices_[best].stamp) & 0xff) >= 128) best = v;
  }
  return best;
}

std::pair<int, int> McuModel::runtime_gains(const Region& region, const VoiceState& voice,
                                            const ChannelState& channel) {
  double attenuation = modulator_sum(region, voice, channel, kGenInitialAttenuation, false, true);
  attenuation += channel.generator_offsets[kGenInitialAttenuation] + voice.tremolo_attenuation_cb;
  if (channel.soft) attenuation += 30.0;
  double level = std::pow(10.0, -attenuation / 200.0);
  int total_pan = std::max(-500, std::min(500, int(std::round(
      double(region.pan) + channel.generator_offsets[kGenPan] +
      modulator_sum(region, voice, channel, kGenPan, false, true)))));
  int base_left = region.stereo ? region.base_gain_l : region.base_gain;
  int base_right = region.stereo ? region.base_gain_r : region.base_gain;
  int left = int(std::round(double(base_left) * level * double(500 - total_pan) / 500.0));
  int right = int(std::round(double(base_right) * level * double(500 + total_pan) / 500.0));
  return {clamp_q15(left), clamp_q15(right)};
}

double McuModel::modulator_sum(const Region& region, const VoiceState& voice,
                               const ChannelState& channel, uint16_t dest,
                               bool include_note_sources, bool include_realtime_sources) {
  auto native_7bit = [&](uint16_t source) -> double {
    bool cc = (source & 0x0080u) != 0;
    int index = source & 0x007fu;
    if (cc) {
      if (index == 1) return channel.modulation;
      if (index == 7) return channel.volume;
      if (index == 10) return channel.pan;
      if (index == 11) return channel.expression;
      return channel.cc[index];
    }
    switch (index) {
      case 2:
        return std::max(1, std::min(127, voice.velocity));
      case 3:
        return std::max(0, std::min(127, voice.note));
      case 10:
        return std::max(0, std::min(127, channel.key_pressure[voice.note & 0x7f]));
      case 13:
        return std::max(0, std::min(127, channel.channel_pressure));
      case 16:
        return std::max(0.0, std::min(127.0, double(channel.pitch_bend_range_semitones) +
                                                 double(channel.pitch_bend_range_cents) / 100.0));
      default:
        return 0.0;
    }
  };

  auto map_source = [&](uint16_t source) -> double {
    if (source == kModSrcNone) return 1.0;
    int type = (source >> 10) & 0x3f;
    bool bipolar = (source & 0x0200u) != 0;
    bool negative = (source & 0x0100u) != 0;
    bool cc = (source & 0x0080u) != 0;
    int index = source & 0x007fu;
    if (!cc && index == 14) {
      double value = double(std::max(-8192, std::min(8191, channel.pitch_bend))) / 8192.0;
      return negative ? -value : value;
    }
    double native = native_7bit(source);
    double x = negative ? (127.0 - native) / 128.0 : native / 128.0;
    if (bipolar) return shape_bipolar(-1.0 + 2.0 * x, type);
    return shape_unipolar(x, type);
  };

  const auto& mods = region.modulators.empty() ? fallback_default_modulators() : region.modulators;
  double sum = 0.0;
  for (const auto& mod : mods) {
    if (mod.dest != dest) continue;
    if (!include_note_sources && (is_note_on_source(mod.src) || is_note_on_source(mod.amount_src))) continue;
    if (!include_realtime_sources && (is_realtime_source(mod.src) || is_realtime_source(mod.amount_src))) continue;
    double value = double(mod.amount) * map_source(mod.src) * map_source(mod.amount_src);
    if (mod.transform == kTransformAbsoluteValue) value = std::abs(value);
    sum += value;
  }
  return sum;
}

uint32_t McuModel::modulated_phase_inc(uint32_t base_phase_inc, double cents) {
  double raw = double(base_phase_inc) * std::pow(2.0, cents / 1200.0);
  if (raw < 1.0) return 1;
  if (raw > double(UINT32_MAX)) return UINT32_MAX;
  return uint32_t(std::round(raw));
}

int q2_14(double value) {
  double raw = std::round(value * 16384.0);
  if (raw > double(std::numeric_limits<int16_t>::max())) return std::numeric_limits<int16_t>::max();
  if (raw < double(std::numeric_limits<int16_t>::min())) return std::numeric_limits<int16_t>::min();
  return int(raw);
}

FilterConfig McuModel::filter_for(int cutoff_cents, int resonance_cb, int sample_rate) {
  cutoff_cents = std::max(1500, std::min(13500, cutoff_cents));
  double cutoff_hz = 8.176 * std::pow(2.0, double(cutoff_cents) / 1200.0);
  double nyquist = double(sample_rate) * 0.5;
  FilterConfig filter;
  if (cutoff_hz >= nyquist * 0.97) return filter;
  resonance_cb = std::max(0, std::min(960, resonance_cb));
  double q = std::max(0.5, std::pow(10.0, double(resonance_cb) / 200.0) * 0.7071067811865476);
  double omega = 2.0 * 3.14159265358979323846 * cutoff_hz / double(sample_rate);
  double sin_w = std::sin(omega);
  double cos_w = std::cos(omega);
  double alpha = sin_w / (2.0 * q);
  double a0 = 1.0 + alpha;
  filter.enable = true;
  filter.b0 = q2_14(((1.0 - cos_w) * 0.5) / a0);
  filter.b1 = q2_14((1.0 - cos_w) / a0);
  filter.b2 = q2_14(((1.0 - cos_w) * 0.5) / a0);
  filter.a1 = q2_14((-2.0 * cos_w) / a0);
  filter.a2 = q2_14((1.0 - alpha) / a0);
  return filter;
}

}  // namespace render
