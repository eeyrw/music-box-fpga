#include "host/command_scheduler.h"

#include "host/ch347_transport.h"

#include <algorithm>
#include <stdexcept>

namespace host {

void DryRunCommandTransport::write_command_words(render::CommandWordView words) {
  Ch347RegisterTransport::validate_command_transaction(words);
  if (failures_remaining_ != 0) {
    --failures_remaining_;
    throw std::runtime_error("injected dry-run transport failure");
  }
  if (latency_.count() != 0) std::this_thread::sleep_for(latency_);
  last_word_count_ = uint8_t(words.size());
  std::copy(words.begin(), words.end(), last_words_.begin());
  ++transaction_count_;
  word_count_ += words.size();
  maximum_transaction_words_ = std::max(
      maximum_transaction_words_, uint32_t(words.size()));
}

AsyncCommandScheduler::BatchGuard::BatchGuard(
    AsyncCommandScheduler& scheduler)
    : scheduler_(&scheduler) {
  scheduler_->begin_batch();
}

AsyncCommandScheduler::BatchGuard::~BatchGuard() {
  if (scheduler_) scheduler_->end_batch();
}

AsyncCommandScheduler::BatchGuard::BatchGuard(BatchGuard&& other) noexcept
    : scheduler_(other.scheduler_) {
  other.scheduler_ = nullptr;
}

AsyncCommandScheduler::AsyncCommandScheduler(
    std::unique_ptr<render::CommandWordSink> transport)
    : transport_(std::move(transport)) {
  if (!transport_) throw std::invalid_argument("command scheduler transport is null");
  worker_ = std::thread(&AsyncCommandScheduler::worker_main, this);
}

AsyncCommandScheduler::~AsyncCommandScheduler() { shutdown(); }

uint64_t AsyncCommandScheduler::monotonic_ns() {
  return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count());
}

bool AsyncCommandScheduler::lifecycle_opcode(uint8_t opcode) {
  return opcode == 0x10 || opcode == 0x14 || opcode == 0x15;
}

int AsyncCommandScheduler::replaceable_kind(uint8_t opcode) {
  if (opcode == 0x16) return 0;
  if (opcode == 0x18) return 1;
  if (opcode == 0x17) return 2;
  return -1;
}

int AsyncCommandScheduler::command_voice(render::CommandWordView command) {
  return int((command[0] >> 14) & 0x3ffu);
}

uint16_t AsyncCommandScheduler::command_generation(
    render::CommandWordView command) {
  return command.size() > 1 ? uint16_t(command[1]) : 0;
}

AsyncCommandScheduler::PendingCommand AsyncCommandScheduler::copy_command(
    render::CommandWordView command) {
  if (command.empty() || command.size() > render::kMaxCommandWords) {
    throw std::invalid_argument("scheduler received an invalid command length");
  }
  PendingCommand pending;
  for (uint32_t word : command) pending.command.push_back(word);
  pending.enqueue_ns = monotonic_ns();
  return pending;
}

template <std::size_t Capacity>
void AsyncCommandScheduler::push_queue(
    FixedQueue<Capacity>& queue, const PendingCommand& command,
    const char* overflow_message) {
  if (queue.count == Capacity) throw std::overflow_error(overflow_message);
  queue.entries[queue.tail] = command;
  queue.tail = (queue.tail + 1) % Capacity;
  ++queue.count;
}

template <std::size_t Capacity>
bool AsyncCommandScheduler::pop_queue(
    FixedQueue<Capacity>& queue, PendingCommand& command) {
  if (queue.count == 0) return false;
  command = queue.entries[queue.head];
  queue.head = (queue.head + 1) % Capacity;
  --queue.count;
  return true;
}

void AsyncCommandScheduler::begin_batch() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopping_) throw std::runtime_error("command scheduler is stopping");
  ++producer_batch_depth_;
}

void AsyncCommandScheduler::end_batch() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (producer_batch_depth_ == 0) return;
  --producer_batch_depth_;
  if (producer_batch_depth_ == 0) work_available_.notify_one();
}

void AsyncCommandScheduler::write_command_words(render::CommandWordView words) {
  if (words.empty()) return;
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopping_) throw std::runtime_error("command scheduler is stopping");
  std::size_t offset = 0;
  while (offset < words.size()) {
    const std::size_t command_words = std::size_t(words[offset] & 0xffu) + 1u;
    if (command_words > render::kMaxCommandWords ||
        command_words > words.size() - offset) {
      throw std::invalid_argument("scheduler received incomplete command words");
    }
    enqueue_one({words.data() + offset, command_words});
    offset += command_words;
  }
  if (producer_batch_depth_ == 0) work_available_.notify_one();
}

void AsyncCommandScheduler::invalidate_updates(
    int voice, uint16_t generation, bool all) {
  if (voice < 0 || voice >= render::kNumVoices) return;
  for (ReplaceableCommand& update : replaceable_[voice]) {
    if (update.valid && (all || update.generation != generation)) {
      update.valid = false;
      --replaceable_count_;
      ++stats_.dropped_replaceable_updates;
    }
  }
}

void AsyncCommandScheduler::clear_replaceable_updates() {
  for (auto& voice : replaceable_) {
    for (ReplaceableCommand& update : voice) {
      if (!update.valid) continue;
      update.valid = false;
      --replaceable_count_;
      ++stats_.dropped_replaceable_updates;
    }
  }
}

void AsyncCommandScheduler::enqueue_one(render::CommandWordView command) {
  const uint8_t opcode = uint8_t(command[0] >> 24);
  const int voice = command_voice(command);
  const uint16_t generation = command_generation(command);
  const PendingCommand pending = copy_command(command);
  if (opcode == 0x10) invalidate_updates(voice, generation, false);
  if (opcode == 0x15) invalidate_updates(voice, generation, true);

  const int kind = replaceable_kind(opcode);
  if (kind >= 0 && voice >= 0 && voice < render::kNumVoices) {
    ReplaceableCommand& slot = replaceable_[voice][kind];
    if (slot.valid) {
      ++stats_.coalesced_updates;
    } else {
      slot.valid = true;
      ++replaceable_count_;
    }
    slot.pending = pending;
    slot.generation = generation;
  } else if (lifecycle_opcode(opcode)) {
    push_queue(lifecycle_, pending, "lifecycle command queue overflow");
  } else {
    push_queue(normal_, pending, "normal command queue overflow");
  }
  ++stats_.enqueued_commands;
  const std::size_t depth = pending_count_locked();
  stats_.pending_commands = uint32_t(depth);
  stats_.queue_high_water = std::max(stats_.queue_high_water, uint32_t(depth));
}

std::size_t AsyncCommandScheduler::pending_count_locked() const {
  return lifecycle_.count + normal_.count + replaceable_count_;
}

bool AsyncCommandScheduler::has_pending_locked() const {
  return pending_count_locked() != 0;
}

bool AsyncCommandScheduler::take_next_locked(PendingCommand& command) {
  if (pop_queue(lifecycle_, command)) return true;
  if (pop_queue(normal_, command)) return true;
  constexpr std::size_t kSlotCount = render::kNumVoices * 3u;
  for (std::size_t scanned = 0; scanned < kSlotCount; ++scanned) {
    const std::size_t flat = (replaceable_cursor_ + scanned) % kSlotCount;
    ReplaceableCommand& slot = replaceable_[flat / 3u][flat % 3u];
    if (!slot.valid) continue;
    command = slot.pending;
    slot.valid = false;
    --replaceable_count_;
    replaceable_cursor_ = (flat + 1u) % kSlotCount;
    return true;
  }
  return false;
}

void AsyncCommandScheduler::return_command_locked(
    const PendingCommand& command) {
  const uint8_t opcode = uint8_t(command.command.words[0] >> 24);
  if (lifecycle_opcode(opcode)) {
    lifecycle_.head = (lifecycle_.head + lifecycle_.entries.size() - 1) %
                      lifecycle_.entries.size();
    lifecycle_.entries[lifecycle_.head] = command;
    ++lifecycle_.count;
    return;
  }
  const int kind = replaceable_kind(opcode);
  const int voice = command_voice(command.command.view());
  if (kind >= 0 && voice >= 0 && voice < render::kNumVoices) {
    ReplaceableCommand& slot = replaceable_[voice][kind];
    if (!slot.valid) {
      slot.valid = true;
      ++replaceable_count_;
    }
    slot.pending = command;
    slot.generation = command_generation(command.command.view());
    return;
  }
  normal_.head = (normal_.head + normal_.entries.size() - 1) %
                 normal_.entries.size();
  normal_.entries[normal_.head] = command;
  ++normal_.count;
}

bool AsyncCommandScheduler::wait_idle(std::chrono::milliseconds timeout) {
  std::unique_lock<std::mutex> lock(mutex_);
  return idle_.wait_for(lock, timeout, [&] {
    return !worker_busy_ && !has_pending_locked();
  });
}

CommandSchedulerStats AsyncCommandScheduler::stats() const {
  std::lock_guard<std::mutex> lock(mutex_);
  CommandSchedulerStats snapshot = stats_;
  snapshot.pending_commands = uint32_t(pending_count_locked());
  return snapshot;
}

void AsyncCommandScheduler::shutdown() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopped_) return;
    stopping_ = true;
    producer_batch_depth_ = 0;
  }
  work_available_.notify_all();
  if (worker_.joinable()) worker_.join();
  std::lock_guard<std::mutex> lock(mutex_);
  stopped_ = true;
}

void AsyncCommandScheduler::worker_main() {
  std::array<uint32_t, kMaxTransactionWords> transaction{};
  while (true) {
    std::size_t transaction_words = 0;
    std::size_t command_count = 0;
    uint64_t oldest_enqueue_ns = 0;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      work_available_.wait(lock, [&] {
        return stopping_ || (producer_batch_depth_ == 0 && has_pending_locked());
      });
      if (stopping_ && !has_pending_locked()) break;
      if (producer_batch_depth_ != 0) continue;
      worker_busy_ = true;
      PendingCommand pending;
      while (take_next_locked(pending)) {
        const std::size_t length = pending.command.length;
        if (transaction_words != 0 &&
            transaction_words + length > transaction.size()) {
          return_command_locked(pending);
          break;
        }
        std::copy_n(pending.command.words.begin(), length,
                    transaction.begin() + transaction_words);
        transaction_words += length;
        ++command_count;
        if (oldest_enqueue_ns == 0 || pending.enqueue_ns < oldest_enqueue_ns) {
          oldest_enqueue_ns = pending.enqueue_ns;
        }
        if (transaction_words == transaction.size()) break;
      }
      stats_.pending_commands = uint32_t(pending_count_locked());
    }

    bool delivered = false;
    bool abandon = false;
    while (!delivered && !abandon) {
      const uint64_t driver_start = monotonic_ns();
      try {
        transport_->write_command_words(
            {transaction.data(), transaction_words});
        delivered = true;
      } catch (const std::exception&) {
        const uint64_t elapsed = monotonic_ns() - driver_start;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          ++stats_.transport_errors;
          ++stats_.consecutive_transport_errors;
          stats_.maximum_consecutive_transport_errors = std::max(
              stats_.maximum_consecutive_transport_errors,
              stats_.consecutive_transport_errors);
          stats_.driver_total_ns += elapsed;
          stats_.driver_max_ns = std::max(stats_.driver_max_ns, elapsed);
          abandon = stopping_;
        }
        if (!abandon) std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
      if (delivered) {
        const uint64_t now = monotonic_ns();
        const uint64_t elapsed = now - driver_start;
        std::lock_guard<std::mutex> lock(mutex_);
        stats_.consecutive_transport_errors = 0;
        stats_.driver_total_ns += elapsed;
        stats_.driver_max_ns = std::max(stats_.driver_max_ns, elapsed);
        if (oldest_enqueue_ns != 0) {
          stats_.maximum_command_age_ns = std::max(
              stats_.maximum_command_age_ns, now - oldest_enqueue_ns);
        }
        stats_.emitted_commands += command_count;
        ++stats_.emitted_transactions;
        stats_.transaction_words_total += transaction_words;
        stats_.maximum_transaction_words = std::max(
            stats_.maximum_transaction_words, uint32_t(transaction_words));
      }
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (abandon) stats_.abandoned_commands += command_count;
      worker_busy_ = false;
      if (!has_pending_locked()) idle_.notify_all();
    }
  }
  std::lock_guard<std::mutex> lock(mutex_);
  worker_busy_ = false;
  idle_.notify_all();
}

}  // namespace host
