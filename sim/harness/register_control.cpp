#include "register_control.h"

namespace render {

RegisterVoiceControl::RegisterVoiceControl(RegisterWriteSink& registers)
    : registers_(registers) {}

void RegisterVoiceControl::set_envelope(int voice, int level) {
  registers_.write_register(voice_addr(voice, kRegEnvelopeLevel), uint32_t(uint16_t(clamp_q15(level))));
}

void RegisterVoiceControl::set_gain(int voice, int gain_l, int gain_r) {
  uint32_t left = uint32_t(uint16_t(clamp_q15(gain_l)));
  uint32_t right = uint32_t(uint16_t(clamp_q15(gain_r)));
  registers_.write_register(voice_addr(voice, kRegGainRuntime), (right << 16) | left);
}

void RegisterVoiceControl::set_phase_inc(int voice, uint32_t phase_inc) {
  registers_.write_register(voice_addr(voice, kRegPhaseIncRuntime), phase_inc);
}

void RegisterVoiceControl::set_filter(int voice, const FilterConfig& filter) {
  registers_.write_register(voice_addr(voice, kRegFilterControl), uint32_t(filter.enable ? 1 : 0));
  registers_.write_register(voice_addr(voice, kRegFilterB0), uint32_t(filter.b0));
  registers_.write_register(voice_addr(voice, kRegFilterB1), uint32_t(filter.b1));
  registers_.write_register(voice_addr(voice, kRegFilterB2), uint32_t(filter.b2));
  registers_.write_register(voice_addr(voice, kRegFilterA1), uint32_t(filter.a1));
  registers_.write_register(voice_addr(voice, kRegFilterA2), uint32_t(filter.a2));
  registers_.write_register(voice_addr(voice, kRegFilterCommit), 1);
}

void RegisterVoiceControl::commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) {
  registers_.write_register(voice_addr(voice, kRegControl), uint32_t((r.stereo ? 2 : 0) | (enable ? 1 : 0)));
  registers_.write_register(voice_addr(voice, kRegBaseAddr), r.base_addr);
  registers_.write_register(voice_addr(voice, kRegBaseAddrR), r.base_addr_r);
  registers_.write_register(voice_addr(voice, kRegLength), r.length);
  registers_.write_register(voice_addr(voice, kRegLengthR), r.length_r);
  registers_.write_register(voice_addr(voice, kRegLoopStart), r.loop_start);
  registers_.write_register(voice_addr(voice, kRegLoopStartR), r.loop_start_r);
  registers_.write_register(voice_addr(voice, kRegLoopEnd), r.loop_end);
  registers_.write_register(voice_addr(voice, kRegLoopEndR), r.loop_end_r);
  registers_.write_register(voice_addr(voice, kRegPhaseInit), 0);
  registers_.write_register(voice_addr(voice, kRegPhaseInc), phase_inc);
  registers_.write_register(voice_addr(voice, kRegGainL), uint32_t(uint16_t(r.gain_l)));
  registers_.write_register(voice_addr(voice, kRegGainR), uint32_t(uint16_t(r.gain_r)));
  registers_.write_register(voice_addr(voice, kRegLoopMode), uint32_t(r.loop_mode & 0x3));
  registers_.write_register(voice_addr(voice, kRegFilterControl), uint32_t(r.filter_enable ? 1 : 0));
  registers_.write_register(voice_addr(voice, kRegFilterB0), uint32_t(r.filter_b0));
  registers_.write_register(voice_addr(voice, kRegFilterB1), uint32_t(r.filter_b1));
  registers_.write_register(voice_addr(voice, kRegFilterB2), uint32_t(r.filter_b2));
  registers_.write_register(voice_addr(voice, kRegFilterA1), uint32_t(r.filter_a1));
  registers_.write_register(voice_addr(voice, kRegFilterA2), uint32_t(r.filter_a2));
  registers_.write_register(voice_addr(voice, kRegCommit), 1);
}

void RegisterVoiceControl::release_voice(int voice, const Region& r) {
  (void)r;
  registers_.write_register(voice_addr(voice, kRegReleaseControl), 1);
}

}  // namespace render
