#pragma once

#include <string>

namespace render {

struct MemoryProfile {
  std::string name;
  int random_latency_cycles = 0;
  int sequential_latency_cycles = 0;
  int ready_gap_cycles = 0;
};

MemoryProfile parse_memory_profile(const std::string& name);

}  // namespace render
