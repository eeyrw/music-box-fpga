#include "command_control.h"

#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace render {
namespace {

class CaptureSink : public CommandWordSink {
 public:
  void write_command_words(const std::vector<uint32_t>& words) override {
    commands.push_back(words);
  }
  std::vector<std::vector<uint32_t>> commands;
};

uint8_t opcode(const std::vector<uint32_t>& command) {
  return uint8_t(command.at(0) >> 24);
}

void test_stereo_start_and_runtime_actions() {
  CaptureSink sink;
  CommandVoiceControl control(sink);
  Region r;
  r.stereo = true;
  r.base_addr = 0x1234;
  r.base_addr_r = 0x5678;
  r.length = 0x200;
  r.length_r = 0x240;
  r.loop_start = 0x20;
  r.loop_start_r = 0x30;
  r.loop_end = 0x180;
  r.loop_end_r = 0x190;
  r.gain_l = 0x2000;
  r.gain_r = 0x1000;
  r.filter_enable = true;
  r.filter_b0 = 0x2000;
  r.filter_b1 = 0x1000;
  r.filter_b2 = -0x0800;
  r.filter_a1 = -0x0400;
  r.filter_a2 = 0x0200;
  r.loop_mode = 2;
  r.volume_envelope.delay_samples = 96;
  r.volume_envelope.attack_samples = 192;
  r.volume_envelope.hold_samples = 144;
  r.volume_envelope.decay_samples = 240;
  r.volume_envelope.sustain_cb_q12_20 = 60u << 20;
  r.volume_envelope.release_samples = 288;

  control.start_voice(3, 0x00018000, r);
  control.update_gain_phase(3, 0x1111, 0x2222, 0x0001a000);
  FilterConfig filter{true, 0x3000, 0x0100, -0x0200, -0x0300, 0x0400};
  control.update_filter(3, filter);
  control.release_voice(3, 0x12345678);
  control.stop_voice(3);

  if (sink.commands.size() != 5) throw std::runtime_error("wrong command count");
  if (opcode(sink.commands[0]) != 0x11 || sink.commands[0].size() != 16)
    throw std::runtime_error("stereo DEFINE framing mismatch");
  if (opcode(sink.commands[1]) != 0x12 || sink.commands[1].size() != 9)
    throw std::runtime_error("START framing mismatch");
  if (sink.commands[1][3] != 96 || sink.commands[1][4] != 0x01555556u ||
      sink.commands[1][5] != 144 || sink.commands[1][7] != (60u << 20))
    throw std::runtime_error("envelope duration conversion mismatch");
  if (opcode(sink.commands[2]) != 0x16 || sink.commands[2][1] != 0x22221111)
    throw std::runtime_error("GAIN_PHASE packing mismatch");
  if (opcode(sink.commands[3]) != 0x17 || sink.commands[3][3] != 0x00010400)
    throw std::runtime_error("FILTER packing mismatch");
  if (opcode(sink.commands[4]) != 0x14 || sink.commands[4][1] != 0x12345678)
    throw std::runtime_error("RELEASE packing mismatch");
  if (opcode(sink.commands.back()) != 0x14)
    throw std::runtime_error("released voice accepted a later STOP");
}

void test_mono_word_count_and_seq_generation() {
  CaptureSink sink;
  CommandVoiceControl control(sink);
  Region r;
  r.length = 8;
  r.loop_end = 8;
  control.start_voice(0, 0x100, r);
  control.start_voice(0, 0x200, r);
  if (sink.commands.size() != 4 || sink.commands[0].size() != 12 ||
      sink.commands[1].size() != 9)
    throw std::runtime_error("mono Note On must emit 21 words");
  const uint8_t first_seq = uint8_t(sink.commands[0][0] >> 8);
  const uint8_t second_seq = uint8_t(sink.commands[2][0] >> 8);
  if (first_seq == 0 || second_seq != uint8_t(first_seq + 1))
    throw std::runtime_error("voice sequence did not advance");
}

void test_long_envelope_durations_produce_nonzero_steps() {
  CaptureSink sink;
  CommandVoiceControl control(sink);
  Region r;
  r.length = 8;
  r.loop_end = 8;
  r.volume_envelope.attack_samples = 20'318'733;
  r.volume_envelope.decay_samples = 20'318'733;
  r.volume_envelope.sustain_cb_q12_20 = 1000u << 20;
  r.volume_envelope.release_samples = 20'318'733;

  control.start_voice(0, 0x100, r);
  const auto& start = sink.commands.at(1);
  if (start[4] == 0 || start[6] == 0 || start[8] == 0)
    throw std::runtime_error("long envelope duration produced a zero step");
  if (start[4] != 212u || start[6] != 52u || start[8] != 52u)
    throw std::runtime_error("long envelope duration did not use ceiling division");
}

void test_global_audio_commands() {
  CaptureSink sink;
  CommandAudioControl control(sink);
  CompressorCommandConfig config;
  config.enable = true;
  config.threshold_cb_q12_20 = 120u << 20;
  config.ratio_slope_q0_16 = 0x8000;
  config.attack_step_cb_q12_20 = 4u << 20;
  config.release_step_cb_q12_20 = 1u << 20;
  control.configure_compressor(config);
  control.set_master_volume(0x4000);
  ChorusCommandConfig chorus;
  chorus.enable = true;
  chorus.base_delay_q16_8 = 12u << 8;
  chorus.depth_q16_8 = 3u << 8;
  chorus.lfo_phase_inc_q0_32 = 0x12345678;
  chorus.input_send_q1_15 = 0x6000;
  chorus.return_gain_q1_15 = 0x2000;
  chorus.feedback_q1_15 = -0x1000;
  chorus.stereo_phase_offset_q0_32 = 0x40000000;
  control.configure_chorus(chorus);
  ReverbCommandConfig reverb;
  reverb.enable = true;
  reverb.pre_delay_frames = 17;
  reverb.input_send_q1_15 = 0x3000;
  reverb.return_gain_q1_15 = 0x2000;
  reverb.damping_q1_15 = 0x1000;
  reverb.chorus_to_reverb_q1_15 = 0x0800;
  reverb.feedback_gain_q1_15 = {1, 2, 3, 4, 5, 6, 7, 8};
  control.configure_reverb(reverb);
  control.clear_effects(3);

  if (sink.commands.size() != 5 || opcode(sink.commands[0]) != 0x20 ||
      sink.commands[0].size() != 5 || sink.commands[0][1] != 0x00010001 ||
      sink.commands[0][2] != (120u << 20) ||
      sink.commands[0][3] != (4u << 20))
    throw std::runtime_error("COMPRESSOR_CONFIG packing mismatch");
  if (opcode(sink.commands[1]) != 0x21 || sink.commands[1].size() != 2 ||
      sink.commands[1][1] != 0x4000)
    throw std::runtime_error("MASTER_VOLUME packing mismatch");
  if (opcode(sink.commands[2]) != 0x22 || sink.commands[2].size() != 7 ||
      sink.commands[2][1] != 0xf0000001u ||
      sink.commands[2][5] != 0x20006000u)
    throw std::runtime_error("CHORUS_CONFIG packing mismatch");
  if (opcode(sink.commands[3]) != 0x23 || sink.commands[3].size() != 10 ||
      sink.commands[3][1] != 35u || sink.commands[3][6] != 0x00020001u ||
      sink.commands[3][9] != 0x00080007u)
    throw std::runtime_error("REVERB_CONFIG packing mismatch");
  if (opcode(sink.commands[4]) != 0x24 || sink.commands[4][1] != 3u)
    throw std::runtime_error("EFFECT_CLEAR packing mismatch");
}

}  // namespace
}  // namespace render

int main() {
  try {
    render::test_stereo_start_and_runtime_actions();
    render::test_mono_word_count_and_seq_generation();
    render::test_long_envelope_durations_produce_nonzero_steps();
    render::test_global_audio_commands();
  } catch (const std::exception& e) {
    std::cerr << "FAIL: " << e.what() << "\n";
    return 1;
  }
  std::cout << "PASS: command control\n";
  return 0;
}
