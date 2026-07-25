#include "core_rtl_harness.h"

#include "Vwavetable_render_core.h"

#include <cstdio>
#include <algorithm>
#include <stdexcept>
#include <string>

namespace render {
namespace {

int sample_timeout_cycles() {
  // The core render path uses an ideal word memory, but the renderer still walks
  // configured voices serially and a stereo voice can consume four word reads.
  // Keep this tied to kNumVoices so high-polyphony MIDI/SF2 renders do not trip
  // a smoke-test bound from smaller configurations.
  constexpr int kReadsPerStereoVoice = 4;
  constexpr int kPipelineSlackPerRead = 8;
  return 64 + kNumVoices * kReadsPerStereoVoice * kPipelineSlackPerRead;
}

constexpr unsigned voice_id_width() {
  unsigned width = 0;
  unsigned remaining = unsigned(kNumVoices - 1);
  while (remaining != 0) {
    ++width;
    remaining >>= 1;
  }
  return width;
}

constexpr unsigned kMemReqValidBit = 32 + 1 + voice_id_width();

bool mem_req_valid(uint64_t request) {
  return ((request >> kMemReqValidBit) & 1u) != 0;
}

uint32_t mem_req_addr(uint64_t request) {
  return uint32_t(request);
}

uint32_t pack_mem_rsp(bool valid, int16_t data) {
  return (uint32_t(valid) << 16) | uint16_t(data);
}

}  // namespace

CoreRtlHarness::CoreRtlHarness(const std::vector<int16_t>& memory)
    : top_(new Vwavetable_render_core), memory_(memory) {
  top_->clk = 0;
  top_->rst = 1;
  top_->bus_valid = 0;
  top_->bus_write = 0;
  top_->bus_address = 0;
  top_->bus_wdata = 0;
  top_->cmd_stream_valid = 0;
  top_->cmd_stream_data = 0;
  top_->sample_tick = 0;
  top_->mem_req_ready = 1;
  top_->mem_rsp = 0;
}

CoreRtlHarness::~CoreRtlHarness() {
  delete top_;
}

void CoreRtlHarness::reset() {
  for (int i = 0; i < 3; ++i) tick();
  top_->rst = 0;
  tick();
}

std::pair<int16_t, int16_t> CoreRtlHarness::request_sample(int produced) {
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
    throw std::runtime_error("core RTL sample response timed out at output sample " +
                             std::to_string(produced) + " after " +
                             std::to_string(timeout_limit) + " cycles" +
                             " busy=" + std::to_string(int(top_->busy)) +
                             " mem_req_valid=" +
                             std::to_string(int(mem_req_valid(top_->mem_req))) +
                             " mem_req_ready=" + std::to_string(int(top_->mem_req_ready)) +
                             " mem_rsp_valid=" + std::to_string(int(rsp_valid_)));
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

void CoreRtlHarness::write_command_words(const std::vector<uint32_t>& words) {
  if (words.empty()) return;
  const uint8_t opcode = uint8_t(words.front() >> 24);
  const int voice = int((words.front() >> 16) & 0xffu);
  if (voice >= 0 && voice < kNumVoices) {
    if (opcode == 0x10 || opcode == 0x11) {
      voices_[voice].stereo = opcode == 0x11;
      const size_t filter_word = opcode == 0x11 ? 13 : 9;
      voices_[voice].filter_enable = words.size() > filter_word &&
                                     (words[filter_word] & 0x00010000u) != 0;
    } else if (opcode == 0x12) {
      voices_[voice].enabled = true;
      voices_[voice].envelope_level = kQ15Full;
    } else if (opcode == 0x15) {
      voices_[voice].enabled = false;
      voices_[voice].envelope_level = 0;
    } else if (opcode == 0x17 && words.size() >= 4) {
      voices_[voice].filter_enable = (words[3] & 0x00010000u) != 0;
    }
  }

  for (uint32_t word : words) {
    int waited = 0;
    while (!top_->cmd_stream_ready && waited < 1000) {
      tick();
      ++waited;
    }
    if (!top_->cmd_stream_ready)
      throw std::runtime_error("core RTL command FIFO backpressure timeout");
    top_->cmd_stream_data = word;
    top_->cmd_stream_valid = 1;
    tick();
    top_->cmd_stream_valid = 0;
  }
  // The stream handshake accepts words into the ingress FIFO. Let the parser
  // publish this complete command before the caller can request a PCM frame.
  for (int i = 0; i < 3; ++i) tick();
}

void CoreRtlHarness::tick() {
  ++total_cycles_;
  top_->clk = 0;
  top_->mem_req_ready = 1;
  top_->mem_rsp = pack_mem_rsp(rsp_valid_, rsp_data_);
  top_->eval();

  const uint64_t request = top_->mem_req;
  bool next_rsp_valid = mem_req_valid(request) && top_->mem_req_ready;
  int16_t next_rsp_data = next_rsp_valid ? read_word(mem_req_addr(request)) : 0;
  if (next_rsp_valid) ++total_memory_reads_;

  top_->clk = 1;
  top_->eval();

  rsp_valid_ = next_rsp_valid;
  rsp_data_ = next_rsp_data;

  top_->clk = 0;
  top_->eval();
}

int16_t CoreRtlHarness::read_word(uint32_t address) const {
  return address < memory_.size() ? memory_[address] : 0;
}

uint32_t CoreRtlHarness::count_enabled_voices() const {
  uint32_t count = 0;
  for (const auto& voice : voices_) {
    if (voice.enabled) ++count;
  }
  return count;
}

uint32_t CoreRtlHarness::count_audible_voices() const {
  uint32_t count = 0;
  for (const auto& voice : voices_) {
    if (voice.enabled && voice.envelope_level > 0) ++count;
  }
  return count;
}

uint32_t CoreRtlHarness::count_filtered_voices() const {
  uint32_t count = 0;
  for (const auto& voice : voices_) {
    if (voice.enabled && voice.filter_enable) ++count;
  }
  return count;
}

uint32_t CoreRtlHarness::count_stereo_voices() const {
  uint32_t count = 0;
  for (const auto& voice : voices_) {
    if (voice.enabled && voice.stereo) ++count;
  }
  return count;
}

}  // namespace render
