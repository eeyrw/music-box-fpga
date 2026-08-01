#pragma once

#include "render_types.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <stdexcept>
#include <vector>

namespace render {

constexpr std::size_t kMaxCommandWords = 17;

class CommandWordView {
 public:
  CommandWordView() = default;
  CommandWordView(const uint32_t* data, std::size_t size)
      : data_(data), size_(size) {}
  CommandWordView(const std::vector<uint32_t>& words)
      : data_(words.data()), size_(words.size()) {}

  const uint32_t* begin() const { return data_; }
  const uint32_t* end() const { return size_ == 0 ? data_ : data_ + size_; }
  const uint32_t* data() const { return data_; }
  std::size_t size() const { return size_; }
  bool empty() const { return size_ == 0; }
  uint32_t operator[](std::size_t index) const { return data_[index]; }
  uint32_t at(std::size_t index) const {
    if (index >= size_) throw std::out_of_range("command word index");
    return data_[index];
  }
  uint32_t front() const { return data_[0]; }

 private:
  const uint32_t* data_ = nullptr;
  std::size_t size_ = 0;
};

struct FixedCommand {
  std::array<uint32_t, kMaxCommandWords> words{};
  uint8_t length = 0;

  void push_back(uint32_t word) {
    if (length >= words.size()) throw std::length_error("command exceeds 17 words");
    words[length++] = word;
  }
  CommandWordView view() const { return {words.data(), length}; }
};

class CommandWordSink {
 public:
  virtual ~CommandWordSink() = default;
  virtual void write_command_words(CommandWordView words) = 0;
};

class CommandFanout : public CommandWordSink {
 public:
  CommandFanout(CommandWordSink& first, CommandWordSink& second)
      : first_(first), second_(second) {}
  void write_command_words(CommandWordView words) override;

 private:
  CommandWordSink& first_;
  CommandWordSink& second_;
};

constexpr std::size_t kMaxControlActionsPerFrame = 16;
constexpr std::size_t kFrameCommandQueueCapacity = 1024;

class FrameBatchedCommandSink : public CommandWordSink {
 public:
  explicit FrameBatchedCommandSink(
      CommandWordSink& sink,
      std::size_t max_actions_per_frame = kMaxControlActionsPerFrame);

  void write_command_words(CommandWordView words) override;
  std::size_t apply_frame();

  std::size_t pending_actions() const { return pending_count_; }
  std::size_t max_pending_actions() const { return max_pending_actions_; }
  uint64_t total_enqueued_actions() const { return total_enqueued_actions_; }
  uint64_t total_applied_actions() const { return total_applied_actions_; }
  uint64_t max_deferred_frames() const { return max_deferred_frames_; }

 private:
  struct PendingCommand {
    FixedCommand command;
    uint64_t enqueue_frame = 0;
  };

  CommandWordSink& sink_;
  std::size_t max_actions_per_frame_;
  std::array<PendingCommand, kFrameCommandQueueCapacity> pending_{};
  std::size_t pending_head_ = 0;
  std::size_t pending_tail_ = 0;
  std::size_t pending_count_ = 0;
  std::size_t max_pending_actions_ = 0;
  uint64_t frame_index_ = 0;
  uint64_t total_enqueued_actions_ = 0;
  uint64_t total_applied_actions_ = 0;
  uint64_t max_deferred_frames_ = 0;
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
    uint16_t generation = 0;
    bool active = false;
    bool released = false;
    int gain_l = 0;
    int gain_r = 0;
    uint32_t phase_inc = 0;
    FilterConfig filter;
  };

  void emit(uint8_t opcode, int voice, CommandWordView payload,
            uint8_t flags = 0);
  void emit(uint8_t opcode, int voice,
            std::initializer_list<uint32_t> payload, uint8_t flags = 0);
  CommandWordSink& sink_;
  std::array<VoiceMirror, kNumVoices> voices_{};
};

struct CompressorCommandConfig {
  bool enable = false;
  uint32_t threshold_cb_q12_20 = 0;
  uint16_t ratio_slope_q0_16 = 0;
  uint32_t attack_step_cb_q12_20 = 0;
  uint32_t release_step_cb_q12_20 = 0;
};

struct ChorusCommandConfig {
  bool enable = false;
  uint32_t base_delay_q16_8 = 0;
  uint32_t depth_q16_8 = 0;
  uint32_t lfo_phase_inc_q0_32 = 0;
  uint16_t input_send_q1_15 = 0;
  uint16_t return_gain_q1_15 = 0;
  int16_t feedback_q1_15 = 0;
  uint32_t stereo_phase_offset_q0_32 = 0;
};

struct ReverbCommandConfig {
  bool enable = false;
  uint16_t input_send_q1_15 = 0;
  uint16_t return_gain_q1_15 = 0;
  uint16_t damping_q1_15 = 0;
  uint16_t chorus_to_reverb_q1_15 = 0;
  uint16_t pre_delay_frames = 0;
  std::array<uint16_t, 8> feedback_gain_q1_15{};
};

class CommandAudioControl {
 public:
  explicit CommandAudioControl(CommandWordSink& sink) : sink_(sink) {}

  void configure_compressor(const CompressorCommandConfig& config);
  void set_master_volume(int gain_q1_15);
  void configure_chorus(const ChorusCommandConfig& config);
  void configure_reverb(const ReverbCommandConfig& config);
  void clear_effects(uint8_t mask);

 private:
  void emit(uint8_t opcode, CommandWordView payload);
  void emit(uint8_t opcode, std::initializer_list<uint32_t> payload);
  CommandWordSink& sink_;
};

uint32_t envelope_release_step(const Region& region);

}  // namespace render
