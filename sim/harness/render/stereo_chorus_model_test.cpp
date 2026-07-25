#include "stereo_chorus_model.h"

#include <iostream>
#include <stdexcept>

namespace render {
namespace {

void expect(std::pair<int32_t, int32_t> actual, int32_t left, int32_t right,
            const char* message) {
  if (actual.first != left || actual.second != right) {
    throw std::runtime_error(message);
  }
}

void test_delay_and_warmup() {
  StereoChorusModel model(8);
  ChorusConfig config;
  config.enable = true;
  config.base_delay_q16_8 = 2u << 8;
  config.stereo_phase_offset_q0_32 = 0;
  model.set_config(config);
  expect(model.process_frame(100, -100), 0, 0, "warm-up frame 0 mismatch");
  expect(model.process_frame(200, -200), 0, 0, "warm-up frame 1 mismatch");
  expect(model.process_frame(300, -300), 100, -100, "integer delay mismatch");
  expect(model.process_frame(400, -400), 200, -200, "delay advance mismatch");
}

void test_fraction_feedback_and_clear() {
  StereoChorusModel model(8);
  ChorusConfig config;
  config.enable = true;
  config.base_delay_q16_8 = (1u << 8) + 128u;
  config.feedback_q1_15 = 0x4000;
  config.stereo_phase_offset_q0_32 = 0;
  model.set_config(config);
  expect(model.process_frame(1000, -1000), 0, 0, "fraction warm-up mismatch");
  expect(model.process_frame(2000, -2000), 500, -500, "fractional zero interpolation mismatch");
  expect(model.process_frame(0, 0), 1625, -1625, "fractional feedback mismatch");
  model.clear();
  expect(model.process_frame(0, 0), 0, 0, "clear did not invalidate history");
}

void test_disable_modulation_wrap_and_clamp() {
  StereoChorusModel model(8);
  ChorusConfig config;
  config.enable = false;
  config.base_delay_q16_8 = 3u << 8;
  config.depth_q16_8 = 1u << 8;
  config.lfo_phase_inc_q0_32 = 0x40000000u;
  config.stereo_phase_offset_q0_32 = 0x40000000u;
  model.set_config(config);
  for (int index = 0; index < 5; ++index) {
    expect(model.process_frame(100 + index, 200 + index), 0, 0,
           "disabled chorus emitted wet data");
  }
  if (model.lfo_phase() != 0x40000000u || model.history_level() != 5) {
    throw std::runtime_error("disabled chorus did not advance state");
  }
  config.enable = true;
  config.base_delay_q16_8 = 0;
  config.depth_q16_8 = 0xffffffu;
  config.feedback_q1_15 = 0x7fff;
  config.input_send_q1_15 = 0xffff;
  model.set_config(config);
  model.process_frame(0, 0);
  if (!model.config_clamped()) throw std::runtime_error("invalid config was not reported");
}

void test_stereo_phase_pointer_wrap_and_saturation() {
  StereoChorusModel model(8);
  ChorusConfig config;
  config.enable = true;
  config.base_delay_q16_8 = 3u << 8;
  config.depth_q16_8 = 1u << 8;
  config.stereo_phase_offset_q0_32 = 0x40000000u;
  model.set_config(config);
  for (int index = 0; index < 4; ++index) {
    model.process_frame(10 + 10 * index, 100 + 10 * index);
  }
  expect(model.process_frame(50, 140), 20, 100, "stereo phase offset mismatch");

  model.clear();
  config.depth_q16_8 = 0;
  config.base_delay_q16_8 = 1u << 8;
  config.stereo_phase_offset_q0_32 = 0;
  model.set_config(config);
  expect(model.process_frame(0, 0), 0, 0, "pointer wrap warm-up mismatch");
  for (int index = 1; index <= 12; ++index) {
    expect(model.process_frame(index, -index), index - 1, -(index - 1),
           "pointer wrap output mismatch");
  }

  model.clear();
  config.feedback_q1_15 = 0x6000;
  model.set_config(config);
  expect(model.process_frame(8388607, -8388608), 0, 0,
         "saturation warm-up mismatch");
  expect(model.process_frame(8388607, -8388608), 8388607, -8388608,
         "saturation tap mismatch");
  if (model.saturation_count() != 2) {
    throw std::runtime_error("chorus saturation count mismatch");
  }
}

}  // namespace
}  // namespace render

int main() {
  try {
    render::test_delay_and_warmup();
    render::test_fraction_feedback_and_clear();
    render::test_disable_modulation_wrap_and_clamp();
    render::test_stereo_phase_pointer_wrap_and_saturation();
    std::cout << "PASS: C++ stereo chorus model\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << "\n";
    return 1;
  }
}
