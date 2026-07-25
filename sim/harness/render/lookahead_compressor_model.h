#pragma once

#include "command_control.h"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

namespace render {

class LookaheadCompressorModel : public CommandWordSink {
 public:
  explicit LookaheadCompressorModel(std::size_t lookahead_frames = 48,
                                    RenderDiagnostics* diagnostics = nullptr);

  void reset();
  void write_command_words(const std::vector<uint32_t>& words) override;

  std::optional<std::pair<int16_t, int16_t>> process_frame(int32_t mix_l,
                                                           int32_t mix_r);

  bool primed() const { return delay_level_ == delay_line_.size(); }
  uint32_t gain_reduction_cb_q12_20() const { return gain_reduction_; }
  uint32_t target_gain_reduction_cb_q12_20() const { return target_gain_reduction_; }
  uint32_t detector_peak() const { return detector_peak_; }
  uint32_t max_gain_reduction_cb_q12_20() const { return max_gain_reduction_; }
  uint32_t max_detector_peak() const { return max_detector_peak_; }
  uint32_t input_frame_count() const { return input_frame_count_; }
  uint32_t output_frame_count() const { return output_frame_count_; }
  uint32_t compressed_frame_count() const { return compressed_frame_count_; }
  uint32_t saturation_count() const { return saturation_count_; }
  const CompressorCommandConfig& config() const { return config_; }
  int16_t master_volume() const { return master_volume_; }

 private:
  static int32_t signed_mix24(int32_t value);
  static uint32_t magnitude(int32_t value);
  static int64_t arithmetic_shift_right(int64_t value, unsigned bits);
  static int16_t saturate_pcm(int64_t value);
  static int16_t gain_from_cb(uint32_t attenuation_cb_q12_20);
  static int64_t level_cb_q12_20(uint32_t peak_magnitude);
  static uint32_t sat_inc(uint32_t value, uint32_t amount = 1);
  void sync_diagnostics();

  std::vector<std::pair<int32_t, int32_t>> delay_line_;
  std::size_t delay_ptr_ = 0;
  std::size_t delay_level_ = 0;
  CompressorCommandConfig config_;
  int16_t master_volume_ = 0x7fff;
  uint32_t gain_reduction_ = 0;
  uint32_t target_gain_reduction_ = 0;
  uint32_t detector_peak_ = 0;
  uint32_t max_gain_reduction_ = 0;
  uint32_t max_detector_peak_ = 0;
  uint32_t input_frame_count_ = 0;
  uint32_t output_frame_count_ = 0;
  uint32_t compressed_frame_count_ = 0;
  uint32_t saturation_count_ = 0;
  RenderDiagnostics* diagnostics_ = nullptr;
};

}  // namespace render
