#include "host/mcu_sf2_asset_runtime.h"

#include "mcu/msf2.h"

#include "sim/harness/formats/sf2_loader.h"

#include <filesystem>
#include <cstdlib>
#include <stdexcept>
#include <vector>

namespace {

class RecordingSink final : public render::CommandWordSink {
 public:
  void write_command_words(render::CommandWordView words) override {
    render::FixedCommand command;
    for (uint32_t word : words) command.push_back(word);
    commands.push_back(command);
  }
  std::vector<render::FixedCommand> commands;
};

int record_c_command(void* context, const uint32_t* words, uint8_t word_count) {
  auto& sink = *static_cast<RecordingSink*>(context);
  render::FixedCommand command;
  for (uint8_t index = 0; index < word_count; ++index) command.push_back(words[index]);
  sink.commands.push_back(command);
  return 0;
}

void require_same_command_shape(const RecordingSink& expected,
                                const RecordingSink& actual,
                                const char* stage) {
  if (expected.commands.size() != actual.commands.size()) {
    throw std::runtime_error(std::string(stage) + " pure-C command count mismatch: " +
                             std::to_string(expected.commands.size()) + " != " +
                             std::to_string(actual.commands.size()));
  }
  for (size_t index = 0; index < expected.commands.size(); ++index) {
    const auto& a = expected.commands[index];
    const auto& b = actual.commands[index];
    if (a.length != b.length || (a.words[0] >> 24) != (b.words[0] >> 24) ||
        ((a.words[0] >> 14) & 0x3ffu) != ((b.words[0] >> 14) & 0x3ffu) ||
        a.words[1] != b.words[1]) {
      throw std::runtime_error(std::string(stage) +
                               " pure-C command framing/lifecycle mismatch at " +
                               std::to_string(index));
    }
    const uint8_t command_opcode = uint8_t(a.words[0] >> 24);
    const auto close_u16_pair = [](uint32_t left, uint32_t right) {
      return std::abs(int64_t(uint16_t(left)) - uint16_t(right)) <= 1 &&
             std::abs(int64_t(uint16_t(left >> 16)) - uint16_t(right >> 16)) <= 1;
    };
    const auto close_s16_pair = [](uint32_t left, uint32_t right) {
      return std::abs(int64_t(int16_t(left)) - int16_t(right)) <= 1 &&
             std::abs(int64_t(int16_t(left >> 16)) - int16_t(right >> 16)) <= 1;
    };
    bool numeric_ok = true;
    if (command_opcode == 0x10) {
      numeric_ok = a.words[0] == b.words[0] && a.words[2] == b.words[2] &&
                   a.words[3] == b.words[3];
      size_t word = 4;
      const uint8_t flags = uint8_t((a.words[0] >> 8) & 0x3fu);
      if ((flags & 0x03u) != 0u) {
        numeric_ok = numeric_ok && a.words[word] == b.words[word] &&
                     a.words[word + 1] == b.words[word + 1];
        word += 2;
      }
      numeric_ok = numeric_ok &&
                   std::abs(int64_t(a.words[word]) - b.words[word]) <= 1;
      ++word;
      numeric_ok = numeric_ok && close_u16_pair(a.words[word], b.words[word]);
      ++word;
      if ((flags & 0x04u) != 0u) {
        numeric_ok = numeric_ok &&
                     close_s16_pair(a.words[word], b.words[word]) &&
                     close_s16_pair(a.words[word + 1], b.words[word + 1]) &&
                     std::abs(int64_t(int16_t(a.words[word + 2])) -
                              int16_t(b.words[word + 2])) <= 1 &&
                     ((a.words[word + 2] ^ b.words[word + 2]) &
                      0x00010000u) == 0;
        word += 3;
      }
      while (numeric_ok && word < a.length) {
        numeric_ok = a.words[word] == b.words[word];
        ++word;
      }
    } else if (command_opcode == 0x18) {
      numeric_ok = std::abs(int64_t(a.words[2]) - b.words[2]) <= 1;
    } else if (command_opcode == 0x16) {
      numeric_ok = close_u16_pair(a.words[2], b.words[2]);
    } else if (command_opcode == 0x17) {
      numeric_ok = close_s16_pair(a.words[2], b.words[2]) &&
                   close_s16_pair(a.words[3], b.words[3]) &&
                   std::abs(int64_t(int16_t(a.words[4])) - int16_t(b.words[4])) <= 1 &&
                   ((a.words[4] ^ b.words[4]) & 0x00010000u) == 0;
    }
    if (!numeric_ok) {
      throw std::runtime_error(std::string(stage) +
                               " pure-C runtime numeric error exceeds one LSB at " +
                               std::to_string(index));
    }
  }
}

uint8_t opcode(const render::FixedCommand& command) {
  return uint8_t(command.words[0] >> 24);
}

struct PlayableCell {
  uint16_t program = 0;
  uint16_t bank = 0;
  uint8_t key = 0;
  uint8_t velocity = 100;
};

PlayableCell first_playable(const render::McuSf2AssetView& view) {
  const int32_t piano_index = view.find_preset(0, 0);
  if (piano_index >= 0) {
    const auto piano = view.preset(size_t(piano_index));
    for (uint32_t local = 0; local < piano.zone_count; ++local) {
      const auto zone = view.zone(piano.first_zone + local);
      if (60 >= zone.key_low && 60 <= zone.key_high &&
          100 >= zone.velocity_low && 100 <= zone.velocity_high) {
        return {0, 0, 60, 100};
      }
    }
  }
  for (size_t preset_index = 0; preset_index < view.preset_count(); ++preset_index) {
    const auto preset = view.preset(preset_index);
    for (int key = 0; key < 128; ++key) {
      for (uint32_t local = 0; local < preset.zone_count; ++local) {
        const auto zone = view.zone(preset.first_zone + local);
        if (key >= zone.key_low && key <= zone.key_high &&
            100 >= zone.velocity_low && 100 <= zone.velocity_high) {
          return {preset.program, preset.bank, uint8_t(key), 100};
        }
      }
    }
  }
  throw std::runtime_error("fixture contains no playable MCU asset cell");
}

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) throw std::runtime_error("expected SF2 fixture path");
  render::Sf2Data sf2 = render::load_sf2(argv[1]);
  const auto image = render::build_mcu_sf2_asset(
      sf2, std::filesystem::file_size(argv[1]));
  const render::McuSf2AssetView view(image.data(), image.size());
  const PlayableCell cell = first_playable(view);

  RecordingSink sink;
  host::McuSf2AssetRuntime runtime(view, sink, 8);
  msf2_view c_view{};
  msf2_runtime c_runtime{};
  std::array<msf2_channel_state, MSF2_CHANNEL_COUNT> c_channels{};
  std::array<msf2_voice_state, 8> c_voices{};
  std::array<uint16_t, 8> c_free_stack{};
  RecordingSink c_sink;
  require(msf2_view_init(&c_view, image.data(), image.size()) == MSF2_OK &&
              msf2_runtime_init(&c_runtime, &c_view, c_channels.data(),
                                c_voices.data(), c_free_stack.data(),
                                uint16_t(c_voices.size()), record_c_command,
                                &c_sink) == MSF2_OK,
          "pure-C runtime initialization failed");
  const uint16_t layers = runtime.note_on(
      0, cell.program, cell.bank, cell.key, cell.velocity);
  uint8_t c_layers = 0;
  require(msf2_runtime_note_on(&c_runtime, 0, cell.program, cell.bank, cell.key,
                               cell.velocity, &c_layers) == MSF2_OK &&
              c_layers == layers,
          "pure-C Note On layer count mismatch");
  require_same_command_shape(sink, c_sink, "Note On");
  require(layers != 0 && !sink.commands.empty() && opcode(sink.commands.front()) == 0x10,
          "compiled runtime did not emit START first");
  require(sink.commands.size() == layers && c_sink.commands.size() == layers,
          "Note On emitted a control update before START installation");
  std::array<uint16_t, render::kNumVoices> first_generations{};
  uint16_t first_start_count = 0;
  for (const auto& command : sink.commands) {
    if (opcode(command) != 0x10) continue;
    const uint16_t voice = uint16_t((command.words[0] >> 14) & 0x3ffu);
    first_generations[voice] = uint16_t(command.words[1]);
    require(first_generations[voice] == 1, "first START generation is not one");
    ++first_start_count;
  }
  require(first_start_count == layers, "initial START count does not match layers");

  const size_t before_controller = sink.commands.size();
  const size_t c_before_controller = c_sink.commands.size();
  runtime.control_change(0, 7, 0);
  require(msf2_runtime_control_change(&c_runtime, 0, 7, 0) == MSF2_OK,
          "pure-C CC7 failed");
  require(c_sink.commands.size() == c_before_controller,
          "pure-C CC7 performed synchronous voice/SPI work");
  bool saw_gain = false;
  for (size_t index = before_controller; index < sink.commands.size(); ++index) {
    saw_gain |= opcode(sink.commands[index]) == 0x16;
  }
  require(saw_gain, "CC7 did not update active compiled voices");
  require(msf2_runtime_advance_samples(&c_runtime, 48) == MSF2_OK,
          "pure-C deferred CC7 tick failed");
  bool c_saw_gain = false;
  for (size_t index = c_before_controller; index < c_sink.commands.size(); ++index) {
    c_saw_gain |= opcode(c_sink.commands[index]) == 0x16;
  }
  require(c_saw_gain, "pure-C deferred CC7 did not emit gain on the next tick");
  runtime.advance_samples(48);

  const size_t c_before_pitch = c_sink.commands.size();
  runtime.pitch_bend(0, 4096);
  require(msf2_runtime_pitch_bend(&c_runtime, 0, 4096) == MSF2_OK,
          "pure-C pitch bend failed");
  require(c_sink.commands.size() == c_before_pitch,
          "pure-C pitch bend performed synchronous voice/SPI work");
  runtime.channel_pressure(0, 73);
  require(msf2_runtime_channel_pressure(&c_runtime, 0, 73) == MSF2_OK,
          "pure-C channel pressure failed");
  require(c_sink.commands.size() == c_before_pitch,
          "pure-C channel pressure performed synchronous voice/SPI work");
  runtime.key_pressure(0, cell.key, 51);
  require(msf2_runtime_key_pressure(&c_runtime, 0, cell.key, 51) == MSF2_OK,
          "pure-C key pressure failed");
  require(c_sink.commands.size() == c_before_pitch,
          "pure-C key pressure performed synchronous voice/SPI work");
  for (int tick = 0; tick < 4; ++tick) {
    runtime.advance_samples(48);
    require(msf2_runtime_advance_samples(&c_runtime, 48) == MSF2_OK,
            "pure-C modulation tick failed");
  }
  sink.commands.clear();
  c_sink.commands.clear();

  runtime.control_change(0, 64, 127);
  require(msf2_runtime_control_change(&c_runtime, 0, 64, 127) == MSF2_OK,
          "pure-C sustain-on failed");
  const size_t before_sustain_note_off = sink.commands.size();
  runtime.note_off(0, cell.key);
  require(msf2_runtime_note_off(&c_runtime, 0, cell.key) == MSF2_OK,
          "pure-C sustained Note Off failed");
  require(sink.commands.size() == before_sustain_note_off,
          "sustain-held Note Off emitted a release");
  runtime.control_change(0, 64, 0);
  require(msf2_runtime_control_change(&c_runtime, 0, 64, 0) == MSF2_OK,
          "pure-C sustain release failed");
  require_same_command_shape(sink, c_sink, "sustain release");
  require(sink.commands.size() > before_sustain_note_off,
          "sustain release did not emit a lifecycle command");
  runtime.advance_samples(UINT32_MAX);
  require(msf2_runtime_advance_samples(&c_runtime, UINT32_MAX) == MSF2_OK,
          "pure-C release reclamation failed");
  for (uint16_t voice = 0; voice < render::kNumVoices; ++voice) {
    if (first_generations[voice] == 0) continue;
    runtime.complete_voice(voice);
    require(msf2_runtime_complete_voice(&c_runtime, voice) == MSF2_OK,
            "pure-C FPGA completion reconciliation failed");
  }

  sink.commands.clear();
  c_sink.commands.clear();
  runtime.control_change(0, 7, 127);
  require(msf2_runtime_control_change(&c_runtime, 0, 7, 127) == MSF2_OK,
          "pure-C CC7 reset failed");
  runtime.note_on(0, cell.program, cell.bank, cell.key, cell.velocity);
  require(msf2_runtime_note_on(&c_runtime, 0, cell.program, cell.bank, cell.key,
                               cell.velocity, &c_layers) == MSF2_OK,
          "pure-C reused Note On failed");
  require_same_command_shape(sink, c_sink, "reused Note On");
  require(!sink.commands.empty() && opcode(sink.commands.front()) == 0x10,
          "reused compiled voice did not emit START");
  uint16_t reused_start_count = 0;
  for (const auto& command : sink.commands) {
    if (opcode(command) != 0x10) continue;
    const uint16_t voice = uint16_t((command.words[0] >> 14) & 0x3ffu);
    require(first_generations[voice] != 0 &&
                command.words[1] == uint32_t(first_generations[voice] + 1u),
            "reused voice generation did not advance");
    ++reused_start_count;
  }
  require(reused_start_count == layers, "reused START count does not match layers");

  RecordingSink steal_sink;
  host::McuSf2AssetRuntime one_voice(view, steal_sink, 1);
  one_voice.note_on(0, cell.program, cell.bank, cell.key, cell.velocity);
  one_voice.note_on(0, cell.program, cell.bank, cell.key, cell.velocity);
  bool saw_stop = false;
  for (const auto& command : steal_sink.commands) saw_stop |= opcode(command) == 0x15;
  require(!saw_stop && one_voice.stats().stolen_voices != 0,
          "fixed allocator did not atomically replace a stolen voice");

  msf2_runtime c_one_voice{};
  std::array<msf2_channel_state, MSF2_CHANNEL_COUNT> c_one_channels{};
  std::array<msf2_voice_state, 1> c_one_voices{};
  std::array<uint16_t, 1> c_one_free{};
  RecordingSink c_steal_sink;
  require(msf2_runtime_init(&c_one_voice, &c_view, c_one_channels.data(),
                            c_one_voices.data(), c_one_free.data(), 1,
                            record_c_command, &c_steal_sink) == MSF2_OK &&
              msf2_runtime_note_on(&c_one_voice, 0, cell.program, cell.bank,
                                   cell.key, cell.velocity, &c_layers) == MSF2_OK &&
              msf2_runtime_note_on(&c_one_voice, 0, cell.program, cell.bank,
                                   cell.key, cell.velocity, &c_layers) == MSF2_OK &&
              c_one_voice.stats.stolen_voices != 0,
          "pure-C fixed allocator did not use the bounded steal path");

  msf2_runtime c_tick_runtime{};
  std::array<msf2_channel_state, MSF2_CHANNEL_COUNT> c_tick_channels{};
  std::array<msf2_voice_state, 1> c_tick_voices{};
  std::array<uint16_t, 1> c_tick_free{};
  RecordingSink c_tick_sink;
  require(msf2_runtime_init(&c_tick_runtime, &c_view, c_tick_channels.data(),
                            c_tick_voices.data(), c_tick_free.data(), 1,
                            record_c_command, &c_tick_sink) == MSF2_OK &&
              msf2_runtime_advance_samples(&c_tick_runtime, 47) == MSF2_OK &&
              c_tick_runtime.control_tick_index == 0 &&
              msf2_runtime_advance_samples(&c_tick_runtime, 1) == MSF2_OK &&
              c_tick_runtime.control_tick_index == 1,
          "pure-C sample accumulator did not produce one 1 ms control tick");

  msf2_runtime c_bulk_runtime{};
  msf2_runtime c_step_runtime{};
  std::array<msf2_channel_state, MSF2_CHANNEL_COUNT> c_bulk_channels{};
  std::array<msf2_channel_state, MSF2_CHANNEL_COUNT> c_step_channels{};
  std::array<msf2_voice_state, 4> c_bulk_voices{};
  std::array<msf2_voice_state, 4> c_step_voices{};
  std::array<uint16_t, 4> c_bulk_free{};
  std::array<uint16_t, 4> c_step_free{};
  RecordingSink c_bulk_sink;
  RecordingSink c_step_sink;
  require(msf2_runtime_init(&c_bulk_runtime, &c_view, c_bulk_channels.data(),
                            c_bulk_voices.data(), c_bulk_free.data(), 4,
                            record_c_command, &c_bulk_sink) == MSF2_OK &&
              msf2_runtime_init(&c_step_runtime, &c_view, c_step_channels.data(),
                                c_step_voices.data(), c_step_free.data(), 4,
                                record_c_command, &c_step_sink) == MSF2_OK &&
              msf2_runtime_note_on(&c_bulk_runtime, 0, cell.program, cell.bank,
                                   cell.key, cell.velocity, &c_layers) == MSF2_OK &&
              msf2_runtime_note_on(&c_step_runtime, 0, cell.program, cell.bank,
                                   cell.key, cell.velocity, &c_layers) == MSF2_OK,
          "elapsed-control equivalence setup failed");
  require(c_bulk_runtime.active_count == c_step_runtime.active_count &&
              c_bulk_runtime.active_count != 0,
          "elapsed-control equivalence layer mismatch");
  for (uint16_t position = 0; position < c_bulk_runtime.active_count; ++position) {
    auto& bulk_voice = c_bulk_voices[c_bulk_runtime.active_voice_indices[position]];
    auto& step_voice = c_step_voices[c_step_runtime.active_voice_indices[position]];
    bulk_voice.periodic_groups = MSF2_CONTROL_GROUP_ALL;
    bulk_voice.mod_lfo_phase = 1000;
    bulk_voice.vib_lfo_phase = 2000;
    bulk_voice.mod_lfo_wait_ticks = 3;
    bulk_voice.vib_lfo_wait_ticks = 5;
    bulk_voice.config.mod_lfo_step = 12345;
    bulk_voice.config.vib_lfo_step = 54321;
    bulk_voice.mod_env_stage = 1;
    bulk_voice.mod_env_stage_tick = 0;
    bulk_voice.mod_env_wait_ticks = 2;
    bulk_voice.mod_env_level = 0;
    bulk_voice.config.mod_env_attack_ticks = 3;
    bulk_voice.config.mod_env_hold_ticks = 2;
    bulk_voice.config.mod_env_decay_ticks = 4;
    bulk_voice.config.mod_env_sustain_level = 12000;
    step_voice = bulk_voice;
  }
  require(msf2_runtime_advance_control(&c_bulk_runtime, 17) == MSF2_OK,
          "bulk elapsed-control advance failed");
  for (int tick = 0; tick < 17; ++tick) {
    require(msf2_runtime_advance_control(&c_step_runtime, 1) == MSF2_OK,
            "single-step elapsed-control advance failed");
  }
  for (uint16_t position = 0; position < c_bulk_runtime.active_count; ++position) {
    const auto& bulk_voice =
        c_bulk_voices[c_bulk_runtime.active_voice_indices[position]];
    const auto& step_voice =
        c_step_voices[c_step_runtime.active_voice_indices[position]];
    require(bulk_voice.mod_lfo_phase == step_voice.mod_lfo_phase &&
                bulk_voice.vib_lfo_phase == step_voice.vib_lfo_phase &&
                bulk_voice.mod_lfo_wait_ticks == step_voice.mod_lfo_wait_ticks &&
                bulk_voice.vib_lfo_wait_ticks == step_voice.vib_lfo_wait_ticks &&
                bulk_voice.mod_env_stage == step_voice.mod_env_stage &&
                bulk_voice.mod_env_stage_tick == step_voice.mod_env_stage_tick &&
                bulk_voice.mod_env_wait_ticks == step_voice.mod_env_wait_ticks &&
                bulk_voice.mod_env_level == step_voice.mod_env_level &&
                bulk_voice.phase_increment == step_voice.phase_increment &&
                bulk_voice.gain_l == step_voice.gain_l &&
                bulk_voice.gain_r == step_voice.gain_r &&
                bulk_voice.filter_enable == step_voice.filter_enable &&
                bulk_voice.filter_b0 == step_voice.filter_b0 &&
                bulk_voice.filter_b1 == step_voice.filter_b1 &&
                bulk_voice.filter_b2 == step_voice.filter_b2 &&
                bulk_voice.filter_a1 == step_voice.filter_a1 &&
                bulk_voice.filter_a2 == step_voice.filter_a2,
            "bulk elapsed-control state differs from repeated single ticks");
  }
  require(c_bulk_runtime.control_tick_index == c_step_runtime.control_tick_index,
          "bulk elapsed-control tick index differs from repeated single ticks");
  for (uint16_t position = 0; position < c_bulk_runtime.active_count; ++position) {
    auto& bulk_voice = c_bulk_voices[c_bulk_runtime.active_voice_indices[position]];
    auto& step_voice = c_step_voices[c_step_runtime.active_voice_indices[position]];
    bulk_voice.mod_env_stage = 6;
    bulk_voice.mod_env_stage_tick = 0;
    bulk_voice.mod_env_release_start = 20000;
    bulk_voice.mod_env_level = 20000;
    bulk_voice.config.mod_env_release_ticks = 7;
    step_voice = bulk_voice;
  }
  require(msf2_runtime_advance_control(&c_bulk_runtime, 12) == MSF2_OK,
          "bulk release-envelope advance failed");
  for (int tick = 0; tick < 12; ++tick) {
    require(msf2_runtime_advance_control(&c_step_runtime, 1) == MSF2_OK,
            "single-step release-envelope advance failed");
  }
  for (uint16_t position = 0; position < c_bulk_runtime.active_count; ++position) {
    const auto& bulk_voice =
        c_bulk_voices[c_bulk_runtime.active_voice_indices[position]];
    const auto& step_voice =
        c_step_voices[c_step_runtime.active_voice_indices[position]];
    require(bulk_voice.mod_env_stage == step_voice.mod_env_stage &&
                bulk_voice.mod_env_stage_tick == step_voice.mod_env_stage_tick &&
                bulk_voice.mod_env_level == step_voice.mod_env_level &&
                bulk_voice.mod_lfo_phase == step_voice.mod_lfo_phase &&
                bulk_voice.vib_lfo_phase == step_voice.vib_lfo_phase,
            "bulk release-envelope state differs from repeated single ticks");
  }

  msf2_runtime c_active_runtime{};
  std::array<msf2_channel_state, MSF2_CHANNEL_COUNT> c_active_channels{};
  std::array<msf2_voice_state, 4> c_active_voices{};
  std::array<uint16_t, 4> c_active_free{};
  RecordingSink c_active_sink;
  require(msf2_runtime_init(&c_active_runtime, &c_view, c_active_channels.data(),
                            c_active_voices.data(), c_active_free.data(), 4,
                            record_c_command, &c_active_sink) == MSF2_OK &&
              msf2_runtime_note_on(&c_active_runtime, 0, cell.program, cell.bank,
                                   cell.key, cell.velocity, &c_layers) == MSF2_OK &&
              c_active_runtime.active_count == c_layers,
          "pure-C runtime did not populate the dense active-voice index");
  for (uint16_t position = 0; position < c_active_runtime.active_count;
       ++position) {
    const uint16_t voice = c_active_runtime.active_voice_indices[position];
    require(voice < c_active_runtime.voice_capacity &&
                c_active_voices[voice].stage != MSF2_VOICE_FREE &&
                c_active_voices[voice].active_position == position,
            "dense active-voice index lost its reverse position");
    c_active_voices[voice].periodic_groups = 0;
  }
  const uint32_t evaluations_before_static =
      c_active_runtime.stats.control_voice_evaluations;
  require(msf2_runtime_advance_control(&c_active_runtime, 5u) == MSF2_OK &&
              c_active_runtime.stats.control_voice_evaluations ==
                  evaluations_before_static,
          "static voices performed periodic modulation evaluation");
  require(msf2_runtime_control_change(&c_active_runtime, 0, 7, 64) == MSF2_OK &&
              c_active_channels[0].dirty_groups == MSF2_CONTROL_GROUP_ALL &&
              msf2_runtime_advance_control(&c_active_runtime, 5u) == MSF2_OK &&
              c_active_runtime.stats.control_voice_evaluations ==
                  evaluations_before_static + c_active_runtime.active_count &&
              c_active_channels[0].dirty_groups == 0,
          "controller dirty groups did not produce exactly one channel refresh");
  for (uint16_t position = 0; position < c_active_runtime.active_count;
       ++position) {
    const uint16_t voice = c_active_runtime.active_voice_indices[position];
    c_active_voices[voice].periodic_groups = MSF2_CONTROL_GROUP_GAIN;
  }
  std::array<msf2_control_voice_snapshot, 4> control_snapshot{};
  std::array<uint32_t, MSF2_CHANNEL_COUNT> dirty_revisions{};
  const uint32_t evaluations_before_periodic =
      c_active_runtime.stats.control_voice_evaluations;
  msf2_runtime_capture_control_snapshot(
      &c_active_runtime, control_snapshot.data(), dirty_revisions.data());
  require(msf2_runtime_advance_control_slice(
              &c_active_runtime, control_snapshot.data(), 0u, 2u, 5u) ==
              MSF2_OK &&
              msf2_runtime_control_change(&c_active_runtime, 0, 7, 65) ==
                  MSF2_OK &&
              msf2_runtime_advance_control_slice(
                  &c_active_runtime, control_snapshot.data(), 2u, 2u, 5u) ==
                  MSF2_OK,
          "split control update failed");
  msf2_runtime_complete_control(&c_active_runtime, 5u,
                                dirty_revisions.data());
  require(c_active_runtime.stats.control_voice_evaluations ==
                  evaluations_before_periodic + c_active_runtime.active_count &&
              c_active_runtime.control_tick_index == 15 &&
              c_active_channels[0].dirty_groups == MSF2_CONTROL_GROUP_ALL,
          "split control update lost a concurrent controller change");
  const uint32_t evaluations_before_dirty_catchup =
      c_active_runtime.stats.control_voice_evaluations;
  require(msf2_runtime_advance_control(&c_active_runtime, 5u) == MSF2_OK &&
              c_active_runtime.stats.control_voice_evaluations ==
                  evaluations_before_dirty_catchup +
                      c_active_runtime.active_count &&
              c_active_runtime.control_tick_index == 20 &&
              c_active_channels[0].dirty_groups == 0,
          "control update did not catch up a concurrent controller change");

  msf2_runtime_capture_control_snapshot(
      &c_active_runtime, control_snapshot.data(), dirty_revisions.data());
  require(msf2_runtime_all_sound_off(&c_active_runtime, 0) == MSF2_OK,
          "voice reuse STOP setup failed");
  for (uint16_t voice = 0; voice < c_active_runtime.voice_capacity; ++voice) {
    if (c_active_voices[voice].stage != MSF2_VOICE_FREE) {
      require(msf2_runtime_complete_voice(&c_active_runtime, voice) == MSF2_OK,
              "voice reuse FPGA completion setup failed");
    }
  }
  require(msf2_runtime_note_on(&c_active_runtime, 0, cell.program,
                               cell.bank, cell.key, cell.velocity,
                               &c_layers) == MSF2_OK,
          "voice reuse setup failed");
  for (uint16_t position = 0; position < c_active_runtime.active_count;
       ++position) {
    c_active_voices[c_active_runtime.active_voice_indices[position]]
        .periodic_groups = MSF2_CONTROL_GROUP_GAIN;
  }
  const uint32_t evaluations_before_stale_slice =
      c_active_runtime.stats.control_voice_evaluations;
  require(msf2_runtime_advance_control_slice(
              &c_active_runtime, control_snapshot.data(), 0u, 4u, 5u) ==
              MSF2_OK,
          "stale split control update failed");
  msf2_runtime_complete_control(&c_active_runtime, 5u,
                                dirty_revisions.data());
  require(c_active_runtime.stats.control_voice_evaluations ==
                  evaluations_before_stale_slice &&
              c_active_runtime.control_tick_index == 25 &&
              msf2_runtime_all_sound_off(&c_active_runtime, 0) == MSF2_OK,
          "stale control snapshot modified a reused voice generation");
  for (uint16_t voice = 0; voice < c_active_runtime.voice_capacity; ++voice) {
    if (c_active_voices[voice].stage != MSF2_VOICE_FREE) {
      require(msf2_runtime_complete_voice(&c_active_runtime, voice) == MSF2_OK,
              "final FPGA completion reconciliation failed");
    }
  }
  require(c_active_runtime.active_count == 0 &&
              c_active_runtime.free_count == c_active_runtime.voice_capacity,
          "final FPGA completion did not free all voices");

  const auto before_unmapped = runtime.stats().unmapped_notes;
  (void)runtime.note_on(0, 127, 16383, cell.key, cell.velocity);
  require(runtime.stats().unmapped_notes == before_unmapped + 1,
          "unmapped compiled preset was not rejected");
  return 0;
}
