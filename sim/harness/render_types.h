#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace render {

constexpr int kNumVoices = 32;
constexpr int kQ15Full = 32767;
constexpr uint16_t kVoiceBase = 0x0100;
constexpr uint16_t kVoiceStride = 0x0040;

struct Args {
  std::string sf2 = "assets/soundfonts/MT6276.sf2";
  std::string midi;
  std::string instrument;
  std::string out_dir = "build/render_midi";
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
  int loop_mode = 0;
  int sustain_level = kQ15Full;
  int attack_step = kQ15Full;
  int decay_step = kQ15Full;
  int release_step = kQ15Full;
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
};

enum EnvState {
  ENV_SILENT = 0,
  ENV_ATTACK = 1,
  ENV_DECAY = 2,
  ENV_SUSTAIN = 3,
  ENV_RELEASE = 4,
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
