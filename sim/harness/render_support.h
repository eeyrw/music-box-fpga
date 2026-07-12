#pragma once

#include "render_types.h"
#include "sf2_loader.h"

#include <array>
#include <string>
#include <vector>

namespace render {

Args parse_args(int argc, char** argv);
void write_summary(const std::string& path, const std::vector<Region>& regions,
                   int sample_rate, int samples, int events,
                   const std::string& extra_fields = "");
void prepare_events_and_regions(const Args& args, const Sf2Data& sf2, int sample_count,
                                int adsr_tick_samples, std::vector<NoteEvent>& events,
                                std::vector<Region>& regions,
                                std::vector<int16_t>& wave_memory);

class McuModel {
 public:
  McuModel(VoiceControlSink& sink, const std::vector<Region>& regions);

  void handle_event(const NoteEvent& event);
  void envelope_tick();

 private:
  void note_off(int channel, int note);
  void note_on(const NoteEvent& event);
  int first_free_or_oldest_slot() const;

  VoiceControlSink& sink_;
  const std::vector<Region>& regions_;
  std::array<VoiceState, kNumVoices> voices_{};
  int alloc_stamp_ = 0;
};

}  // namespace render
