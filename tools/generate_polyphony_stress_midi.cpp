#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct Event {
  uint32_t tick;
  uint32_t order;
  std::vector<uint8_t> data;
};

void append_be16(std::vector<uint8_t>& out, uint16_t value) {
  out.push_back(uint8_t(value >> 8));
  out.push_back(uint8_t(value));
}

void append_be32(std::vector<uint8_t>& out, uint32_t value) {
  out.push_back(uint8_t(value >> 24));
  out.push_back(uint8_t(value >> 16));
  out.push_back(uint8_t(value >> 8));
  out.push_back(uint8_t(value));
}

void append_vlq(std::vector<uint8_t>& out, uint32_t value) {
  uint8_t bytes[5];
  int count = 0;
  bytes[count++] = uint8_t(value & 0x7f);
  while ((value >>= 7) != 0) bytes[count++] = uint8_t((value & 0x7f) | 0x80);
  while (count != 0) out.push_back(bytes[--count]);
}

void add_event(std::vector<Event>& events, uint32_t tick, uint32_t& order,
               std::initializer_list<uint8_t> data) {
  events.push_back(Event{tick, order++, std::vector<uint8_t>(data)});
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 2) {
      std::cerr << "usage: generate_polyphony_stress_midi OUTPUT.mid\n";
      return 2;
    }

    constexpr uint16_t kPpq = 480;
    constexpr uint32_t kEndTick = 10 * 2 * kPpq;
    std::mt19937 rng(0x53474d32u);
    std::uniform_int_distribution<int> note_dist(24, 108);
    std::uniform_int_distribution<int> velocity_dist(48, 127);
    std::uniform_int_distribution<int> channel_dist(0, 15);
    std::uniform_int_distribution<int> program_dist(0, 127);

    std::vector<Event> events;
    uint32_t order = 0;
    events.push_back(Event{0, order++, {0xff, 0x51, 0x03, 0x07, 0xa1, 0x20}});
    const std::string name = "SGM 256-voice random-access stress";
    std::vector<uint8_t> name_event{0xff, 0x03, uint8_t(name.size())};
    name_event.insert(name_event.end(), name.begin(), name.end());
    events.push_back(Event{0, order++, std::move(name_event)});

    for (int channel = 0; channel < 16; ++channel) {
      const int program = (channel * 11 + 3) & 0x7f;
      add_event(events, 0, order,
                {uint8_t(0xc0 | channel), uint8_t(program)});
      add_event(events, 0, order,
                {uint8_t(0xb0 | channel), 7, uint8_t(100)});
      add_event(events, 0, order,
                {uint8_t(0xb0 | channel), 10,
                 uint8_t((channel * 23 + 17) & 0x7f)});
      if (channel != 9) {
        add_event(events, 0, order,
                  {uint8_t(0xb0 | channel), 64, uint8_t(127)});
      }
    }

    // More than 256 simultaneous note instances force all allocator slots live,
    // including banks/programs that expand one MIDI note into stereo regions.
    for (int channel = 0; channel < 16; ++channel) {
      for (int index = 0; index < 20; ++index) {
        const int note = channel == 9 ? 35 + (index % 47) : note_dist(rng);
        add_event(events, 0, order,
                  {uint8_t(0x90 | channel), uint8_t(note),
                   uint8_t(velocity_dist(rng))});
      }
    }

    // Churn voices and programs at 25 ms intervals. Sustain keeps released
    // melodic notes resident until allocation pressure steals them.
    for (uint32_t tick = 24, step = 1; tick < kEndTick; tick += 24, ++step) {
      if ((step % 16) == 0) {
        for (int channel = 0; channel < 16; ++channel) {
          if (channel == 9) continue;
          add_event(events, tick, order,
                    {uint8_t(0xc0 | channel), uint8_t(program_dist(rng))});
        }
      }
      for (int burst = 0; burst < 8; ++burst) {
        const int channel = channel_dist(rng);
        const int note = channel == 9 ? 35 + (rng() % 47) : note_dist(rng);
        add_event(events, tick, order,
                  {uint8_t(0x90 | channel), uint8_t(note),
                   uint8_t(velocity_dist(rng))});
        add_event(events, std::min(kEndTick - 1, tick + 12), order,
                  {uint8_t(0x80 | channel), uint8_t(note), uint8_t(0)});
      }
    }

    for (int channel = 0; channel < 16; ++channel) {
      add_event(events, kEndTick, order,
                {uint8_t(0xb0 | channel), 64, uint8_t(0)});
      add_event(events, kEndTick, order,
                {uint8_t(0xb0 | channel), 123, uint8_t(0)});
    }

    std::stable_sort(events.begin(), events.end(), [](const Event& a, const Event& b) {
      return a.tick < b.tick || (a.tick == b.tick && a.order < b.order);
    });

    std::vector<uint8_t> track;
    uint32_t previous_tick = 0;
    for (const Event& event : events) {
      append_vlq(track, event.tick - previous_tick);
      track.insert(track.end(), event.data.begin(), event.data.end());
      previous_tick = event.tick;
    }
    append_vlq(track, 0);
    track.insert(track.end(), {0xff, 0x2f, 0x00});

    std::vector<uint8_t> midi{'M', 'T', 'h', 'd'};
    append_be32(midi, 6);
    append_be16(midi, 0);
    append_be16(midi, 1);
    append_be16(midi, kPpq);
    midi.insert(midi.end(), {'M', 'T', 'r', 'k'});
    append_be32(midi, uint32_t(track.size()));
    midi.insert(midi.end(), track.begin(), track.end());

    std::ofstream output(argv[1], std::ios::binary);
    if (!output) throw std::runtime_error("failed to open output MIDI");
    output.write(reinterpret_cast<const char*>(midi.data()),
                 std::streamsize(midi.size()));
    if (!output) throw std::runtime_error("failed to write output MIDI");
    std::cout << "stress MIDI events=" << events.size()
              << " bytes=" << midi.size() << " duration_seconds=10\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "generate_polyphony_stress_midi failed: " << error.what() << "\n";
    return 1;
  }
}
