#pragma once

#include "render_types.h"

namespace render {

class FanoutSink : public VoiceControlSink {
 public:
  FanoutSink(VoiceControlSink& a, VoiceControlSink& b) : a_(a), b_(b) {}

  void set_envelope(int voice, int level) override {
    a_.set_envelope(voice, level);
    b_.set_envelope(voice, level);
  }

  void set_gain(int voice, int gain_l, int gain_r) override {
    a_.set_gain(voice, gain_l, gain_r);
    b_.set_gain(voice, gain_l, gain_r);
  }

  void set_phase_inc(int voice, uint32_t phase_inc) override {
    a_.set_phase_inc(voice, phase_inc);
    b_.set_phase_inc(voice, phase_inc);
  }

  void set_filter(int voice, const FilterConfig& filter) override {
    a_.set_filter(voice, filter);
    b_.set_filter(voice, filter);
  }

  void commit_voice(int voice, int enable, uint32_t phase_inc, const Region& region) override {
    a_.commit_voice(voice, enable, phase_inc, region);
    b_.commit_voice(voice, enable, phase_inc, region);
  }

  void release_voice(int voice, const Region& region) override {
    a_.release_voice(voice, region);
    b_.release_voice(voice, region);
  }

 private:
  VoiceControlSink& a_;
  VoiceControlSink& b_;
};

}  // namespace render
