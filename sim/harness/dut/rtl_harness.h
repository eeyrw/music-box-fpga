#pragma once

#include "memory_profile.h"
#include "register_control.h"
#include "wav_writer.h"

#include <cstdint>
#include <string>
#include <vector>

class Vwavetable_cached_render_core;

namespace render {

struct MemoryStats {
  std::string profile;
  uint64_t responses = 0;
  uint64_t external_line_requests = 0;
  uint64_t sequential_line_requests = 0;
  uint64_t response_latency_sum = 0;
  uint16_t response_latency_max = 0;
  uint64_t cache_demand_hits = 0;
  uint64_t cache_demand_misses = 0;
  uint64_t cache_line_fills = 0;
  uint64_t cache_same_line_endpoint_hits = 0;
  uint64_t cache_replacements = 0;
  uint64_t prefetch_issued = 0;
  uint64_t prefetch_filled = 0;
  uint64_t prefetch_used = 0;
  uint64_t prefetch_dropped = 0;
  uint64_t prefetch_late = 0;
  uint64_t render_frames = 0;
  uint32_t last_render_cycles = 0;
  uint64_t render_cycle_sum = 0;
  uint32_t max_render_cycles = 0;
  uint64_t deadline_misses = 0;
  uint64_t over_budget_frames = 0;
  uint32_t max_over_budget_cycles = 0;
  uint64_t endpoint_cross_line_pairs = 0;
  uint64_t endpoint_fetch_slot_pressure_cycles = 0;
  uint64_t endpoint_memory_stall_cycles = 0;
  uint8_t endpoint_fetch_slot_max_occupancy = 0;
  uint8_t endpoint_word_req_max_occupancy = 0;
  uint8_t endpoint_rsp_meta_max_occupancy = 0;
  uint8_t dsp_context_queue_max_occupancy = 0;
  uint64_t dsp_ready_no_context_cycles = 0;
  int line_words = 0;
  int random_latency_cycles = 0;
  int sequential_latency_cycles = 0;
  int ready_gap_cycles = 0;
  RegisterWriteStats register_writes;
};

// Thin Verilator-side driver for wavetable_cached_render_core. It owns the top
// module, models the external line-memory slave, writes the generated stereo PCM
// stream as a WAV file, and exposes firmware-like helpers for voice register
// writes.
class RtlHarness : public VoiceControlSink, private RegisterWriteSink {
 public:
  RtlHarness(const std::vector<int16_t>& memory, const std::string& wav_path,
             int sample_rate, const MemoryProfile& memory_profile);
  ~RtlHarness();

  void reset();
  void set_envelope(int voice, int level) override;
  void set_gain(int voice, int gain_l, int gain_r) override;
  void set_phase_inc(int voice, uint32_t phase_inc) override;
  void set_filter(int voice, const FilterConfig& filter) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override;
  void release_voice(int voice, const Region& region) override;
  void request_sample(int produced);

  int nonzero_output_words() const { return int(wav_.nonzero_words()); }
  MemoryStats memory_stats() const;
  void print_memory_stats() const;

 private:
  static constexpr int kLineWords = 32;

  void write_register(uint16_t address, uint32_t data) override;
  void tick();
  void service_external_memory();

  Vwavetable_cached_render_core* top_ = nullptr;
  RegisterVoiceControl voice_control_;
  // Shared wave-memory image. For SF2-backed renders this is the complete file
  // image, with regions pointing at absolute sample words inside smpl.
  const std::vector<int16_t>& memory_;
  MemoryProfile memory_profile_;
  WavWriter wav_;
  int sample_rate_ = 48000;
  bool line_pending_ = false;
  uint32_t line_pending_addr_ = 0;
  int line_countdown_ = 0;
  int ready_gap_countdown_ = 0;
  bool have_last_line_addr_ = false;
  uint32_t last_line_addr_ = 0;
  uint64_t memory_responses_ = 0;
  uint64_t external_line_requests_ = 0;
  uint64_t sequential_line_requests_ = 0;
  uint64_t response_latency_sum_ = 0;
  uint16_t response_latency_max_ = 0;
  uint64_t cache_demand_hits_ = 0;
  uint64_t cache_demand_misses_ = 0;
  uint64_t cache_line_fills_ = 0;
  uint64_t cache_same_line_endpoint_hits_ = 0;
  uint64_t cache_replacements_ = 0;
  uint64_t prefetch_issued_ = 0;
  uint64_t prefetch_filled_ = 0;
  uint64_t prefetch_used_ = 0;
  uint64_t prefetch_dropped_ = 0;
  uint64_t prefetch_late_ = 0;
  uint64_t endpoint_cross_line_pairs_ = 0;
  uint64_t endpoint_fetch_slot_pressure_cycles_ = 0;
  uint64_t endpoint_memory_stall_cycles_ = 0;
  uint64_t dsp_ready_no_context_cycles_ = 0;
  RegisterWriteStats register_write_stats_;
};

}  // namespace render
