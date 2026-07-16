#include "midi_parser.h"
#include "reference_synth.h"
#include "register_control.h"
#include "render_support.h"
#include "rtl_harness.h"
#include "sf2_loader.h"

#include "Vboard_loader_render_tops.h"

#include <verilated.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace render {
namespace {

constexpr int kLineWords = 8;
constexpr int kMigBeatBytes = 16;
constexpr uint16_t kRca = 0x1234;

MemoryProfile parse_board_memory_profile(const std::string& name) {
  if (name == "ddr") return MemoryProfile{"ddr", 10, 4, 0};
  if (name == "sdram") return MemoryProfile{"sdram", 16, 8, 1};
  if (name == "parallel-nor" || name == "nor") return MemoryProfile{"parallel-nor", 28, 14, 3};
  throw std::runtime_error("unknown memory profile: " + name + " (expected ddr, sdram, or parallel-nor)");
}

std::vector<uint8_t> read_file_bytes(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error("failed to open " + path);
  f.seekg(0, std::ios::end);
  std::streamoff size = f.tellg();
  if (size < 0) throw std::runtime_error("failed to size " + path);
  f.seekg(0, std::ios::beg);
  std::vector<uint8_t> data(static_cast<size_t>(size));
  if (!data.empty()) f.read(reinterpret_cast<char*>(data.data()), std::streamsize(data.size()));
  if (!f && !data.empty()) throw std::runtime_error("failed to read " + path);
  return data;
}

void put_u16le(std::vector<uint8_t>& data, size_t offset, uint16_t value) {
  data.at(offset + 0) = uint8_t(value & 0xff);
  data.at(offset + 1) = uint8_t((value >> 8) & 0xff);
}

void put_u32le(std::vector<uint8_t>& data, size_t offset, uint32_t value) {
  for (int i = 0; i < 4; ++i) data.at(offset + size_t(i)) = uint8_t((value >> (8 * i)) & 0xff);
}

void put_u64le(std::vector<uint8_t>& data, size_t offset, uint64_t value) {
  for (int i = 0; i < 8; ++i) data.at(offset + size_t(i)) = uint8_t((value >> (8 * i)) & 0xff);
}

std::vector<uint8_t> make_raw_sd_image(const std::vector<uint8_t>& sf2_bytes, uint64_t sf2_start_lba) {
  const size_t total = size_t(sf2_start_lba) * 512u + sf2_bytes.size();
  std::vector<uint8_t> image((total + 511u) & ~size_t(511u), 0);
  image[0] = 'W';
  image[1] = 'T';
  image[2] = 'S';
  image[3] = 'F';
  put_u32le(image, 0x04, 1);
  put_u32le(image, 0x08, 0x40);
  put_u32le(image, 0x0c, 0);
  put_u64le(image, 0x10, sf2_start_lba);
  put_u64le(image, 0x18, sf2_bytes.size());
  put_u64le(image, 0x20, 0);
  std::copy(sf2_bytes.begin(), sf2_bytes.end(), image.begin() + size_t(sf2_start_lba) * 512u);
  return image;
}

std::vector<int16_t> words_from_bytes(const std::vector<uint8_t>& bytes, size_t byte_count) {
  std::vector<int16_t> words;
  words.reserve((byte_count + 1) / 2);
  for (size_t i = 0; i < byte_count; i += 2) {
    uint16_t lo = bytes[i];
    uint16_t hi = (i + 1 < byte_count) ? bytes[i + 1] : 0;
    words.push_back(int16_t(lo | (hi << 8)));
  }
  return words;
}

void write_wav_header(std::ofstream& f, int sample_rate, uint32_t data_bytes) {
  auto put16 = [&f](uint16_t value) {
    char b[2] = {char(value & 0xff), char((value >> 8) & 0xff)};
    f.write(b, 2);
  };
  auto put32 = [&f](uint32_t value) {
    char b[4] = {char(value & 0xff), char((value >> 8) & 0xff),
                 char((value >> 16) & 0xff), char((value >> 24) & 0xff)};
    f.write(b, 4);
  };
  f.write("RIFF", 4);
  put32(36 + data_bytes);
  f.write("WAVEfmt ", 8);
  put32(16);
  put16(1);
  put16(2);
  put32(uint32_t(sample_rate));
  put32(uint32_t(sample_rate * 4));
  put16(4);
  put16(16);
  f.write("data", 4);
  put32(data_bytes);
}

class WavWriter {
 public:
  WavWriter(const std::string& path, int sample_rate) : f_(path, std::ios::binary), sample_rate_(sample_rate) {
    if (!f_) throw std::runtime_error("failed to open " + path);
    write_wav_header(f_, sample_rate_, 0);
  }

  ~WavWriter() {
    if (f_) {
      f_.seekp(0);
      write_wav_header(f_, sample_rate_, data_bytes_);
    }
  }

  void write_stereo(int16_t left, int16_t right) {
    char l[2] = {char(uint16_t(left) & 0xff), char((uint16_t(left) >> 8) & 0xff)};
    char r[2] = {char(uint16_t(right) & 0xff), char((uint16_t(right) >> 8) & 0xff)};
    f_.write(l, 2);
    f_.write(r, 2);
    data_bytes_ += 4;
  }

 private:
  std::ofstream f_;
  int sample_rate_ = 48000;
  uint32_t data_bytes_ = 0;
};

class FanoutSink : public VoiceControlSink {
 public:
  FanoutSink(VoiceControlSink& a, VoiceControlSink& b) : a_(a), b_(b) {}

  void set_envelope(int voice, int level) override {
    a_.set_envelope(voice, level);
    b_.set_envelope(voice, level);
  }
  void set_gain(int voice, int gain_l, int gain_r) override {
    a_.set_gain(voice, gain_l, gain_r);
    b_.set_gain(voice, gain_l, gain_r);
  }
  void set_phase_inc(int voice, uint32_t phase_inc) override {
    a_.set_phase_inc(voice, phase_inc);
    b_.set_phase_inc(voice, phase_inc);
  }
  void set_filter(int voice, const FilterConfig& filter) override {
    a_.set_filter(voice, filter);
    b_.set_filter(voice, filter);
  }
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) override {
    a_.commit_voice(voice, enable, phase_inc, r);
    b_.commit_voice(voice, enable, phase_inc, r);
  }
  void release_voice(int voice, const Region& r) override {
    a_.release_voice(voice, r);
    b_.release_voice(voice, r);
  }

 private:
  VoiceControlSink& a_;
  VoiceControlSink& b_;
};

class BoardLoaderRenderHarness : public VoiceControlSink, private RegisterWriteSink {
 public:
  BoardLoaderRenderHarness(const std::vector<uint8_t>& sd_image, size_t sf2_size_bytes,
                           const std::string& wav_path, int sample_rate,
                           const MemoryProfile& memory_profile)
      : top_(new Vboard_loader_render_tops), voice_control_(*this), sd_image_(sd_image),
        ddr_bytes_(sf2_size_bytes + kMigBeatBytes, 0), wav_(wav_path, sample_rate),
        memory_profile_(memory_profile) {
    init_inputs();
  }

  ~BoardLoaderRenderHarness() override { delete top_; }

  void reset_loader() {
    top_->rst = 1;
    top_->core_rst = 1;
    for (int i = 0; i < 4; ++i) tick();
    top_->rst = 0;
    tick();
  }

  void load_from_sd() {
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
                                 " loader=" + std::to_string(int(top_->loader_error_code)));
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

  void reset_core() {
    top_->core_rst = 1;
    for (int i = 0; i < 4; ++i) tick();
    top_->core_rst = 0;
    tick();
  }

  std::pair<int16_t, int16_t> request_sample(int produced) {
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
                               " hits=" + std::to_string(memory_hits_) +
                               " misses=" + std::to_string(memory_misses_) +
                               " responses=" + std::to_string(memory_responses_));
    }
    int16_t l = int16_t(top_->core_sample_l);
    int16_t r = int16_t(top_->core_sample_r);
    wav_.write_stereo(l, r);
    if (l != 0) ++nonzero_output_words_;
    if (r != 0) ++nonzero_output_words_;
    return {l, r};
  }

  void set_envelope(int voice, int level) override { voice_control_.set_envelope(voice, level); }
  void set_gain(int voice, int gain_l, int gain_r) override { voice_control_.set_gain(voice, gain_l, gain_r); }
  void set_phase_inc(int voice, uint32_t phase_inc) override { voice_control_.set_phase_inc(voice, phase_inc); }
  void set_filter(int voice, const FilterConfig& filter) override { voice_control_.set_filter(voice, filter); }
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) override {
    voice_control_.commit_voice(voice, enable, phase_inc, r);
  }
  void release_voice(int voice, const Region& r) override { voice_control_.release_voice(voice, r); }

  const std::vector<uint8_t>& ddr_bytes() const { return ddr_bytes_; }
  uint64_t loader_cycles() const { return loader_cycles_; }
  int nonzero_output_words() const { return nonzero_output_words_; }
  const RegisterWriteStats& register_write_stats() const { return register_write_stats_; }
  uint64_t memory_hits() const { return memory_hits_; }
  uint64_t memory_misses() const { return memory_misses_; }
  uint64_t memory_responses() const { return memory_responses_; }

 private:
  void init_inputs() {
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

  void write_register(uint16_t address, uint32_t data) override {
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

  void tick() {
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

  void drive_combinational_inputs() {
    top_->sd_cmd_ready = 1;
    top_->sd_rsp_valid = pending_rsp_cycles_ > 0 ? 1 : 0;
    top_->sd_rsp_status = pending_rsp_status_;
    top_->sd_rsp_data[0] = uint32_t(pending_rsp_data_ & 0xffff'ffffULL);
    top_->sd_rsp_data[1] = uint32_t((pending_rsp_data_ >> 32) & 0xffff'ffffULL);
    top_->sd_rsp_data[2] = 0;
    top_->sd_rsp_data[3] = 0;
    top_->sd_data_valid = data_active_ ? 1 : 0;
    top_->sd_data = data_active_ ? sector_byte(active_lba_, data_index_) : 0;
    top_->sd_data_last = data_active_ && data_index_ == 511;
    top_->sd_data_status = 0;

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

  void observe_sequential_outputs() {
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
      }
    }
    if (top_->sd_cmd_valid && top_->sd_cmd_ready) handle_sd_command();
    if (data_active_ && top_->sd_data_valid && top_->sd_data_ready) {
      if (data_index_ == 511) {
        data_active_ = false;
      } else {
        ++data_index_;
      }
    }
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
    if (top_->core_mem_debug_hit_pulse) ++memory_hits_;
    if (top_->core_mem_debug_miss_pulse) ++memory_misses_;
    if (top_->core_mem_debug_response_pulse) ++memory_responses_;
  }

  void handle_sd_command() {
    uint8_t cmd = top_->sd_cmd_index;
    uint32_t arg = top_->sd_cmd_arg;
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
    if (cmd == 17 && card_selected_ && wide_bus_) {
      active_lba_ = arg;
      data_start_pending_ = true;
      return respond(0, 0);
    }
    respond(1, 0);
  }

  void respond(uint8_t status, uint64_t data) {
    pending_rsp_cycles_ = 2;
    pending_rsp_status_ = status;
    pending_rsp_data_ = data;
  }

  uint8_t sector_byte(uint32_t lba, int index) const {
    size_t offset = size_t(lba) * 512u + size_t(index);
    return offset < sd_image_.size() ? sd_image_[offset] : 0;
  }

  void write_mig_beat(uint32_t addr) {
    for (int i = 0; i < kMigBeatBytes; ++i) {
      if (((top_->mig_app_wdf_mask >> i) & 1u) == 0) {
        size_t byte_addr = size_t(addr) + size_t(i);
        if (byte_addr >= ddr_bytes_.size()) ddr_bytes_.resize(byte_addr + 1, 0);
        ddr_bytes_[byte_addr] = uint8_t((top_->mig_app_wdf_data[i / 4] >> ((i % 4) * 8)) & 0xff);
      }
    }
  }

  uint16_t word_at(uint32_t word_addr) const {
    size_t byte_addr = size_t(word_addr) * 2u;
    uint16_t lo = byte_addr < ddr_bytes_.size() ? ddr_bytes_[byte_addr] : 0;
    uint16_t hi = (byte_addr + 1) < ddr_bytes_.size() ? ddr_bytes_[byte_addr + 1] : 0;
    return uint16_t(lo | (hi << 8));
  }

  Vboard_loader_render_tops* top_ = nullptr;
  RegisterVoiceControl voice_control_;
  const std::vector<uint8_t>& sd_image_;
  std::vector<uint8_t> ddr_bytes_;
  WavWriter wav_;
  MemoryProfile memory_profile_;
  RegisterWriteStats register_write_stats_;
  int pending_rsp_cycles_ = 0;
  uint8_t pending_rsp_status_ = 0;
  uint64_t pending_rsp_data_ = 0;
  bool app_cmd_ = false;
  bool card_selected_ = false;
  bool wide_bus_ = false;
  int acmd41_seen_ = 0;
  bool data_active_ = false;
  bool data_start_pending_ = false;
  int data_start_delay_ = 0;
  uint32_t active_lba_ = 0;
  int data_index_ = 0;
  uint32_t pending_mig_addr_ = 0;
  bool line_pending_ = false;
  uint32_t line_pending_addr_ = 0;
  int line_countdown_ = 0;
  int ready_gap_countdown_ = 0;
  bool have_last_line_addr_ = false;
  uint32_t last_line_addr_ = 0;
  int nonzero_output_words_ = 0;
  uint64_t total_cycles_ = 0;
  uint64_t loader_cycles_ = 0;
  uint64_t memory_hits_ = 0;
  uint64_t memory_misses_ = 0;
  uint64_t memory_responses_ = 0;
  uint64_t sd_commands_ = 0;
  int last_cmd_ = -1;
};

}  // namespace
}  // namespace render

int main(int argc, char** argv) {
  try {
    Verilated::commandArgs(argc, argv);
    render::Args args = render::parse_args(argc, argv);
    int sample_count = std::max(1, int(std::round(args.seconds * args.sample_rate)));
    int adsr_tick_samples = std::max(1, int(std::round(args.adsr_tick_ms * args.sample_rate / 1000.0)));

    render::Sf2Data sf2 = render::load_sf2(args.sf2);
    std::vector<uint8_t> sf2_bytes = render::read_file_bytes(args.sf2);
    std::vector<uint8_t> sd_image = render::make_raw_sd_image(sf2_bytes, 1);
    std::vector<render::NoteEvent> events = args.midi.empty() ? render::default_melody()
                                                              : render::parse_midi(args.midi);

    std::string wav_path = args.out_dir + "/out.wav";
    render::MemoryProfile memory_profile = render::parse_board_memory_profile(args.memory_profile);
    render::BoardLoaderRenderHarness board(sd_image, sf2_bytes.size(), wav_path, args.sample_rate, memory_profile);
    board.load_from_sd();

    const auto& loaded = board.ddr_bytes();
    if (loaded.size() < sf2_bytes.size()) {
      throw std::runtime_error("DDR image shorter than source SF2 bytes");
    }
    auto mismatch = std::mismatch(sf2_bytes.begin(), sf2_bytes.end(), loaded.begin());
    if (mismatch.first != sf2_bytes.end()) {
      size_t index = size_t(mismatch.first - sf2_bytes.begin());
      throw std::runtime_error("DDR image loaded by SD native RTL does not match source SF2 bytes at byte " +
                               std::to_string(index) + " expected=" + std::to_string(int(*mismatch.first)) +
                               " got=" + std::to_string(int(*mismatch.second)));
    }
    std::vector<int16_t> wave_memory = render::words_from_bytes(loaded, sf2_bytes.size());

    std::vector<render::Region> regions;
    render::prepare_events_and_regions(args, sf2, sample_count, adsr_tick_samples, events, regions, wave_memory);
    render::ReferenceSynth reference(wave_memory);
    board.reset_core();
    render::FanoutSink control(board, reference);
    render::McuModel mcu(control, regions);

    size_t event_index = 0;
    int next_adsr_sample = 0;
    int mismatches = 0;
    for (int produced = 0; produced < sample_count; ++produced) {
      while (event_index < events.size() && events[event_index].sample <= produced) {
        mcu.handle_event(events[event_index++]);
      }
      while (produced >= next_adsr_sample) {
        mcu.envelope_tick();
        next_adsr_sample += adsr_tick_samples;
      }
      auto ref = reference.render_sample();
      auto got = board.request_sample(produced);
      if (got != ref) {
        ++mismatches;
        if (mismatches <= 10) {
          std::cerr << "sample " << produced << " mismatch RTL L=" << got.first
                    << " R=" << got.second << " reference L=" << ref.first
                    << " R=" << ref.second << "\n";
        }
      }
    }

    if (board.nonzero_output_words() == 0) {
      throw std::runtime_error("board loader render produced all-zero PCM");
    }
    if (mismatches != 0) {
      throw std::runtime_error("board loader render found " + std::to_string(mismatches) +
                               " RTL/reference mismatches");
    }

    const auto& reg = board.register_write_stats();
    std::string extra = "  \"loader_cycles\": " + std::to_string(board.loader_cycles()) +
        ",\n  \"sd_image_bytes\": " + std::to_string(sd_image.size()) +
        ",\n  \"sf2_size_bytes\": " + std::to_string(sf2_bytes.size()) +
        ",\n  \"loaded_words\": " + std::to_string(wave_memory.size()) +
        ",\n  \"nonzero_output_words\": " + std::to_string(board.nonzero_output_words()) +
        ",\n  \"memory_hits\": " + std::to_string(board.memory_hits()) +
        ",\n  \"memory_misses\": " + std::to_string(board.memory_misses()) +
        ",\n  \"memory_responses\": " + std::to_string(board.memory_responses()) +
        ",\n  \"register_writes_total\": " + std::to_string(reg.total) +
        ",\n  \"wav_path\": \"" + wav_path + "\"";
    render::write_summary(args.out_dir + "/board_loader_render_config.json", regions,
                          args.sample_rate, sample_count, int(events.size()), extra);

    std::cout << "PASS: board loader render loaded " << sf2_bytes.size()
              << " SF2 bytes from raw SD image, matched " << sample_count
              << " RTL/reference stereo samples, wav=" << wav_path << "\n";
    std::cout << "loader_cycles=" << board.loader_cycles()
              << " regions=" << regions.size()
              << " events=" << events.size()
              << " nonzero_output_words=" << board.nonzero_output_words()
              << " memory_hits=" << board.memory_hits()
              << " memory_misses=" << board.memory_misses()
              << " register_writes=" << reg.total << "\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render-board-loader failed: " << e.what() << "\n";
    return 1;
  }
}
