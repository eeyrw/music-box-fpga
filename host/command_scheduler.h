#pragma once

#include "sim/harness/control/command_control.h"

#include <array>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>

namespace host {

constexpr std::size_t kSchedulerLifecycleCapacity = 2048;
constexpr std::size_t kSchedulerNormalCapacity = 512;
constexpr std::size_t kMaxTransactionWords = 63;

struct CommandSchedulerStats {
  uint64_t enqueued_commands = 0;
  uint64_t emitted_commands = 0;
  uint64_t emitted_transactions = 0;
  uint64_t coalesced_updates = 0;
  uint64_t dropped_replaceable_updates = 0;
  uint64_t transport_errors = 0;
  uint64_t abandoned_commands = 0;
  uint32_t consecutive_transport_errors = 0;
  uint32_t maximum_consecutive_transport_errors = 0;
  uint64_t driver_total_ns = 0;
  uint64_t driver_max_ns = 0;
  uint64_t maximum_command_age_ns = 0;
  uint64_t transaction_words_total = 0;
  uint32_t maximum_transaction_words = 0;
  uint32_t queue_high_water = 0;
  uint32_t pending_commands = 0;
};

class DryRunCommandTransport final : public render::CommandWordSink {
 public:
  void write_command_words(render::CommandWordView words) override;
  void fail_next_transactions(uint32_t count) { failures_remaining_ = count; }
  void set_latency(std::chrono::microseconds latency) { latency_ = latency; }

  uint64_t transaction_count() const { return transaction_count_; }
  uint64_t word_count() const { return word_count_; }
  uint32_t maximum_transaction_words() const { return maximum_transaction_words_; }
  render::CommandWordView last_transaction() const {
    return {last_words_.data(), last_word_count_};
  }

 private:
  std::array<uint32_t, kMaxTransactionWords> last_words_{};
  uint8_t last_word_count_ = 0;
  uint32_t failures_remaining_ = 0;
  std::chrono::microseconds latency_{0};
  uint64_t transaction_count_ = 0;
  uint64_t word_count_ = 0;
  uint32_t maximum_transaction_words_ = 0;
};

class AsyncCommandScheduler final : public render::CommandWordSink {
 public:
  class BatchGuard {
   public:
    explicit BatchGuard(AsyncCommandScheduler& scheduler);
    ~BatchGuard();
    BatchGuard(const BatchGuard&) = delete;
    BatchGuard& operator=(const BatchGuard&) = delete;
    BatchGuard(BatchGuard&& other) noexcept;

   private:
    AsyncCommandScheduler* scheduler_ = nullptr;
  };

  explicit AsyncCommandScheduler(
      std::unique_ptr<render::CommandWordSink> transport);
  ~AsyncCommandScheduler() override;
  AsyncCommandScheduler(const AsyncCommandScheduler&) = delete;
  AsyncCommandScheduler& operator=(const AsyncCommandScheduler&) = delete;

  void write_command_words(render::CommandWordView words) override;
  BatchGuard batch() { return BatchGuard(*this); }
  bool wait_idle(std::chrono::milliseconds timeout);
  CommandSchedulerStats stats() const;
  void shutdown();

 private:
  struct PendingCommand {
    render::FixedCommand command;
    uint64_t enqueue_ns = 0;
  };

  template <std::size_t Capacity>
  struct FixedQueue {
    std::array<PendingCommand, Capacity> entries{};
    std::size_t head = 0;
    std::size_t tail = 0;
    std::size_t count = 0;
  };

  struct ReplaceableCommand {
    PendingCommand pending;
    uint16_t generation = 0;
    bool valid = false;
  };

  static uint64_t monotonic_ns();
  static bool lifecycle_opcode(uint8_t opcode);
  static int replaceable_kind(uint8_t opcode);
  static int command_voice(render::CommandWordView command);
  static uint16_t command_generation(render::CommandWordView command);
  static PendingCommand copy_command(render::CommandWordView command);

  template <std::size_t Capacity>
  static void push_queue(FixedQueue<Capacity>& queue,
                         const PendingCommand& command,
                         const char* overflow_message);
  template <std::size_t Capacity>
  static bool pop_queue(FixedQueue<Capacity>& queue, PendingCommand& command);

  void begin_batch();
  void end_batch();
  void enqueue_one(render::CommandWordView command);
  void invalidate_updates(int voice, uint16_t generation, bool all);
  void clear_replaceable_updates();
  std::size_t pending_count_locked() const;
  bool has_pending_locked() const;
  bool take_next_locked(PendingCommand& command);
  void return_command_locked(const PendingCommand& command);
  void worker_main();

  std::unique_ptr<render::CommandWordSink> transport_;
  mutable std::mutex mutex_;
  std::condition_variable work_available_;
  std::condition_variable idle_;
  FixedQueue<kSchedulerLifecycleCapacity> lifecycle_;
  FixedQueue<kSchedulerNormalCapacity> normal_;
  std::array<std::array<ReplaceableCommand, 3>, render::kNumVoices>
      replaceable_{};
  std::size_t replaceable_count_ = 0;
  std::size_t replaceable_cursor_ = 0;
  std::size_t producer_batch_depth_ = 0;
  bool worker_busy_ = false;
  bool stopping_ = false;
  bool stopped_ = false;
  CommandSchedulerStats stats_;
  std::thread worker_;
};

}  // namespace host
