#include "reference_synth.h"

#include <algorithm>

namespace render {

ReferenceSynth::ReferenceSynth(const std::vector<int16_t>& memory)
    : memory_(memory), voices_(kNumVoices) {}

void ReferenceSynth::set_envelope(int voice, int level) {
  voices_.at(voice).envelope = int16_t(clamp_q15(level));
}

void ReferenceSynth::set_gain(int voice, int gain_l, int gain_r) {
  VoiceConfig& v = voices_.at(voice);
  v.gain_l = int16_t(clamp_q15(gain_l));
  v.gain_r = int16_t(clamp_q15(gain_r));
}

void ReferenceSynth::set_phase_inc(int voice, uint32_t phase_inc) {
  voices_.at(voice).phase_inc = phase_inc;
}

void ReferenceSynth::set_filter(int voice, const FilterConfig& filter) {
  VoiceConfig& v = voices_.at(voice);
  v.filter_enable = filter.enable;
  v.filter_b0 = int32_t(filter.b0);
  v.filter_b1 = int32_t(filter.b1);
  v.filter_b2 = int32_t(filter.b2);
  v.filter_a1 = int32_t(filter.a1);
  v.filter_a2 = int32_t(filter.a2);
}

void ReferenceSynth::commit_voice(int voice, int enable, uint32_t phase_inc, const Region& r) {
  VoiceConfig& v = voices_.at(voice);
  v.enable = enable != 0;
  v.valid = r.length != 0 && (r.loop_mode == 0 || (r.loop_start < r.loop_end && r.loop_end <= r.length));
  v.stereo = r.stereo;
  v.released = false;
  v.base_addr = r.base_addr;
  v.base_addr_r = r.base_addr_r;
  v.length = uint16_t(r.length);
  v.loop_start = uint16_t(r.loop_start);
  v.loop_end = uint16_t(r.loop_end);
  v.phase = 0;
  v.phase_inc = phase_inc;
  v.gain_l = int16_t(r.gain_l);
  v.gain_r = int16_t(r.gain_r);
  v.filter_enable = r.filter_enable;
  v.filter_b0 = int32_t(r.filter_b0);
  v.filter_b1 = int32_t(r.filter_b1);
  v.filter_b2 = int32_t(r.filter_b2);
  v.filter_a1 = int32_t(r.filter_a1);
  v.filter_a2 = int32_t(r.filter_a2);
  v.filter_z1_l = 0;
  v.filter_z2_l = 0;
  v.filter_z1_r = 0;
  v.filter_z2_r = 0;
  v.loop_mode = r.loop_mode;
}

void ReferenceSynth::release_voice(int voice, const Region& region) {
  VoiceConfig& v = voices_.at(voice);
  v.loop_mode = region.loop_mode;
  v.released = true;
}

std::pair<int16_t, int16_t> ReferenceSynth::render_sample() {
  int32_t accum_l = 0;
  int32_t accum_r = 0;

  for (VoiceConfig& v : voices_) {
    bool loop_active = (v.loop_mode == 1) || ((v.loop_mode == 2) && !v.released);
    bool voice_done = (v.loop_mode == 0 || !loop_active) && ((v.phase >> 16) >= v.length);
    if (!v.enable || !v.valid || voice_done) continue;

    uint16_t frame_0 = uint16_t(v.phase >> 16);
    uint16_t frame_1 = 0;
    if (loop_active) {
      frame_1 = (uint16_t(frame_0 + 1) >= v.loop_end) ? v.loop_start : uint16_t(frame_0 + 1);
    } else {
      frame_1 = (uint16_t(frame_0 + 1) >= v.length) ? frame_0 : uint16_t(frame_0 + 1);
    }
    uint16_t fraction = uint16_t(v.phase & 0xffffu);

    uint64_t phase_sum = uint64_t(v.phase) + uint64_t(v.phase_inc);
    uint64_t loop_end_phase = uint64_t(v.loop_end) << 16;
    uint32_t loop_length_phase = uint32_t(v.loop_end - v.loop_start) << 16;
    if (loop_active && phase_sum >= loop_end_phase)
      v.phase = uint32_t(phase_sum) - loop_length_phase;
    else
      v.phase = uint32_t(phase_sum);

    int16_t raw_l0 = read_word(v.base_addr + uint32_t(frame_0));
    int16_t raw_l1 = read_word(v.base_addr + uint32_t(frame_1));
    int16_t raw_r0 = v.stereo ? read_word(v.base_addr_r + uint32_t(frame_0)) : raw_l0;
    int16_t raw_r1 = v.stereo ? read_word(v.base_addr_r + uint32_t(frame_1)) : raw_l1;

    int16_t interp_l = interpolate(raw_l0, raw_l1, fraction);
    int16_t interp_r = interpolate(raw_r0, raw_r1, fraction);
    int16_t filter_l = v.filter_enable ? biquad(interp_l, v.filter_z1_l, v.filter_z2_l, v) : interp_l;
    int16_t filter_r = v.filter_enable ? biquad(interp_r, v.filter_z1_r, v.filter_z2_r, v) : interp_r;
    int16_t gained_l = apply_gain(filter_l, v.gain_l);
    int16_t gained_r = apply_gain(filter_r, v.gain_r);
    int16_t env_l = v.envelope == int16_t(0x7fff) ? gained_l : apply_gain(gained_l, v.envelope);
    int16_t env_r = v.envelope == int16_t(0x7fff) ? gained_r : apply_gain(gained_r, v.envelope);
    accum_l += env_l;
    accum_r += env_r;
  }

  return {saturate(accum_l), saturate(accum_r)};
}

int16_t ReferenceSynth::interpolate(int16_t sample_0, int16_t sample_1, uint16_t fraction) {
  int32_t difference = int32_t(sample_1) - int32_t(sample_0);
  int64_t product = int64_t(difference) * int64_t(fraction);
  int32_t scaled_difference = int32_t(product >> 16);
  return saturate(int32_t(sample_0) + scaled_difference);
}

int16_t ReferenceSynth::apply_gain(int16_t sample, int16_t gain) {
  int32_t product = int32_t(sample) * int32_t(gain);
  return saturate(product >> 15);
}

int16_t ReferenceSynth::saturate(int32_t value) {
  if (value > 32767) return int16_t(0x7fff);
  if (value < -32768) return int16_t(0x8000);
  return int16_t(value);
}

int64_t ReferenceSynth::saturate_i64(__int128 value) {
  if (value > __int128(9223372036854775807ll)) return 0x7fffffffffffffffll;
  if (value < -__int128(9223372036854775807ll) - 1) return int64_t(0x8000000000000000ull);
  return int64_t(value);
}

int16_t ReferenceSynth::biquad(int16_t sample, int64_t& z1, int64_t& z2, const VoiceConfig& v) {
  int64_t y_q28 = int64_t(v.filter_b0) * int64_t(sample) + z1;
  int64_t y_shift = y_q28 >> 28;
  int16_t y = y_shift > 32767 ? int16_t(0x7fff) :
              (y_shift < -32768 ? int16_t(0x8000) : int16_t(y_shift));
  __int128 next_z1 = __int128(v.filter_b1) * sample - __int128(v.filter_a1) * y + z2;
  __int128 next_z2 = __int128(v.filter_b2) * sample - __int128(v.filter_a2) * y;
  z1 = saturate_i64(next_z1);
  z2 = saturate_i64(next_z2);
  return y;
}

int16_t ReferenceSynth::read_word(uint32_t address) const {
  return address < memory_.size() ? memory_[address] : 0;
}

}  // namespace render
