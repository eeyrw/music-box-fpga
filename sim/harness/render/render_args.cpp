#include "render_support.h"

#include <algorithm>
#include <cmath>
#include <sstream>
#include <stdexcept>

namespace render {

std::string render_input_json_fields(const Args& args, int tick_samples) {
  std::ostringstream s;
  s << "  \"sf2_path\": " << json_string(args.sf2)
    << ",\n  \"midi_path\": ";
  if (args.midi.empty())
    s << "null";
  else
    s << json_string(args.midi);
  s << ",\n  \"uses_default_melody\": " << (args.midi.empty() ? "true" : "false")
    << ",\n  \"instrument_override\": ";
  if (args.instrument.empty())
    s << "null";
  else
    s << json_string(args.instrument);
  s << ",\n  \"start_seconds\": " << args.start_seconds
    << ",\n  \"requested_seconds\": " << args.seconds
    << ",\n  \"control_update_mode\": "
    << json_string(args.sample_accurate_control ? "sample_accurate" : "periodic")
    << ",\n  \"control_tick_ms\": " << args.control_tick_ms
    << ",\n  \"control_tick_ms_ignored\": "
    << (args.sample_accurate_control ? "true" : "false")
    << ",\n  \"control_tick_samples\": " << tick_samples
    << ",\n  \"detailed_diagnostics\": " << (args.detailed_diagnostics ? "true" : "false")
    << ",\n  \"compressor_enable\": " << (args.compressor_enable ? "true" : "false")
    << ",\n  \"compressor_threshold_cb\": " << args.compressor_threshold_cb
    << ",\n  \"compressor_ratio\": " << args.compressor_ratio
    << ",\n  \"compressor_attack_ms\": " << args.compressor_attack_ms
    << ",\n  \"compressor_release_ms\": " << args.compressor_release_ms
    << ",\n  \"master_volume\": " << args.master_volume
    << ",\n  \"render_num_voices\": " << kNumVoices;
  return s.str();
}

std::string memory_profile_json_field(const Args& args) {
  return "  \"memory_profile\": " + json_string(args.memory_profile);
}

int control_tick_samples(const Args& args) {
  if (args.sample_accurate_control) return 1;
  return std::max(1, int(std::round(args.control_tick_ms * args.sample_rate / 1000.0)));
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
    else if (a == "--start-seconds") args.start_seconds = std::stod(need("--start-seconds"));
    else if (a == "--seconds") args.seconds = std::stod(need("--seconds"));
    else if (a == "--sample-rate") args.sample_rate = std::stoi(need("--sample-rate"));
    else if (a == "--control-tick-ms") args.control_tick_ms = std::stod(need("--control-tick-ms"));
    else if (a == "--sample-accurate-control") args.sample_accurate_control = true;
    else if (a == "--detailed-diagnostics") args.detailed_diagnostics = true;
    else if (a == "--compressor-enable") args.compressor_enable = true;
    else if (a == "--compressor-threshold-cb")
      args.compressor_threshold_cb = std::stod(need("--compressor-threshold-cb"));
    else if (a == "--compressor-ratio")
      args.compressor_ratio = std::stod(need("--compressor-ratio"));
    else if (a == "--compressor-attack-ms")
      args.compressor_attack_ms = std::stod(need("--compressor-attack-ms"));
    else if (a == "--compressor-release-ms")
      args.compressor_release_ms = std::stod(need("--compressor-release-ms"));
    else if (a == "--master-volume") args.master_volume = std::stod(need("--master-volume"));
    else if (a == "--memory-profile") args.memory_profile = need("--memory-profile");
    else if (a == "--out-dir") args.out_dir = need("--out-dir");
    else throw std::runtime_error("unknown argument: " + a);
  }
  return args;
}

}  // namespace render
