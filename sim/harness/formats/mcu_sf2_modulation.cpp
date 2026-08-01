#include "mcu_sf2_modulation.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>

namespace render {
namespace {

constexpr uint16_t kSourceNone = 0;
constexpr uint16_t kTransformAbsoluteValue = 2;

int32_t round_q16(double value) {
  const double scaled = value * double(kMcuModulationOne);
  if (scaled >= double(std::numeric_limits<int32_t>::max())) return INT32_MAX;
  if (scaled <= double(std::numeric_limits<int32_t>::min())) return INT32_MIN;
  return int32_t(std::llround(scaled));
}

double concave(int value) {
  if (value <= 0) return 0.0;
  if (value >= 127) return 1.0;
  return (-400.0 / 960.0) * std::log10(double(127 - value) / 127.0);
}

double convex(int value) {
  if (value <= 0) return 0.0;
  if (value >= 127) return 1.0;
  return 1.0 - (-400.0 / 960.0) * std::log10(double(value) / 127.0);
}

int32_t multiply_q16(int32_t a, int32_t b) {
  const int64_t product = int64_t(a) * int64_t(b);
  const int64_t bias = product >= 0 ? int64_t(1) << 15 : -(int64_t(1) << 15);
  return int32_t((product + bias) / (int64_t(1) << 16));
}

int native_7bit(uint16_t source, const McuFixedChannelState& channel,
                const McuFixedVoiceSources& voice) {
  const bool cc = (source & 0x0080u) != 0;
  const int index = source & 0x007f;
  if (cc) return channel.cc[size_t(index)];
  switch (index) {
    case 2: return std::max(1, int(voice.velocity));
    case 3: return voice.note;
    case 10: return channel.key_pressure[size_t(voice.note & 0x7f)];
    case 13: return channel.channel_pressure;
    default: return 0;
  }
}

}  // namespace

uint8_t mcu_sf2_source_curve_id(uint16_t source) {
  const uint8_t type = uint8_t((source >> 10) & 3u);
  const uint8_t bipolar = (source & 0x0200u) != 0 ? 4u : 0u;
  const uint8_t negative = (source & 0x0100u) != 0 ? 8u : 0u;
  return uint8_t(type | bipolar | negative);
}

uint16_t mcu_sf2_source_dependencies(uint16_t source) {
  if (source == kSourceNone) return 0;
  if ((source & 0x0080u) != 0) return kMcuDependencyCc;
  switch (source & 0x007fu) {
    case 2:
    case 3: return kMcuDependencyNote;
    case 10:
    case 13: return kMcuDependencyPressure;
    case 14: return kMcuDependencyPitchWheel;
    case 16: return kMcuDependencyTuning;
    default: return 0;
  }
}

int32_t mcu_sf2_source_curve_q16(uint8_t curve_id, uint8_t value) {
  const int type = curve_id & 3;
  const bool bipolar = (curve_id & 4u) != 0;
  const bool negative = (curve_id & 8u) != 0;
  const int directed = negative ? 127 - int(value) : int(value);
  const double x = double(directed) / 128.0;
  double shaped = x;
  if (bipolar) {
    const double v = -1.0 + 2.0 * x;
    const double magnitude = std::abs(v);
    if (type == 1) {
      const double curved = concave(int(std::round(magnitude * 128.0)));
      shaped = v >= 0.0 ? std::min(curved, 127.0 / 128.0) : -curved;
    } else if (type == 2) {
      const double curved = convex(int(std::round(magnitude * 128.0)));
      shaped = v >= 0.0 ? std::min(curved, 127.0 / 128.0) : -curved;
    }
    else if (type == 3) shaped = v >= 0.0 ? 1.0 : -1.0;
    else shaped = v;
  } else if (type == 1) {
    shaped = std::min(concave(directed), 127.0 / 128.0);
  } else if (type == 2) {
    shaped = std::min(convex(directed), 127.0 / 128.0);
  } else if (type == 3) {
    shaped = x >= 0.5 ? 1.0 : 0.0;
  }
  return round_q16(shaped);
}

int32_t mcu_sf2_source_value_q16(uint16_t source,
                                 const McuFixedChannelState& channel,
                                 const McuFixedVoiceSources& voice) {
  if (source == kSourceNone) return kMcuModulationOne;
  if ((source & 0x0080u) == 0 && (source & 0x007fu) == 14) {
    int32_t value = int32_t(channel.pitch_bend) * 8;
    return (source & 0x0100u) != 0 ? -value : value;
  }
  if ((source & 0x0080u) == 0 && (source & 0x007fu) == 16) {
    const int32_t hundredths = int32_t(channel.pitch_bend_range_semitones) * 100 +
                               channel.pitch_bend_range_cents;
    const int native_q16 = int((int64_t(hundredths) * kMcuModulationOne + 50) / 100);
    const int value = std::max(0, std::min(127 * kMcuModulationOne, native_q16));
    const bool negative = (source & 0x0100u) != 0;
    const int32_t directed = negative ? 127 * kMcuModulationOne - value : value;
    return directed / 128;
  }
  return mcu_sf2_source_curve_q16(mcu_sf2_source_curve_id(source),
                                  uint8_t(native_7bit(source, channel, voice)));
}

int64_t mcu_sf2_evaluate_term_q16(const McuSf2ModulationTerm& term,
                                  const McuFixedChannelState& channel,
                                  const McuFixedVoiceSources& voice) {
  int32_t value = multiply_q16(mcu_sf2_source_value_q16(term.source, channel, voice),
                               mcu_sf2_source_value_q16(term.amount_source, channel, voice));
  int64_t result = int64_t(term.amount) * value;
  if (term.transform == kTransformAbsoluteValue) result = std::llabs(result);
  return result;
}

double mcu_sf2_pitch_ratio(int64_t cents_q16) {
  constexpr int kMinimumCents = -24000;
  constexpr int kMaximumCents = 24000;
  constexpr int kStepsPerCent = 4;
  constexpr int kRatioCount =
      (kMaximumCents - kMinimumCents) * kStepsPerCent + 1;
  static const std::array<double, kRatioCount> ratios = [] {
    std::array<double, kRatioCount> values{};
    for (int index = 0; index < kRatioCount; ++index) {
      const double cents = double(index) / kStepsPerCent + kMinimumCents;
      values[index] = std::pow(2.0, cents / 1200.0);
    }
    return values;
  }();
  const double cents = double(cents_q16) / kMcuModulationOne;
  double ratio = ratios.front();
  if (cents >= kMaximumCents) {
    ratio = ratios.back();
  } else if (cents > kMinimumCents) {
    const double position = (cents - kMinimumCents) * kStepsPerCent;
    const int lower = int(position);
    const double fraction = position - lower;
    ratio = ratios[lower] + (ratios[lower + 1] - ratios[lower]) * fraction;
  }
  return ratio;
}

uint32_t mcu_sf2_phase_increment(uint32_t base_phase_increment,
                                 int64_t cents_q16) {
  const double raw = double(base_phase_increment) * mcu_sf2_pitch_ratio(cents_q16);
  if (raw < 1.0) return 1;
  if (raw > double(UINT32_MAX)) return UINT32_MAX;
  return uint32_t(std::round(raw));
}

std::pair<int, int> mcu_sf2_mono_gains(uint16_t base_gain, int16_t base_pan,
                                       int64_t attenuation_q16,
                                       int64_t pan_delta_q16) {
  const double attenuation = double(attenuation_q16) / kMcuModulationOne;
  const double level = attenuation_gain(attenuation);
  const int scaled = clamp_q15(int(std::round(double(base_gain) * level)));
  const int64_t pan_q16 = int64_t(base_pan) * kMcuModulationOne + pan_delta_q16;
  const int64_t bias = pan_q16 >= 0 ? int64_t(1) << 15 : -(int64_t(1) << 15);
  const int pan = std::max(-500, std::min(500,
      int((pan_q16 + bias) / (int64_t(1) << 16))));
  return equal_power_pan_gains(scaled, scaled, pan, false);
}

FilterConfig mcu_sf2_filter_config(int cutoff_cents, int resonance_cb,
                                   int sample_rate) {
  auto q2_14 = [](double value) {
    const double raw = std::round(value * 16384.0);
    return int(std::max(double(INT16_MIN), std::min(double(INT16_MAX), raw)));
  };
  cutoff_cents = std::max(1500, std::min(13500, cutoff_cents));
  const double cutoff_hz = 8.176 * std::pow(2.0, double(cutoff_cents) / 1200.0);
  const double nyquist = double(sample_rate) * 0.5;
  FilterConfig filter;
  if (cutoff_hz >= nyquist * 0.97) return filter;
  resonance_cb = std::max(0, std::min(960, ((resonance_cb + 1) / 2) * 2));
  const double q = std::max(
      0.5, std::pow(10.0, double(resonance_cb) / 200.0) * 0.7071067811865476);
  const double omega = 2.0 * 3.14159265358979323846 * cutoff_hz /
                       double(sample_rate);
  const double sin_w = std::sin(omega);
  const double cos_w = std::cos(omega);
  const double alpha = sin_w / (2.0 * q);
  const double a0 = 1.0 + alpha;
  filter.enable = true;
  filter.b0 = q2_14(((1.0 - cos_w) * 0.5) / a0);
  filter.b1 = q2_14((1.0 - cos_w) / a0);
  filter.b2 = q2_14(((1.0 - cos_w) * 0.5) / a0);
  filter.a1 = q2_14((-2.0 * cos_w) / a0);
  filter.a2 = q2_14((1.0 - alpha) / a0);
  return filter;
}

}  // namespace render
