#include "fdn_reverb_model.h"

#include "generated/dsp_lut.h"

#include <iostream>
#include <stdexcept>
#include <vector>

namespace render {
namespace {

void expect(std::pair<int32_t, int32_t> actual, int32_t left, int32_t right,
            const char* message) {
  if (actual.first != left || actual.second != right) {
    throw std::runtime_error(message);
  }
}

void test_impulse_signs_and_warmup() {
  FdnReverbModel model({1, 2, 3, 4, 5, 6, 7, 8}, 8);
  ReverbConfig config;
  config.enable = true;
  model.set_config(config);
  expect(model.process_frame(8000, 0), 0, 0, "FDN impulse input mismatch");
  const int signs_l[8] = {1, 1, -1, -1, 1, 1, -1, -1};
  const int signs_r[8] = {1, -1, -1, 1, 1, -1, -1, 1};
  for (int line = 0; line < 8; ++line) {
    expect(model.process_frame(0, 0), 500 * signs_l[line], 500 * signs_r[line],
           "FDN output sign mismatch");
  }
  if (model.valid_line_mask() != 0xffu) {
    throw std::runtime_error("FDN warm-up mask mismatch");
  }
}

void test_predelay_damping_disable_and_clear() {
  FdnReverbModel model({1, 2, 3, 4, 5, 6, 7, 8}, 8);
  ReverbConfig config;
  config.enable = false;
  config.pre_delay_frames = 2;
  config.damping_q1_15 = 0x4000;
  model.set_config(config);
  expect(model.process_frame(8000, 0), 0, 0, "disabled FDN emitted output");
  expect(model.process_frame(0, 0), 0, 0, "disabled pre-delay frame mismatch");
  expect(model.process_frame(0, 0), 0, 0, "disabled injection frame mismatch");
  config.enable = true;
  model.set_config(config);
  expect(model.process_frame(0, 0), 250, 250, "FDN damping/pre-delay mismatch");
  if (model.pre_delay_occupancy() != 4) {
    throw std::runtime_error("FDN pre-delay occupancy mismatch");
  }
  model.clear();
  expect(model.process_frame(0, 0), 0, 0, "FDN clear exposed stale state");
  if (model.valid_line_mask() != 0x01u) {
    throw std::runtime_error("FDN clear/warm-up mask mismatch");
  }
}

void test_hadamard_feedback() {
  FdnReverbModel model({1, 2, 3, 4, 5, 6, 7, 8}, 8);
  ReverbConfig config;
  config.enable = true;
  config.feedback_gain_q1_15[0] = 0x2000;
  model.set_config(config);
  expect(model.process_frame(8000, 0), 0, 0, "FDN feedback impulse mismatch");
  expect(model.process_frame(0, 0), 500, 500, "FDN feedback first tap mismatch");
  expect(model.process_frame(0, 0), 625, -375,
         "FDN Hadamard feedback mismatch");
}

void test_clamp_and_production_delay_set() {
  FdnReverbModel model;
  ReverbConfig config;
  config.enable = true;
  config.damping_q1_15 = 0xffff;
  config.pre_delay_frames = 0xffff;
  config.feedback_gain_q1_15.fill(0xffff);
  model.set_config(config);
  model.process_frame(0, 0);
  if (!model.config_clamped()) throw std::runtime_error("FDN invalid config not clamped");

  model.reset();
  config = {};
  config.enable = true;
  model.set_config(config);
  expect(model.process_frame(8000, 0), 0, 0, "production FDN impulse mismatch");
  for (uint32_t frame = 1; frame < dsp_lut::kFdnDelayLengths[0]; ++frame) {
    expect(model.process_frame(0, 0), 0, 0, "production FDN early reflection");
  }
  expect(model.process_frame(0, 0), 500, 500,
         "production FDN first reflection mismatch");
}

}  // namespace
}  // namespace render

int main() {
  try {
    render::test_impulse_signs_and_warmup();
    render::test_predelay_damping_disable_and_clear();
    render::test_hadamard_feedback();
    render::test_clamp_and_production_delay_set();
    std::cout << "PASS: C++ eight-line FDN reverb model\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << "\n";
    return 1;
  }
}
