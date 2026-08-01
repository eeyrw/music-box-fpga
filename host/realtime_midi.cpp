#include "host/realtime_midi.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace host {

int MidiStreamDecoder::data_byte_count(uint8_t status) {
  switch (status & 0xf0u) {
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

void MidiStreamDecoder::reset() {
  program_.fill(0);
  bank_msb_.fill(0);
  bank_lsb_.fill(0);
  running_status_ = 0;
  status_ = 0;
  data_count_ = 0;
  expected_data_ = 0;
  system_bytes_remaining_ = 0;
  in_sysex_ = false;
}

bool MidiStreamDecoder::feed(uint8_t byte, uint64_t timestamp_ns,
                             TimestampedMidiEvent& decoded) {
  if (byte >= 0xf8u) return false;
  if (in_sysex_) {
    if (byte == 0xf7u) in_sysex_ = false;
    return false;
  }
  if ((byte & 0x80u) != 0) system_bytes_remaining_ = 0;
  if (system_bytes_remaining_ != 0) {
    --system_bytes_remaining_;
    return false;
  }
  if ((byte & 0x80u) != 0) {
    data_count_ = 0;
    if (byte >= 0x80u && byte <= 0xefu) {
      status_ = byte;
      running_status_ = byte;
      expected_data_ = uint8_t(data_byte_count(byte));
    } else {
      running_status_ = 0;
      status_ = 0;
      expected_data_ = 0;
      if (byte == 0xf0u) in_sysex_ = true;
      else if (byte == 0xf1u || byte == 0xf3u) system_bytes_remaining_ = 1;
      else if (byte == 0xf2u) system_bytes_remaining_ = 2;
    }
    return false;
  }
  if (status_ == 0) {
    if (running_status_ == 0) return false;
    status_ = running_status_;
    expected_data_ = uint8_t(data_byte_count(status_));
  }
  if (data_count_ < data_.size()) data_[data_count_++] = byte;
  if (data_count_ != expected_data_) return false;
  const bool emitted = finish_message(timestamp_ns, decoded);
  data_count_ = 0;
  status_ = running_status_;
  expected_data_ = uint8_t(data_byte_count(status_));
  return emitted;
}

bool MidiStreamDecoder::finish_message(uint64_t timestamp_ns,
                                       TimestampedMidiEvent& decoded) {
  const int channel = status_ & 0x0f;
  const int type = status_ & 0xf0;
  render::NoteEvent event;
  event.channel = channel;
  event.program = program_[channel];
  event.bank = (bank_msb_[channel] << 7) | bank_lsb_[channel];
  if (type == 0x80 || type == 0x90) {
    event.type = render::NoteEvent::EVENT_NOTE;
    event.note = data_[0] & 0x7f;
    event.velocity = data_[1] & 0x7f;
    event.on = type == 0x90 && event.velocity != 0;
  } else if (type == 0xa0) {
    event.type = render::NoteEvent::EVENT_KEY_PRESSURE;
    event.note = data_[0] & 0x7f;
    event.value = data_[1] & 0x7f;
  } else if (type == 0xb0) {
    event.type = render::NoteEvent::EVENT_CONTROL;
    event.controller = data_[0] & 0x7f;
    event.value = data_[1] & 0x7f;
    if (event.controller == 0) bank_msb_[channel] = event.value;
    if (event.controller == 32) bank_lsb_[channel] = event.value;
    event.bank = (bank_msb_[channel] << 7) | bank_lsb_[channel];
  } else if (type == 0xc0) {
    program_[channel] = data_[0] & 0x7f;
    return false;
  } else if (type == 0xd0) {
    event.type = render::NoteEvent::EVENT_CHANNEL_PRESSURE;
    event.value = data_[0] & 0x7f;
  } else if (type == 0xe0) {
    event.type = render::NoteEvent::EVENT_PITCH_BEND;
    event.pitch_bend = ((int(data_[1]) << 7) | int(data_[0])) - 8192;
  } else {
    return false;
  }
  decoded.timestamp_ns = timestamp_ns;
  decoded.event = event;
  return true;
}

bool BoundedMidiEventQueue::lifecycle_event(const render::NoteEvent& event) {
  if (event.type == render::NoteEvent::EVENT_NOTE) return !event.on;
  if (event.type != render::NoteEvent::EVENT_CONTROL) return false;
  return event.controller == 120 || event.controller == 123 ||
         (event.controller >= 124 && event.controller <= 127);
}

bool BoundedMidiEventQueue::replaceable_event(const render::NoteEvent& event) {
  return event.type == render::NoteEvent::EVENT_CONTROL ||
         event.type == render::NoteEvent::EVENT_PITCH_BEND ||
         event.type == render::NoteEvent::EVENT_CHANNEL_PRESSURE ||
         event.type == render::NoteEvent::EVENT_KEY_PRESSURE;
}

bool BoundedMidiEventQueue::same_replacement_key(
    const render::NoteEvent& left, const render::NoteEvent& right) {
  if (left.type != right.type || left.channel != right.channel) return false;
  if (left.type == render::NoteEvent::EVENT_CONTROL) {
    return left.controller == right.controller;
  }
  if (left.type == render::NoteEvent::EVENT_KEY_PRESSURE) {
    return left.note == right.note;
  }
  return true;
}

BoundedMidiEventQueue::PushResult BoundedMidiEventQueue::push(
    const TimestampedMidiEvent& event) {
  std::lock_guard<std::mutex> lock(mutex_);
  const bool lifecycle = lifecycle_event(event.event);
  const std::size_t normal_limit = kCapacity - kLifecycleReserve;
  if ((!lifecycle && count_ >= normal_limit) || count_ == kCapacity) {
    if (lifecycle) {
      ++stats_.lifecycle_overflows;
      return PushResult::kLifecycleOverflow;
    }
    if (replaceable_event(event.event)) {
      for (std::size_t offset = 0; offset < count_; ++offset) {
        const std::size_t index = (head_ + count_ - 1 - offset) % kCapacity;
        if (same_replacement_key(events_[index].event, event.event)) {
          events_[index] = event;
          ++stats_.coalesced;
          return PushResult::kCoalesced;
        }
      }
      ++stats_.dropped_replaceable;
      return PushResult::kDropped;
    }
    ++stats_.dropped_note_on;
    return PushResult::kDropped;
  }
  events_[tail_] = event;
  tail_ = (tail_ + 1) % kCapacity;
  ++count_;
  ++stats_.enqueued;
  stats_.depth = uint32_t(count_);
  stats_.high_water = std::max(stats_.high_water, uint32_t(count_));
  return PushResult::kQueued;
}

bool BoundedMidiEventQueue::pop(TimestampedMidiEvent& event) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (count_ == 0) return false;
  event = events_[head_];
  head_ = (head_ + 1) % kCapacity;
  --count_;
  ++stats_.dequeued;
  stats_.depth = uint32_t(count_);
  return true;
}

MidiEventQueueStats BoundedMidiEventQueue::stats() const {
  std::lock_guard<std::mutex> lock(mutex_);
  MidiEventQueueStats snapshot = stats_;
  snapshot.depth = uint32_t(count_);
  return snapshot;
}

MidiFilePlayback::MidiFilePlayback(std::vector<render::NoteEvent> events,
                                   uint64_t start_timestamp_ns)
    : end_timestamp_ns_(start_timestamp_ns) {
  events_.reserve(events.size());
  double previous_seconds = 0.0;
  for (const render::NoteEvent& event : events) {
    if (!std::isfinite(event.time_seconds) || event.time_seconds < 0.0) {
      throw std::runtime_error("MIDI file event time must be finite and nonnegative");
    }
    if (!events_.empty() && event.time_seconds < previous_seconds) {
      throw std::runtime_error("MIDI file events must be ordered by time");
    }
    const long double delay_ns =
        static_cast<long double>(event.time_seconds) * 1000000000.0L;
    const long double maximum_delay = std::min(
        static_cast<long double>(std::numeric_limits<uint64_t>::max() -
                                 start_timestamp_ns),
        static_cast<long double>(std::numeric_limits<long long>::max()));
    if (delay_ns > maximum_delay) {
      throw std::runtime_error("MIDI file duration exceeds monotonic clock range");
    }
    const uint64_t timestamp_ns =
        start_timestamp_ns + static_cast<uint64_t>(std::llround(delay_ns));
    events_.push_back({timestamp_ns, event});
    end_timestamp_ns_ = timestamp_ns;
    previous_seconds = event.time_seconds;
  }
}

std::size_t MidiFilePlayback::enqueue_due(
    uint64_t now_ns, BoundedMidiEventQueue& queue) {
  std::size_t count = 0;
  while (next_event_ < events_.size() &&
         events_[next_event_].timestamp_ns <= now_ns) {
    const BoundedMidiEventQueue::PushResult result =
        queue.push(events_[next_event_]);
    if (result == BoundedMidiEventQueue::PushResult::kLifecycleOverflow) {
      lifecycle_overflow_ = true;
      break;
    }
    ++next_event_;
    ++count;
  }
  return count;
}

}  // namespace host
