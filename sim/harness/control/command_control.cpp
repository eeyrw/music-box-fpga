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
constexpr uint32_t kSilenceCbQ12_20 = 960u << 20;

uint32_t pack_pair(int high, int low) {
  return (uint32_t(uint16_t(high)) << 16) | uint32_t(uint16_t(low));
}

uint32_t duration_samples(int ticks, int scale) {
  uint64_t samples = uint64_t(std::max(0, ticks)) * uint64_t(std::max(1, scale));
  return uint32_t(std::min<uint64_t>(samples, 0x00ffffffu));
}

uint32_t q15_to_cb_q12_20(int level) {
  level = clamp_q15(level);
  if (level <= 0) return kSilenceCbQ12_20;
  double cb = -200.0 * std::log10(double(level) / double(kQ15Full));
  return uint32_t(std::llround(std::clamp(cb, 0.0, 960.0) * double(1u << 20)));
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

  const uint32_t delay = duration_samples(r.delay_ticks, r.envelope_tick_samples);
  const uint32_t attack_duration = duration_samples(r.attack_ticks, r.envelope_tick_samples);
  const uint32_t attack_step = r.attack_sub_tick ? 0 : ceil_step(0xffffffffu, attack_duration);
  const uint32_t hold = duration_samples(r.hold_ticks, r.envelope_tick_samples);
  const uint32_t sustain_cb = q15_to_cb_q12_20(r.sustain_level);
  const uint32_t decay_duration = duration_samples(r.decay_ticks, r.envelope_tick_samples);
  const uint32_t decay_step = ceil_step(sustain_cb, decay_duration);
  emit(kStart, voice, mirror.seq,
       {pack_pair(r.gain_r, r.gain_l), phase_inc, delay, attack_step, hold,
        decay_step, sustain_cb, envelope_release_step(r)});
  mirror.active = true;
}

void CommandVoiceControl::update_gain_phase(int voice, int gain_l, int gain_r,
                                            uint32_t phase_inc) {
  const VoiceMirror& mirror = voices_.at(voice);
  if (!mirror.active) return;
  emit(kGainPhase, voice, mirror.seq,
       {pack_pair(clamp_q15(gain_r), clamp_q15(gain_l)), phase_inc});
}

void CommandVoiceControl::update_filter(int voice, const FilterConfig& filter) {
  const VoiceMirror& mirror = voices_.at(voice);
  if (!mirror.active) return;
  emit(kFilter, voice, mirror.seq,
       {pack_pair(filter.b1, filter.b0), pack_pair(filter.a1, filter.b2),
        uint32_t(uint16_t(filter.a2)) | (filter.enable ? 0x00010000u : 0u)});
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

uint32_t envelope_release_step(const Region& region) {
  const uint32_t duration = duration_samples(region.release_ticks,
                                             region.envelope_tick_samples);
  return ceil_step(kSilenceCbQ12_20, duration);
}

}  // namespace render
