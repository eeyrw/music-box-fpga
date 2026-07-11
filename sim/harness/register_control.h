#pragma once

#include "render_types.h"

#include <cstdint>

namespace render {

class RegisterWriteSink {
 public:
  virtual ~RegisterWriteSink() = default;
  virtual void write_register(uint16_t address, uint32_t data) = 0;
};

class RegisterVoiceControl : public VoiceControlSink {
 public:
  explicit RegisterVoiceControl(RegisterWriteSink& registers);

  void set_envelope(int voice, int level) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override;
  void release_voice(int voice, const Region& region) override;

 private:
  RegisterWriteSink& registers_;
};

}  // namespace render
