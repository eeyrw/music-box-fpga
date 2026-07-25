#include "effect_return_mixer_model.h"

#include <iostream>
#include <stdexcept>

namespace render {
namespace {

void expect(EffectReturnMixerModel::StereoFrame actual, int32_t left,
            int32_t right, const char* message) {
  if (actual.first != left || actual.second != right) {
    throw std::runtime_error(message);
  }
}

void test_routing_and_returns() {
  EffectReturnMixerModel mixer;
  ChorusConfig chorus;
  ReverbConfig reverb;
  reverb.input_send_q1_15 = 0x7fff;
  reverb.chorus_to_reverb_q1_15 = 0x4000;
  expect(mixer.route_reverb({100, -100}, {-40, 40}, reverb), 80, -80,
         "effect reverb route mismatch");

  chorus.return_gain_q1_15 = 0x4000;
  reverb.return_gain_q1_15 = 0x4000;
  expect(mixer.mix({100, -100}, {-40, 40}, {10, -10}, chorus, reverb),
         85, -85, "effect return mix mismatch");
  expect(mixer.mix({-1, 1}, {-1, 1}, {-1, 1}, chorus, reverb),
         -3, 1, "effect negative rounding mismatch");
}

void test_bypass_saturation_and_clear() {
  EffectReturnMixerModel mixer;
  ChorusConfig chorus;
  ReverbConfig reverb;
  chorus.return_gain_q1_15 = 0x7fff;
  reverb.input_send_q1_15 = 0x7fff;
  reverb.chorus_to_reverb_q1_15 = 0x7fff;
  reverb.return_gain_q1_15 = 0x7fff;
  expect(mixer.route_reverb({0x7fffff, -0x800000},
                            {0x7fffff, -0x800000}, reverb),
         0x7fffff, -0x800000, "effect route saturation mismatch");
  expect(mixer.mix({0x7fffff, -0x800000}, {0x7fffff, -0x800000},
                   {0x7fffff, -0x800000}, chorus, reverb),
         0x7fffff, -0x800000, "effect mix saturation mismatch");
  if (mixer.saturation_count() != 4) {
    throw std::runtime_error("effect saturation count mismatch");
  }
  reverb.input_send_q1_15 = 0xffff;
  expect(mixer.route_reverb({111, -222}, {0, 0}, reverb), 111, -222,
         "effect gain clamp mismatch");
  if (!mixer.config_clamped()) {
    throw std::runtime_error("effect invalid gain not reported");
  }
  mixer.clear();
  if (mixer.saturation_count() != 0 || mixer.config_clamped()) {
    throw std::runtime_error("effect mixer clear mismatch");
  }
}

}  // namespace
}  // namespace render

int main() {
  try {
    render::test_routing_and_returns();
    render::test_bypass_saturation_and_clear();
    std::cout << "PASS: C++ effect return mixer model\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << "\n";
    return 1;
  }
}
