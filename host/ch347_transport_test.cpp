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
  using host::Ch347RegisterTransport;

  if (Ch347RegisterTransport::selected_clock_hz(1'000'000) != 937'500 ||
      Ch347RegisterTransport::selected_clock_hz(2'000'000) != 1'875'000 ||
      Ch347RegisterTransport::selected_clock_hz(5'000'000) != 3'750'000 ||
      Ch347RegisterTransport::selected_clock_hz(10'000'000) != 7'500'000 ||
      Ch347RegisterTransport::selected_clock_hz(468'750) != 468'750 ||
      Ch347RegisterTransport::selected_clock_hz(60'000'000) != 60'000'000 ||
      Ch347RegisterTransport::selected_clock_hz(100'000'000) != 60'000'000) {
    throw std::runtime_error("CH347 clock selection mismatch");
  }
  expect_throw(
      [] { Ch347RegisterTransport::selected_clock_hz(0); },
      "CH347 accepted a zero clock request");
  expect_throw(
      [] { Ch347RegisterTransport::selected_clock_hz(468'749); },
      "CH347 accepted a request below its minimum clock");

  const Ch347RegisterTransport::RegisterRequest register_request =
      Ch347RegisterTransport::encode_register_request(
          true, 0x0010u, 0x1234'5678u);
  if (register_request.size() != 12 ||
      Ch347RegisterTransport::register_frame_crc32(
          0x5au, 0x01u, 0x0010u, 0x1234'5678u) != 0x0c1e'7dd5u ||
      register_request != Ch347RegisterTransport::RegisterRequest({
          0x5a, 0x01, 0x00, 0x10,
          0x12, 0x34, 0x56, 0x78,
          0x0c, 0x1e, 0x7d, 0xd5})) {
    throw std::runtime_error("CH347 register request encoding mismatch");
  }

  const Ch347RegisterTransport::RegisterFetch response_transfer = {
          0x00, 0x00, 0x00, 0x00,
          0x00, 0x00, 0x00, 0x10,
          0x12, 0x34, 0x56, 0x78,
          0x6e, 0x8f, 0x99, 0x6f};
  const Ch347RegisterTransport::RegisterMailboxResponse register_response =
      Ch347RegisterTransport::decode_register_response(response_transfer);
  if (register_response.status != 0 || register_response.operation != 0 ||
      register_response.address != 0x0010u ||
      register_response.data != 0x1234'5678u) {
    throw std::runtime_error("CH347 register response decoding mismatch");
  }
  expect_throw(
      [] {
        Ch347RegisterTransport::RegisterFetch corrupt_response = {
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x10,
            0x12, 0x34, 0x56, 0x78,
            0x6e, 0x8f, 0x99, 0x6e};
        Ch347RegisterTransport::decode_register_response(corrupt_response);
      },
      "CH347 accepted a corrupt register response CRC");

  Ch347RegisterTransport::validate_command_transaction({0x7f000000u});
  Ch347RegisterTransport::validate_command_transaction(
      {0x15000001u, 0x00000001u});
  std::vector<uint32_t> maximum_command(17, 0u);
  maximum_command[0] = 0x10000010u;
  Ch347RegisterTransport::validate_command_transaction(maximum_command);
  Ch347RegisterTransport::validate_command_transaction(
      {0x7f000000u, 0x15000001u, 0x00000001u});
  const std::vector<uint32_t> encoded_words = {
      0x7f000000u, 0x15000001u, 0x00000001u};
  const Ch347RegisterTransport::CommandTransaction encoded =
      Ch347RegisterTransport::encode_command_transaction(encoded_words);
  if (Ch347RegisterTransport::command_transaction_crc16(encoded_words) != 0xbf80u ||
      Ch347RegisterTransport::command_transaction_crc16_oracle(encoded_words) != 0xbf80u ||
      encoded.size() != 16 ||
      !std::equal(encoded.data(), encoded.data() + encoded.size(), std::vector<uint8_t>({
          0xa5, 0x03, 0xbf, 0x80,
          0x7f, 0x00, 0x00, 0x00,
          0x15, 0x00, 0x00, 0x01,
          0x00, 0x00, 0x00, 0x01}).begin())) {
    throw std::runtime_error("CH347 command transaction encoding mismatch");
  }
  std::vector<uint32_t> maximum_transaction(63, 0x7f000000u);
  Ch347RegisterTransport::validate_command_transaction(maximum_transaction);
  for (uint32_t seed = 0; seed < 4096; ++seed) {
    std::vector<uint32_t> words(1 + seed % 63, 0x7f000000u);
    if (Ch347RegisterTransport::command_transaction_crc16(words) !=
        Ch347RegisterTransport::command_transaction_crc16_oracle(words)) {
      throw std::runtime_error("table-driven CRC16 differs from bit oracle");
    }
  }

  expect_throw(
      [] { Ch347RegisterTransport::validate_command_transaction({}); },
      "CH347 accepted an empty command transaction");
  expect_throw(
      [] {
        Ch347RegisterTransport::validate_command_transaction(
            {0x15000001u});
      },
      "CH347 accepted a truncated command transaction");
  expect_throw(
      [] {
        std::vector<uint32_t> oversized(64, 0x7f000000u);
        Ch347RegisterTransport::validate_command_transaction(oversized);
      },
      "CH347 accepted a transaction above its transfer limit");
  expect_throw(
      [] {
        std::vector<uint32_t> oversized_payload(18, 0u);
        oversized_payload[0] = 0x10000011u;
        Ch347RegisterTransport::validate_command_transaction(oversized_payload);
      },
      "CH347 accepted a command above the parser payload limit");

  std::cout << "PASS: CH347 mailbox and command transaction framing\n";
  return 0;
}
