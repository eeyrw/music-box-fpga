#include "global_effects_model.h"

#include "generated/dsp_lut.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <utility>

namespace render {
namespace {

constexpr uint8_t kChorusConfigOpcode = 0x22;
constexpr uint8_t kReverbConfigOpcode = 0x23;
constexpr uint8_t kEffectClearOpcode = 0x24;

uint16_t q15(double value) {
  return uint16_t(std::clamp<long long>(std::llround(value * 32768.0), 0, 0x7fff));
}

uint32_t frames_q16_8(double milliseconds, int sample_rate) {
  return uint32_t(std::llround(milliseconds * sample_rate * 256.0 / 1000.0));
}

uint32_t lfo_increment(double hz, int sample_rate) {
  return uint32_t(std::llround(hz * 4294967296.0 / sample_rate));
}

GlobalEffectsPreset wet_preset(int sample_rate, double chorus_base_ms,
                               double chorus_depth_ms, double chorus_hz,
                               double chorus_send, double chorus_return,
                               double chorus_feedback,
                               double rt60_seconds, double reverb_send,
                               double reverb_return, double damping,
                               double chorus_to_reverb,
                               double pre_delay_ms,
                               std::vector<std::size_t> line_lengths = {}) {
  GlobalEffectsPreset preset;
  preset.reverb_line_lengths = std::move(line_lengths);
  preset.chorus.enable = true;
  preset.chorus.base_delay_q16_8 = frames_q16_8(chorus_base_ms, sample_rate);
  preset.chorus.depth_q16_8 = frames_q16_8(chorus_depth_ms, sample_rate);
  preset.chorus.lfo_phase_inc_q0_32 = lfo_increment(chorus_hz, sample_rate);
  preset.chorus.input_send_q1_15 = q15(chorus_send);
  preset.chorus.return_gain_q1_15 = q15(chorus_return);
  preset.chorus.feedback_q1_15 = int16_t(q15(chorus_feedback));
  preset.chorus.stereo_phase_offset_q0_32 = 0x40000000u;

  preset.reverb.enable = true;
  preset.reverb.input_send_q1_15 = q15(reverb_send);
  preset.reverb.return_gain_q1_15 = q15(reverb_return);
  preset.reverb.damping_q1_15 = q15(damping);
  preset.reverb.chorus_to_reverb_q1_15 = q15(chorus_to_reverb);
  preset.reverb.pre_delay_frames = uint16_t(std::llround(
      pre_delay_ms * sample_rate / 1000.0));
  for (std::size_t line = 0; line < preset.reverb.feedback_gain_q1_15.size(); ++line) {
    const std::size_t delay_frames = preset.reverb_line_lengths.empty()
        ? dsp_lut::kFdnDelayLengths[line]
        : preset.reverb_line_lengths[line];
    const double decay = std::pow(
        10.0, -3.0 * double(delay_frames) /
                  (rt60_seconds * sample_rate));
    preset.reverb.feedback_gain_q1_15[line] = q15(decay / std::sqrt(8.0));
  }
  return preset;
}

}  // namespace

GlobalEffectsPreset make_global_effects_preset(const std::string& name,
                                               int sample_rate) {
  if (sample_rate <= 0) throw std::invalid_argument("effect sample rate must be positive");
  if (name == "off") return {};
  if (sample_rate != 48000) {
    throw std::invalid_argument("global effects presets currently require 48000 Hz");
  }
  if (name == "studio") {
    return wet_preset(sample_rate, 8.0, 1.0, 0.45, 1.0, 0.12, 0.0,
                      1.0, 0.30, 0.18, 0.55, 0.05, 8.0);
  }
  if (name == "hall") {
    GlobalEffectsPreset preset =
        wet_preset(sample_rate, 8.0, 1.0, 0.45, 0.0, 0.0, 0.0,
                   4.5, 0.75, 0.55, 0.58, 0.0, 35.0);
    preset.chorus = {};
    return preset;
  }
  if (name == "chorus") {
    GlobalEffectsPreset preset;
    preset.chorus.enable = true;
    preset.chorus.base_delay_q16_8 = frames_q16_8(8.0, sample_rate);
    preset.chorus.depth_q16_8 = frames_q16_8(1.5, sample_rate);
    preset.chorus.lfo_phase_inc_q0_32 = lfo_increment(0.6, sample_rate);
    preset.chorus.input_send_q1_15 = 0x7fff;
    preset.chorus.return_gain_q1_15 = q15(0.28);
    preset.chorus.feedback_q1_15 = int16_t(q15(0.04));
    preset.chorus.stereo_phase_offset_q0_32 = 0x40000000u;
    return preset;
  }
  if (name == "chorus-max") {
    GlobalEffectsPreset preset;
    preset.chorus.enable = true;
    preset.chorus.base_delay_q16_8 = frames_q16_8(18.0, sample_rate);
    preset.chorus.depth_q16_8 = frames_q16_8(8.0, sample_rate);
    preset.chorus.lfo_phase_inc_q0_32 = lfo_increment(0.8, sample_rate);
    preset.chorus.input_send_q1_15 = 0x7fff;
    preset.chorus.return_gain_q1_15 = 0x7fff;
    preset.chorus.feedback_q1_15 = int16_t(q15(0.4));
    preset.chorus.stereo_phase_offset_q0_32 = 0x40000000u;
    return preset;
  }
  if (name == "reverb-max") {
    GlobalEffectsPreset preset =
        wet_preset(sample_rate, 18.0, 4.0, 0.30, 1.0, 0.0, 0.0,
                   8.0, 1.0, 1.0, 0.55, 0.0, 30.0);
    preset.chorus = {};
    return preset;
  }
  throw std::invalid_argument("unknown effects preset: " + name);
}

void apply_global_effect_enable_overrides(GlobalEffectsPreset& preset,
                                          const std::string& chorus_enable,
                                          const std::string& reverb_enable) {
  auto apply = [](const std::string& value, bool& enable,
                  const char* effect_name) {
    if (value == "auto") return;
    if (value == "off") {
      enable = false;
      return;
    }
    if (value == "on") {
      if (!enable) {
        throw std::invalid_argument(std::string(effect_name) +
                                    " cannot be enabled because the selected preset has no " +
                                    effect_name + " parameters");
      }
      return;
    }
    throw std::invalid_argument(std::string("invalid ") + effect_name +
                                " enable override (expected auto, on, or off)");
  };
  apply(chorus_enable, preset.chorus.enable, "chorus");
  apply(reverb_enable, preset.reverb.enable, "reverb");
}

GlobalEffectsModel::GlobalEffectsModel(
    std::vector<std::size_t> reverb_line_lengths)
    : reverb_(std::move(reverb_line_lengths)) {
  reset();
}

void GlobalEffectsModel::reset() {
  chorus_.reset();
  reverb_.reset();
  mixer_.clear();
  chorus_config_ = {};
  reverb_config_ = {};
  chorus_.set_config(chorus_config_);
  reverb_.set_config(reverb_config_);
}

void GlobalEffectsModel::write_command_words(const std::vector<uint32_t>& words) {
  if (words.empty()) return;
  const uint8_t opcode = uint8_t(words[0] >> 24);
  const uint8_t voice = uint8_t(words[0] >> 16);
  const uint8_t seq = uint8_t(words[0] >> 8);
  const std::size_t payload_words = std::size_t(words[0] & 0xffu);
  if (voice != 0 || seq != 0 || words.size() != payload_words + 1) return;

  if (opcode == kChorusConfigOpcode && payload_words == 6) {
    ChorusConfig config;
    config.enable = (words[1] & 1u) != 0;
    config.feedback_q1_15 = int16_t(words[1] >> 16);
    config.base_delay_q16_8 = words[2];
    config.depth_q16_8 = words[3];
    config.lfo_phase_inc_q0_32 = words[4];
    config.input_send_q1_15 = uint16_t(words[5]);
    config.return_gain_q1_15 = uint16_t(words[5] >> 16);
    config.stereo_phase_offset_q0_32 = words[6];
    chorus_config_ = config;
    chorus_.set_config(chorus_config_);
  } else if (opcode == kReverbConfigOpcode && payload_words == 9) {
    ReverbConfig config;
    config.enable = (words[1] & 1u) != 0;
    config.pre_delay_frames = uint16_t(words[1] >> 1);
    config.input_send_q1_15 = uint16_t(words[2]);
    config.return_gain_q1_15 = uint16_t(words[3]);
    config.damping_q1_15 = uint16_t(words[4]);
    config.chorus_to_reverb_q1_15 = uint16_t(words[5]);
    for (std::size_t pair = 0; pair < 4; ++pair) {
      config.feedback_gain_q1_15[pair * 2] = uint16_t(words[6 + pair]);
      config.feedback_gain_q1_15[pair * 2 + 1] = uint16_t(words[6 + pair] >> 16);
    }
    reverb_config_ = config;
    reverb_.set_config(reverb_config_);
  } else if (opcode == kEffectClearOpcode && payload_words == 1 &&
             (words[1] & ~3u) == 0 && (words[1] & 3u) != 0) {
    if ((words[1] & 1u) != 0) chorus_.clear();
    if ((words[1] & 2u) != 0) reverb_.clear();
  }
}

GlobalEffectsModel::StereoFrame GlobalEffectsModel::process_frame(
    int32_t dry_l, int32_t dry_r) {
  const StereoFrame dry{dry_l, dry_r};
  const StereoFrame chorus_wet = chorus_.process_frame(dry_l, dry_r);
  const StereoFrame reverb_input =
      mixer_.route_reverb(dry, chorus_wet, reverb_config_);
  const StereoFrame reverb_wet =
      reverb_.process_frame(reverb_input.first, reverb_input.second);
  return mixer_.mix(dry, chorus_wet, reverb_wet,
                    chorus_config_, reverb_config_);
}

bool GlobalEffectsModel::config_clamped() const {
  return chorus_.config_clamped() || reverb_.config_clamped() ||
         mixer_.config_clamped();
}

}  // namespace render
