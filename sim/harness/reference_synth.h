#pragma once

#include "render_types.h"

#include <cstdint>
#include <utility>
#include <vector>

namespace render {

class ReferenceSynth : public VoiceControlSink {
 public:
  explicit ReferenceSynth(const std::vector<int16_t>& memory);

  void set_envelope(int voice, int level) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override;
  void release_voice(int voice, const Region& region) override;
  std::pair<int16_t, int16_t> render_sample();

 private:
  struct VoiceConfig {
    bool enable = false;
    bool valid = false;
    bool stereo = false;
    bool released = false;
    uint32_t base_addr = 0;
    uint16_t length = 0;
    uint16_t loop_start = 0;
    uint16_t loop_end = 0;
    uint32_t phase = 0;
    uint32_t phase_inc = 0;
    int16_t gain_l = 0;
    int16_t gain_r = 0;
    int16_t envelope = 0x7fff;
    int loop_mode = 0;
  };

  static int16_t interpolate(int16_t sample_0, int16_t sample_1, uint16_t fraction);
  static int16_t apply_gain(int16_t sample, int16_t gain);
  static int16_t saturate(int32_t value);
  int16_t read_word(uint32_t address) const;

  const std::vector<int16_t>& memory_;
  std::vector<VoiceConfig> voices_;
};

}  // namespace render
