#pragma once

#include "generated/register_map.h"

#include <algorithm>
#include <cstdint>
#include <cmath>
#include <string>
#include <vector>

namespace render {

#ifndef RENDER_NUM_VOICES
#define RENDER_NUM_VOICES 32
#endif

constexpr int kNumVoices = RENDER_NUM_VOICES;
constexpr int kQ15Full = int(regs::kQ15Full);
constexpr int kPhaseFrameBits = 24;
constexpr int kPhaseFracBits = 8;
constexpr uint32_t kPhaseFracScale = 1u << kPhaseFracBits;
constexpr uint32_t kPhaseFracMask = kPhaseFracScale - 1u;
constexpr uint32_t kPhaseFrameMask = (1u << kPhaseFrameBits) - 1u;
constexpr uint16_t kVoiceBase = regs::kVoiceBase;
constexpr uint16_t kVoiceStride = regs::kVoiceStride;

constexpr int kRegBaseAddr = regs::kOffBaseAddr;
constexpr int kRegBaseAddrR = regs::kOffBaseAddrR;
constexpr int kRegLength = regs::kOffLength;
constexpr int kRegLengthR = regs::kOffLengthR;
constexpr int kRegLoopStart = regs::kOffLoopStart;
constexpr int kRegLoopStartR = regs::kOffLoopStartR;
constexpr int kRegLoopEnd = regs::kOffLoopEnd;
constexpr int kRegLoopEndR = regs::kOffLoopEndR;
constexpr int kRegVoiceControl = regs::kOffVoiceControl;
constexpr int kRegPhaseInit = regs::kOffPhaseInit;
constexpr int kRegPhaseInc = regs::kOffPhaseInc;
constexpr int kRegPhaseIncRuntime = regs::kOffPhaseIncRuntime;
constexpr int kRegGain = regs::kOffGain;
constexpr int kRegGainRuntime = regs::kOffGainRuntime;
constexpr int kRegEnvelope = regs::kOffEnvelope;
constexpr int kRegEnvelopeRuntime = regs::kOffEnvelopeRuntime;
constexpr int kRegFilterControl = regs::kOffFilterControl;
constexpr int kRegFilterB0B1 = regs::kOffFilterB0B1;
constexpr int kRegFilterB2A1 = regs::kOffFilterB2A1;
constexpr int kRegFilterA2 = regs::kOffFilterA2;
constexpr int kRegReleaseControl = regs::kOffReleaseControl;
constexpr int kRegStatus = regs::kOffStatus;

struct Args {
  std::string sf2 = "assets/soundfonts/MT6276.sf2";
  std::string midi;
  std::string instrument;
  std::string out_dir = "build/render_memory";
  std::string memory_profile = "ddr";
  int key = 60;
  double seconds = 2.0;
  int sample_rate = 48000;
  double adsr_tick_ms = 5.0;
  bool sample_accurate_envelope = false;
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
};

struct Sf2Modulator {
  uint16_t src = 0;
  uint16_t dest = 0;
  int amount = 0;
  uint16_t amount_src = 0;
  uint16_t transform = 0;
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
  int initial_envelope = 0;
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
  int attack_step = kQ15Full;
  int decay_step = kQ15Full;
  int release_step = kQ15Full;
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

struct RegisterWriteStats {
  uint64_t total = 0;
  uint64_t envelope = 0;
  uint64_t gain_runtime = 0;
  uint64_t phase_inc_runtime = 0;
  uint64_t filter = 0;
  uint64_t commit = 0;
  uint64_t release = 0;
  uint64_t config = 0;
};

struct RenderDiagnostics {
  uint64_t frames = 0;
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
  uint64_t runtime_envelope_updates = 0;
  uint64_t runtime_gain_updates = 0;
  uint64_t runtime_phase_updates = 0;
  uint64_t runtime_filter_updates = 0;
  uint32_t max_runtime_envelope_jump = 0;
  int max_runtime_envelope_jump_voice = -1;
  uint64_t max_runtime_envelope_jump_tick = 0;
  uint32_t max_runtime_gain_jump_l = 0;
  uint32_t max_runtime_gain_jump_r = 0;
  uint32_t max_runtime_phase_inc_jump = 0;
  uint32_t max_runtime_filter_coeff_jump = 0;
};

class VoiceControlSink {
 public:
  virtual ~VoiceControlSink() = default;
  virtual void set_envelope(int voice, int level) = 0;
  virtual void set_gain(int voice, int gain_l, int gain_r) = 0;
  virtual void set_phase_inc(int voice, uint32_t phase_inc) = 0;
  virtual void set_filter(int voice, const FilterConfig& filter) = 0;
  virtual void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) = 0;
  virtual void release_voice(int voice, const Region& region) = 0;
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

inline uint16_t voice_addr(int voice, int offset) {
  return regs::voice_addr(voice, uint16_t(offset));
}

inline void note_register_write(RegisterWriteStats& stats, uint16_t address) {
  ++stats.total;
  if (address < kVoiceBase) return;
  int offset = int((address - kVoiceBase) % kVoiceStride);
  switch (offset) {
    case kRegEnvelopeRuntime:
      ++stats.envelope;
      break;
    case kRegGainRuntime:
      ++stats.gain_runtime;
      break;
    case kRegPhaseIncRuntime:
      ++stats.phase_inc_runtime;
      break;
    case kRegFilterControl:
    case kRegFilterB0B1:
    case kRegFilterB2A1:
    case kRegFilterA2:
      ++stats.filter;
      break;
    case kRegVoiceControl:
      ++stats.commit;
      break;
    case kRegReleaseControl:
      ++stats.release;
      break;
    default:
      ++stats.config;
      break;
  }
}

}  // namespace render
