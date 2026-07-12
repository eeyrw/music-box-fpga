#pragma once

#include "render_types.h"

#include <cstdint>
#include <map>
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

struct Sf2Data {
  std::vector<int16_t> smpl;
  std::string ifil;
  std::string isng;
  std::string inam;
  std::vector<Preset> presets;
  std::vector<Instrument> instruments;
  std::vector<Bag> preset_bags;
  std::vector<Bag> instrument_bags;
  std::vector<Generator> preset_generators;
  std::vector<Generator> instrument_generators;
  std::vector<SampleHeader> samples;
};

Sf2Data load_sf2(const std::string& path);
int select_instrument(const Sf2Data& sf2, const std::string& instrument);

Region make_region_for_preset(const Sf2Data& sf2, int program, int bank, int key,
                               int velocity, int sample_rate, int tick_samples,
                               std::vector<int16_t>& memory);
std::vector<Region> make_regions_for_preset(const Sf2Data& sf2, int program, int bank, int key,
                                            int velocity, int sample_rate, int tick_samples,
                                            std::vector<int16_t>& memory);
Region make_region_for_instrument(const Sf2Data& sf2, int inst_idx, int key,
                                   int velocity, int sample_rate, int tick_samples,
                                   std::vector<int16_t>& memory);
std::vector<Region> make_regions_for_instrument(const Sf2Data& sf2, int inst_idx, int key,
                                                int velocity, int sample_rate, int tick_samples,
                                                std::vector<int16_t>& memory);

}  // namespace render
