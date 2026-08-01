#include "host/mcu_sf2_asset_runtime.h"

#include "sim/harness/formats/sf2_loader.h"
#include "sim/harness/render/reference_synth.h"
#include "sim/harness/render/render_support.h"

#include <filesystem>
#include <stdexcept>
#include <string>
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

struct PlayableCell {
  uint16_t program = 0;
  uint16_t bank = 0;
  uint8_t key = 0;
  uint8_t velocity = 100;
};

PlayableCell first_playable(const render::McuSf2AssetView& view) {
  for (size_t preset = 0; preset < view.preset_dispatch_count(); ++preset) {
    const auto dispatch = view.preset_dispatch(preset);
    for (int key = 0; key < 128; ++key) {
      if (view.find_velocity_span(preset, key, 100).layer_count != 0) {
        return {dispatch.program, dispatch.bank, uint8_t(key), 100};
      }
    }
  }
  throw std::runtime_error("fixture contains no playable MCU asset cell");
}

void require_equal(const RecordingSink& expected, const RecordingSink& actual,
                   const char* stage) {
  if (expected.commands.size() != actual.commands.size()) {
    throw std::runtime_error(std::string(stage) + " command count mismatch: " +
                             std::to_string(expected.commands.size()) + " != " +
                             std::to_string(actual.commands.size()));
  }
  for (size_t command = 0; command < expected.commands.size(); ++command) {
    const auto& a = expected.commands[command];
    const auto& b = actual.commands[command];
    if (a.length != b.length) {
      throw std::runtime_error(std::string(stage) + " command length mismatch");
    }
    for (size_t word = 0; word < a.length; ++word) {
      if (a.words[word] != b.words[word]) {
        throw std::runtime_error(std::string(stage) + " command word mismatch at " +
                                 std::to_string(command) + ":" +
                                 std::to_string(word) + " (" +
                                 std::to_string(a.words[word]) + " != " +
                                 std::to_string(b.words[word]) + ")");
      }
    }
  }
}

render::NoteEvent control_event(int controller, int value) {
  render::NoteEvent event;
  event.type = render::NoteEvent::EVENT_CONTROL;
  event.channel = 0;
  event.controller = controller;
  event.value = value;
  return event;
}

void require_audio_equal(render::ReferenceSynth& expected,
                         render::ReferenceSynth& actual, int samples,
                         const char* stage) {
  for (int sample = 0; sample < samples; ++sample) {
    if (expected.render_sample() != actual.render_sample()) {
      throw std::runtime_error(std::string(stage) +
                               " reference PCM mismatch at sample " +
                               std::to_string(sample));
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) throw std::runtime_error("expected SF2 fixture path");
  const render::Sf2Data sf2 = render::load_sf2(argv[1]);
  const auto image = render::build_mcu_sf2_asset(
      sf2, std::filesystem::file_size(argv[1]));
  const render::McuSf2AssetView view(image.data(), image.size());
  const PlayableCell cell = first_playable(view);
  std::vector<render::Region> regions = render::make_regions_for_preset(
      sf2, cell.program, cell.bank, cell.key, cell.velocity, 48000, 48);

  RecordingSink reference_sink;
  render::ReferenceSynth reference_synth(sf2.file_words);
  render::CommandFanout reference_fanout(reference_sink, reference_synth);
  render::CommandVoiceControl reference_commands(reference_fanout);
  render::McuModel reference(reference_commands, regions, nullptr, {1, 1, 4});
  RecordingSink compiled_sink;
  render::ReferenceSynth compiled_synth(sf2.file_words);
  render::CommandFanout compiled_fanout(compiled_sink, compiled_synth);
  host::McuSf2AssetRuntime compiled(view, compiled_fanout);

  for (size_t index = 0; index < regions.size(); ++index) {
    render::NoteEvent event;
    event.type = render::NoteEvent::EVENT_NOTE;
    event.on = true;
    event.channel = 0;
    event.program = cell.program;
    event.bank = cell.bank;
    event.note = cell.key;
    event.velocity = cell.velocity;
    event.region = int(index);
    event.phase_inc = regions[index].phase_inc;
    event.note_instance = 1;
    reference.handle_event(event);
  }
  compiled.note_on(0, cell.program, cell.bank, cell.key, cell.velocity);
  require_equal(reference_sink, compiled_sink, "Note On");
  require_audio_equal(reference_synth, compiled_synth, 256, "Note On");

  reference.handle_event(control_event(7, 91));
  compiled.control_change(0, 7, 91);
  require_equal(reference_sink, compiled_sink, "CC7");
  require_audio_equal(reference_synth, compiled_synth, 128, "CC7");

  render::NoteEvent bend;
  bend.type = render::NoteEvent::EVENT_PITCH_BEND;
  bend.channel = 0;
  bend.pitch_bend = 4096;
  reference.handle_event(bend);
  compiled.pitch_bend(0, 4096);
  require_equal(reference_sink, compiled_sink, "pitch bend");
  require_audio_equal(reference_synth, compiled_synth, 128, "pitch bend");

  for (int tick = 0; tick < 4; ++tick) {
    reference.control_tick();
    compiled.advance_samples(48);
  }
  require_equal(reference_sink, compiled_sink, "control ticks");
  require_audio_equal(reference_synth, compiled_synth, 256, "control ticks");

  render::NoteEvent off;
  off.type = render::NoteEvent::EVENT_NOTE;
  off.on = false;
  off.channel = 0;
  off.note = cell.key;
  off.note_instance = 1;
  reference.handle_event(off);
  compiled.note_off(0, cell.key);
  require_equal(reference_sink, compiled_sink, "Note Off");
  require_audio_equal(reference_synth, compiled_synth, 256, "Note Off");
  return 0;
}
