#pragma once

#include "render_types.h"
#include "sf2_loader.h"

#include <array>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace render {

struct RenderPreparationTiming {
  double sf2_load_ms = 0.0;
  double event_parse_ms = 0.0;
  double region_prepare_ms = 0.0;
};

struct RenderInputs {
  int sample_count = 0;
  int control_tick_samples = 1;
  Sf2Data sf2;
  std::vector<NoteEvent> events;
};

Args parse_args(int argc, char** argv);
int control_tick_samples(const Args& args);
RenderInputs load_render_inputs(const Args& args, RenderPreparationTiming* timing = nullptr);
std::vector<int16_t> take_sf2_wave_memory(RenderInputs& inputs);
void prepare_render_regions(const Args& args, RenderInputs& inputs,
                            std::vector<int16_t>& wave_memory,
                            std::vector<Region>& regions,
                            RenderPreparationTiming* timing = nullptr);
std::string json_string(const std::string& value);
std::string render_input_json_fields(const Args& args, int control_tick_samples);
std::string memory_profile_json_field(const Args& args);
void write_summary(const std::string& path, const std::vector<Region>& regions,
                   int sample_rate, int samples, int events,
                   const std::string& extra_fields = "");
std::string diagnostics_json_fields(const RenderDiagnostics& diagnostics);
void prepare_events_and_regions(const Args& args, const Sf2Data& sf2, int sample_count,
                                int control_tick_samples, std::vector<NoteEvent>& events,
                                std::vector<Region>& regions,
                                std::vector<int16_t>& wave_memory);

struct ControlUpdateRates {
  uint32_t gain_ticks = 1;
  uint32_t pitch_ticks = 1;
  uint32_t filter_ticks = 4;
};

struct ControlMathValidation {
  double max_pitch_ratio_error = 0.0;
  double max_attenuation_gain_error = 0.0;
  uint32_t max_phase_increment_error = 0;
  uint32_t max_filter_coefficient_error = 0;
};

ControlMathValidation validate_control_math_approximations();

class McuModel {
 public:
  McuModel(VoiceCommandSink& sink, const std::vector<Region>& regions,
           RenderDiagnostics* diagnostics = nullptr,
           ControlUpdateRates update_rates = {});

  void handle_event(const NoteEvent& event);
  void control_tick();
  void set_current_sample(uint32_t sample) { current_sample_ = sample; }
  bool region_in_use(int region) const;

 private:
  struct ChannelState {
    std::array<int, 128> cc{};
    std::array<int, 128> key_pressure{};
    std::array<double, 64> generator_offsets{};
    int volume = 127;
    int expression = 127;
    int pan = 64;
    int pitch_bend = 0;
    int modulation = 0;
    int channel_pressure = 0;
    int rpn_msb = 127;
    int rpn_lsb = 127;
    int nrpn_msb = 127;
    int nrpn_base = 0;
    int nrpn_generator = -1;
    int data_entry_lsb = 0;
    int pitch_bend_range_semitones = 2;
    int pitch_bend_range_cents = 0;
    bool sustain = false;
    bool soft = false;
    bool sostenuto = false;
    bool data_entry_is_nrpn = false;
  };

  void control_change(const NoteEvent& event);
  void channel_pressure(const NoteEvent& event);
  void key_pressure(const NoteEvent& event);
  void pitch_bend(const NoteEvent& event);
  void update_voice_controls(int voice, uint8_t dirty_groups = 0x07);
  void update_voice_modulation(int voice, uint8_t dirty_groups,
                               bool advance_modulation);
  void update_channel_controls(int channel, uint8_t dirty_groups = 0x07);
  void release_deferred_pedal_voices(int channel);
  void all_notes_off(int channel);
  void apply_data_entry(int channel, int msb_value);
  void reset_controllers(int channel);
  void record_runtime_gain_update(int voice, int gain_l, int gain_r);
  void record_runtime_phase_update(int voice, uint32_t phase_inc);
  void record_runtime_filter_update(int voice, const FilterConfig& filter);
  void release_voice(int voice);
  void note_off(int channel, int note, uint64_t note_instance = 0);
  void note_on(const NoteEvent& event);
  int first_free_or_steal_slot();
  std::pair<int, int> runtime_gains(const Region& region, const VoiceState& voice,
                                    const ChannelState& channel);
  double modulator_sum(const Region& region, const VoiceState& voice,
                       const ChannelState& channel, uint16_t dest,
                       bool include_note_sources = true,
                       bool include_realtime_sources = true);
  static uint32_t modulated_phase_inc(uint32_t base_phase_inc, double cents);
  static FilterConfig filter_for(int cutoff_cents, int resonance_cb, int sample_rate);
  void activate_voice(int voice);
  void deactivate_voice(int voice);
  void record_emitted_commands(uint64_t count = 1);

  VoiceCommandSink& sink_;
  const std::vector<Region>& regions_;
  int sample_rate_ = 48000;
  std::array<ChannelState, 16> channels_{};
  std::array<VoiceState, kNumVoices> voices_{};
  std::array<bool, kNumVoices> runtime_gain_valid_{};
  std::array<int, kNumVoices> last_runtime_gain_l_{};
  std::array<int, kNumVoices> last_runtime_gain_r_{};
  std::array<bool, kNumVoices> runtime_phase_valid_{};
  std::array<uint32_t, kNumVoices> last_runtime_phase_inc_{};
  std::array<bool, kNumVoices> runtime_filter_valid_{};
  std::array<FilterConfig, kNumVoices> last_runtime_filter_{};
  std::array<int, kNumVoices> active_positions_{};
  std::array<int, kNumVoices> active_voices_{};
  int active_voice_count_ = 0;
  RenderDiagnostics* diagnostics_ = nullptr;
  ControlUpdateRates update_rates_;
  int alloc_stamp_ = 0;
  uint64_t next_note_instance_ = 0;
  uint64_t control_tick_index_ = 0;
  uint32_t current_sample_ = 0;
};

class RenderTimeline {
 public:
  RenderTimeline(const std::vector<NoteEvent>& events, int control_tick_samples,
                 McuModel& mcu);
  void advance_to(int sample);

 private:
  const std::vector<NoteEvent>& events_;
  McuModel& mcu_;
  size_t event_index_ = 0;
  int control_tick_samples_ = 1;
  int next_control_sample_ = 0;
};

}  // namespace render
