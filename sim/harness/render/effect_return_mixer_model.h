#pragma once

#include "fdn_reverb_model.h"
#include "stereo_chorus_model.h"

#include <cstdint>
#include <utility>

namespace render {

class EffectReturnMixerModel {
 public:
  using StereoFrame = std::pair<int32_t, int32_t>;

  void clear() {
    config_clamped_ = false;
    saturation_count_ = 0;
  }
  StereoFrame route_reverb(StereoFrame dry, StereoFrame chorus_wet,
                           const ReverbConfig& reverb_config,
                           bool commit = true);
  StereoFrame mix(StereoFrame dry, StereoFrame chorus_wet,
                  StereoFrame reverb_wet, const ChorusConfig& chorus_config,
                  const ReverbConfig& reverb_config);

  uint32_t saturation_count() const { return saturation_count_; }
  bool config_clamped() const { return config_clamped_; }

 private:
  static int64_t arithmetic_shift_right(int64_t value, unsigned bits);
  static int64_t scale_q1_15(int32_t sample, uint16_t gain);
  static int32_t signed_mix24(int32_t value);
  static int32_t saturate_mix24(int64_t value, bool* saturated);
  void add_saturation_events(uint32_t amount);

  uint32_t saturation_count_ = 0;
  bool config_clamped_ = false;
};

}  // namespace render
