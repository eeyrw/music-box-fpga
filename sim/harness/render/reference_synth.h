#pragma once

#include "render_types.h"

#include <cstdint>
#include <utility>
#include <vector>

namespace render {

class ReferenceSynth : public VoiceControlSink, public EnvelopeEventSink {
 public:
  explicit ReferenceSynth(const std::vector<int16_t>& memory, RenderDiagnostics* diagnostics = nullptr);

  void set_envelope(int voice, int level) override;
  void set_gain(int voice, int gain_l, int gain_r) override;
  void set_phase_inc(int voice, uint32_t phase_inc) override;
  void set_filter(int voice, const FilterConfig& filter) override;
  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override;
  void release_voice(int voice, const Region& region) override;
  void push_envelope_event(const EnvelopeEvent& event) override;
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
  };

  struct EnvelopeState {
    int mode = 0;
    int32_t gain_q23 = 0;
    uint32_t cb_q8_8 = 0;
    uint32_t step = 0;
    uint32_t target = 0;
    uint32_t phase = 0;
    uint32_t duration = 0;
    bool active = false;
  };

  static int16_t interpolate(int16_t sample_0, int16_t sample_1, uint32_t fraction);
  static int16_t apply_gain(int32_t sample, int16_t gain, bool* saturated = nullptr);
  static int16_t apply_output_gain(int32_t sample, int16_t gain, int16_t envelope,
                                   bool* saturated = nullptr, int32_t* saturated_input = nullptr);
  static int16_t saturate(int32_t value, bool* saturated = nullptr);
  static int32_t saturate_i20(int64_t value, bool* saturated = nullptr);
  static int64_t saturate_filter_state(int64_t value, bool* saturated = nullptr);
  static int16_t cb_to_q15(uint32_t cb_q8_8);
  static int32_t biquad(int16_t sample, int64_t& z1, int64_t& z2, const VoiceConfig& v,
                        bool* y_saturated = nullptr, bool* state_saturated = nullptr,
                        int64_t* y_input = nullptr, uint64_t* state_input = nullptr);
  int16_t read_word(uint32_t address) const;
  void prepare_event_envelope(int voice);
  void apply_envelope_event(const EnvelopeEvent& event);

  const std::vector<int16_t>& memory_;
  std::vector<VoiceConfig> voices_;
  std::vector<EnvelopeState> envelopes_;
  std::vector<EnvelopeEvent> envelope_events_;
  uint32_t sample_counter_ = 0;
  RenderDiagnostics* diagnostics_ = nullptr;
};

}  // namespace render
