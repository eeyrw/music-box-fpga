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

void add_pitch_bend(std::vector<Event>& events, uint32_t tick, uint32_t& order,
                    int channel, int bend) {
  bend = std::max(-8192, std::min(8191, bend));
  const int value = bend + 8192;
  add_event(events, tick, order,
            {uint8_t(0xe0 | channel), uint8_t(value & 0x7f),
             uint8_t((value >> 7) & 0x7f)});
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc < 2 || argc > 4) {
      std::cerr << "usage: generate_polyphony_stress_midi OUTPUT.mid "
                   "[initial-notes-per-channel] [churn-notes-per-step]\n";
      return 2;
    }

    const int initial_notes_per_channel = argc >= 3 ? std::stoi(argv[2]) : 20;
    const int churn_notes_per_step = argc >= 4 ? std::stoi(argv[3]) : 8;
    if (initial_notes_per_channel < 0 || initial_notes_per_channel > 64 ||
        churn_notes_per_step < 0 || churn_notes_per_step > 64) {
      throw std::runtime_error("stress note counts must be in range 0..64");
    }

    constexpr uint16_t kPpq = 480;
    constexpr uint32_t kEndTick = 10 * 2 * kPpq;
    std::mt19937 rng(0x53474d32u);
    std::uniform_int_distribution<int> note_dist(24, 108);
    std::uniform_int_distribution<int> velocity_dist(48, 127);
    std::uniform_int_distribution<int> channel_dist(0, 15);
    std::uniform_int_distribution<int> program_dist(0, 127);
    std::mt19937 bend_rng(0x50495443u);
    std::uniform_int_distribution<int> bend_dist(-8192, 8191);

    std::vector<Event> events;
    uint32_t order = 0;
    events.push_back(Event{0, order++, {0xff, 0x51, 0x03, 0x07, 0xa1, 0x20}});
    const std::string name = "SGM 512-voice random-access stress";
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
      // RPN 0: use a different bend range and fractional cents per channel.
      add_event(events, 0, order, {uint8_t(0xb0 | channel), 101, 0});
      add_event(events, 0, order, {uint8_t(0xb0 | channel), 100, 0});
      add_event(events, 0, order,
                {uint8_t(0xb0 | channel), 6,
                 uint8_t(2 + ((channel * 5) % 23))});
      add_event(events, 0, order,
                {uint8_t(0xb0 | channel), 38,
                 uint8_t((channel * 17) % 100)});
      add_event(events, 0, order, {uint8_t(0xb0 | channel), 101, 127});
      add_event(events, 0, order, {uint8_t(0xb0 | channel), 100, 127});
      if (channel != 9) {
        add_event(events, 0, order,
                  {uint8_t(0xb0 | channel), 64, uint8_t(127)});
      }
    }

    // Stereo-region expansion lets the default 320 simultaneous MIDI notes
    // fill the 512 mono-voice allocator while spanning many banks and programs.
    for (int channel = 0; channel < 16; ++channel) {
      for (int index = 0; index < initial_notes_per_channel; ++index) {
        const int note = channel == 9 ? 35 + (index % 47) : note_dist(rng);
        add_event(events, 0, order,
                  {uint8_t(0x90 | channel), uint8_t(note),
                   uint8_t(velocity_dist(rng))});
      }
    }

    // Churn voices and programs at 25 ms intervals. Sustain keeps released
    // melodic notes resident until allocation pressure steals them.
    for (uint32_t tick = 24, step = 1;
         churn_notes_per_step != 0 && tick < kEndTick;
         tick += 24, ++step) {
      for (int channel = 0; channel < 16; ++channel) {
        const int phase = int((step + uint32_t(channel * 7)) & 63u);
        int bend = 0;
        switch (channel & 3) {
          case 0:
            bend = phase < 32 ? -8192 + phase * 512
                              : 8191 - (phase - 32) * 512;
            break;
          case 1:
            bend = -8192 + int((step * 977u + uint32_t(channel * 2053)) &
                               0x3fffu);
            break;
          case 2:
            bend = bend_dist(bend_rng);
            break;
          default: {
            constexpr int kBoundaryPattern[8] = {
                -8192, -4096, 0, 4096, 8191, 2048, -2048, 0};
            bend = kBoundaryPattern[(step + uint32_t(channel)) & 7u];
            break;
          }
        }
        add_pitch_bend(events, tick, order, channel, bend);
      }
      if ((step % 16) == 0) {
        for (int channel = 0; channel < 16; ++channel) {
          if (channel == 9) continue;
          add_event(events, tick, order,
                    {uint8_t(0xc0 | channel), uint8_t(program_dist(rng))});
        }
      }
      for (int burst = 0; burst < churn_notes_per_step; ++burst) {
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
      add_pitch_bend(events, kEndTick, order, channel, 0);
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
