#include "lookahead_compressor_model.h"

#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <utility>

namespace render {
namespace {

constexpr uint32_t kOctaveCbQ12_20 = 63130566u;

void expect_no_output(LookaheadCompressorModel& model, int32_t left, int32_t right) {
  if (model.process_frame(left, right).has_value()) {
    throw std::runtime_error("look-ahead delay produced output while priming");
  }
}

void expect_output(LookaheadCompressorModel& model, int32_t left, int32_t right,
                   int expected_l, int expected_r) {
  auto output = model.process_frame(left, right);
  if (!output || output->first != expected_l || output->second != expected_r) {
    throw std::runtime_error("look-ahead compressor output mismatch");
  }
}

void prime(LookaheadCompressorModel& model, int32_t first_l, int32_t first_r) {
  expect_no_output(model, first_l, first_r);
  expect_no_output(model, 0, 0);
  expect_no_output(model, 0, 0);
  expect_no_output(model, 0, 0);
  if (!model.primed()) throw std::runtime_error("look-ahead model did not prime");
}

void test_bypass_and_master() {
  LookaheadCompressorModel model(4);
  expect_no_output(model, 1000, -1000);
  expect_no_output(model, 2000, -2000);
  expect_no_output(model, 3000, -3000);
  expect_no_output(model, 4000, -4000);
  expect_output(model, 5000, -5000, 1000, -1000);
  expect_output(model, 6000, -6000, 2000, -2000);

  model.reset();
  CommandAudioControl audio(model);
  audio.set_master_volume(0x4000);
  prime(model, 10000, -10000);
  expect_output(model, 0, 0, 5000, -5000);
}

void test_compression_and_release() {
  RenderDiagnostics diagnostics;
  LookaheadCompressorModel model(4, &diagnostics);
  CommandAudioControl audio(model);
  CompressorCommandConfig config;
  config.enable = true;
  config.ratio_slope_q0_16 = 0x8000;
  config.release_step_cb_q12_20 = kOctaveCbQ12_20 >> 1;
  audio.configure_compressor(config);

  prime(model, 10000, -10000);
  expect_output(model, 0, -131072, 5000, -5000);
  if (model.gain_reduction_cb_q12_20() != kOctaveCbQ12_20) {
    throw std::runtime_error("compressor attack/ratio mismatch");
  }
  if (!diagnostics.compressor_enabled || !diagnostics.compressor_primed ||
      !diagnostics.compressor_active || diagnostics.compressor_delay_level != 4 ||
      diagnostics.compressor_target_gain_reduction_cb_q12_20 != kOctaveCbQ12_20 ||
      diagnostics.compressor_detector_peak != 131072 ||
      diagnostics.compressor_max_detector_peak != 131072 ||
      diagnostics.compressor_max_gain_reduction_cb_q12_20 != kOctaveCbQ12_20 ||
      diagnostics.compressor_input_frame_count != 5 ||
      diagnostics.compressor_output_frame_count != 1 ||
      diagnostics.compressor_compressed_frame_count != 1 ||
      diagnostics.compressor_saturation_count != 0) {
    throw std::runtime_error("compressor diagnostics mismatch");
  }
  expect_output(model, 0, 0, 0, 0);
  if (model.gain_reduction_cb_q12_20() !=
      kOctaveCbQ12_20 - (kOctaveCbQ12_20 >> 1)) {
    throw std::runtime_error("compressor release mismatch");
  }
}

void test_final_saturation() {
  LookaheadCompressorModel model(4);
  prime(model, 100000, -100000);
  expect_output(model, 0, 0, 32767, -32768);
  if (model.output_frame_count() != 1 || model.saturation_count() != 2) {
    throw std::runtime_error("compressor saturation diagnostics mismatch");
  }
}

}  // namespace
}  // namespace render

int main() {
  try {
    render::test_bypass_and_master();
    render::test_compression_and_release();
    render::test_final_saturation();
    std::cout << "PASS: C++ look-ahead compressor model\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << "\n";
    return 1;
  }
}
