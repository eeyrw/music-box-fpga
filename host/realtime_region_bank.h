#pragma once

#include "sim/harness/formats/sf2_loader.h"
#include "sim/harness/render/render_support.h"

#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace host {

struct RealtimeRegionBankStats {
  uint64_t hits = 0;
  uint64_t misses = 0;
  uint64_t evictions = 0;
  uint64_t rejected_lookups = 0;
  uint32_t entries = 0;
  uint32_t used_region_slots = 0;
};

class RealtimeRegionBank {
 public:
  static constexpr std::size_t kDefaultEntryCapacity = 4096;
  static constexpr std::size_t kDefaultRegionCapacity = 16384;

  RealtimeRegionBank(const render::Sf2Data& sf2, int sample_rate,
                     int tick_samples,
                     std::size_t entry_capacity = kDefaultEntryCapacity,
                     std::size_t region_capacity = kDefaultRegionCapacity);

  const std::vector<int>& regions_for_preset(
      int program, int bank, int key, int velocity,
      const render::McuModel& mcu);
  const std::vector<render::Region>& regions() const { return regions_; }
  RealtimeRegionBankStats stats() const;

 private:
  struct Entry {
    std::vector<int> region_indices;
    uint64_t last_use = 0;
  };

  static uint64_t make_key(int program, int bank, int key, int velocity);
  bool evict_one(const render::McuModel& mcu);
  std::vector<int> claim_slots(std::size_t count,
                               const render::McuModel& mcu);

  render::Sf2RegionCache cache_;
  std::size_t entry_capacity_;
  std::vector<render::Region> regions_;
  std::vector<bool> slot_used_;
  std::unordered_map<uint64_t, Entry> entries_;
  uint64_t use_counter_ = 0;
  RealtimeRegionBankStats stats_;
};

}  // namespace host
