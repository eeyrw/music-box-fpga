#include "register_control.h"

namespace render {

RegisterVoiceControl::RegisterVoiceControl(RegisterWriteSink& registers)
    : registers_(registers) {}

void RegisterVoiceControl::set_envelope(int voice, int level) {
  registers_.write_register(voice_addr(voice, 0x2c), uint32_t(uint16_t(clamp_q15(level))));
}

void RegisterVoiceControl::commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) {
  registers_.write_register(voice_addr(voice, 0x00), uint32_t((r.stereo ? 2 : 0) | (enable ? 1 : 0)));
  registers_.write_register(voice_addr(voice, 0x04), r.base_addr);
  registers_.write_register(voice_addr(voice, 0x08), r.length);
  registers_.write_register(voice_addr(voice, 0x0c), r.loop_start);
  registers_.write_register(voice_addr(voice, 0x10), r.loop_end);
  registers_.write_register(voice_addr(voice, 0x14), 0);
  registers_.write_register(voice_addr(voice, 0x18), phase_inc);
  registers_.write_register(voice_addr(voice, 0x1c), uint32_t(uint16_t(r.gain_l)));
  registers_.write_register(voice_addr(voice, 0x20), uint32_t(uint16_t(r.gain_r)));
  registers_.write_register(voice_addr(voice, 0x34), uint32_t(r.loop_mode & 0x3));
  registers_.write_register(voice_addr(voice, 0x24), 1);
}

void RegisterVoiceControl::release_voice(int voice, const Region& r) {
  registers_.write_register(voice_addr(voice, 0x34), uint32_t(0x100 | (r.loop_mode & 0x3)));
}

}  // namespace render
