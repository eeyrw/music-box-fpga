#include "memory_profile.h"

#include <stdexcept>

namespace render {

MemoryProfile parse_memory_profile(const std::string& name) {
  if (name == "ddr") return MemoryProfile{"ddr", 10, 4, 0};
  if (name == "sdram") return MemoryProfile{"sdram", 16, 8, 1};
  if (name == "parallel-nor" || name == "nor") return MemoryProfile{"parallel-nor", 28, 14, 3};
  throw std::runtime_error("unknown memory profile: " + name + " (expected ddr, sdram, or parallel-nor)");
}

}  // namespace render
