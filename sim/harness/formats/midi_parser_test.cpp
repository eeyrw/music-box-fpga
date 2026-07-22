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

std::vector<uint8_t> make_header(uint16_t format, uint16_t tracks, uint16_t division = 480) {
  std::vector<uint8_t> file;
  file.insert(file.end(), {'M', 'T', 'h', 'd'});
  push_u32(file, 6);
  push_u16(file, format);
  push_u16(file, tracks);
  push_u16(file, division);
  return file;
}

std::string write_file(const std::string& name, const std::vector<uint8_t>& data) {
  const std::string path = "build/" + name;
  std::ofstream out(path, std::ios::binary);
  if (!out) throw std::runtime_error("failed to create " + path);
  out.write(reinterpret_cast<const char*>(data.data()), data.size());
  return path;
}

std::string write_tick_zero_fast_tempo_midi() {
  const std::string path = "build/midi_parser_test_tick0_tempo.mid";
  std::vector<uint8_t> file = make_header(1, 2);

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

std::string write_cross_track_state_midi() {
  std::vector<uint8_t> file = make_header(1, 2);

  std::vector<uint8_t> state_track;
  push_varlen(state_track, 0);
  state_track.insert(state_track.end(), {0xb0, 0, 2});
  push_varlen(state_track, 0);
  state_track.insert(state_track.end(), {0xb0, 32, 3});
  push_varlen(state_track, 0);
  state_track.insert(state_track.end(), {0xc0, 5});
  push_varlen(state_track, 0);
  state_track.insert(state_track.end(), {0xff, 0x2f, 0x00});
  append_track(file, state_track);

  std::vector<uint8_t> note_track;
  push_varlen(note_track, 0);
  note_track.insert(note_track.end(), {0x90, 64, 100});
  push_varlen(note_track, 120);
  note_track.insert(note_track.end(), {0x80, 64, 0});
  push_varlen(note_track, 0);
  note_track.insert(note_track.end(), {0xff, 0x2f, 0x00});
  append_track(file, note_track);

  return write_file("midi_parser_test_cross_track_state.mid", file);
}

std::string write_same_tick_order_midi() {
  std::vector<uint8_t> file = make_header(0, 1);
  std::vector<uint8_t> track;
  push_varlen(track, 0);
  track.insert(track.end(), {0x90, 60, 100});
  push_varlen(track, 0);
  track.insert(track.end(), {0xc0, 42});
  push_varlen(track, 0);
  track.insert(track.end(), {0x90, 62, 100});
  push_varlen(track, 0);
  track.insert(track.end(), {0xff, 0x2f, 0x00});
  append_track(file, track);
  return write_file("midi_parser_test_same_tick_order.mid", file);
}

std::string write_meta_cancels_running_status_midi() {
  std::vector<uint8_t> file = make_header(0, 1);
  std::vector<uint8_t> track;
  push_varlen(track, 0);
  track.insert(track.end(), {0x90, 60, 100});
  push_varlen(track, 0);
  track.insert(track.end(), {0xff, 0x01, 0x00});
  push_varlen(track, 0);
  track.insert(track.end(), {62, 100});
  push_varlen(track, 0);
  track.insert(track.end(), {0xff, 0x2f, 0x00});
  append_track(file, track);
  return write_file("midi_parser_test_meta_cancels_running.mid", file);
}

std::string write_sysex_cancels_running_status_midi() {
  std::vector<uint8_t> file = make_header(0, 1);
  std::vector<uint8_t> track;
  push_varlen(track, 0);
  track.insert(track.end(), {0x90, 60, 100});
  push_varlen(track, 0);
  track.insert(track.end(), {0xf7, 0x01, 0xf8});
  push_varlen(track, 0);
  track.insert(track.end(), {62, 100});
  push_varlen(track, 0);
  track.insert(track.end(), {0xff, 0x2f, 0x00});
  append_track(file, track);
  return write_file("midi_parser_test_sysex_cancels_running.mid", file);
}

std::string write_format_midi(uint16_t format, uint16_t tracks) {
  std::vector<uint8_t> file = make_header(format, tracks);
  for (uint16_t i = 0; i < tracks; ++i) {
    std::vector<uint8_t> track;
    push_varlen(track, 0);
    track.insert(track.end(), {0xff, 0x2f, 0x00});
    append_track(file, track);
  }
  return write_file("midi_parser_test_bad_format_" + std::to_string(format) + "_" +
                        std::to_string(tracks) + ".mid",
                    file);
}

std::string write_truncated_track_midi() {
  std::vector<uint8_t> file = make_header(0, 1);
  file.insert(file.end(), {'M', 'T', 'r', 'k'});
  push_u32(file, 8);
  file.insert(file.end(), {0x00, 0x90, 60});
  return write_file("midi_parser_test_truncated_track.mid", file);
}

std::string write_truncated_event_midi() {
  std::vector<uint8_t> file = make_header(0, 1);
  std::vector<uint8_t> track;
  push_varlen(track, 0);
  track.insert(track.end(), {0x90, 60});
  append_track(file, track);
  return write_file("midi_parser_test_truncated_event.mid", file);
}

std::string write_oversized_varlen_midi() {
  std::vector<uint8_t> file = make_header(0, 1);
  std::vector<uint8_t> track{0x81, 0x80, 0x80, 0x80, 0x00, 0xff, 0x2f, 0x00};
  append_track(file, track);
  return write_file("midi_parser_test_oversized_varlen.mid", file);
}

void expect_near(double actual, double expected, const char* label) {
  if (std::abs(actual - expected) > 1e-9) {
    throw std::runtime_error(std::string(label) + " expected " + std::to_string(expected) +
                             " got " + std::to_string(actual));
  }
}

template <typename Fn>
void expect_throws(Fn fn, const char* label) {
  try {
    fn();
  } catch (const std::exception&) {
    return;
  }
  throw std::runtime_error(std::string(label) + " did not throw");
}

}  // namespace

int main() {
  try {
    {
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
    }

    {
      auto events = render::parse_midi(write_cross_track_state_midi());
      if (events.size() != 4) throw std::runtime_error("cross-track state MIDI event count mismatch");
      if (events[2].type != render::NoteEvent::EVENT_NOTE || events[2].program != 5 ||
          events[2].bank != ((2 << 7) | 3)) {
        throw std::runtime_error("format 1 channel state was not applied across tracks");
      }
    }

    {
      auto events = render::parse_midi(write_same_tick_order_midi());
      if (events.size() != 2) throw std::runtime_error("same-tick order MIDI event count mismatch");
      if (events[0].note != 60 || events[0].program != 0) {
        throw std::runtime_error("first same-tick note did not keep pre-program state");
      }
      if (events[1].note != 62 || events[1].program != 42) {
        throw std::runtime_error("second same-tick note did not see intervening program change");
      }
    }

    expect_throws([] { render::parse_midi(write_meta_cancels_running_status_midi()); },
                  "meta running-status cancellation");
    expect_throws([] { render::parse_midi(write_sysex_cancels_running_status_midi()); },
                  "sysex running-status cancellation");
    expect_throws([] { render::parse_midi(write_format_midi(0, 2)); }, "format 0 track-count validation");
    expect_throws([] { render::parse_midi(write_format_midi(2, 1)); }, "format 2 rejection");
    expect_throws([] { render::parse_midi(write_format_midi(3, 1)); }, "unknown format rejection");
    expect_throws([] { render::parse_midi(write_truncated_track_midi()); }, "truncated track validation");
    expect_throws([] { render::parse_midi(write_truncated_event_midi()); }, "truncated event validation");
    expect_throws([] { render::parse_midi(write_oversized_varlen_midi()); }, "oversized varlen validation");

    std::cout << "PASS: MIDI parser handles tempo, ordering, channel state, and strict SMF validation\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "midi_parser_test failed: " << e.what() << "\n";
    return 1;
  }
}
