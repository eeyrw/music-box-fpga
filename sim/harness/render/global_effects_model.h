#pragma once

#include "command_control.h"
#include "effect_return_mixer_model.h"
#include "fdn_reverb_model.h"
#include "stereo_chorus_model.h"

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace render {

struct GlobalEffectsPreset {
  ChorusCommandConfig chorus;
  ReverbCommandConfig reverb;
  std::vector<std::size_t> reverb_line_lengths;
};

GlobalEffectsPreset make_global_effects_preset(const std::string& name,
                                               int sample_rate);
void apply_global_effect_enable_overrides(GlobalEffectsPreset& preset,
                                          const std::string& chorus_enable,
                                          const std::string& reverb_enable);

class GlobalEffectsModel : public CommandWordSink {
 public:
  using StereoFrame = std::pair<int32_t, int32_t>;

  explicit GlobalEffectsModel(std::vector<std::size_t> reverb_line_lengths = {});

  void reset();
  void write_command_words(CommandWordView words) override;
  StereoFrame process_frame(int32_t dry_l, int32_t dry_r);

  const ChorusConfig& chorus_config() const { return chorus_config_; }
  const ReverbConfig& reverb_config() const { return reverb_config_; }
  uint32_t chorus_saturation_count() const { return chorus_.saturation_count(); }
  uint32_t reverb_saturation_count() const { return reverb_.saturation_count(); }
  uint32_t mixer_saturation_count() const { return mixer_.saturation_count(); }
  bool config_clamped() const;
  std::size_t chorus_history_level() const { return chorus_.history_level(); }
  uint8_t reverb_valid_line_mask() const { return reverb_.valid_line_mask(); }

 private:
  StereoChorusModel chorus_;
  FdnReverbModel reverb_;
  EffectReturnMixerModel mixer_;
  ChorusConfig chorus_config_;
  ReverbConfig reverb_config_;
};

}  // namespace render
