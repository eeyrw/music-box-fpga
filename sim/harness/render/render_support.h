#pragma once

#include "render_types.h"
#include "sf2_loader.h"

#include <array>
#include <cstdint>
#include <string>
#include <utility>
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
  struct ChannelState {
    std::array<int, 128> cc{};
    int volume = 127;
    int expression = 127;
    int pan = 64;
    int pitch_bend = 0;
    int modulation = 0;
    int channel_pressure = 0;
    int rpn_msb = 127;
    int rpn_lsb = 127;
    int pitch_bend_range_semitones = 2;
    int pitch_bend_range_cents = 0;
    bool sustain = false;
  };

  void control_change(const NoteEvent& event);
  void channel_pressure(const NoteEvent& event);
  void pitch_bend(const NoteEvent& event);
  void update_voice_controls(int voice);
  void update_voice_modulation(int voice);
  void update_channel_controls(int channel);
  void release_voice(int voice);
  void note_off(int channel, int note);
  void note_on(const NoteEvent& event);
  int first_free_or_oldest_slot() const;
  static std::pair<int, int> runtime_gains(const Region& region, const VoiceState& voice,
                                           const ChannelState& channel);
  static double modulator_sum(const Region& region, const VoiceState& voice,
                              const ChannelState& channel, uint16_t dest,
                              bool include_note_sources = true,
                              bool include_realtime_sources = true);
  static uint32_t modulated_phase_inc(uint32_t base_phase_inc, double cents);
  static FilterConfig filter_for(int cutoff_cents, int resonance_cb, int sample_rate);

  VoiceControlSink& sink_;
  const std::vector<Region>& regions_;
  int sample_rate_ = 48000;
  std::array<ChannelState, 16> channels_{};
  std::array<VoiceState, kNumVoices> voices_{};
  int alloc_stamp_ = 0;
};

}  // namespace render
