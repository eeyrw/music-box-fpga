#include "full_system_harness.h"

#include "Vwavetable_demo_system.h"

#include <stdexcept>

namespace render {

FullSystemHarness::FullSystemHarness(const std::vector<int16_t>& memory,
                                      const std::string& wav_path, int sample_rate)
    : top_(new Vwavetable_demo_system), voice_control_(*this), memory_(memory),
      wav_(wav_path, sample_rate), sample_rate_(sample_rate) {
  top_->clk = 0;
  top_->rst = 1;
  top_->core_rst = 1;
  top_->spi_sclk = 0;
  top_->spi_cs_n = 1;
  top_->spi_mosi = 0;
  top_->ext_req_ready = 1;
  top_->ext_rsp_valid = 0;
  for (int i = 0; i < 4; ++i) top_->ext_rsp_data[i] = 0;
  top_->debug_ext_access = 0;
  top_->debug_ext_rdata = 0;
}

FullSystemHarness::~FullSystemHarness() {
  delete top_;
}

void FullSystemHarness::reset() {
  run_cycles(8);
  top_->rst = 0;
  top_->core_rst = 0;
  run_cycles(8);
}

void FullSystemHarness::run_until_frames(uint64_t target_frames) {
  uint64_t timeout = 0;
  while (frames_ < target_frames) {
    tick();
    if (++timeout > target_frames * 4096 + 100000) {
      throw std::runtime_error("full-system render timed out waiting for I2S frames");
    }
  }
}

FullSystemStats FullSystemHarness::stats() const {
  FullSystemStats s;
  s.frames = frames_;
  s.nonzero_output_words = wav_.nonzero_words();
  s.underruns = underruns_;
  s.sample_drops = sample_drops_;
  s.render_deadline_misses = render_deadline_misses_;
  s.max_render_latency_cycles = max_render_latency_cycles_;
  s.memory_responses = memory_responses_;
  s.external_line_requests = external_line_requests_;
  s.sequential_line_requests = sequential_line_requests_;
  s.register_writes = register_write_stats_;
  return s;
}

void FullSystemHarness::set_envelope(int voice, int level) {
  voice_control_.set_envelope(voice, level);
}

void FullSystemHarness::set_gain(int voice, int gain_l, int gain_r) {
  voice_control_.set_gain(voice, gain_l, gain_r);
}

void FullSystemHarness::set_phase_inc(int voice, uint32_t phase_inc) {
  voice_control_.set_phase_inc(voice, phase_inc);
}

void FullSystemHarness::set_filter(int voice, const FilterConfig& filter) {
  voice_control_.set_filter(voice, filter);
}

void FullSystemHarness::commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) {
  voice_control_.commit_voice(voice, enable, phase_inc, r);
}

void FullSystemHarness::release_voice(int voice, const Region& r) {
  voice_control_.release_voice(voice, r);
}

void FullSystemHarness::write_register(uint16_t address, uint32_t data) {
  note_register_write(register_write_stats_, address);
  top_->spi_cs_n = 0;
  run_cycles(3);
  spi_send_byte(0x80);
  spi_send_byte(uint8_t(address >> 8));
  spi_send_byte(uint8_t(address));
  spi_send_byte(uint8_t(data >> 24));
  spi_send_byte(uint8_t(data >> 16));
  spi_send_byte(uint8_t(data >> 8));
  spi_send_byte(uint8_t(data));
  run_cycles(4);
  top_->spi_cs_n = 1;
  run_cycles(4);
  if (top_->spi_error) throw std::runtime_error("full-system SPI write reported error");
}

void FullSystemHarness::spi_send_byte(uint8_t value) {
  for (int bit = 7; bit >= 0; --bit) spi_clock_bit(((value >> bit) & 1u) != 0);
}

void FullSystemHarness::spi_clock_bit(bool bit_value) {
  top_->spi_mosi = bit_value ? 1 : 0;
  run_cycles(2);
  top_->spi_sclk = 1;
  run_cycles(2);
  top_->spi_sclk = 0;
  run_cycles(2);
}

void FullSystemHarness::run_cycles(int cycles) {
  for (int i = 0; i < cycles; ++i) tick();
}

void FullSystemHarness::tick() {
  top_->clk = 0;
  service_external_memory();
  top_->eval();

  top_->clk = 1;
  top_->eval();

  if (top_->underrun_pulse) ++underruns_;
  if (top_->sample_drop_pulse) ++sample_drops_;
  if (top_->render_deadline_miss_pulse) ++render_deadline_misses_;
  if (top_->render_latency_cycles > max_render_latency_cycles_) {
    max_render_latency_cycles_ = top_->render_latency_cycles;
  }
  if (top_->mem_debug_response_pulse) ++memory_responses_;
  observe_i2s();

  top_->clk = 0;
  top_->eval();
}

void FullSystemHarness::service_external_memory() {
  top_->ext_req_ready = line_pending_ ? 0 : 1;
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
    } else {
      --line_countdown_;
    }
  } else if (top_->ext_req_valid) {
    bool sequential = have_last_line_addr_ && (top_->ext_req_addr == last_line_addr_ + uint32_t(kLineWords));
    line_pending_ = true;
    line_pending_addr_ = top_->ext_req_addr;
    line_countdown_ = sequential ? kSequentialLatencyCycles : kRandomLatencyCycles;
    have_last_line_addr_ = true;
    last_line_addr_ = top_->ext_req_addr;
    ++external_line_requests_;
    if (sequential) ++sequential_line_requests_;
  }
}

void FullSystemHarness::observe_i2s() {
  bool bclk = top_->i2s_bclk != 0;
  if (!bclk_prev_ && bclk) {
    bool lrclk = top_->i2s_lrclk != 0;
    if ((lrclk != rx_lrclk_) && (rx_bit_count_ != 15)) {
      rx_lrclk_ = lrclk;
      rx_bit_count_ = 0;
      rx_shift_ = 0;
    } else {
      rx_shift_ = uint16_t((rx_shift_ << 1) | uint16_t(top_->i2s_sdata & 1));
      if (rx_bit_count_ == 15) {
        int16_t word = int16_t(rx_shift_);
        if (!rx_lrclk_) {
          rx_left_ = word;
        } else {
          decoded_frame(rx_left_, word);
        }
        rx_lrclk_ = lrclk;
        rx_bit_count_ = 0;
        rx_shift_ = 0;
      } else {
        ++rx_bit_count_;
      }
    }
  }
  bclk_prev_ = bclk;
}

void FullSystemHarness::decoded_frame(int16_t left, int16_t right) {
  wav_.write_stereo(left, right);
  ++frames_;
}

}  // namespace render
