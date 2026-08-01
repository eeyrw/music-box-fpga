#include "host/realtime_region_bank.h"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace host {

RealtimeRegionBank::RealtimeRegionBank(
    const render::Sf2Data& sf2, int sample_rate, int tick_samples,
    std::size_t entry_capacity, std::size_t region_capacity)
    : cache_(sf2, sample_rate, tick_samples, entry_capacity),
      entry_capacity_(entry_capacity), regions_(region_capacity),
      slot_used_(region_capacity, false) {
  if (entry_capacity == 0 || region_capacity == 0) {
    throw std::invalid_argument("real-time region bank capacities must be nonzero");
  }
  entries_.reserve(entry_capacity);
}

uint64_t RealtimeRegionBank::make_key(
    int program, int bank, int key, int velocity) {
  return uint64_t(program & 0x7f) |
         (uint64_t(bank & 0x3fff) << 7) |
         (uint64_t(key & 0x7f) << 21) |
         (uint64_t(velocity & 0x7f) << 28);
}

bool RealtimeRegionBank::evict_one(const render::McuModel& mcu) {
  auto victim = entries_.end();
  uint64_t oldest = std::numeric_limits<uint64_t>::max();
  for (auto it = entries_.begin(); it != entries_.end(); ++it) {
    bool in_use = false;
    for (int region : it->second.region_indices) {
      if (mcu.region_in_use(region)) {
        in_use = true;
        break;
      }
    }
    if (!in_use && it->second.last_use < oldest) {
      oldest = it->second.last_use;
      victim = it;
    }
  }
  if (victim == entries_.end()) return false;
  for (int region : victim->second.region_indices) {
    slot_used_.at(std::size_t(region)) = false;
    regions_.at(std::size_t(region)) = {};
    --stats_.used_region_slots;
  }
  entries_.erase(victim);
  ++stats_.evictions;
  return true;
}

std::vector<int> RealtimeRegionBank::claim_slots(
    std::size_t count, const render::McuModel& mcu) {
  auto available = [&] {
    return std::count(slot_used_.begin(), slot_used_.end(), false);
  };
  while (std::size_t(available()) < count) {
    if (!evict_one(mcu)) return {};
  }
  std::vector<int> claimed;
  claimed.reserve(count);
  for (std::size_t index = 0; index < slot_used_.size() && claimed.size() < count;
       ++index) {
    if (slot_used_[index]) continue;
    slot_used_[index] = true;
    claimed.push_back(int(index));
  }
  stats_.used_region_slots += uint32_t(claimed.size());
  return claimed;
}

const std::vector<int>& RealtimeRegionBank::regions_for_preset(
    int program, int bank, int key, int velocity,
    const render::McuModel& mcu) {
  const uint64_t cache_key = make_key(program, bank, key, velocity);
  auto found = entries_.find(cache_key);
  if (found != entries_.end()) {
    ++stats_.hits;
    found->second.last_use = ++use_counter_;
    return found->second.region_indices;
  }
  ++stats_.misses;
  const auto prepared = cache_.regions_for_preset(program, bank, key, velocity);
  while (entries_.size() >= entry_capacity_) {
    if (!evict_one(mcu)) {
      ++stats_.rejected_lookups;
      throw std::overflow_error("all real-time region cache entries are active");
    }
  }
  std::vector<int> slots = claim_slots(prepared->size(), mcu);
  if (slots.size() != prepared->size()) {
    ++stats_.rejected_lookups;
    throw std::overflow_error("all real-time region slots are active");
  }
  for (std::size_t index = 0; index < slots.size(); ++index) {
    regions_[std::size_t(slots[index])] = prepared->at(index);
  }
  Entry entry;
  entry.region_indices = std::move(slots);
  entry.last_use = ++use_counter_;
  auto inserted = entries_.emplace(cache_key, std::move(entry));
  stats_.entries = uint32_t(entries_.size());
  return inserted.first->second.region_indices;
}

RealtimeRegionBankStats RealtimeRegionBank::stats() const {
  RealtimeRegionBankStats snapshot = stats_;
  snapshot.entries = uint32_t(entries_.size());
  return snapshot;
}

}  // namespace host
