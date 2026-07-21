#include "quick_rtl_harness.h"

#include "Vwavetable_render_core.h"

#include <cstdio>
#include <algorithm>
#include <stdexcept>
#include <string>

namespace render {
namespace {

std::string hex16(uint16_t v) {
  char b[8];
  std::snprintf(b, sizeof(b), "%04x", v);
  return b;
}

int sample_timeout_cycles() {
  // The quick core uses an ideal word memory, but the renderer still walks
  // configured voices serially and a stereo voice can consume four word reads.
  // Keep this tied to kNumVoices so high-polyphony MIDI/SF2 renders do not trip
  // a smoke-test bound from smaller configurations.
  constexpr int kReadsPerStereoVoice = 4;
  constexpr int kPipelineSlackPerRead = 8;
  return 64 + kNumVoices * kReadsPerStereoVoice * kPipelineSlackPerRead;
}

}  // namespace

QuickRtlHarness::QuickRtlHarness(const std::vector<int16_t>& memory)
    : top_(new Vwavetable_render_core), voice_control_(*this), memory_(memory) {
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
  voices_.at(voice).envelope_level = level;
  voice_control_.set_envelope(voice, level);
}

void QuickRtlHarness::set_gain(int voice, int gain_l, int gain_r) {
  voice_control_.set_gain(voice, gain_l, gain_r);
}

void QuickRtlHarness::set_phase_inc(int voice, uint32_t phase_inc) {
  voice_control_.set_phase_inc(voice, phase_inc);
}

void QuickRtlHarness::set_filter(int voice, const FilterConfig& filter) {
  voices_.at(voice).filter_enable = filter.enable;
  voice_control_.set_filter(voice, filter);
}

void QuickRtlHarness::commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) {
  voices_.at(voice).enabled = enable != 0;
  voices_.at(voice).stereo = r.stereo;
  voices_.at(voice).filter_enable = r.filter_enable;
  voice_control_.commit_voice(voice, enable, phase_inc, r);
}

void QuickRtlHarness::release_voice(int voice, const Region& r) {
  voice_control_.release_voice(voice, r);
}

std::pair<int16_t, int16_t> QuickRtlHarness::request_sample(int produced) {
  top_->sample_tick = 1;
  uint64_t start_memory_reads = total_memory_reads_;
  uint32_t enabled_voices = count_enabled_voices();
  uint32_t audible_voices = count_audible_voices();
  uint32_t filtered_voices = count_filtered_voices();
  uint32_t stereo_voices = count_stereo_voices();
  tick();
  top_->sample_tick = 0;

  int timeout = 0;
  const int timeout_limit = sample_timeout_cycles();
  uint32_t render_cycles = 1;
  while (!top_->sample_valid && timeout < timeout_limit) {
    tick();
    ++timeout;
    ++render_cycles;
  }
  if (!top_->sample_valid) {
    throw std::runtime_error("quick RTL sample response timed out at output sample " +
                             std::to_string(produced) + " after " +
                             std::to_string(timeout_limit) + " cycles" +
                             " busy=" + std::to_string(int(top_->busy)) +
                             " mem_req_valid=" + std::to_string(int(top_->mem_req_valid)) +
                             " mem_req_ready=" + std::to_string(int(top_->mem_req_ready)) +
                             " mem_rsp_valid=" + std::to_string(int(top_->mem_rsp_valid)));
  }
  render_cycles_sum_ += render_cycles;
  max_render_cycles_ = std::max(max_render_cycles_, render_cycles);
  uint32_t render_memory_reads = uint32_t(total_memory_reads_ - start_memory_reads);
  render_memory_reads_sum_ += render_memory_reads;
  max_render_memory_reads_ = std::max(max_render_memory_reads_, render_memory_reads);
  enabled_voice_sum_ += enabled_voices;
  max_enabled_voices_ = std::max(max_enabled_voices_, enabled_voices);
  audible_voice_sum_ += audible_voices;
  max_audible_voices_ = std::max(max_audible_voices_, audible_voices);
  filtered_voice_sum_ += filtered_voices;
  max_filtered_voices_ = std::max(max_filtered_voices_, filtered_voices);
  stereo_voice_sum_ += stereo_voices;
  max_stereo_voices_ = std::max(max_stereo_voices_, stereo_voices);
  return {int16_t(top_->sample_l), int16_t(top_->sample_r)};
}

void QuickRtlHarness::write_register(uint16_t address, uint32_t data) {
  constexpr int kBusTimeoutCycles = 1000;
  note_register_write(register_write_stats_, address);
  top_->bus_valid = 1;
  top_->bus_write = 1;
  top_->bus_address = address;
  top_->bus_wdata = data;
  int waited = 0;
  while (!top_->bus_ready && waited < kBusTimeoutCycles) {
    tick();
    ++waited;
  }
  if (!top_->bus_ready || top_->bus_error) {
    throw std::runtime_error("quick RTL bus write failed at address 0x" + hex16(address));
  }
  top_->bus_valid = 0;
  top_->bus_write = 0;
  tick();
}

void QuickRtlHarness::tick() {
  ++total_cycles_;
  top_->clk = 0;
  top_->mem_req_ready = 1;
  top_->mem_rsp_valid = rsp_valid_ ? 1 : 0;
  top_->mem_rsp_data = rsp_data_;
  top_->eval();

  bool next_rsp_valid = top_->mem_req_valid && top_->mem_req_ready;
  int16_t next_rsp_data = next_rsp_valid ? read_word(top_->mem_req_addr) : 0;
  if (next_rsp_valid) ++total_memory_reads_;

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

uint32_t QuickRtlHarness::count_enabled_voices() const {
  uint32_t count = 0;
  for (const auto& voice : voices_) {
    if (voice.enabled) ++count;
  }
  return count;
}

uint32_t QuickRtlHarness::count_audible_voices() const {
  uint32_t count = 0;
  for (const auto& voice : voices_) {
    if (voice.enabled && voice.envelope_level > 0) ++count;
  }
  return count;
}

uint32_t QuickRtlHarness::count_filtered_voices() const {
  uint32_t count = 0;
  for (const auto& voice : voices_) {
    if (voice.enabled && voice.filter_enable) ++count;
  }
  return count;
}

uint32_t QuickRtlHarness::count_stereo_voices() const {
  uint32_t count = 0;
  for (const auto& voice : voices_) {
    if (voice.enabled && voice.stereo) ++count;
  }
  return count;
}

}  // namespace render
