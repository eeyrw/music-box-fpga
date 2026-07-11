#pragma once

#include "render_types.h"

#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

class Vwavetable_core_system;

namespace render {

struct FullSystemStats {
  uint64_t frames = 0;
  uint64_t nonzero_output_words = 0;
  uint64_t underruns = 0;
  uint64_t sample_drops = 0;
  uint64_t memory_hits = 0;
  uint64_t memory_misses = 0;
  uint64_t memory_responses = 0;
  uint64_t external_line_requests = 0;
  uint64_t sequential_line_requests = 0;
};

class FullSystemHarness : public VoiceControlSink {
 public:
  FullSystemHarness(const std::vector<int16_t>& memory, const std::string& wav_path,
                    int sample_rate);
  ~FullSystemHarness();

  void reset();
  void run_until_frames(uint64_t target_frames);
  uint64_t frames() const { return frames_; }
  FullSystemStats stats() const;

  void set_envelope(int voice, int level) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override;
  void release_voice(int voice, const Region& region) override;

 private:
  static constexpr int kLineWords = 8;
  static constexpr int kRandomLatencyCycles = 10;
  static constexpr int kSequentialLatencyCycles = 4;

  void spi_write_word(uint16_t address, uint32_t data);
  void spi_send_byte(uint8_t value);
  void spi_clock_bit(bool bit_value);
  void run_cycles(int cycles);
  void tick();
  void service_external_memory();
  void observe_i2s();
  void decoded_frame(int16_t left, int16_t right);
  void write_wav_header(uint32_t data_bytes);
  void write_pcm16(int16_t sample);

  Vwavetable_core_system* top_ = nullptr;
  const std::vector<int16_t>& memory_;
  std::ofstream wav_;
  int sample_rate_ = 48000;
  bool line_pending_ = false;
  uint32_t line_pending_addr_ = 0;
  int line_countdown_ = 0;
  bool have_last_line_addr_ = false;
  uint32_t last_line_addr_ = 0;
  bool bclk_prev_ = false;
  bool rx_lrclk_ = false;
  int rx_bit_count_ = 0;
  uint16_t rx_shift_ = 0;
  int16_t rx_left_ = 0;
  uint32_t data_bytes_ = 0;
  uint64_t frames_ = 0;
  uint64_t nonzero_output_words_ = 0;
  uint64_t underruns_ = 0;
  uint64_t sample_drops_ = 0;
  uint64_t memory_hits_ = 0;
  uint64_t memory_misses_ = 0;
  uint64_t memory_responses_ = 0;
  uint64_t external_line_requests_ = 0;
  uint64_t sequential_line_requests_ = 0;
};

}  // namespace render
