#pragma once

#include "sim/harness/register_control.h"

#include <cstddef>
#include <cstdint>
#include <string>

namespace host {

struct Ch347Options {
  std::string library_path = "libch347.so";
  unsigned long device_index = 0;
  unsigned long chip_select_mask = 0x80;
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

 private:
  struct SpiConfig;

  using OpenDeviceFn = void* (*)(unsigned long device_index);
  using CloseDeviceFn = int (*)(unsigned long device_index);
  using SpiInitFn = int (*)(unsigned long device_index, SpiConfig* config);
  using SpiWriteFn = int (*)(unsigned long device_index, unsigned long chip_select,
                            unsigned long length, unsigned long write_step, void* buffer);

  static unsigned char clock_code_for_hz(int requested_hz);
  static std::string dl_error();

  template <typename T>
  T resolve(const char* name);

  void write_spi(const uint8_t* data, size_t size);

  Ch347Options options_;
  void* library_ = nullptr;
  bool opened_ = false;
  OpenDeviceFn open_device_ = nullptr;
  CloseDeviceFn close_device_ = nullptr;
  SpiInitFn spi_init_ = nullptr;
  SpiWriteFn spi_write_ = nullptr;
};

}  // namespace host
