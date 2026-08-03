#include "host/command_scheduler.h"

#include "host/ch347_transport.h"

#include <array>
#include <chrono>
#include <cstdint>
#include <memory>
#include <limits>
#include <stdexcept>
#include <thread>

namespace {

class RecordingTransport final : public render::CommandWordSink {
 public:
  void write_command_words(render::CommandWordView words) override {
    host::Ch347CommandTransport::validate_command_transaction(words);
    if (failures_remaining != 0) {
      --failures_remaining;
      throw std::runtime_error("injected transport failure");
    }
    if (transaction_count >= transactions.size()) {
      throw std::runtime_error("recording transport overflow");
    }
    Transaction& transaction = transactions[transaction_count++];
    transaction.length = uint8_t(words.size());
    std::copy(words.begin(), words.end(), transaction.words.begin());
  }

  struct Transaction {
    std::array<uint32_t, host::kMaxTransactionWords> words{};
    uint8_t length = 0;
  };

  std::array<Transaction, 16> transactions{};
  std::size_t transaction_count = 0;
  uint32_t failures_remaining = 0;
};

render::FixedCommand command(uint8_t opcode, int voice,
                             std::initializer_list<uint32_t> payload) {
  render::FixedCommand result;
  result.push_back((uint32_t(opcode) << 24) |
                   (uint32_t(voice & 0x3ff) << 14) |
                   uint32_t(payload.size()));
  for (uint32_t word : payload) result.push_back(word);
  return result;
}

void test_priority_coalescing_batch_and_retry() {
  auto transport = std::make_unique<RecordingTransport>();
  RecordingTransport* recording = transport.get();
  recording->failures_remaining = 1;
  host::AsyncCommandScheduler scheduler(std::move(transport));
  {
    auto batch = scheduler.batch();
    const render::FixedCommand start_left = command(
        0x10, 4, {7, 0x1000, 64, 0x100, 0x40004000});
    const render::FixedCommand start_right = command(
        0x10, 5, {9, 0x2000, 64, 0x100, 0x40004000});
    scheduler.write_command_words(start_left.view());
    scheduler.write_command_words(start_right.view());
    for (uint32_t phase = 0x101; phase <= 0x10a; ++phase) {
      const render::FixedCommand pitch = command(0x18, 4, {7, phase});
      scheduler.write_command_words(pitch.view());
    }
    const render::FixedCommand stop = command(0x15, 5, {9});
    scheduler.write_command_words(stop.view());
  }
  if (!scheduler.wait_idle(std::chrono::seconds(2))) {
    throw std::runtime_error("scheduler did not drain");
  }
  const host::CommandSchedulerStats stats = scheduler.stats();
  if (recording->transaction_count != 1 ||
      recording->transactions[0].length != 17 ||
      uint8_t(recording->transactions[0].words[0] >> 24) != 0x10 ||
      uint8_t(recording->transactions[0].words[6] >> 24) != 0x10 ||
      uint8_t(recording->transactions[0].words[12] >> 24) != 0x15 ||
      uint8_t(recording->transactions[0].words[14] >> 24) != 0x18 ||
      recording->transactions[0].words[16] != 0x10a ||
      stats.coalesced_updates != 9 || stats.transport_errors != 1 ||
      stats.emitted_commands != 4 || stats.emitted_transactions != 1 ||
      stats.maximum_transaction_words != 17 || stats.pending_commands != 0) {
    throw std::runtime_error("scheduler priority/coalescing/retry mismatch");
  }
}

void test_transaction_word_limit() {
  auto transport = std::make_unique<RecordingTransport>();
  RecordingTransport* recording = transport.get();
  host::AsyncCommandScheduler scheduler(std::move(transport));
  {
    auto batch = scheduler.batch();
    for (int voice = 0; voice < 12; ++voice) {
      const render::FixedCommand start = command(
          0x10, voice, {uint32_t(voice + 1), uint32_t(voice * 64), 64,
                        0x100, 0x40004000});
      scheduler.write_command_words(start.view());
    }
  }
  if (!scheduler.wait_idle(std::chrono::seconds(2))) {
    throw std::runtime_error("scheduler word-limit case did not drain");
  }
  if (recording->transaction_count != 2 ||
      recording->transactions[0].length != 60 ||
      recording->transactions[1].length != 12) {
    throw std::runtime_error("scheduler did not coalesce complete commands");
  }
}

void test_dry_run_transport() {
  host::DryRunCommandTransport transport;
  const render::FixedCommand stop = command(0x15, 2, {3});
  transport.write_command_words(stop.view());
  if (transport.transaction_count() != 1 || transport.word_count() != 2 ||
      transport.maximum_transaction_words() != 2 ||
      transport.last_transaction()[1] != 3) {
    throw std::runtime_error("dry-run command transport mismatch");
  }
}

void test_shutdown_reports_abandoned_transaction() {
  auto transport = std::make_unique<RecordingTransport>();
  transport->failures_remaining = std::numeric_limits<uint32_t>::max();
  host::AsyncCommandScheduler scheduler(std::move(transport));
  const render::FixedCommand stop = command(0x15, 2, {3});
  scheduler.write_command_words(stop.view());
  std::this_thread::sleep_for(std::chrono::milliseconds(5));
  scheduler.shutdown();
  const host::CommandSchedulerStats stats = scheduler.stats();
  if (stats.transport_errors == 0 || stats.abandoned_commands != 1 ||
      stats.emitted_commands != 0 || stats.emitted_transactions != 0) {
    throw std::runtime_error("failed shutdown transaction was reported as delivered");
  }
}

}  // namespace

int main() {
  test_priority_coalescing_batch_and_retry();
  test_transaction_word_limit();
  test_dry_run_transport();
  test_shutdown_reports_abandoned_transaction();
  return 0;
}
