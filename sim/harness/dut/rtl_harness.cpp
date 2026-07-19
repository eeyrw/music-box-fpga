#include "rtl_harness.h"

#include "Vwavetable_cached_render_core.h"

#include <cstdio>
#include <iostream>
#include <stdexcept>

namespace render {
namespace {

std::string hex16(uint16_t v) {
  char b[8];
  std::snprintf(b, sizeof(b), "%04x", v);
  return b;
}

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

}  // namespace

RtlHarness::RtlHarness(const std::vector<int16_t>& memory, const std::string& wav_path,
                       int sample_rate, const MemoryProfile& memory_profile)
    : top_(new Vwavetable_cached_render_core), voice_control_(*this), memory_(memory),
      memory_profile_(memory_profile), wav_(wav_path, sample_rate), sample_rate_(sample_rate) {
  top_->clk = 0;
  top_->rst = 1;
  top_->bus_valid = 0;
  top_->bus_write = 0;
  top_->bus_address = 0;
  top_->bus_wdata = 0;
  top_->sample_tick = 0;
  top_->ext_req_ready = 1;
  top_->ext_rsp_valid = 0;
  for (int i = 0; i < 4; ++i) top_->ext_rsp_data[i] = 0;
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

void RtlHarness::write_register(uint16_t address, uint32_t data) {
  constexpr int kBusTimeoutCycles = 1000;
  note_register_write(register_write_stats_, address);
  // Commit writes can hold ready low while the RTL reads shadow state into the
  // active/runtime RAMs. Keep valid asserted until the register bank accepts it.
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
    throw std::runtime_error("bus write failed at address 0x" + hex16(address));
  }
  top_->bus_valid = 0;
  top_->bus_write = 0;
  tick();
}

void RtlHarness::set_envelope(int voice, int level) {
  voice_control_.set_envelope(voice, level);
}

void RtlHarness::set_gain(int voice, int gain_l, int gain_r) {
  voice_control_.set_gain(voice, gain_l, gain_r);
}

void RtlHarness::set_phase_inc(int voice, uint32_t phase_inc) {
  voice_control_.set_phase_inc(voice, phase_inc);
}

void RtlHarness::set_filter(int voice, const FilterConfig& filter) {
  voice_control_.set_filter(voice, filter);
}

void RtlHarness::commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) {
  voice_control_.commit_voice(voice, enable, phase_inc, r);
}

void RtlHarness::release_voice(int voice, const Region& r) {
  voice_control_.release_voice(voice, r);
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
                             " ext_rsp_valid=" + std::to_string(int(top_->ext_rsp_valid)));
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

  if (top_->mem_debug_hit_pulse) ++memory_hits_;
  if (top_->mem_debug_miss_pulse) ++memory_misses_;
  if (top_->mem_debug_response_pulse) {
    ++memory_responses_;
    uint16_t latency = top_->mem_debug_response_latency;
    response_latency_sum_ += latency;
    if (latency > response_latency_max_) response_latency_max_ = latency;
  }

  top_->clk = 0;
  top_->eval();
}

void RtlHarness::service_external_memory() {
  top_->ext_req_ready = (!line_pending_ && ready_gap_countdown_ == 0) ? 1 : 0;
  top_->ext_rsp_valid = 0;

  if (line_pending_) {
    if (line_countdown_ == 0) {
      for (int i = 0; i < 4; ++i) top_->ext_rsp_data[i] = 0;
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
  uint64_t requests = stats.hits + stats.misses;
  double hit_rate = requests == 0 ? 0.0 : (100.0 * double(memory_hits_) / double(requests));
  double avg_latency = stats.responses == 0 ? 0.0 : (double(stats.response_latency_sum) / double(stats.responses));
  std::cout << "memory_subsystem hits=" << stats.hits
            << " misses=" << stats.misses
            << " hit_rate=" << hit_rate << "%"
            << " profile=" << stats.profile
            << " external_line_requests=" << stats.external_line_requests
            << " sequential_line_requests=" << stats.sequential_line_requests
            << " responses=" << stats.responses
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
  stats.hits = memory_hits_;
  stats.misses = memory_misses_;
  stats.responses = memory_responses_;
  stats.external_line_requests = external_line_requests_;
  stats.sequential_line_requests = sequential_line_requests_;
  stats.response_latency_sum = response_latency_sum_;
  stats.response_latency_max = response_latency_max_;
  stats.line_words = kLineWords;
  stats.random_latency_cycles = memory_profile_.random_latency_cycles;
  stats.sequential_latency_cycles = memory_profile_.sequential_latency_cycles;
  stats.ready_gap_cycles = memory_profile_.ready_gap_cycles;
  stats.register_writes = register_write_stats_;
  return stats;
}

}  // namespace render
