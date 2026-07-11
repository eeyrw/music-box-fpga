#pragma once

#include "render_types.h"

#include <cstdint>
#include <utility>
#include <vector>

class Vwavetable_core;

namespace render {

class QuickRtlHarness : public VoiceControlSink {
 public:
  explicit QuickRtlHarness(const std::vector<int16_t>& memory);
  ~QuickRtlHarness();

  void reset();
  void set_envelope(int voice, int level) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override;
  void release_voice(int voice, const Region& region) override;
  std::pair<int16_t, int16_t> request_sample(int produced);

 private:
  void bus_write_word(uint16_t address, uint32_t data);
  void tick();
  int16_t read_word(uint32_t address) const;

  Vwavetable_core* top_ = nullptr;
  const std::vector<int16_t>& memory_;
  bool rsp_valid_ = false;
  int16_t rsp_data_ = 0;
};

}  // namespace render
