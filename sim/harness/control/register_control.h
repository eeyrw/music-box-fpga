#pragma once

#include "render_types.h"

#include <cstdint>
#include <vector>

namespace render {

class RegisterWriteSink {
 public:
  virtual ~RegisterWriteSink() = default;
  virtual void write_register(uint16_t address, uint32_t data) = 0;
  virtual void write_registers(uint16_t start_address, const std::vector<uint32_t>& data);
};

class RegisterVoiceControl : public VoiceControlSink {
 public:
  explicit RegisterVoiceControl(RegisterWriteSink& registers);

  void set_envelope(int voice, int level) override;
  void set_gain(int voice, int gain_l, int gain_r) override;
  void set_phase_inc(int voice, uint32_t phase_inc) override;
  void set_filter(int voice, const FilterConfig& filter) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override;
  void release_voice(int voice, const Region& region) override;

 private:
  RegisterWriteSink& registers_;
};

}  // namespace render
