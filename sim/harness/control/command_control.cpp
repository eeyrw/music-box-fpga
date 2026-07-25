#include "command_control.h"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace render {
namespace {

constexpr uint8_t kDefineMono = 0x10;
constexpr uint8_t kDefineStereo = 0x11;
constexpr uint8_t kStart = 0x12;
constexpr uint8_t kRelease = 0x14;
constexpr uint8_t kStop = 0x15;
constexpr uint8_t kGainPhase = 0x16;
constexpr uint8_t kFilter = 0x17;
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

void CommandFanout::write_command_words(const std::vector<uint32_t>& words) {
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
    const std::vector<uint32_t>& words) {
  if (words.empty()) return;
  pending_.push_back({words, frame_index_});
  ++total_enqueued_actions_;
  max_pending_actions_ = std::max(max_pending_actions_, pending_.size());
}

std::size_t FrameBatchedCommandSink::apply_frame() {
  std::size_t applied = 0;
  while (applied < max_actions_per_frame_ && !pending_.empty()) {
    PendingCommand command = std::move(pending_.front());
    pending_.pop_front();
    max_deferred_frames_ = std::max(
        max_deferred_frames_, frame_index_ - command.enqueue_frame);
    const bool flush = uint8_t(command.words.front() >> 24) == 0x7f;
    sink_.write_command_words(command.words);
    ++applied;
    ++total_applied_actions_;
    if (flush) {
      pending_.clear();
      break;
    }
  }
  ++frame_index_;
  return applied;
}

CommandVoiceControl::CommandVoiceControl(CommandWordSink& sink) : sink_(sink) {}

void CommandVoiceControl::emit(uint8_t opcode, int voice, uint8_t seq,
                               std::initializer_list<uint32_t> payload) {
  if (voice < 0 || voice >= kNumVoices) throw std::out_of_range("voice command slot");
  std::vector<uint32_t> words;
  words.reserve(payload.size() + 1);
  words.push_back((uint32_t(opcode) << 24) | (uint32_t(uint8_t(voice)) << 16) |
                  (uint32_t(seq) << 8) | uint32_t(payload.size()));
  words.insert(words.end(), payload.begin(), payload.end());
  sink_.write_command_words(words);
}

void CommandVoiceControl::start_voice(int voice, uint32_t phase_inc, const Region& r) {
  VoiceMirror& mirror = voices_.at(voice);
  mirror.seq = uint8_t(mirror.seq + 1u);
  if (mirror.seq == 0) mirror.seq = 1;

  const uint32_t filter0 = pack_pair(r.filter_b1, r.filter_b0);
  const uint32_t filter1 = pack_pair(r.filter_a1, r.filter_b2);
  const uint32_t filter2 = uint32_t(uint16_t(r.filter_a2)) |
                           (r.filter_enable ? 0x00010000u : 0u);
  if (r.stereo) {
    emit(kDefineStereo, voice, mirror.seq,
         {r.base_addr, r.base_addr_r, r.length, r.length_r,
          r.loop_start, r.loop_start_r, r.loop_end, r.loop_end_r, 0,
          uint32_t(r.loop_mode & 3), filter0, filter1, filter2, 0, 0});
  } else {
    emit(kDefineMono, voice, mirror.seq,
         {r.base_addr, r.length, r.loop_start, r.loop_end, 0,
          uint32_t(r.loop_mode & 3), filter0, filter1, filter2, 0, 0});
  }

  const VolumeEnvelopeParams& env = r.volume_envelope;
  const uint32_t attack_step = ceil_step(0xffffffffu, env.attack_samples);
  const uint32_t decay_step = ceil_step(env.sustain_cb_q12_20, env.decay_samples);
  emit(kStart, voice, mirror.seq,
       {pack_pair(r.gain_r, r.gain_l), phase_inc, env.delay_samples, attack_step,
        env.hold_samples, decay_step, env.sustain_cb_q12_20,
        envelope_release_step(r)});
  mirror.active = true;
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
  emit(kGainPhase, voice, mirror.seq,
       {pack_pair(next_gain_r, next_gain_l), phase_inc});
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
  emit(kFilter, voice, mirror.seq,
       {pack_pair(filter.b1, filter.b0), pack_pair(filter.a1, filter.b2),
        uint32_t(uint16_t(filter.a2)) | (filter.enable ? 0x00010000u : 0u)});
  mirror.filter = filter;
}

void CommandVoiceControl::release_voice(int voice, uint32_t release_step_cb_q12_20) {
  VoiceMirror& mirror = voices_.at(voice);
  if (!mirror.active) return;
  emit(kRelease, voice, mirror.seq, {release_step_cb_q12_20});
  mirror.active = false;
}

void CommandVoiceControl::stop_voice(int voice) {
  VoiceMirror& mirror = voices_.at(voice);
  if (!mirror.active) return;
  emit(kStop, voice, mirror.seq, {});
  mirror.active = false;
}

void CommandAudioControl::emit(uint8_t opcode,
                               std::initializer_list<uint32_t> payload) {
  std::vector<uint32_t> words;
  words.reserve(payload.size() + 1);
  words.push_back((uint32_t(opcode) << 24) | uint32_t(payload.size()));
  words.insert(words.end(), payload.begin(), payload.end());
  sink_.write_command_words(words);
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
