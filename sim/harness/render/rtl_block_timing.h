#pragma once

#include <algorithm>
#include <cstdint>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>

namespace render {

inline uint32_t next_rtl_render_boundary(uint32_t frame, uint32_t end_frame,
                                         uint32_t max_block_frames) {
  if (max_block_frames == 0 || frame >= end_frame)
    throw std::invalid_argument("invalid RTL render block boundary");
  return uint32_t(std::min<uint64_t>(
      end_frame, uint64_t(frame) + uint64_t(max_block_frames)));
}

struct RtlBlockTimingBucket {
  uint64_t blocks = 0;
  uint64_t total_cycles = 0;
  uint64_t max_cycles = 0;
  uint64_t max_utilization_ppm = 0;
  uint64_t deadline_misses = 0;
};

class RtlBlockTiming {
 public:
  RtlBlockTiming(uint64_t clock_hz, uint64_t sample_rate_hz)
      : clock_hz_(clock_hz), sample_rate_hz_(sample_rate_hz) {
    if (clock_hz == 0 || sample_rate_hz == 0)
      throw std::invalid_argument("RTL block timing rates must be nonzero");
  }

  void observe(uint32_t frame_count, uint64_t service_cycles) {
    if (frame_count == 0)
      throw std::invalid_argument("RTL block timing frame count must be nonzero");

    RtlBlockTimingBucket& bucket = buckets_[frame_count];
    const uint64_t utilization_ppm =
        service_cycles * sample_rate_hz_ * 1'000'000u /
        (uint64_t(frame_count) * clock_hz_);
    const uint64_t deadline_cycles =
        uint64_t(frame_count) * clock_hz_ / sample_rate_hz_;

    ++bucket.blocks;
    bucket.total_cycles += service_cycles;
    bucket.max_cycles = std::max(bucket.max_cycles, service_cycles);
    bucket.max_utilization_ppm =
        std::max(bucket.max_utilization_ppm, utilization_ppm);
    bucket.deadline_misses += service_cycles > deadline_cycles;

    ++blocks_;
    total_cycles_ += service_cycles;
    max_cycles_ = std::max(max_cycles_, service_cycles);
    max_utilization_ppm_ =
        std::max(max_utilization_ppm_, utilization_ppm);
    deadline_misses_ += service_cycles > deadline_cycles;
  }

  uint64_t blocks() const { return blocks_; }
  uint64_t total_cycles() const { return total_cycles_; }
  uint64_t max_cycles() const { return max_cycles_; }
  uint64_t max_utilization_ppm() const { return max_utilization_ppm_; }
  uint64_t deadline_misses() const { return deadline_misses_; }
  const std::map<uint32_t, RtlBlockTimingBucket>& buckets() const {
    return buckets_;
  }

  std::string buckets_json() const {
    std::ostringstream out;
    out << '{';
    bool first = true;
    for (const auto& [frames, bucket] : buckets_) {
      if (!first) out << ',';
      first = false;
      out << '\"' << frames << "\":{";
      out << "\"blocks\":" << bucket.blocks;
      out << ",\"total_cycles\":" << bucket.total_cycles;
      out << ",\"max_cycles\":" << bucket.max_cycles;
      out << ",\"max_utilization_ppm\":"
          << bucket.max_utilization_ppm;
      out << ",\"deadline_misses\":" << bucket.deadline_misses;
      out << '}';
    }
    out << '}';
    return out.str();
  }

 private:
  uint64_t clock_hz_;
  uint64_t sample_rate_hz_;
  std::map<uint32_t, RtlBlockTimingBucket> buckets_;
  uint64_t blocks_ = 0;
  uint64_t total_cycles_ = 0;
  uint64_t max_cycles_ = 0;
  uint64_t max_utilization_ppm_ = 0;
  uint64_t deadline_misses_ = 0;
};

}  // namespace render
