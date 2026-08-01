#include "render_support.h"

#include <algorithm>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {

class CountingSink : public render::VoiceCommandSink {
 public:
  void start_voice(int, uint32_t, const render::Region&) override { ++commands; }
  void update_gain_phase(int, int, int, uint32_t) override { ++commands; }
  void update_filter(int, const render::FilterConfig&) override { ++commands; }
  void release_voice(int, uint32_t) override { ++commands; }
  void stop_voice(int) override { ++commands; }
  uint64_t commands = 0;
};

render::Region benchmark_region() {
  render::Region region;
  region.length = 48000;
  region.loop_end = 48000;
  region.loop_mode = 1;
  region.phase_inc = render::kPhaseFracScale;
  region.base_gain = 0x5000;
  region.gain_l = 0x3000;
  region.gain_r = 0x3000;
  region.initial_filter_fc = 7200;
  region.initial_filter_q = 120;
  region.output_sample_rate = 48000;
  region.mod_lfo_step = 977;
  region.vib_lfo_step = 1301;
  region.mod_lfo_to_pitch = 30;
  region.vib_lfo_to_pitch = 20;
  region.mod_lfo_to_filter_fc = 600;
  region.mod_lfo_to_volume = 40;
  region.mod_env_to_pitch = 25;
  region.mod_env_to_filter_fc = 1200;
  region.mod_env_attack_ticks = 20;
  region.mod_env_decay_ticks = 40;
  region.mod_env_release_ticks = 80;
  region.mod_env_sustain_level = 0x5000;
  region.modulators_by_destination[0] = {
      {0x020e, 0, 12700, 0x0010, 0}};
  region.modulators_by_destination[5] = {
      {0x0081, 5, 50, 0, 0}};
  region.modulators_by_destination[8] = {
      {0x0102, 8, -2400, 0, 0}};
  region.modulators_by_destination[13] = {
      {0x0081, 13, 80, 0, 0}};
  region.modulators_by_destination[17] = {
      {0x028a, 17, 500, 0, 0}};
  region.modulators_by_destination[48] = {
      {0x0502, 48, 960, 0, 0}, {0x0587, 48, 960, 0, 0},
      {0x058b, 48, 960, 0, 0}};
  return region;
}

void run_case(int voice_count) {
  CountingSink sink;
  render::RenderDiagnostics diagnostics;
  std::vector<render::Region> regions{benchmark_region()};
  render::McuModel mcu(sink, regions, &diagnostics, {1, 1, 4});
  for (int voice = 0; voice < voice_count; ++voice) {
    render::NoteEvent note;
    note.on = true;
    note.channel = voice & 0x0f;
    note.note = 24 + voice % 88;
    note.velocity = 32 + voice % 96;
    note.phase_inc = render::kPhaseFracScale + uint32_t(voice % 12) * 16u;
    mcu.handle_event(note);
  }
  for (int tick = 0; tick < 20; ++tick) mcu.control_tick();
  diagnostics = {};
  sink.commands = 0;
  for (int tick = 0; tick < 200; ++tick) {
    if ((tick % 10) == 0) {
      render::NoteEvent modulation;
      modulation.type = render::NoteEvent::EVENT_CONTROL;
      modulation.channel = tick / 10;
      modulation.controller = 1;
      modulation.value = (tick * 7) & 0x7f;
      mcu.handle_event(modulation);
    }
    if ((tick % 25) == 0) {
      render::NoteEvent volume;
      volume.type = render::NoteEvent::EVENT_CONTROL;
      volume.channel = tick / 25;
      volume.controller = 7;
      volume.value = 64 + (tick & 31);
      mcu.handle_event(volume);
    }
    mcu.control_tick();
  }
  const uint64_t average_ns = diagnostics.control_tick_count == 0 ? 0 :
      diagnostics.control_tick_total_ns / diagnostics.control_tick_count;
  std::cout << "{\"voices\":" << voice_count
            << ",\"ticks\":" << diagnostics.control_tick_count
            << ",\"average_tick_ns\":" << average_ns
            << ",\"max_tick_ns\":" << diagnostics.control_tick_max_ns
            << ",\"modulator_evaluations\":"
            << diagnostics.control_modulator_evaluations
            << ",\"dirty_groups\":"
            << diagnostics.control_dirty_group_evaluations
            << ",\"emitted_commands\":"
            << diagnostics.control_emitted_commands << "}\n";
}

}  // namespace

int main() {
  try {
    for (int voices : {128, 256, 512}) {
      if (voices <= render::kNumVoices) run_case(voices);
    }
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "mcu_control_benchmark failed: " << error.what() << '\n';
    return 1;
  }
}
