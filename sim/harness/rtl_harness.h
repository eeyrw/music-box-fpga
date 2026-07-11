#pragma once

#include "render_types.h"

#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

class Vwavetable_core;

namespace render {

// Thin Verilator-side driver for wavetable_core. It owns the top module, models
// the external wave-memory slave, writes the generated stereo PCM stream as a
// WAV file, and exposes firmware-like helpers for voice register writes.
class RtlHarness {
 public:
  RtlHarness(const std::vector<int16_t>& memory, const std::string& wav_path, int sample_rate);
  ~RtlHarness();

  void reset();
  void set_envelope(int voice, int level);
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region);
  void release_voice(int voice, const Region& region);
  void request_sample(int produced);

  int nonzero_output_words() const { return nonzero_output_words_; }

 private:
  void bus_write_word(uint16_t address, uint32_t data);
  void tick();
  void write_wav_header(uint32_t data_bytes);
  void write_pcm16(int16_t sample);

  Vwavetable_core* top_ = nullptr;
  // Shared wave-memory image. Mono regions are stored one int16_t per frame;
  // stereo regions are interleaved left/right exactly as the RTL expects.
  const std::vector<int16_t>& memory_;
  std::ofstream wav_;
  int sample_rate_ = 48000;
  // Latched response for the one-cycle memory model implemented in tick().
  bool pending_valid_ = false;
  uint16_t pending_data_ = 0;
  uint32_t data_bytes_ = 0;
  int nonzero_output_words_ = 0;
};

}  // namespace render
