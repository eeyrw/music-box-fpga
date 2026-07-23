#include "register_control.h"

namespace render {
namespace {

uint32_t pack_pair(int high, int low) {
  return (uint32_t(uint16_t(high)) << 16) | uint32_t(uint16_t(low));
}

}  // namespace

RegisterVoiceControl::RegisterVoiceControl(RegisterWriteSink& registers)
    : registers_(registers) {}

void RegisterWriteSink::write_registers(uint16_t start_address, const std::vector<uint32_t>& data) {
  for (size_t i = 0; i < data.size(); ++i) {
    write_register(uint16_t(start_address + i * 4), data[i]);
  }
}

void RegisterVoiceControl::set_envelope(int voice, int level) {
  registers_.write_register(voice_addr(voice, kRegEnvelopeRuntime), uint32_t(uint16_t(clamp_q15(level))));
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
  registers_.write_register(voice_addr(voice, kRegFilterB0B1), pack_pair(filter.b1, filter.b0));
  registers_.write_register(voice_addr(voice, kRegFilterB2A1), pack_pair(filter.a1, filter.b2));
  registers_.write_register(voice_addr(voice, kRegFilterA2),
                            uint32_t(uint16_t(filter.a2)) | regs::kFilterA2ApplyMask);
}

void RegisterVoiceControl::commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) {
  std::vector<uint32_t> config = {
      r.base_addr,
      r.base_addr_r,
      r.length,
      r.length_r,
      r.loop_start,
      r.loop_start_r,
      r.loop_end,
      r.loop_end_r,
      0,
      phase_inc,
      pack_pair(r.gain_r, r.gain_l),
      uint32_t(uint16_t(clamp_q15(r.initial_envelope))),
      uint32_t(r.filter_enable ? 1 : 0),
      pack_pair(r.filter_b1, r.filter_b0),
      pack_pair(r.filter_a1, r.filter_b2),
      uint32_t(uint16_t(r.filter_a2)),
      uint32_t((r.stereo ? 1 : 0) | ((r.loop_mode & 0x3) << 1)) |
          (enable ? regs::kVoiceControlEnableMask : 0u) |
          regs::kVoiceControlApplyMask,
  };
  registers_.write_registers(voice_addr(voice, kRegBaseAddr), config);
}

void RegisterVoiceControl::release_voice(int voice, const Region& r) {
  (void)r;
  registers_.write_register(voice_addr(voice, kRegReleaseControl), 1);
}

void RegisterVoiceControl::push_envelope_event(const EnvelopeEvent& event) {
  uint32_t data1 = (uint32_t(event.payload0) << 16) |
                   (uint32_t(event.opcode) << 8) |
                   uint32_t(uint8_t(event.voice));
  registers_.write_register(regs::kEventFifoData0, event.timestamp);
  registers_.write_register(regs::kEventFifoData1, data1);
  registers_.write_register(regs::kEventFifoData2, event.payload1);
  registers_.write_register(regs::kEventFifoData3, event.payload2);
  registers_.write_register(regs::kEventFifoPush, 1);
}

}  // namespace render
