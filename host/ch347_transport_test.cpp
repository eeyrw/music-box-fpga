#include "host/ch347_transport.h"

#include <functional>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {

void expect_throw(const std::function<void()>& operation, const char* message) {
  try {
    operation();
  } catch (const std::exception&) {
    return;
  }
  throw std::runtime_error(message);
}

}  // namespace

int main() {
  using host::Ch347CommandTransport;

  if (Ch347CommandTransport::selected_clock_hz(1'000'000) != 937'500 ||
      Ch347CommandTransport::selected_clock_hz(2'000'000) != 1'875'000 ||
      Ch347CommandTransport::selected_clock_hz(5'000'000) != 3'750'000 ||
      Ch347CommandTransport::selected_clock_hz(10'000'000) != 7'500'000 ||
      Ch347CommandTransport::selected_clock_hz(468'750) != 468'750 ||
      Ch347CommandTransport::selected_clock_hz(60'000'000) != 60'000'000 ||
      Ch347CommandTransport::selected_clock_hz(100'000'000) != 60'000'000) {
    throw std::runtime_error("CH347 clock selection mismatch");
  }
  expect_throw(
      [] { Ch347CommandTransport::selected_clock_hz(0); },
      "CH347 accepted a zero clock request");
  expect_throw(
      [] { Ch347CommandTransport::selected_clock_hz(468'749); },
      "CH347 accepted a request below its minimum clock");

  Ch347CommandTransport::validate_command_transaction({0x99000000u});
  Ch347CommandTransport::validate_command_transaction(
      {0x15000001u, 0x00000001u});
  std::vector<uint32_t> maximum_command(17, 0u);
  maximum_command[0] = 0x10000010u;
  Ch347CommandTransport::validate_command_transaction(maximum_command);
  Ch347CommandTransport::validate_command_transaction(
      {0x99000000u, 0x15000001u, 0x00000001u});
  const std::vector<uint32_t> encoded_words = {
      0x99000000u, 0x15000001u, 0x00000001u};
  const Ch347CommandTransport::CommandTransaction encoded =
      Ch347CommandTransport::encode_command_transaction(encoded_words);
  if (Ch347CommandTransport::command_transaction_crc16(encoded_words) != 0xadffu ||
      Ch347CommandTransport::command_transaction_crc16_oracle(encoded_words) != 0xadffu ||
      encoded.size() != 16 ||
      !std::equal(encoded.data(), encoded.data() + encoded.size(), std::vector<uint8_t>({
          0xa5, 0x03, 0xad, 0xff,
          0x99, 0x00, 0x00, 0x00,
          0x15, 0x00, 0x00, 0x01,
          0x00, 0x00, 0x00, 0x01}).begin())) {
    throw std::runtime_error("CH347 command transaction encoding mismatch");
  }
  std::vector<uint32_t> maximum_transaction(63, 0x99000000u);
  Ch347CommandTransport::validate_command_transaction(maximum_transaction);
  for (uint32_t seed = 0; seed < 4096; ++seed) {
    std::vector<uint32_t> words(1 + seed % 63, 0x99000000u);
    if (Ch347CommandTransport::command_transaction_crc16(words) !=
        Ch347CommandTransport::command_transaction_crc16_oracle(words)) {
      throw std::runtime_error("table-driven CRC16 differs from bit oracle");
    }
  }

  expect_throw(
      [] { Ch347CommandTransport::validate_command_transaction({}); },
      "CH347 accepted an empty command transaction");
  expect_throw(
      [] {
        Ch347CommandTransport::validate_command_transaction(
            {0x15000001u});
      },
      "CH347 accepted a truncated command transaction");
  expect_throw(
      [] {
        std::vector<uint32_t> oversized(64, 0x99000000u);
        Ch347CommandTransport::validate_command_transaction(oversized);
      },
      "CH347 accepted a transaction above its transfer limit");
  expect_throw(
      [] {
        std::vector<uint32_t> oversized_payload(18, 0u);
        oversized_payload[0] = 0x10000011u;
        Ch347CommandTransport::validate_command_transaction(oversized_payload);
      },
      "CH347 accepted a command above the parser payload limit");

  std::cout << "PASS: CH347 command transaction framing\n";
  return 0;
}
