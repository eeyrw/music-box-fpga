#include "voice_compute_pipeline_model.h"

#include <algorithm>
#include <limits>
#include <stdexcept>
#include <vector>

namespace render {
namespace {

struct WorkEntry {
  bool occupied = false;
  uint32_t issued_frames = 0;
  uint64_t ready_cycle = 0;
  uint64_t next_issue_cycle = 0;
  uint64_t retire_cycle = 0;
};

}  // namespace

VoiceComputePipelineResult simulate_voice_compute_pipeline(
    const VoiceComputePipelineConfig& config) {
  if (config.voice_count == 0 || config.frames_per_voice == 0 ||
      config.frontend_cycles_per_voice == 0 ||
      config.filter_recurrence_cycles == 0 ||
      config.dsp_pipeline_cycles == 0 || config.work_entries == 0) {
    throw std::invalid_argument("voice compute pipeline parameters must be nonzero");
  }

  std::vector<WorkEntry> entries(config.work_entries);
  VoiceComputePipelineResult result;
  uint32_t prepared_voices = 0;
  uint32_t retired_voices = 0;
  uint32_t round_robin_start = 0;
  uint64_t next_frontend_completion = config.frontend_cycles_per_voice;

  const uint64_t cycle_limit =
      uint64_t(config.voice_count) * config.frames_per_voice *
      (config.frontend_cycles_per_voice + config.filter_recurrence_cycles +
       config.dsp_pipeline_cycles + config.work_entries);

  for (uint64_t cycle = 0; retired_voices != config.voice_count; ++cycle) {
    if (cycle > cycle_limit) {
      throw std::runtime_error("voice compute pipeline model did not converge");
    }

    for (auto& entry : entries) {
      if (entry.occupied && entry.issued_frames == config.frames_per_voice &&
          cycle >= entry.retire_cycle) {
        entry = {};
        ++retired_voices;
      }
    }

    if (prepared_voices < config.voice_count &&
        cycle >= next_frontend_completion) {
      auto free_entry = std::find_if(entries.begin(), entries.end(),
                                    [](const WorkEntry& entry) {
                                      return !entry.occupied;
                                    });
      if (free_entry != entries.end()) {
        free_entry->occupied = true;
        free_entry->ready_cycle = cycle + 1;
        free_entry->next_issue_cycle = cycle + 1;
        ++prepared_voices;
        next_frontend_completion =
            cycle + config.frontend_cycles_per_voice;
      } else {
        ++result.frontend_stall_cycles;
      }
    }

    uint32_t occupied_entries = 0;
    for (const auto& entry : entries)
      occupied_entries += entry.occupied ? 1u : 0u;
    result.max_occupied_entries =
        std::max(result.max_occupied_entries, occupied_entries);

    bool issued = false;
    for (uint32_t offset = 0; offset < config.work_entries; ++offset) {
      const uint32_t index =
          (round_robin_start + offset) % config.work_entries;
      auto& entry = entries[index];
      if (!entry.occupied || entry.issued_frames == config.frames_per_voice ||
          cycle < entry.ready_cycle || cycle < entry.next_issue_cycle) {
        continue;
      }

      ++entry.issued_frames;
      ++result.issued_samples;
      entry.next_issue_cycle = cycle + config.filter_recurrence_cycles;
      if (entry.issued_frames == config.frames_per_voice) {
        entry.retire_cycle = cycle + config.dsp_pipeline_cycles;
      }
      round_robin_start = (index + 1) % config.work_entries;
      issued = true;
      break;
    }
    if (!issued) ++result.dsp_idle_cycles;
    result.total_cycles = cycle + 1;
  }

  return result;
}

}  // namespace render
