#include "host/mcu_sf2_asset_runtime.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <vector>

namespace {

class CountingSink final : public render::CommandWordSink {
 public:
  void write_command_words(render::CommandWordView words) override {
    ++commands;
    command_words += words.size();
  }
  uint64_t commands = 0;
  uint64_t command_words = 0;
};

std::vector<uint8_t> read_file(const char* path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("cannot open MCU SF2 asset");
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(input), {});
}

struct Cell {
  uint16_t program = 0;
  uint16_t bank = 0;
  uint8_t key = 60;
  uint8_t velocity = 100;
};

Cell find_single_layer_cell(const render::McuSf2AssetView& view) {
  for (size_t preset = 0; preset < view.preset_dispatch_count(); ++preset) {
    const auto dispatch = view.preset_dispatch(preset);
    for (int key = 0; key < 128; ++key) {
      const auto span = view.find_velocity_span(preset, key, 100);
      if (span.layer_count == 1) {
        return {dispatch.program, dispatch.bank, uint8_t(key), 100};
      }
    }
  }
  throw std::runtime_error("asset has no single-layer benchmark cell");
}

uint64_t elapsed_ns(std::chrono::steady_clock::time_point start) {
  return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now() - start).count());
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 2) throw std::runtime_error("usage: mcu_sf2_runtime_benchmark <asset.msf2>");
    const auto image = read_file(argv[1]);
    const render::McuSf2AssetView view(image.data(), image.size());
    const Cell cell = find_single_layer_cell(view);
    std::cout << "{\n  \"schema\": \"mcu-sf2-runtime-benchmark-v1\",\n"
              << "  \"runtime_object_bytes\": "
              << sizeof(host::McuSf2AssetRuntime) << ",\n"
              << "  \"asset_bytes\": " << image.size() << ",\n"
              << "  \"capacities\": [\n";
    const uint16_t capacities[] = {128, 256, 512};
    for (size_t capacity_index = 0; capacity_index < 3; ++capacity_index) {
      const uint16_t capacity = capacities[capacity_index];
      CountingSink sink;
      host::McuSf2AssetRuntime runtime(view, sink, capacity);
      uint64_t note_total = 0;
      uint64_t note_max = 0;
      for (uint16_t index = 0; index < capacity; ++index) {
        const auto start = std::chrono::steady_clock::now();
        (void)runtime.note_on(0, cell.program, cell.bank, cell.key, cell.velocity);
        const uint64_t duration = elapsed_ns(start);
        note_total += duration;
        note_max = std::max(note_max, duration);
      }
      const auto controller_start = std::chrono::steady_clock::now();
      runtime.control_change(0, 7, 96);
      const uint64_t controller_ns = elapsed_ns(controller_start);
      const auto steal_start = std::chrono::steady_clock::now();
      (void)runtime.note_on(0, cell.program, cell.bank, cell.key, cell.velocity);
      const uint64_t steal_ns = elapsed_ns(steal_start);
      std::cout << "    {\"voices\": " << capacity
                << ", \"note_on_average_ns\": " << note_total / capacity
                << ", \"note_on_max_ns\": " << note_max
                << ", \"controller_update_ns\": " << controller_ns
                << ", \"steal_note_on_ns\": " << steal_ns
                << ", \"commands\": " << sink.commands
                << ", \"command_words\": " << sink.command_words << "}"
                << (capacity_index == 2 ? "\n" : ",\n");
    }
    std::cout << "  ]\n}\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "mcu_sf2_runtime_benchmark failed: " << error.what() << '\n';
    return 1;
  }
}
