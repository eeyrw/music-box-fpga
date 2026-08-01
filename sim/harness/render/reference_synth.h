#pragma once

#include "command_control.h"

#include <cstdint>
#include <utility>
#include <vector>

namespace render {

class ReferenceSynth : public CommandWordSink {
 public:
  explicit ReferenceSynth(const std::vector<int16_t>& memory, RenderDiagnostics* diagnostics = nullptr);

  void write_command_words(CommandWordView words) override;
  std::pair<int32_t, int32_t> render_mix();
  std::pair<int16_t, int16_t> render_sample();

 private:
  struct VoiceConfig {
    bool enable = false;
    bool valid = false;
    bool stereo = false;
    bool released = false;
    uint32_t base_addr = 0;
    uint32_t base_addr_r = 0;
    uint32_t length = 0;
    uint32_t length_r = 0;
    uint32_t loop_start = 0;
    uint32_t loop_start_r = 0;
    uint32_t loop_end = 0;
    uint32_t loop_end_r = 0;
    uint32_t phase = 0;
    uint32_t phase_r = 0;
    uint32_t phase_inc = 0;
    int16_t gain_l = 0;
    int16_t gain_r = 0;
    int16_t envelope = 0;
    bool filter_enable = false;
    int32_t filter_b0 = 0x00004000;
    int32_t filter_b1 = 0;
    int32_t filter_b2 = 0;
    int32_t filter_a1 = 0;
    int32_t filter_a2 = 0;
    int64_t filter_z1_l = 0;
    int64_t filter_z2_l = 0;
    int64_t filter_z1_r = 0;
    int64_t filter_z2_r = 0;
    int loop_mode = 0;
    uint16_t generation = 0;
  };

  struct EnvelopeState {
    enum Stage { kDelay, kAttack, kHold, kDecay, kSustain, kRelease } stage = kDelay;
    uint32_t delay_samples = 0;
    uint32_t attack_step = 0;
    uint32_t hold_samples = 0;
    uint32_t decay_step = 0;
    uint32_t sustain_cb = 0;
    uint32_t release_step = 0;
    uint32_t elapsed = 0;
    uint32_t attack_level = 0;
    uint32_t attenuation_cb = 0;
  };

  static int16_t interpolate(int16_t sample_0, int16_t sample_1, uint32_t fraction);
  static int16_t apply_gain(int32_t sample, int16_t gain, bool* saturated = nullptr);
  static int16_t apply_output_gain(int32_t sample, int16_t gain, int16_t envelope,
                                   bool* saturated = nullptr, int32_t* saturated_input = nullptr);
  static int16_t saturate(int32_t value, bool* saturated = nullptr);
  static int32_t saturate_i20(int64_t value, bool* saturated = nullptr);
  static int64_t saturate_filter_state(int64_t value, bool* saturated = nullptr);
  static int16_t cb_to_q15(uint32_t cb_q12_20);
  static uint32_t q15_to_cb(int16_t level);
  static int32_t biquad(int16_t sample, int64_t& z1, int64_t& z2, const VoiceConfig& v,
                        bool* y_saturated = nullptr, bool* state_saturated = nullptr,
                        int64_t* y_input = nullptr, uint64_t* state_input = nullptr);
  int16_t read_word(uint32_t address) const;
  static void advance_envelope(VoiceConfig& voice, EnvelopeState& envelope);
  static int16_t envelope_level(const VoiceConfig& voice, const EnvelopeState& envelope);

  const std::vector<int16_t>& memory_;
  std::vector<VoiceConfig> voices_;
  std::vector<EnvelopeState> envelopes_;
  uint32_t sample_counter_ = 0;
  RenderDiagnostics* diagnostics_ = nullptr;
};

}  // namespace render
