#include "register_control.h"

#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <utility>
#include <vector>

namespace render {
namespace {

class CaptureSink : public RegisterWriteSink {
 public:
  void write_register(uint16_t address, uint32_t data) override {
    writes.push_back({address, data});
  }

  std::vector<std::pair<uint16_t, uint32_t>> writes;
};

void expect_write(const CaptureSink& sink, size_t index, uint16_t address, uint32_t data) {
  if (index >= sink.writes.size()) throw std::runtime_error("missing expected register write");
  if (sink.writes[index].first != address || sink.writes[index].second != data) {
    throw std::runtime_error("unexpected register write sequence");
  }
}

void test_voice_register_sequence() {
  CaptureSink sink;
  RegisterVoiceControl control(sink);
  Region r;
  r.stereo = true;
  r.base_addr = 0x1234;
  r.length = 0x200;
  r.loop_start = 0x20;
  r.loop_end = 0x180;
  r.gain_l = -1;
  r.gain_r = 0x4000;
  r.loop_mode = 2;

  control.set_envelope(3, 40000);
  control.commit_voice(3, 1, 0x00018000, r);
  control.release_voice(3, r);

  uint16_t base = voice_addr(3, 0);
  if (sink.writes.size() != 13) throw std::runtime_error("wrong register write count");
  expect_write(sink, 0, uint16_t(base + 0x2c), 0x7fff);
  expect_write(sink, 1, uint16_t(base + 0x00), 0x00000003);
  expect_write(sink, 2, uint16_t(base + 0x04), 0x00001234);
  expect_write(sink, 3, uint16_t(base + 0x08), 0x00000200);
  expect_write(sink, 4, uint16_t(base + 0x0c), 0x00000020);
  expect_write(sink, 5, uint16_t(base + 0x10), 0x00000180);
  expect_write(sink, 6, uint16_t(base + 0x14), 0x00000000);
  expect_write(sink, 7, uint16_t(base + 0x18), 0x00018000);
  expect_write(sink, 8, uint16_t(base + 0x1c), 0x0000ffff);
  expect_write(sink, 9, uint16_t(base + 0x20), 0x00004000);
  expect_write(sink, 10, uint16_t(base + 0x34), 0x00000002);
  expect_write(sink, 11, uint16_t(base + 0x24), 0x00000001);
  expect_write(sink, 12, uint16_t(base + 0x34), 0x00000102);
}

}  // namespace
}  // namespace render

int main() {
  try {
    render::test_voice_register_sequence();
  } catch (const std::exception& e) {
    std::cerr << "FAIL: " << e.what() << "\n";
    return 1;
  }
  std::cout << "PASS: register control\n";
  return 0;
}
