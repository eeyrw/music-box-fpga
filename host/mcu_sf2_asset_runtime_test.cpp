#include "host/mcu_sf2_asset_runtime.h"

#include "sim/harness/formats/sf2_loader.h"

#include <filesystem>
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
  for (size_t preset = 0; preset < view.preset_dispatch_count(); ++preset) {
    const auto dispatch = view.preset_dispatch(preset);
    for (int key = 0; key < 128; ++key) {
      const auto span = view.find_velocity_span(preset, key, 100);
      if (span.layer_count != 0) {
        return {dispatch.program, dispatch.bank, uint8_t(key), 100};
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
  const uint16_t layers = runtime.note_on(
      0, cell.program, cell.bank, cell.key, cell.velocity);
  require(layers != 0 && !sink.commands.empty() && opcode(sink.commands.front()) == 0x10,
          "compiled runtime did not emit START first");
  const uint16_t first_voice = uint16_t((sink.commands.front().words[0] >> 14) & 0x3ffu);
  const uint16_t first_generation = uint16_t(sink.commands.front().words[1]);
  require(first_generation == 1, "first START generation is not one");

  const size_t before_controller = sink.commands.size();
  runtime.control_change(0, 7, 0);
  bool saw_gain = false;
  for (size_t index = before_controller; index < sink.commands.size(); ++index) {
    saw_gain |= opcode(sink.commands[index]) == 0x16;
  }
  require(saw_gain, "CC7 did not update active compiled voices");

  runtime.control_change(0, 64, 127);
  const size_t before_sustain_note_off = sink.commands.size();
  runtime.note_off(0, cell.key);
  require(sink.commands.size() == before_sustain_note_off,
          "sustain-held Note Off emitted a release");
  runtime.control_change(0, 64, 0);
  require(sink.commands.size() > before_sustain_note_off,
          "sustain release did not emit a lifecycle command");
  runtime.advance_samples(UINT32_MAX);

  sink.commands.clear();
  runtime.control_change(0, 7, 127);
  runtime.note_on(0, cell.program, cell.bank, cell.key, cell.velocity);
  require(!sink.commands.empty() && opcode(sink.commands.front()) == 0x10,
          "reused compiled voice did not emit START");
  require(((sink.commands.front().words[0] >> 14) & 0x3ffu) == first_voice &&
              sink.commands.front().words[1] == uint32_t(first_generation + 1),
          "reused voice generation did not advance");

  RecordingSink steal_sink;
  host::McuSf2AssetRuntime one_voice(view, steal_sink, 1);
  one_voice.note_on(0, cell.program, cell.bank, cell.key, cell.velocity);
  one_voice.note_on(0, cell.program, cell.bank, cell.key, cell.velocity);
  bool saw_stop = false;
  for (const auto& command : steal_sink.commands) saw_stop |= opcode(command) == 0x15;
  require(saw_stop && one_voice.stats().stolen_voices != 0,
          "fixed allocator did not use the bounded steal path");

  const auto before_unmapped = runtime.stats().unmapped_notes;
  (void)runtime.note_on(0, 127, 16383, cell.key, cell.velocity);
  require(runtime.stats().unmapped_notes == before_unmapped + 1,
          "unmapped compiled preset was not rejected");
  return 0;
}
