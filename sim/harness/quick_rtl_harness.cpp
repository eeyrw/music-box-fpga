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
    : top_(new Vwavetable_core), voice_control_(*this), memory_(memory) {
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
  voice_control_.set_envelope(voice, level);
}

void QuickRtlHarness::commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) {
  voice_control_.commit_voice(voice, enable, phase_inc, r);
}

void QuickRtlHarness::release_voice(int voice, const Region& r) {
  voice_control_.release_voice(voice, r);
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

void QuickRtlHarness::write_register(uint16_t address, uint32_t data) {
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
