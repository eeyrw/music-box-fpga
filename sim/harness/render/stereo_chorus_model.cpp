#include "stereo_chorus_model.h"

#include "generated/dsp_lut.h"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace render {
namespace {

constexpr int32_t kFeedbackLimitQ1_15 = 0x6000;

}  // namespace

StereoChorusModel::StereoChorusModel(std::size_t delay_capacity)
    : history_(delay_capacity) {
  if (delay_capacity < 4 || (delay_capacity & (delay_capacity - 1)) != 0) {
    throw std::invalid_argument("chorus delay capacity must be a power of two >= 4");
  }
  reset();
}

void StereoChorusModel::reset() {
  write_ptr_ = 0;
  history_age_ = 0;
  lfo_phase_ = 0;
  config_ = {};
  config_clamped_ = false;
  saturation_count_ = 0;
}

void StereoChorusModel::clear() {
  write_ptr_ = 0;
  history_age_ = 0;
  lfo_phase_ = 0;
  config_clamped_ = false;
  saturation_count_ = 0;
}

std::pair<int32_t, int32_t> StereoChorusModel::process_frame(int32_t left,
                                                             int32_t right) {
  const ChorusConfig config = effective_config();
  left = signed_mix24(left);
  right = signed_mix24(right);

  const int64_t mod_l = arithmetic_shift_right(
      int64_t(config.depth_q16_8) * sine_q15(lfo_phase_), 15);
  const int64_t mod_r = arithmetic_shift_right(
      int64_t(config.depth_q16_8) *
          sine_q15(lfo_phase_ + config.stereo_phase_offset_q0_32),
      15);
  const int32_t wet_l = tap(uint32_t(int64_t(config.base_delay_q16_8) + mod_l), false);
  const int32_t wet_r = tap(uint32_t(int64_t(config.base_delay_q16_8) + mod_r), true);

  const auto input_scaled = [&config](int32_t sample) {
    if (config.input_send_q1_15 == 0x7fff) return int64_t(sample);
    return arithmetic_shift_right(int64_t(sample) * config.input_send_q1_15, 15);
  };
  const int64_t feedback_l = arithmetic_shift_right(
      int64_t(wet_l) * config.feedback_q1_15, 15);
  const int64_t feedback_r = arithmetic_shift_right(
      int64_t(wet_r) * config.feedback_q1_15, 15);
  bool saturated_l = false;
  bool saturated_r = false;
  history_[write_ptr_] = {
      saturate_mix24(input_scaled(left) + feedback_l, &saturated_l),
      saturate_mix24(input_scaled(right) + feedback_r, &saturated_r)};
  saturation_count_ = sat_inc(saturation_count_, uint32_t(saturated_l) + saturated_r);

  write_ptr_ = (write_ptr_ + 1) & (history_.size() - 1);
  history_age_ = std::min(history_age_ + 1, history_.size());
  lfo_phase_ += config.lfo_phase_inc_q0_32;
  return config.enable ? std::pair<int32_t, int32_t>{wet_l, wet_r}
                       : std::pair<int32_t, int32_t>{0, 0};
}

ChorusConfig StereoChorusModel::effective_config() {
  ChorusConfig result = config_;
  const uint32_t maximum = uint32_t((history_.size() - 2) << 8);
  const uint32_t requested_base = result.base_delay_q16_8;
  result.base_delay_q16_8 = std::clamp(result.base_delay_q16_8, 1u << 8, maximum);
  uint32_t depth_limit = std::min(result.base_delay_q16_8 - (1u << 8),
                                  maximum - result.base_delay_q16_8);
  const uint32_t requested_depth = result.depth_q16_8;
  result.depth_q16_8 = std::min(result.depth_q16_8, depth_limit);
  const int16_t requested_feedback = result.feedback_q1_15;
  result.feedback_q1_15 = int16_t(std::clamp<int32_t>(
      result.feedback_q1_15, -kFeedbackLimitQ1_15, kFeedbackLimitQ1_15));
  const uint16_t requested_send = result.input_send_q1_15;
  result.input_send_q1_15 = std::min<uint16_t>(result.input_send_q1_15, 0x7fff);
  if (result.enable &&
      (requested_base != result.base_delay_q16_8 ||
       requested_depth != result.depth_q16_8 ||
       requested_feedback != result.feedback_q1_15 ||
       requested_send != result.input_send_q1_15)) {
    config_clamped_ = true;
  }
  return result;
}

int32_t StereoChorusModel::tap(uint32_t delay_q16_8, bool right) const {
  const std::size_t integer_delay = delay_q16_8 >> 8;
  const uint32_t fraction = delay_q16_8 & 0xffu;
  const auto sample = [this, right](std::size_t distance) {
    if (distance > history_age_) return int32_t{0};
    const std::size_t address = (write_ptr_ - distance) & (history_.size() - 1);
    return right ? history_[address].second : history_[address].first;
  };
  const int32_t newer = sample(integer_delay);
  const int32_t older = sample(integer_delay + 1);
  return int32_t(int64_t(newer) +
                 arithmetic_shift_right(int64_t(older - newer) * fraction, 8));
}

int16_t StereoChorusModel::sine_q15(uint32_t phase) {
  const uint32_t position = phase >> 22;
  const uint32_t quadrant = position >> 8;
  const uint32_t offset = position & 0xffu;
  const uint32_t index = (quadrant & 1u) ? 256u - offset : offset;
  const int16_t magnitude = int16_t(dsp_lut::kChorusSineQuarterQ1_15[index]);
  return quadrant >= 2 ? int16_t(-magnitude) : magnitude;
}

int64_t StereoChorusModel::arithmetic_shift_right(int64_t value, unsigned bits) {
  if (value >= 0) return value >> bits;
  return -int64_t((uint64_t(-(value + 1)) + 1u + ((uint64_t{1} << bits) - 1u)) >> bits);
}

int32_t StereoChorusModel::signed_mix24(int32_t value) {
  const uint32_t bits = uint32_t(value) & 0x00ffffffu;
  return (bits & 0x00800000u) ? int32_t(int64_t(bits) - (int64_t{1} << 24))
                              : int32_t(bits);
}

int32_t StereoChorusModel::saturate_mix24(int64_t value, bool* saturated) {
  constexpr int32_t minimum = -(1 << 23);
  constexpr int32_t maximum = (1 << 23) - 1;
  const bool clipped = value < minimum || value > maximum;
  if (saturated) *saturated = clipped;
  return int32_t(std::clamp<int64_t>(value, minimum, maximum));
}

uint32_t StereoChorusModel::sat_inc(uint32_t value, uint32_t amount) {
  return amount > std::numeric_limits<uint32_t>::max() - value
             ? std::numeric_limits<uint32_t>::max()
             : value + amount;
}

}  // namespace render
