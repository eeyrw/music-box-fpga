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
constexpr int GEN_MOD_LFO_TO_PITCH = 5;
constexpr int GEN_VIB_LFO_TO_PITCH = 6;
constexpr int GEN_MOD_ENV_TO_PITCH = 7;
constexpr int GEN_INITIAL_FILTER_FC = 8;
constexpr int GEN_INITIAL_FILTER_Q = 9;
constexpr int GEN_MOD_LFO_TO_FILTER_FC = 10;
constexpr int GEN_MOD_ENV_TO_FILTER_FC = 11;
constexpr int GEN_END_ADDRS_COARSE_OFFSET = 12;
constexpr int GEN_MOD_LFO_TO_VOLUME = 13;
constexpr int GEN_CHORUS_EFFECTS_SEND = 15;
constexpr int GEN_REVERB_EFFECTS_SEND = 16;
constexpr int GEN_DELAY_MOD_LFO = 21;
constexpr int GEN_FREQ_MOD_LFO = 22;
constexpr int GEN_DELAY_VIB_LFO = 23;
constexpr int GEN_FREQ_VIB_LFO = 24;
constexpr int GEN_DELAY_MOD_ENV = 25;
constexpr int GEN_ATTACK_MOD_ENV = 26;
constexpr int GEN_HOLD_MOD_ENV = 27;
constexpr int GEN_DECAY_MOD_ENV = 28;
constexpr int GEN_SUSTAIN_MOD_ENV = 29;
constexpr int GEN_RELEASE_MOD_ENV = 30;
constexpr int GEN_KEYNUM_TO_MOD_ENV_HOLD = 31;
constexpr int GEN_KEYNUM_TO_MOD_ENV_DECAY = 32;
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

constexpr uint16_t MOD_SRC_NONE = 0x0000;
constexpr uint16_t MOD_SRC_NOTE_ON_VELOCITY = 0x0502;
constexpr uint16_t MOD_SRC_NOTE_ON_VELOCITY_LINEAR_NEG = 0x0102;
constexpr uint16_t MOD_SRC_CHANNEL_PRESSURE = 0x000d;
constexpr uint16_t MOD_SRC_CC1 = 0x0081;
constexpr uint16_t MOD_SRC_CC7 = 0x0587;
constexpr uint16_t MOD_SRC_CC10 = 0x028a;
constexpr uint16_t MOD_SRC_CC11 = 0x058b;
constexpr uint16_t MOD_SRC_PITCH_WHEEL = 0x020e;
constexpr uint16_t MOD_SRC_PITCH_WHEEL_SENSITIVITY = 0x0010;

constexpr uint16_t MOD_TRANS_LINEAR = 0;
constexpr uint16_t MOD_TRANS_ABSOLUTE_VALUE = 2;

using Zone = std::map<int, int>;

struct ModKey {
  uint16_t src = 0;
  uint16_t dest = 0;
  uint16_t amount_src = 0;
  uint16_t transform = 0;

  bool operator<(const ModKey& other) const {
    if (src != other.src) return src < other.src;
    if (dest != other.dest) return dest < other.dest;
    if (amount_src != other.amount_src) return amount_src < other.amount_src;
    return transform < other.transform;
  }
};

struct ArticulationZone {
  Zone generators;
  std::vector<Sf2Modulator> modulators;
};

struct ChunkRef {
  std::vector<uint8_t> data;
  size_t payload_offset = 0;
};

std::vector<int16_t> file_words_from_bytes(const std::vector<uint8_t>& data) {
  std::vector<int16_t> words;
  words.reserve((data.size() + 1) / 2);
  for (size_t i = 0; i < data.size(); i += 2) {
    uint16_t lo = data[i];
    uint16_t hi = (i + 1 < data.size()) ? uint16_t(data[i + 1]) : 0;
    words.push_back(int16_t(lo | (hi << 8)));
  }
  return words;
}

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

std::map<std::string, ChunkRef> list_chunk_refs(const std::vector<uint8_t>& data, const char wanted[4]) {
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
      std::map<std::string, ChunkRef> chunks;
      size_t child = payload + 4;
      size_t end = payload + size;
      while (child + 8 <= end) {
        std::string id(reinterpret_cast<const char*>(data.data() + child), 4);
        uint32_t child_size = read_u32le(data, child + 4);
        size_t child_payload = child + 8;
        if (child_payload + child_size > end) throw std::runtime_error("truncated LIST child chunk");
        chunks[id] = {slice(data, child_payload, child_size), child_payload};
        child = child_payload + child_size + (child_size & 1u);
      }
      return chunks;
    }
    pos = payload + size + (size & 1u);
  }
  throw std::runtime_error(std::string("missing LIST ") + std::string(wanted, 4));
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

std::vector<Sf2Modulator> parse_modulators(const std::vector<uint8_t>& c) {
  std::vector<Sf2Modulator> out;
  for (size_t i = 0; i + 10 <= c.size(); i += 10) {
    out.push_back({read_u16le(c, i), read_u16le(c, i + 2),
                   int(int16_t(read_u16le(c, i + 4))), read_u16le(c, i + 6),
                   read_u16le(c, i + 8)});
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
  if (sf2.preset_bags.back().mod_index + 1 != int(sf2.preset_modulators.size())) {
    throw std::runtime_error("SF2 pbag terminal modulator index does not match pmod size");
  }
  if (sf2.instrument_bags.back().mod_index + 1 != int(sf2.instrument_modulators.size())) {
    throw std::runtime_error("SF2 ibag terminal modulator index does not match imod size");
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
  int usable_instruments = std::max(0, int(sf2.instruments.size()) - 1);
  for (size_t bag = 0; bag + 1 < sf2.preset_bags.size(); ++bag) {
    int start = sf2.preset_bags[bag].gen_index;
    int end = sf2.preset_bags[bag + 1].gen_index;
    for (int i = start; i < end; ++i) {
      if (sf2.preset_generators.at(i).oper == GEN_INSTRUMENT &&
          sf2.preset_generators.at(i).amount >= usable_instruments) {
        throw std::runtime_error("SF2 preset generator references terminal or missing instrument");
      }
    }
  }
  for (size_t bag = 0; bag + 1 < sf2.instrument_bags.size(); ++bag) {
    int start = sf2.instrument_bags[bag].gen_index;
    int end = sf2.instrument_bags[bag + 1].gen_index;
    for (int i = start; i < end; ++i) {
      if (sf2.instrument_generators.at(i).oper == GEN_SAMPLE_ID &&
          sf2.instrument_generators.at(i).amount >= usable_samples) {
        throw std::runtime_error("SF2 instrument generator references terminal or missing sample");
      }
    }
  }

  for (int i = 0; i < usable_samples; ++i) {
    const auto& s = sf2.samples[i];
    if (s.end < s.start) throw std::runtime_error("SF2 sample header has invalid sample bounds");
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

ModKey mod_key(const Sf2Modulator& mod) {
  return {mod.src, mod.dest, mod.amount_src, mod.transform};
}

bool valid_mod_source(uint16_t source, bool amount_source) {
  if (source == MOD_SRC_NONE) return true;
  int type = (source >> 10) & 0x3f;
  if (type > 3) return false;
  bool cc = (source & 0x0080u) != 0;
  int index = source & 0x007fu;
  if (cc) {
    if (index == 0 || index == 6 || index == 32 || index == 38 || (98 <= index && index <= 101) ||
        120 <= index) {
      return false;
    }
    return true;
  }
  if (index == 127) return !amount_source;
  return index == 0 || index == 2 || index == 3 || index == 10 || index == 13 ||
         index == 14 || index == 16;
}

bool valid_mod_destination(uint16_t dest, size_t mod_count) {
  if (dest & 0x8000u) return (dest & 0x7fffu) < mod_count;
  return dest == 0 || dest == GEN_MOD_LFO_TO_PITCH || dest == GEN_VIB_LFO_TO_PITCH ||
         dest == GEN_MOD_ENV_TO_PITCH || dest == GEN_INITIAL_FILTER_FC ||
         dest == GEN_INITIAL_FILTER_Q || dest == GEN_MOD_LFO_TO_FILTER_FC ||
         dest == GEN_MOD_ENV_TO_FILTER_FC || dest == GEN_MOD_LFO_TO_VOLUME ||
         dest == GEN_CHORUS_EFFECTS_SEND || dest == GEN_REVERB_EFFECTS_SEND ||
         dest == GEN_PAN || dest == GEN_INITIAL_ATTENUATION ||
         dest == GEN_COARSE_TUNE || dest == GEN_FINE_TUNE;
}

bool valid_transform(uint16_t transform) {
  return transform == MOD_TRANS_LINEAR || transform == MOD_TRANS_ABSOLUTE_VALUE;
}

std::vector<Sf2Modulator> default_modulators() {
  return {
    {MOD_SRC_NOTE_ON_VELOCITY, GEN_INITIAL_ATTENUATION, 960, MOD_SRC_NONE, MOD_TRANS_LINEAR},
    {MOD_SRC_NOTE_ON_VELOCITY_LINEAR_NEG, GEN_INITIAL_FILTER_FC, -2400, MOD_SRC_NONE, MOD_TRANS_LINEAR},
    {MOD_SRC_CHANNEL_PRESSURE, GEN_VIB_LFO_TO_PITCH, 50, MOD_SRC_NONE, MOD_TRANS_LINEAR},
    {MOD_SRC_CC1, GEN_VIB_LFO_TO_PITCH, 50, MOD_SRC_NONE, MOD_TRANS_LINEAR},
    {MOD_SRC_CC7, GEN_INITIAL_ATTENUATION, 960, MOD_SRC_NONE, MOD_TRANS_LINEAR},
    {MOD_SRC_CC10, GEN_PAN, 1000, MOD_SRC_NONE, MOD_TRANS_LINEAR},
    {MOD_SRC_CC11, GEN_INITIAL_ATTENUATION, 960, MOD_SRC_NONE, MOD_TRANS_LINEAR},
    {MOD_SRC_PITCH_WHEEL, 0, 12700, MOD_SRC_PITCH_WHEEL_SENSITIVITY, MOD_TRANS_LINEAR},
  };
}

std::vector<Sf2Modulator> modulators_for_zone_checked(const std::vector<Sf2Modulator>& mods,
                                                      int start, int end) {
  std::map<ModKey, Sf2Modulator> by_key;
  size_t count = size_t(std::max(0, end - start));
  for (int i = start; i < end; ++i) {
    const auto& mod = mods.at(i);
    if (mod.src == 0 && mod.dest == 0 && mod.amount == 0 &&
        mod.amount_src == 0 && mod.transform == 0) {
      continue;
    }
    if (!valid_mod_source(mod.src, false) || !valid_mod_source(mod.amount_src, true) ||
        !valid_mod_destination(mod.dest, count) || !valid_transform(mod.transform)) {
      continue;
    }
    if (mod.amount_src == 127) continue;
    by_key[mod_key(mod)] = mod;
  }
  std::vector<Sf2Modulator> out;
  for (const auto& kv : by_key) out.push_back(kv.second);
  return out;
}

std::map<ModKey, Sf2Modulator> modulator_map(const std::vector<Sf2Modulator>& mods) {
  std::map<ModKey, Sf2Modulator> out;
  for (const auto& mod : mods) out[mod_key(mod)] = mod;
  return out;
}

std::vector<Sf2Modulator> modulators_from_map(const std::map<ModKey, Sf2Modulator>& mods) {
  std::vector<Sf2Modulator> out;
  for (const auto& kv : mods) out.push_back(kv.second);
  return out;
}

void replace_modulators(std::map<ModKey, Sf2Modulator>& base,
                        const std::vector<Sf2Modulator>& overlay) {
  for (const auto& mod : overlay) base[mod_key(mod)] = mod;
}

void add_modulators(std::map<ModKey, Sf2Modulator>& base,
                    const std::vector<Sf2Modulator>& overlay) {
  for (const auto& mod : overlay) {
    auto key = mod_key(mod);
    auto it = base.find(key);
    if (it == base.end()) {
      base[key] = mod;
    } else {
      int amount = it->second.amount + mod.amount;
      it->second.amount = std::max(-32768, std::min(32767, amount));
    }
  }
}

int add_amount_bits(int a, int b) {
  int sum = signed_amount(a) + signed_amount(b);
  sum = std::max(-32768, std::min(32767, sum));
  return int(uint16_t(int16_t(sum)));
}

bool default_generator_amount(int oper, int& amount) {
  switch (oper) {
    case GEN_INITIAL_FILTER_FC:
      amount = 13500;
      return true;
    case GEN_DELAY_MOD_LFO:
    case GEN_DELAY_VIB_LFO:
    case GEN_DELAY_MOD_ENV:
    case GEN_ATTACK_MOD_ENV:
    case GEN_HOLD_MOD_ENV:
    case GEN_DECAY_MOD_ENV:
    case GEN_RELEASE_MOD_ENV:
    case GEN_DELAY_VOL_ENV:
    case GEN_ATTACK_VOL_ENV:
    case GEN_HOLD_VOL_ENV:
    case GEN_DECAY_VOL_ENV:
    case GEN_RELEASE_VOL_ENV:
      amount = int(uint16_t(int16_t(-12000)));
      return true;
    case GEN_SCALE_TUNING:
      amount = 100;
      return true;
    case GEN_MOD_LFO_TO_PITCH:
    case GEN_VIB_LFO_TO_PITCH:
    case GEN_MOD_ENV_TO_PITCH:
    case GEN_INITIAL_FILTER_Q:
    case GEN_MOD_LFO_TO_FILTER_FC:
    case GEN_MOD_ENV_TO_FILTER_FC:
    case GEN_MOD_LFO_TO_VOLUME:
    case GEN_PAN:
    case GEN_FREQ_MOD_LFO:
    case GEN_FREQ_VIB_LFO:
    case GEN_SUSTAIN_MOD_ENV:
    case GEN_KEYNUM_TO_MOD_ENV_HOLD:
    case GEN_KEYNUM_TO_MOD_ENV_DECAY:
    case GEN_SUSTAIN_VOL_ENV:
    case GEN_KEYNUM_TO_VOL_ENV_HOLD:
    case GEN_KEYNUM_TO_VOL_ENV_DECAY:
    case GEN_INITIAL_ATTENUATION:
    case GEN_COARSE_TUNE:
    case GEN_FINE_TUNE:
      amount = 0;
      return true;
    default:
      return false;
  }
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

std::vector<ArticulationZone> instrument_zones(const Sf2Data& sf2, int inst_index) {
  int start = sf2.instruments.at(inst_index).bag_index;
  int end = sf2.instruments.at(inst_index + 1).bag_index;
  std::vector<ArticulationZone> zones;
  Zone global;
  std::vector<Sf2Modulator> global_mods;
  for (int bag = start; bag < end; ++bag) {
    bool has_sample = false;
    Zone z = generators_for_zone_checked(sf2.instrument_generators,
                                         sf2.instrument_bags.at(bag).gen_index,
                                         sf2.instrument_bags.at(bag + 1).gen_index,
                                         GEN_SAMPLE_ID, false, has_sample);
    std::vector<Sf2Modulator> mods = modulators_for_zone_checked(sf2.instrument_modulators,
                                                                 sf2.instrument_bags.at(bag).mod_index,
                                                                 sf2.instrument_bags.at(bag + 1).mod_index);
    if (!has_sample) {
      // Only the first zone can be global. Later zones without sampleID are
      // malformed local zones and are ignored by the SF2 spec.
      if (bag == start) {
        for (const auto& kv : z) global[kv.first] = kv.second;
        global_mods = mods;
      }
    } else {
      // A local sample zone overrides any matching global generator. The merged
      // result is what Note On region selection consumes.
      Zone merged = global;
      for (const auto& kv : z) merged[kv.first] = kv.second;
      auto merged_mods = modulator_map(default_modulators());
      replace_modulators(merged_mods, global_mods);
      replace_modulators(merged_mods, mods);
      zones.push_back({merged, modulators_from_map(merged_mods)});
    }
  }
  return zones;
}

std::vector<ArticulationZone> preset_zones(const Sf2Data& sf2, int preset_index) {
  int start = sf2.presets.at(preset_index).bag_index;
  int end = sf2.presets.at(preset_index + 1).bag_index;
  std::vector<ArticulationZone> zones;
  Zone global;
  std::vector<Sf2Modulator> global_mods;
  for (int bag = start; bag < end; ++bag) {
    bool has_instrument = false;
    Zone z = generators_for_zone_checked(sf2.preset_generators,
                                         sf2.preset_bags.at(bag).gen_index,
                                         sf2.preset_bags.at(bag + 1).gen_index,
                                         GEN_INSTRUMENT, true, has_instrument);
    std::vector<Sf2Modulator> mods = modulators_for_zone_checked(sf2.preset_modulators,
                                                                 sf2.preset_bags.at(bag).mod_index,
                                                                 sf2.preset_bags.at(bag + 1).mod_index);
    if (!has_instrument) {
      // Only the first zone can be global. Later zones without instrument are
      // malformed local zones and are ignored by the SF2 spec.
      if (bag == start) {
        for (const auto& kv : z) global[kv.first] = kv.second;
        global_mods = mods;
      }
    } else {
      Zone merged = global;
      for (const auto& kv : z) merged[kv.first] = kv.second;
      auto merged_mods = modulator_map(global_mods);
      replace_modulators(merged_mods, mods);
      zones.push_back({merged, modulators_from_map(merged_mods)});
    }
  }
  return zones;
}

std::vector<ArticulationZone> matching_zones_for_velocity(const std::vector<ArticulationZone>& zones,
                                                          int key, int velocity) {
  std::vector<ArticulationZone> out;
  for (const auto& z : zones) if (zone_matches(z.generators, key, velocity)) out.push_back(z);
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
  // Convert SF2 pitch metadata into the RTL Q24.8 phase increment. One integer
  // phase unit is 1/256 of a source sample frame; 0x00000100 advances by one
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
  double raw = std::round(rate_ratio * double(kPhaseFracScale));
  if (raw < 1.0) return 1;
  if (raw > double(std::numeric_limits<uint32_t>::max())) return std::numeric_limits<uint32_t>::max();
  return uint32_t(raw);
}

void pitch_modulation_generators(const Zone& zone, Region& region) {
  region.mod_lfo_to_pitch = zone.count(GEN_MOD_LFO_TO_PITCH) ? signed_amount(zone.at(GEN_MOD_LFO_TO_PITCH)) : 0;
  region.vib_lfo_to_pitch = zone.count(GEN_VIB_LFO_TO_PITCH) ? signed_amount(zone.at(GEN_VIB_LFO_TO_PITCH)) : 0;
  region.mod_env_to_pitch = zone.count(GEN_MOD_ENV_TO_PITCH) ? signed_amount(zone.at(GEN_MOD_ENV_TO_PITCH)) : 0;
}

void gain_config(const Zone& zone, Region& region) {
  int pan = signed_amount(zone.count(GEN_PAN) ? zone.at(GEN_PAN) : 0);
  region.pan = std::max(-500, std::min(500, pan));
  int atten = zone.count(GEN_INITIAL_ATTENUATION) ? signed_amount(zone.at(GEN_INITIAL_ATTENUATION)) : 0;
  atten = std::max(0, std::min(1440, atten));
  int gain = 0x4000;
  if (atten) gain = int(std::round(double(gain) * std::pow(10.0, -double(atten) / 200.0)));
  region.base_gain = std::max(0, std::min(0x7fff, gain));
  int left = int(std::round(double(region.base_gain) * double(500 - region.pan) / 500.0));
  int right = int(std::round(double(region.base_gain) * double(500 + region.pan) / 500.0));
  region.gain_l = std::max(0, std::min(0x7fff, left));
  region.gain_r = std::max(0, std::min(0x7fff, right));
}

double timecents_to_seconds(int value, bool present, int default_timecents) {
  // SF2 envelope times use timecents: seconds = 2^(timecents / 1200). The spec's
  // most negative value conventionally represents an immediate stage.
  int tc = present ? signed_amount(value) : default_timecents;
  if (tc <= -32768) return 0.0;
  return std::min(100.0, std::pow(2.0, double(tc) / 1200.0));
}

int centibels_to_level(int cb) {
  // Sustain is attenuation from full scale in centibels. Convert that to the
  // software envelope's Q1.15 level range.
  if (cb <= 0) return kQ15Full;
  int level = int(std::round(kQ15Full * std::pow(10.0, -double(cb) / 200.0)));
  return std::max(0, std::min(kQ15Full, level));
}

int percent_drop_to_level(int tenth_percent_drop) {
  int drop = std::max(0, std::min(1000, tenth_percent_drop));
  int level = int(std::round(kQ15Full * double(1000 - drop) / 1000.0));
  return std::max(0, std::min(kQ15Full, level));
}

int envelope_step(double seconds, int tick_samples, int sample_rate) {
  // The MCU model updates envelopes only once per control tick. Convert a stage
  // duration in seconds to a per-tick Q1.15 increment/decrement that reaches the
  // target in approximately that duration.
  int ticks = std::max(1, int(std::round(seconds * sample_rate / tick_samples)));
  return std::max(1, std::min(kQ15Full, int(std::round(double(kQ15Full) / ticks))));
}

int envelope_tick_count(double seconds, int tick_samples, int sample_rate) {
  if (seconds <= 0.0) return 1;
  return std::max(1, int(std::round(seconds * sample_rate / tick_samples)));
}

int scaled_envelope_tick_count(double seconds, double fraction, int tick_samples, int sample_rate) {
  if (fraction <= 0.0) return 1;
  return envelope_tick_count(seconds * std::min(1.0, fraction), tick_samples, sample_rate);
}

int q2_14(double value) {
  double raw = std::round(value * 16384.0);
  if (raw > double(std::numeric_limits<int16_t>::max())) return std::numeric_limits<int16_t>::max();
  if (raw < double(std::numeric_limits<int16_t>::min())) return std::numeric_limits<int16_t>::min();
  return int(raw);
}

FilterConfig filter_config_for(int cutoff_cents, int resonance_cb, int output_sample_rate) {
  cutoff_cents = std::max(1500, std::min(13500, cutoff_cents));
  double cutoff_hz = 8.176 * std::pow(2.0, double(cutoff_cents) / 1200.0);
  double nyquist = double(output_sample_rate) * 0.5;
  FilterConfig filter;
  if (cutoff_hz >= nyquist * 0.97) {
    return filter;
  }

  resonance_cb = std::max(0, std::min(960, resonance_cb));
  double q = std::max(0.5, std::pow(10.0, double(resonance_cb) / 200.0) * 0.7071067811865476);
  double omega = 2.0 * 3.14159265358979323846 * cutoff_hz / double(output_sample_rate);
  double sin_w = std::sin(omega);
  double cos_w = std::cos(omega);
  double alpha = sin_w / (2.0 * q);
  double a0 = 1.0 + alpha;

  filter.enable = true;
  filter.b0 = q2_14(((1.0 - cos_w) * 0.5) / a0);
  filter.b1 = q2_14((1.0 - cos_w) / a0);
  filter.b2 = q2_14(((1.0 - cos_w) * 0.5) / a0);
  filter.a1 = q2_14((-2.0 * cos_w) / a0);
  filter.a2 = q2_14((1.0 - alpha) / a0);
  return filter;
}

void filter_coefficients(const Zone& zone, int output_sample_rate, Region& region) {
  region.initial_filter_fc = zone.count(GEN_INITIAL_FILTER_FC) ? signed_amount(zone.at(GEN_INITIAL_FILTER_FC)) : 13500;
  region.initial_filter_q = zone.count(GEN_INITIAL_FILTER_Q) ? signed_amount(zone.at(GEN_INITIAL_FILTER_Q)) : 0;
  FilterConfig filter = filter_config_for(region.initial_filter_fc, region.initial_filter_q, output_sample_rate);
  region.filter_enable = filter.enable;
  region.filter_b0 = filter.b0;
  region.filter_b1 = filter.b1;
  region.filter_b2 = filter.b2;
  region.filter_a1 = filter.a1;
  region.filter_a2 = filter.a2;
}

int envelope_ticks(double seconds, int tick_samples, int sample_rate) {
  if (seconds <= 0.0) return 0;
  return std::max(0, int(std::round(seconds * sample_rate / tick_samples)));
}

uint32_t lfo_step(int freq_cents, int tick_samples, int sample_rate) {
  double hz = 8.176 * std::pow(2.0, double(signed_amount(freq_cents)) / 1200.0);
  double cycles_per_tick = hz * double(tick_samples) / double(sample_rate);
  double raw = std::round(cycles_per_tick * 65536.0);
  if (raw <= 0.0) return 0;
  if (raw > double(UINT32_MAX)) return UINT32_MAX;
  return uint32_t(raw);
}

void modulation_generators(const Zone& zone, int key, int tick_samples, int sample_rate, Region& region) {
  region.mod_lfo_delay_ticks = envelope_ticks(timecents_to_seconds(zone.count(GEN_DELAY_MOD_LFO) ? zone.at(GEN_DELAY_MOD_LFO) : 0,
                                                              zone.count(GEN_DELAY_MOD_LFO), -12000),
                                             tick_samples, sample_rate);
  region.vib_lfo_delay_ticks = envelope_ticks(timecents_to_seconds(zone.count(GEN_DELAY_VIB_LFO) ? zone.at(GEN_DELAY_VIB_LFO) : 0,
                                                              zone.count(GEN_DELAY_VIB_LFO), -12000),
                                             tick_samples, sample_rate);
  region.mod_lfo_step = lfo_step(zone.count(GEN_FREQ_MOD_LFO) ? zone.at(GEN_FREQ_MOD_LFO) : 0,
                                 tick_samples, sample_rate);
  region.vib_lfo_step = lfo_step(zone.count(GEN_FREQ_VIB_LFO) ? zone.at(GEN_FREQ_VIB_LFO) : 0,
                                 tick_samples, sample_rate);
  pitch_modulation_generators(zone, region);
  region.mod_lfo_to_filter_fc = zone.count(GEN_MOD_LFO_TO_FILTER_FC) ? signed_amount(zone.at(GEN_MOD_LFO_TO_FILTER_FC)) : 0;
  region.mod_env_to_filter_fc = zone.count(GEN_MOD_ENV_TO_FILTER_FC) ? signed_amount(zone.at(GEN_MOD_ENV_TO_FILTER_FC)) : 0;
  region.mod_lfo_to_volume = zone.count(GEN_MOD_LFO_TO_VOLUME) ? signed_amount(zone.at(GEN_MOD_LFO_TO_VOLUME)) : 0;

  double a = timecents_to_seconds(zone.count(GEN_ATTACK_MOD_ENV) ? zone.at(GEN_ATTACK_MOD_ENV) : 0,
                                  zone.count(GEN_ATTACK_MOD_ENV), -12000);
  int hold_tc = signed_amount(zone.count(GEN_HOLD_MOD_ENV) ? zone.at(GEN_HOLD_MOD_ENV) : 0);
  if (zone.count(GEN_KEYNUM_TO_MOD_ENV_HOLD)) hold_tc += signed_amount(zone.at(GEN_KEYNUM_TO_MOD_ENV_HOLD)) * (60 - key);
  double h = timecents_to_seconds(hold_tc, zone.count(GEN_HOLD_MOD_ENV) || zone.count(GEN_KEYNUM_TO_MOD_ENV_HOLD), -12000);
  int decay_tc = signed_amount(zone.count(GEN_DECAY_MOD_ENV) ? zone.at(GEN_DECAY_MOD_ENV) : 0);
  if (zone.count(GEN_KEYNUM_TO_MOD_ENV_DECAY)) decay_tc += signed_amount(zone.at(GEN_KEYNUM_TO_MOD_ENV_DECAY)) * (60 - key);
  double d = timecents_to_seconds(decay_tc, zone.count(GEN_DECAY_MOD_ENV) || zone.count(GEN_KEYNUM_TO_MOD_ENV_DECAY), -12000);
  double r = timecents_to_seconds(zone.count(GEN_RELEASE_MOD_ENV) ? zone.at(GEN_RELEASE_MOD_ENV) : 0,
                                  zone.count(GEN_RELEASE_MOD_ENV), -12000);
  double delay = timecents_to_seconds(zone.count(GEN_DELAY_MOD_ENV) ? zone.at(GEN_DELAY_MOD_ENV) : 0,
                                      zone.count(GEN_DELAY_MOD_ENV), -12000);
  region.mod_env_delay_ticks = envelope_ticks(delay, tick_samples, sample_rate);
  region.mod_env_hold_ticks = envelope_ticks(h, tick_samples, sample_rate);
  int mod_sustain_drop = signed_amount(zone.count(GEN_SUSTAIN_MOD_ENV) ? zone.at(GEN_SUSTAIN_MOD_ENV) : 0);
  mod_sustain_drop = std::max(0, std::min(1000, mod_sustain_drop));
  region.mod_env_sustain_level = percent_drop_to_level(mod_sustain_drop);
  region.mod_env_attack_ticks = envelope_tick_count(a, tick_samples, sample_rate);
  region.mod_env_decay_ticks = scaled_envelope_tick_count(d, double(mod_sustain_drop) / 1000.0,
                                                          tick_samples, sample_rate);
  region.mod_env_release_ticks = envelope_tick_count(r, tick_samples, sample_rate);
  region.mod_env_attack_step = envelope_step(a, tick_samples, sample_rate);
  region.mod_env_decay_step = envelope_step(d, tick_samples, sample_rate);
  region.mod_env_release_step = envelope_step(r, tick_samples, sample_rate);
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
  int vol_sustain_cb = signed_amount(zone.count(GEN_SUSTAIN_VOL_ENV) ? zone.at(GEN_SUSTAIN_VOL_ENV) : 0);
  vol_sustain_cb = std::max(0, std::min(1440, vol_sustain_cb));
  region.sustain_level = centibels_to_level(vol_sustain_cb);
  region.attack_ticks = envelope_tick_count(a, tick_samples, sample_rate);
  region.decay_ticks = scaled_envelope_tick_count(d, double(std::min(1000, vol_sustain_cb)) / 1000.0,
                                                  tick_samples, sample_rate);
  region.release_ticks = envelope_tick_count(r, tick_samples, sample_rate);
  region.attack_step = envelope_step(a, tick_samples, sample_rate);
  region.decay_step = envelope_step(d, tick_samples, sample_rate);
  region.release_step = envelope_step(r, tick_samples, sample_rate);
}

Zone combine_preset_and_instrument_zones(const Zone& preset, const Zone& instrument) {
  Zone zone = instrument;
  for (const auto& kv : preset) {
    if (!additive_preset_generator(kv.first)) continue;
    auto it = zone.find(kv.first);
    if (it != zone.end()) {
      zone[kv.first] = add_amount_bits(it->second, kv.second);
    } else {
      int default_amount = 0;
      zone[kv.first] = default_generator_amount(kv.first, default_amount)
                           ? add_amount_bits(default_amount, kv.second)
                           : kv.second;
    }
  }
  return zone;
}

std::vector<Sf2Modulator> combine_preset_and_instrument_modulators(
    const std::vector<Sf2Modulator>& preset, const std::vector<Sf2Modulator>& instrument) {
  auto mods = modulator_map(instrument);
  add_modulators(mods, preset);
  return modulators_from_map(mods);
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
  // each other. Return indexes in left,right order only when the target is the
  // opposite side and links back to the selected header; stale or non-reciprocal
  // links are common enough in loose SoundFonts that treating them as mono is
  // safer than pairing unrelated sample data.
  const auto& s = sf2.samples.at(selected);
  if (s.sample_type & SAMPLE_ROM_FLAG) throw std::runtime_error("selected SF2 sample references ROM data");
  int t = sanitize_sample_type(s.sample_type);
  if ((t == SAMPLE_LEFT || t == SAMPLE_RIGHT) && s.sample_link >= 0 && s.sample_link < int(sf2.samples.size())) {
    const auto& other = sf2.samples.at(s.sample_link);
    if (other.sample_type & SAMPLE_ROM_FLAG) throw std::runtime_error("linked SF2 sample references ROM data");
    int other_type = sanitize_sample_type(other.sample_type);
    bool reciprocal = other.sample_link == selected;
    if (t == SAMPLE_LEFT && other_type == SAMPLE_RIGHT && reciprocal) return {selected, s.sample_link};
    if (t == SAMPLE_RIGHT && other_type == SAMPLE_LEFT && reciprocal) return {s.sample_link, selected};
  }
  if (t == SAMPLE_LINKED) throw std::runtime_error("SF2 linkedSample type is not directly playable by this renderer");
  return {selected, -1};
}

const ArticulationZone* find_zone_for_sample(const std::vector<ArticulationZone>& zones, int sample_id) {
  for (const auto& zone : zones) {
    auto it = zone.generators.find(GEN_SAMPLE_ID);
    if (it != zone.generators.end() && it->second == sample_id) return &zone;
  }
  return nullptr;
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

uint32_t relative_sample_pos(uint32_t value, uint32_t base) {
  return value > base ? value - base : 0;
}

void fill_region_addresses_for_sample_pair(const Sf2Data& sf2, int left_sample_id, int right_sample_id,
                                           const Zone& left_zone, const Zone& right_zone, Region& region) {
  // The external wave memory is a word-addressed image of the complete SF2 file.
  // SampleHeader positions are word indexes into smpl, so add the smpl payload's
  // file word offset and keep loop points relative to the selected playback window.
  const auto& left = sf2.samples.at(left_sample_id);
  const auto& right = sf2.samples.at(right_sample_id);
  if ((left.sample_type & SAMPLE_ROM_FLAG) || (right.sample_type & SAMPLE_ROM_FLAG)) {
    throw std::runtime_error("selected SF2 sample references ROM data");
  }
  SampleWindow left_window = sample_window(sf2, left, left_zone);
  SampleWindow right_window = sample_window(sf2, right, right_zone);
  uint32_t frames_l = std::min<uint32_t>(left_window.end - left_window.start, kPhaseFrameMask);
  uint32_t frames_r = std::min<uint32_t>(right_window.end - right_window.start, kPhaseFrameMask);
  region.stereo = true;
  region.sample_left = left.name;
  region.sample_right = right.name;
  region.base_addr = sf2.smpl_word_offset + left_window.start;
  region.base_addr_r = sf2.smpl_word_offset + right_window.start;
  region.length = frames_l;
  region.length_r = frames_r;
  region.loop_start = std::min<uint32_t>(relative_sample_pos(left_window.start_loop, left_window.start),
                                         frames_l ? frames_l - 1 : 0);
  region.loop_start_r = std::min<uint32_t>(relative_sample_pos(right_window.start_loop, right_window.start),
                                           frames_r ? frames_r - 1 : 0);
  region.loop_end = std::max<uint32_t>(region.loop_start + 1,
                                       std::min<uint32_t>(relative_sample_pos(left_window.end_loop, left_window.start),
                                                          frames_l));
  region.loop_end_r = std::max<uint32_t>(region.loop_start_r + 1,
                                         std::min<uint32_t>(relative_sample_pos(right_window.end_loop, right_window.start),
                                                            frames_r));
}

void fill_region_addresses(const Sf2Data& sf2, int selected_sample, const Zone& left_zone,
                           const Zone& right_zone, Region& region) {
  auto pair = linked_pair(sf2, selected_sample);
  const auto& left = sf2.samples.at(pair.first);
  SampleWindow left_window = sample_window(sf2, left, left_zone);
  region.sample_left = left.name;
  region.base_addr = sf2.smpl_word_offset + left_window.start;

  if (pair.second >= 0 && sanitize_sample_type(sf2.samples.at(pair.second).sample_type) != SAMPLE_MONO) {
    fill_region_addresses_for_sample_pair(sf2, pair.first, pair.second, left_zone, right_zone, region);
    return;
  }

  uint32_t frames = std::min<uint32_t>(left_window.end - left_window.start, kPhaseFrameMask);
  region.stereo = false;
  region.base_addr_r = region.base_addr;
  region.length = frames;
  region.length_r = frames;
  region.loop_start = std::min<uint32_t>(relative_sample_pos(left_window.start_loop, left_window.start), frames ? frames - 1 : 0);
  region.loop_start_r = region.loop_start;
  region.loop_end = std::max<uint32_t>(region.loop_start + 1,
                                       std::min<uint32_t>(relative_sample_pos(left_window.end_loop, left_window.start),
                                                          frames));
  region.loop_end_r = region.loop_end;
  if (region.loop_start >= region.loop_end || region.loop_end > frames) {
    region.loop_start = 0;
    region.loop_end = frames;
    region.loop_start_r = 0;
    region.loop_end_r = frames;
  }
}

int zone_sample_id(const ArticulationZone& zone) {
  return zone.generators.at(GEN_SAMPLE_ID);
}

int zone_pan(const ArticulationZone& zone) {
  return signed_amount(zone.generators.count(GEN_PAN) ? zone.generators.at(GEN_PAN) : 0);
}

bool same_range_generators(const Zone& a, const Zone& b) {
  return key_range(a) == key_range(b) && vel_range(a) == vel_range(b);
}

bool compatible_unlinked_stereo_pair(const Sf2Data& sf2, const ArticulationZone& left_zone,
                                     const ArticulationZone& right_zone) {
  int left_id = zone_sample_id(left_zone);
  int right_id = zone_sample_id(right_zone);
  if (left_id == right_id) return false;
  const auto& left = sf2.samples.at(left_id);
  const auto& right = sf2.samples.at(right_id);
  if ((left.sample_type & SAMPLE_ROM_FLAG) || (right.sample_type & SAMPLE_ROM_FLAG)) {
    throw std::runtime_error("selected SF2 sample references ROM data");
  }
  if (left.sample_rate != right.sample_rate || left.original_pitch != right.original_pitch ||
      left.pitch_correction != right.pitch_correction) {
    return false;
  }
  if (!same_range_generators(left_zone.generators, right_zone.generators)) return false;

  SampleWindow left_window = sample_window(sf2, left, left_zone.generators);
  SampleWindow right_window = sample_window(sf2, right, right_zone.generators);
  uint32_t frames_l = left_window.end - left_window.start;
  uint32_t frames_r = right_window.end - right_window.start;
  return frames_l != 0 && frames_r != 0;
}

int unlinked_stereo_partner_index(const Sf2Data& sf2, const std::vector<ArticulationZone>& zones,
                                  size_t selected) {
  int selected_pan = zone_pan(zones.at(selected));
  if (selected_pan > -450) return -1;
  for (size_t i = selected + 1; i < zones.size(); ++i) {
    if (zone_pan(zones.at(i)) < 450) continue;
    if (compatible_unlinked_stereo_pair(sf2, zones.at(selected), zones.at(i))) return int(i);
  }
  return -1;
}

bool selected_unlinked_right_with_matching_left(const Sf2Data& sf2, const std::vector<ArticulationZone>& zones,
                                                size_t selected) {
  int selected_pan = zone_pan(zones.at(selected));
  if (selected_pan < 450) return false;
  for (size_t i = 0; i < selected; ++i) {
    if (zone_pan(zones.at(i)) > -450) continue;
    if (compatible_unlinked_stereo_pair(sf2, zones.at(i), zones.at(selected))) return true;
  }
  return false;
}

bool selected_right_with_matching_left_zone(const Sf2Data& sf2, int sample_id,
                                            const std::vector<ArticulationZone>& zones) {
  int sample_type = sanitize_sample_type(sf2.samples.at(sample_id).sample_type);
  if (sample_type != SAMPLE_RIGHT) return false;
  auto pair = linked_pair(sf2, sample_id);
  return pair.second >= 0 && pair.first != sample_id && find_zone_for_sample(zones, pair.first) != nullptr;
}

void linked_stereo_zone_selection(const Sf2Data& sf2, int sample_id,
                                  const ArticulationZone& selected_zone,
                                  const std::vector<ArticulationZone>& zones,
                                  const ArticulationZone*& left_zone,
                                  const ArticulationZone*& right_zone,
                                  const ArticulationZone*& pitch_zone,
                                  int& pitch_sample_id) {
  auto pair = linked_pair(sf2, sample_id);
  left_zone = &selected_zone;
  right_zone = &selected_zone;
  pitch_zone = &selected_zone;
  pitch_sample_id = pair.first;
  if (pair.second < 0) return;

  const ArticulationZone* matching_left = find_zone_for_sample(zones, pair.first);
  const ArticulationZone* matching_right = find_zone_for_sample(zones, pair.second);
  if (matching_left) left_zone = matching_left;
  if (matching_right) {
    right_zone = matching_right;
    pitch_zone = matching_right;
  }
  pitch_sample_id = pair.second;
}

bool pitch_destination(uint16_t dest) {
  return dest == 0 || dest == GEN_MOD_LFO_TO_PITCH || dest == GEN_VIB_LFO_TO_PITCH ||
         dest == GEN_MOD_ENV_TO_PITCH;
}

std::vector<Sf2Modulator> stereo_runtime_modulators(const ArticulationZone& selected,
                                                    const ArticulationZone& pitch_zone) {
  auto mods = modulator_map(selected.modulators);
  for (auto it = mods.begin(); it != mods.end();) {
    if (pitch_destination(it->second.dest)) it = mods.erase(it);
    else ++it;
  }
  for (const auto& mod : pitch_zone.modulators) {
    if (pitch_destination(mod.dest)) mods[mod_key(mod)] = mod;
  }
  return modulators_from_map(mods);
}

void center_hard_panned_stereo_gain(Region& region) {
  region.pan = 0;
  region.gain_l = region.base_gain;
  region.gain_r = region.base_gain;
}

}  // namespace

Sf2Data load_sf2(const std::string& path) {
  // Load the raw SF2 tables into simple vectors. The loader keeps the original
  // bag/generator indexes because zone expansion needs sentinel records and
  // adjacent bag ranges exactly as encoded in pdta.
  auto data = read_file(path);
  auto sdta_refs = list_chunk_refs(data, "sdta");
  std::vector<uint8_t> info_payload;
  std::map<std::string, std::vector<uint8_t>> info;
  if (find_list_chunk_optional(data, "INFO", info_payload)) info = list_chunks(info_payload);
  auto sdta = list_chunks(find_list_chunk(data, "sdta"));
  auto pdta = list_chunks(find_list_chunk(data, "pdta"));
  Sf2Data sf2;
  sf2.file_words = file_words_from_bytes(data);
  auto smpl_ref = sdta_refs.find("smpl");
  if (smpl_ref == sdta_refs.end()) throw std::runtime_error("missing SF2 chunk smpl");
  if ((smpl_ref->second.payload_offset & 1u) != 0) throw std::runtime_error("SF2 smpl payload is not word aligned");
  sf2.smpl_word_offset = uint32_t(smpl_ref->second.payload_offset / 2);
  sf2.ifil = version_chunk(info, "ifil");
  sf2.isng = text_chunk(info, "isng");
  sf2.inam = text_chunk(info, "INAM");
  if (sf2.ifil.empty()) throw std::runtime_error("SF2 INFO is missing required ifil version");
  if (sf2.isng.empty()) throw std::runtime_error("SF2 INFO is missing required isng target engine");
  if (sf2.inam.empty()) throw std::runtime_error("SF2 INFO is missing required INAM name");
  const auto& smpl = require_chunk(sdta, "smpl", 2, 0);
  for (size_t i = 0; i + 2 <= smpl.size(); i += 2) {
    sf2.smpl.push_back(int16_t(read_u16le(smpl, i)));
  }
  sf2.presets = parse_presets(require_chunk(pdta, "phdr", 38, 2));
  sf2.preset_bags = parse_bags(require_chunk(pdta, "pbag", 4, 1));
  sf2.preset_modulators = parse_modulators(require_chunk(pdta, "pmod", 10, 1));
  sf2.preset_generators = parse_generators(require_chunk(pdta, "pgen", 4, 1));
  sf2.instruments = parse_instruments(require_chunk(pdta, "inst", 22, 2));
  sf2.instrument_bags = parse_bags(require_chunk(pdta, "ibag", 4, 1));
  sf2.instrument_modulators = parse_modulators(require_chunk(pdta, "imod", 10, 1));
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
  (void)memory;
  // Full MIDI mode starts at the channel program/bank, selects a preset zone,
  // follows that zone to an instrument, then merges preset and instrument
  // generators. Instrument generators override preset defaults for the final
  // playable sample region.
  int preset_idx = select_preset(sf2, program, bank);
  std::vector<Region> regions;
  for (const ArticulationZone& pzone : matching_zones_for_velocity(preset_zones(sf2, preset_idx), key, velocity)) {
    int inst_idx = pzone.generators.at(GEN_INSTRUMENT);
    std::vector<ArticulationZone> matching_izones =
        matching_zones_for_velocity(instrument_zones(sf2, inst_idx), key, velocity);
    std::vector<ArticulationZone> combined_zones;
    combined_zones.reserve(matching_izones.size());
    for (const ArticulationZone& peer : matching_izones) {
      combined_zones.push_back({
          combine_preset_and_instrument_zones(pzone.generators, peer.generators),
          combine_preset_and_instrument_modulators(pzone.modulators, peer.modulators)});
    }
    for (size_t zone_index = 0; zone_index < combined_zones.size(); ++zone_index) {
      const ArticulationZone& articulation = combined_zones.at(zone_index);
      const Zone& zone = articulation.generators;
      int sample_id = zone.at(GEN_SAMPLE_ID);
      if (selected_right_with_matching_left_zone(sf2, sample_id, combined_zones)) continue;
      if (selected_unlinked_right_with_matching_left(sf2, combined_zones, zone_index)) continue;
      const ArticulationZone* left_zone = &articulation;
      const ArticulationZone* right_zone = &articulation;
      const ArticulationZone* pitch_zone = &articulation;
      int pitch_sample_id = sample_id;
      linked_stereo_zone_selection(sf2, sample_id, articulation, combined_zones, left_zone, right_zone,
                                   pitch_zone, pitch_sample_id);
      int unlinked_right_index = -1;
      if (linked_pair(sf2, sample_id).second < 0) {
        unlinked_right_index = unlinked_stereo_partner_index(sf2, combined_zones, zone_index);
        if (unlinked_right_index >= 0) {
          right_zone = &combined_zones.at(size_t(unlinked_right_index));
          pitch_zone = right_zone;
          pitch_sample_id = zone_sample_id(*right_zone);
        }
      }
      Region r;
      r.key = key;
      r.output_sample_rate = sample_rate;
      r.program = program;
      r.bank = bank;
      r.preset = sf2.presets.at(preset_idx).name;
      r.instrument = sf2.instruments.at(inst_idx).name;
      if (unlinked_right_index >= 0) {
        fill_region_addresses_for_sample_pair(sf2, sample_id, pitch_sample_id,
                                              left_zone->generators, right_zone->generators, r);
      } else {
        fill_region_addresses(sf2, sample_id, left_zone->generators, right_zone->generators, r);
      }
      r.phase_inc = phase_inc_for_key(key, pitch_zone->generators, sf2.samples.at(pitch_sample_id), sample_rate);
      gain_config(zone, r);
      if (unlinked_right_index >= 0) center_hard_panned_stereo_gain(r);
      r.loop_mode = loop_mode_from_zone(zone);
      r.effective_velocity = zone.count(GEN_VELOCITY) ? std::max(0, std::min(127, signed_amount(zone.at(GEN_VELOCITY)))) : -1;
      r.exclusive_class = zone.count(GEN_EXCLUSIVE_CLASS) ? std::max(0, std::min(127, signed_amount(zone.at(GEN_EXCLUSIVE_CLASS)))) : 0;
      volume_envelope(zone, key, tick_samples, sample_rate, r);
      modulation_generators(zone, key, tick_samples, sample_rate, r);
      pitch_modulation_generators(pitch_zone->generators, r);
      filter_coefficients(zone, sample_rate, r);
      r.modulators = stereo_runtime_modulators(articulation, *pitch_zone);
      regions.push_back(r);
    }
  }
  if (regions.empty()) throw std::runtime_error("no SF2 zone matches key/velocity");
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
  (void)memory;
  // Forced-instrument mode skips preset lookup. This is useful for bring-up a
  // specific SF2 instrument because MIDI program and bank messages cannot change
  // the selected sample set.
  std::vector<Region> regions;
  std::vector<ArticulationZone> matching = matching_zones_for_velocity(instrument_zones(sf2, inst_idx), key, velocity);
  for (size_t zone_index = 0; zone_index < matching.size(); ++zone_index) {
    const ArticulationZone& articulation = matching.at(zone_index);
    const Zone& zone = articulation.generators;
    int sample_id = zone.at(GEN_SAMPLE_ID);
    if (selected_right_with_matching_left_zone(sf2, sample_id, matching)) continue;
    if (selected_unlinked_right_with_matching_left(sf2, matching, zone_index)) continue;
    const ArticulationZone* left_zone = &articulation;
    const ArticulationZone* right_zone = &articulation;
    const ArticulationZone* pitch_zone = &articulation;
    int pitch_sample_id = sample_id;
    linked_stereo_zone_selection(sf2, sample_id, articulation, matching, left_zone, right_zone,
                                 pitch_zone, pitch_sample_id);
    int unlinked_right_index = -1;
    if (linked_pair(sf2, sample_id).second < 0) {
      unlinked_right_index = unlinked_stereo_partner_index(sf2, matching, zone_index);
      if (unlinked_right_index >= 0) {
        right_zone = &matching.at(size_t(unlinked_right_index));
        pitch_zone = right_zone;
        pitch_sample_id = zone_sample_id(*right_zone);
      }
    }
    Region r;
    r.key = key;
    r.output_sample_rate = sample_rate;
    r.instrument = sf2.instruments.at(inst_idx).name;
    r.preset = r.instrument;
    if (unlinked_right_index >= 0) {
      fill_region_addresses_for_sample_pair(sf2, sample_id, pitch_sample_id,
                                            left_zone->generators, right_zone->generators, r);
    } else {
      fill_region_addresses(sf2, sample_id, left_zone->generators, right_zone->generators, r);
    }
    r.phase_inc = phase_inc_for_key(key, pitch_zone->generators, sf2.samples.at(pitch_sample_id), sample_rate);
    gain_config(zone, r);
    if (unlinked_right_index >= 0) center_hard_panned_stereo_gain(r);
    r.loop_mode = loop_mode_from_zone(zone);
    r.effective_velocity = zone.count(GEN_VELOCITY) ? std::max(0, std::min(127, signed_amount(zone.at(GEN_VELOCITY)))) : -1;
    r.exclusive_class = zone.count(GEN_EXCLUSIVE_CLASS) ? std::max(0, std::min(127, signed_amount(zone.at(GEN_EXCLUSIVE_CLASS)))) : 0;
    volume_envelope(zone, key, tick_samples, sample_rate, r);
    modulation_generators(zone, key, tick_samples, sample_rate, r);
    pitch_modulation_generators(pitch_zone->generators, r);
    filter_coefficients(zone, sample_rate, r);
    r.modulators = stereo_runtime_modulators(articulation, *pitch_zone);
    regions.push_back(r);
  }
  if (regions.empty()) throw std::runtime_error("no SF2 zone matches key/velocity");
  return regions;
}

}  // namespace render
