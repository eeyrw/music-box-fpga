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

Ch347CommandTransport::Ch347CommandTransport(const Ch347Options& options)
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

Ch347CommandTransport::~Ch347CommandTransport() { close(); }

void Ch347CommandTransport::close() noexcept {
  if (opened_ && close_device_) close_device_(fd_);
  if (library_) dlclose(library_);
  opened_ = false;
  library_ = nullptr;
}

void Ch347CommandTransport::write_command_words(render::CommandWordView words) {
  CommandTransaction bytes = encode_command_transaction(words);
  const bool ok = spi_write_(fd_, false, options_.chip_select_mask,
                             int(bytes.size()), int(bytes.size()), bytes.bytes.data());
  if (!ok) {
    std::ostringstream msg;
    msg << "CH347SPI_Write failed for " << bytes.size() << " command bytes";
    throw std::runtime_error(msg.str());
  }
}

int Ch347CommandTransport::selected_clock_hz(int requested_hz) {
  return clock_choice_for_hz(requested_hz).hz;
}

void Ch347CommandTransport::validate_command_transaction(
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

uint16_t Ch347CommandTransport::command_transaction_crc16(
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

uint16_t Ch347CommandTransport::command_transaction_crc16_oracle(
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

Ch347CommandTransport::CommandTransaction
Ch347CommandTransport::encode_command_transaction(render::CommandWordView words) {
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

std::string Ch347CommandTransport::dl_error() {
  const char* error = dlerror();
  return error ? std::string(error) : std::string("unknown dynamic-loader error");
}

template <typename T>
T Ch347CommandTransport::resolve(const char* name) {
  dlerror();
  void* symbol = dlsym(library_, name);
  const char* error = dlerror();
  if (error || !symbol) throw std::runtime_error(std::string("failed to resolve ") + name + ": " + dl_error());
  return reinterpret_cast<T>(symbol);
}

template <typename T>
T Ch347CommandTransport::resolve_optional(const char* name) {
  dlerror();
  void* symbol = dlsym(library_, name);
  const char* error = dlerror();
  if (error || !symbol) return nullptr;
  return reinterpret_cast<T>(symbol);
}

}  // namespace host
