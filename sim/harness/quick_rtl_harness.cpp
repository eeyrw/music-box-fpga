#include "quick_rtl_harness.h"

#include "Vwavetable_core.h"

#include <cstdio>
#include <stdexcept>
#include <string>

namespace render {
namespace {

std::string hex16(uint16_t v) {
  char b[8];
  std::snprintf(b, sizeof(b), "%04x", v);
  return b;
}

}  // namespace

QuickRtlHarness::QuickRtlHarness(const std::vector<int16_t>& memory)
    : top_(new Vwavetable_core), memory_(memory) {
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

QuickRtlHarness::~QuickRtlHarness() {
  delete top_;
}

void QuickRtlHarness::reset() {
  for (int i = 0; i < 3; ++i) tick();
  top_->rst = 0;
  tick();
}

void QuickRtlHarness::set_envelope(int voice, int level) {
  bus_write_word(voice_addr(voice, 0x2c), uint32_t(uint16_t(clamp_q15(level))));
}

void QuickRtlHarness::commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) {
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

void QuickRtlHarness::release_voice(int voice, const Region& r) {
  bus_write_word(voice_addr(voice, 0x34), uint32_t(0x100 | (r.loop_mode & 0x3)));
}

std::pair<int16_t, int16_t> QuickRtlHarness::request_sample(int produced) {
  top_->sample_tick = 1;
  tick();
  top_->sample_tick = 0;

  int timeout = 0;
  while (!top_->sample_valid && timeout < 500) {
    tick();
    ++timeout;
  }
  if (!top_->sample_valid) {
    throw std::runtime_error("quick RTL sample response timed out at output sample " + std::to_string(produced));
  }
  return {int16_t(top_->sample_l), int16_t(top_->sample_r)};
}

void QuickRtlHarness::bus_write_word(uint16_t address, uint32_t data) {
  top_->bus_valid = 1;
  top_->bus_write = 1;
  top_->bus_address = address;
  top_->bus_wdata = data;
  tick();
  if (!top_->bus_ready || top_->bus_error) {
    throw std::runtime_error("quick RTL bus write failed at address 0x" + hex16(address));
  }
  top_->bus_valid = 0;
  top_->bus_write = 0;
  tick();
}

void QuickRtlHarness::tick() {
  top_->clk = 0;
  top_->mem_req_ready = 1;
  top_->mem_rsp_valid = rsp_valid_ ? 1 : 0;
  top_->mem_rsp_data = rsp_data_;
  top_->eval();

  bool next_rsp_valid = top_->mem_req_valid && top_->mem_req_ready;
  int16_t next_rsp_data = next_rsp_valid ? read_word(top_->mem_req_addr) : 0;

  top_->clk = 1;
  top_->eval();

  rsp_valid_ = next_rsp_valid;
  rsp_data_ = next_rsp_data;

  top_->clk = 0;
  top_->eval();
}

int16_t QuickRtlHarness::read_word(uint32_t address) const {
  return address < memory_.size() ? memory_[address] : 0;
}

}  // namespace render
