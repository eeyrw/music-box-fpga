#pragma once

#include <cstdint>
#include <cmath>
#include <string>
#include <vector>

namespace render {

#ifndef RENDER_NUM_VOICES
#define RENDER_NUM_VOICES 32
#endif

constexpr int kNumVoices = RENDER_NUM_VOICES;
constexpr int kQ15Full = 32767;
constexpr uint16_t kVoiceBase = 0x0100;
constexpr uint16_t kVoiceStride = 0x0080;

constexpr int kRegControl = 0x00;
constexpr int kRegBaseAddr = 0x04;
constexpr int kRegLength = 0x08;
constexpr int kRegLoopStart = 0x0c;
constexpr int kRegLoopEnd = 0x10;
constexpr int kRegPhaseInit = 0x14;
constexpr int kRegPhaseInc = 0x18;
constexpr int kRegGainL = 0x1c;
constexpr int kRegGainR = 0x20;
constexpr int kRegCommit = 0x24;
constexpr int kRegEnvelopeLevel = 0x2c;
constexpr int kRegPhaseIncRuntime = 0x30;
constexpr int kRegLoopMode = 0x34;
constexpr int kRegFilterControl = 0x38;
constexpr int kRegFilterB0 = 0x3c;
constexpr int kRegFilterB1 = 0x40;
constexpr int kRegFilterB2 = 0x44;
constexpr int kRegFilterA1 = 0x48;
constexpr int kRegFilterA2 = 0x4c;
constexpr int kRegGainRuntime = 0x50;
constexpr int kRegReleaseControl = 0x54;

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

struct Region {
  int key = 0;
  int output_sample_rate = 48000;
  int program = 0;
  int bank = 0;
  std::string preset;
  std::string instrument;
  std::string sample_left;
  std::string sample_right;
  bool stereo = false;
  uint32_t base_addr = 0;
  uint32_t length = 0;
  uint32_t loop_start = 0;
  uint32_t loop_end = 0;
  uint32_t phase_inc = 1;
  int gain_l = 0x4000;
  int gain_r = 0x4000;
  bool filter_enable = false;
  int filter_b0 = 0x10000000;
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
  int mod_env_delay_ticks = 0;
  int mod_env_hold_ticks = 0;
  int mod_env_sustain_level = kQ15Full;
  int mod_env_attack_ticks = 1;
  int mod_env_decay_ticks = 1;
  int mod_env_release_ticks = 1;
  int mod_env_attack_step = kQ15Full;
  int mod_env_decay_step = kQ15Full;
  int mod_env_release_step = kQ15Full;
};

struct FilterConfig {
  bool enable = false;
  int b0 = 0x10000000;
  int b1 = 0;
  int b2 = 0;
  int a1 = 0;
  int a2 = 0;
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

inline int velocity_target(int velocity) {
  int vel = velocity < 0 ? 0 : (velocity > 127 ? 127 : velocity);
  if (vel == 0) return 0;
  double missing = double(127 - vel) / 127.0;
  double attenuation_cb = 960.0 * missing * missing;
  int level = int(std::round(double(kQ15Full) * std::pow(10.0, -attenuation_cb / 200.0)));
  return clamp_q15(level);
}

inline uint16_t voice_addr(int voice, int offset) {
  return uint16_t(kVoiceBase + voice * kVoiceStride + offset);
}

}  // namespace render
