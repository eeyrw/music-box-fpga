#include "midi_parser.h"

#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void push_u16(std::vector<uint8_t>& out, uint16_t value) {
  out.push_back(uint8_t(value >> 8));
  out.push_back(uint8_t(value));
}

void push_u32(std::vector<uint8_t>& out, uint32_t value) {
  out.push_back(uint8_t(value >> 24));
  out.push_back(uint8_t(value >> 16));
  out.push_back(uint8_t(value >> 8));
  out.push_back(uint8_t(value));
}

void push_varlen(std::vector<uint8_t>& out, uint32_t value) {
  uint8_t bytes[5];
  int count = 0;
  bytes[count++] = uint8_t(value & 0x7f);
  value >>= 7;
  while (value != 0) {
    bytes[count++] = uint8_t((value & 0x7f) | 0x80);
    value >>= 7;
  }
  while (count > 0) out.push_back(bytes[--count]);
}

void append_track(std::vector<uint8_t>& file, const std::vector<uint8_t>& track) {
  file.insert(file.end(), {'M', 'T', 'r', 'k'});
  push_u32(file, uint32_t(track.size()));
  file.insert(file.end(), track.begin(), track.end());
}

std::string write_tick_zero_fast_tempo_midi() {
  const std::string path = "build/midi_parser_test_tick0_tempo.mid";
  std::vector<uint8_t> file;
  file.insert(file.end(), {'M', 'T', 'h', 'd'});
  push_u32(file, 6);
  push_u16(file, 1);
  push_u16(file, 2);
  push_u16(file, 480);

  std::vector<uint8_t> tempo_track;
  push_varlen(tempo_track, 0);
  tempo_track.insert(tempo_track.end(), {0xff, 0x51, 0x03, 0x05, 0xb8, 0xd8});
  push_varlen(tempo_track, 0);
  tempo_track.insert(tempo_track.end(), {0xff, 0x2f, 0x00});
  append_track(file, tempo_track);

  std::vector<uint8_t> note_track;
  push_varlen(note_track, 0);
  note_track.insert(note_track.end(), {0xb0, 7, 100});
  push_varlen(note_track, 0);
  note_track.insert(note_track.end(), {0xe0, 0x00, 0x60});
  push_varlen(note_track, 480);
  note_track.insert(note_track.end(), {0x90, 60, 100});
  push_varlen(note_track, 480);
  note_track.insert(note_track.end(), {0x80, 60, 0});
  push_varlen(note_track, 0);
  note_track.insert(note_track.end(), {0xff, 0x2f, 0x00});
  append_track(file, note_track);

  std::ofstream out(path, std::ios::binary);
  if (!out) throw std::runtime_error("failed to create " + path);
  out.write(reinterpret_cast<const char*>(file.data()), file.size());
  return path;
}

void expect_near(double actual, double expected, const char* label) {
  if (std::abs(actual - expected) > 1e-9) {
    throw std::runtime_error(std::string(label) + " expected " + std::to_string(expected) +
                             " got " + std::to_string(actual));
  }
}

}  // namespace

int main() {
  try {
    auto events = render::parse_midi(write_tick_zero_fast_tempo_midi());
    if (events.size() != 4) {
      throw std::runtime_error("expected 4 MIDI events, got " + std::to_string(events.size()));
    }
    if (events[0].type != render::NoteEvent::EVENT_CONTROL || events[0].controller != 7 || events[0].value != 100) {
      throw std::runtime_error("CC7 volume event was not preserved");
    }
    if (events[1].type != render::NoteEvent::EVENT_PITCH_BEND || events[1].pitch_bend != 4096) {
      throw std::runtime_error("pitch bend event was not preserved");
    }
    expect_near(events[2].time_seconds, 0.375, "note on time");
    expect_near(events[3].time_seconds, 0.750, "note off time");
    std::cout << "PASS: MIDI parser preserves tick-zero tempo over default tempo\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "midi_parser_test failed: " << e.what() << "\n";
    return 1;
  }
}
