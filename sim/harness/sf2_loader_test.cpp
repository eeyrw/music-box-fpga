#include "sf2_loader.h"

#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void push_u16(std::vector<uint8_t>& out, uint16_t value) {
  out.push_back(uint8_t(value));
  out.push_back(uint8_t(value >> 8));
}

void push_u32(std::vector<uint8_t>& out, uint32_t value) {
  out.push_back(uint8_t(value));
  out.push_back(uint8_t(value >> 8));
  out.push_back(uint8_t(value >> 16));
  out.push_back(uint8_t(value >> 24));
}

void push_name(std::vector<uint8_t>& out, const std::string& name) {
  for (int i = 0; i < 20; ++i) out.push_back(i < int(name.size()) ? uint8_t(name[i]) : 0);
}

void push_chunk(std::vector<uint8_t>& out, const char id[4], const std::vector<uint8_t>& payload) {
  out.insert(out.end(), id, id + 4);
  push_u32(out, uint32_t(payload.size()));
  out.insert(out.end(), payload.begin(), payload.end());
  if (payload.size() & 1u) out.push_back(0);
}

std::vector<uint8_t> make_list(const char type[4], const std::vector<std::pair<std::string, std::vector<uint8_t>>>& chunks) {
  std::vector<uint8_t> payload;
  payload.insert(payload.end(), type, type + 4);
  for (const auto& c : chunks) push_chunk(payload, c.first.c_str(), c.second);
  std::vector<uint8_t> out;
  push_chunk(out, "LIST", payload);
  return out;
}

void push_phdr(std::vector<uint8_t>& out, const std::string& name, uint16_t preset,
               uint16_t bank, uint16_t bag_index) {
  push_name(out, name);
  push_u16(out, preset);
  push_u16(out, bank);
  push_u16(out, bag_index);
  push_u32(out, 0);
  push_u32(out, 0);
  push_u32(out, 0);
}

void push_inst(std::vector<uint8_t>& out, const std::string& name, uint16_t bag_index) {
  push_name(out, name);
  push_u16(out, bag_index);
}

void push_bag(std::vector<uint8_t>& out, uint16_t gen_index, uint16_t mod_index) {
  push_u16(out, gen_index);
  push_u16(out, mod_index);
}

void push_gen(std::vector<uint8_t>& out, uint16_t oper, uint16_t amount) {
  push_u16(out, oper);
  push_u16(out, amount);
}

void push_sample(std::vector<uint8_t>& out, const std::string& name, uint32_t start,
                 uint32_t end, uint32_t start_loop, uint32_t end_loop,
                 uint32_t sample_rate, uint8_t original_pitch, int8_t correction,
                 uint16_t link, uint16_t type) {
  push_name(out, name);
  push_u32(out, start);
  push_u32(out, end);
  push_u32(out, start_loop);
  push_u32(out, end_loop);
  push_u32(out, sample_rate);
  out.push_back(original_pitch);
  out.push_back(uint8_t(correction));
  push_u16(out, link);
  push_u16(out, type);
}

uint16_t bits(int16_t value) {
  return uint16_t(value);
}

std::string write_test_sf2() {
  std::vector<uint8_t> smpl;
  for (int i = 0; i < 64; ++i) push_u16(smpl, uint16_t(int16_t((i % 17) * 120 - 900)));
  for (int i = 0; i < 46; ++i) push_u16(smpl, 0);

  std::vector<uint8_t> phdr;
  push_phdr(phdr, "Preset", 0, 0, 0);
  push_phdr(phdr, "EOP", 0, 0, 2);

  std::vector<uint8_t> pbag;
  push_bag(pbag, 0, 0);
  push_bag(pbag, 1, 0);
  push_bag(pbag, 6, 0);

  std::vector<uint8_t> pgen;
  push_gen(pgen, 48, 100);             // global initialAttenuation, additive
  push_gen(pgen, 43, 0x7f00);          // local keyRange
  push_gen(pgen, 17, bits(250));       // local pan, additive with instrument pan
  push_gen(pgen, 58, 69);              // illegal at preset level, must be ignored
  push_gen(pgen, 52, bits(-5));        // local fineTune, additive
  push_gen(pgen, 41, 0);               // terminal instrument
  push_gen(pgen, 0, 0);                // terminal record

  std::vector<uint8_t> inst;
  push_inst(inst, "Inst", 0);
  push_inst(inst, "EOI", 2);

  std::vector<uint8_t> ibag;
  push_bag(ibag, 0, 0);
  push_bag(ibag, 1, 0);
  push_bag(ibag, 10, 0);

  std::vector<uint8_t> igen;
  push_gen(igen, 52, bits(10));        // global fineTune, absolute at instrument level
  push_gen(igen, 43, 0x7f00);          // local keyRange
  push_gen(igen, 17, bits(-250));      // local pan
  push_gen(igen, 58, bits(-1));        // use sample header original pitch
  push_gen(igen, 54, 1);               // continuous loop
  push_gen(igen, 0, 2);                // startAddrsOffset
  push_gen(igen, 1, bits(-4));         // endAddrsOffset
  push_gen(igen, 2, 1);                // startloopAddrsOffset
  push_gen(igen, 3, bits(-1));         // endloopAddrsOffset
  push_gen(igen, 53, 0);               // terminal sampleID
  push_gen(igen, 0, 0);                // terminal record

  std::vector<uint8_t> shdr;
  push_sample(shdr, "Sample", 0, 64, 8, 40, 48000, 60, 0, 0, 1);
  push_sample(shdr, "EOS", 0, 0, 0, 0, 0, 0, 0, 0, 0);

  std::vector<uint8_t> riff;
  riff.insert(riff.end(), {'R', 'I', 'F', 'F'});
  push_u32(riff, 0);
  riff.insert(riff.end(), {'s', 'f', 'b', 'k'});
  auto sdta = make_list("sdta", {{"smpl", smpl}});
  auto pdta = make_list("pdta", {{"phdr", phdr}, {"pbag", pbag}, {"pmod", std::vector<uint8_t>(10, 0)},
                                  {"pgen", pgen}, {"inst", inst}, {"ibag", ibag},
                                  {"imod", std::vector<uint8_t>(10, 0)}, {"igen", igen}, {"shdr", shdr}});
  riff.insert(riff.end(), sdta.begin(), sdta.end());
  riff.insert(riff.end(), pdta.begin(), pdta.end());
  uint32_t riff_size = uint32_t(riff.size() - 8);
  riff[4] = uint8_t(riff_size);
  riff[5] = uint8_t(riff_size >> 8);
  riff[6] = uint8_t(riff_size >> 16);
  riff[7] = uint8_t(riff_size >> 24);

  const std::string path = "build/sf2_loader_test.sf2";
  std::ofstream out(path, std::ios::binary);
  if (!out) throw std::runtime_error("failed to create " + path);
  out.write(reinterpret_cast<const char*>(riff.data()), riff.size());
  return path;
}

void expect_equal(int actual, int expected, const char* label) {
  if (actual != expected) {
    throw std::runtime_error(std::string(label) + " expected " + std::to_string(expected) +
                             " got " + std::to_string(actual));
  }
}

void expect_load_fails_without_pmod(const std::string& good_path) {
  std::ifstream in(good_path, std::ios::binary);
  if (!in) throw std::runtime_error("failed to reopen " + good_path);
  std::vector<uint8_t> data{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
  bool replaced = false;
  for (size_t i = 0; i + 4 <= data.size(); ++i) {
    if (data[i] == 'p' && data[i + 1] == 'm' && data[i + 2] == 'o' && data[i + 3] == 'd') {
      data[i] = 'x';
      replaced = true;
      break;
    }
  }
  if (!replaced) throw std::runtime_error("test fixture did not contain pmod");
  const std::string bad_path = "build/sf2_loader_missing_pmod.sf2";
  std::ofstream out(bad_path, std::ios::binary);
  if (!out) throw std::runtime_error("failed to create " + bad_path);
  out.write(reinterpret_cast<const char*>(data.data()), data.size());
  try {
    (void)render::load_sf2(bad_path);
  } catch (const std::runtime_error&) {
    return;
  }
  throw std::runtime_error("missing pmod chunk was not rejected");
}

}  // namespace

int main() {
  try {
    std::string path = write_test_sf2();
    expect_load_fails_without_pmod(path);
    render::Sf2Data sf2 = render::load_sf2(path);
    std::vector<int16_t> memory;
    render::Region preset = render::make_region_for_preset(sf2, 0, 0, 60, 100, 48000, 480, memory);
    int expected_phase = int(std::round(std::pow(2.0, 5.0 / 1200.0) * 65536.0));
    int expected_gain = int(std::round(0x4000 * std::pow(10.0, -100.0 / 200.0)));
    expect_equal(int(preset.phase_inc), expected_phase, "preset additive fineTune phase");
    expect_equal(preset.gain_l, expected_gain, "preset additive pan left gain");
    expect_equal(preset.gain_r, expected_gain, "preset additive pan right gain");
    expect_equal(int(preset.length), 58, "sample address offsets length");
    expect_equal(int(preset.loop_start), 7, "sample startloop offset");
    expect_equal(int(preset.loop_end), 37, "sample endloop offset");

    render::Region inst = render::make_region_for_instrument(sf2, 0, 60, 100, 48000, 480, memory);
    expect_equal(inst.gain_l, 24576, "instrument pan left gain");
    expect_equal(inst.gain_r, 8192, "instrument pan right gain");

    std::cout << "PASS: SF2 loader applies generator precedence and pan rules\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "sf2_loader_test failed: " << e.what() << "\n";
    return 1;
  }
}
