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
  r.envelope_tick_samples = 48;
  r.delay_ticks = 2;
  r.attack_ticks = 4;
  r.hold_ticks = 3;
  r.decay_ticks = 5;
  r.release_ticks = 6;
  r.sustain_level = 0x4000;

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
  if (sink.commands[1][3] != 96 || sink.commands[1][5] != 144)
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
  r.attack_sub_tick = true;
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

}  // namespace
}  // namespace render

int main() {
  try {
    render::test_stereo_start_and_runtime_actions();
    render::test_mono_word_count_and_seq_generation();
  } catch (const std::exception& e) {
    std::cerr << "FAIL: " << e.what() << "\n";
    return 1;
  }
  std::cout << "PASS: command control\n";
  return 0;
}
