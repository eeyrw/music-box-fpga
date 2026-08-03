#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "sim/harness/control/command_control.h"
#include "third_party/ch347_linux/ch347_lib.h"

namespace host {

struct Ch347Options {
  std::string library_path = "third_party/ch347_linux/lib/x64/libch347.so";
  std::string device_path = "/dev/ch34x_pis2";
  uint8_t chip_select_mask = 0x80;
  int spi_mode = 0;
  int clock_hz = 1000000;
};

class Ch347CommandTransport : public render::CommandWordSink {
 public:
  explicit Ch347CommandTransport(const Ch347Options& options);
  ~Ch347CommandTransport() override;

  Ch347CommandTransport(const Ch347CommandTransport&) = delete;
  Ch347CommandTransport& operator=(const Ch347CommandTransport&) = delete;

  void write_command_words(render::CommandWordView words) override;

  struct CommandTransaction {
    std::array<uint8_t, 256> bytes{};
    uint16_t length = 0;
    const uint8_t* data() const { return bytes.data(); }
    std::size_t size() const { return length; }
    uint8_t operator[](std::size_t index) const { return bytes[index]; }
  };

  int configured_clock_hz() const { return configured_clock_hz_; }
  static int selected_clock_hz(int requested_hz);
  static void validate_command_transaction(render::CommandWordView words);
  static void validate_command_transaction(std::initializer_list<uint32_t> words) {
    validate_command_transaction({words.begin(), words.size()});
  }
  static uint16_t command_transaction_crc16(render::CommandWordView words);
  static uint16_t command_transaction_crc16(std::initializer_list<uint32_t> words) {
    return command_transaction_crc16({words.begin(), words.size()});
  }
  static uint16_t command_transaction_crc16_oracle(render::CommandWordView words);
  static CommandTransaction encode_command_transaction(render::CommandWordView words);
 private:
  using SpiConfig = mSpiCfgS;
  using OpenDeviceFn = decltype(&::CH347OpenDevice);
  using CloseDeviceFn = decltype(&::CH347CloseDevice);
  using SpiInitFn = decltype(&::CH347SPI_Init);
  using SpiSetFrequencyFn = decltype(&::CH347SPI_SetFrequency);
  using SpiWriteFn = decltype(&::CH347SPI_Write);

  static std::string dl_error();

  template <typename T>
  T resolve(const char* name);
  template <typename T>
  T resolve_optional(const char* name);

  void close() noexcept;

  Ch347Options options_;
  int configured_clock_hz_ = 0;
  void* library_ = nullptr;
  int fd_ = -1;
  bool opened_ = false;
  OpenDeviceFn open_device_ = nullptr;
  CloseDeviceFn close_device_ = nullptr;
  SpiInitFn spi_init_ = nullptr;
  SpiSetFrequencyFn spi_set_frequency_ = nullptr;
  SpiWriteFn spi_write_ = nullptr;
};

}  // namespace host
