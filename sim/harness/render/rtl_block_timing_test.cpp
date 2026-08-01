#include "rtl_block_timing.h"

#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void expect(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

}  // namespace

int main() {
  try {
    expect(render::next_rtl_render_boundary(0, 100, 16) == 16,
           "full block boundary mismatch");
    expect(render::next_rtl_render_boundary(96, 100, 16) == 100,
           "tail block boundary mismatch");

    render::RtlBlockTiming timing(100'000'000u, 48'000u);
    timing.observe(16, 28'000);
    timing.observe(16, 33'334);
    timing.observe(8, 16'000);

    expect(timing.blocks() == 3, "block total mismatch");
    expect(timing.total_cycles() == 77'334, "cycle total mismatch");
    expect(timing.max_cycles() == 33'334, "maximum cycles mismatch");
    expect(timing.max_utilization_ppm() == 1'000'020,
           "maximum utilization mismatch");
    expect(timing.deadline_misses() == 1, "deadline miss mismatch");

    const auto& full = timing.buckets().at(16);
    expect(full.blocks == 2 && full.total_cycles == 61'334 &&
               full.max_cycles == 33'334 && full.deadline_misses == 1,
           "sixteen-frame bucket mismatch");
    const auto& half = timing.buckets().at(8);
    expect(half.max_utilization_ppm == 960'000 &&
               half.deadline_misses == 0,
           "eight-frame bucket mismatch");

    const std::string json = timing.buckets_json();
    expect(json.find("\"16\":{\"blocks\":2") != std::string::npos &&
               json.find("\"deadline_misses\":1") != std::string::npos,
           "bucket JSON mismatch");

    bool rejected_zero_frames = false;
    try {
      timing.observe(0, 1);
    } catch (const std::invalid_argument&) {
      rejected_zero_frames = true;
    }
    expect(rejected_zero_frames, "zero-frame observation was accepted");
  } catch (const std::exception& e) {
    std::cerr << "FAIL: " << e.what() << '\n';
    return 1;
  }
  std::cout << "PASS: RTL block timing statistics\n";
  return 0;
}
