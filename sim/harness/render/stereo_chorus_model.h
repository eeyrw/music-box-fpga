#pragma once

#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

namespace render {

struct ChorusConfig {
  bool enable = false;
  uint32_t base_delay_q16_8 = 1u << 8;
  uint32_t depth_q16_8 = 0;
  uint32_t lfo_phase_inc_q0_32 = 0;
  uint16_t input_send_q1_15 = 0x7fff;
  uint16_t return_gain_q1_15 = 0;
  int16_t feedback_q1_15 = 0;
  uint32_t stereo_phase_offset_q0_32 = 0x40000000u;
};

class StereoChorusModel {
 public:
  explicit StereoChorusModel(std::size_t delay_capacity = 2048);

  void reset();
  void clear();
  void set_config(const ChorusConfig& config) { config_ = config; }
  std::pair<int32_t, int32_t> process_frame(int32_t left, int32_t right);

  uint32_t lfo_phase() const { return lfo_phase_; }
  std::size_t history_level() const { return history_age_; }
  bool config_clamped() const { return config_clamped_; }
  uint32_t saturation_count() const { return saturation_count_; }

 private:
  static int16_t sine_q15(uint32_t phase);
  static int64_t arithmetic_shift_right(int64_t value, unsigned bits);
  static int32_t signed_mix25(int32_t value);
  static int32_t saturate_mix25(int64_t value, bool* saturated = nullptr);
  static uint32_t sat_inc(uint32_t value, uint32_t amount = 1);
  ChorusConfig effective_config();
  int32_t tap(uint32_t delay_q16_8, bool right) const;

  std::vector<std::pair<int32_t, int32_t>> history_;
  std::size_t write_ptr_ = 0;
  std::size_t history_age_ = 0;
  uint32_t lfo_phase_ = 0;
  ChorusConfig config_;
  bool config_clamped_ = false;
  uint32_t saturation_count_ = 0;
};

}  // namespace render
