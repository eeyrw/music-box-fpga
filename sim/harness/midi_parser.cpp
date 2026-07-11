#include "midi_parser.h"

#include "byte_reader.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <stdexcept>

namespace render {
namespace {

// Standard MIDI files encode most time values as variable-length quantities.
// Each byte contributes seven payload bits; the high bit says whether another
// byte follows. The parser returns the decoded delta tick and advances pos to
// the next byte after the number.
uint32_t read_varlen(const std::vector<uint8_t>& data, size_t& pos) {
  uint32_t value = 0;
  while (true) {
    if (pos >= data.size()) throw std::runtime_error("truncated MIDI varlen");
    uint8_t b = data[pos++];
    value = (value << 7) | (b & 0x7f);
    if ((b & 0x80) == 0) return value;
  }
}

struct TickEvent {
  // Absolute tick within the MIDI file. Track-local delta ticks are accumulated
  // before events are merged across tracks.
  uint32_t tick = 0;
  NoteEvent event;
};

struct TempoEvent {
  // Tempo events are global in SMF format 0 and 1. order keeps the original read
  // order so multiple tempo events at the same tick behave like the file stream:
  // later tempo messages override earlier ones, including the synthetic default.
  uint32_t tick = 0;
  uint32_t tempo = 500000;
  uint32_t order = 0;
};

}  // namespace

std::vector<NoteEvent> parse_midi(const std::string& path) {
  auto data = read_file(path);

  // The harness intentionally implements only standard MIDI files with PPQ
  // timing. SMPTE timing is rejected because the rest of the render path expects
  // musical ticks that can be converted through the tempo map.
  if (data.size() < 14 || std::memcmp(data.data(), "MThd", 4) != 0) {
    throw std::runtime_error("not a standard MIDI file");
  }

  uint32_t header_len = read_u32be(data, 4);
  uint16_t track_count = read_u16be(data, 10);
  uint16_t division = read_u16be(data, 12);
  if (division & 0x8000) throw std::runtime_error("SMPTE time division is not supported");

  size_t pos = 8 + header_len;
  std::vector<TickEvent> tick_events;

  // MIDI specifies an implicit 120 BPM tempo until a Set Tempo meta event says
  // otherwise. Treat that as a real tempo event at tick 0 so the conversion loop
  // below can handle files with or without explicit tempo messages uniformly.
  std::vector<TempoEvent> tempos{{0, 500000, 0}};
  uint32_t tempo_order = 1;

  for (int tr = 0; tr < track_count; ++tr) {
    if (pos + 8 > data.size() || std::memcmp(data.data() + pos, "MTrk", 4) != 0) {
      throw std::runtime_error("missing MTrk chunk");
    }
    uint32_t size = read_u32be(data, pos + 4);
    pos += 8;
    size_t end = pos + size;

    uint32_t tick = 0;
    int running_status = -1;
    std::array<int, 16> program{};
    std::array<int, 16> bank_msb{};
    std::array<int, 16> bank_lsb{};

    while (pos < end) {
      tick += read_varlen(data, pos);
      if (pos >= end) break;

      // MIDI running status omits repeated status bytes. Keep the last channel
      // status so dense files can be parsed without expanding the stream first.
      int status = data[pos];
      if (status & 0x80) {
        ++pos;
        running_status = status;
      } else if (running_status >= 0) {
        status = running_status;
      } else {
        throw std::runtime_error("MIDI running status without previous status");
      }

      if (status == 0xff) {
        uint8_t meta = data[pos++];
        uint32_t len = read_varlen(data, pos);
        if (meta == 0x51 && len == 3) {
          // Set Tempo stores microseconds per quarter note in three big-endian
          // bytes. This value is not BPM; smaller numbers mean faster playback.
          uint32_t tempo = (uint32_t(data[pos]) << 16) |
                           (uint32_t(data[pos + 1]) << 8) | data[pos + 2];
          tempos.push_back({tick, tempo, tempo_order++});
        }
        pos += len;
        continue;
      }

      if (status == 0xf0 || status == 0xf7) {
        uint32_t len = read_varlen(data, pos);
        pos += len;
        continue;
      }

      int type = status & 0xf0;
      int ch = status & 0x0f;
      if (type == 0x80 || type == 0x90) {
        // Note On with velocity zero is semantically Note Off, but it is still
        // stored as a note event so the MCU model can release the matching RTL
        // voice at the exact converted sample.
        int note = data[pos++];
        int vel = data[pos++];
        NoteEvent ev;
        ev.note = note;
        ev.on = (type == 0x90 && vel != 0);
        ev.velocity = vel;
        ev.channel = ch;
        ev.program = program[ch];
        ev.bank = (bank_msb[ch] << 7) | bank_lsb[ch];
        tick_events.push_back({tick, ev});
      } else if (type == 0xb0) {
        int controller = data[pos++];
        int value = data[pos++];
        // Bank select is split into MSB and LSB controllers. The selected bank
        // is latched into later Note On events so preset lookup does not need to
        // inspect controller history again.
        if (controller == 0) bank_msb[ch] = value;
        else if (controller == 32) bank_lsb[ch] = value;
      } else if (type == 0xc0) {
        // Program changes also latch per channel and are copied into Note On
        // events. This models what firmware would know when allocating a voice.
        program[ch] = data[pos++];
      } else if (type == 0xa0 || type == 0xe0) {
        pos += 2;
      } else if (type == 0xd0) {
        pos += 1;
      } else {
        throw std::runtime_error("unsupported MIDI status");
      }
    }
    pos = end;
  }

  std::sort(tempos.begin(), tempos.end(), [](const TempoEvent& a, const TempoEvent& b) {
    if (a.tick != b.tick) return a.tick < b.tick;
    return a.order < b.order;
  });
  std::sort(tick_events.begin(), tick_events.end(),
            [](const TickEvent& a, const TickEvent& b) { return a.tick < b.tick; });

  // Tempo changes are global in standard MIDI files. Walk the tempo map once and
  // convert each absolute tick to seconds before the renderer maps it to samples.
  // The loop advances through all tempo events whose tick is at or before the
  // note event. For equal-tick tempo events, the insertion order above ensures
  // the last tempo message at that tick is the one used for the event itself.
  std::vector<NoteEvent> events;
  size_t tempo_index = 0;
  uint32_t last_tick = 0;
  double last_seconds = 0.0;
  uint32_t tempo = tempos.front().tempo;
  for (auto te : tick_events) {
    while (tempo_index + 1 < tempos.size() && tempos[tempo_index + 1].tick <= te.tick) {
      auto next = tempos[++tempo_index];
      last_seconds += double(next.tick - last_tick) * double(tempo) / double(division) / 1000000.0;
      last_tick = next.tick;
      tempo = next.tempo;
    }
    te.event.time_seconds = last_seconds + double(te.tick - last_tick) * double(tempo) / double(division) / 1000000.0;
    events.push_back(te.event);
  }
  return events;
}

std::vector<NoteEvent> default_melody() {
  // This fallback is used when render-midi is run without a MIDI file. The times
  // are already seconds, so they bypass the MIDI tempo conversion path.
  std::vector<int> notes{60, 64, 67, 72, 67, 64, 60};
  std::vector<NoteEvent> events;
  for (size_t i = 0; i < notes.size(); ++i) {
    events.push_back({double(i) * 0.24, notes[i], true, 110, 0, 0, 0});
    events.push_back({double(i) * 0.24 + 0.20, notes[i], false, 0, 0, 0, 0});
  }
  return events;
}

}  // namespace render
