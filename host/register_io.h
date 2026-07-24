#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace host {

class RegisterIo {
 public:
  virtual ~RegisterIo() = default;
  virtual void write_register(uint16_t address, uint32_t data) = 0;
  virtual uint32_t read_register(uint16_t address) = 0;
  virtual void write_registers(uint16_t start_address, const std::vector<uint32_t>& data) {
    for (size_t i = 0; i < data.size(); ++i)
      write_register(uint16_t(start_address + i * 4), data[i]);
  }
};

}  // namespace host
