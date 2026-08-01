#pragma once

#include "render_types.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <utility>

namespace render {

constexpr int kMcuModulationFractionBits = 16;
constexpr int32_t kMcuModulationOne = 1 << kMcuModulationFractionBits;
constexpr size_t kMcuSourceCurveCount = 16;
constexpr size_t kMcuSourceCurveSize = 128;

enum McuModulationDependency : uint16_t {
  kMcuDependencyNote = 1u << 0,
  kMcuDependencyCc = 1u << 1,
  kMcuDependencyPitchWheel = 1u << 2,
  kMcuDependencyPressure = 1u << 3,
  kMcuDependencyTuning = 1u << 4,
};

struct McuFixedChannelState {
  std::array<uint8_t, 128> cc{};
  std::array<uint8_t, 128> key_pressure{};
  int16_t pitch_bend = 0;
  uint8_t channel_pressure = 0;
  uint8_t pitch_bend_range_semitones = 2;
  uint8_t pitch_bend_range_cents = 0;
};

struct McuFixedVoiceSources {
  uint8_t note = 0;
  uint8_t velocity = 127;
};

struct McuSf2ModulationTerm {
  uint16_t source = 0;
  uint16_t destination = 0;
  int16_t amount = 0;
  uint16_t amount_source = 0;
  uint16_t transform = 0;
  uint16_t dependencies = 0;
};

uint8_t mcu_sf2_source_curve_id(uint16_t source);
uint16_t mcu_sf2_source_dependencies(uint16_t source);
int32_t mcu_sf2_source_curve_q16(uint8_t curve_id, uint8_t value);
int32_t mcu_sf2_source_value_q16(uint16_t source,
                                 const McuFixedChannelState& channel,
                                 const McuFixedVoiceSources& voice);
int64_t mcu_sf2_evaluate_term_q16(const McuSf2ModulationTerm& term,
                                  const McuFixedChannelState& channel,
                                  const McuFixedVoiceSources& voice);
double mcu_sf2_pitch_ratio(int64_t cents_q16);
uint32_t mcu_sf2_phase_increment(uint32_t base_phase_increment,
                                 int64_t cents_q16);
std::pair<int, int> mcu_sf2_mono_gains(uint16_t base_gain, int16_t base_pan,
                                       int64_t attenuation_q16,
                                       int64_t pan_delta_q16);
FilterConfig mcu_sf2_filter_config(int cutoff_cents, int resonance_cb,
                                   int sample_rate);

}  // namespace render
