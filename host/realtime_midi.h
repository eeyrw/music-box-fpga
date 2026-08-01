#pragma once

#include "sim/harness/render/render_types.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace host {

struct TimestampedMidiEvent {
  uint64_t timestamp_ns = 0;
  render::NoteEvent event;
};

class MidiStreamDecoder {
 public:
  bool feed(uint8_t byte, uint64_t timestamp_ns,
            TimestampedMidiEvent& decoded);
  void reset();

 private:
  static int data_byte_count(uint8_t status);
  bool finish_message(uint64_t timestamp_ns, TimestampedMidiEvent& decoded);

  std::array<int, 16> program_{};
  std::array<int, 16> bank_msb_{};
  std::array<int, 16> bank_lsb_{};
  uint8_t running_status_ = 0;
  uint8_t status_ = 0;
  std::array<uint8_t, 2> data_{};
  uint8_t data_count_ = 0;
  uint8_t expected_data_ = 0;
  uint8_t system_bytes_remaining_ = 0;
  bool in_sysex_ = false;
};

struct MidiEventQueueStats {
  uint64_t enqueued = 0;
  uint64_t dequeued = 0;
  uint64_t coalesced = 0;
  uint64_t dropped_replaceable = 0;
  uint64_t dropped_note_on = 0;
  uint64_t lifecycle_overflows = 0;
  uint32_t high_water = 0;
  uint32_t depth = 0;
};

class BoundedMidiEventQueue {
 public:
  enum class PushResult { kQueued, kCoalesced, kDropped, kLifecycleOverflow };
  static constexpr std::size_t kCapacity = 2048;
  static constexpr std::size_t kLifecycleReserve = 256;

  PushResult push(const TimestampedMidiEvent& event);
  bool pop(TimestampedMidiEvent& event);
  MidiEventQueueStats stats() const;

 private:
  static bool lifecycle_event(const render::NoteEvent& event);
  static bool replaceable_event(const render::NoteEvent& event);
  static bool same_replacement_key(const render::NoteEvent& left,
                                   const render::NoteEvent& right);

  mutable std::mutex mutex_;
  std::array<TimestampedMidiEvent, kCapacity> events_{};
  std::size_t head_ = 0;
  std::size_t tail_ = 0;
  std::size_t count_ = 0;
  MidiEventQueueStats stats_;
};

}  // namespace host
