#include "host/ch347_transport.h"

#include <array>
#include <dlfcn.h>
#include <sstream>
#include <stdexcept>

namespace host {
namespace {

using UCHAR = unsigned char;
using USHORT = unsigned short;
using ULONG = unsigned long;

struct ClockChoice {
  int hz;
  UCHAR code;
};

constexpr ClockChoice kClockChoices[] = {
    {60000000, 0}, {30000000, 1}, {15000000, 2}, {7500000, 3},
    {3750000, 4},  {1875000, 5},  {937500, 6},   {468750, 7},
};

}  // namespace

struct Ch347RegisterTransport::SpiConfig {
  UCHAR iMode = 0;
  UCHAR iClock = 7;
  UCHAR iByteOrder = 1;
  USHORT iSpiWriteReadInterval = 0;
  UCHAR iSpiOutDefaultData = 0xff;
  ULONG iChipSelect = 0x80;
  UCHAR CS1Polarity = 0;
  UCHAR CS2Polarity = 0;
  USHORT iIsAutoDeativeCS = 1;
  USHORT iActiveDelay = 0;
  ULONG iDelayDeactive = 0;
};

Ch347RegisterTransport::Ch347RegisterTransport(const Ch347Options& options)
    : options_(options) {
  library_ = dlopen(options_.library_path.c_str(), RTLD_NOW);
  if (!library_) throw std::runtime_error("failed to load " + options_.library_path + ": " + dl_error());

  open_device_ = resolve<OpenDeviceFn>("CH347OpenDevice");
  close_device_ = resolve<CloseDeviceFn>("CH347CloseDevice");
  spi_init_ = resolve<SpiInitFn>("CH347SPI_Init");
  spi_write_ = resolve<SpiWriteFn>("CH347SPI_Write");

  void* handle = open_device_(options_.device_index);
  if (!handle) throw std::runtime_error("CH347OpenDevice failed for device index " + std::to_string(options_.device_index));
  opened_ = true;

  SpiConfig config;
  config.iMode = UCHAR(options_.spi_mode & 0x3);
  config.iClock = clock_code_for_hz(options_.clock_hz);
  config.iByteOrder = 1;
  config.iChipSelect = options_.chip_select_mask;
  config.iIsAutoDeativeCS = 1;
  if (!spi_init_(options_.device_index, &config)) {
    throw std::runtime_error("CH347SPI_Init failed for device index " + std::to_string(options_.device_index));
  }
}

Ch347RegisterTransport::~Ch347RegisterTransport() {
  if (opened_ && close_device_) close_device_(options_.device_index);
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

void Ch347RegisterTransport::write_spi(const uint8_t* data, size_t size) {
  if (size == 0) return;
  std::array<uint8_t, 256> local_buffer{};
  if (size > local_buffer.size()) throw std::runtime_error("CH347 SPI transfer is too large");
  for (size_t i = 0; i < size; ++i) local_buffer[i] = data[i];

  int ok = spi_write_(options_.device_index, options_.chip_select_mask,
                      static_cast<unsigned long>(size), static_cast<unsigned long>(size),
                      local_buffer.data());
  if (!ok) {
    std::ostringstream msg;
    msg << "CH347SPI_Write failed for " << size << " bytes";
    throw std::runtime_error(msg.str());
  }
}

}  // namespace host
