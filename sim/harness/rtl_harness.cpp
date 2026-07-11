#include "rtl_harness.h"

#include "Vwavetable_core.h"

#include <cstdio>
#include <stdexcept>

namespace render {
namespace {

std::string hex16(uint16_t v) {
  char b[8];
  std::snprintf(b, sizeof(b), "%04x", v);
  return b;
}

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

RtlHarness::RtlHarness(const std::vector<int16_t>& memory, const std::string& wav_path, int sample_rate)
    : top_(new Vwavetable_core), memory_(memory), wav_(wav_path, std::ios::binary), sample_rate_(sample_rate) {
  if (!wav_) throw std::runtime_error("failed to open " + wav_path);
  write_wav_header(0);

  top_->clk = 0;
  top_->rst = 1;
  top_->bus_valid = 0;
  top_->bus_write = 0;
  top_->bus_address = 0;
  top_->bus_wdata = 0;
  top_->sample_tick = 0;
  top_->mem_req_ready = 1;
  top_->mem_rsp_valid = 0;
  top_->mem_rsp_data = 0;
}

RtlHarness::~RtlHarness() {
  if (wav_) {
    wav_.seekp(0);
    write_wav_header(data_bytes_);
    wav_.close();
  }
  delete top_;
}

void RtlHarness::reset() {
  for (int i = 0; i < 3; ++i) tick();
  top_->rst = 0;
  tick();
}

void RtlHarness::bus_write_word(uint16_t address, uint32_t data) {
  top_->bus_valid = 1;
  top_->bus_write = 1;
  top_->bus_address = address;
  top_->bus_wdata = data;
  tick();
  if (!top_->bus_ready || top_->bus_error) {
    throw std::runtime_error("bus write failed at address 0x" + hex16(address));
  }
  top_->bus_valid = 0;
  top_->bus_write = 0;
  tick();
}

void RtlHarness::set_envelope(int voice, int level) {
  bus_write_word(voice_addr(voice, 0x2c), uint32_t(uint16_t(clamp_q15(level))));
}

void RtlHarness::commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) {
  bus_write_word(voice_addr(voice, 0x00), uint32_t((r.stereo ? 2 : 0) | (enable ? 1 : 0)));
  bus_write_word(voice_addr(voice, 0x04), r.base_addr);
  bus_write_word(voice_addr(voice, 0x08), r.length);
  bus_write_word(voice_addr(voice, 0x0c), r.loop_start);
  bus_write_word(voice_addr(voice, 0x10), r.loop_end);
  bus_write_word(voice_addr(voice, 0x14), 0);
  bus_write_word(voice_addr(voice, 0x18), phase_inc);
  bus_write_word(voice_addr(voice, 0x1c), uint32_t(uint16_t(r.gain_l)));
  bus_write_word(voice_addr(voice, 0x20), uint32_t(uint16_t(r.gain_r)));
  bus_write_word(voice_addr(voice, 0x34), uint32_t(r.loop_mode & 0x3));
  bus_write_word(voice_addr(voice, 0x24), 1);
}

void RtlHarness::release_voice(int voice, const Region& r) {
  bus_write_word(voice_addr(voice, 0x34), uint32_t(0x100 | (r.loop_mode & 0x3)));
}

void RtlHarness::request_sample(int produced) {
  top_->sample_tick = 1;
  tick();
  top_->sample_tick = 0;

  int timeout = 0;
  while (!top_->sample_valid && timeout < 600) {
    tick();
    ++timeout;
  }
  if (!top_->sample_valid) {
    throw std::runtime_error("sample response timed out at output sample " + std::to_string(produced));
  }
  write_pcm16(int16_t(top_->sample_l));
  write_pcm16(int16_t(top_->sample_r));
}

void RtlHarness::tick() {
  top_->clk = 0;
  top_->mem_req_ready = 1;
  top_->eval();

  // The behavioral memory is a one-cycle ready/valid slave. Capture the request
  // before the rising edge, then present its response on the next simulated tick.
  bool next_pending_valid = top_->mem_req_valid;
  uint16_t next_pending_data = 0;
  if (top_->mem_req_valid && top_->mem_req_addr < memory_.size()) {
    next_pending_data = uint16_t(memory_[top_->mem_req_addr]);
  }
  top_->mem_rsp_valid = pending_valid_ ? 1 : 0;
  top_->mem_rsp_data = pending_data_;

  top_->clk = 1;
  top_->eval();
  pending_valid_ = next_pending_valid;
  pending_data_ = next_pending_data;
  top_->clk = 0;
  top_->eval();
}

void RtlHarness::write_wav_header(uint32_t data_bytes) {
  wav_.write("RIFF", 4);
  put_u32le(wav_, 36 + data_bytes);
  wav_.write("WAVEfmt ", 8);
  put_u32le(wav_, 16);
  put_u16le(wav_, 1);
  put_u16le(wav_, 2);
  put_u32le(wav_, uint32_t(sample_rate_));
  put_u32le(wav_, uint32_t(sample_rate_ * 2 * 2));
  put_u16le(wav_, 4);
  put_u16le(wav_, 16);
  wav_.write("data", 4);
  put_u32le(wav_, data_bytes);
}

void RtlHarness::write_pcm16(int16_t sample) {
  if (sample != 0) ++nonzero_output_words_;
  put_u16le(wav_, uint16_t(sample));
  data_bytes_ += 2;
}

}  // namespace render
