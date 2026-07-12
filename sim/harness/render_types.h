#pragma once

#include <cstdint>
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
  double time_seconds = 0.0;
  int note = 0;
  bool on = false;
  int velocity = 100;
  int channel = 0;
  int program = 0;
  int bank = 0;
  int sample = 0;
  uint32_t phase_inc = 1;
  int region = 0;
};

struct Region {
  int key = 0;
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
  int attack_step = kQ15Full;
  int decay_step = kQ15Full;
  int release_step = kQ15Full;
};

class VoiceControlSink {
 public:
  virtual ~VoiceControlSink() = default;
  virtual void set_envelope(int voice, int level) = 0;
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
  return (vel * kQ15Full + 63) / 127;
}

inline uint16_t voice_addr(int voice, int offset) {
  return uint16_t(kVoiceBase + voice * kVoiceStride + offset);
}

}  // namespace render
