#include "fdn_reverb_model.h"

#include "generated/dsp_lut.h"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace render {
namespace {

constexpr uint16_t kFeedbackLimitQ1_15 = 0x2d41;

}  // namespace

FdnReverbModel::FdnReverbModel(std::vector<std::size_t> line_lengths,
                               std::size_t pre_delay_capacity)
    : pre_delay_(pre_delay_capacity) {
  if (line_lengths.empty()) {
    line_lengths.assign(dsp_lut::kFdnDelayLengths.begin(),
                        dsp_lut::kFdnDelayLengths.end());
  }
  if (line_lengths.size() != 8 || pre_delay_capacity < 1) {
    throw std::invalid_argument("FDN requires eight nonempty lines and pre-delay storage");
  }
  for (std::size_t length : line_lengths) {
    if (length == 0) throw std::invalid_argument("FDN line length must be positive");
    lines_.emplace_back(length);
  }
  reset();
}

void FdnReverbModel::reset() {
  pointers_.fill(0);
  ages_.fill(0);
  damping_state_.fill(0);
  pre_delay_ptr_ = 0;
  pre_delay_age_ = 0;
  config_ = {};
  config_clamped_ = false;
  saturation_count_ = 0;
}

void FdnReverbModel::clear() {
  pointers_.fill(0);
  ages_.fill(0);
  damping_state_.fill(0);
  pre_delay_ptr_ = 0;
  pre_delay_age_ = 0;
  config_clamped_ = false;
  saturation_count_ = 0;
}

std::pair<int32_t, int32_t> FdnReverbModel::process_frame(int32_t left,
                                                          int32_t right) {
  const ReverbConfig config = effective_config();
  left = signed_mix24(left);
  right = signed_mix24(right);

  std::pair<int32_t, int32_t> delayed{left, right};
  if (config.pre_delay_frames != 0) {
    const std::size_t distance = config.pre_delay_frames;
    if (distance <= pre_delay_age_) {
      const std::size_t address =
          (pre_delay_ptr_ + pre_delay_.size() - distance) % pre_delay_.size();
      delayed = pre_delay_[address];
    } else {
      delayed = {0, 0};
    }
  }
  pre_delay_[pre_delay_ptr_] = {left, right};
  pre_delay_ptr_ = (pre_delay_ptr_ + 1) % pre_delay_.size();
  pre_delay_age_ = std::min(pre_delay_age_ + 1, pre_delay_.size());

  const int64_t input_l = delayed.first;
  const int64_t input_r = delayed.second;

  std::array<int32_t, 8> damped{};
  for (std::size_t line = 0; line < 8; ++line) {
    const int32_t read = ages_[line] < lines_[line].size()
                             ? 0
                             : lines_[line][pointers_[line]];
    damped[line] = int32_t(int64_t(read) + arithmetic_shift_right(
        int64_t(damping_state_[line] - read) * config.damping_q1_15, 15));
    damping_state_[line] = damped[line];
  }

  const std::array<int64_t, 8> transformed = hadamard(damped);
  for (std::size_t line = 0; line < 8; ++line) {
    const int64_t injection = arithmetic_shift_right(
        input_l + ((line & 1u) ? -input_r : input_r), 1);
    const int64_t feedback = arithmetic_shift_right(
        transformed[line] * config.feedback_gain_q1_15[line], 15);
    bool saturated = false;
    lines_[line][pointers_[line]] = saturate_mix24(injection + feedback, &saturated);
    saturation_count_ = sat_inc(saturation_count_, saturated ? 1u : 0u);
    pointers_[line] = (pointers_[line] + 1) % lines_[line].size();
    ages_[line] = std::min(ages_[line] + 1, lines_[line].size());
  }

  int64_t wet_l_sum = 0;
  int64_t wet_r_sum = 0;
  for (std::size_t line = 0; line < 8; ++line) {
    const int sign_l = ((line >> 1) & 1u) ? -1 : 1;
    const int sign_r = (line == 1 || line == 2 || line == 5 || line == 6) ? -1 : 1;
    wet_l_sum += sign_l * int64_t(damped[line]);
    wet_r_sum += sign_r * int64_t(damped[line]);
  }
  if (!config.enable) return {0, 0};
  return {saturate_mix24(arithmetic_shift_right(wet_l_sum, 3)),
          saturate_mix24(arithmetic_shift_right(wet_r_sum, 3))};
}

ReverbConfig FdnReverbModel::effective_config() {
  ReverbConfig result = config_;
  const uint16_t damping = result.damping_q1_15;
  const uint16_t pre_delay = result.pre_delay_frames;
  result.damping_q1_15 = std::min<uint16_t>(result.damping_q1_15, 0x7fff);
  result.pre_delay_frames = uint16_t(std::min<std::size_t>(
      result.pre_delay_frames, pre_delay_.size() - 1));
  if (damping != result.damping_q1_15 || pre_delay != result.pre_delay_frames) {
    config_clamped_ = true;
  }
  for (uint16_t& gain : result.feedback_gain_q1_15) {
    const uint16_t requested = gain;
    gain = std::min(gain, kFeedbackLimitQ1_15);
    if (gain != requested) config_clamped_ = true;
  }
  return result;
}

std::array<int64_t, 8> FdnReverbModel::hadamard(
    const std::array<int32_t, 8>& input) {
  std::array<int64_t, 8> a{};
  std::array<int64_t, 8> b{};
  std::array<int64_t, 8> output{};
  for (std::size_t index = 0; index < 8; index += 2) {
    a[index] = int64_t(input[index]) + input[index + 1];
    a[index + 1] = int64_t(input[index]) - input[index + 1];
  }
  for (std::size_t block = 0; block < 8; block += 4) {
    b[block] = a[block] + a[block + 2];
    b[block + 1] = a[block + 1] + a[block + 3];
    b[block + 2] = a[block] - a[block + 2];
    b[block + 3] = a[block + 1] - a[block + 3];
  }
  for (std::size_t index = 0; index < 4; ++index) {
    output[index] = b[index] + b[index + 4];
    output[index + 4] = b[index] - b[index + 4];
  }
  return output;
}

uint8_t FdnReverbModel::valid_line_mask() const {
  uint8_t mask = 0;
  for (std::size_t line = 0; line < 8; ++line) {
    if (ages_[line] == lines_[line].size()) mask |= uint8_t(1u << line);
  }
  return mask;
}

int64_t FdnReverbModel::arithmetic_shift_right(int64_t value, unsigned bits) {
  if (value >= 0) return value >> bits;
  return -int64_t((uint64_t(-(value + 1)) + 1u + ((uint64_t{1} << bits) - 1u)) >> bits);
}

int32_t FdnReverbModel::signed_mix24(int32_t value) {
  const uint32_t bits = uint32_t(value) & 0x00ffffffu;
  return (bits & 0x00800000u) ? int32_t(int64_t(bits) - (int64_t{1} << 24))
                              : int32_t(bits);
}

int32_t FdnReverbModel::saturate_mix24(int64_t value, bool* saturated) {
  constexpr int32_t minimum = -(1 << 23);
  constexpr int32_t maximum = (1 << 23) - 1;
  const bool clipped = value < minimum || value > maximum;
  if (saturated) *saturated = clipped;
  return int32_t(std::clamp<int64_t>(value, minimum, maximum));
}

uint32_t FdnReverbModel::sat_inc(uint32_t value, uint32_t amount) {
  return amount > std::numeric_limits<uint32_t>::max() - value
             ? std::numeric_limits<uint32_t>::max()
             : value + amount;
}

}  // namespace render
