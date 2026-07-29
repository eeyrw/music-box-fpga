#include "lookahead_compressor_model.h"

#include "generated/dsp_lut.h"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace render {
namespace {

constexpr uint8_t kCompressorConfigOpcode = 0x20;
constexpr uint8_t kMasterVolumeOpcode = 0x21;

}  // namespace

LookaheadCompressorModel::LookaheadCompressorModel(std::size_t lookahead_frames,
                                                   RenderDiagnostics* diagnostics)
    : delay_line_(lookahead_frames), diagnostics_(diagnostics) {
  if (lookahead_frames == 0) {
    throw std::invalid_argument("look-ahead frame count must be positive");
  }
  reset();
}

void LookaheadCompressorModel::reset() {
  std::fill(delay_line_.begin(), delay_line_.end(), std::pair<int32_t, int32_t>{0, 0});
  delay_ptr_ = 0;
  delay_level_ = 0;
  config_ = {};
  master_volume_ = 0x7fff;
  gain_reduction_ = 0;
  target_gain_reduction_ = 0;
  detector_peak_ = 0;
  max_gain_reduction_ = 0;
  max_detector_peak_ = 0;
  input_frame_count_ = 0;
  output_frame_count_ = 0;
  compressed_frame_count_ = 0;
  saturation_count_ = 0;
  sync_diagnostics();
}

void LookaheadCompressorModel::write_command_words(const std::vector<uint32_t>& words) {
  if (words.empty()) return;
  const uint8_t opcode = uint8_t(words[0] >> 24);
  const uint8_t voice = uint8_t(words[0] >> 16);
  const uint8_t seq = uint8_t(words[0] >> 8);
  const std::size_t payload_words = std::size_t(words[0] & 0xffu);
  if (voice != 0 || seq != 0 || words.size() != payload_words + 1) return;

  if (opcode == kCompressorConfigOpcode && payload_words == 4) {
    if ((words[1] & 0xfffe0000u) != 0 ||
        words[2] > dsp_lut::kCompCbSilenceQ12_20 ||
        words[3] > dsp_lut::kCompCbSilenceQ12_20 ||
        words[4] > dsp_lut::kCompCbSilenceQ12_20) {
      return;
    }
    config_.enable = (words[1] & 1u) != 0;
    config_.ratio_slope_q0_16 = uint16_t((words[1] >> 1) & 0xffffu);
    config_.threshold_cb_q12_20 = words[2];
    config_.attack_step_cb_q12_20 = words[3];
    config_.release_step_cb_q12_20 = words[4];
  } else if (opcode == kMasterVolumeOpcode && payload_words == 1) {
    if ((words[1] & 0xffff8000u) == 0) master_volume_ = int16_t(words[1]);
  }
  sync_diagnostics();
}

std::optional<std::pair<int16_t, int16_t>> LookaheadCompressorModel::process_frame(
    int32_t mix_l, int32_t mix_r) {
  mix_l = signed_mix25(mix_l);
  mix_r = signed_mix25(mix_r);
  const std::pair<int32_t, int32_t> delayed = delay_line_[delay_ptr_];
  const bool delayed_valid = primed();
  delay_line_[delay_ptr_] = {mix_l, mix_r};
  delay_ptr_ = (delay_ptr_ + 1) % delay_line_.size();
  if (!delayed_valid) ++delay_level_;

  const uint32_t peak = std::max(magnitude(mix_l), magnitude(mix_r));
  detector_peak_ = peak;
  max_detector_peak_ = std::max(max_detector_peak_, peak);
  input_frame_count_ = sat_inc(input_frame_count_);
  uint32_t target = 0;
  if (config_.enable && peak != 0) {
    const int64_t over = level_cb_q12_20(peak) + config_.threshold_cb_q12_20;
    if (over > 0) {
      target = uint32_t((uint64_t(over) * config_.ratio_slope_q0_16) >> 16);
    }
  }
  target_gain_reduction_ = target;

  if (!config_.enable) {
    gain_reduction_ = 0;
  } else if (target > gain_reduction_) {
    const uint32_t distance = target - gain_reduction_;
    gain_reduction_ = config_.attack_step_cb_q12_20 == 0 ||
                              distance <= config_.attack_step_cb_q12_20
                          ? target
                          : gain_reduction_ + config_.attack_step_cb_q12_20;
  } else if (target < gain_reduction_) {
    const uint32_t distance = gain_reduction_ - target;
    gain_reduction_ = config_.release_step_cb_q12_20 == 0 ||
                              distance <= config_.release_step_cb_q12_20
                          ? target
                          : gain_reduction_ - config_.release_step_cb_q12_20;
  }
  max_gain_reduction_ = std::max(max_gain_reduction_, gain_reduction_);

  if (!delayed_valid) {
    sync_diagnostics();
    return std::nullopt;
  }

  const bool compressor_bypass = !config_.enable || gain_reduction_ == 0;
  int64_t scaled_l = 0;
  int64_t scaled_r = 0;
  if (compressor_bypass && master_volume_ == int16_t(0x7fff)) {
    scaled_l = delayed.first;
    scaled_r = delayed.second;
  } else if (compressor_bypass) {
    scaled_l = arithmetic_shift_right(int64_t(delayed.first) * master_volume_, 15);
    scaled_r = arithmetic_shift_right(int64_t(delayed.second) * master_volume_, 15);
  } else {
    const int16_t compressor_gain = gain_from_cb(gain_reduction_);
    if (master_volume_ == int16_t(0x7fff)) {
      scaled_l = arithmetic_shift_right(int64_t(delayed.first) * compressor_gain, 15);
      scaled_r = arithmetic_shift_right(int64_t(delayed.second) * compressor_gain, 15);
    } else {
      scaled_l = arithmetic_shift_right(
          int64_t(delayed.first) * compressor_gain * master_volume_, 30);
      scaled_r = arithmetic_shift_right(
          int64_t(delayed.second) * compressor_gain * master_volume_, 30);
    }
  }
  output_frame_count_ = sat_inc(output_frame_count_);
  if (!compressor_bypass) compressed_frame_count_ = sat_inc(compressed_frame_count_);
  const uint32_t saturation_events =
      uint32_t(scaled_l > std::numeric_limits<int16_t>::max() ||
               scaled_l < std::numeric_limits<int16_t>::min()) +
      uint32_t(scaled_r > std::numeric_limits<int16_t>::max() ||
               scaled_r < std::numeric_limits<int16_t>::min());
  saturation_count_ = sat_inc(saturation_count_, saturation_events);
  sync_diagnostics();
  return std::pair<int16_t, int16_t>{saturate_pcm(scaled_l), saturate_pcm(scaled_r)};
}

int32_t LookaheadCompressorModel::signed_mix25(int32_t value) {
  const uint32_t bits = uint32_t(value) & 0x01ffffffu;
  return (bits & 0x01000000u) != 0
             ? int32_t(int64_t(bits) - (int64_t{1} << 25))
             : int32_t(bits);
}

uint32_t LookaheadCompressorModel::magnitude(int32_t value) {
  return value < 0 ? uint32_t(-(int64_t(value))) : uint32_t(value);
}

int64_t LookaheadCompressorModel::arithmetic_shift_right(int64_t value, unsigned bits) {
  if (value >= 0) return value >> bits;
  const uint64_t absolute = uint64_t(-(value + 1)) + 1u;
  const uint64_t rounded = absolute + ((uint64_t{1} << bits) - 1u);
  return -int64_t(rounded >> bits);
}

int16_t LookaheadCompressorModel::saturate_pcm(int64_t value) {
  if (value > std::numeric_limits<int16_t>::max()) return std::numeric_limits<int16_t>::max();
  if (value < std::numeric_limits<int16_t>::min()) return std::numeric_limits<int16_t>::min();
  return int16_t(value);
}

int16_t LookaheadCompressorModel::gain_from_cb(uint32_t attenuation_cb_q12_20) {
  if (attenuation_cb_q12_20 >= dsp_lut::kCompCbSilenceQ12_20) return 0;
  uint32_t octave = 0;
  if (attenuation_cb_q12_20 >= dsp_lut::kCompCbOctaveQ12_20[16]) {
    octave = 16;
  } else {
    if (attenuation_cb_q12_20 >= dsp_lut::kCompCbOctaveQ12_20[8]) octave = 8;
    if (attenuation_cb_q12_20 >= dsp_lut::kCompCbOctaveQ12_20[octave + 4]) octave += 4;
    if (attenuation_cb_q12_20 >= dsp_lut::kCompCbOctaveQ12_20[octave + 2]) octave += 2;
    if (attenuation_cb_q12_20 >= dsp_lut::kCompCbOctaveQ12_20[octave + 1]) octave += 1;
  }
  const uint32_t residual = attenuation_cb_q12_20 - dsp_lut::kCompCbOctaveQ12_20[octave];
  const uint32_t index =
      (residual + (1u << (dsp_lut::kCompCbToQ15ResidualIndexShift - 1u))) >>
      dsp_lut::kCompCbToQ15ResidualIndexShift;
  const uint32_t shifted = dsp_lut::kCompCbToQ15Mantissa.at(index) >> octave;
  return int16_t((shifted + (1u << (dsp_lut::kCompCbToQ15GuardBits - 1u))) >>
                 dsp_lut::kCompCbToQ15GuardBits);
}

int64_t LookaheadCompressorModel::level_cb_q12_20(uint32_t peak_magnitude) {
  uint32_t exponent = 0;
  for (int bit = 23; bit >= 0; --bit) {
    if ((peak_magnitude & (1u << bit)) != 0) {
      exponent = uint32_t(bit);
      break;
    }
  }
  const uint32_t normalized = peak_magnitude << (31u - exponent);
  const uint32_t index =
      ((normalized >> dsp_lut::kCompMagToCbIndexShift) &
       ((1u << dsp_lut::kCompMagToCbMantissaBits) - 1u)) +
      ((normalized >> dsp_lut::kCompMagToCbRoundBit) & 1u);
  const int64_t mantissa = dsp_lut::kCompMagToCbMantissa.at(index);
  if (exponent >= dsp_lut::kCompMagToCbReferenceExponent) {
    return int64_t(dsp_lut::kCompCbOctaveQ12_20.at(
               exponent - dsp_lut::kCompMagToCbReferenceExponent)) +
           mantissa;
  }
  return -int64_t(dsp_lut::kCompCbOctaveQ12_20.at(
             dsp_lut::kCompMagToCbReferenceExponent - exponent)) +
         mantissa;
}

uint32_t LookaheadCompressorModel::sat_inc(uint32_t value, uint32_t amount) {
  return amount > std::numeric_limits<uint32_t>::max() - value
             ? std::numeric_limits<uint32_t>::max()
             : value + amount;
}

void LookaheadCompressorModel::sync_diagnostics() {
  if (!diagnostics_) return;
  diagnostics_->compressor_enabled = config_.enable;
  diagnostics_->compressor_primed = primed();
  diagnostics_->compressor_active = config_.enable && gain_reduction_ != 0;
  diagnostics_->compressor_delay_level = uint32_t(delay_level_);
  diagnostics_->compressor_gain_reduction_cb_q12_20 = gain_reduction_;
  diagnostics_->compressor_target_gain_reduction_cb_q12_20 = target_gain_reduction_;
  diagnostics_->compressor_detector_peak = detector_peak_;
  diagnostics_->compressor_max_gain_reduction_cb_q12_20 = max_gain_reduction_;
  diagnostics_->compressor_max_detector_peak = max_detector_peak_;
  diagnostics_->compressor_input_frame_count = input_frame_count_;
  diagnostics_->compressor_output_frame_count = output_frame_count_;
  diagnostics_->compressor_compressed_frame_count = compressed_frame_count_;
  diagnostics_->compressor_saturation_count = saturation_count_;
}

}  // namespace render
