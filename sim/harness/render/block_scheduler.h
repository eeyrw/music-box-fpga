#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace render {

constexpr uint32_t kPrototypeMaxBlockFrames = 8;

bool timeline_before(uint32_t lhs, uint32_t rhs);

struct BlockPlan {
  uint32_t start_frame = 0;
  uint32_t frame_count = 0;
  std::size_t first_event = 0;
  std::size_t event_count = 0;
  std::size_t late_event_count = 0;
};

class BlockScheduler {
 public:
  explicit BlockScheduler(uint32_t max_block_frames = kPrototypeMaxBlockFrames,
                          uint32_t start_frame = 0);

  BlockPlan plan(uint32_t frames_remaining,
                 const std::vector<uint32_t>& event_frames,
                 uint32_t available_frames = kPrototypeMaxBlockFrames) const;
  void commit(const BlockPlan& plan);

  uint32_t next_frame() const { return next_frame_; }
  std::size_t next_event() const { return next_event_; }
  bool late_event_seen() const { return late_event_seen_; }

 private:
  uint32_t max_block_frames_;
  uint32_t next_frame_;
  std::size_t next_event_ = 0;
  bool late_event_seen_ = false;
};

template <typename Function>
void for_each_frame(const BlockPlan& plan, Function&& function) {
  for (uint32_t index = 0; index < plan.frame_count; ++index) {
    function(plan.start_frame + index, index);
  }
}

}  // namespace render
