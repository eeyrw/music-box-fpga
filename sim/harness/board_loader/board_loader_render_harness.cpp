#include "board_loader_render_harness.h"

#include "Vboard_loader_render_tops.h"

#include <stdexcept>
#include <string>

namespace render {
namespace {

constexpr int kLineWords = 8;
constexpr int kMigBeatBytes = 16;
constexpr uint16_t kRca = 0x1234;

}  // namespace

BoardLoaderRenderHarness::BoardLoaderRenderHarness(const std::vector<uint8_t>& sd_image,
                                                   size_t sf2_size_bytes,
                                                   const std::string& wav_path,
                                                   int sample_rate,
                                                   const MemoryProfile& memory_profile)
    : top_(new Vboard_loader_render_tops), voice_control_(*this), sd_image_(sd_image),
      ddr_bytes_(sf2_size_bytes + kMigBeatBytes, 0), wav_(wav_path, sample_rate),
      memory_profile_(memory_profile) {
  init_inputs();
}

BoardLoaderRenderHarness::~BoardLoaderRenderHarness() {
  delete top_;
}

void BoardLoaderRenderHarness::reset_loader() {
  top_->rst = 1;
  top_->core_rst = 1;
  for (int i = 0; i < 4; ++i) tick();
  top_->rst = 0;
  tick();
}

void BoardLoaderRenderHarness::load_from_sd() {
  reset_loader();
  top_->loader_ddr_init_calib_complete = 1;
  top_->loader_start = 1;
  tick();
  top_->loader_start = 0;

  int timeout = 0;
  const int timeout_limit = int((sd_image_.size() / 512u + 64u) * 20000u);
  while (!top_->loader_asset_loaded && timeout < timeout_limit) {
    if (top_->loader_sd_error_code != 0 || top_->loader_error_code != 0) {
      throw std::runtime_error("loader error sd=" + std::to_string(int(top_->loader_sd_error_code)) +
                               " loader=" + std::to_string(int(top_->loader_error_code)) +
                               " current_lba=" + std::to_string(top_->loader_current_lba) +
                               " bytes_loaded=" + std::to_string(top_->loader_bytes_loaded) +
                               " sd_commands=" + std::to_string(sd_commands_) +
                               " last_cmd=" + std::to_string(last_cmd_));
    }
    tick();
    ++timeout;
  }
  if (!top_->loader_asset_loaded) {
    throw std::runtime_error("SD-to-DDR loader timed out after " + std::to_string(timeout_limit) +
                             " cycles status=" + std::to_string(int(top_->loader_status_state)) +
                             " sd_initialized=" + std::to_string(int(top_->loader_sd_initialized)) +
                             " busy=" + std::to_string(int(top_->loader_busy)) +
                             " sd_commands=" + std::to_string(sd_commands_) +
                             " last_cmd=" + std::to_string(last_cmd_) +
                             " bytes_loaded=" + std::to_string(uint64_t(top_->loader_bytes_loaded)) +
                             " sf2_size=" + std::to_string(uint64_t(top_->loader_sf2_size_bytes)) +
                             " current_lba=" + std::to_string(uint32_t(top_->loader_current_lba)));
  }
  loader_cycles_ = total_cycles_;
}

void BoardLoaderRenderHarness::reset_core() {
  top_->core_rst = 1;
  for (int i = 0; i < 4; ++i) tick();
  top_->core_rst = 0;
  tick();
}

std::pair<int16_t, int16_t> BoardLoaderRenderHarness::request_sample(int produced) {
  top_->core_sample_tick = 1;
  tick();
  top_->core_sample_tick = 0;

  int waited = 0;
  const int timeout_limit = 64 + kNumVoices * 4 *
      (memory_profile_.random_latency_cycles + memory_profile_.ready_gap_cycles + 8);
  while (!top_->core_sample_valid && waited < timeout_limit) {
    tick();
    ++waited;
  }
  if (!top_->core_sample_valid) {
    throw std::runtime_error("core sample timeout at sample " + std::to_string(produced) +
                             " busy=" + std::to_string(int(top_->core_busy)) +
                             " ext_req_valid=" + std::to_string(int(top_->core_ext_req_valid)) +
                             " ext_req_ready=" + std::to_string(int(top_->core_ext_req_ready)) +
                             " ext_rsp_valid=" + std::to_string(int(top_->core_ext_rsp_valid)) +
                             " responses=" + std::to_string(memory_responses_));
  }
  int16_t l = int16_t(top_->core_sample_l);
  int16_t r = int16_t(top_->core_sample_r);
  wav_.write_stereo(l, r);
  return {l, r};
}

void BoardLoaderRenderHarness::set_envelope(int voice, int level) {
  voice_control_.set_envelope(voice, level);
}

void BoardLoaderRenderHarness::set_gain(int voice, int gain_l, int gain_r) {
  voice_control_.set_gain(voice, gain_l, gain_r);
}

void BoardLoaderRenderHarness::set_phase_inc(int voice, uint32_t phase_inc) {
  voice_control_.set_phase_inc(voice, phase_inc);
}

void BoardLoaderRenderHarness::set_filter(int voice, const FilterConfig& filter) {
  voice_control_.set_filter(voice, filter);
}

void BoardLoaderRenderHarness::commit_voice(int voice, int enable, uint32_t phase_inc,
                                            const Region& r) {
  voice_control_.commit_voice(voice, enable, phase_inc, r);
}

void BoardLoaderRenderHarness::release_voice(int voice, const Region& r) {
  voice_control_.release_voice(voice, r);
}

void BoardLoaderRenderHarness::init_inputs() {
  top_->clk = 0;
  top_->rst = 1;
  top_->loader_start = 0;
  top_->loader_ddr_init_calib_complete = 0;
  top_->sd_cmd_ready = 1;
  top_->sd_rsp_valid = 0;
  top_->sd_rsp_status = 0;
  for (int i = 0; i < 4; ++i) top_->sd_rsp_data[i] = 0;
  top_->sd_data_valid = 0;
  top_->sd_data = 0;
  top_->sd_data_last = 0;
  top_->sd_data_status = 0;
  top_->mig_app_rdy = 1;
  top_->mig_app_wdf_rdy = 1;
  top_->core_rst = 1;
  top_->core_bus_valid = 0;
  top_->core_bus_write = 0;
  top_->core_bus_address = 0;
  top_->core_bus_wdata = 0;
  top_->core_sample_tick = 0;
  top_->core_ext_req_ready = 1;
  top_->core_ext_rsp_valid = 0;
  for (int i = 0; i < 4; ++i) top_->core_ext_rsp_data[i] = 0;
}

void BoardLoaderRenderHarness::write_register(uint16_t address, uint32_t data) {
  constexpr int kBusTimeoutCycles = 1000;
  note_register_write(register_write_stats_, address);
  top_->core_bus_valid = 1;
  top_->core_bus_write = 1;
  top_->core_bus_address = address;
  top_->core_bus_wdata = data;
  int waited = 0;
  while (!top_->core_bus_ready && waited < kBusTimeoutCycles) {
    tick();
    ++waited;
  }
  if (!top_->core_bus_ready || top_->core_bus_error) {
    throw std::runtime_error("core register write failed at 0x" + std::to_string(address));
  }
  top_->core_bus_valid = 0;
  top_->core_bus_write = 0;
  tick();
}

void BoardLoaderRenderHarness::tick() {
  drive_combinational_inputs();
  top_->clk = 0;
  top_->eval();

  top_->clk = 1;
  top_->eval();
  observe_sequential_outputs();
  ++total_cycles_;

  top_->clk = 0;
  top_->eval();
}

void BoardLoaderRenderHarness::drive_combinational_inputs() {
  top_->sd_cmd_ready = 1;
  top_->sd_rsp_valid = pending_rsp_cycles_ > 0 ? 1 : 0;
  top_->sd_rsp_status = pending_rsp_status_;
  top_->sd_rsp_data[0] = uint32_t(pending_rsp_data_ & 0xffff'ffffULL);
  top_->sd_rsp_data[1] = uint32_t((pending_rsp_data_ >> 32) & 0xffff'ffffULL);
  top_->sd_rsp_data[2] = 0;
  top_->sd_rsp_data[3] = 0;
  top_->sd_data_valid = data_active_ ? 1 : 0;
  top_->sd_data = data_active_ ? current_sd_data_ : 0;
  top_->sd_data_last = data_active_ && data_index_ == active_block_len_ - 1 &&
                       active_block_index_ == active_block_count_ - 1;
  top_->sd_data_status = 0;
  driven_sd_data_valid_ = top_->sd_data_valid != 0;
  driven_sd_data_ = top_->sd_data;

  top_->core_ext_req_ready = (!line_pending_ && ready_gap_countdown_ == 0) ? 1 : 0;
  top_->core_ext_rsp_valid = 0;

  if (!line_pending_ && ready_gap_countdown_ == 0 && top_->core_ext_req_valid) {
    bool sequential = have_last_line_addr_ && top_->core_ext_req_addr == last_line_addr_ + uint32_t(kLineWords);
    line_pending_ = true;
    line_pending_addr_ = top_->core_ext_req_addr;
    line_countdown_ = sequential ? memory_profile_.sequential_latency_cycles
                                 : memory_profile_.random_latency_cycles;
    have_last_line_addr_ = true;
    last_line_addr_ = top_->core_ext_req_addr;
    top_->core_ext_req_ready = 1;
  }

  if (line_pending_ && line_countdown_ == 0) {
    for (int i = 0; i < 4; ++i) top_->core_ext_rsp_data[i] = 0;
    for (int w = 0; w < kLineWords; ++w) {
      uint32_t word_addr = line_pending_addr_ + uint32_t(w);
      uint16_t value = word_at(word_addr);
      int bit = w * 16;
      top_->core_ext_rsp_data[bit / 32] |= uint32_t(value) << (bit % 32);
    }
    top_->core_ext_rsp_valid = 1;
  }
}

void BoardLoaderRenderHarness::observe_sequential_outputs() {
  bool data_was_active = data_active_;
  if (pending_rsp_cycles_ > 0) {
    --pending_rsp_cycles_;
    if (pending_rsp_cycles_ == 0 && data_start_pending_) {
      data_start_pending_ = false;
      data_start_delay_ = 3;
    }
  } else if (data_start_delay_ > 0) {
    --data_start_delay_;
    if (data_start_delay_ == 0) {
      data_active_ = true;
      data_index_ = 0;
      active_block_index_ = 0;
      current_sd_data_ = active_data_byte();
    }
  }
  if (data_was_active && driven_sd_data_valid_ && top_->sd_data_ready) {
    if (data_index_ == active_block_len_ - 1) {
      data_index_ = 0;
      if (active_block_index_ == active_block_count_ - 1) {
        data_active_ = false;
      } else {
        ++active_block_index_;
        current_sd_data_ = active_data_byte();
      }
    } else {
      ++data_index_;
      current_sd_data_ = active_data_byte();
    }
  }
  if (top_->sd_cmd_valid && top_->sd_cmd_ready) handle_sd_command();
  if (top_->mig_app_en && top_->mig_app_rdy) pending_mig_addr_ = top_->mig_app_addr;
  if (top_->mig_app_wdf_wren && top_->mig_app_wdf_rdy) write_mig_beat(pending_mig_addr_);

  if (line_pending_ && line_countdown_ == 0 && top_->core_ext_rsp_valid) {
    line_pending_ = false;
    ready_gap_countdown_ = memory_profile_.ready_gap_cycles;
  } else if (line_pending_ && line_countdown_ > 0) {
    --line_countdown_;
  } else if (!line_pending_ && ready_gap_countdown_ > 0) {
    --ready_gap_countdown_;
  }
  if (top_->core_mem_debug_response_pulse) ++memory_responses_;
}

void BoardLoaderRenderHarness::handle_sd_command() {
  uint8_t cmd = top_->sd_cmd_index;
  uint32_t arg = top_->sd_cmd_arg;
  data_active_ = false;
  ++sd_commands_;
  last_cmd_ = cmd;
  if (cmd == 0) {
    app_cmd_ = false;
    card_selected_ = false;
    return;
  }
  if (cmd == 8) return respond(0, 0x1aa);
  if (cmd == 55) {
    app_cmd_ = true;
    return respond(0, 0);
  }
  if (cmd == 41 && app_cmd_) {
    app_cmd_ = false;
    if (acmd41_seen_++ == 0) return respond(0, 0x4000'0000ULL);
    return respond(0, 0xc000'0000ULL);
  }
  if (cmd == 2) return respond(0, 0x02544d5341303847ULL);
  if (cmd == 3) return respond(0, uint64_t(kRca) << 16);
  if (cmd == 7 && arg == (uint32_t(kRca) << 16)) {
    card_selected_ = true;
    return respond(0, 0);
  }
  if (cmd == 6 && app_cmd_ && card_selected_ && arg == 2) {
    app_cmd_ = false;
    wide_bus_ = true;
    return respond(0, 0);
  }
  if (cmd == 6 && !app_cmd_ && card_selected_ && arg == 0x80ff'fff1U) {
    active_block_len_ = 64;
    active_block_count_ = 1;
    data_start_pending_ = true;
    return respond(0, 0);
  }
  if (cmd == 17 && card_selected_ && wide_bus_) {
    active_lba_ = arg;
    active_block_len_ = top_->sd_cmd_block_len;
    active_block_count_ = 1;
    data_start_pending_ = true;
    return respond(0, 0);
  }
  if (cmd == 23 && card_selected_ && wide_bus_ && (arg >> 16) == 0 && (arg & 0xffffU) != 0) {
    predeclared_block_count_ = arg & 0xffffU;
    return respond(0, 0);
  }
  if (cmd == 18 && card_selected_ && wide_bus_ && predeclared_block_count_ != 0 &&
      top_->sd_cmd_block_count == predeclared_block_count_) {
    active_lba_ = arg;
    active_block_len_ = top_->sd_cmd_block_len;
    active_block_count_ = predeclared_block_count_;
    predeclared_block_count_ = 0;
    data_start_pending_ = true;
    return respond(0, 0);
  }
  respond(1, 0);
}

void BoardLoaderRenderHarness::respond(uint8_t status, uint64_t data) {
  pending_rsp_cycles_ = 2;
  pending_rsp_status_ = status;
  pending_rsp_data_ = data;
}

uint8_t BoardLoaderRenderHarness::sector_byte(uint32_t lba, int index) const {
  size_t offset = size_t(lba) * 512u + size_t(index);
  return offset < sd_image_.size() ? sd_image_[offset] : 0;
}

uint8_t BoardLoaderRenderHarness::active_data_byte() const {
  if (active_block_len_ == 64) return 0x5a;
  return sector_byte(active_lba_ + uint32_t(active_block_index_), data_index_);
}

void BoardLoaderRenderHarness::write_mig_beat(uint32_t addr) {
  for (int i = 0; i < kMigBeatBytes; ++i) {
    if (((top_->mig_app_wdf_mask >> i) & 1u) == 0) {
      size_t byte_addr = size_t(addr) + size_t(i);
      if (byte_addr >= ddr_bytes_.size()) ddr_bytes_.resize(byte_addr + 1, 0);
      ddr_bytes_[byte_addr] = uint8_t((top_->mig_app_wdf_data[i / 4] >> ((i % 4) * 8)) & 0xff);
    }
  }
}

uint16_t BoardLoaderRenderHarness::word_at(uint32_t word_addr) const {
  size_t byte_addr = size_t(word_addr) * 2u;
  uint16_t lo = byte_addr < ddr_bytes_.size() ? ddr_bytes_[byte_addr] : 0;
  uint16_t hi = (byte_addr + 1) < ddr_bytes_.size() ? ddr_bytes_[byte_addr + 1] : 0;
  return uint16_t(lo | (hi << 8));
}

}  // namespace render
