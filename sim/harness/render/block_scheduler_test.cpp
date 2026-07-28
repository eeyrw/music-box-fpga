#include "block_scheduler.h"

#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

void expect(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

void test_event_boundaries_and_source_order() {
  render::BlockScheduler scheduler;
  const std::vector<uint32_t> events{3, 3, 9};

  auto plan = scheduler.plan(20, events);
  expect(plan.start_frame == 0 && plan.frame_count == 3 && plan.event_count == 0,
         "event inside block did not shorten first block");
  scheduler.commit(plan);

  plan = scheduler.plan(17, events);
  expect(plan.start_frame == 3 && plan.frame_count == 6,
         "following event did not define the next boundary");
  expect(plan.first_event == 0 && plan.event_count == 2,
         "same-frame events were not retained in source order");
  scheduler.commit(plan);

  plan = scheduler.plan(11, events);
  expect(plan.start_frame == 9 && plan.event_count == 1,
         "event at block start was not selected before rendering");
}

void test_late_events_capacity_and_partial_blocks() {
  render::BlockScheduler scheduler(8, 10);
  const std::vector<uint32_t> events{7, 10, 12};
  auto plan = scheduler.plan(10, events, 1);
  expect(plan.event_count == 2 && plan.late_event_count == 1,
         "late and on-time events were not separated");
  expect(plan.frame_count == 1, "available output capacity was ignored");
  scheduler.commit(plan);
  expect(scheduler.late_event_seen(), "late-event status was not sticky");

  plan = scheduler.plan(1, events);
  expect(plan.start_frame == 11 && plan.frame_count == 1,
         "final partial block was not emitted");
  scheduler.commit(plan);
  plan = scheduler.plan(0, events);
  expect(plan.frame_count == 0 && plan.event_count == 1,
         "boundary event was not applicable after the final frame");
}

void test_wrap_and_frame_iteration() {
  render::BlockScheduler scheduler(8, 0xfffffffcu);
  const std::vector<uint32_t> events{1};
  auto plan = scheduler.plan(8, events);
  expect(plan.frame_count == 5, "wrapped event distance was calculated incorrectly");

  std::vector<std::pair<uint32_t, uint32_t>> frames;
  render::for_each_frame(plan, [&](uint32_t frame, uint32_t index) {
    frames.emplace_back(frame, index);
  });
  expect(frames.size() == 5 && frames.front().first == 0xfffffffcu &&
             frames.back().first == 0 && frames.back().second == 4,
         "frame iteration did not preserve wrapped timeline order");
  scheduler.commit(plan);
  plan = scheduler.plan(3, events);
  expect(plan.start_frame == 1 && plan.event_count == 1,
         "wrapped boundary event was not applied at block start");
}

void test_one_frame_mode() {
  render::BlockScheduler scheduler(1);
  const std::vector<uint32_t> events{2};
  std::vector<uint32_t> rendered;
  for (uint32_t remaining = 4; remaining != 0; --remaining) {
    const auto plan = scheduler.plan(remaining, events);
    render::for_each_frame(plan, [&](uint32_t frame, uint32_t) {
      rendered.push_back(frame);
    });
    scheduler.commit(plan);
  }
  expect(rendered == std::vector<uint32_t>({0, 1, 2, 3}),
         "one-frame mode changed the reference frame sequence");
  expect(scheduler.next_event() == 1, "one-frame mode did not apply its event");
}

}  // namespace

int main() {
  try {
    test_event_boundaries_and_source_order();
    test_late_events_capacity_and_partial_blocks();
    test_wrap_and_frame_iteration();
    test_one_frame_mode();
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
  std::cout << "PASS: block scheduler\n";
  return 0;
}
