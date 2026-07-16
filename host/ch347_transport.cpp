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

}  // namespace

Ch347RegisterTransport::Ch347RegisterTransport(const Ch347Options& options)
    : options_(options) {
  library_ = dlopen(options_.library_path.c_str(), RTLD_NOW);
  if (!library_) throw std::runtime_error("failed to load " + options_.library_path + ": " + dl_error());

  open_device_ = resolve<OpenDeviceFn>("CH347OpenDevice");
  close_device_ = resolve<CloseDeviceFn>("CH347CloseDevice");
  spi_init_ = resolve<SpiInitFn>("CH347SPI_Init");
  spi_set_frequency_ = resolve_optional<SpiSetFrequencyFn>("CH347SPI_SetFrequency");
  spi_write_ = resolve<SpiWriteFn>("CH347SPI_Write");
  spi_write_read_ = resolve_optional<SpiWriteReadFn>("CH347SPI_WriteRead");

  fd_ = open_device_(options_.device_path.c_str());
  if (fd_ < 0) throw std::runtime_error("CH347OpenDevice failed for " + options_.device_path);
  opened_ = true;

  if (spi_set_frequency_ && !spi_set_frequency_(fd_, uint32_t(options_.clock_hz))) {
    throw std::runtime_error("CH347SPI_SetFrequency failed for " + std::to_string(options_.clock_hz) + " Hz");
  }

  SpiConfig config = {};
  config.iMode = uint8_t(options_.spi_mode & 0x3);
  config.iClock = clock_code_for_hz(options_.clock_hz);
  config.iByteOrder = 1;
  config.iChipSelect = options_.chip_select_mask;
  config.iIsAutoDeativeCS = 1;
  if (!spi_init_(fd_, &config)) {
    throw std::runtime_error("CH347SPI_Init failed for " + options_.device_path);
  }
}

Ch347RegisterTransport::~Ch347RegisterTransport() {
  if (opened_ && close_device_) close_device_(fd_);
  if (library_) dlclose(library_);
}

void Ch347RegisterTransport::write_register(uint16_t address, uint32_t data) {
  std::array<uint8_t, 7> frame = {
      0x80,
      uint8_t(address >> 8),
      uint8_t(address),
      uint8_t(data >> 24),
      uint8_t(data >> 16),
      uint8_t(data >> 8),
      uint8_t(data),
  };
  write_spi(frame.data(), frame.size());
}

uint32_t Ch347RegisterTransport::read_register(uint16_t address) {
  std::array<uint8_t, 7> frame = {
      0x00,
      uint8_t(address >> 8),
      uint8_t(address),
      0x00,
      0x00,
      0x00,
      0x00,
  };
  transfer_spi(frame.data(), frame.size());
  return (uint32_t(frame[3]) << 24) | (uint32_t(frame[4]) << 16) |
         (uint32_t(frame[5]) << 8) | uint32_t(frame[6]);
}

unsigned char Ch347RegisterTransport::clock_code_for_hz(int requested_hz) {
  if (requested_hz <= 0) throw std::runtime_error("CH347 SPI clock must be positive");
  for (const ClockChoice& choice : kClockChoices) {
    if (requested_hz >= choice.hz) return choice.code;
  }
  return kClockChoices[sizeof(kClockChoices) / sizeof(kClockChoices[0]) - 1].code;
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

void Ch347RegisterTransport::write_spi(const uint8_t* data, size_t size) {
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

void Ch347RegisterTransport::transfer_spi(uint8_t* data, size_t size) {
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
