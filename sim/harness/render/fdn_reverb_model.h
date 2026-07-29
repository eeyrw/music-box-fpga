#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <utility>
#include <vector>

namespace render {

struct ReverbConfig {
  bool enable = false;
  uint16_t input_send_q1_15 = 0x7fff;
  uint16_t return_gain_q1_15 = 0;
  uint16_t damping_q1_15 = 0;
  uint16_t chorus_to_reverb_q1_15 = 0;
  uint16_t pre_delay_frames = 0;
  std::array<uint16_t, 8> feedback_gain_q1_15{};
};

class FdnReverbModel {
 public:
  explicit FdnReverbModel(std::vector<std::size_t> line_lengths = {},
                          std::size_t pre_delay_capacity = 2048);

  void reset();
  void clear();
  void set_config(const ReverbConfig& config) { config_ = config; }
  std::pair<int32_t, int32_t> process_frame(int32_t left, int32_t right);

  bool config_clamped() const { return config_clamped_; }
  uint8_t valid_line_mask() const;
  std::size_t pre_delay_occupancy() const { return pre_delay_age_; }
  uint32_t saturation_count() const { return saturation_count_; }

 private:
  static int64_t arithmetic_shift_right(int64_t value, unsigned bits);
  static int64_t symmetric_round_shift_15(int64_t value);
  static int32_t apply_state_deadband(int32_t value);
  static int32_t signed_mix25(int32_t value);
  static int32_t saturate_mix25(int64_t value, bool* saturated = nullptr);
  static uint32_t sat_inc(uint32_t value, uint32_t amount = 1);
  static std::array<int64_t, 8> hadamard(const std::array<int32_t, 8>& input);
  ReverbConfig effective_config();

  std::vector<std::vector<int32_t>> lines_;
  std::array<std::size_t, 8> pointers_{};
  std::array<std::size_t, 8> ages_{};
  std::array<int32_t, 8> damping_state_{};
  std::vector<std::pair<int32_t, int32_t>> pre_delay_;
  std::size_t pre_delay_ptr_ = 0;
  std::size_t pre_delay_age_ = 0;
  ReverbConfig config_;
  bool config_clamped_ = false;
  uint32_t saturation_count_ = 0;
};

}  // namespace render
