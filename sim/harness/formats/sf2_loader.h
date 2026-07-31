#pragma once

#include "render_types.h"

#include <cstdint>
#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace render {

struct Preset { std::string name; int preset = 0; int bank = 0; int bag_index = 0; };
struct Instrument { std::string name; int bag_index = 0; };
struct Bag { int gen_index = 0; int mod_index = 0; };
struct Generator { int oper = 0; int amount = 0; };
struct SampleHeader {
  std::string name;
  uint32_t start = 0;
  uint32_t end = 0;
  uint32_t start_loop = 0;
  uint32_t end_loop = 0;
  uint32_t sample_rate = 0;
  int original_pitch = 0;
  int pitch_correction = 0;
  int sample_link = 0;
  int sample_type = 0;
};

struct Sf2CompiledData;

struct Sf2Data {
  std::vector<int16_t> file_words;
  uint32_t smpl_word_offset = 0;
  uint32_t smpl_word_count = 0;
  std::string ifil;
  std::string isng;
  std::string inam;
  std::vector<Preset> presets;
  std::vector<Instrument> instruments;
  std::vector<Bag> preset_bags;
  std::vector<Bag> instrument_bags;
  std::vector<Generator> preset_generators;
  std::vector<Generator> instrument_generators;
  std::vector<Sf2Modulator> preset_modulators;
  std::vector<Sf2Modulator> instrument_modulators;
  std::vector<SampleHeader> samples;
  std::shared_ptr<const Sf2CompiledData> compiled;
};

struct Sf2LoaderStats {
  size_t retained_bytes = 0;
  size_t compiled_retained_bytes = 0;
  size_t compiled_preset_candidate_count = 0;
  size_t compiled_instrument_candidate_count = 0;
  size_t preset_count = 0;
  size_t instrument_count = 0;
  size_t preset_bag_count = 0;
  size_t instrument_bag_count = 0;
  size_t preset_generator_count = 0;
  size_t instrument_generator_count = 0;
  size_t preset_modulator_count = 0;
  size_t instrument_modulator_count = 0;
  size_t sample_count = 0;
};

Sf2Data load_sf2(const std::string& path);
Sf2LoaderStats sf2_loader_stats(const Sf2Data& sf2);
int select_instrument(const Sf2Data& sf2, const std::string& instrument);

class Sf2RegionCache {
 public:
  Sf2RegionCache(const Sf2Data& sf2, int sample_rate, int tick_samples,
                 size_t capacity = 4096);
  ~Sf2RegionCache();
  Sf2RegionCache(const Sf2RegionCache&) = delete;
  Sf2RegionCache& operator=(const Sf2RegionCache&) = delete;

  std::shared_ptr<const std::vector<Region>> regions_for_preset(
      int program, int bank, int key, int velocity);
  std::shared_ptr<const std::vector<Region>> regions_for_instrument(
      int instrument, int key, int velocity);
  void set_output_config(int sample_rate, int tick_samples);
  void clear();
  size_t size() const;
  size_t capacity() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

Region make_region_for_preset(const Sf2Data& sf2, int program, int bank, int key,
                               int velocity, int sample_rate, int tick_samples);
std::vector<Region> make_regions_for_preset(const Sf2Data& sf2, int program, int bank, int key,
                                            int velocity, int sample_rate, int tick_samples);
Region make_region_for_instrument(const Sf2Data& sf2, int inst_idx, int key,
                                   int velocity, int sample_rate, int tick_samples);
std::vector<Region> make_regions_for_instrument(const Sf2Data& sf2, int inst_idx, int key,
                                                int velocity, int sample_rate, int tick_samples);

}  // namespace render
