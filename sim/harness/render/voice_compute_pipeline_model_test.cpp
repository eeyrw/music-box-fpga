#include "voice_compute_pipeline_model.h"

#include <array>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void expect(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

}  // namespace

int main() {
  try {
    constexpr uint64_t kExpectedSamples = 256 * 8;
    constexpr uint64_t kBlockDeadline = 16666;
    constexpr std::array<uint32_t, 4> kEntryCounts{1, 2, 4, 8};

    uint64_t previous_cycles = UINT64_MAX;
    for (const uint32_t entries : kEntryCounts) {
      render::VoiceComputePipelineConfig config;
      config.work_entries = entries;
      const auto result = render::simulate_voice_compute_pipeline(config);

      expect(result.issued_samples == kExpectedSamples,
             "model did not issue every voice sample");
      expect(result.total_cycles <= previous_cycles,
             "adding work entries made the schedule slower");
      expect(result.max_occupied_entries <= entries,
             "model exceeded configured work-entry capacity");
      if (entries == 1) {
        expect(result.total_cycles < kBlockDeadline,
               "one-slot projected compute schedule missed the block deadline");
      }

      std::cout << "VOICE_COMPUTE_MODEL entries=" << entries
                << " cycles=" << result.total_cycles
                << " frontend_stall=" << result.frontend_stall_cycles
                << " dsp_idle=" << result.dsp_idle_cycles
                << " max_occupied=" << result.max_occupied_entries << '\n';
      previous_cycles = result.total_cycles;
    }

    render::VoiceComputePipelineConfig conservative;
    conservative.frontend_cycles_per_voice = 60;
    conservative.work_entries = 8;
    const auto conservative_result =
        render::simulate_voice_compute_pipeline(conservative);
    expect(conservative_result.total_cycles < kBlockDeadline,
           "conservative two-slot compute projection missed the deadline");
    std::cout << "VOICE_COMPUTE_MODEL entries=8 frontend=60 cycles="
              << conservative_result.total_cycles << '\n';
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }

  std::cout << "PASS: voice compute pipeline scheduling model\n";
  return 0;
}
