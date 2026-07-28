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

void test_mono_start_and_runtime_actions() {
  CaptureSink sink;
  CommandVoiceControl control(sink);
  Region r;
  r.base_addr = 0x1234;
  r.length = 0x200;
  r.loop_start = 0x20;
  r.loop_end = 0x180;
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

  if (sink.commands.size() != 6) throw std::runtime_error("wrong command count");
  if (opcode(sink.commands[0]) != 0x10 || sink.commands[0].size() != 18)
    throw std::runtime_error("mono START framing mismatch");
  if (sink.commands[0][12] != 96 || sink.commands[0][13] != 0x01555556u ||
      sink.commands[0][14] != 144 || sink.commands[0][16] != (60u << 20))
    throw std::runtime_error("envelope duration conversion mismatch");
  if (opcode(sink.commands[1]) != 0x16 || sink.commands[1][2] != 0x22221111)
    throw std::runtime_error("GAIN packing mismatch");
  if (opcode(sink.commands[2]) != 0x18 || sink.commands[2][2] != 0x0001a000)
    throw std::runtime_error("PITCH packing mismatch");
  if (opcode(sink.commands[3]) != 0x17 || sink.commands[3][4] != 0x00010400)
    throw std::runtime_error("FILTER packing mismatch");
  if (opcode(sink.commands[4]) != 0x14 || sink.commands[4][2] != 0x12345678)
    throw std::runtime_error("RELEASE packing mismatch");
  if (opcode(sink.commands[5]) != 0x15)
    throw std::runtime_error("released voice did not accept STOP");
}

void test_mono_word_count_and_generation() {
  CaptureSink sink;
  CommandVoiceControl control(sink);
  Region r;
  r.length = 8;
  r.loop_end = 8;
  control.start_voice(0, 0x100, r);
  control.start_voice(0, 0x200, r);
  if (sink.commands.size() != 2 || sink.commands[0].size() != 18 ||
      sink.commands[1].size() != 18)
    throw std::runtime_error("mono Note On must emit one 18-word command");
  const uint16_t first_generation = uint16_t(sink.commands[0][1]);
  const uint16_t second_generation = uint16_t(sink.commands[1][1]);
  if (first_generation == 0 || second_generation != uint16_t(first_generation + 1))
    throw std::runtime_error("voice generation did not advance");
}

void test_stereo_region_is_rejected() {
  CaptureSink sink;
  CommandVoiceControl control(sink);
  Region r;
  r.stereo = true;
  r.length = 8;
  r.loop_end = 8;
  try {
    control.start_voice(0, 0x100, r);
  } catch (const std::invalid_argument&) {
    return;
  }
  throw std::runtime_error("stereo Region reached mono command protocol");
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
  const auto& start = sink.commands.at(0);
  if (start[13] == 0 || start[15] == 0 || start[17] == 0)
    throw std::runtime_error("long envelope duration produced a zero step");
  if (start[13] != 212u || start[15] != 52u || start[17] != 52u)
    throw std::runtime_error("long envelope duration did not use ceiling division");
}

void test_redundant_start_runtime_actions_are_suppressed() {
  CaptureSink sink;
  CommandVoiceControl control(sink);
  Region r;
  r.length = 8;
  r.loop_end = 8;
  r.gain_l = 0x1234;
  r.gain_r = 0x2345;
  r.filter_enable = true;
  r.filter_b0 = 0x3000;
  r.filter_b1 = 0x0100;
  r.filter_b2 = -0x0200;
  r.filter_a1 = -0x0300;
  r.filter_a2 = 0x0400;
  const uint32_t phase_inc = 0x180;

  control.start_voice(0, phase_inc, r);
  control.update_gain_phase(0, r.gain_l, r.gain_r, phase_inc);
  control.update_filter(0, {r.filter_enable, r.filter_b0, r.filter_b1,
                            r.filter_b2, r.filter_a1, r.filter_a2});
  if (sink.commands.size() != 1) {
    throw std::runtime_error("START-equivalent runtime commands were not suppressed");
  }

  control.update_gain_phase(0, r.gain_l + 1, r.gain_r, phase_inc);
  FilterConfig changed{r.filter_enable, r.filter_b0 + 1, r.filter_b1,
                       r.filter_b2, r.filter_a1, r.filter_a2};
  control.update_filter(0, changed);
  if (sink.commands.size() != 3 || opcode(sink.commands[1]) != 0x16 ||
      opcode(sink.commands[2]) != 0x17) {
    throw std::runtime_error("changed runtime commands were suppressed");
  }
}

void test_frame_batched_command_sink() {
  CaptureSink sink;
  FrameBatchedCommandSink batched(sink);
  for (uint32_t index = 0; index < 18; ++index) {
    batched.write_command_words({0x15000000u | index});
  }
  if (batched.pending_actions() != 18 || batched.max_pending_actions() != 18 ||
      batched.total_enqueued_actions() != 18) {
    throw std::runtime_error("frame batch enqueue diagnostics mismatch");
  }
  if (batched.apply_frame() != 16 || sink.commands.size() != 16 ||
      batched.pending_actions() != 2 || batched.max_deferred_frames() != 0) {
    throw std::runtime_error("first frame did not apply exactly 16 actions");
  }
  if (batched.apply_frame() != 2 || sink.commands.size() != 18 ||
      batched.pending_actions() != 0 || batched.max_deferred_frames() != 1 ||
      batched.total_applied_actions() != 18) {
    throw std::runtime_error("deferred action batch diagnostics mismatch");
  }

  CaptureSink flush_sink;
  FrameBatchedCommandSink flush_batch(flush_sink);
  flush_batch.write_command_words({0x15000000u});
  flush_batch.write_command_words({0x7f000000u});
  flush_batch.write_command_words({0x15000000u});
  if (flush_batch.apply_frame() != 2 || flush_batch.pending_actions() != 0 ||
      flush_sink.commands.size() != 2 || opcode(flush_sink.commands.back()) != 0x7f) {
    throw std::runtime_error("STREAM_FLUSH did not discard deferred actions");
  }
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
    render::test_mono_start_and_runtime_actions();
    render::test_mono_word_count_and_generation();
    render::test_stereo_region_is_rejected();
    render::test_long_envelope_durations_produce_nonzero_steps();
    render::test_redundant_start_runtime_actions_are_suppressed();
    render::test_frame_batched_command_sink();
    render::test_global_audio_commands();
  } catch (const std::exception& e) {
    std::cerr << "FAIL: " << e.what() << "\n";
    return 1;
  }
  std::cout << "PASS: command control\n";
  return 0;
}
