#pragma once

#include <cstdint>
#include <fstream>
#include <string>

namespace render {

class WavWriter {
 public:
  WavWriter(const std::string& path, int sample_rate);
  ~WavWriter();

  WavWriter(const WavWriter&) = delete;
  WavWriter& operator=(const WavWriter&) = delete;

  void write_stereo(int16_t left, int16_t right);
  void write_pcm16(int16_t sample);
  uint32_t data_bytes() const { return data_bytes_; }
  uint64_t nonzero_words() const { return nonzero_words_; }

 private:
  void write_header(uint32_t data_bytes);

  std::ofstream f_;
  int sample_rate_ = 48000;
  uint32_t data_bytes_ = 0;
  uint64_t nonzero_words_ = 0;
};

}  // namespace render
