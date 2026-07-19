#include "wav_writer.h"

#include <stdexcept>

namespace render {
namespace {

void put_u16le(std::ofstream& f, uint16_t value) {
  char b[2] = {char(value & 0xff), char((value >> 8) & 0xff)};
  f.write(b, 2);
}

void put_u32le(std::ofstream& f, uint32_t value) {
  char b[4] = {char(value & 0xff), char((value >> 8) & 0xff),
               char((value >> 16) & 0xff), char((value >> 24) & 0xff)};
  f.write(b, 4);
}

}  // namespace

WavWriter::WavWriter(const std::string& path, int sample_rate)
    : f_(path, std::ios::binary), sample_rate_(sample_rate) {
  if (!f_) throw std::runtime_error("failed to open " + path);
  write_header(0);
}

WavWriter::~WavWriter() {
  if (f_) {
    f_.seekp(0);
    write_header(data_bytes_);
  }
}

void WavWriter::write_stereo(int16_t left, int16_t right) {
  write_pcm16(left);
  write_pcm16(right);
}

void WavWriter::write_pcm16(int16_t sample) {
  if (sample != 0) ++nonzero_words_;
  put_u16le(f_, uint16_t(sample));
  data_bytes_ += 2;
}

void WavWriter::write_header(uint32_t data_bytes) {
  f_.write("RIFF", 4);
  put_u32le(f_, 36 + data_bytes);
  f_.write("WAVEfmt ", 8);
  put_u32le(f_, 16);
  put_u16le(f_, 1);
  put_u16le(f_, 2);
  put_u32le(f_, uint32_t(sample_rate_));
  put_u32le(f_, uint32_t(sample_rate_ * 2 * 2));
  put_u16le(f_, 4);
  put_u16le(f_, 16);
  f_.write("data", 4);
  put_u32le(f_, data_bytes);
}

}  // namespace render
