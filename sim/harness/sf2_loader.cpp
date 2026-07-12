#include "sf2_loader.h"

#include "byte_reader.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace render {
namespace {

constexpr int GEN_PAN = 17;
constexpr int GEN_START_ADDRS_OFFSET = 0;
constexpr int GEN_END_ADDRS_OFFSET = 1;
constexpr int GEN_STARTLOOP_ADDRS_OFFSET = 2;
constexpr int GEN_ENDLOOP_ADDRS_OFFSET = 3;
constexpr int GEN_START_ADDRS_COARSE_OFFSET = 4;
constexpr int GEN_INITIAL_FILTER_FC = 8;
constexpr int GEN_INITIAL_FILTER_Q = 9;
constexpr int GEN_DELAY_VOL_ENV = 33;
constexpr int GEN_ATTACK_VOL_ENV = 34;
constexpr int GEN_HOLD_VOL_ENV = 35;
constexpr int GEN_DECAY_VOL_ENV = 36;
constexpr int GEN_SUSTAIN_VOL_ENV = 37;
constexpr int GEN_RELEASE_VOL_ENV = 38;
constexpr int GEN_KEYNUM_TO_VOL_ENV_HOLD = 39;
constexpr int GEN_KEYNUM_TO_VOL_ENV_DECAY = 40;
constexpr int GEN_INSTRUMENT = 41;
constexpr int GEN_KEY_RANGE = 43;
constexpr int GEN_VEL_RANGE = 44;
constexpr int GEN_STARTLOOP_ADDRS_COARSE_OFFSET = 45;
constexpr int GEN_KEYNUM = 46;
constexpr int GEN_VELOCITY = 47;
constexpr int GEN_INITIAL_ATTENUATION = 48;
constexpr int GEN_END_ADDRS_COARSE_OFFSET = 12;
constexpr int GEN_ENDLOOP_ADDRS_COARSE_OFFSET = 50;
constexpr int GEN_COARSE_TUNE = 51;
constexpr int GEN_FINE_TUNE = 52;
constexpr int GEN_SAMPLE_ID = 53;
constexpr int GEN_SAMPLE_MODES = 54;
constexpr int GEN_SCALE_TUNING = 56;
constexpr int GEN_EXCLUSIVE_CLASS = 57;
constexpr int GEN_OVERRIDING_ROOT_KEY = 58;

constexpr int SAMPLE_MONO = 1;
constexpr int SAMPLE_RIGHT = 2;
constexpr int SAMPLE_LEFT = 4;
constexpr int SAMPLE_LINKED = 8;
constexpr int SAMPLE_ROM_FLAG = 0x8000;

using Zone = std::map<int, int>;

// Locate one top-level LIST chunk inside the RIFF/sfbk container. SoundFont2
// keeps sample PCM under LIST sdta and preset/instrument metadata under LIST
// pdta; the harness loads only those two sections.
std::vector<uint8_t> find_list_chunk(const std::vector<uint8_t>& data, const char wanted[4]) {
  if (data.size() < 12 || std::memcmp(data.data(), "RIFF", 4) != 0 ||
      std::memcmp(data.data() + 8, "sfbk", 4) != 0) {
    throw std::runtime_error("not a SoundFont2 RIFF/sfbk file");
  }

  size_t pos = 12;
  while (pos + 8 <= data.size()) {
    uint32_t size = read_u32le(data, pos + 4);
    size_t payload = pos + 8;
    if (payload + size > data.size()) throw std::runtime_error("truncated RIFF chunk");
    if (std::memcmp(data.data() + pos, "LIST", 4) == 0 && size >= 4 &&
        std::memcmp(data.data() + payload, wanted, 4) == 0) {
      return slice(data, payload + 4, size - 4);
    }
    pos = payload + size + (size & 1u);
  }
  throw std::runtime_error(std::string("missing LIST ") + std::string(wanted, 4));
}

bool find_list_chunk_optional(const std::vector<uint8_t>& data, const char wanted[4],
                              std::vector<uint8_t>& out) {
  if (data.size() < 12 || std::memcmp(data.data(), "RIFF", 4) != 0 ||
      std::memcmp(data.data() + 8, "sfbk", 4) != 0) {
    throw std::runtime_error("not a SoundFont2 RIFF/sfbk file");
  }
  size_t pos = 12;
  while (pos + 8 <= data.size()) {
    uint32_t size = read_u32le(data, pos + 4);
    size_t payload = pos + 8;
    if (payload + size > data.size()) throw std::runtime_error("truncated RIFF chunk");
    if (std::memcmp(data.data() + pos, "LIST", 4) == 0 && size >= 4 &&
        std::memcmp(data.data() + payload, wanted, 4) == 0) {
      out = slice(data, payload + 4, size - 4);
      return true;
    }
    pos = payload + size + (size & 1u);
  }
  return false;
}

std::map<std::string, std::vector<uint8_t>> list_chunks(const std::vector<uint8_t>& payload) {
  // Return child chunks by four-character ID. RIFF chunks are padded to an even
  // byte count, so pos advances by size plus the low padding bit.
  std::map<std::string, std::vector<uint8_t>> chunks;
  size_t pos = 0;
  while (pos + 8 <= payload.size()) {
    std::string id(reinterpret_cast<const char*>(payload.data() + pos), 4);
    uint32_t size = read_u32le(payload, pos + 4);
    size_t start = pos + 8;
    chunks[id] = slice(payload, start, size);
    pos = start + size + (size & 1u);
  }
  return chunks;
}

const std::vector<uint8_t>& require_chunk(const std::map<std::string, std::vector<uint8_t>>& chunks,
                                          const char* id, size_t record_size,
                                          size_t min_records) {
  auto it = chunks.find(id);
  if (it == chunks.end()) throw std::runtime_error(std::string("missing SF2 chunk ") + id);
  if (record_size != 0 && (it->second.size() % record_size) != 0) {
    throw std::runtime_error(std::string("SF2 chunk ") + id + " has invalid record size");
  }
  if (record_size != 0 && it->second.size() / record_size < min_records) {
    throw std::runtime_error(std::string("SF2 chunk ") + id + " has too few records");
  }
  return it->second;
}

int signed_amount(int amount) {
  // SF2 generator amounts are stored as unsigned 16-bit fields even when the
  // generator meaning is signed. Reinterpret the low 16 bits as int16_t.
  return int16_t(uint16_t(amount));
}

int sanitize_sample_type(int sample_type) {
  // The high bit marks ROM samples in the SF2 spec. This harness only cares
  // whether the sample is mono, left, or right, so mask off non-type flags.
  return sample_type & 0x7fff;
}

std::string text_chunk(const std::map<std::string, std::vector<uint8_t>>& chunks, const char* id) {
  auto it = chunks.find(id);
  if (it == chunks.end()) return {};
  std::string s(reinterpret_cast<const char*>(it->second.data()), it->second.size());
  while (!s.empty() && s.back() == '\0') s.pop_back();
  return s;
}

std::string version_chunk(const std::map<std::string, std::vector<uint8_t>>& chunks, const char* id) {
  auto it = chunks.find(id);
  if (it == chunks.end()) return {};
  if (it->second.size() < 4) throw std::runtime_error(std::string("SF2 INFO ") + id + " is too short");
  return std::to_string(read_u16le(it->second, 0)) + "." + std::to_string(read_u16le(it->second, 2));
}

int16_t merge_smpl_sm24(int16_t high, uint8_t low) {
  int32_t full = (int32_t(high) << 8) | int32_t(low);
  int32_t rounded = full >= 0 ? ((full + 128) >> 8) : -(((-full) + 128) >> 8);
  rounded = std::max<int32_t>(std::numeric_limits<int16_t>::min(),
                              std::min<int32_t>(std::numeric_limits<int16_t>::max(), rounded));
  return int16_t(rounded);
}

std::vector<Preset> parse_presets(const std::vector<uint8_t>& c) {
  std::vector<Preset> out;
  for (size_t i = 0; i + 38 <= c.size(); i += 38) {
    out.push_back({clean_name(c, i, 20), read_u16le(c, i + 20),
                   read_u16le(c, i + 22), read_u16le(c, i + 24)});
  }
  return out;
}

std::vector<Instrument> parse_instruments(const std::vector<uint8_t>& c) {
  std::vector<Instrument> out;
  for (size_t i = 0; i + 22 <= c.size(); i += 22) {
    out.push_back({clean_name(c, i, 20), read_u16le(c, i + 20)});
  }
  return out;
}

std::vector<Bag> parse_bags(const std::vector<uint8_t>& c) {
  std::vector<Bag> out;
  for (size_t i = 0; i + 4 <= c.size(); i += 4) {
    out.push_back({read_u16le(c, i), read_u16le(c, i + 2)});
  }
  return out;
}

std::vector<Generator> parse_generators(const std::vector<uint8_t>& c) {
  std::vector<Generator> out;
  for (size_t i = 0; i + 4 <= c.size(); i += 4) {
    out.push_back({read_u16le(c, i), read_u16le(c, i + 2)});
  }
  return out;
}

std::vector<SampleHeader> parse_samples(const std::vector<uint8_t>& c) {
  std::vector<SampleHeader> out;
  for (size_t i = 0; i + 46 <= c.size(); i += 46) {
    SampleHeader s;
    s.name = clean_name(c, i, 20);
    s.start = read_u32le(c, i + 20);
    s.end = read_u32le(c, i + 24);
    s.start_loop = read_u32le(c, i + 28);
    s.end_loop = read_u32le(c, i + 32);
    s.sample_rate = read_u32le(c, i + 36);
    s.original_pitch = c[i + 40];
    s.pitch_correction = int8_t(c[i + 41]);
    s.sample_link = read_u16le(c, i + 42);
    s.sample_type = read_u16le(c, i + 44);
    out.push_back(s);
  }
  return out;
}

void validate_index_tables(const Sf2Data& sf2) {
  auto check_monotonic = [](const char* label, const auto& records, auto member) {
    for (size_t i = 1; i < records.size(); ++i) {
      if (records[i].*member < records[i - 1].*member) {
        throw std::runtime_error(std::string("SF2 ") + label + " indices are not monotonic");
      }
    }
  };
  check_monotonic("phdr bag", sf2.presets, &Preset::bag_index);
  check_monotonic("inst bag", sf2.instruments, &Instrument::bag_index);
  check_monotonic("pbag generator", sf2.preset_bags, &Bag::gen_index);
  check_monotonic("ibag generator", sf2.instrument_bags, &Bag::gen_index);
  check_monotonic("pbag modulator", sf2.preset_bags, &Bag::mod_index);
  check_monotonic("ibag modulator", sf2.instrument_bags, &Bag::mod_index);

  if (sf2.presets.back().bag_index + 1 != int(sf2.preset_bags.size())) {
    throw std::runtime_error("SF2 phdr terminal bag index does not match pbag size");
  }
  if (sf2.instruments.back().bag_index + 1 != int(sf2.instrument_bags.size())) {
    throw std::runtime_error("SF2 inst terminal bag index does not match ibag size");
  }
  if (sf2.preset_bags.back().gen_index + 1 != int(sf2.preset_generators.size())) {
    throw std::runtime_error("SF2 pbag terminal generator index does not match pgen size");
  }
  if (sf2.instrument_bags.back().gen_index + 1 != int(sf2.instrument_generators.size())) {
    throw std::runtime_error("SF2 ibag terminal generator index does not match igen size");
  }
  if (sf2.samples.size() < 2) throw std::runtime_error("SF2 shdr has no usable samples");

  int usable_presets = std::max(0, int(sf2.presets.size()) - 1);
  for (int i = 0; i < usable_presets; ++i) {
    if (sf2.presets[i].preset < 0 || sf2.presets[i].preset > 127 ||
        sf2.presets[i].bank < 0 || sf2.presets[i].bank > 16383) {
      throw std::runtime_error("SF2 preset header has out-of-range preset or bank");
    }
    for (int j = i + 1; j < usable_presets; ++j) {
      if (sf2.presets[i].preset == sf2.presets[j].preset && sf2.presets[i].bank == sf2.presets[j].bank) {
        throw std::runtime_error("SF2 preset header contains duplicate preset/bank");
      }
    }
  }

  int usable_samples = std::max(0, int(sf2.samples.size()) - 1);
  for (int i = 0; i < usable_samples; ++i) {
    const auto& s = sf2.samples[i];
    if (s.end < s.start || s.start_loop < s.start || s.end_loop > s.end || s.end_loop < s.start_loop) {
      throw std::runtime_error("SF2 sample header has invalid sample or loop bounds");
    }
    if (s.sample_rate == 0) throw std::runtime_error("SF2 sample header has zero sample rate");
    int t = sanitize_sample_type(s.sample_type);
    if (t != SAMPLE_MONO && t != SAMPLE_LEFT && t != SAMPLE_RIGHT && t != SAMPLE_LINKED) {
      throw std::runtime_error("SF2 sample header has illegal sample type");
    }
    if ((t == SAMPLE_LEFT || t == SAMPLE_RIGHT || t == SAMPLE_LINKED) &&
        (s.sample_link < 0 || s.sample_link >= usable_samples)) {
      throw std::runtime_error("SF2 linked sample points outside usable sample headers");
    }
  }
}

bool illegal_preset_generator(int oper) {
  // SF2 sample, substitution, and some index generators are undefined at the
  // preset level. Preset value generators are relative; these are not.
  return oper == GEN_START_ADDRS_OFFSET || oper == GEN_END_ADDRS_OFFSET ||
         oper == GEN_STARTLOOP_ADDRS_OFFSET || oper == GEN_ENDLOOP_ADDRS_OFFSET ||
         oper == GEN_START_ADDRS_COARSE_OFFSET || oper == GEN_END_ADDRS_COARSE_OFFSET ||
         oper == GEN_STARTLOOP_ADDRS_COARSE_OFFSET || oper == GEN_KEYNUM || oper == GEN_VELOCITY ||
         oper == GEN_ENDLOOP_ADDRS_COARSE_OFFSET || oper == GEN_SAMPLE_ID ||
         oper == GEN_SAMPLE_MODES || oper == GEN_EXCLUSIVE_CLASS ||
         oper == GEN_OVERRIDING_ROOT_KEY;
}

bool additive_preset_generator(int oper) {
  return oper != GEN_KEY_RANGE && oper != GEN_VEL_RANGE && oper != GEN_INSTRUMENT &&
         !illegal_preset_generator(oper);
}

Zone generators_for_zone_checked(const std::vector<Generator>& gens, int start, int end,
                                 int terminal_oper, bool preset_level,
                                 bool& has_terminal) {
  Zone zone;
  has_terminal = false;
  for (int i = start; i < end; ++i) {
    int oper = gens.at(i).oper;
    int rel = i - start;
    if (oper == GEN_KEY_RANGE && rel != 0) continue;
    if (oper == GEN_VEL_RANGE && !(rel == 0 || (rel == 1 && gens.at(start).oper == GEN_KEY_RANGE))) continue;
    if (preset_level && illegal_preset_generator(oper)) continue;
    zone[oper] = gens.at(i).amount;
    if (oper == terminal_oper) {
      has_terminal = true;
      break;
    }
  }
  return zone;
}

int add_amount_bits(int a, int b) {
  int sum = signed_amount(a) + signed_amount(b);
  sum = std::max(-32768, std::min(32767, sum));
  return int(uint16_t(int16_t(sum)));
}

int sample_offset(const Zone& zone, int fine_oper, int coarse_oper) {
  int fine = zone.count(fine_oper) ? signed_amount(zone.at(fine_oper)) : 0;
  int coarse = zone.count(coarse_oper) ? signed_amount(zone.at(coarse_oper)) : 0;
  return fine + coarse * 32768;
}

uint32_t clamp_sample_pos(int64_t value, uint32_t low, uint32_t high) {
  if (value < int64_t(low)) return low;
  if (value > int64_t(high)) return high;
  return uint32_t(value);
}

std::pair<int, int> key_range(const Zone& zone) {
  auto it = zone.find(GEN_KEY_RANGE);
  if (it == zone.end()) return {0, 127};
  return {it->second & 0xff, (it->second >> 8) & 0xff};
}

std::pair<int, int> vel_range(const Zone& zone) {
  auto it = zone.find(GEN_VEL_RANGE);
  if (it == zone.end()) return {0, 127};
  return {it->second & 0xff, (it->second >> 8) & 0xff};
}

bool zone_matches(const Zone& zone, int key, int velocity) {
  auto kr = key_range(zone);
  auto vr = vel_range(zone);
  if (kr.first > kr.second || vr.first > vr.second || kr.second > 127 || vr.second > 127) {
    throw std::runtime_error("SF2 zone has invalid keyRange or velRange");
  }
  return kr.first <= key && key <= kr.second && vr.first <= velocity && velocity <= vr.second;
}

std::vector<Zone> instrument_zones(const Sf2Data& sf2, int inst_index) {
  int start = sf2.instruments.at(inst_index).bag_index;
  int end = sf2.instruments.at(inst_index + 1).bag_index;
  std::vector<Zone> zones;
  Zone global;
  for (int bag = start; bag < end; ++bag) {
    bool has_sample = false;
    Zone z = generators_for_zone_checked(sf2.instrument_generators,
                                         sf2.instrument_bags.at(bag).gen_index,
                                         sf2.instrument_bags.at(bag + 1).gen_index,
                                         GEN_SAMPLE_ID, false, has_sample);
    if (!has_sample) {
      // Only the first zone can be global. Later zones without sampleID are
      // malformed local zones and are ignored by the SF2 spec.
      if (bag == start) for (const auto& kv : z) global[kv.first] = kv.second;
    } else {
      // A local sample zone overrides any matching global generator. The merged
      // result is what Note On region selection consumes.
      Zone merged = global;
      for (const auto& kv : z) merged[kv.first] = kv.second;
      zones.push_back(merged);
    }
  }
  return zones;
}

std::vector<Zone> preset_zones(const Sf2Data& sf2, int preset_index) {
  int start = sf2.presets.at(preset_index).bag_index;
  int end = sf2.presets.at(preset_index + 1).bag_index;
  std::vector<Zone> zones;
  Zone global;
  for (int bag = start; bag < end; ++bag) {
    bool has_instrument = false;
    Zone z = generators_for_zone_checked(sf2.preset_generators,
                                         sf2.preset_bags.at(bag).gen_index,
                                         sf2.preset_bags.at(bag + 1).gen_index,
                                         GEN_INSTRUMENT, true, has_instrument);
    if (!has_instrument) {
      // Only the first zone can be global. Later zones without instrument are
      // malformed local zones and are ignored by the SF2 spec.
      if (bag == start) for (const auto& kv : z) global[kv.first] = kv.second;
    } else {
      Zone merged = global;
      for (const auto& kv : z) merged[kv.first] = kv.second;
      zones.push_back(merged);
    }
  }
  return zones;
}

std::vector<Zone> matching_zones_for_velocity(const std::vector<Zone>& zones, int key, int velocity) {
  std::vector<Zone> out;
  for (const auto& z : zones) if (zone_matches(z, key, velocity)) out.push_back(z);
  if (out.empty()) throw std::runtime_error("no SF2 zone matches key/velocity");
  return out;
}

int select_preset(const Sf2Data& sf2, int program, int bank) {
  // SF2 phdr has a terminal sentinel record, so usable excludes the final entry.
  // Try the exact bank/program first, fall back to bank 0 for files without the
  // requested bank, then General MIDI program 0 as a last musical default.
  int usable = std::max(0, int(sf2.presets.size()) - 1);
  for (int i = 0; i < usable; ++i) {
    if (sf2.presets[i].preset == program && sf2.presets[i].bank == bank) return i;
  }
  if (bank != 0) {
    for (int i = 0; i < usable; ++i) {
      if (sf2.presets[i].preset == program && sf2.presets[i].bank == 0) return i;
    }
  }
  for (int i = 0; i < usable; ++i) {
    if (sf2.presets[i].preset == 0 && sf2.presets[i].bank == 0) return i;
  }
  if (usable > 0) return 0;
  throw std::runtime_error("soundfont has no presets");
}

uint32_t phase_inc_for_key(int key, const Zone& zone, const SampleHeader& sample, int output_sample_rate) {
  // Convert SF2 pitch metadata into the RTL Q16.16 phase increment. One integer
  // phase unit is 1/65536 of a source sample frame; 0x00010000 advances by one
  // source frame per output frame.
  int effective_key = key;
  if (zone.count(GEN_KEYNUM)) {
    int forced_key = signed_amount(zone.at(GEN_KEYNUM));
    if (0 <= forced_key && forced_key <= 127) effective_key = forced_key;
  }
  int sample_root = (0 <= sample.original_pitch && sample.original_pitch <= 127) ? sample.original_pitch : 60;
  int root_key = sample_root;
  if (zone.count(GEN_OVERRIDING_ROOT_KEY)) {
    int override_key = signed_amount(zone.at(GEN_OVERRIDING_ROOT_KEY));
    if (0 <= override_key && override_key <= 127) root_key = override_key;
  }
  int scale_tuning = zone.count(GEN_SCALE_TUNING) ? signed_amount(zone.at(GEN_SCALE_TUNING)) : 100;
  scale_tuning = std::max(0, std::min(1200, scale_tuning));
  int cents = ((effective_key - root_key) * scale_tuning + sample.pitch_correction +
               signed_amount(zone.count(GEN_FINE_TUNE) ? zone.at(GEN_FINE_TUNE) : 0) +
               signed_amount(zone.count(GEN_COARSE_TUNE) ? zone.at(GEN_COARSE_TUNE) : 0) * 100);
  double rate_ratio = (double(sample.sample_rate) / double(output_sample_rate)) *
                      std::pow(2.0, double(cents) / 1200.0);
  double raw = std::round(rate_ratio * 65536.0);
  if (raw < 1.0) return 1;
  if (raw > double(std::numeric_limits<uint32_t>::max())) return std::numeric_limits<uint32_t>::max();
  return uint32_t(raw);
}

std::pair<int, int> pan_gains(const Zone& zone) {
  // The RTL has independent signed Q1.15 gains per channel. The render harness
  // uses a conservative base gain of 0x4000, applies SF2 pan as a simple linear
  // balance, then applies initial attenuation in centibels.
  int pan = signed_amount(zone.count(GEN_PAN) ? zone.at(GEN_PAN) : 0);
  pan = std::max(-500, std::min(500, pan));
  int left = int(std::round(0x4000 * double(500 - pan) / 500.0));
  int right = int(std::round(0x4000 * double(500 + pan) / 500.0));
  int atten = zone.count(GEN_INITIAL_ATTENUATION) ? signed_amount(zone.at(GEN_INITIAL_ATTENUATION)) : 0;
  if (atten) {
    double scale = std::pow(10.0, -double(atten) / 200.0);
    left = int(std::round(left * scale));
    right = int(std::round(right * scale));
  }
  return {std::max(0, std::min(0x7fff, left)), std::max(0, std::min(0x7fff, right))};
}

double timecents_to_seconds(int value, bool present, int default_timecents) {
  // SF2 envelope times use timecents: seconds = 2^(timecents / 1200). The spec's
  // very negative values represent zero-time stages, which become immediate in
  // the software envelope model.
  int tc = present ? signed_amount(value) : default_timecents;
  if (tc <= -12000) return 0.0;
  return std::min(100.0, std::pow(2.0, double(tc) / 1200.0));
}

int centibels_to_level(int cb) {
  // Sustain is attenuation from full scale in centibels. Convert that to the
  // software envelope's Q1.15 level range.
  if (cb <= 0) return kQ15Full;
  int level = int(std::round(kQ15Full * std::pow(10.0, -double(cb) / 200.0)));
  return std::max(0, std::min(kQ15Full, level));
}

int envelope_step(double seconds, int tick_samples, int sample_rate) {
  // The MCU model updates envelopes only once per control tick. Convert a stage
  // duration in seconds to a per-tick Q1.15 increment/decrement that reaches the
  // target in approximately that duration.
  int ticks = std::max(1, int(std::round(seconds * sample_rate / tick_samples)));
  return std::max(1, std::min(kQ15Full, int(std::round(double(kQ15Full) / ticks))));
}

int q4_28(double value) {
  double raw = std::round(value * 268435456.0);
  if (raw > double(std::numeric_limits<int32_t>::max())) return std::numeric_limits<int32_t>::max();
  if (raw < double(std::numeric_limits<int32_t>::min())) return std::numeric_limits<int32_t>::min();
  return int(raw);
}

void filter_coefficients(const Zone& zone, int output_sample_rate, Region& region) {
  int cutoff_cents = zone.count(GEN_INITIAL_FILTER_FC) ? signed_amount(zone.at(GEN_INITIAL_FILTER_FC)) : 13500;
  cutoff_cents = std::max(1500, std::min(13500, cutoff_cents));
  double cutoff_hz = 8.176 * std::pow(2.0, double(cutoff_cents) / 1200.0);
  double nyquist = double(output_sample_rate) * 0.5;
  if (cutoff_hz >= nyquist * 0.97) {
    region.filter_enable = false;
    region.filter_b0 = 0x10000000;
    region.filter_b1 = 0;
    region.filter_b2 = 0;
    region.filter_a1 = 0;
    region.filter_a2 = 0;
    return;
  }

  int resonance_cb = zone.count(GEN_INITIAL_FILTER_Q) ? signed_amount(zone.at(GEN_INITIAL_FILTER_Q)) : 0;
  resonance_cb = std::max(0, std::min(960, resonance_cb));
  double q = std::max(0.5, std::pow(10.0, double(resonance_cb) / 200.0) * 0.7071067811865476);
  double omega = 2.0 * 3.14159265358979323846 * cutoff_hz / double(output_sample_rate);
  double sin_w = std::sin(omega);
  double cos_w = std::cos(omega);
  double alpha = sin_w / (2.0 * q);
  double a0 = 1.0 + alpha;

  region.filter_enable = true;
  region.filter_b0 = q4_28(((1.0 - cos_w) * 0.5) / a0);
  region.filter_b1 = q4_28((1.0 - cos_w) / a0);
  region.filter_b2 = q4_28(((1.0 - cos_w) * 0.5) / a0);
  region.filter_a1 = q4_28((-2.0 * cos_w) / a0);
  region.filter_a2 = q4_28((1.0 - alpha) / a0);
}

int envelope_ticks(double seconds, int tick_samples, int sample_rate) {
  if (seconds <= 0.0) return 0;
  return std::max(1, int(std::round(seconds * sample_rate / tick_samples)));
}

void volume_envelope(const Zone& zone, int key, int tick_samples, int sample_rate, Region& region) {
  // Gather the SF2 volume-envelope generators currently modeled by the harness
  // and convert their timecents values into coarse MCU control ticks.
  double a = timecents_to_seconds(zone.count(GEN_ATTACK_VOL_ENV) ? zone.at(GEN_ATTACK_VOL_ENV) : 0,
                                  zone.count(GEN_ATTACK_VOL_ENV), -12000);
  int hold_tc = signed_amount(zone.count(GEN_HOLD_VOL_ENV) ? zone.at(GEN_HOLD_VOL_ENV) : 0);
  if (zone.count(GEN_KEYNUM_TO_VOL_ENV_HOLD)) hold_tc += signed_amount(zone.at(GEN_KEYNUM_TO_VOL_ENV_HOLD)) * (60 - key);
  double h = timecents_to_seconds(hold_tc, zone.count(GEN_HOLD_VOL_ENV) || zone.count(GEN_KEYNUM_TO_VOL_ENV_HOLD), -12000);
  int decay_tc = signed_amount(zone.count(GEN_DECAY_VOL_ENV) ? zone.at(GEN_DECAY_VOL_ENV) : 0);
  if (zone.count(GEN_KEYNUM_TO_VOL_ENV_DECAY)) decay_tc += signed_amount(zone.at(GEN_KEYNUM_TO_VOL_ENV_DECAY)) * (60 - key);
  double d = timecents_to_seconds(decay_tc, zone.count(GEN_DECAY_VOL_ENV) || zone.count(GEN_KEYNUM_TO_VOL_ENV_DECAY), -12000);
  double r = timecents_to_seconds(zone.count(GEN_RELEASE_VOL_ENV) ? zone.at(GEN_RELEASE_VOL_ENV) : 0,
                                  zone.count(GEN_RELEASE_VOL_ENV), -12000);
  double delay = timecents_to_seconds(zone.count(GEN_DELAY_VOL_ENV) ? zone.at(GEN_DELAY_VOL_ENV) : 0,
                                      zone.count(GEN_DELAY_VOL_ENV), -12000);
  region.delay_ticks = envelope_ticks(delay, tick_samples, sample_rate);
  region.hold_ticks = envelope_ticks(h, tick_samples, sample_rate);
  region.sustain_level = centibels_to_level(zone.count(GEN_SUSTAIN_VOL_ENV) ? zone.at(GEN_SUSTAIN_VOL_ENV) : 0);
  region.attack_step = envelope_step(a, tick_samples, sample_rate);
  region.decay_step = envelope_step(d, tick_samples, sample_rate);
  region.release_step = envelope_step(r, tick_samples, sample_rate);
}

Zone combine_preset_and_instrument_zones(const Zone& preset, const Zone& instrument) {
  Zone zone = instrument;
  for (const auto& kv : preset) {
    if (!additive_preset_generator(kv.first)) continue;
    auto it = zone.find(kv.first);
    zone[kv.first] = (it == zone.end()) ? kv.second : add_amount_bits(it->second, kv.second);
  }
  return zone;
}

int loop_mode_from_zone(const Zone& zone) {
  // SF2 sampleModes 1 means continuous loop and 3 means loop until note release.
  // Those map directly to the small loop-mode field implemented by the RTL.
  int sample_modes = (zone.count(GEN_SAMPLE_MODES) ? zone.at(GEN_SAMPLE_MODES) : 0) & 0x3;
  if (sample_modes == 1) return 1;
  if (sample_modes == 3) return 2;
  return 0;
}

std::pair<int, int> linked_pair(const Sf2Data& sf2, int selected) {
  // Stereo SF2 samples are normally stored as two mono sample headers linked to
  // each other. Return indexes in left,right order so build_wave_words can pack
  // the RTL memory image deterministically.
  const auto& s = sf2.samples.at(selected);
  if (s.sample_type & SAMPLE_ROM_FLAG) throw std::runtime_error("selected SF2 sample references ROM data");
  int t = sanitize_sample_type(s.sample_type);
  if (t == SAMPLE_LEFT && s.sample_link >= 0 && s.sample_link < int(sf2.samples.size())) return {selected, s.sample_link};
  if (t == SAMPLE_RIGHT && s.sample_link >= 0 && s.sample_link < int(sf2.samples.size())) return {s.sample_link, selected};
  if (t == SAMPLE_LINKED) throw std::runtime_error("SF2 linkedSample type is not directly playable by this renderer");
  return {selected, -1};
}

struct SampleWindow {
  uint32_t start = 0;
  uint32_t end = 0;
  uint32_t start_loop = 0;
  uint32_t end_loop = 0;
};

SampleWindow sample_window(const Sf2Data& sf2, const SampleHeader& h, const Zone& zone) {
  uint32_t pool = uint32_t(std::min<size_t>(sf2.smpl.size(), std::numeric_limits<uint32_t>::max()));
  uint32_t header_start = std::min<uint32_t>(h.start, pool);
  uint32_t header_end = std::min<uint32_t>(h.end, pool);
  if (header_end < header_start) header_end = header_start;

  int start_offset = sample_offset(zone, GEN_START_ADDRS_OFFSET, GEN_START_ADDRS_COARSE_OFFSET);
  int end_offset = sample_offset(zone, GEN_END_ADDRS_OFFSET, GEN_END_ADDRS_COARSE_OFFSET);
  int start_loop_offset = sample_offset(zone, GEN_STARTLOOP_ADDRS_OFFSET, GEN_STARTLOOP_ADDRS_COARSE_OFFSET);
  int end_loop_offset = sample_offset(zone, GEN_ENDLOOP_ADDRS_OFFSET, GEN_ENDLOOP_ADDRS_COARSE_OFFSET);

  SampleWindow w;
  w.start = clamp_sample_pos(int64_t(h.start) + start_offset, header_start, header_end);
  w.end = clamp_sample_pos(int64_t(h.end) + end_offset, w.start, header_end);
  w.start_loop = clamp_sample_pos(int64_t(h.start_loop) + start_loop_offset, w.start, w.end);
  w.end_loop = clamp_sample_pos(int64_t(h.end_loop) + end_loop_offset, w.start_loop, w.end);
  return w;
}

std::vector<int16_t> sample_pcm(const Sf2Data& sf2, const SampleWindow& w) {
  // SampleHeader offsets are word indexes into the smpl chunk. Clamp corrupt or
  // out-of-range values to the loaded PCM array so malformed SF2 data fails
  // softly where possible.
  return std::vector<int16_t>(sf2.smpl.begin() + w.start, sf2.smpl.begin() + w.end);
}

std::vector<int16_t> build_wave_words(const Sf2Data& sf2, int selected_sample, const Zone& zone, Region& region) {
  // Build the exact wave-memory words consumed by wavetable_core and fill the
  // region metadata that will later be committed into a voice slot. The RTL uses
  // frame indexes for length and loop points; stereo consumes two memory words
  // per frame while mono consumes one.
  auto rel = [](uint32_t value, uint32_t base) -> uint32_t { return value > base ? value - base : 0; };
  auto pair = linked_pair(sf2, selected_sample);
  const auto& left = sf2.samples.at(pair.first);
  SampleWindow left_window = sample_window(sf2, left, zone);
  std::vector<int16_t> left_pcm = sample_pcm(sf2, left_window);
  region.sample_left = left.name;

  // SF2 stereo is usually two linked mono sample headers. Convert that pair to
  // the RTL memory contract: left0, right0, left1, right1, ...
  if (pair.second >= 0 && sanitize_sample_type(sf2.samples.at(pair.second).sample_type) != SAMPLE_MONO) {
    const auto& right = sf2.samples.at(pair.second);
    SampleWindow right_window = sample_window(sf2, right, zone);
    std::vector<int16_t> right_pcm = sample_pcm(sf2, right_window);
    uint32_t frames = std::min<uint32_t>({uint32_t(left_pcm.size()), uint32_t(right_pcm.size()), 65535u});
    std::vector<int16_t> words;
    words.reserve(size_t(frames) * 2);
    for (uint32_t i = 0; i < frames; ++i) {
      words.push_back(left_pcm[i]);
      words.push_back(right_pcm[i]);
    }
    region.stereo = true;
    region.sample_right = right.name;
    region.length = frames;
    // SF2 loop end points are absolute sample positions. Convert to frame-local
    // indexes and keep the RTL contract that loop_end is exclusive.
    region.loop_start = std::min<uint32_t>({rel(left_window.start_loop, left_window.start), rel(right_window.start_loop, right_window.start), frames ? frames - 1 : 0});
    region.loop_end = std::max<uint32_t>(region.loop_start + 1, std::min<uint32_t>({rel(left_window.end_loop, left_window.start), rel(right_window.end_loop, right_window.start), frames}));
    return words;
  }

  uint32_t frames = std::min<uint32_t>(uint32_t(left_pcm.size()), 65535u);
  std::vector<int16_t> words(left_pcm.begin(), left_pcm.begin() + frames);
  region.stereo = false;
  region.length = frames;
  region.loop_start = std::min<uint32_t>(rel(left_window.start_loop, left_window.start), frames ? frames - 1 : 0);
  region.loop_end = std::max<uint32_t>(region.loop_start + 1, std::min<uint32_t>(rel(left_window.end_loop, left_window.start), frames));
  if (region.loop_start >= region.loop_end || region.loop_end > frames) {
    region.loop_start = 0;
    region.loop_end = frames;
  }
  return words;
}

}  // namespace

Sf2Data load_sf2(const std::string& path) {
  // Load the raw SF2 tables into simple vectors. The loader keeps the original
  // bag/generator indexes because zone expansion needs sentinel records and
  // adjacent bag ranges exactly as encoded in pdta.
  auto data = read_file(path);
  std::vector<uint8_t> info_payload;
  std::map<std::string, std::vector<uint8_t>> info;
  if (find_list_chunk_optional(data, "INFO", info_payload)) info = list_chunks(info_payload);
  auto sdta = list_chunks(find_list_chunk(data, "sdta"));
  auto pdta = list_chunks(find_list_chunk(data, "pdta"));
  Sf2Data sf2;
  sf2.ifil = version_chunk(info, "ifil");
  sf2.isng = text_chunk(info, "isng");
  sf2.inam = text_chunk(info, "INAM");
  if (sf2.ifil.empty()) throw std::runtime_error("SF2 INFO is missing required ifil version");
  if (sf2.isng.empty()) throw std::runtime_error("SF2 INFO is missing required isng target engine");
  if (sf2.inam.empty()) throw std::runtime_error("SF2 INFO is missing required INAM name");
  const auto& smpl = require_chunk(sdta, "smpl", 2, 0);
  auto sm24_it = sdta.find("sm24");
  bool use_sm24 = sm24_it != sdta.end() && sm24_it->second.size() >= smpl.size() / 2;
  for (size_t i = 0; i + 2 <= smpl.size(); i += 2) {
    int16_t high = int16_t(read_u16le(smpl, i));
    if (use_sm24) sf2.smpl.push_back(merge_smpl_sm24(high, sm24_it->second[i / 2]));
    else sf2.smpl.push_back(high);
  }
  sf2.presets = parse_presets(require_chunk(pdta, "phdr", 38, 2));
  sf2.preset_bags = parse_bags(require_chunk(pdta, "pbag", 4, 1));
  require_chunk(pdta, "pmod", 10, 1);
  sf2.preset_generators = parse_generators(require_chunk(pdta, "pgen", 4, 1));
  sf2.instruments = parse_instruments(require_chunk(pdta, "inst", 22, 2));
  sf2.instrument_bags = parse_bags(require_chunk(pdta, "ibag", 4, 1));
  require_chunk(pdta, "imod", 10, 1);
  sf2.instrument_generators = parse_generators(require_chunk(pdta, "igen", 4, 1));
  sf2.samples = parse_samples(require_chunk(pdta, "shdr", 46, 2));
  validate_index_tables(sf2);
  return sf2;
}

int select_instrument(const Sf2Data& sf2, const std::string& instrument) {
  // Forced-instrument mode accepts either a numeric instrument index or a
  // case-insensitive substring of the instrument name. The terminal sentinel is
  // excluded from the searchable range.
  int usable = std::max(0, int(sf2.instruments.size()) - 1);
  if (instrument.empty()) return 0;
  char* end = nullptr;
  long idx = std::strtol(instrument.c_str(), &end, 0);
  if (end && *end == 0 && idx >= 0 && idx < usable) return int(idx);
  std::string needle = instrument;
  std::transform(needle.begin(), needle.end(), needle.begin(), [](unsigned char c) { return char(std::tolower(c)); });
  for (int i = 0; i < usable; ++i) {
    std::string name = sf2.instruments[i].name;
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    if (name == needle || name.find(needle) != std::string::npos) return i;
  }
  throw std::runtime_error("instrument not found: " + instrument);
}

Region make_region_for_preset(const Sf2Data& sf2, int program, int bank, int key,
                               int velocity, int sample_rate, int tick_samples,
                               std::vector<int16_t>& memory) {
  return make_regions_for_preset(sf2, program, bank, key, velocity, sample_rate, tick_samples, memory).front();
}

std::vector<Region> make_regions_for_preset(const Sf2Data& sf2, int program, int bank, int key,
                                            int velocity, int sample_rate, int tick_samples,
                                            std::vector<int16_t>& memory) {
  // Full MIDI mode starts at the channel program/bank, selects a preset zone,
  // follows that zone to an instrument, then merges preset and instrument
  // generators. Instrument generators override preset defaults for the final
  // playable sample region.
  int preset_idx = select_preset(sf2, program, bank);
  std::vector<Region> regions;
  for (const Zone& pzone : matching_zones_for_velocity(preset_zones(sf2, preset_idx), key, velocity)) {
    int inst_idx = pzone.at(GEN_INSTRUMENT);
    for (const Zone& izone : matching_zones_for_velocity(instrument_zones(sf2, inst_idx), key, velocity)) {
      Zone zone = combine_preset_and_instrument_zones(pzone, izone);
      int sample_id = zone.at(GEN_SAMPLE_ID);
      Region r;
      r.key = key;
      r.program = program;
      r.bank = bank;
      r.preset = sf2.presets.at(preset_idx).name;
      r.instrument = sf2.instruments.at(inst_idx).name;
      r.base_addr = uint32_t(memory.size());
      auto words = build_wave_words(sf2, sample_id, zone, r);
      const auto& left = sf2.samples.at(linked_pair(sf2, sample_id).first);
      r.phase_inc = phase_inc_for_key(key, zone, left, sample_rate);
      auto gains = pan_gains(zone);
      r.gain_l = gains.first;
      r.gain_r = gains.second;
      r.loop_mode = loop_mode_from_zone(zone);
      r.effective_velocity = zone.count(GEN_VELOCITY) ? std::max(0, std::min(127, signed_amount(zone.at(GEN_VELOCITY)))) : -1;
      r.exclusive_class = zone.count(GEN_EXCLUSIVE_CLASS) ? std::max(0, std::min(127, signed_amount(zone.at(GEN_EXCLUSIVE_CLASS)))) : 0;
      volume_envelope(zone, key, tick_samples, sample_rate, r);
      filter_coefficients(zone, sample_rate, r);
      memory.insert(memory.end(), words.begin(), words.end());
      regions.push_back(r);
    }
  }
  return regions;
}

Region make_region_for_instrument(const Sf2Data& sf2, int inst_idx, int key,
                                   int velocity, int sample_rate, int tick_samples,
                                   std::vector<int16_t>& memory) {
  return make_regions_for_instrument(sf2, inst_idx, key, velocity, sample_rate, tick_samples, memory).front();
}

std::vector<Region> make_regions_for_instrument(const Sf2Data& sf2, int inst_idx, int key,
                                                int velocity, int sample_rate, int tick_samples,
                                                std::vector<int16_t>& memory) {
  // Forced-instrument mode skips preset lookup. This is useful for debugging a
  // specific SF2 instrument because MIDI program and bank messages cannot change
  // the selected sample set.
  std::vector<Region> regions;
  for (const Zone& zone : matching_zones_for_velocity(instrument_zones(sf2, inst_idx), key, velocity)) {
    int sample_id = zone.at(GEN_SAMPLE_ID);
    Region r;
    r.key = key;
    r.instrument = sf2.instruments.at(inst_idx).name;
    r.preset = r.instrument;
    r.base_addr = uint32_t(memory.size());
    auto words = build_wave_words(sf2, sample_id, zone, r);
    const auto& left = sf2.samples.at(linked_pair(sf2, sample_id).first);
    r.phase_inc = phase_inc_for_key(key, zone, left, sample_rate);
    auto gains = pan_gains(zone);
    r.gain_l = gains.first;
    r.gain_r = gains.second;
    r.loop_mode = loop_mode_from_zone(zone);
    r.effective_velocity = zone.count(GEN_VELOCITY) ? std::max(0, std::min(127, signed_amount(zone.at(GEN_VELOCITY)))) : -1;
    r.exclusive_class = zone.count(GEN_EXCLUSIVE_CLASS) ? std::max(0, std::min(127, signed_amount(zone.at(GEN_EXCLUSIVE_CLASS)))) : 0;
    volume_envelope(zone, key, tick_samples, sample_rate, r);
    filter_coefficients(zone, sample_rate, r);
    memory.insert(memory.end(), words.begin(), words.end());
    regions.push_back(r);
  }
  return regions;
}

}  // namespace render
