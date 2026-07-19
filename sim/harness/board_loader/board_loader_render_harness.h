#pragma once

#include "memory_profile.h"
#include "register_control.h"
#include "wav_writer.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

class Vboard_loader_render_tops;

namespace render {

class BoardLoaderRenderHarness : public VoiceControlSink, private RegisterWriteSink {
 public:
  BoardLoaderRenderHarness(const std::vector<uint8_t>& sd_image, size_t sf2_size_bytes,
                           const std::string& wav_path, int sample_rate,
                           const MemoryProfile& memory_profile);
  ~BoardLoaderRenderHarness() override;

  void load_from_sd();
  void reset_core();
  std::pair<int16_t, int16_t> request_sample(int produced);

  void set_envelope(int voice, int level) override;
  void set_gain(int voice, int gain_l, int gain_r) override;
  void set_phase_inc(int voice, uint32_t phase_inc) override;
  void set_filter(int voice, const FilterConfig& filter) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) override;
  void release_voice(int voice, const Region& r) override;

  const std::vector<uint8_t>& ddr_bytes() const { return ddr_bytes_; }
  uint64_t loader_cycles() const { return loader_cycles_; }
  int nonzero_output_words() const { return int(wav_.nonzero_words()); }
  const RegisterWriteStats& register_write_stats() const { return register_write_stats_; }
  uint64_t memory_responses() const { return memory_responses_; }

 private:
  void reset_loader();
  void init_inputs();
  void write_register(uint16_t address, uint32_t data) override;
  void tick();
  void drive_combinational_inputs();
  void observe_sequential_outputs();
  void handle_sd_command();
  void respond(uint8_t status, uint64_t data);
  uint8_t sector_byte(uint32_t lba, int index) const;
  uint8_t active_data_byte() const;
  void write_mig_beat(uint32_t addr);
  uint16_t word_at(uint32_t word_addr) const;

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
  int active_block_len_ = 512;
  int active_block_index_ = 0;
  int active_block_count_ = 1;
  int predeclared_block_count_ = 0;
  uint8_t current_sd_data_ = 0;
  bool driven_sd_data_valid_ = false;
  uint8_t driven_sd_data_ = 0;
  uint32_t pending_mig_addr_ = 0;
  bool line_pending_ = false;
  uint32_t line_pending_addr_ = 0;
  int line_countdown_ = 0;
  int ready_gap_countdown_ = 0;
  bool have_last_line_addr_ = false;
  uint32_t last_line_addr_ = 0;
  uint64_t total_cycles_ = 0;
  uint64_t loader_cycles_ = 0;
  uint64_t memory_responses_ = 0;
  uint64_t sd_commands_ = 0;
  int last_cmd_ = -1;
};

}  // namespace render
