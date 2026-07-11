#include "midi_parser.h"

#include "byte_reader.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <stdexcept>

namespace render {
namespace {

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
  uint32_t tick = 0;
  NoteEvent event;
};

}  // namespace

std::vector<NoteEvent> parse_midi(const std::string& path) {
  auto data = read_file(path);
  if (data.size() < 14 || std::memcmp(data.data(), "MThd", 4) != 0) {
    throw std::runtime_error("not a standard MIDI file");
  }

  uint32_t header_len = read_u32be(data, 4);
  uint16_t track_count = read_u16be(data, 10);
  uint16_t division = read_u16be(data, 12);
  if (division & 0x8000) throw std::runtime_error("SMPTE time division is not supported");

  size_t pos = 8 + header_len;
  std::vector<TickEvent> tick_events;
  std::vector<std::pair<uint32_t, uint32_t>> tempos{{0, 500000}};

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
          uint32_t tempo = (uint32_t(data[pos]) << 16) |
                           (uint32_t(data[pos + 1]) << 8) | data[pos + 2];
          tempos.push_back({tick, tempo});
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
        if (controller == 0) bank_msb[ch] = value;
        else if (controller == 32) bank_lsb[ch] = value;
      } else if (type == 0xc0) {
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

  std::sort(tempos.begin(), tempos.end());
  std::sort(tick_events.begin(), tick_events.end(),
            [](const TickEvent& a, const TickEvent& b) { return a.tick < b.tick; });

  // Tempo changes are global in standard MIDI files. Walk the tempo map once and
  // convert each absolute tick to seconds before the renderer maps it to samples.
  std::vector<NoteEvent> events;
  size_t tempo_index = 0;
  uint32_t last_tick = 0;
  double last_seconds = 0.0;
  uint32_t tempo = tempos.front().second;
  for (auto te : tick_events) {
    while (tempo_index + 1 < tempos.size() && tempos[tempo_index + 1].first <= te.tick) {
      auto next = tempos[++tempo_index];
      last_seconds += double(next.first - last_tick) * double(tempo) / double(division) / 1000000.0;
      last_tick = next.first;
      tempo = next.second;
    }
    te.event.time_seconds = last_seconds + double(te.tick - last_tick) * double(tempo) / double(division) / 1000000.0;
    events.push_back(te.event);
  }
  return events;
}

std::vector<NoteEvent> default_melody() {
  std::vector<int> notes{60, 64, 67, 72, 67, 64, 60};
  std::vector<NoteEvent> events;
  for (size_t i = 0; i < notes.size(); ++i) {
    events.push_back({double(i) * 0.24, notes[i], true, 110, 0, 0, 0});
    events.push_back({double(i) * 0.24 + 0.20, notes[i], false, 0, 0, 0, 0});
  }
  return events;
}

}  // namespace render
