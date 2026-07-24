#pragma once

#include "render_types.h"

#include <array>
#include <cstdint>
#include <initializer_list>
#include <vector>

namespace render {

class CommandWordSink {
 public:
  virtual ~CommandWordSink() = default;
  virtual void write_command_words(const std::vector<uint32_t>& words) = 0;
};

class CommandFanout : public CommandWordSink {
 public:
  CommandFanout(CommandWordSink& first, CommandWordSink& second)
      : first_(first), second_(second) {}
  void write_command_words(const std::vector<uint32_t>& words) override;

 private:
  CommandWordSink& first_;
  CommandWordSink& second_;
};

class CommandVoiceControl : public VoiceCommandSink {
 public:
  explicit CommandVoiceControl(CommandWordSink& sink);

  void start_voice(int voice, uint32_t phase_inc, const Region& region) override;
  void update_gain_phase(int voice, int gain_l, int gain_r,
                         uint32_t phase_inc) override;
  void update_filter(int voice, const FilterConfig& filter) override;
  void release_voice(int voice, uint32_t release_step_cb_q12_20) override;
  void stop_voice(int voice) override;

 private:
  struct VoiceMirror {
    uint8_t seq = 0;
    bool active = false;
  };

  void emit(uint8_t opcode, int voice, uint8_t seq,
            std::initializer_list<uint32_t> payload);
  CommandWordSink& sink_;
  std::array<VoiceMirror, kNumVoices> voices_{};
};

uint32_t envelope_release_step(const Region& region);

}  // namespace render
