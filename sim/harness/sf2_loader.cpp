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
constexpr int GEN_ATTACK_VOL_ENV = 34;
constexpr int GEN_DECAY_VOL_ENV = 36;
constexpr int GEN_SUSTAIN_VOL_ENV = 37;
constexpr int GEN_RELEASE_VOL_ENV = 38;
constexpr int GEN_INSTRUMENT = 41;
constexpr int GEN_KEY_RANGE = 43;
constexpr int GEN_VEL_RANGE = 44;
constexpr int GEN_INITIAL_ATTENUATION = 48;
constexpr int GEN_COARSE_TUNE = 51;
constexpr int GEN_FINE_TUNE = 52;
constexpr int GEN_SAMPLE_ID = 53;
constexpr int GEN_SAMPLE_MODES = 54;
constexpr int GEN_OVERRIDING_ROOT_KEY = 58;

constexpr int SAMPLE_MONO = 1;
constexpr int SAMPLE_RIGHT = 2;
constexpr int SAMPLE_LEFT = 4;

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

Zone generators_for_zone(const std::vector<Generator>& gens, int start, int end) {
  // Convert the flat generator list referenced by a bag range into a lookup map.
  // Later duplicate operators replace earlier ones, matching the "last value in
  // the zone wins" behavior used by the rest of the loader.
  Zone zone;
  for (int i = start; i < end; ++i) zone[gens.at(i).oper] = gens.at(i).amount;
  return zone;
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
  return kr.first <= key && key <= kr.second && vr.first <= velocity && velocity <= vr.second;
}

std::vector<Zone> instrument_zones(const Sf2Data& sf2, int inst_index) {
  int start = sf2.instruments.at(inst_index).bag_index;
  int end = sf2.instruments.at(inst_index + 1).bag_index;
  std::vector<Zone> zones;
  Zone global;
  for (int bag = start; bag < end; ++bag) {
    Zone z = generators_for_zone(sf2.instrument_generators,
                                 sf2.instrument_bags.at(bag).gen_index,
                                 sf2.instrument_bags.at(bag + 1).gen_index);
    if (!z.count(GEN_SAMPLE_ID)) {
      // An instrument bag without sampleID is a global instrument zone. It
      // supplies defaults inherited by later sample zones in this instrument.
      for (const auto& kv : z) global[kv.first] = kv.second;
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
    Zone z = generators_for_zone(sf2.preset_generators,
                                 sf2.preset_bags.at(bag).gen_index,
                                 sf2.preset_bags.at(bag + 1).gen_index);
    if (!z.count(GEN_INSTRUMENT)) {
      // Same pattern as instruments: a preset bag without instrument is a global
      // preset zone and contributes defaults to subsequent instrument zones.
      for (const auto& kv : z) global[kv.first] = kv.second;
    } else {
      Zone merged = global;
      for (const auto& kv : z) merged[kv.first] = kv.second;
      zones.push_back(merged);
    }
  }
  return zones;
}

Zone select_zone_for_velocity(const std::vector<Zone>& zones, int key, int velocity) {
  // Prefer an exact key+velocity match. If velocity splits are missing or odd,
  // fall back to a key-only match, then to the first zone. This keeps rendering
  // useful for imperfect SoundFonts while still honoring normal splits.
  for (const auto& z : zones) if (zone_matches(z, key, velocity)) return z;
  for (const auto& z : zones) {
    auto kr = key_range(z);
    if (kr.first <= key && key <= kr.second) return z;
  }
  if (!zones.empty()) return zones.front();
  throw std::runtime_error("instrument has no sample zones");
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
  int root_key = zone.count(GEN_OVERRIDING_ROOT_KEY) ? zone.at(GEN_OVERRIDING_ROOT_KEY)
                                                     : sample.original_pitch;
  if (root_key == 255) root_key = sample.original_pitch;
  int cents = ((key - root_key) * 100 + sample.pitch_correction +
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
  int left = pan < 0 ? int(std::round(0x4000 * double(500 - pan) / 500.0)) : 0x4000;
  int right = pan > 0 ? int(std::round(0x4000 * double(500 + pan) / 500.0)) : 0x4000;
  int atten = zone.count(GEN_INITIAL_ATTENUATION) ? zone.at(GEN_INITIAL_ATTENUATION) : 0;
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

void volume_envelope(const Zone& zone, int tick_samples, int sample_rate,
                     int& sustain, int& attack, int& decay, int& release) {
  // Gather the subset of SF2 volume-envelope generators currently modeled by
  // the harness. Hold is not modeled yet; attack, decay, sustain, and release
  // are enough to exercise runtime envelope register writes.
  double a = timecents_to_seconds(zone.count(GEN_ATTACK_VOL_ENV) ? zone.at(GEN_ATTACK_VOL_ENV) : 0,
                                  zone.count(GEN_ATTACK_VOL_ENV), -12000);
  double d = timecents_to_seconds(zone.count(GEN_DECAY_VOL_ENV) ? zone.at(GEN_DECAY_VOL_ENV) : 0,
                                  zone.count(GEN_DECAY_VOL_ENV), -12000);
  double r = timecents_to_seconds(zone.count(GEN_RELEASE_VOL_ENV) ? zone.at(GEN_RELEASE_VOL_ENV) : 0,
                                  zone.count(GEN_RELEASE_VOL_ENV), -12000);
  sustain = centibels_to_level(zone.count(GEN_SUSTAIN_VOL_ENV) ? zone.at(GEN_SUSTAIN_VOL_ENV) : 0);
  attack = envelope_step(a, tick_samples, sample_rate);
  decay = envelope_step(d, tick_samples, sample_rate);
  release = envelope_step(r, tick_samples, sample_rate);
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
  int t = sanitize_sample_type(s.sample_type);
  if (t == SAMPLE_LEFT && s.sample_link >= 0 && s.sample_link < int(sf2.samples.size())) return {selected, s.sample_link};
  if (t == SAMPLE_RIGHT && s.sample_link >= 0 && s.sample_link < int(sf2.samples.size())) return {s.sample_link, selected};
  return {selected, -1};
}

std::vector<int16_t> sample_pcm(const Sf2Data& sf2, const SampleHeader& h) {
  // SampleHeader offsets are word indexes into the smpl chunk. Clamp corrupt or
  // out-of-range values to the loaded PCM array so malformed SF2 data fails
  // softly where possible.
  uint32_t start = std::min<uint32_t>(h.start, sf2.smpl.size());
  uint32_t end = std::min<uint32_t>(h.end, sf2.smpl.size());
  if (end < start) end = start;
  return std::vector<int16_t>(sf2.smpl.begin() + start, sf2.smpl.begin() + end);
}

std::vector<int16_t> build_wave_words(const Sf2Data& sf2, int selected_sample, Region& region) {
  // Build the exact wave-memory words consumed by wavetable_core and fill the
  // region metadata that will later be committed into a voice slot. The RTL uses
  // frame indexes for length and loop points; stereo consumes two memory words
  // per frame while mono consumes one.
  auto rel = [](uint32_t value, uint32_t base) -> uint32_t { return value > base ? value - base : 0; };
  auto pair = linked_pair(sf2, selected_sample);
  const auto& left = sf2.samples.at(pair.first);
  std::vector<int16_t> left_pcm = sample_pcm(sf2, left);
  region.sample_left = left.name;

  // SF2 stereo is usually two linked mono sample headers. Convert that pair to
  // the RTL memory contract: left0, right0, left1, right1, ...
  if (pair.second >= 0 && sanitize_sample_type(sf2.samples.at(pair.second).sample_type) != SAMPLE_MONO) {
    const auto& right = sf2.samples.at(pair.second);
    std::vector<int16_t> right_pcm = sample_pcm(sf2, right);
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
    region.loop_start = std::min<uint32_t>({rel(left.start_loop, left.start), rel(right.start_loop, right.start), frames ? frames - 1 : 0});
    region.loop_end = std::max<uint32_t>(region.loop_start + 1, std::min<uint32_t>({rel(left.end_loop, left.start), rel(right.end_loop, right.start), frames}));
    return words;
  }

  uint32_t frames = std::min<uint32_t>(uint32_t(left_pcm.size()), 65535u);
  std::vector<int16_t> words(left_pcm.begin(), left_pcm.begin() + frames);
  region.stereo = false;
  region.length = frames;
  region.loop_start = std::min<uint32_t>(rel(left.start_loop, left.start), frames ? frames - 1 : 0);
  region.loop_end = std::max<uint32_t>(region.loop_start + 1, std::min<uint32_t>(rel(left.end_loop, left.start), frames));
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
  auto sdta = list_chunks(find_list_chunk(data, "sdta"));
  auto pdta = list_chunks(find_list_chunk(data, "pdta"));
  Sf2Data sf2;
  const auto& smpl = sdta.at("smpl");
  for (size_t i = 0; i + 2 <= smpl.size(); i += 2) sf2.smpl.push_back(int16_t(read_u16le(smpl, i)));
  sf2.presets = parse_presets(pdta.at("phdr"));
  sf2.instruments = parse_instruments(pdta.at("inst"));
  sf2.preset_bags = parse_bags(pdta.at("pbag"));
  sf2.instrument_bags = parse_bags(pdta.at("ibag"));
  sf2.preset_generators = parse_generators(pdta.at("pgen"));
  sf2.instrument_generators = parse_generators(pdta.at("igen"));
  sf2.samples = parse_samples(pdta.at("shdr"));
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
  // Full MIDI mode starts at the channel program/bank, selects a preset zone,
  // follows that zone to an instrument, then merges preset and instrument
  // generators. Instrument generators override preset defaults for the final
  // playable sample region.
  int preset_idx = select_preset(sf2, program, bank);
  Zone pzone = select_zone_for_velocity(preset_zones(sf2, preset_idx), key, velocity);
  int inst_idx = pzone.at(GEN_INSTRUMENT);
  Zone izone = select_zone_for_velocity(instrument_zones(sf2, inst_idx), key, velocity);
  Zone zone = pzone;
  for (const auto& kv : izone) zone[kv.first] = kv.second;
  int sample_id = zone.at(GEN_SAMPLE_ID);

  Region r;
  r.key = key;
  r.program = program;
  r.bank = bank;
  r.preset = sf2.presets.at(preset_idx).name;
  r.instrument = sf2.instruments.at(inst_idx).name;
  r.base_addr = uint32_t(memory.size());
  // Append this region's PCM words to one shared memory image. base_addr records
  // where the RTL voice should start fetching for this region.
  auto words = build_wave_words(sf2, sample_id, r);
  const auto& left = sf2.samples.at(linked_pair(sf2, sample_id).first);
  r.phase_inc = phase_inc_for_key(key, zone, left, sample_rate);
  auto gains = pan_gains(zone);
  r.gain_l = gains.first;
  r.gain_r = gains.second;
  r.loop_mode = loop_mode_from_zone(zone);
  volume_envelope(zone, tick_samples, sample_rate, r.sustain_level, r.attack_step, r.decay_step, r.release_step);
  memory.insert(memory.end(), words.begin(), words.end());
  return r;
}

Region make_region_for_instrument(const Sf2Data& sf2, int inst_idx, int key,
                                   int velocity, int sample_rate, int tick_samples,
                                   std::vector<int16_t>& memory) {
  // Forced-instrument mode skips preset lookup. This is useful for debugging a
  // specific SF2 instrument because MIDI program and bank messages cannot change
  // the selected sample set.
  Zone zone = select_zone_for_velocity(instrument_zones(sf2, inst_idx), key, velocity);
  int sample_id = zone.at(GEN_SAMPLE_ID);
  Region r;
  r.key = key;
  r.instrument = sf2.instruments.at(inst_idx).name;
  r.preset = r.instrument;
  r.base_addr = uint32_t(memory.size());
  auto words = build_wave_words(sf2, sample_id, r);
  const auto& left = sf2.samples.at(linked_pair(sf2, sample_id).first);
  r.phase_inc = phase_inc_for_key(key, zone, left, sample_rate);
  r.gain_l = 0x4000;
  r.gain_r = 0x4000;
  r.loop_mode = loop_mode_from_zone(zone);
  volume_envelope(zone, tick_samples, sample_rate, r.sustain_level, r.attack_step, r.decay_step, r.release_step);
  memory.insert(memory.end(), words.begin(), words.end());
  return r;
}

}  // namespace render
