#pragma once

#include "register_control.h"
#include "wav_writer.h"

#include <cstdint>
#include <string>
#include <vector>

class Vwavetable_demo_system;

namespace render {

struct FullSystemStats {
  uint64_t frames = 0;
  uint64_t nonzero_output_words = 0;
  uint64_t underruns = 0;
  uint64_t sample_drops = 0;
  uint64_t render_deadline_misses = 0;
  uint64_t max_render_latency_cycles = 0;
  uint64_t memory_responses = 0;
  uint64_t external_line_requests = 0;
  uint64_t sequential_line_requests = 0;
  RegisterWriteStats register_writes;
};

class FullSystemHarness : public VoiceControlSink, private RegisterWriteSink {
 public:
  FullSystemHarness(const std::vector<int16_t>& memory, const std::string& wav_path,
                    int sample_rate);
  ~FullSystemHarness();

  void reset();
  void run_until_frames(uint64_t target_frames);
  uint64_t frames() const { return frames_; }
  FullSystemStats stats() const;

  void set_envelope(int voice, int level) override;
  void set_gain(int voice, int gain_l, int gain_r) override;
  void set_phase_inc(int voice, uint32_t phase_inc) override;
  void set_filter(int voice, const FilterConfig& filter) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override;
  void release_voice(int voice, const Region& region) override;

 private:
  static constexpr int kLineWords = 8;
  static constexpr int kRandomLatencyCycles = 10;
  static constexpr int kSequentialLatencyCycles = 4;

  void write_register(uint16_t address, uint32_t data) override;
  void spi_send_byte(uint8_t value);
  void spi_clock_bit(bool bit_value);
  void run_cycles(int cycles);
  void tick();
  void service_external_memory();
  void observe_i2s();
  void decoded_frame(int16_t left, int16_t right);

  Vwavetable_demo_system* top_ = nullptr;
  RegisterVoiceControl voice_control_;
  const std::vector<int16_t>& memory_;
  WavWriter wav_;
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
  uint64_t frames_ = 0;
  uint64_t underruns_ = 0;
  uint64_t sample_drops_ = 0;
  uint64_t render_deadline_misses_ = 0;
  uint64_t max_render_latency_cycles_ = 0;
  uint64_t memory_responses_ = 0;
  uint64_t external_line_requests_ = 0;
  uint64_t sequential_line_requests_ = 0;
  RegisterWriteStats register_write_stats_;
};

}  // namespace render
