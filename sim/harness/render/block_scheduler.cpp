#include "block_scheduler.h"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace render {

bool timeline_before(uint32_t lhs, uint32_t rhs) {
  return ((lhs - rhs) & (uint32_t(1) << 31)) != 0;
}

BlockScheduler::BlockScheduler(uint32_t max_block_frames, uint32_t start_frame)
    : max_block_frames_(max_block_frames), next_frame_(start_frame) {
  if (max_block_frames == 0 || max_block_frames >= (uint32_t(1) << 31)) {
    throw std::invalid_argument("block length must be in the timeline half-range");
  }
}

BlockPlan BlockScheduler::plan(uint32_t frames_remaining,
                               const std::vector<uint32_t>& event_frames,
                               uint32_t available_frames) const {
  BlockPlan result;
  result.start_frame = next_frame_;
  result.first_event = next_event_;

  std::size_t event = next_event_;
  while (event < event_frames.size() &&
         !timeline_before(next_frame_, event_frames[event])) {
    if (timeline_before(event_frames[event], next_frame_)) {
      ++result.late_event_count;
    }
    ++event;
  }
  result.event_count = event - next_event_;

  uint32_t limit = std::min({max_block_frames_, available_frames, frames_remaining});
  if (event < event_frames.size()) {
    const uint32_t event_distance = event_frames[event] - next_frame_;
    if (event_distance >= (uint32_t(1) << 31)) {
      throw std::invalid_argument("event lies outside the timeline half-range");
    }
    limit = std::min(limit, event_distance);
  }
  result.frame_count = limit;
  return result;
}

void BlockScheduler::commit(const BlockPlan& plan) {
  if (plan.start_frame != next_frame_ || plan.first_event != next_event_ ||
      plan.frame_count > max_block_frames_) {
    throw std::invalid_argument("block plan does not match scheduler state");
  }
  if (plan.event_count > std::numeric_limits<std::size_t>::max() - next_event_) {
    throw std::overflow_error("event index overflow");
  }

  next_event_ += plan.event_count;
  next_frame_ += plan.frame_count;
  late_event_seen_ = late_event_seen_ || plan.late_event_count != 0;
}

}  // namespace render
