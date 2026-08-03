#include "sf2_loader.h"

#include "byte_reader.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstring>
#include <limits>
#include <list>
#include <map>
#include <stdexcept>
#include <type_traits>

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
// FluidSynth applies the EMU8k/10k 0.4 scale to file-defined attenuation for
// every SoundFont because existing banks commonly target that hardware behavior.
// Runtime modulators remain in their standard centibel units.
constexpr double EMU_FILE_ATTENUATION_SCALE = 0.4;
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

}  // namespace

struct CompiledCandidate {
  Zone generators;
  std::map<uint16_t, std::vector<Sf2Modulator>> modulators_by_destination;
  int instrument = 0;
  int velocity_low = 0;
  int velocity_high = 127;
};

struct CompiledTarget {
  std::vector<CompiledCandidate> candidates;
  std::array<std::vector<size_t>, 128> candidates_by_key;
};

struct Sf2CompiledData {
  std::map<std::pair<int, int>, int> preset_by_bank_program;
  std::map<std::string, int> instrument_exact;
  std::map<std::string, int> instrument_folded;
  std::vector<CompiledTarget> presets;
  std::vector<CompiledTarget> instruments;
};

namespace {

std::shared_ptr<const Sf2CompiledData> compile_sf2_data(const Sf2Data& sf2);

struct ByteRange {
  size_t offset = 0;
  size_t size = 0;
};

using ChunkTable = std::map<std::string, ByteRange>;

struct RiffIndex {
  std::map<std::string, ChunkTable> lists;
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

uint16_t range_u16le(const std::vector<uint8_t>& data, const ByteRange& range, size_t offset) {
  if (offset > range.size || range.size - offset < 2) throw std::runtime_error("truncated u16le");
  return read_u16le(data, range.offset + offset);
}

uint32_t range_u32le(const std::vector<uint8_t>& data, const ByteRange& range, size_t offset) {
  if (offset > range.size || range.size - offset < 4) throw std::runtime_error("truncated u32le");
  return read_u32le(data, range.offset + offset);
}

std::string range_name(const std::vector<uint8_t>& data, const ByteRange& range,
                       size_t offset, size_t size) {
  if (offset > range.size || size > range.size - offset) throw std::runtime_error("truncated SF2 name");
  std::string name;
  for (size_t i = 0; i < size && data[range.offset + offset + i] != 0; ++i) {
    name.push_back(char(data[range.offset + offset + i]));
  }
  while (!name.empty() && name.back() == ' ') name.pop_back();
  return name;
}

ChunkTable scan_list_children(const std::vector<uint8_t>& data, size_t begin, size_t end) {
  ChunkTable chunks;
  size_t pos = begin;
  while (pos < end) {
    if (end - pos < 8) throw std::runtime_error("truncated LIST child header");
    std::string id(reinterpret_cast<const char*>(data.data() + pos), 4);
    uint32_t child_size = read_u32le(data, pos + 4);
    size_t payload = pos + 8;
    if (child_size > end - payload) throw std::runtime_error("truncated LIST child chunk");
    if (!chunks.emplace(id, ByteRange{payload, child_size}).second) {
      throw std::runtime_error("duplicate SF2 chunk " + id);
    }
    size_t padded_size = size_t(child_size) + (child_size & 1u);
    if (padded_size > end - payload) throw std::runtime_error("truncated LIST child padding");
    pos = payload + padded_size;
  }
  return chunks;
}

RiffIndex scan_riff(const std::vector<uint8_t>& data) {
  if (data.size() < 12 || std::memcmp(data.data(), "RIFF", 4) != 0 ||
      std::memcmp(data.data() + 8, "sfbk", 4) != 0) {
    throw std::runtime_error("not a SoundFont2 RIFF/sfbk file");
  }
  uint32_t riff_size = read_u32le(data, 4);
  if (riff_size < 4 || size_t(riff_size) > data.size() - 8) {
    throw std::runtime_error("truncated SF2 RIFF container");
  }
  const size_t end = 8 + size_t(riff_size);
  RiffIndex index;
  size_t pos = 12;
  while (pos < end) {
    if (end - pos < 8) throw std::runtime_error("truncated RIFF chunk header");
    uint32_t size = read_u32le(data, pos + 4);
    size_t payload = pos + 8;
    if (size > end - payload) throw std::runtime_error("truncated RIFF chunk");
    if (std::memcmp(data.data() + pos, "LIST", 4) == 0) {
      if (size < 4) throw std::runtime_error("SF2 LIST chunk is too short");
      std::string type(reinterpret_cast<const char*>(data.data() + payload), 4);
      ChunkTable children = scan_list_children(data, payload + 4, payload + size);
      if (!index.lists.emplace(type, std::move(children)).second) {
        throw std::runtime_error("duplicate SF2 LIST " + type);
      }
    }
    size_t padded_size = size_t(size) + (size & 1u);
    if (padded_size > end - payload) throw std::runtime_error("truncated RIFF chunk padding");
    pos = payload + padded_size;
  }
  return index;
}

const ChunkTable& require_list(const RiffIndex& index, const char* type) {
  auto it = index.lists.find(type);
  if (it == index.lists.end()) throw std::runtime_error(std::string("missing LIST ") + type);
  return it->second;
}

const ByteRange& require_chunk(const ChunkTable& chunks, const char* id,
                               size_t record_size, size_t min_records) {
  auto it = chunks.find(id);
  if (it == chunks.end()) throw std::runtime_error(std::string("missing SF2 chunk ") + id);
  if (record_size != 0 && (it->second.size % record_size) != 0) {
    throw std::runtime_error(std::string("SF2 chunk ") + id + " has invalid record size");
  }
  if (record_size != 0 && it->second.size / record_size < min_records) {
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

std::string text_chunk(const std::vector<uint8_t>& data, const ChunkTable& chunks, const char* id) {
  auto it = chunks.find(id);
  if (it == chunks.end()) return {};
  const ByteRange& range = it->second;
  std::string s(reinterpret_cast<const char*>(data.data() + range.offset), range.size);
  while (!s.empty() && s.back() == '\0') s.pop_back();
  return s;
}

std::string version_chunk(const std::vector<uint8_t>& data, const ChunkTable& chunks, const char* id) {
  auto it = chunks.find(id);
  if (it == chunks.end()) return {};
  if (it->second.size < 4) throw std::runtime_error(std::string("SF2 INFO ") + id + " is too short");
  return std::to_string(range_u16le(data, it->second, 0)) + "." +
         std::to_string(range_u16le(data, it->second, 2));
}

std::vector<Preset> parse_presets(const std::vector<uint8_t>& data, const ByteRange& c) {
  std::vector<Preset> out;
  out.reserve(c.size / 38);
  for (size_t i = 0; i < c.size; i += 38) {
    out.push_back({range_name(data, c, i, 20), range_u16le(data, c, i + 20),
                   range_u16le(data, c, i + 22), range_u16le(data, c, i + 24)});
  }
  return out;
}

std::vector<Instrument> parse_instruments(const std::vector<uint8_t>& data, const ByteRange& c) {
  std::vector<Instrument> out;
  out.reserve(c.size / 22);
  for (size_t i = 0; i < c.size; i += 22) {
    out.push_back({range_name(data, c, i, 20), range_u16le(data, c, i + 20)});
  }
  return out;
}

std::vector<Bag> parse_bags(const std::vector<uint8_t>& data, const ByteRange& c) {
  std::vector<Bag> out;
  out.reserve(c.size / 4);
  for (size_t i = 0; i < c.size; i += 4) {
    out.push_back({range_u16le(data, c, i), range_u16le(data, c, i + 2)});
  }
  return out;
}

std::vector<Generator> parse_generators(const std::vector<uint8_t>& data, const ByteRange& c) {
  std::vector<Generator> out;
  out.reserve(c.size / 4);
  for (size_t i = 0; i < c.size; i += 4) {
    out.push_back({range_u16le(data, c, i), range_u16le(data, c, i + 2)});
  }
  return out;
}

std::vector<Sf2Modulator> parse_modulators(const std::vector<uint8_t>& data, const ByteRange& c) {
  std::vector<Sf2Modulator> out;
  out.reserve(c.size / 10);
  for (size_t i = 0; i < c.size; i += 10) {
    out.push_back({range_u16le(data, c, i), range_u16le(data, c, i + 2),
                   int(int16_t(range_u16le(data, c, i + 4))), range_u16le(data, c, i + 6),
                   range_u16le(data, c, i + 8)});
  }
  return out;
}

std::vector<SampleHeader> parse_samples(const std::vector<uint8_t>& data, const ByteRange& c) {
  std::vector<SampleHeader> out;
  out.reserve(c.size / 46);
  for (size_t i = 0; i < c.size; i += 46) {
    SampleHeader s;
    s.name = range_name(data, c, i, 20);
    s.start = range_u32le(data, c, i + 20);
    s.end = range_u32le(data, c, i + 24);
    s.start_loop = range_u32le(data, c, i + 28);
    s.end_loop = range_u32le(data, c, i + 32);
    s.sample_rate = range_u32le(data, c, i + 36);
    s.original_pitch = data[c.offset + i + 40];
    s.pitch_correction = int8_t(data[c.offset + i + 41]);
    s.sample_link = range_u16le(data, c, i + 42);
    s.sample_type = range_u16le(data, c, i + 44);
    out.push_back(s);
  }
  return out;
}

void validate_parsed_tables(Sf2Data& sf2) {
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
    auto& s = sf2.samples[i];
    if (s.end < s.start) throw std::runtime_error("SF2 sample header has invalid sample bounds");
    if (s.end > sf2.smpl_word_count) {
      throw std::runtime_error("SF2 sample header exceeds the smpl payload");
    }
    if (s.sample_rate == 0) throw std::runtime_error("SF2 sample header has zero sample rate");
    int t = sanitize_sample_type(s.sample_type);
    if (t != SAMPLE_MONO && t != SAMPLE_LEFT && t != SAMPLE_RIGHT && t != SAMPLE_LINKED) {
      throw std::runtime_error("SF2 sample header has illegal sample type");
    }
    if ((t == SAMPLE_LEFT || t == SAMPLE_RIGHT || t == SAMPLE_LINKED) &&
        s.sample_link >= usable_samples) {
      // Instrument zones define the actual voices. Keep a malformed link from
      // affecting region construction by normalizing it to this sample.
      s.sample_link = i;
    }
    if (s.start_loop < s.start || s.start_loop > s.end ||
        s.end_loop < s.start_loop || s.end_loop > s.end) {
      // Malformed loop metadata is common in unused samples. Normalize it to
      // the complete sample window; sampleModes still decides whether it loops.
      s.start_loop = s.start;
      s.end_loop = s.end;
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
    // The SF2 text says 1000, but its bipolar source already spans both pan
    // halves. FluidSynth uses 500 so CC10 covers the legal -500..+500 range.
    {MOD_SRC_CC10, GEN_PAN, 500, MOD_SRC_NONE, MOD_TRANS_LINEAR},
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

template <typename ZoneView>
int sample_offset(const ZoneView& zone, int fine_oper, int coarse_oper) {
  int fine = zone.count(fine_oper) ? signed_amount(zone.at(fine_oper)) : 0;
  int coarse = zone.count(coarse_oper) ? signed_amount(zone.at(coarse_oper)) : 0;
  return fine + coarse * 32768;
}

uint32_t clamp_sample_pos(int64_t value, uint32_t low, uint32_t high) {
  if (value < int64_t(low)) return low;
  if (value > int64_t(high)) return high;
  return uint32_t(value);
}

template <typename ZoneView>
std::pair<int, int> key_range(const ZoneView& zone) {
  if (!zone.count(GEN_KEY_RANGE)) return {0, 127};
  const int value = zone.at(GEN_KEY_RANGE);
  return {value & 0xff, (value >> 8) & 0xff};
}

template <typename ZoneView>
std::pair<int, int> vel_range(const ZoneView& zone) {
  if (!zone.count(GEN_VEL_RANGE)) return {0, 127};
  const int value = zone.at(GEN_VEL_RANGE);
  return {value & 0xff, (value >> 8) & 0xff};
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

int select_preset(const Sf2Data& sf2, int program, int bank) {
  // SF2 phdr has a terminal sentinel record, so usable excludes the final entry.
  // Try the exact bank/program first, fall back to bank 0 for files without the
  // requested bank, then General MIDI program 0 as a last musical default.
  int usable = std::max(0, int(sf2.presets.size()) - 1);
  const auto compiled = sf2.compiled ? sf2.compiled : compile_sf2_data(sf2);
  auto find = [&](int wanted_bank, int wanted_program) {
    auto it = compiled->preset_by_bank_program.find({wanted_bank, wanted_program});
    return it == compiled->preset_by_bank_program.end() ? -1 : it->second;
  };
  int selected = find(bank, program);
  if (selected >= 0) return selected;
  if (bank != 0) {
    selected = find(0, program);
    if (selected >= 0) return selected;
  }
  selected = find(0, 0);
  if (selected >= 0) return selected;
  if (usable > 0) return 0;
  throw std::runtime_error("soundfont has no presets");
}

template <typename ZoneView>
uint32_t phase_inc_for_key(int key, const ZoneView& zone, const SampleHeader& sample, int output_sample_rate) {
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

template <typename ZoneView>
void pitch_modulation_generators(const ZoneView& zone, Region& region) {
  region.mod_lfo_to_pitch = zone.count(GEN_MOD_LFO_TO_PITCH) ? signed_amount(zone.at(GEN_MOD_LFO_TO_PITCH)) : 0;
  region.vib_lfo_to_pitch = zone.count(GEN_VIB_LFO_TO_PITCH) ? signed_amount(zone.at(GEN_VIB_LFO_TO_PITCH)) : 0;
  region.mod_env_to_pitch = zone.count(GEN_MOD_ENV_TO_PITCH) ? signed_amount(zone.at(GEN_MOD_ENV_TO_PITCH)) : 0;
}

template <typename ZoneView>
int zone_attenuation_gain(const ZoneView& zone) {
  double atten = zone.count(GEN_INITIAL_ATTENUATION)
                     ? double(signed_amount(zone.at(GEN_INITIAL_ATTENUATION))) * EMU_FILE_ATTENUATION_SCALE
                     : 0.0;
  atten = std::max(0.0, std::min(1440.0, atten));
  int gain = 0x4000;
  if (atten != 0.0) gain = int(std::round(double(gain) * std::pow(10.0, -atten / 200.0)));
  return std::max(0, std::min(0x7fff, gain));
}

template <typename ZoneView>
void gain_config(const ZoneView& zone, Region& region) {
  int pan = signed_amount(zone.count(GEN_PAN) ? zone.at(GEN_PAN) : 0);
  region.pan = std::max(-500, std::min(500, pan));
  region.base_gain = zone_attenuation_gain(zone);
  region.base_gain_l = region.base_gain;
  region.base_gain_r = region.base_gain;
  auto gains = equal_power_pan_gains(region.base_gain, region.base_gain, region.pan, false);
  region.gain_l = gains.first;
  region.gain_r = gains.second;
}

enum class TimecentRange {
  kDelayHold,
  kAttackDecayRelease,
};

double timecents_to_seconds(int value, bool present, int default_timecents,
                            TimecentRange range) {
  // SF2 envelope times use timecents: seconds = 2^(timecents / 1200). The spec's
  // most negative value conventionally represents an immediate stage.
  int tc = present ? signed_amount(value) : default_timecents;
  if (tc <= -32768) return 0.0;
  const int maximum = range == TimecentRange::kDelayHold ? 5000 : 8000;
  tc = std::max(-12000, std::min(maximum, tc));
  return std::pow(2.0, double(tc) / 1200.0);
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

uint32_t duration_samples(double seconds, int sample_rate) {
  if (seconds <= 0.0) return 0;
  double samples = std::round(seconds * double(sample_rate));
  return uint32_t(std::max(1.0, std::min(double(UINT32_MAX), samples)));
}

uint32_t rtl_duration_samples(double seconds, int sample_rate) {
  return std::min(0x00ffffffu, duration_samples(seconds, sample_rate));
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

template <typename ZoneView>
void filter_coefficients(const ZoneView& zone, int output_sample_rate, Region& region) {
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

bool envelope_time_is_sub_tick(double seconds, int tick_samples, int sample_rate) {
  return seconds < (double(tick_samples) / double(sample_rate));
}

uint32_t lfo_step(int freq_cents, int tick_samples, int sample_rate) {
  double hz = 8.176 * std::pow(2.0, double(signed_amount(freq_cents)) / 1200.0);
  double cycles_per_tick = hz * double(tick_samples) / double(sample_rate);
  double raw = std::round(cycles_per_tick * 65536.0);
  if (raw <= 0.0) return 0;
  if (raw > double(UINT32_MAX)) return UINT32_MAX;
  return uint32_t(raw);
}

template <typename ZoneView>
void modulation_generators(const ZoneView& zone, int key, int tick_samples, int sample_rate, Region& region) {
  region.mod_lfo_delay_ticks = envelope_ticks(timecents_to_seconds(zone.count(GEN_DELAY_MOD_LFO) ? zone.at(GEN_DELAY_MOD_LFO) : 0,
                                                              zone.count(GEN_DELAY_MOD_LFO), -12000,
                                                              TimecentRange::kDelayHold),
                                             tick_samples, sample_rate);
  region.vib_lfo_delay_ticks = envelope_ticks(timecents_to_seconds(zone.count(GEN_DELAY_VIB_LFO) ? zone.at(GEN_DELAY_VIB_LFO) : 0,
                                                              zone.count(GEN_DELAY_VIB_LFO), -12000,
                                                              TimecentRange::kDelayHold),
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
                                  zone.count(GEN_ATTACK_MOD_ENV), -12000,
                                  TimecentRange::kAttackDecayRelease);
  int hold_tc = signed_amount(zone.count(GEN_HOLD_MOD_ENV) ? zone.at(GEN_HOLD_MOD_ENV) : 0);
  if (zone.count(GEN_KEYNUM_TO_MOD_ENV_HOLD)) hold_tc += signed_amount(zone.at(GEN_KEYNUM_TO_MOD_ENV_HOLD)) * (60 - key);
  double h = timecents_to_seconds(hold_tc, zone.count(GEN_HOLD_MOD_ENV) || zone.count(GEN_KEYNUM_TO_MOD_ENV_HOLD), -12000,
                                  TimecentRange::kDelayHold);
  int decay_tc = signed_amount(zone.count(GEN_DECAY_MOD_ENV) ? zone.at(GEN_DECAY_MOD_ENV) : 0);
  if (zone.count(GEN_KEYNUM_TO_MOD_ENV_DECAY)) decay_tc += signed_amount(zone.at(GEN_KEYNUM_TO_MOD_ENV_DECAY)) * (60 - key);
  double d = timecents_to_seconds(decay_tc, zone.count(GEN_DECAY_MOD_ENV) || zone.count(GEN_KEYNUM_TO_MOD_ENV_DECAY), -12000,
                                  TimecentRange::kAttackDecayRelease);
  double r = timecents_to_seconds(zone.count(GEN_RELEASE_MOD_ENV) ? zone.at(GEN_RELEASE_MOD_ENV) : 0,
                                  zone.count(GEN_RELEASE_MOD_ENV), -12000,
                                  TimecentRange::kAttackDecayRelease);
  double delay = timecents_to_seconds(zone.count(GEN_DELAY_MOD_ENV) ? zone.at(GEN_DELAY_MOD_ENV) : 0,
                                      zone.count(GEN_DELAY_MOD_ENV), -12000,
                                      TimecentRange::kDelayHold);
  region.mod_env_delay_ticks = envelope_ticks(delay, tick_samples, sample_rate);
  region.mod_env_hold_ticks = envelope_ticks(h, tick_samples, sample_rate);
  int mod_sustain_drop = signed_amount(zone.count(GEN_SUSTAIN_MOD_ENV) ? zone.at(GEN_SUSTAIN_MOD_ENV) : 0);
  mod_sustain_drop = std::max(0, std::min(1000, mod_sustain_drop));
  region.mod_env_sustain_level = percent_drop_to_level(mod_sustain_drop);
  region.mod_env_attack_ticks = envelope_tick_count(a, tick_samples, sample_rate);
  region.mod_env_decay_ticks = scaled_envelope_tick_count(d, double(mod_sustain_drop) / 1000.0,
                                                          tick_samples, sample_rate);
  region.mod_env_release_ticks = envelope_tick_count(r, tick_samples, sample_rate);
  region.mod_env_attack_sub_tick = envelope_time_is_sub_tick(a, tick_samples, sample_rate);
  region.mod_env_attack_step = envelope_step(a, tick_samples, sample_rate);
  region.mod_env_decay_step = envelope_step(d, tick_samples, sample_rate);
  region.mod_env_release_step = envelope_step(r, tick_samples, sample_rate);
}

template <typename ZoneView>
void volume_envelope(const ZoneView& zone, int key, int tick_samples, int sample_rate, Region& region) {
  // Audible envelope parameters are prepared directly in output-sample units.
  // The tick counts below are only the MCU lifecycle shadow used for allocation.
  double a = timecents_to_seconds(zone.count(GEN_ATTACK_VOL_ENV) ? zone.at(GEN_ATTACK_VOL_ENV) : 0,
                                  zone.count(GEN_ATTACK_VOL_ENV), -12000,
                                  TimecentRange::kAttackDecayRelease);
  int hold_tc = signed_amount(zone.count(GEN_HOLD_VOL_ENV) ? zone.at(GEN_HOLD_VOL_ENV) : 0);
  if (zone.count(GEN_KEYNUM_TO_VOL_ENV_HOLD)) hold_tc += signed_amount(zone.at(GEN_KEYNUM_TO_VOL_ENV_HOLD)) * (60 - key);
  double h = timecents_to_seconds(hold_tc, zone.count(GEN_HOLD_VOL_ENV) || zone.count(GEN_KEYNUM_TO_VOL_ENV_HOLD), -12000,
                                  TimecentRange::kDelayHold);
  int decay_tc = signed_amount(zone.count(GEN_DECAY_VOL_ENV) ? zone.at(GEN_DECAY_VOL_ENV) : 0);
  if (zone.count(GEN_KEYNUM_TO_VOL_ENV_DECAY)) decay_tc += signed_amount(zone.at(GEN_KEYNUM_TO_VOL_ENV_DECAY)) * (60 - key);
  double d = timecents_to_seconds(decay_tc, zone.count(GEN_DECAY_VOL_ENV) || zone.count(GEN_KEYNUM_TO_VOL_ENV_DECAY), -12000,
                                  TimecentRange::kAttackDecayRelease);
  double r = timecents_to_seconds(zone.count(GEN_RELEASE_VOL_ENV) ? zone.at(GEN_RELEASE_VOL_ENV) : 0,
                                  zone.count(GEN_RELEASE_VOL_ENV), -12000,
                                  TimecentRange::kAttackDecayRelease);
  double delay = timecents_to_seconds(zone.count(GEN_DELAY_VOL_ENV) ? zone.at(GEN_DELAY_VOL_ENV) : 0,
                                      zone.count(GEN_DELAY_VOL_ENV), -12000,
                                      TimecentRange::kDelayHold);
  region.delay_ticks = envelope_ticks(delay, tick_samples, sample_rate);
  region.hold_ticks = envelope_ticks(h, tick_samples, sample_rate);
  int vol_sustain_cb = signed_amount(zone.count(GEN_SUSTAIN_VOL_ENV) ? zone.at(GEN_SUSTAIN_VOL_ENV) : 0);
  vol_sustain_cb = std::max(0, std::min(1440, vol_sustain_cb));
  region.sustain_level = centibels_to_level(vol_sustain_cb);
  region.attack_ticks = envelope_tick_count(a, tick_samples, sample_rate);
  region.decay_ticks = scaled_envelope_tick_count(d, double(std::min(1000, vol_sustain_cb)) / 1000.0,
                                                  tick_samples, sample_rate);
  region.release_ticks = envelope_tick_count(r, tick_samples, sample_rate);
  region.volume_envelope.delay_samples = rtl_duration_samples(delay, sample_rate);
  region.volume_envelope.attack_samples = duration_samples(a, sample_rate);
  region.volume_envelope.hold_samples = rtl_duration_samples(h, sample_rate);
  double decay_fraction = double(std::min(1000, vol_sustain_cb)) / 1000.0;
  region.volume_envelope.decay_samples = duration_samples(d * decay_fraction, sample_rate);
  region.volume_envelope.sustain_cb_q12_20 = uint32_t(std::min(1000, vol_sustain_cb)) << 20;
  region.volume_envelope.release_samples = duration_samples(r, sample_rate);
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

std::string case_fold(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](unsigned char c) { return char(std::tolower(c)); });
  return value;
}

void add_compiled_candidate(CompiledTarget& target, ArticulationZone articulation,
                            int instrument, std::pair<int, int> keys,
                            std::pair<int, int> velocities) {
  if (keys.first > keys.second || velocities.first > velocities.second) return;
  articulation.generators[GEN_KEY_RANGE] = keys.first | (keys.second << 8);
  articulation.generators[GEN_VEL_RANGE] = velocities.first | (velocities.second << 8);
  CompiledCandidate candidate;
  candidate.instrument = instrument;
  candidate.velocity_low = velocities.first;
  candidate.velocity_high = velocities.second;
  for (const auto& mod : articulation.modulators) {
    candidate.modulators_by_destination[mod.dest].push_back(mod);
  }
  candidate.generators = std::move(articulation.generators);
  size_t index = target.candidates.size();
  target.candidates.push_back(std::move(candidate));
  for (int key = keys.first; key <= keys.second; ++key) {
    target.candidates_by_key[size_t(key)].push_back(index);
  }
}

std::shared_ptr<const Sf2CompiledData> compile_sf2_data(const Sf2Data& sf2) {
  auto compiled = std::make_shared<Sf2CompiledData>();
  int usable_instruments = std::max(0, int(sf2.instruments.size()) - 1);
  int usable_presets = std::max(0, int(sf2.presets.size()) - 1);
  compiled->instruments.resize(size_t(usable_instruments));
  compiled->presets.resize(size_t(usable_presets));

  std::vector<std::vector<ArticulationZone>> expanded_instruments{
      static_cast<size_t>(usable_instruments)};
  for (int instrument = 0; instrument < usable_instruments; ++instrument) {
    compiled->instrument_exact.emplace(sf2.instruments[instrument].name, instrument);
    compiled->instrument_folded.emplace(case_fold(sf2.instruments[instrument].name), instrument);
    expanded_instruments[size_t(instrument)] = instrument_zones(sf2, instrument);
    for (const auto& zone : expanded_instruments[size_t(instrument)]) {
      add_compiled_candidate(compiled->instruments[size_t(instrument)], zone, instrument,
                             key_range(zone.generators), vel_range(zone.generators));
    }
  }

  for (int preset = 0; preset < usable_presets; ++preset) {
    const auto& header = sf2.presets[preset];
    compiled->preset_by_bank_program.emplace(std::make_pair(header.bank, header.preset), preset);
    for (const auto& preset_zone : preset_zones(sf2, preset)) {
      int instrument = preset_zone.generators.at(GEN_INSTRUMENT);
      const auto preset_keys = key_range(preset_zone.generators);
      const auto preset_velocities = vel_range(preset_zone.generators);
      for (const auto& instrument_zone : expanded_instruments.at(size_t(instrument))) {
        const auto instrument_keys = key_range(instrument_zone.generators);
        const auto instrument_velocities = vel_range(instrument_zone.generators);
        std::pair<int, int> keys = {std::max(preset_keys.first, instrument_keys.first),
                                    std::min(preset_keys.second, instrument_keys.second)};
        std::pair<int, int> velocities = {
            std::max(preset_velocities.first, instrument_velocities.first),
            std::min(preset_velocities.second, instrument_velocities.second)};
        ArticulationZone combined = {
            combine_preset_and_instrument_zones(preset_zone.generators,
                                                instrument_zone.generators),
            combine_preset_and_instrument_modulators(preset_zone.modulators,
                                                     instrument_zone.modulators)};
        add_compiled_candidate(compiled->presets[size_t(preset)], std::move(combined),
                               instrument, keys, velocities);
      }
    }
  }
  return compiled;
}

template <typename ZoneView>
int loop_mode_from_zone(const ZoneView& zone) {
  // SF2 sampleModes 1 means continuous loop and 3 means loop until note release.
  // Those map directly to the small loop-mode field implemented by the RTL.
  int sample_modes = (zone.count(GEN_SAMPLE_MODES) ? zone.at(GEN_SAMPLE_MODES) : 0) & 0x3;
  if (sample_modes == 1) return 1;
  if (sample_modes == 3) return 2;
  return 0;
}

struct SampleWindow {
  uint32_t start = 0;
  uint32_t end = 0;
  uint32_t start_loop = 0;
  uint32_t end_loop = 0;
};

template <typename ZoneView>
SampleWindow sample_window(const Sf2Data& sf2, const SampleHeader& h, const ZoneView& zone) {
  uint32_t pool = sf2.smpl_word_count;
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

template <typename ZoneView>
void fill_region_addresses_from_sample(uint32_t sample_word_offset,
                                       uint32_t sample_word_count,
                                       const SampleHeader& sample,
                                       const ZoneView& zone, Region& region) {
  // Every playable zone stays mono. Linked stereo is represented by two
  // adjacent zones and therefore two independently constructed Regions.
  if (sample.sample_type & SAMPLE_ROM_FLAG) {
    throw std::runtime_error("selected SF2 sample references ROM data");
  }
  if (sanitize_sample_type(sample.sample_type) == SAMPLE_LINKED) {
    throw std::runtime_error("SoundFont linkedSample type is unsupported");
  }
  Sf2Data bounds;
  bounds.smpl_word_count = sample_word_count;
  SampleWindow window = sample_window(bounds, sample, zone);
  region.sample_left = sample.name;
  region.sample_right = sample.name;
  region.base_addr = sample_word_offset + window.start;
  region.base_addr_r = region.base_addr;
  uint32_t frames = std::min<uint32_t>(window.end - window.start, kPhaseFrameMask);
  region.stereo = false;
  region.stereo_source = "mono";
  region.length = frames;
  region.length_r = frames;
  region.loop_start = std::min<uint32_t>(relative_sample_pos(window.start_loop, window.start),
                                         frames ? frames - 1 : 0);
  region.loop_start_r = region.loop_start;
  region.loop_end = std::max<uint32_t>(region.loop_start + 1,
                                       std::min<uint32_t>(relative_sample_pos(window.end_loop, window.start),
                                                          frames));
  region.loop_end_r = region.loop_end;
  if (region.loop_start >= region.loop_end || region.loop_end > frames) {
    region.loop_start = 0;
    region.loop_end = frames;
    region.loop_start_r = 0;
    region.loop_end_r = frames;
  }
}

template <typename ZoneView>
void fill_region_addresses(const Sf2Data& sf2, int sample_id,
                           const ZoneView& zone, Region& region) {
  fill_region_addresses_from_sample(sf2.smpl_word_offset, sf2.smpl_word_count,
                                    sf2.samples.at(sample_id), zone, region);
}

template <typename ZoneView>
Region region_from_zone(const Sf2Data& sf2, const ZoneView& zone,
                        int key, int sample_rate, int tick_samples,
                        int program, int bank, const std::string& preset_name,
                        const std::string& instrument_name,
                        const std::map<uint16_t, std::vector<Sf2Modulator>>& grouped_modulators) {
  int sample_id = zone.at(GEN_SAMPLE_ID);
  Region region;
  region.key = key;
  region.output_sample_rate = sample_rate;
  region.program = program;
  region.bank = bank;
  region.preset = preset_name;
  region.instrument = instrument_name;
  fill_region_addresses(sf2, sample_id, zone, region);
  region.phase_inc = phase_inc_for_key(key, zone, sf2.samples.at(sample_id), sample_rate);
  gain_config(zone, region);
  region.loop_mode = loop_mode_from_zone(zone);
  region.effective_velocity = zone.count(GEN_VELOCITY)
                                  ? std::max(0, std::min(127, signed_amount(zone.at(GEN_VELOCITY))))
                                  : -1;
  region.exclusive_class = zone.count(GEN_EXCLUSIVE_CLASS)
                               ? std::max(0, std::min(127, signed_amount(zone.at(GEN_EXCLUSIVE_CLASS))))
                               : 0;
  volume_envelope(zone, key, tick_samples, sample_rate, region);
  modulation_generators(zone, key, tick_samples, sample_rate, region);
  pitch_modulation_generators(zone, region);
  filter_coefficients(zone, sample_rate, region);
  region.modulators_by_destination = grouped_modulators;
  return region;
}

std::vector<Region> regions_from_compiled_target(
    const Sf2Data& sf2, const CompiledTarget& target, int key, int velocity,
    int sample_rate, int tick_samples, int program, int bank,
    const std::string& preset_name) {
  key = std::max(0, std::min(127, key));
  velocity = std::max(0, std::min(127, velocity));
  const auto& candidates = target.candidates_by_key[size_t(key)];
  std::vector<Region> regions;
  regions.reserve(candidates.size());
  for (size_t index : candidates) {
    const auto& candidate = target.candidates.at(index);
    if (velocity < candidate.velocity_low || velocity > candidate.velocity_high) continue;
    regions.push_back(region_from_zone(
        sf2, candidate.generators, key, sample_rate, tick_samples,
        program, bank, preset_name,
        sf2.instruments.at(candidate.instrument).name,
        candidate.modulators_by_destination));
  }
  return regions;
}

}  // namespace

Sf2Data load_sf2(const std::string& path) {
  // Byte ranges remain non-owning views into data. After parsing, only the
  // word-addressed file image and compact metadata survive this function.
  auto data = read_file(path);
  RiffIndex index = scan_riff(data);
  const ChunkTable empty_info;
  auto info_it = index.lists.find("INFO");
  const ChunkTable& info = info_it == index.lists.end() ? empty_info : info_it->second;
  const ChunkTable& sdta = require_list(index, "sdta");
  const ChunkTable& pdta = require_list(index, "pdta");
  Sf2Data sf2;
  const ByteRange& smpl = require_chunk(sdta, "smpl", 2, 0);
  if ((smpl.offset & 1u) != 0) throw std::runtime_error("SF2 smpl payload is not word aligned");
  if (smpl.offset / 2 > std::numeric_limits<uint32_t>::max() ||
      smpl.size / 2 > std::numeric_limits<uint32_t>::max()) {
    throw std::runtime_error("SF2 smpl payload exceeds word-addressable limits");
  }
  sf2.smpl_word_offset = uint32_t(smpl.offset / 2);
  sf2.smpl_word_count = uint32_t(smpl.size / 2);
  sf2.ifil = version_chunk(data, info, "ifil");
  sf2.isng = text_chunk(data, info, "isng");
  sf2.inam = text_chunk(data, info, "INAM");
  if (sf2.ifil.empty()) throw std::runtime_error("SF2 INFO is missing required ifil version");
  if (sf2.isng.empty()) throw std::runtime_error("SF2 INFO is missing required isng target engine");
  if (sf2.inam.empty()) throw std::runtime_error("SF2 INFO is missing required INAM name");
  sf2.presets = parse_presets(data, require_chunk(pdta, "phdr", 38, 2));
  sf2.preset_bags = parse_bags(data, require_chunk(pdta, "pbag", 4, 1));
  sf2.preset_modulators = parse_modulators(data, require_chunk(pdta, "pmod", 10, 1));
  sf2.preset_generators = parse_generators(data, require_chunk(pdta, "pgen", 4, 1));
  sf2.instruments = parse_instruments(data, require_chunk(pdta, "inst", 22, 2));
  sf2.instrument_bags = parse_bags(data, require_chunk(pdta, "ibag", 4, 1));
  sf2.instrument_modulators = parse_modulators(data, require_chunk(pdta, "imod", 10, 1));
  sf2.instrument_generators = parse_generators(data, require_chunk(pdta, "igen", 4, 1));
  sf2.samples = parse_samples(data, require_chunk(pdta, "shdr", 46, 2));
  validate_parsed_tables(sf2);
  sf2.compiled = compile_sf2_data(sf2);
  sf2.file_words = file_words_from_bytes(data);
  return sf2;
}

Sf2LoaderStats sf2_loader_stats(const Sf2Data& sf2) {
  Sf2LoaderStats stats;
  stats.preset_count = sf2.presets.size();
  stats.instrument_count = sf2.instruments.size();
  stats.preset_bag_count = sf2.preset_bags.size();
  stats.instrument_bag_count = sf2.instrument_bags.size();
  stats.preset_generator_count = sf2.preset_generators.size();
  stats.instrument_generator_count = sf2.instrument_generators.size();
  stats.preset_modulator_count = sf2.preset_modulators.size();
  stats.instrument_modulator_count = sf2.instrument_modulators.size();
  stats.sample_count = sf2.samples.size();
  stats.retained_bytes = sizeof(Sf2Data) + sf2.file_words.capacity() * sizeof(int16_t) +
                         sf2.presets.capacity() * sizeof(Preset) +
                         sf2.instruments.capacity() * sizeof(Instrument) +
                         sf2.preset_bags.capacity() * sizeof(Bag) +
                         sf2.instrument_bags.capacity() * sizeof(Bag) +
                         sf2.preset_generators.capacity() * sizeof(Generator) +
                         sf2.instrument_generators.capacity() * sizeof(Generator) +
                         sf2.preset_modulators.capacity() * sizeof(Sf2Modulator) +
                         sf2.instrument_modulators.capacity() * sizeof(Sf2Modulator) +
                         sf2.samples.capacity() * sizeof(SampleHeader);
  stats.retained_bytes += sf2.ifil.capacity() + sf2.isng.capacity() + sf2.inam.capacity();
  for (const auto& preset : sf2.presets) stats.retained_bytes += preset.name.capacity();
  for (const auto& instrument : sf2.instruments) stats.retained_bytes += instrument.name.capacity();
  for (const auto& sample : sf2.samples) stats.retained_bytes += sample.name.capacity();
  if (sf2.compiled) {
    const auto& compiled = *sf2.compiled;
    size_t bytes = sizeof(Sf2CompiledData);
    bytes += compiled.preset_by_bank_program.size() *
             sizeof(decltype(compiled.preset_by_bank_program)::value_type);
    auto add_string_index = [&](const auto& index) {
      bytes += index.size() * sizeof(typename std::decay_t<decltype(index)>::value_type);
      for (const auto& entry : index) bytes += entry.first.capacity();
    };
    add_string_index(compiled.instrument_exact);
    add_string_index(compiled.instrument_folded);
    auto add_targets = [&](const std::vector<CompiledTarget>& targets,
                           size_t& candidate_count) {
      bytes += targets.capacity() * sizeof(CompiledTarget);
      for (const auto& target : targets) {
        candidate_count += target.candidates.size();
        bytes += target.candidates.capacity() * sizeof(CompiledCandidate);
        for (const auto& candidate : target.candidates) {
          bytes += candidate.generators.size() * sizeof(Zone::value_type);
          bytes += candidate.modulators_by_destination.size() *
                   sizeof(decltype(candidate.modulators_by_destination)::value_type);
          for (const auto& group : candidate.modulators_by_destination) {
            bytes += group.second.capacity() * sizeof(Sf2Modulator);
          }
        }
        for (const auto& by_key : target.candidates_by_key) {
          bytes += by_key.capacity() * sizeof(size_t);
        }
      }
    };
    add_targets(compiled.presets, stats.compiled_preset_candidate_count);
    add_targets(compiled.instruments, stats.compiled_instrument_candidate_count);
    stats.compiled_retained_bytes = bytes;
    stats.retained_bytes += bytes;
  }
  return stats;
}

Sf2SemanticData compile_sf2_semantics(const Sf2Data& sf2) {
  auto checked_u32 = [](size_t value, const char* label) {
    if (value > std::numeric_limits<uint32_t>::max()) {
      throw std::runtime_error(std::string(label) + " exceeds 32-bit asset indexing");
    }
    return uint32_t(value);
  };

  const auto compiled = sf2.compiled ? sf2.compiled : compile_sf2_data(sf2);
  Sf2SemanticData semantic;
  semantic.presets.reserve(compiled->presets.size());
  for (size_t preset_index = 0; preset_index < compiled->presets.size(); ++preset_index) {
    const auto& source_preset = sf2.presets.at(preset_index);
    const auto& target = compiled->presets[preset_index];
    Sf2SemanticPreset preset;
    preset.program = uint16_t(source_preset.preset);
    preset.bank = uint16_t(source_preset.bank);
    preset.first_candidate = checked_u32(semantic.candidates.size(), "candidate offset");
    preset.candidate_count = checked_u32(target.candidates.size(), "preset candidate count");
    semantic.presets.push_back(preset);

    for (const auto& source_candidate : target.candidates) {
      const auto keys = key_range(source_candidate.generators);
      Sf2SemanticCandidate candidate;
      candidate.key_low = uint8_t(keys.first);
      candidate.key_high = uint8_t(keys.second);
      candidate.velocity_low = uint8_t(source_candidate.velocity_low);
      candidate.velocity_high = uint8_t(source_candidate.velocity_high);
      candidate.instrument = uint32_t(source_candidate.instrument);
      candidate.first_generator = checked_u32(semantic.generators.size(), "generator offset");
      candidate.generator_count = checked_u32(source_candidate.generators.size(),
                                              "candidate generator count");
      for (const auto& generator : source_candidate.generators) {
        semantic.generators.push_back(
            {uint16_t(generator.first), uint16_t(generator.second)});
      }
      candidate.first_modulator = checked_u32(semantic.modulators.size(), "modulator offset");
      for (const auto& destination : source_candidate.modulators_by_destination) {
        semantic.modulators.insert(semantic.modulators.end(), destination.second.begin(),
                                   destination.second.end());
      }
      candidate.modulator_count = checked_u32(
          semantic.modulators.size() - candidate.first_modulator,
          "candidate modulator count");
      semantic.candidates.push_back(candidate);
    }
  }

  const size_t usable_samples = sf2.samples.empty() ? 0 : sf2.samples.size() - 1;
  semantic.samples.reserve(usable_samples);
  for (size_t index = 0; index < usable_samples; ++index) {
    const auto& sample = sf2.samples[index];
    semantic.samples.push_back({
        sample.start, sample.end, sample.start_loop, sample.end_loop,
        sample.sample_rate, uint8_t(sample.original_pitch),
        int8_t(sample.pitch_correction), uint16_t(sample.sample_link),
        uint16_t(sample.sample_type)});
  }
  return semantic;
}

Region make_region_for_compiled_candidate(const Sf2Data& sf2,
                                          size_t preset_index,
                                          size_t candidate_index,
                                          int key, int sample_rate,
                                          int tick_samples) {
  const auto compiled = sf2.compiled ? sf2.compiled : compile_sf2_data(sf2);
  const auto& target = compiled->presets.at(preset_index);
  const auto& candidate = target.candidates.at(candidate_index);
  if (key < 0 || key > 127) throw std::out_of_range("compiled candidate key");
  const auto keys = key_range(candidate.generators);
  if (key < keys.first || key > keys.second) {
    throw std::out_of_range("key is outside compiled candidate range");
  }
  const auto& preset = sf2.presets.at(preset_index);
  return region_from_zone(
      sf2, candidate.generators, key, sample_rate, tick_samples,
      preset.preset, preset.bank, preset.name,
      sf2.instruments.at(size_t(candidate.instrument)).name,
      candidate.modulators_by_destination);
}

Region materialize_sf2_region(const Sf2SemanticGenerator* generators,
                              size_t generator_count,
                              const Sf2SemanticSample& source_sample,
                              uint32_t sample_word_offset,
                              uint32_t sample_word_count,
                              int key, int sample_rate, int tick_samples) {
  struct FixedZone {
    std::array<uint16_t, 61> values{};
    uint64_t present = 0;
    size_t count(int oper) const {
      return oper >= 0 && oper < int(values.size()) &&
             (present & (uint64_t(1) << oper)) != 0;
    }
    int at(int oper) const {
      if (!count(oper)) throw std::out_of_range("compact SF2 generator");
      return values[size_t(oper)];
    }
  } zone;
  if (key < 0 || key > 127 || generators == nullptr || generator_count > 61) {
    throw std::out_of_range("compact SF2 materialization input");
  }
  for (size_t index = 0; index < generator_count; ++index) {
    const auto generator = generators[index];
    if (generator.oper >= zone.values.size() || zone.count(generator.oper)) {
      throw std::runtime_error("invalid compact SF2 generator set");
    }
    zone.values[generator.oper] = generator.amount;
    zone.present |= uint64_t(1) << generator.oper;
  }

  SampleHeader sample;
  sample.start = source_sample.start;
  sample.end = source_sample.end;
  sample.start_loop = source_sample.start_loop;
  sample.end_loop = source_sample.end_loop;
  sample.sample_rate = source_sample.sample_rate;
  sample.original_pitch = source_sample.original_pitch;
  sample.pitch_correction = source_sample.pitch_correction;
  sample.sample_link = source_sample.sample_link;
  sample.sample_type = source_sample.sample_type;
  Region region;
  region.key = key;
  region.output_sample_rate = sample_rate;
  fill_region_addresses_from_sample(sample_word_offset, sample_word_count,
                                    sample, zone, region);
  region.phase_inc = phase_inc_for_key(key, zone, sample, sample_rate);
  gain_config(zone, region);
  region.loop_mode = loop_mode_from_zone(zone);
  region.effective_velocity = zone.count(GEN_VELOCITY)
      ? std::max(0, std::min(127, signed_amount(zone.at(GEN_VELOCITY)))) : -1;
  region.exclusive_class = zone.count(GEN_EXCLUSIVE_CLASS)
      ? std::max(0, std::min(127, signed_amount(zone.at(GEN_EXCLUSIVE_CLASS)))) : 0;
  volume_envelope(zone, key, tick_samples, sample_rate, region);
  modulation_generators(zone, key, tick_samples, sample_rate, region);
  pitch_modulation_generators(zone, region);
  filter_coefficients(zone, sample_rate, region);
  return region;
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
  const auto compiled = sf2.compiled ? sf2.compiled : compile_sf2_data(sf2);
  auto exact = compiled->instrument_exact.find(instrument);
  if (exact != compiled->instrument_exact.end()) return exact->second;
  std::string needle = case_fold(instrument);
  auto folded = compiled->instrument_folded.find(needle);
  if (folded != compiled->instrument_folded.end()) return folded->second;
  for (int i = 0; i < usable; ++i) {
    std::string name = case_fold(sf2.instruments[i].name);
    if (name == needle || name.find(needle) != std::string::npos) return i;
  }
  throw std::runtime_error("instrument not found: " + instrument);
}

Region make_region_for_preset(const Sf2Data& sf2, int program, int bank, int key,
                               int velocity, int sample_rate, int tick_samples) {
  return make_regions_for_preset(sf2, program, bank, key, velocity,
                                 sample_rate, tick_samples).front();
}

std::vector<Region> make_regions_for_preset(const Sf2Data& sf2, int program, int bank, int key,
                                              int velocity, int sample_rate, int tick_samples) {
  const auto compiled = sf2.compiled ? sf2.compiled : compile_sf2_data(sf2);
  int preset_idx = select_preset(sf2, program, bank);
  std::vector<Region> regions = regions_from_compiled_target(
      sf2, compiled->presets.at(size_t(preset_idx)), key, velocity,
      sample_rate, tick_samples, program, bank, sf2.presets.at(preset_idx).name);
  if (regions.empty()) throw std::runtime_error("no SF2 zone matches key/velocity");
  return regions;
}

Region make_region_for_instrument(const Sf2Data& sf2, int inst_idx, int key,
                                   int velocity, int sample_rate, int tick_samples) {
  return make_regions_for_instrument(sf2, inst_idx, key, velocity,
                                     sample_rate, tick_samples).front();
}

std::vector<Region> make_regions_for_instrument(const Sf2Data& sf2, int inst_idx, int key,
                                                  int velocity, int sample_rate, int tick_samples) {
  const auto compiled = sf2.compiled ? sf2.compiled : compile_sf2_data(sf2);
  const std::string& instrument_name = sf2.instruments.at(inst_idx).name;
  std::vector<Region> regions = regions_from_compiled_target(
      sf2, compiled->instruments.at(size_t(inst_idx)), key, velocity,
      sample_rate, tick_samples, 0, 0, instrument_name);
  if (regions.empty()) throw std::runtime_error("no SF2 zone matches key/velocity");
  return regions;
}

struct Sf2RegionCache::Impl {
  using Key = std::array<int, 7>;
  struct Entry {
    std::shared_ptr<const std::vector<Region>> regions;
    std::list<Key>::iterator lru;
  };

  const Sf2Data& sf2;
  int sample_rate;
  int tick_samples;
  size_t max_entries;
  std::map<Key, Entry> entries;
  std::list<Key> lru;

  Impl(const Sf2Data& source, int rate, int ticks, size_t capacity)
      : sf2(source), sample_rate(rate), tick_samples(ticks),
        max_entries(std::max<size_t>(1, capacity)) {
    if (sample_rate <= 0 || tick_samples <= 0) {
      throw std::runtime_error("SF2 Region cache output configuration must be positive");
    }
  }

  template <typename Builder>
  std::shared_ptr<const std::vector<Region>> lookup(const Key& key, Builder builder) {
    auto found = entries.find(key);
    if (found != entries.end()) {
      lru.splice(lru.begin(), lru, found->second.lru);
      return found->second.regions;
    }
    auto regions = std::make_shared<const std::vector<Region>>(builder());
    if (entries.size() == max_entries) {
      entries.erase(lru.back());
      lru.pop_back();
    }
    lru.push_front(key);
    entries.emplace(key, Entry{regions, lru.begin()});
    return regions;
  }
};

Sf2RegionCache::Sf2RegionCache(const Sf2Data& sf2, int sample_rate,
                               int tick_samples, size_t capacity)
    : impl_(std::make_unique<Impl>(sf2, sample_rate, tick_samples, capacity)) {}

Sf2RegionCache::~Sf2RegionCache() = default;

std::shared_ptr<const std::vector<Region>> Sf2RegionCache::regions_for_preset(
    int program, int bank, int key, int velocity) {
  Impl::Key cache_key = {0, program, bank, key, velocity,
                         impl_->sample_rate, impl_->tick_samples};
  return impl_->lookup(cache_key, [&] {
    const auto compiled = impl_->sf2.compiled ? impl_->sf2.compiled
                                              : compile_sf2_data(impl_->sf2);
    int preset = select_preset(impl_->sf2, program, bank);
    return regions_from_compiled_target(
        impl_->sf2, compiled->presets.at(size_t(preset)), key, velocity,
        impl_->sample_rate, impl_->tick_samples, program, bank,
        impl_->sf2.presets.at(size_t(preset)).name);
  });
}

std::shared_ptr<const std::vector<Region>> Sf2RegionCache::regions_for_instrument(
    int instrument, int key, int velocity) {
  Impl::Key cache_key = {1, instrument, 0, key, velocity,
                         impl_->sample_rate, impl_->tick_samples};
  return impl_->lookup(cache_key, [&] {
    const auto compiled = impl_->sf2.compiled ? impl_->sf2.compiled
                                              : compile_sf2_data(impl_->sf2);
    return regions_from_compiled_target(
        impl_->sf2, compiled->instruments.at(size_t(instrument)), key, velocity,
        impl_->sample_rate, impl_->tick_samples, 0, 0,
        impl_->sf2.instruments.at(size_t(instrument)).name);
  });
}

void Sf2RegionCache::set_output_config(int sample_rate, int tick_samples) {
  if (sample_rate <= 0 || tick_samples <= 0) {
    throw std::runtime_error("SF2 Region cache output configuration must be positive");
  }
  if (sample_rate == impl_->sample_rate && tick_samples == impl_->tick_samples) return;
  impl_->sample_rate = sample_rate;
  impl_->tick_samples = tick_samples;
  clear();
}

void Sf2RegionCache::clear() {
  impl_->entries.clear();
  impl_->lru.clear();
}

size_t Sf2RegionCache::size() const { return impl_->entries.size(); }

size_t Sf2RegionCache::capacity() const { return impl_->max_entries; }

}  // namespace render
