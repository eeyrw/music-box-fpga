#pragma once

#include "render_types.h"

#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

class Vwavetable_core;
class Vwavetable_core_memory;

namespace render {

struct MemoryStats {
  std::string profile;
  uint64_t hits = 0;
  uint64_t misses = 0;
  uint64_t responses = 0;
  uint64_t external_line_requests = 0;
  uint64_t sequential_line_requests = 0;
  uint64_t response_latency_sum = 0;
  uint16_t response_latency_max = 0;
  int line_words = 0;
  int random_latency_cycles = 0;
  int sequential_latency_cycles = 0;
  int ready_gap_cycles = 0;
};

struct MemoryProfile {
  std::string name;
  int random_latency_cycles = 0;
  int sequential_latency_cycles = 0;
  int ready_gap_cycles = 0;
};

MemoryProfile parse_memory_profile(const std::string& name);

// Thin Verilator-side driver for wavetable_core. It owns the top module, models
// the external wave-memory slave, writes the generated stereo PCM stream as a
// WAV file, and exposes firmware-like helpers for voice register writes.
class RtlHarness : public VoiceControlSink {
 public:
  RtlHarness(const std::vector<int16_t>& memory, const std::string& wav_path,
             int sample_rate, const MemoryProfile& memory_profile);
  ~RtlHarness();

  void reset();
  void set_envelope(int voice, int level) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override;
  void release_voice(int voice, const Region& region) override;
  void request_sample(int produced);

  int nonzero_output_words() const { return nonzero_output_words_; }
  MemoryStats memory_stats() const;
  void print_memory_stats() const;

 private:
  static constexpr int kLineWords = 8;

  void bus_write_word(uint16_t address, uint32_t data);
  void tick();
  void service_external_memory();
  void write_wav_header(uint32_t data_bytes);
  void write_pcm16(int16_t sample);

  Vwavetable_core_memory* top_ = nullptr;
  // Shared wave-memory image. Mono regions are stored one int16_t per frame;
  // stereo regions are interleaved left/right exactly as the RTL expects.
  const std::vector<int16_t>& memory_;
  MemoryProfile memory_profile_;
  std::ofstream wav_;
  int sample_rate_ = 48000;
  bool line_pending_ = false;
  uint32_t line_pending_addr_ = 0;
  int line_countdown_ = 0;
  int ready_gap_countdown_ = 0;
  bool have_last_line_addr_ = false;
  uint32_t last_line_addr_ = 0;
  uint32_t data_bytes_ = 0;
  int nonzero_output_words_ = 0;
  uint64_t memory_hits_ = 0;
  uint64_t memory_misses_ = 0;
  uint64_t memory_responses_ = 0;
  uint64_t external_line_requests_ = 0;
  uint64_t sequential_line_requests_ = 0;
  uint64_t response_latency_sum_ = 0;
  uint16_t response_latency_max_ = 0;
};

}  // namespace render
