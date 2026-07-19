#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "sim/harness/control/register_control.h"
#include "third_party/ch347_linux/ch347_lib.h"

namespace host {

struct Ch347Options {
  std::string library_path = "third_party/ch347_linux/lib/x64/libch347.so";
  std::string device_path = "/dev/ch34x_pis2";
  uint8_t chip_select_mask = 0x80;
  int spi_mode = 0;
  int clock_hz = 1000000;
};

class Ch347RegisterTransport : public render::RegisterWriteSink {
 public:
  explicit Ch347RegisterTransport(const Ch347Options& options);
  ~Ch347RegisterTransport() override;

  Ch347RegisterTransport(const Ch347RegisterTransport&) = delete;
  Ch347RegisterTransport& operator=(const Ch347RegisterTransport&) = delete;

  void write_register(uint16_t address, uint32_t data) override;
  uint32_t read_register(uint16_t address);
  void write_registers(uint16_t start_address, const std::vector<uint32_t>& data);
  std::vector<uint32_t> read_registers(uint16_t start_address, size_t count);

 private:
  using SpiConfig = mSpiCfgS;
  using OpenDeviceFn = decltype(&::CH347OpenDevice);
  using CloseDeviceFn = decltype(&::CH347CloseDevice);
  using SpiInitFn = decltype(&::CH347SPI_Init);
  using SpiSetFrequencyFn = decltype(&::CH347SPI_SetFrequency);
  using SpiWriteFn = decltype(&::CH347SPI_Write);
  using SpiWriteReadFn = decltype(&::CH347SPI_WriteRead);

  static unsigned char clock_code_for_hz(int requested_hz);
  static std::string dl_error();

  template <typename T>
  T resolve(const char* name);
  template <typename T>
  T resolve_optional(const char* name);

  void write_spi(const uint8_t* data, size_t size);
  void transfer_spi(uint8_t* data, size_t size);

  Ch347Options options_;
  void* library_ = nullptr;
  int fd_ = -1;
  bool opened_ = false;
  OpenDeviceFn open_device_ = nullptr;
  CloseDeviceFn close_device_ = nullptr;
  SpiInitFn spi_init_ = nullptr;
  SpiSetFrequencyFn spi_set_frequency_ = nullptr;
  SpiWriteFn spi_write_ = nullptr;
  SpiWriteReadFn spi_write_read_ = nullptr;
};

}  // namespace host
