#include "render_support.h"

#include "midi_parser.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <utility>

namespace render {

RenderInputs load_render_inputs(const Args& args, RenderPreparationTiming* timing) {
  using Clock = std::chrono::steady_clock;
  auto elapsed_ms = [](Clock::time_point start, Clock::time_point end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
  };

  RenderInputs inputs;
  inputs.sample_count = std::max(1, int(std::round(args.seconds * args.sample_rate)));
  inputs.control_tick_samples = control_tick_samples(args);
  auto start = Clock::now();
  inputs.sf2 = load_sf2(args.sf2);
  auto end = Clock::now();
  if (timing) timing->sf2_load_ms = elapsed_ms(start, end);
  start = end;
  inputs.events = args.midi.empty() ? default_melody() : parse_midi(args.midi);
  end = Clock::now();
  if (timing) timing->event_parse_ms = elapsed_ms(start, end);
  return inputs;
}

std::vector<int16_t> take_sf2_wave_memory(RenderInputs& inputs) {
  return std::move(inputs.sf2.file_words);
}

void prepare_render_regions(const Args& args, RenderInputs& inputs,
                            std::vector<int16_t>& wave_memory,
                            std::vector<Region>& regions,
                            RenderPreparationTiming* timing) {
  using Clock = std::chrono::steady_clock;
  auto start = Clock::now();
  prepare_events_and_regions(args, inputs.sf2, inputs.sample_count,
                             inputs.control_tick_samples, inputs.events,
                             regions, wave_memory);
  if (timing) {
    timing->region_prepare_ms =
        std::chrono::duration<double, std::milli>(Clock::now() - start).count();
  }
}

RenderTimeline::RenderTimeline(const std::vector<NoteEvent>& events,
                               int tick_samples, McuModel& mcu)
    : events_(events), mcu_(mcu),
      control_tick_samples_(std::max(1, tick_samples)) {}

void RenderTimeline::advance_to(int sample) {
  mcu_.set_current_sample(uint32_t(sample));
  while (event_index_ < events_.size() && events_[event_index_].sample <= sample) {
    mcu_.handle_event(events_[event_index_++]);
  }
  while (sample >= next_control_sample_) {
    mcu_.control_tick();
    next_control_sample_ += control_tick_samples_;
  }
}

}  // namespace render
