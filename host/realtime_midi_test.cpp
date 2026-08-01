#include "host/realtime_midi.h"

#include <cstdint>
#include <stdexcept>

namespace {

void test_decoder_running_status_and_timestamp() {
  host::MidiStreamDecoder decoder;
  host::TimestampedMidiEvent decoded;
  const uint8_t bytes[] = {
      0xb2, 0x00, 0x01, 0x20, 0x02,
      0xc2, 0x05,
      0x92, 0x3c, 0x64, 0x3d, 0x00,
      0xe2, 0x00, 0x40,
  };
  int emitted = 0;
  for (std::size_t index = 0; index < sizeof(bytes); ++index) {
    if (!decoder.feed(bytes[index], 1000 + index, decoded)) continue;
    ++emitted;
    if (emitted == 3) {
      if (!decoded.event.on || decoded.event.note != 60 ||
          decoded.event.velocity != 100 || decoded.event.channel != 2 ||
          decoded.event.program != 5 || decoded.event.bank != 130 ||
          decoded.timestamp_ns != 1009) {
        throw std::runtime_error("decoded Note On state/timestamp mismatch");
      }
    } else if (emitted == 4) {
      if (decoded.event.on || decoded.event.note != 61) {
        throw std::runtime_error("running-status velocity-zero Note Off mismatch");
      }
    } else if (emitted == 5 && decoded.event.pitch_bend != 0) {
      throw std::runtime_error("decoded pitch bend mismatch");
    }
  }
  if (emitted != 5) throw std::runtime_error("unexpected decoded event count");
}

void test_bounded_event_queue_overload_policy() {
  host::BoundedMidiEventQueue queue;
  host::TimestampedMidiEvent note;
  note.event.type = render::NoteEvent::EVENT_NOTE;
  note.event.on = true;
  for (std::size_t index = 0;
       index < host::BoundedMidiEventQueue::kCapacity -
                   host::BoundedMidiEventQueue::kLifecycleReserve;
       ++index) {
    note.timestamp_ns = index;
    if (queue.push(note) !=
        host::BoundedMidiEventQueue::PushResult::kQueued) {
      throw std::runtime_error("normal event reserve filled early");
    }
  }
  if (queue.push(note) != host::BoundedMidiEventQueue::PushResult::kDropped) {
    throw std::runtime_error("Note On was not rejected at lifecycle reserve");
  }
  host::TimestampedMidiEvent control;
  control.event.type = render::NoteEvent::EVENT_CONTROL;
  control.event.channel = 3;
  control.event.controller = 1;
  control.event.value = 10;
  if (queue.push(control) != host::BoundedMidiEventQueue::PushResult::kDropped) {
    throw std::runtime_error("unmatched controller was not dropped at reserve");
  }
  host::TimestampedMidiEvent note_off = note;
  note_off.event.on = false;
  if (queue.push(note_off) != host::BoundedMidiEventQueue::PushResult::kQueued) {
    throw std::runtime_error("Note Off did not use lifecycle reserve");
  }
  for (std::size_t index = 1;
       index < host::BoundedMidiEventQueue::kLifecycleReserve; ++index) {
    note_off.event.note = int(index & 0x7f);
    if (queue.push(note_off) != host::BoundedMidiEventQueue::PushResult::kQueued) {
      throw std::runtime_error("lifecycle reserve filled early");
    }
  }
  host::TimestampedMidiEvent all_sound_off;
  all_sound_off.event.type = render::NoteEvent::EVENT_CONTROL;
  all_sound_off.event.controller = 120;
  if (queue.push(all_sound_off) !=
      host::BoundedMidiEventQueue::PushResult::kLifecycleOverflow) {
    throw std::runtime_error("full lifecycle queue did not report overflow");
  }
  const host::MidiEventQueueStats stats = queue.stats();
  if (stats.dropped_note_on != 1 || stats.dropped_replaceable != 1 ||
      stats.lifecycle_overflows != 1 ||
      stats.high_water != host::BoundedMidiEventQueue::kCapacity) {
    throw std::runtime_error("MIDI queue overload counters mismatch");
  }
}

}  // namespace

int main() {
  test_decoder_running_status_and_timestamp();
  test_bounded_event_queue_overload_policy();
  return 0;
}
