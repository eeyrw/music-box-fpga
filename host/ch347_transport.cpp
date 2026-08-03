#include "host/ch347_transport.h"

#include <array>
#include <dlfcn.h>
#include <sstream>
#include <stdexcept>

namespace host {
namespace {

struct ClockChoice {
  int hz;
  uint8_t code;
};

constexpr ClockChoice kClockChoices[] = {
    {60000000, 0}, {30000000, 1}, {15000000, 2}, {7500000, 3},
    {3750000, 4},  {1875000, 5},  {937500, 6},   {468750, 7},
};

constexpr size_t kMaxCommandPayloadWords = 16;
constexpr size_t kMaxCommandTransactionWords = 63;
constexpr uint8_t kMailboxRequestOpcode = 0x5a;
constexpr uint8_t kMailboxFetchOpcode = 0x5b;
constexpr uint8_t kRegisterRead = 0x00;
constexpr uint8_t kRegisterWrite = 0x01;
constexpr uint8_t kResponseOk = 0x00;
constexpr uint8_t kResponseBusError = 0x01;
constexpr uint8_t kResponseBusy = 0x02;
constexpr uint8_t kResponseEmpty = 0x03;
constexpr int kMailboxFetchLimit = 1000;

class RegisterResponseCrcError : public std::runtime_error {
 public:
  RegisterResponseCrcError()
      : std::runtime_error("CH347 mailbox response CRC mismatch") {}
};

ClockChoice clock_choice_for_hz(int requested_hz) {
  if (requested_hz <= 0) {
    throw std::runtime_error("CH347 SPI clock must be positive");
  }
  for (const ClockChoice& choice : kClockChoices) {
    if (requested_hz >= choice.hz) return choice;
  }
  throw std::runtime_error(
      "CH347 SPI clock request is below the 468750 Hz minimum");
}

}  // namespace

Ch347RegisterTransport::Ch347RegisterTransport(const Ch347Options& options)
    : options_(options) {
  if (options_.spi_mode != 0) {
    throw std::runtime_error("Smart Artix SPI bridge requires mode 0");
  }
  const ClockChoice clock = clock_choice_for_hz(options_.clock_hz);
  configured_clock_hz_ = clock.hz;

  library_ = dlopen(options_.library_path.c_str(), RTLD_NOW);
  if (!library_) throw std::runtime_error("failed to load " + options_.library_path + ": " + dl_error());

  try {
    open_device_ = resolve<OpenDeviceFn>("CH347OpenDevice");
    close_device_ = resolve<CloseDeviceFn>("CH347CloseDevice");
    spi_init_ = resolve<SpiInitFn>("CH347SPI_Init");
    spi_set_frequency_ = resolve_optional<SpiSetFrequencyFn>("CH347SPI_SetFrequency");
    spi_write_ = resolve<SpiWriteFn>("CH347SPI_Write");
    spi_write_read_ = resolve_optional<SpiWriteReadFn>("CH347SPI_WriteRead");

    fd_ = open_device_(options_.device_path.c_str());
    if (fd_ < 0) throw std::runtime_error("CH347OpenDevice failed for " + options_.device_path);
    opened_ = true;

    SpiConfig config = {};
    config.iMode = 0;
    config.iClock = clock.code;
    config.iByteOrder = 1;
    config.iChipSelect = options_.chip_select_mask;
    config.iIsAutoDeativeCS = 1;
    if (!spi_init_(fd_, &config)) {
      throw std::runtime_error("CH347SPI_Init failed for " + options_.device_path);
    }
    if (spi_set_frequency_ &&
        !spi_set_frequency_(fd_, uint32_t(configured_clock_hz_))) {
      throw std::runtime_error("CH347SPI_SetFrequency failed for " +
                               std::to_string(configured_clock_hz_) + " Hz");
    }
  } catch (...) {
    close();
    throw;
  }
}

Ch347RegisterTransport::~Ch347RegisterTransport() { close(); }

void Ch347RegisterTransport::close() noexcept {
  if (opened_ && close_device_) close_device_(fd_);
  if (library_) dlclose(library_);
  opened_ = false;
  library_ = nullptr;
}

void Ch347RegisterTransport::write_register(uint16_t address, uint32_t data) {
  (void)transact_register(true, address, data);
}

uint32_t Ch347RegisterTransport::read_register(uint16_t address) {
  return transact_register(false, address, 0).data;
}

void Ch347RegisterTransport::write_command_words(render::CommandWordView words) {
  CommandTransaction bytes = encode_command_transaction(words);
  const bool ok = spi_write_(fd_, false, options_.chip_select_mask,
                             int(bytes.size()), int(bytes.size()), bytes.bytes.data());
  if (!ok) {
    std::ostringstream msg;
    msg << "CH347SPI_Write failed for " << bytes.size() << " command bytes";
    throw std::runtime_error(msg.str());
  }
}

void Ch347RegisterTransport::flush_command_stream() {
  const FlushTransaction transaction = encode_flush_transaction();
  send_transaction(transaction.data(), transaction.size());
}

int Ch347RegisterTransport::selected_clock_hz(int requested_hz) {
  return clock_choice_for_hz(requested_hz).hz;
}

void Ch347RegisterTransport::validate_command_transaction(
    render::CommandWordView words) {
  if (words.empty()) {
    throw std::invalid_argument("CH347 command transaction must not be empty");
  }
  if (words.size() > kMaxCommandTransactionWords) {
    throw std::invalid_argument(
        "CH347 command transaction exceeds the 63-word transfer limit");
  }

  size_t offset = 0;
  while (offset < words.size()) {
    const size_t payload_words = size_t(words[offset] & 0xffu);
    if (payload_words > kMaxCommandPayloadWords) {
      throw std::invalid_argument(
          "CH347 command header exceeds the current 16-word payload limit");
    }
    const size_t command_words = payload_words + 1u;
    if (command_words > words.size() - offset) {
      throw std::invalid_argument(
          "CH347 command transaction ends with an incomplete command");
    }
    offset += command_words;
  }
}

uint16_t Ch347RegisterTransport::command_transaction_crc16(
    render::CommandWordView words) {
  validate_command_transaction(words);
  static const std::array<uint16_t, 256> table = [] {
    std::array<uint16_t, 256> result{};
    for (std::size_t i = 0; i < result.size(); ++i) {
      uint16_t crc = uint16_t(i << 8);
      for (int bit = 0; bit < 8; ++bit) {
        crc = (crc & 0x8000u) ? uint16_t((crc << 1) ^ 0x1021u)
                              : uint16_t(crc << 1);
      }
      result[i] = crc;
    }
    return result;
  }();
  auto update = [&](uint16_t crc, uint8_t byte) {
    return uint16_t((crc << 8) ^ table[uint8_t((crc >> 8) ^ byte)]);
  };

  uint16_t crc = update(0xffffu, uint8_t(words.size()));
  for (uint32_t word : words) {
    crc = update(crc, uint8_t(word >> 24));
    crc = update(crc, uint8_t(word >> 16));
    crc = update(crc, uint8_t(word >> 8));
    crc = update(crc, uint8_t(word));
  }
  return crc;
}

uint16_t Ch347RegisterTransport::command_transaction_crc16_oracle(
    render::CommandWordView words) {
  validate_command_transaction(words);
  auto update = [](uint16_t crc, uint8_t byte) {
    crc ^= uint16_t(byte) << 8;
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc & 0x8000u) ? uint16_t((crc << 1) ^ 0x1021u)
                            : uint16_t(crc << 1);
    }
    return crc;
  };
  uint16_t crc = update(0xffffu, uint8_t(words.size()));
  for (uint32_t word : words) {
    crc = update(crc, uint8_t(word >> 24));
    crc = update(crc, uint8_t(word >> 16));
    crc = update(crc, uint8_t(word >> 8));
    crc = update(crc, uint8_t(word));
  }
  return crc;
}

Ch347RegisterTransport::CommandTransaction
Ch347RegisterTransport::encode_command_transaction(render::CommandWordView words) {
  const uint16_t crc = command_transaction_crc16(words);
  CommandTransaction transaction;
  auto push = [&](uint8_t byte) { transaction.bytes[transaction.length++] = byte; };
  push(0xa5);
  push(uint8_t(words.size()));
  push(uint8_t(crc >> 8));
  push(uint8_t(crc));
  for (uint32_t word : words) {
    push(uint8_t(word >> 24));
    push(uint8_t(word >> 16));
    push(uint8_t(word >> 8));
    push(uint8_t(word));
  }
  return transaction;
}

Ch347RegisterTransport::FlushTransaction
Ch347RegisterTransport::encode_flush_transaction() {
  auto update = [](uint16_t crc, uint8_t byte) {
    crc ^= uint16_t(byte) << 8;
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc & 0x8000u) ? uint16_t((crc << 1) ^ 0x1021u)
                            : uint16_t(crc << 1);
    }
    return crc;
  };
  uint16_t crc = update(0xffffu, 0xa6u);
  crc = update(crc, 0x00u);
  return {0xa6u, 0x00u, uint8_t(crc >> 8), uint8_t(crc)};
}

uint32_t Ch347RegisterTransport::register_frame_crc32(
    uint8_t byte0, uint8_t byte1, uint16_t address, uint32_t data) {
  auto update = [](uint32_t crc, uint8_t byte) {
    crc ^= byte;
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc & 1u) != 0 ? (crc >> 1) ^ 0xedb88320u : crc >> 1;
    }
    return crc;
  };

  uint32_t crc = update(0xffff'ffffu, byte0);
  crc = update(crc, byte1);
  crc = update(crc, uint8_t(address >> 8));
  crc = update(crc, uint8_t(address));
  crc = update(crc, uint8_t(data >> 24));
  crc = update(crc, uint8_t(data >> 16));
  crc = update(crc, uint8_t(data >> 8));
  crc = update(crc, uint8_t(data));
  return crc ^ 0xffff'ffffu;
}

Ch347RegisterTransport::RegisterRequest
Ch347RegisterTransport::encode_register_request(
    bool write, uint16_t address, uint32_t data) {
  const uint8_t operation = write ? kRegisterWrite : kRegisterRead;
  const uint32_t crc = register_frame_crc32(
      kMailboxRequestOpcode, operation, address, data);
  return {
      kMailboxRequestOpcode, operation,
      uint8_t(address >> 8), uint8_t(address),
      uint8_t(data >> 24), uint8_t(data >> 16),
      uint8_t(data >> 8), uint8_t(data),
      uint8_t(crc >> 24), uint8_t(crc >> 16),
      uint8_t(crc >> 8), uint8_t(crc),
  };
}

Ch347RegisterTransport::RegisterMailboxResponse
Ch347RegisterTransport::decode_register_response(
    const RegisterFetch& transfer) {
  RegisterMailboxResponse response = {
      transfer[4], transfer[5],
      uint16_t((uint16_t(transfer[6]) << 8) | transfer[7]),
      (uint32_t(transfer[8]) << 24) | (uint32_t(transfer[9]) << 16) |
          (uint32_t(transfer[10]) << 8) | uint32_t(transfer[11]),
  };
  const uint32_t received_crc =
      (uint32_t(transfer[12]) << 24) | (uint32_t(transfer[13]) << 16) |
      (uint32_t(transfer[14]) << 8) | uint32_t(transfer[15]);
  const uint32_t expected_crc = register_frame_crc32(
      response.status, response.operation, response.address, response.data);
  if (received_crc != expected_crc) {
    throw RegisterResponseCrcError();
  }
  return response;
}

Ch347RegisterTransport::RegisterMailboxResponse
Ch347RegisterTransport::transact_register(
    bool write, uint16_t address, uint32_t data) {
  const RegisterRequest request =
      encode_register_request(write, address, data);
  send_transaction(request.data(), request.size());

  const uint8_t expected_operation = write ? kRegisterWrite : kRegisterRead;
  for (int attempt = 0; attempt < kMailboxFetchLimit; ++attempt) {
    RegisterFetch fetch{};
    fetch[0] = kMailboxFetchOpcode;
    exchange_transaction(fetch.data(), fetch.size());
    RegisterMailboxResponse response{};
    try {
      response = decode_register_response(fetch);
    } catch (const RegisterResponseCrcError&) {
      continue;
    }
    if (response.status == kResponseBusy) continue;
    if (response.status == kResponseEmpty) {
      throw std::runtime_error("CH347 mailbox request was rejected");
    }
    if (response.operation != expected_operation || response.address != address) {
      throw std::runtime_error("CH347 mailbox response does not match request");
    }
    if (response.status == kResponseBusError) {
      std::ostringstream msg;
      msg << "CH347 register bus error at address 0x" << std::hex << address;
      throw std::runtime_error(msg.str());
    }
    if (response.status != kResponseOk) {
      throw std::runtime_error("CH347 mailbox returned an unknown status");
    }
    return response;
  }
  throw std::runtime_error("CH347 mailbox register request timed out");
}

std::string Ch347RegisterTransport::dl_error() {
  const char* error = dlerror();
  return error ? std::string(error) : std::string("unknown dynamic-loader error");
}

template <typename T>
T Ch347RegisterTransport::resolve(const char* name) {
  dlerror();
  void* symbol = dlsym(library_, name);
  const char* error = dlerror();
  if (error || !symbol) throw std::runtime_error(std::string("failed to resolve ") + name + ": " + dl_error());
  return reinterpret_cast<T>(symbol);
}

template <typename T>
T Ch347RegisterTransport::resolve_optional(const char* name) {
  dlerror();
  void* symbol = dlsym(library_, name);
  const char* error = dlerror();
  if (error || !symbol) return nullptr;
  return reinterpret_cast<T>(symbol);
}

void Ch347RegisterTransport::send_transaction(
    const uint8_t* data, size_t size) {
  if (size == 0) return;
  std::array<uint8_t, 256> local_buffer{};
  if (size > local_buffer.size()) throw std::runtime_error("CH347 SPI transfer is too large");
  for (size_t i = 0; i < size; ++i) local_buffer[i] = data[i];

  bool ok = spi_write_(fd_, false, options_.chip_select_mask,
                       int(size), int(size), local_buffer.data());
  if (!ok) {
    std::ostringstream msg;
    msg << "CH347SPI_Write failed for " << size << " bytes";
    throw std::runtime_error(msg.str());
  }
}

void Ch347RegisterTransport::exchange_transaction(
    uint8_t* data, size_t size) {
  if (size == 0) return;
  if (size > 256) throw std::runtime_error("CH347 SPI transfer is too large");
  if (!spi_write_read_) throw std::runtime_error("CH347SPI_WriteRead is not available in the loaded CH347 library");
  bool ok = spi_write_read_(fd_, false, options_.chip_select_mask, int(size), data);
  if (!ok) {
    std::ostringstream msg;
    msg << "CH347SPI_WriteRead failed for " << size << " bytes";
    throw std::runtime_error(msg.str());
  }
}

}  // namespace host
