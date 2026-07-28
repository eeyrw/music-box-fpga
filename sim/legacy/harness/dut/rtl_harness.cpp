#include "rtl_harness.h"

#include "Vwavetable_cached_render_core.h"

#include <cstdio>
#include <iostream>
#include <stdexcept>

namespace render {
namespace {

int sample_timeout_cycles(const MemoryProfile& profile) {
  // The core renders voices serially. A worst-case stereo voice can issue four
  // word reads, and each word read may miss the line cache when many regions are
  // active. Keep this bound tied to the selected external-memory profile instead
  // of using a fixed value that only fits small smoke renders.
  constexpr int kReadsPerStereoVoice = 4;
  constexpr int kPipelineSlackPerRead = 8;
  return 64 + kNumVoices * kReadsPerStereoVoice *
                  (profile.random_latency_cycles + profile.ready_gap_cycles + kPipelineSlackPerRead);
}

bool packed_bit(uint64_t value, unsigned bit) {
  return ((value >> bit) & 1U) != 0;
}

uint64_t packed_u64(const VlWide<13>& value, unsigned low_word) {
  return uint64_t(value[low_word]) |
         (uint64_t(value[low_word + 1]) << 32);
}

}  // namespace

RtlHarness::RtlHarness(const std::vector<int16_t>& memory, const std::string& wav_path,
                       int sample_rate, const MemoryProfile& memory_profile)
    : top_(new Vwavetable_cached_render_core), memory_(memory),
      memory_profile_(memory_profile), wav_(wav_path, sample_rate), sample_rate_(sample_rate) {
  top_->clk = 0;
  top_->rst = 1;
  top_->bus_valid = 0;
  top_->bus_write = 0;
  top_->bus_address = 0;
  top_->bus_wdata = 0;
  top_->cmd_stream_valid = 0;
  top_->cmd_stream_data = 0;
  top_->sample_tick = 0;
  top_->ext_req_ready = 1;
  top_->ext_rsp_valid = 0;
  for (int i = 0; i < kLineWords / 2; ++i) top_->ext_rsp_data[i] = 0;
}

RtlHarness::~RtlHarness() {
  delete top_;
}

void RtlHarness::reset() {
  // Keep reset asserted for a few clocks so all sequential RTL state sees it,
  // then release reset and tick once more before any bus transaction.
  for (int i = 0; i < 3; ++i) tick();
  top_->rst = 0;
  tick();
}

void RtlHarness::write_command_words(const std::vector<uint32_t>& words) {
  for (uint32_t word : words) {
    int waited = 0;
    while (!top_->cmd_stream_ready && waited < 1000) {
      tick();
      ++waited;
    }
    if (!top_->cmd_stream_ready)
      throw std::runtime_error("command FIFO backpressure timeout");
    top_->cmd_stream_data = word;
    top_->cmd_stream_valid = 1;
    tick();
    top_->cmd_stream_valid = 0;
  }
  for (int i = 0; i < 3; ++i) tick();
}

void RtlHarness::request_sample(int produced) {
  // One call corresponds to one stereo output frame. sample_tick is pulsed for a
  // clock, then the harness waits for sample_valid while continuing to service
  // the memory ready/valid interface inside tick().
  top_->sample_tick = 1;
  tick();
  top_->sample_tick = 0;

  int timeout = 0;
  const int timeout_limit = sample_timeout_cycles(memory_profile_);
  while (!top_->sample_valid && timeout < timeout_limit) {
    tick();
    ++timeout;
  }
  if (!top_->sample_valid) {
    throw std::runtime_error("sample response timed out at output sample " + std::to_string(produced) +
                             " after " + std::to_string(timeout_limit) + " cycles" +
                             " busy=" + std::to_string(int(top_->busy)) +
                             " ext_req_valid=" + std::to_string(int(top_->ext_req_valid)) +
                             " ext_req_ready=" + std::to_string(int(top_->ext_req_ready)) +
                             " ext_rsp_valid=" + std::to_string(int(top_->ext_rsp_valid)) +
                             " render_active=" +
                             std::to_string(int(top_->render_diagnostics[12] & 1U)) +
                             " render_cycle_counter=" +
                             std::to_string(uint32_t(top_->render_diagnostics[0])) +
                             " render_frame_count=" +
                             std::to_string(packed_u64(top_->render_diagnostics, 6)) +
                             " deadline_misses=" +
                             std::to_string(packed_u64(top_->render_diagnostics, 4)) +
                             " prefetch_issued=" + std::to_string(prefetch_issued_) +
                             " prefetch_filled=" + std::to_string(prefetch_filled_) +
                             " prefetch_used=" + std::to_string(prefetch_used_) +
                             " prefetch_dropped=" + std::to_string(prefetch_dropped_) +
                             " prefetch_late=" + std::to_string(prefetch_late_));
  }
  wav_.write_stereo(int16_t(top_->sample_l), int16_t(top_->sample_r));
}

void RtlHarness::tick() {
  // Model one full clock cycle. The RTL memory subsystem converts core word
  // reads into external line reads; the C++ harness services that external side
  // with a fixed-latency line memory model.
  top_->clk = 0;
  service_external_memory();
  top_->eval();

  top_->clk = 1;
  top_->eval();

  if (packed_bit(top_->cache_diagnostics, 26)) {
    ++memory_responses_;
    uint16_t latency = uint16_t((top_->cache_diagnostics >> 10) & 0xffffU);
    response_latency_sum_ += latency;
    if (latency > response_latency_max_) response_latency_max_ = latency;
  }
  if (packed_bit(top_->cache_diagnostics, 9)) ++cache_demand_hits_;
  if (packed_bit(top_->cache_diagnostics, 8)) ++cache_demand_misses_;
  if (packed_bit(top_->cache_diagnostics, 7)) ++cache_line_fills_;
  if (packed_bit(top_->cache_diagnostics, 6)) ++cache_same_line_endpoint_hits_;
  if (packed_bit(top_->cache_diagnostics, 5)) ++cache_replacements_;
  if (packed_bit(top_->cache_diagnostics, 4)) ++prefetch_issued_;
  if (packed_bit(top_->cache_diagnostics, 3)) ++prefetch_filled_;
  if (packed_bit(top_->cache_diagnostics, 2)) ++prefetch_used_;
  if (packed_bit(top_->cache_diagnostics, 1)) ++prefetch_dropped_;
  if (packed_bit(top_->cache_diagnostics, 0)) ++prefetch_late_;
  if (packed_bit(top_->voice_diagnostics, 35)) ++endpoint_cross_line_pairs_;
  if (packed_bit(top_->voice_diagnostics, 34)) ++endpoint_fetch_slot_pressure_cycles_;
  if (packed_bit(top_->voice_diagnostics, 33)) ++endpoint_memory_stall_cycles_;
  if (packed_bit(top_->voice_diagnostics, 0)) ++dsp_ready_no_context_cycles_;

  top_->clk = 0;
  top_->eval();
}

void RtlHarness::service_external_memory() {
  top_->ext_req_ready = (!line_pending_ && ready_gap_countdown_ == 0) ? 1 : 0;
  top_->ext_rsp_valid = 0;

  if (line_pending_) {
    if (line_countdown_ == 0) {
      for (int i = 0; i < kLineWords / 2; ++i) top_->ext_rsp_data[i] = 0;
      for (int w = 0; w < kLineWords; ++w) {
        uint32_t addr = line_pending_addr_ + uint32_t(w);
        uint16_t value = addr < memory_.size() ? uint16_t(memory_[addr]) : 0;
        int bit = w * 16;
        top_->ext_rsp_data[bit / 32] |= uint32_t(value) << (bit % 32);
      }
      top_->ext_rsp_valid = 1;
      line_pending_ = false;
      ready_gap_countdown_ = memory_profile_.ready_gap_cycles;
    } else {
      --line_countdown_;
    }
  } else if (ready_gap_countdown_ > 0) {
    --ready_gap_countdown_;
  } else if (top_->ext_req_valid) {
    bool sequential = have_last_line_addr_ && (top_->ext_req_addr == last_line_addr_ + uint32_t(kLineWords));
    line_pending_ = true;
    line_pending_addr_ = top_->ext_req_addr;
    line_countdown_ = sequential ? memory_profile_.sequential_latency_cycles
                                 : memory_profile_.random_latency_cycles;
    have_last_line_addr_ = true;
    last_line_addr_ = top_->ext_req_addr;
    ++external_line_requests_;
    if (sequential) ++sequential_line_requests_;
  }
}

void RtlHarness::print_memory_stats() const {
  MemoryStats stats = memory_stats();
  double avg_latency = stats.responses == 0 ? 0.0 : (double(stats.response_latency_sum) / double(stats.responses));
  std::cout << "memory_subsystem profile=" << stats.profile
            << " external_line_requests=" << stats.external_line_requests
            << " sequential_line_requests=" << stats.sequential_line_requests
            << " responses=" << stats.responses
            << " cache_demand_hits=" << stats.cache_demand_hits
            << " cache_demand_misses=" << stats.cache_demand_misses
            << " cache_line_fills=" << stats.cache_line_fills
            << " cache_same_line_endpoint_hits=" << stats.cache_same_line_endpoint_hits
            << " cache_replacements=" << stats.cache_replacements
            << " prefetch_issued=" << stats.prefetch_issued
            << " prefetch_filled=" << stats.prefetch_filled
            << " prefetch_used=" << stats.prefetch_used
            << " prefetch_dropped=" << stats.prefetch_dropped
            << " prefetch_late=" << stats.prefetch_late
            << " render_frames=" << stats.render_frames
            << " avg_render_cycles="
            << (stats.render_frames == 0 ? 0.0 : double(stats.render_cycle_sum) / double(stats.render_frames))
            << " max_render_cycles=" << stats.max_render_cycles
            << " deadline_misses=" << stats.deadline_misses
            << " over_budget_frames=" << stats.over_budget_frames
            << " max_over_budget_cycles=" << stats.max_over_budget_cycles
            << " endpoint_cross_line_pairs=" << stats.endpoint_cross_line_pairs
            << " endpoint_fetch_slot_pressure_cycles=" << stats.endpoint_fetch_slot_pressure_cycles
            << " endpoint_memory_stall_cycles=" << stats.endpoint_memory_stall_cycles
            << " endpoint_fetch_slot_max_occupancy=" << int(stats.endpoint_fetch_slot_max_occupancy)
            << " endpoint_word_req_max_occupancy=" << int(stats.endpoint_word_req_max_occupancy)
            << " endpoint_rsp_meta_max_occupancy=" << int(stats.endpoint_rsp_meta_max_occupancy)
            << " dsp_context_queue_max_occupancy=" << int(stats.dsp_context_queue_max_occupancy)
            << " dsp_ready_no_context_cycles=" << stats.dsp_ready_no_context_cycles
            << " avg_response_latency_cycles=" << avg_latency
            << " max_response_latency_cycles=" << stats.response_latency_max
            << " line_words=" << stats.line_words
            << " random_latency_cycles=" << stats.random_latency_cycles
            << " sequential_latency_cycles=" << stats.sequential_latency_cycles
            << " ready_gap_cycles=" << stats.ready_gap_cycles << "\n";
}

MemoryStats RtlHarness::memory_stats() const {
  MemoryStats stats;
  stats.profile = memory_profile_.name;
  stats.responses = memory_responses_;
  stats.external_line_requests = external_line_requests_;
  stats.sequential_line_requests = sequential_line_requests_;
  stats.response_latency_sum = response_latency_sum_;
  stats.response_latency_max = response_latency_max_;
  stats.cache_demand_hits = cache_demand_hits_;
  stats.cache_demand_misses = cache_demand_misses_;
  stats.cache_line_fills = cache_line_fills_;
  stats.cache_same_line_endpoint_hits = cache_same_line_endpoint_hits_;
  stats.cache_replacements = cache_replacements_;
  stats.prefetch_issued = prefetch_issued_;
  stats.prefetch_filled = prefetch_filled_;
  stats.prefetch_used = prefetch_used_;
  stats.prefetch_dropped = prefetch_dropped_;
  stats.prefetch_late = prefetch_late_;
  stats.render_frames = packed_u64(top_->render_diagnostics, 6);
  stats.last_render_cycles = top_->render_diagnostics[11];
  stats.render_cycle_sum = packed_u64(top_->render_diagnostics, 8);
  stats.max_render_cycles = top_->render_diagnostics[10];
  stats.deadline_misses = packed_u64(top_->render_diagnostics, 4);
  stats.over_budget_frames = packed_u64(top_->render_diagnostics, 2);
  stats.max_over_budget_cycles = top_->render_diagnostics[1];
  stats.endpoint_cross_line_pairs = endpoint_cross_line_pairs_;
  stats.endpoint_fetch_slot_pressure_cycles = endpoint_fetch_slot_pressure_cycles_;
  stats.endpoint_memory_stall_cycles = endpoint_memory_stall_cycles_;
  stats.endpoint_fetch_slot_max_occupancy =
      uint8_t((top_->voice_diagnostics >> 27) & 0x7U);
  stats.endpoint_word_req_max_occupancy =
      uint8_t((top_->voice_diagnostics >> 17) & 0x1fU);
  stats.endpoint_rsp_meta_max_occupancy =
      uint8_t((top_->voice_diagnostics >> 7) & 0x1fU);
  stats.dsp_context_queue_max_occupancy =
      uint8_t((top_->voice_diagnostics >> 1) & 0x7U);
  stats.dsp_ready_no_context_cycles = dsp_ready_no_context_cycles_;
  stats.line_words = kLineWords;
  stats.random_latency_cycles = memory_profile_.random_latency_cycles;
  stats.sequential_latency_cycles = memory_profile_.sequential_latency_cycles;
  stats.ready_gap_cycles = memory_profile_.ready_gap_cycles;
  return stats;
}

}  // namespace render
