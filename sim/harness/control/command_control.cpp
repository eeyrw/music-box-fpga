#include "command_control.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace render {
namespace {

constexpr uint8_t kDefineMono = 0x10;
constexpr uint8_t kRelease = 0x14;
constexpr uint8_t kStop = 0x15;
constexpr uint8_t kGain = 0x16;
constexpr uint8_t kFilter = 0x17;
constexpr uint8_t kPitch = 0x18;
constexpr uint8_t kCompressorConfig = 0x20;
constexpr uint8_t kMasterVolume = 0x21;
constexpr uint8_t kChorusConfig = 0x22;
constexpr uint8_t kReverbConfig = 0x23;
constexpr uint8_t kEffectClear = 0x24;
constexpr uint32_t kSilenceCbQ12_20 = 1000u << 20;

uint32_t pack_pair(int high, int low) {
  return (uint32_t(uint16_t(high)) << 16) | uint32_t(uint16_t(low));
}

uint32_t ceil_step(uint64_t distance, uint32_t duration) {
  if (duration == 0) return 0;
  return uint32_t(std::min<uint64_t>(0xffffffffu, (distance + duration - 1u) / duration));
}

}  // namespace

void CommandFanout::write_command_words(CommandWordView words) {
  first_.write_command_words(words);
  second_.write_command_words(words);
}

FrameBatchedCommandSink::FrameBatchedCommandSink(
    CommandWordSink& sink, std::size_t max_actions_per_frame)
    : sink_(sink), max_actions_per_frame_(max_actions_per_frame) {
  if (max_actions_per_frame_ == 0) {
    throw std::invalid_argument("frame action batch must be nonzero");
  }
}

void FrameBatchedCommandSink::write_command_words(
    CommandWordView words) {
  if (words.empty()) return;
  if (words.size() > kMaxCommandWords) {
    throw std::length_error("frame-batched command exceeds 17 words");
  }
  if (pending_count_ == pending_.size()) {
    throw std::length_error("frame-batched command queue is full");
  }
  PendingCommand& pending = pending_[pending_tail_];
  pending.command = {};
  for (uint32_t word : words) pending.command.push_back(word);
  pending.enqueue_frame = frame_index_;
  pending_tail_ = (pending_tail_ + 1) % pending_.size();
  ++pending_count_;
  ++total_enqueued_actions_;
  max_pending_actions_ = std::max(max_pending_actions_, pending_count_);
}

std::size_t FrameBatchedCommandSink::apply_frame() {
  std::size_t applied = 0;
  while (applied < max_actions_per_frame_ && pending_count_ != 0) {
    PendingCommand command = pending_[pending_head_];
    pending_head_ = (pending_head_ + 1) % pending_.size();
    --pending_count_;
    max_deferred_frames_ = std::max(
        max_deferred_frames_, frame_index_ - command.enqueue_frame);
    sink_.write_command_words(command.command.view());
    ++applied;
    ++total_applied_actions_;
  }
  ++frame_index_;
  return applied;
}

CommandVoiceControl::CommandVoiceControl(CommandWordSink& sink) : sink_(sink) {}

void CommandVoiceControl::emit(uint8_t opcode, int voice,
                               std::initializer_list<uint32_t> payload,
                               uint8_t flags) {
  emit(opcode, voice, CommandWordView(payload.begin(), payload.size()), flags);
}

void CommandVoiceControl::emit(uint8_t opcode, int voice,
                               CommandWordView payload,
                               uint8_t flags) {
  if (voice < 0 || voice >= kNumVoices) throw std::out_of_range("voice command slot");
  if (flags > 0x3f) throw std::out_of_range("voice command flags");
  FixedCommand command;
  command.push_back((uint32_t(opcode) << 24) |
                  (uint32_t(voice & 0x3ff) << 14) |
                  (uint32_t(flags) << 8) | uint32_t(payload.size()));
  for (uint32_t word : payload) command.push_back(word);
  sink_.write_command_words(command.view());
}

void CommandVoiceControl::start_voice(int voice, uint32_t phase_inc, const Region& r) {
  VoiceMirror& mirror = voices_.at(voice);
  mirror.generation = uint16_t(mirror.generation + 1u);
  if (mirror.generation == 0) mirror.generation = 1;
  if (r.stereo) {
    throw std::invalid_argument(
        "voice-major command protocol requires one mono Region per voice");
  }

  const VolumeEnvelopeParams& env = r.volume_envelope;
  const uint32_t attack_step = ceil_step(0xffffffffu, env.attack_samples);
  const uint32_t decay_step = ceil_step(env.sustain_cb_q12_20, env.decay_samples);
  const bool has_loop = r.loop_mode != 0;
  const bool has_filter = r.filter_enable;
  const bool has_envelope = env.delay_samples != 0 || env.attack_samples != 0 ||
      env.hold_samples != 0 || env.decay_samples != 0 ||
      env.sustain_cb_q12_20 != 0 || env.release_samples != 0;
  uint8_t flags = uint8_t(r.loop_mode & 3);
  if (has_filter) flags |= 1u << 2;
  if (has_envelope) flags |= 1u << 3;
  FixedCommand payload;
  payload.push_back(uint32_t(mirror.generation));
  payload.push_back(r.base_addr);
  payload.push_back(r.length);
  if (has_loop) {
    payload.push_back(r.loop_start);
    payload.push_back(r.loop_end);
  }
  payload.push_back(phase_inc);
  payload.push_back(pack_pair(r.gain_r, r.gain_l));
  if (has_filter) {
    payload.push_back(pack_pair(r.filter_b1, r.filter_b0));
    payload.push_back(pack_pair(r.filter_a1, r.filter_b2));
    payload.push_back(uint32_t(uint16_t(r.filter_a2)) | 0x00010000u);
  }
  if (has_envelope) {
    payload.push_back(env.delay_samples);
    payload.push_back(attack_step);
    payload.push_back(env.hold_samples);
    payload.push_back(decay_step);
    payload.push_back(env.sustain_cb_q12_20);
    payload.push_back(envelope_release_step(r));
  }
  emit(kDefineMono, voice, payload.view(), flags);
  mirror.active = true;
  mirror.released = false;
  mirror.gain_l = r.gain_l;
  mirror.gain_r = r.gain_r;
  mirror.phase_inc = phase_inc;
  mirror.filter = {r.filter_enable, r.filter_b0, r.filter_b1, r.filter_b2,
                   r.filter_a1, r.filter_a2};
}

void CommandVoiceControl::update_gain_phase(int voice, int gain_l, int gain_r,
                                            uint32_t phase_inc) {
  const VoiceMirror& mirror = voices_.at(voice);
  if (!mirror.active) return;
  const int next_gain_l = clamp_q15(gain_l);
  const int next_gain_r = clamp_q15(gain_r);
  if (next_gain_l == mirror.gain_l && next_gain_r == mirror.gain_r &&
      phase_inc == mirror.phase_inc) {
    return;
  }
  if (next_gain_l != mirror.gain_l || next_gain_r != mirror.gain_r) {
    emit(kGain, voice,
         {uint32_t(mirror.generation), pack_pair(next_gain_r, next_gain_l)});
  }
  if (phase_inc != mirror.phase_inc) {
    emit(kPitch, voice,
         {uint32_t(mirror.generation), phase_inc});
  }
  VoiceMirror& updated = voices_.at(voice);
  updated.gain_l = next_gain_l;
  updated.gain_r = next_gain_r;
  updated.phase_inc = phase_inc;
}

void CommandVoiceControl::update_filter(int voice, const FilterConfig& filter) {
  VoiceMirror& mirror = voices_.at(voice);
  if (!mirror.active) return;
  if (filter.enable == mirror.filter.enable && filter.b0 == mirror.filter.b0 &&
      filter.b1 == mirror.filter.b1 && filter.b2 == mirror.filter.b2 &&
      filter.a1 == mirror.filter.a1 && filter.a2 == mirror.filter.a2) {
    return;
  }
  emit(kFilter, voice,
       {uint32_t(mirror.generation),
        pack_pair(filter.b1, filter.b0),
        pack_pair(filter.a1, filter.b2),
        uint32_t(uint16_t(filter.a2)) | (filter.enable ? 0x00010000u : 0u)});
  mirror.filter = filter;
}

void CommandVoiceControl::release_voice(int voice, uint32_t release_step_cb_q12_20) {
  VoiceMirror& mirror = voices_.at(voice);
  if (!mirror.active) return;
  if (mirror.released) return;
  emit(kRelease, voice,
       {uint32_t(mirror.generation), release_step_cb_q12_20});
  mirror.released = true;
}

void CommandVoiceControl::stop_voice(int voice) {
  VoiceMirror& mirror = voices_.at(voice);
  if (!mirror.active) return;
  emit(kStop, voice, {uint32_t(mirror.generation)});
  mirror.active = false;
  mirror.released = false;
}

void CommandAudioControl::emit(uint8_t opcode,
                               CommandWordView payload) {
  FixedCommand command;
  command.push_back((uint32_t(opcode) << 24) | uint32_t(payload.size()));
  for (uint32_t word : payload) command.push_back(word);
  sink_.write_command_words(command.view());
}

void CommandAudioControl::emit(uint8_t opcode,
                               std::initializer_list<uint32_t> payload) {
  emit(opcode, CommandWordView(payload.begin(), payload.size()));
}

void CommandAudioControl::configure_compressor(
    const CompressorCommandConfig& config) {
  if (config.threshold_cb_q12_20 > kSilenceCbQ12_20 ||
      config.attack_step_cb_q12_20 > kSilenceCbQ12_20 ||
      config.release_step_cb_q12_20 > kSilenceCbQ12_20) {
    throw std::out_of_range("compressor centibel field");
  }
  emit(kCompressorConfig,
       {(uint32_t(config.ratio_slope_q0_16) << 1) |
            (config.enable ? 1u : 0u),
        config.threshold_cb_q12_20, config.attack_step_cb_q12_20,
        config.release_step_cb_q12_20});
}

void CommandAudioControl::set_master_volume(int gain_q1_15) {
  emit(kMasterVolume, {uint32_t(uint16_t(clamp_q15(gain_q1_15)))});
}

void CommandAudioControl::configure_chorus(const ChorusCommandConfig& config) {
  if (config.base_delay_q16_8 > 0x00ffffffu ||
      config.depth_q16_8 > 0x00ffffffu ||
      config.input_send_q1_15 > 0x7fffu ||
      config.return_gain_q1_15 > 0x7fffu ||
      config.feedback_q1_15 < -0x6000 || config.feedback_q1_15 > 0x6000) {
    throw std::out_of_range("chorus command field");
  }
  emit(kChorusConfig,
       {(uint32_t(uint16_t(config.feedback_q1_15)) << 16) |
            (config.enable ? 1u : 0u),
        config.base_delay_q16_8, config.depth_q16_8,
        config.lfo_phase_inc_q0_32,
        pack_pair(config.return_gain_q1_15, config.input_send_q1_15),
        config.stereo_phase_offset_q0_32});
}

void CommandAudioControl::configure_reverb(const ReverbCommandConfig& config) {
  if (config.pre_delay_frames > 0x7ffu || config.input_send_q1_15 > 0x7fffu ||
      config.return_gain_q1_15 > 0x7fffu || config.damping_q1_15 > 0x7fffu ||
      config.chorus_to_reverb_q1_15 > 0x7fffu ||
      std::any_of(config.feedback_gain_q1_15.begin(),
                  config.feedback_gain_q1_15.end(),
                  [](uint16_t gain) { return gain > 0x2d41u; })) {
    throw std::out_of_range("reverb command field");
  }
  emit(kReverbConfig,
       {(uint32_t(config.pre_delay_frames) << 1) | (config.enable ? 1u : 0u),
        config.input_send_q1_15, config.return_gain_q1_15,
        config.damping_q1_15, config.chorus_to_reverb_q1_15,
        pack_pair(config.feedback_gain_q1_15[1], config.feedback_gain_q1_15[0]),
        pack_pair(config.feedback_gain_q1_15[3], config.feedback_gain_q1_15[2]),
        pack_pair(config.feedback_gain_q1_15[5], config.feedback_gain_q1_15[4]),
        pack_pair(config.feedback_gain_q1_15[7], config.feedback_gain_q1_15[6])});
}

void CommandAudioControl::clear_effects(uint8_t mask) {
  if ((mask & ~uint8_t{3}) != 0 || (mask & 3u) == 0) {
    throw std::out_of_range("effect clear mask");
  }
  emit(kEffectClear, {uint32_t(mask)});
}

uint32_t envelope_release_step(const Region& region) {
  return ceil_step(kSilenceCbQ12_20, region.volume_envelope.release_samples);
}

}  // namespace render
