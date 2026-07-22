#include "midi_parser.h"

#include "byte_reader.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>

namespace render {
namespace {

// Standard MIDI files encode most time values as variable-length quantities.
// Each byte contributes seven payload bits; the high bit says whether another
// byte follows. The parser returns the decoded delta tick and advances pos to
// the next byte after the number.
void require_track_bytes(size_t pos, size_t end, size_t count, const char* what) {
  if (count > end || pos > end - count) throw std::runtime_error(std::string("truncated MIDI ") + what);
}

uint8_t read_data_byte(const std::vector<uint8_t>& data, size_t& pos, size_t end, const char* what) {
  require_track_bytes(pos, end, 1, what);
  uint8_t value = data[pos++];
  if (value & 0x80) throw std::runtime_error(std::string("invalid MIDI data byte in ") + what);
  return value;
}

uint32_t read_varlen(const std::vector<uint8_t>& data, size_t& pos, size_t end) {
  uint32_t value = 0;
  for (int i = 0; i < 4; ++i) {
    require_track_bytes(pos, end, 1, "varlen");
    uint8_t b = data[pos++];
    value = (value << 7) | (b & 0x7f);
    if ((b & 0x80) == 0) return value;
  }
  throw std::runtime_error("MIDI varlen exceeds 4 bytes");
}

enum class RawKind {
  kNote,
  kControl,
  kProgram,
  kKeyPressure,
  kPitchBend,
  kChannelPressure,
};

struct RawEvent {
  uint32_t tick = 0;
  uint32_t order = 0;
  RawKind kind = RawKind::kNote;
  int channel = 0;
  int a = 0;
  int b = 0;
  bool note_on_status = false;
};

int event_data_bytes(int status_type) {
  switch (status_type) {
    case 0x80:
    case 0x90:
    case 0xa0:
    case 0xb0:
    case 0xe0:
      return 2;
    case 0xc0:
    case 0xd0:
      return 1;
    default:
      return 0;
  }
}

struct TickEvent {
  // Absolute tick within the MIDI file. Track-local delta ticks are accumulated
  // before events are merged across tracks.
  uint32_t tick = 0;
  uint32_t order = 0;
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
  if (header_len < 6 || 8 + size_t(header_len) > data.size()) {
    throw std::runtime_error("truncated MIDI header");
  }
  uint16_t format = read_u16be(data, 8);
  uint16_t track_count = read_u16be(data, 10);
  uint16_t division = read_u16be(data, 12);
  if (format > 2) throw std::runtime_error("unsupported MIDI file format");
  if (format == 0 && track_count != 1) throw std::runtime_error("format 0 MIDI must contain one track");
  if (format == 2) throw std::runtime_error("format 2 MIDI is not supported");
  if (track_count == 0) throw std::runtime_error("MIDI file contains no tracks");
  if (division & 0x8000) throw std::runtime_error("SMPTE time division is not supported");
  if (division == 0) throw std::runtime_error("MIDI PPQ division must be nonzero");

  size_t pos = 8 + header_len;
  std::vector<RawEvent> raw_events;

  // MIDI specifies an implicit 120 BPM tempo until a Set Tempo meta event says
  // otherwise. Treat that as a real tempo event at tick 0 so the conversion loop
  // below can handle files with or without explicit tempo messages uniformly.
  std::vector<TempoEvent> tempos{{0, 500000, 0}};
  uint32_t event_order = 1;

  for (int tr = 0; tr < track_count; ++tr) {
    if (pos + 8 > data.size() || std::memcmp(data.data() + pos, "MTrk", 4) != 0) {
      throw std::runtime_error("missing MTrk chunk");
    }
    uint32_t size = read_u32be(data, pos + 4);
    pos += 8;
    if (size > data.size() - pos) throw std::runtime_error("truncated MIDI track");
    size_t end = pos + size;

    uint32_t tick = 0;
    int running_status = -1;

    while (pos < end) {
      uint32_t delta = read_varlen(data, pos, end);
      if (delta > std::numeric_limits<uint32_t>::max() - tick) {
        throw std::runtime_error("MIDI tick overflow");
      }
      tick += delta;
      require_track_bytes(pos, end, 1, "event");

      // MIDI running status omits repeated status bytes. Keep the last channel
      // status so dense files can be parsed without expanding the stream first.
      int status = data[pos];
      if (status & 0x80) {
        ++pos;
        if (status >= 0x80 && status <= 0xef) {
          running_status = status;
        } else {
          running_status = -1;
        }
      } else if (running_status >= 0) {
        status = running_status;
      } else {
        throw std::runtime_error("MIDI running status without previous status");
      }

      if (status == 0xff) {
        require_track_bytes(pos, end, 1, "meta event");
        uint8_t meta = data[pos++];
        uint32_t len = read_varlen(data, pos, end);
        require_track_bytes(pos, end, len, "meta payload");
        if (meta == 0x51 && len == 3) {
          // Set Tempo stores microseconds per quarter note in three big-endian
          // bytes. This value is not BPM; smaller numbers mean faster playback.
          uint32_t tempo = (uint32_t(data[pos]) << 16) |
                           (uint32_t(data[pos + 1]) << 8) | data[pos + 2];
          tempos.push_back({tick, tempo, event_order});
        }
        ++event_order;
        pos += len;
        continue;
      }

      if (status == 0xf0 || status == 0xf7) {
        uint32_t len = read_varlen(data, pos, end);
        require_track_bytes(pos, end, len, "sysex payload");
        ++event_order;
        pos += len;
        continue;
      }

      int type = status & 0xf0;
      int ch = status & 0x0f;
      int data_bytes = event_data_bytes(type);
      if (data_bytes == 0) {
        throw std::runtime_error("unsupported MIDI status");
      }
      int a = read_data_byte(data, pos, end, "channel event");
      int b = data_bytes == 2 ? read_data_byte(data, pos, end, "channel event") : 0;
      RawKind kind = RawKind::kNote;
      if (type == 0xb0) kind = RawKind::kControl;
      else if (type == 0xc0) kind = RawKind::kProgram;
      else if (type == 0xa0) kind = RawKind::kKeyPressure;
      else if (type == 0xe0) kind = RawKind::kPitchBend;
      else if (type == 0xd0) kind = RawKind::kChannelPressure;
      raw_events.push_back({tick, event_order++, kind, ch, a, b, type == 0x90});
    }
    pos = end;
  }

  std::sort(tempos.begin(), tempos.end(), [](const TempoEvent& a, const TempoEvent& b) {
    if (a.tick != b.tick) return a.tick < b.tick;
    return a.order < b.order;
  });
  std::sort(raw_events.begin(), raw_events.end(), [](const RawEvent& a, const RawEvent& b) {
    if (a.tick != b.tick) return a.tick < b.tick;
    return a.order < b.order;
  });

  std::array<int, 16> program{};
  std::array<int, 16> bank_msb{};
  std::array<int, 16> bank_lsb{};
  std::vector<TickEvent> tick_events;
  for (const RawEvent& raw : raw_events) {
    NoteEvent ev;
    ev.channel = raw.channel;
    ev.program = program[raw.channel];
    ev.bank = (bank_msb[raw.channel] << 7) | bank_lsb[raw.channel];
    switch (raw.kind) {
      case RawKind::kNote:
        // Note On with velocity zero is semantically Note Off, but it is still
        // stored as a note event so the MCU model can release the matching RTL
        // voice at the exact converted sample.
        ev.type = NoteEvent::EVENT_NOTE;
        ev.note = raw.a;
        ev.on = raw.note_on_status && raw.b != 0;
        ev.velocity = raw.b;
        break;
      case RawKind::kControl:
        if (raw.a == 0) bank_msb[raw.channel] = raw.b;
        else if (raw.a == 32) bank_lsb[raw.channel] = raw.b;
        ev.type = NoteEvent::EVENT_CONTROL;
        ev.bank = (bank_msb[raw.channel] << 7) | bank_lsb[raw.channel];
        ev.controller = raw.a & 0x7f;
        ev.value = raw.b & 0x7f;
        break;
      case RawKind::kProgram:
        program[raw.channel] = raw.a;
        continue;
      case RawKind::kKeyPressure:
        ev.type = NoteEvent::EVENT_KEY_PRESSURE;
        ev.note = raw.a & 0x7f;
        ev.value = raw.b & 0x7f;
        break;
      case RawKind::kPitchBend:
        ev.type = NoteEvent::EVENT_PITCH_BEND;
        ev.pitch_bend = ((raw.b & 0x7f) << 7 | (raw.a & 0x7f)) - 8192;
        break;
      case RawKind::kChannelPressure:
        ev.type = NoteEvent::EVENT_CHANNEL_PRESSURE;
        ev.value = raw.a & 0x7f;
        break;
    }
    tick_events.push_back({raw.tick, raw.order, ev});
  }
  std::sort(tick_events.begin(), tick_events.end(),
            [](const TickEvent& a, const TickEvent& b) {
              if (a.tick != b.tick) return a.tick < b.tick;
              return a.order < b.order;
            });

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
  // This fallback is used when a render target is run without a MIDI file. The times
  // are already seconds, so they bypass the MIDI tempo conversion path.
  std::vector<int> notes{60, 64, 67, 72, 67, 64, 60};
  std::vector<NoteEvent> events;
  for (size_t i = 0; i < notes.size(); ++i) {
    NoteEvent on;
    on.time_seconds = double(i) * 0.24;
    on.note = notes[i];
    on.on = true;
    on.velocity = 110;
    events.push_back(on);
    NoteEvent off;
    off.time_seconds = double(i) * 0.24 + 0.20;
    off.note = notes[i];
    off.on = false;
    off.velocity = 0;
    events.push_back(off);
  }
  return events;
}

}  // namespace render
