#include "effect_return_mixer_model.h"

#include <algorithm>
#include <limits>

namespace render {

EffectReturnMixerModel::StereoFrame EffectReturnMixerModel::route_reverb(
    StereoFrame dry, StereoFrame chorus_wet,
    const ReverbConfig& reverb_config, bool commit) {
  if (commit && (reverb_config.input_send_q1_15 > 0x7fff ||
                 reverb_config.chorus_to_reverb_q1_15 > 0x7fff)) {
    config_clamped_ = true;
  }
  dry = {signed_mix24(dry.first), signed_mix24(dry.second)};
  chorus_wet = {signed_mix24(chorus_wet.first), signed_mix24(chorus_wet.second)};
  bool saturated_l = false;
  bool saturated_r = false;
  const int32_t left = saturate_mix24(
      scale_q1_15(dry.first, reverb_config.input_send_q1_15) +
          scale_q1_15(chorus_wet.first,
                      reverb_config.chorus_to_reverb_q1_15),
      &saturated_l);
  const int32_t right = saturate_mix24(
      scale_q1_15(dry.second, reverb_config.input_send_q1_15) +
          scale_q1_15(chorus_wet.second,
                      reverb_config.chorus_to_reverb_q1_15),
      &saturated_r);
  if (commit) add_saturation_events(uint32_t(saturated_l) + uint32_t(saturated_r));
  return {left, right};
}

EffectReturnMixerModel::StereoFrame EffectReturnMixerModel::mix(
    StereoFrame dry, StereoFrame chorus_wet, StereoFrame reverb_wet,
    const ChorusConfig& chorus_config, const ReverbConfig& reverb_config) {
  if (chorus_config.return_gain_q1_15 > 0x7fff ||
      reverb_config.return_gain_q1_15 > 0x7fff) {
    config_clamped_ = true;
  }
  dry = {signed_mix24(dry.first), signed_mix24(dry.second)};
  chorus_wet = {signed_mix24(chorus_wet.first), signed_mix24(chorus_wet.second)};
  reverb_wet = {signed_mix24(reverb_wet.first), signed_mix24(reverb_wet.second)};
  bool saturated_l = false;
  bool saturated_r = false;
  const int32_t left = saturate_mix24(
      int64_t(dry.first) +
          scale_q1_15(chorus_wet.first, chorus_config.return_gain_q1_15) +
          scale_q1_15(reverb_wet.first, reverb_config.return_gain_q1_15),
      &saturated_l);
  const int32_t right = saturate_mix24(
      int64_t(dry.second) +
          scale_q1_15(chorus_wet.second, chorus_config.return_gain_q1_15) +
          scale_q1_15(reverb_wet.second, reverb_config.return_gain_q1_15),
      &saturated_r);
  add_saturation_events(uint32_t(saturated_l) + uint32_t(saturated_r));
  return {left, right};
}

int64_t EffectReturnMixerModel::arithmetic_shift_right(int64_t value,
                                                        unsigned bits) {
  if (value >= 0) return value >> bits;
  return -int64_t((uint64_t(-(value + 1)) + 1u +
                  ((uint64_t{1} << bits) - 1u)) >> bits);
}

int64_t EffectReturnMixerModel::scale_q1_15(int32_t sample, uint16_t gain) {
  if (gain >= 0x7fff) return sample;
  return arithmetic_shift_right(int64_t(sample) * gain, 15);
}

int32_t EffectReturnMixerModel::signed_mix24(int32_t value) {
  const uint32_t bits = uint32_t(value) & 0x00ffffffu;
  return (bits & 0x00800000u) ? int32_t(int64_t(bits) - (int64_t{1} << 24))
                              : int32_t(bits);
}

int32_t EffectReturnMixerModel::saturate_mix24(int64_t value,
                                                bool* saturated) {
  constexpr int32_t minimum = -(1 << 23);
  constexpr int32_t maximum = (1 << 23) - 1;
  *saturated = value < minimum || value > maximum;
  return int32_t(std::clamp<int64_t>(value, minimum, maximum));
}

void EffectReturnMixerModel::add_saturation_events(uint32_t amount) {
  const uint32_t maximum = std::numeric_limits<uint32_t>::max();
  saturation_count_ = amount > maximum - saturation_count_
                          ? maximum
                          : saturation_count_ + amount;
}

}  // namespace render
