#pragma once

#include "register_control.h"

#include <array>
#include <cstdint>
#include <utility>
#include <vector>

class Vwavetable_render_core;

namespace render {

class QuickRtlHarness : public VoiceControlSink, private RegisterWriteSink {
 public:
  explicit QuickRtlHarness(const std::vector<int16_t>& memory);
  ~QuickRtlHarness();

  void reset();
  void set_envelope(int voice, int level) override;
  void set_gain(int voice, int gain_l, int gain_r) override;
  void set_phase_inc(int voice, uint32_t phase_inc) override;
  void set_filter(int voice, const FilterConfig& filter) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override;
  void release_voice(int voice, const Region& region) override;
  std::pair<int16_t, int16_t> request_sample(int produced);
  uint64_t total_cycles() const { return total_cycles_; }
  uint64_t total_memory_reads() const { return total_memory_reads_; }
  uint64_t render_cycles_sum() const { return render_cycles_sum_; }
  uint32_t max_render_cycles() const { return max_render_cycles_; }
  uint64_t render_memory_reads_sum() const { return render_memory_reads_sum_; }
  uint32_t max_render_memory_reads() const { return max_render_memory_reads_; }
  uint64_t enabled_voice_sum() const { return enabled_voice_sum_; }
  uint32_t max_enabled_voices() const { return max_enabled_voices_; }
  uint64_t audible_voice_sum() const { return audible_voice_sum_; }
  uint32_t max_audible_voices() const { return max_audible_voices_; }
  uint64_t filtered_voice_sum() const { return filtered_voice_sum_; }
  uint32_t max_filtered_voices() const { return max_filtered_voices_; }
  uint64_t stereo_voice_sum() const { return stereo_voice_sum_; }
  uint32_t max_stereo_voices() const { return max_stereo_voices_; }
  const RegisterWriteStats& register_write_stats() const { return register_write_stats_; }

 private:
  struct VoiceMirror {
    bool enabled = false;
    bool stereo = false;
    bool filter_enable = false;
    int envelope_level = 0;
  };

  void write_register(uint16_t address, uint32_t data) override;
  void tick();
  int16_t read_word(uint32_t address) const;
  uint32_t count_enabled_voices() const;
  uint32_t count_audible_voices() const;
  uint32_t count_filtered_voices() const;
  uint32_t count_stereo_voices() const;

  Vwavetable_render_core* top_ = nullptr;
  RegisterVoiceControl voice_control_;
  const std::vector<int16_t>& memory_;
  std::array<VoiceMirror, kNumVoices> voices_{};
  bool rsp_valid_ = false;
  int16_t rsp_data_ = 0;
  uint64_t total_cycles_ = 0;
  uint64_t total_memory_reads_ = 0;
  uint64_t render_cycles_sum_ = 0;
  uint32_t max_render_cycles_ = 0;
  uint64_t render_memory_reads_sum_ = 0;
  uint32_t max_render_memory_reads_ = 0;
  uint64_t enabled_voice_sum_ = 0;
  uint32_t max_enabled_voices_ = 0;
  uint64_t audible_voice_sum_ = 0;
  uint32_t max_audible_voices_ = 0;
  uint64_t filtered_voice_sum_ = 0;
  uint32_t max_filtered_voices_ = 0;
  uint64_t stereo_voice_sum_ = 0;
  uint32_t max_stereo_voices_ = 0;
  RegisterWriteStats register_write_stats_;
};

}  // namespace render
