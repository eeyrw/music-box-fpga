#pragma once

#include "sim/harness/control/command_control.h"
#include "sim/harness/formats/mcu_sf2_asset.h"

#include <array>
#include <cstddef>
#include <cstdint>

namespace host {

struct McuSf2AssetRuntimeStats {
  uint64_t note_ons = 0;
  uint64_t note_offs = 0;
  uint64_t started_voices = 0;
  uint64_t released_voices = 0;
  uint64_t stopped_voices = 0;
  uint64_t stolen_voices = 0;
  uint64_t unmapped_notes = 0;
  uint64_t controller_voice_updates = 0;
  uint32_t active_voices = 0;
  uint32_t maximum_active_voices = 0;
};

class McuSf2AssetRuntime {
 public:
  explicit McuSf2AssetRuntime(const render::McuSf2AssetView& asset,
                              render::CommandWordSink& commands,
                              uint16_t voice_capacity = render::kNumVoices);

  uint16_t note_on(uint8_t channel, uint16_t program, uint16_t bank,
                   uint8_t note, uint8_t velocity);
  void note_off(uint8_t channel, uint8_t note);
  void control_change(uint8_t channel, uint8_t controller, uint8_t value);
  void pitch_bend(uint8_t channel, int16_t value);
  void channel_pressure(uint8_t channel, uint8_t value);
  void key_pressure(uint8_t channel, uint8_t note, uint8_t value);
  void advance_samples(uint32_t samples);
  void complete_voice(uint16_t voice);
  void all_sound_off(uint8_t channel);

  McuSf2AssetRuntimeStats stats() const { return stats_; }

 private:
  enum class VoiceStage : uint8_t { kFree, kActive, kSustainHeld, kReleased };

  struct ChannelState {
    render::McuFixedChannelState sources{};
    bool sustain = false;
    bool soft = false;
  };

  struct VoiceState {
    VoiceStage stage = VoiceStage::kFree;
    uint8_t channel = 0;
    uint8_t note = 0;
    uint8_t velocity = 0;
    uint8_t exclusive_class = 0;
    uint16_t generation = 0;
    uint32_t preset_index = 0;
    uint32_t candidate = 0;
    render::McuSf2RuntimeConfig runtime_config{};
    uint32_t release_step = 0;
    uint32_t phase_increment = 1;
    uint32_t base_phase_increment = 1;
    uint16_t gain_l = 0;
    uint16_t gain_r = 0;
    uint16_t base_gain = 0;
    int16_t pan = 0;
    int8_t effective_velocity = -1;
    uint64_t note_instance = 0;
    uint64_t allocation_stamp = 0;
    uint32_t mod_lfo_phase = 0;
    uint32_t vib_lfo_phase = 0;
    uint32_t mod_lfo_wait_ticks = 0;
    uint32_t vib_lfo_wait_ticks = 0;
    uint32_t mod_env_stage_tick = 0;
    uint32_t mod_env_wait_ticks = 0;
    uint16_t mod_env_level = 0;
    uint16_t mod_env_release_start = 0;
    uint8_t mod_env_stage = 0;
    int32_t tremolo_attenuation_q16 = 0;
    render::FilterConfig filter{};
    bool filter_valid = false;
  };

  uint16_t allocate_voice();
  void reclaim_voice(uint16_t voice);
  void release_voice(uint16_t voice);
  void stop_voice(uint16_t voice);
  void release_exclusive(uint8_t exclusive_class, uint32_t preset_index);
  void refresh_voice(uint16_t voice, uint8_t destination_groups = 0x07);
  void advance_modulation(uint16_t voice);
  int64_t destination_sum_q16(uint32_t candidate, uint32_t program,
                              uint16_t destination, uint8_t channel,
                              uint8_t note, uint8_t velocity,
                              bool include_note_sources = true) const;
  void emit_short(uint8_t opcode, uint16_t voice, uint16_t generation,
                  uint32_t value = 0, bool has_value = false);
  void mark_exclusive(uint16_t voice, bool active);

  const render::McuSf2AssetView& asset_;
  render::CommandWordSink& commands_;
  uint16_t voice_capacity_ = 0;
  std::array<ChannelState, 16> channels_{};
  std::array<VoiceState, render::kNumVoices> voices_{};
  std::array<uint16_t, render::kNumVoices> free_stack_{};
  uint16_t free_count_ = 0;
  std::array<std::array<uint64_t, (render::kNumVoices + 63) / 64>, 128>
      exclusive_voices_{};
  uint64_t next_note_instance_ = 0;
  uint64_t allocation_stamp_ = 0;
  uint64_t control_tick_index_ = 0;
  McuSf2AssetRuntimeStats stats_;
};

}  // namespace host
