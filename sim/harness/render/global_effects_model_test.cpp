#include "global_effects_model.h"

#include <cstdint>
#include <iostream>
#include <stdexcept>

int main() {
  try {
    render::GlobalEffectsModel model;
    render::CommandAudioControl control(model);
    auto dry = model.process_frame(123456, -234567);
    if (dry.first != 123456 || dry.second != -234567) {
      throw std::runtime_error("disabled global effects changed dry mix");
    }

    const auto preset = render::make_global_effects_preset("hall", 48000);
    control.configure_chorus(preset.chorus);
    control.configure_reverb(preset.reverb);
    bool heard_tail = false;
    model.process_frame(1 << 20, -(1 << 20));
    for (int frame = 0; frame < 5000; ++frame) {
      const auto output = model.process_frame(0, 0);
      heard_tail = heard_tail || output.first != 0 || output.second != 0;
    }
    if (!heard_tail || model.reverb_valid_line_mask() != 0xffu ||
        model.config_clamped()) {
      throw std::runtime_error("hall preset did not produce a valid unclamped tail");
    }

    control.clear_effects(3);
    if (model.chorus_history_level() != 0 || model.reverb_valid_line_mask() != 0) {
      throw std::runtime_error("effect clear did not invalidate spatial history");
    }
    bool rejected = false;
    try {
      (void)render::make_global_effects_preset("unknown", 48000);
    } catch (const std::invalid_argument&) {
      rejected = true;
    }
    if (!rejected) throw std::runtime_error("unknown effects preset was accepted");
    const auto musical_chorus =
        render::make_global_effects_preset("chorus", 48000);
    if (!musical_chorus.chorus.enable || musical_chorus.reverb.enable ||
        musical_chorus.chorus.feedback_q1_15 >= 0x1000 ||
        musical_chorus.chorus.return_gain_q1_15 >= 0x3000) {
      throw std::runtime_error("musical chorus preset is too resonant or wet");
    }
    const auto musical_hall =
        render::make_global_effects_preset("hall", 48000);
    if (musical_hall.chorus.enable || !musical_hall.reverb.enable ||
        musical_hall.reverb.return_gain_q1_15 >= 0x6000) {
      throw std::runtime_error("musical hall preset routing mismatch");
    }
    const auto chorus_maximum =
        render::make_global_effects_preset("chorus-max", 48000);
    if (!chorus_maximum.chorus.enable || chorus_maximum.reverb.enable ||
        chorus_maximum.chorus.input_send_q1_15 != 0x7fff ||
        chorus_maximum.chorus.return_gain_q1_15 != 0x7fff) {
      throw std::runtime_error("chorus-max preset did not isolate maximum wet level");
    }
    const auto maximum =
        render::make_global_effects_preset("reverb-max", 48000);
    if (maximum.chorus.enable || !maximum.reverb.enable ||
        maximum.reverb.input_send_q1_15 != 0x7fff ||
        maximum.reverb.return_gain_q1_15 != 0x7fff) {
      throw std::runtime_error("reverb-max preset did not isolate maximum wet level");
    }
    auto reverb_only = render::make_global_effects_preset("studio", 48000);
    render::apply_global_effect_enable_overrides(reverb_only, "off", "on");
    if (reverb_only.chorus.enable || !reverb_only.reverb.enable) {
      throw std::runtime_error("explicit effect enable overrides were not applied");
    }
    bool invalid_enable_rejected = false;
    try {
      auto chorus_only = render::make_global_effects_preset("chorus", 48000);
      render::apply_global_effect_enable_overrides(chorus_only, "on", "on");
    } catch (const std::invalid_argument&) {
      invalid_enable_rejected = true;
    }
    if (!invalid_enable_rejected) {
      throw std::runtime_error("missing preset parameters were explicitly enabled");
    }
    std::cout << "PASS: C++ global effects command and preset model\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "global_effects_model_test failed: " << e.what() << "\n";
    return 1;
  }
}
