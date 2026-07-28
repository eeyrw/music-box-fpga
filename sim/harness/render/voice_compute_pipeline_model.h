#pragma once

#include <cstdint>

namespace render {

struct VoiceComputePipelineConfig {
  uint32_t voice_count = 256;
  uint32_t frames_per_voice = 8;
  uint32_t frontend_cycles_per_voice = 28;
  uint32_t filter_recurrence_cycles = 6;
  uint32_t dsp_pipeline_cycles = 8;
  uint32_t work_entries = 2;
};

struct VoiceComputePipelineResult {
  uint64_t total_cycles = 0;
  uint64_t issued_samples = 0;
  uint64_t frontend_stall_cycles = 0;
  uint64_t dsp_idle_cycles = 0;
  uint32_t max_occupied_entries = 0;
};

VoiceComputePipelineResult simulate_voice_compute_pipeline(
    const VoiceComputePipelineConfig& config);

}  // namespace render
