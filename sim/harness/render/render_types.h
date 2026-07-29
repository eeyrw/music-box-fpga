#pragma once

#include "generated/register_map.h"

#include <algorithm>
#include <cstdint>
#include <cmath>
#include <string>
#include <utility>
#include <vector>

namespace render {

#ifndef RENDER_NUM_VOICES
#define RENDER_NUM_VOICES 512
#endif

constexpr int kNumVoices = RENDER_NUM_VOICES;
constexpr int kQ15Full = int(regs::kQ15Full);
constexpr int kPhaseFrameBits = 24;
constexpr int kPhaseFracBits = 8;
constexpr uint32_t kPhaseFracScale = 1u << kPhaseFracBits;
constexpr uint32_t kPhaseFracMask = kPhaseFracScale - 1u;
constexpr uint32_t kPhaseFrameMask = (1u << kPhaseFrameBits) - 1u;
struct Args {
  std::string sf2 = "assets/soundfonts/MT6276.sf2";
  std::string midi;
  std::string instrument;
  std::string out_dir = "build/render_memory";
  std::string memory_profile = "ddr";
  double start_seconds = 0.0;
  double seconds = 2.0;
  int sample_rate = 48000;
  double control_tick_ms = 5.0;
  bool sample_accurate_control = false;
  bool detailed_diagnostics = false;
  bool compressor_enable = false;
  double compressor_threshold_cb = 120.0;
  double compressor_ratio = 4.0;
  double compressor_attack_ms = 0.0;
  double compressor_release_ms = 100.0;
  double master_volume = 1.0;
  std::string effects_preset = "off";
  std::string chorus_enable = "auto";
  std::string reverb_enable = "auto";
  double effects_tail_seconds = 0.0;
};

struct NoteEvent {
  enum Type {
    EVENT_NOTE = 0,
    EVENT_CONTROL = 1,
    EVENT_PITCH_BEND = 2,
    EVENT_CHANNEL_PRESSURE = 3,
    EVENT_KEY_PRESSURE = 4,
  };

  double time_seconds = 0.0;
  int note = 0;
  bool on = false;
  int velocity = 100;
  int channel = 0;
  int program = 0;
  int bank = 0;
  Type type = EVENT_NOTE;
  int controller = 0;
  int value = 0;
  int pitch_bend = 0;
  int sample = 0;
  uint32_t phase_inc = 1;
  int region = 0;
  uint64_t note_instance = 0;
};

struct Sf2Modulator {
  uint16_t src = 0;
  uint16_t dest = 0;
  int amount = 0;
  uint16_t amount_src = 0;
  uint16_t transform = 0;
};

struct VolumeEnvelopeParams {
  uint32_t delay_samples = 0;
  uint32_t attack_samples = 0;
  uint32_t hold_samples = 0;
  uint32_t decay_samples = 0;
  uint32_t sustain_cb_q12_20 = 0;
  uint32_t release_samples = 0;
};

struct Region {
  int key = 0;
  int output_sample_rate = 48000;
  int program = 0;
  int bank = 0;
  std::string preset;
  std::string instrument;
  std::string sample_left;
  std::string sample_right;
  std::string stereo_source = "mono";
  bool stereo = false;
  uint32_t base_addr = 0;
  uint32_t base_addr_r = 0;
  uint32_t length = 0;
  uint32_t length_r = 0;
  uint32_t loop_start = 0;
  uint32_t loop_start_r = 0;
  uint32_t loop_end = 0;
  uint32_t loop_end_r = 0;
  uint32_t phase_inc = 1;
  int gain_l = 0x4000;
  int gain_r = 0x4000;
  int base_gain = 0x4000;
  int base_gain_l = 0x4000;
  int base_gain_r = 0x4000;
  int pan = 0;
  VolumeEnvelopeParams volume_envelope;
  bool filter_enable = false;
  int filter_b0 = int(regs::kFilterB0UnityQ214);
  int filter_b1 = 0;
  int filter_b2 = 0;
  int filter_a1 = 0;
  int filter_a2 = 0;
  int loop_mode = 0;
  int effective_velocity = -1;
  int exclusive_class = 0;
  int delay_ticks = 0;
  int hold_ticks = 0;
  int sustain_level = kQ15Full;
  int attack_ticks = 1;
  int decay_ticks = 1;
  int release_ticks = 1;
  int control_tick_samples = 1;
  int initial_filter_fc = 13500;
  int initial_filter_q = 0;
  int mod_lfo_delay_ticks = 0;
  uint32_t mod_lfo_step = 0;
  int vib_lfo_delay_ticks = 0;
  uint32_t vib_lfo_step = 0;
  int mod_lfo_to_pitch = 0;
  int vib_lfo_to_pitch = 0;
  int mod_env_to_pitch = 0;
  int mod_lfo_to_filter_fc = 0;
  int mod_env_to_filter_fc = 0;
  int mod_lfo_to_volume = 0;
  int mod_env_delay_ticks = 0;
  int mod_env_hold_ticks = 0;
  int mod_env_sustain_level = kQ15Full;
  int mod_env_attack_ticks = 1;
  int mod_env_decay_ticks = 1;
  int mod_env_release_ticks = 1;
  bool mod_env_attack_sub_tick = false;
  int mod_env_attack_step = kQ15Full;
  int mod_env_decay_step = kQ15Full;
  int mod_env_release_step = kQ15Full;
  std::vector<Sf2Modulator> modulators;
};

struct FilterConfig {
  bool enable = false;
  int b0 = int(regs::kFilterB0UnityQ214);
  int b1 = 0;
  int b2 = 0;
  int a1 = 0;
  int a2 = 0;
};

struct RenderDiagnostics {
  bool detailed_enabled = false;
  uint64_t frames = 0;
  bool compressor_enabled = false;
  bool compressor_primed = false;
  bool compressor_active = false;
  uint32_t compressor_delay_level = 0;
  uint32_t compressor_gain_reduction_cb_q12_20 = 0;
  uint32_t compressor_target_gain_reduction_cb_q12_20 = 0;
  uint32_t compressor_detector_peak = 0;
  uint32_t compressor_max_gain_reduction_cb_q12_20 = 0;
  uint32_t compressor_max_detector_peak = 0;
  uint32_t compressor_input_frame_count = 0;
  uint32_t compressor_output_frame_count = 0;
  uint32_t compressor_compressed_frame_count = 0;
  uint32_t compressor_saturation_count = 0;
  uint64_t filter_y_saturated_frames = 0;
  uint64_t filter_y_saturations = 0;
  uint64_t filter_state_saturated_frames = 0;
  uint64_t filter_state_saturations = 0;
  uint64_t contribution_saturated_frames = 0;
  uint64_t contribution_saturations = 0;
  uint64_t mix_saturated_frames = 0;
  uint64_t mix_saturations = 0;
  uint64_t max_abs_filter_y_input = 0;
  uint64_t max_abs_filter_state_input = 0;
  uint64_t max_abs_voice_contribution_input_l = 0;
  uint64_t max_abs_voice_contribution_input_r = 0;
  uint64_t max_abs_mix_input_l = 0;
  uint64_t max_abs_mix_input_r = 0;
  uint64_t voice_steals = 0;
  uint64_t max_voice_steal_score = 0;
  uint32_t max_voice_steal_level = 0;
  uint32_t max_voice_steal_gain_l = 0;
  uint32_t max_voice_steal_gain_r = 0;
  int max_voice_steal_voice = -1;
  uint64_t max_voice_steal_tick = 0;
  uint64_t runtime_gain_updates = 0;
  uint64_t runtime_phase_updates = 0;
  uint64_t runtime_filter_updates = 0;
  uint64_t audible_envelope_updates = 0;
  uint32_t max_runtime_gain_jump_l = 0;
  uint32_t max_runtime_gain_jump_r = 0;
  uint32_t max_runtime_phase_inc_jump = 0;
  uint32_t max_runtime_filter_coeff_jump = 0;
  uint32_t max_audible_envelope_jump = 0;
  int max_audible_envelope_jump_voice = -1;
  uint64_t max_audible_envelope_jump_frame = 0;
};

class VoiceCommandSink {
 public:
  virtual ~VoiceCommandSink() = default;
  virtual void start_voice(int voice, uint32_t phase_inc, const Region& region) = 0;
  virtual void update_gain_phase(int voice, int gain_l, int gain_r,
                                 uint32_t phase_inc) = 0;
  virtual void update_filter(int voice, const FilterConfig& filter) = 0;
  virtual void release_voice(int voice, uint32_t release_step_cb_q12_20) = 0;
  virtual void stop_voice(int voice) = 0;
};

struct VoiceState {
  int note = 0;
  int channel = 0;
  int region = 0;
  int state = 0;
  int level = 0;
  int target = 0;
  int sustain = 0;
  int stamp = 0;
  int ticks_remaining = 0;
  int env_stage_tick = 0;
  int release_start = 0;
  bool sustain_held = false;
  uint32_t mod_lfo_phase = 0;
  uint32_t vib_lfo_phase = 0;
  int mod_lfo_wait_ticks = 0;
  int vib_lfo_wait_ticks = 0;
  int mod_env_state = 0;
  int mod_env_level = 0;
  int mod_env_ticks_remaining = 0;
  int mod_env_stage_tick = 0;
  int mod_env_release_start = 0;
  int velocity = 127;
  double tremolo_attenuation_cb = 0.0;
  bool key_released = false;
  bool sostenuto_held = false;
  uint64_t note_instance = 0;
};

enum EnvState {
  ENV_SILENT = 0,
  ENV_DELAY = 1,
  ENV_ATTACK = 2,
  ENV_HOLD = 3,
  ENV_DECAY = 4,
  ENV_SUSTAIN = 5,
  ENV_RELEASE = 6,
};

inline int clamp_q15(int value) {
  if (value <= 0) return 0;
  if (value >= kQ15Full) return kQ15Full;
  return value;
}

inline std::pair<int, int> equal_power_pan_gains(int base_left, int base_right,
                                                 int pan, bool center_unity) {
  constexpr double kPi = 3.14159265358979323846;
  pan = std::max(-500, std::min(500, pan));
  double normalization = center_unity ? std::sqrt(2.0) : 1.0;
  double left_factor = normalization * std::sin(double(500 - pan) * kPi / 2000.0);
  double right_factor = normalization * std::sin(double(500 + pan) * kPi / 2000.0);
  return {clamp_q15(int(std::round(double(base_left) * left_factor))),
          clamp_q15(int(std::round(double(base_right) * right_factor)))};
}

inline int concave_attenuation_q15(int value) {
  int v = value < 0 ? 0 : (value > 127 ? 127 : value);
  double shaped;
  if (v >= 127)
    shaped = 0.0;
  else if (v <= 0)
    shaped = 127.0 / 128.0;
  else
    shaped = std::min((-200.0 * 2.0 / 960.0) * std::log10(double(v) / 127.0), 127.0 / 128.0);
  double attenuation_cb = 960.0 * shaped;
  int level = int(std::round(double(kQ15Full) * std::pow(10.0, -attenuation_cb / 200.0)));
  return clamp_q15(level);
}

inline int velocity_target(int velocity) {
  int vel = velocity < 0 ? 0 : (velocity > 127 ? 127 : velocity);
  if (vel == 0) return 0;
  return concave_attenuation_q15(vel);
}

}  // namespace render
