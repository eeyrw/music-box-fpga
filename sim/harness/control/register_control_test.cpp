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
  r.base_addr_r = 0x5678;
  r.length = 0x200;
  r.length_r = 0x240;
  r.loop_start = 0x20;
  r.loop_start_r = 0x30;
  r.loop_end = 0x180;
  r.loop_end_r = 0x190;
  r.gain_l = -1;
  r.gain_r = 0x4000;
  r.filter_enable = true;
  r.filter_b0 = 0x00002000;
  r.filter_b1 = 0x00001000;
  r.filter_b2 = -0x00000800;
  r.filter_a1 = -0x00000400;
  r.filter_a2 = 0x00000200;
  r.loop_mode = 2;

  control.set_envelope(3, 40000);
  control.set_gain(3, 0x2000, 0x1000);
  control.set_phase_inc(3, 0x0001a000);
  control.commit_voice(3, 1, 0x00018000, r);
  FilterConfig filter;
  filter.enable = r.filter_enable;
  filter.b0 = r.filter_b0;
  filter.b1 = r.filter_b1;
  filter.b2 = r.filter_b2;
  filter.a1 = r.filter_a1;
  filter.a2 = r.filter_a2;
  control.set_filter(3, filter);
  control.release_voice(3, r);

  uint16_t base = voice_addr(3, 0);
  if (sink.writes.size() != 25) throw std::runtime_error("wrong register write count");
  expect_write(sink, 0, uint16_t(base + kRegEnvelopeLevel), 0x7fff);
  expect_write(sink, 1, uint16_t(base + kRegGainRuntime), 0x10002000);
  expect_write(sink, 2, uint16_t(base + kRegPhaseIncRuntime), 0x0001a000);
  expect_write(sink, 3, uint16_t(base + kRegBaseAddr), 0x00001234);
  expect_write(sink, 4, uint16_t(base + kRegBaseAddrR), 0x00005678);
  expect_write(sink, 5, uint16_t(base + kRegLength), 0x00000200);
  expect_write(sink, 6, uint16_t(base + kRegLengthR), 0x00000240);
  expect_write(sink, 7, uint16_t(base + kRegLoopStart), 0x00000020);
  expect_write(sink, 8, uint16_t(base + kRegLoopStartR), 0x00000030);
  expect_write(sink, 9, uint16_t(base + kRegLoopEnd), 0x00000180);
  expect_write(sink, 10, uint16_t(base + kRegLoopEndR), 0x00000190);
  expect_write(sink, 11, uint16_t(base + kRegPhaseInit), 0x00000000);
  expect_write(sink, 12, uint16_t(base + kRegPhaseInc), 0x00018000);
  expect_write(sink, 13, uint16_t(base + kRegGainL), 0x0000ffff);
  expect_write(sink, 14, uint16_t(base + kRegGainR), 0x00004000);
  expect_write(sink, 15, uint16_t(base + kRegFilterControl), 0x00000001);
  expect_write(sink, 16, uint16_t(base + kRegFilterB0B1), 0x10002000);
  expect_write(sink, 17, uint16_t(base + kRegFilterB2A1), 0xfc00f800);
  expect_write(sink, 18, uint16_t(base + kRegFilterA2), 0x00000200);
  expect_write(sink, 19, uint16_t(base + kRegVoiceControl), 0x0000001d);
  expect_write(sink, 20, uint16_t(base + kRegFilterControl), 0x00000001);
  expect_write(sink, 21, uint16_t(base + kRegFilterB0B1), 0x10002000);
  expect_write(sink, 22, uint16_t(base + kRegFilterB2A1), 0xfc00f800);
  expect_write(sink, 23, uint16_t(base + kRegFilterA2), 0x00010200);
  expect_write(sink, 24, uint16_t(base + kRegReleaseControl), 0x00000001);
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
