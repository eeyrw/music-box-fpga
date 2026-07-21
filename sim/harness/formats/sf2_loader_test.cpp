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

std::vector<uint8_t> make_text(const std::string& value) {
  return std::vector<uint8_t>(value.begin(), value.end());
}

std::vector<uint8_t> make_version(uint16_t major, uint16_t minor) {
  std::vector<uint8_t> out;
  push_u16(out, major);
  push_u16(out, minor);
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

void push_mod(std::vector<uint8_t>& out, uint16_t src, uint16_t dest, int16_t amount,
              uint16_t amount_src, uint16_t transform) {
  push_u16(out, src);
  push_u16(out, dest);
  push_u16(out, uint16_t(amount));
  push_u16(out, amount_src);
  push_u16(out, transform);
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
  std::vector<uint8_t> sm24;
  for (int i = 0; i < 64; ++i) push_u16(smpl, uint16_t(int16_t((i % 17) * 120 - 900)));
  for (int i = 0; i < 46; ++i) push_u16(smpl, 0);
  sm24.resize(smpl.size() / 2, 0);
  sm24[2] = 255;

  std::vector<uint8_t> phdr;
  push_phdr(phdr, "Preset", 0, 0, 0);
  push_phdr(phdr, "EOP", 0, 0, 2);

  std::vector<uint8_t> pbag;
  push_bag(pbag, 0, 0);
  push_bag(pbag, 1, 0);
  push_bag(pbag, 7, 0);

  std::vector<uint8_t> pgen;
  push_gen(pgen, 48, 100);             // global initialAttenuation, additive
  push_gen(pgen, 43, 0x7f00);          // local keyRange
  push_gen(pgen, 17, bits(250));       // local pan, additive with instrument pan
  push_gen(pgen, 58, 69);              // illegal at preset level, must be ignored
  push_gen(pgen, 52, bits(-5));        // local fineTune, additive
  push_gen(pgen, 34, bits(12000));     // local attackVolEnv, additive with default
  push_gen(pgen, 41, 0);               // terminal instrument
  push_gen(pgen, 0, 0);                // terminal record

  std::vector<uint8_t> inst;
  push_inst(inst, "Inst", 0);
  push_inst(inst, "ClampInst", 2);
  push_inst(inst, "EOI", 3);

  std::vector<uint8_t> ibag;
  push_bag(ibag, 0, 0);
  push_bag(ibag, 1, 0);
  push_bag(ibag, 20, 0);
  push_bag(ibag, 23, 0);

  std::vector<uint8_t> igen;
  push_gen(igen, 52, bits(10));        // global fineTune, absolute at instrument level
  push_gen(igen, 43, 0x7f00);          // local keyRange
  push_gen(igen, 17, bits(-250));      // local pan
  push_gen(igen, 58, bits(-1));        // use sample header original pitch
  push_gen(igen, 54, 1);               // continuous loop
  push_gen(igen, 8, 6900);             // initialFilterFc, enables biquad LPF
  push_gen(igen, 9, 60);               // initialFilterQ
  push_gen(igen, 5, bits(50));         // modLfoToPitch
  push_gen(igen, 6, bits(25));         // vibLfoToPitch
  push_gen(igen, 7, bits(-10));        // modEnvToPitch
  push_gen(igen, 10, bits(1200));      // modLfoToFilterFc
  push_gen(igen, 11, bits(-600));      // modEnvToFilterFc
  // No freqModLFO: SF2 default is 0 cents, or 8.176 Hz.
  push_gen(igen, 24, bits(1200));      // freqVibLFO, 16.352 Hz
  push_gen(igen, 26, bits(-1200));     // attackModEnv
  push_gen(igen, 29, 600);             // sustainModEnv, 40% of peak
  push_gen(igen, 0, 2);                // startAddrsOffset
  push_gen(igen, 1, bits(-4));         // endAddrsOffset
  push_gen(igen, 2, 1);                // startloopAddrsOffset
  push_gen(igen, 3, bits(-1));         // endloopAddrsOffset
  push_gen(igen, 53, 0);               // terminal sampleID
  push_gen(igen, 48, bits(-120));      // negative attenuation clamps to 0 cB
  push_gen(igen, 17, 0);               // centered pan
  push_gen(igen, 53, 0);               // terminal sampleID
  push_gen(igen, 0, 0);                // terminal record

  std::vector<uint8_t> shdr;
  push_sample(shdr, "Sample", 0, 64, 8, 40, 48000, 60, 0, 0, 1);
  push_sample(shdr, "EOS", 0, 0, 0, 0, 0, 0, 0, 0, 0);

  std::vector<uint8_t> riff;
  riff.insert(riff.end(), {'R', 'I', 'F', 'F'});
  push_u32(riff, 0);
  riff.insert(riff.end(), {'s', 'f', 'b', 'k'});
  auto info = make_list("INFO", {{"ifil", make_version(2, 4)}, {"isng", make_text("EMU8000")},
                                  {"INAM", make_text("Unit Test SF2")}});
  auto sdta = make_list("sdta", {{"smpl", smpl}, {"sm24", sm24}});
  auto pdta = make_list("pdta", {{"phdr", phdr}, {"pbag", pbag}, {"pmod", std::vector<uint8_t>(10, 0)},
                                   {"pgen", pgen}, {"inst", inst}, {"ibag", ibag},
                                   {"imod", std::vector<uint8_t>(10, 0)}, {"igen", igen}, {"shdr", shdr}});
  riff.insert(riff.end(), info.begin(), info.end());
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

std::string write_stereo_sf2() {
  std::vector<uint8_t> smpl;
  for (int i = 0; i < 160; ++i) push_u16(smpl, uint16_t(int16_t(i * 64 - 4096)));
  for (int i = 0; i < 46; ++i) push_u16(smpl, 0);

  std::vector<uint8_t> phdr;
  push_phdr(phdr, "StereoPreset", 0, 0, 0);
  push_phdr(phdr, "EOP", 0, 0, 1);

  std::vector<uint8_t> pbag;
  push_bag(pbag, 0, 0);
  push_bag(pbag, 1, 1);

  std::vector<uint8_t> pgen;
  push_gen(pgen, 41, 0);
  push_gen(pgen, 0, 0);

  std::vector<uint8_t> pmod;
  push_mod(pmod, 0x0081, 6, 25, 0, 0);  // CC1 -> vibLfoToPitch, additive to default 50.
  push_mod(pmod, 0, 0, 0, 0, 0);

  std::vector<uint8_t> inst;
  push_inst(inst, "StereoInst", 0);
  push_inst(inst, "EOI", 2);

  std::vector<uint8_t> ibag;
  push_bag(ibag, 0, 0);
  push_bag(ibag, 4, 0);
  push_bag(ibag, 9, 0);

  std::vector<uint8_t> igen;
  push_gen(igen, 43, 0x7f00);
  push_gen(igen, 0, 2);
  push_gen(igen, 52, 0);
  push_gen(igen, 53, 0);
  push_gen(igen, 43, 0x7f00);
  push_gen(igen, 0, 5);
  push_gen(igen, 52, 1200);
  push_gen(igen, 5, 777);
  push_gen(igen, 53, 1);
  push_gen(igen, 0, 0);

  std::vector<uint8_t> shdr;
  push_sample(shdr, "Left", 0, 64, 8, 40, 48000, 60, 0, 1, 4);
  push_sample(shdr, "Right", 64, 128, 72, 104, 48000, 60, 0, 0, 2);
  push_sample(shdr, "EOS", 0, 0, 0, 0, 0, 0, 0, 0, 0);

  std::vector<uint8_t> riff;
  riff.insert(riff.end(), {'R', 'I', 'F', 'F'});
  push_u32(riff, 0);
  riff.insert(riff.end(), {'s', 'f', 'b', 'k'});
  auto info = make_list("INFO", {{"ifil", make_version(2, 4)}, {"isng", make_text("EMU8000")},
                                  {"INAM", make_text("Stereo SF2")}});
  auto sdta = make_list("sdta", {{"smpl", smpl}});
  auto pdta = make_list("pdta", {{"phdr", phdr}, {"pbag", pbag}, {"pmod", pmod},
                                  {"pgen", pgen}, {"inst", inst}, {"ibag", ibag},
                                  {"imod", std::vector<uint8_t>(10, 0)}, {"igen", igen}, {"shdr", shdr}});
  riff.insert(riff.end(), info.begin(), info.end());
  riff.insert(riff.end(), sdta.begin(), sdta.end());
  riff.insert(riff.end(), pdta.begin(), pdta.end());
  uint32_t riff_size = uint32_t(riff.size() - 8);
  riff[4] = uint8_t(riff_size);
  riff[5] = uint8_t(riff_size >> 8);
  riff[6] = uint8_t(riff_size >> 16);
  riff[7] = uint8_t(riff_size >> 24);

  const std::string path = "build/sf2_loader_stereo_test.sf2";
  std::ofstream out(path, std::ios::binary);
  if (!out) throw std::runtime_error("failed to create " + path);
  out.write(reinterpret_cast<const char*>(riff.data()), riff.size());
  return path;
}

std::string write_unlinked_hard_pan_stereo_sf2() {
  std::vector<uint8_t> smpl;
  for (int i = 0; i < 192; ++i) push_u16(smpl, uint16_t(int16_t(i * 32 - 2048)));
  for (int i = 0; i < 46; ++i) push_u16(smpl, 0);

  std::vector<uint8_t> phdr;
  push_phdr(phdr, "UnlinkedPreset", 0, 0, 0);
  push_phdr(phdr, "EOP", 0, 0, 1);

  std::vector<uint8_t> pbag;
  push_bag(pbag, 0, 0);
  push_bag(pbag, 1, 0);

  std::vector<uint8_t> pgen;
  push_gen(pgen, 41, 0);
  push_gen(pgen, 0, 0);

  std::vector<uint8_t> inst;
  push_inst(inst, "UnlinkedStereoInst", 0);
  push_inst(inst, "EOI", 2);

  std::vector<uint8_t> ibag;
  push_bag(ibag, 0, 0);
  push_bag(ibag, 5, 0);
  push_bag(ibag, 10, 0);

  std::vector<uint8_t> igen;
  push_gen(igen, 43, 0x7f00);
  push_gen(igen, 17, bits(-500));
  push_gen(igen, 54, 1);
  push_gen(igen, 52, 0);
  push_gen(igen, 53, 0);
  push_gen(igen, 43, 0x7f00);
  push_gen(igen, 17, bits(500));
  push_gen(igen, 54, 1);
  push_gen(igen, 52, 1200);
  push_gen(igen, 53, 1);
  push_gen(igen, 0, 0);

  std::vector<uint8_t> shdr;
  // Some real-world SF2s mark these as stereo halves but leave sampleLink
  // pointing at an unrelated sample. The instrument zones' hard pan is the
  // useful stereo pairing signal in that case.
  push_sample(shdr, "BrokenLinkL", 0, 64, 8, 40, 48000, 60, 0, 2, 4);
  push_sample(shdr, "BrokenLinkR", 64, 128, 72, 104, 48000, 60, 0, 2, 2);
  push_sample(shdr, "WrongLink", 128, 192, 136, 168, 48000, 60, 0, 0, 1);
  push_sample(shdr, "EOS", 0, 0, 0, 0, 0, 0, 0, 0, 0);

  std::vector<uint8_t> riff;
  riff.insert(riff.end(), {'R', 'I', 'F', 'F'});
  push_u32(riff, 0);
  riff.insert(riff.end(), {'s', 'f', 'b', 'k'});
  auto info = make_list("INFO", {{"ifil", make_version(2, 4)}, {"isng", make_text("EMU8000")},
                                  {"INAM", make_text("Unlinked Stereo SF2")}});
  auto sdta = make_list("sdta", {{"smpl", smpl}});
  auto pdta = make_list("pdta", {{"phdr", phdr}, {"pbag", pbag}, {"pmod", std::vector<uint8_t>(10, 0)},
                                  {"pgen", pgen}, {"inst", inst}, {"ibag", ibag},
                                  {"imod", std::vector<uint8_t>(10, 0)}, {"igen", igen}, {"shdr", shdr}});
  riff.insert(riff.end(), info.begin(), info.end());
  riff.insert(riff.end(), sdta.begin(), sdta.end());
  riff.insert(riff.end(), pdta.begin(), pdta.end());
  uint32_t riff_size = uint32_t(riff.size() - 8);
  riff[4] = uint8_t(riff_size);
  riff[5] = uint8_t(riff_size >> 8);
  riff[6] = uint8_t(riff_size >> 16);
  riff[7] = uint8_t(riff_size >> 24);

  const std::string path = "build/sf2_loader_unlinked_hard_pan_stereo_test.sf2";
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
    if (sf2.ifil != "2.4" || sf2.isng != "EMU8000" || sf2.inam != "Unit Test SF2") {
      throw std::runtime_error("INFO metadata was not parsed correctly");
    }
    std::vector<int16_t> memory = sf2.file_words;
    render::Region preset = render::make_region_for_preset(sf2, 0, 0, 60, 100, 48000, 480, memory);
    int expected_phase = int(std::round(std::pow(2.0, 5.0 / 1200.0) * render::kPhaseFracScale));
    int expected_gain = int(std::round(0x4000 * std::pow(10.0, -100.0 / 200.0)));
    expect_equal(int(preset.phase_inc), expected_phase, "preset additive fineTune phase");
    expect_equal(preset.gain_l, expected_gain, "preset additive pan left gain");
    expect_equal(preset.gain_r, expected_gain, "preset additive pan right gain");
    expect_equal(int(preset.length), 58, "sample address offsets length");
    expect_equal(int(preset.length_r), 58, "mono right length mirrors left length");
    expect_equal(int(preset.base_addr), int(sf2.smpl_word_offset + 2), "absolute smpl base address");
    expect_equal(int(preset.base_addr_r), int(preset.base_addr), "mono right base mirrors left base");
    expect_equal(int(preset.loop_start), 7, "sample startloop offset");
    expect_equal(int(preset.loop_start_r), 7, "mono right startloop mirrors left startloop");
    expect_equal(int(preset.loop_end), 37, "sample endloop offset");
    expect_equal(int(preset.loop_end_r), 37, "mono right endloop mirrors left endloop");
    expect_equal(preset.attack_ticks, 100, "preset attackVolEnv adds to default");
    expect_equal(preset.mod_env_sustain_level, int(std::round(render::kQ15Full * 0.4)),
                 "modulation envelope sustain percent");
    expect_equal(sf2.smpl.at(2), -660, "sm24 ignored by 16-bit renderer");
    expect_equal(int(memory.size()), int(sf2.file_words.size()), "region build does not repack wave memory");
    if (!preset.filter_enable || preset.filter_b0 <= 0 || preset.filter_b1 <= 0 || preset.filter_b2 <= 0) {
      throw std::runtime_error("SF2 filter generators did not produce enabled biquad feed-forward coefficients");
    }
    expect_equal(preset.mod_lfo_to_pitch, 50, "modLfoToPitch amount");
    expect_equal(preset.vib_lfo_to_pitch, 25, "vibLfoToPitch amount");
    expect_equal(preset.mod_env_to_pitch, -10, "modEnvToPitch amount");
    expect_equal(preset.mod_lfo_to_filter_fc, 1200, "modLfoToFilterFc amount");
    expect_equal(preset.mod_env_to_filter_fc, -600, "modEnvToFilterFc amount");
    if (preset.mod_lfo_step == 0 || preset.vib_lfo_step <= preset.mod_lfo_step) {
      throw std::runtime_error("LFO frequency generators did not produce ordered phase steps");
    }
    if (preset.mod_env_attack_step <= 0 || preset.mod_env_attack_step >= render::kQ15Full) {
      throw std::runtime_error("modulation envelope attack generator was not converted to a finite step");
    }

    render::Region inst = render::make_region_for_instrument(sf2, 0, 60, 100, 48000, 480, memory);
    expect_equal(inst.gain_l, 24576, "instrument pan left gain");
    expect_equal(inst.gain_r, 8192, "instrument pan right gain");
    render::Region clamped = render::make_region_for_instrument(sf2, 1, 60, 100, 48000, 480, memory);
    expect_equal(clamped.gain_l, 0x4000, "negative initial attenuation clamps left gain");
    expect_equal(clamped.gain_r, 0x4000, "negative initial attenuation clamps right gain");

    render::Sf2Data stereo_sf2 = render::load_sf2(write_stereo_sf2());
    std::vector<int16_t> stereo_memory = stereo_sf2.file_words;
    auto stereo_regions = render::make_regions_for_preset(stereo_sf2, 0, 0, 60, 100, 48000, 480, stereo_memory);
    expect_equal(int(stereo_regions.size()), 1, "linked stereo pair creates one region");
    const auto& stereo = stereo_regions.at(0);
    if (!stereo.stereo) throw std::runtime_error("linked stereo pair was not marked stereo");
    expect_equal(stereo.sample_left == "Left" ? 1 : 0, 1, "linked stereo left sample name");
    expect_equal(stereo.sample_right == "Right" ? 1 : 0, 1, "linked stereo right sample name");
    expect_equal(int(stereo.base_addr), int(stereo_sf2.smpl_word_offset + 2),
                 "linked stereo left zone start offset");
    expect_equal(int(stereo.base_addr_r), int(stereo_sf2.smpl_word_offset + 69),
                 "linked stereo right zone start offset");
    expect_equal(int(stereo.phase_inc), render::kPhaseFracScale * 2,
                 "linked stereo phase uses right sample pitch generators");
    expect_equal(stereo.mod_lfo_to_pitch, 777, "linked stereo pitch generator uses right zone");
    bool saw_cc1 = false;
    for (const auto& mod : stereo.modulators) {
      if (mod.src == 0x0081 && mod.dest == 6) {
        expect_equal(mod.amount, 75, "pmod CC1 adds to default vibrato modulator");
        saw_cc1 = true;
      }
    }
    if (!saw_cc1) throw std::runtime_error("pmod CC1 vibrato modulator was not preserved");

    stereo_sf2.samples[0].sample_link = 2;
    stereo_sf2.samples[1].sample_link = 0;
    stereo_regions = render::make_regions_for_preset(stereo_sf2, 0, 0, 60, 100, 48000, 480, stereo_memory);
    expect_equal(int(stereo_regions.size()), 2, "invalid linked stereo pair keeps both mono zones");
    for (const auto& region : stereo_regions) {
      if (region.stereo) throw std::runtime_error("invalid linked stereo pair was still marked stereo");
      if (region.sample_left != "Left" && region.sample_left != "Right") {
        throw std::runtime_error("invalid linked stereo pair selected an unrelated sample");
      }
    }

    render::Sf2Data unlinked_sf2 = render::load_sf2(write_unlinked_hard_pan_stereo_sf2());
    std::vector<int16_t> unlinked_memory = unlinked_sf2.file_words;
    auto unlinked_regions = render::make_regions_for_preset(unlinked_sf2, 0, 0, 60, 100, 48000, 480,
                                                            unlinked_memory);
    expect_equal(int(unlinked_regions.size()), 1, "hard-panned unlinked stereo creates one preset region");
    const auto& unlinked = unlinked_regions.at(0);
    if (!unlinked.stereo) throw std::runtime_error("hard-panned unlinked pair was not marked stereo");
    expect_equal(unlinked.sample_left == "BrokenLinkL" ? 1 : 0, 1, "hard-panned left sample name");
    expect_equal(unlinked.sample_right == "BrokenLinkR" ? 1 : 0, 1, "hard-panned right sample name");
    expect_equal(int(unlinked.base_addr), int(unlinked_sf2.smpl_word_offset), "hard-panned left base");
    expect_equal(int(unlinked.base_addr_r), int(unlinked_sf2.smpl_word_offset + 64), "hard-panned right base");
    expect_equal(int(unlinked.length), 64, "hard-panned left length");
    expect_equal(int(unlinked.length_r), 64, "hard-panned right length");
    expect_equal(int(unlinked.phase_inc), render::kPhaseFracScale * 2,
                 "hard-panned unlinked stereo uses right zone pitch generators");
    expect_equal(unlinked.pan, 0, "hard-panned unlinked stereo centers region pan");
    expect_equal(unlinked.gain_l, 0x4000, "hard-panned unlinked stereo left gain");
    expect_equal(unlinked.gain_r, 0x4000, "hard-panned unlinked stereo right gain");

    auto unlinked_inst_regions = render::make_regions_for_instrument(unlinked_sf2, 0, 60, 100, 48000, 480,
                                                                     unlinked_memory);
    expect_equal(int(unlinked_inst_regions.size()), 1,
                 "hard-panned unlinked stereo creates one forced-instrument region");
    if (!unlinked_inst_regions.at(0).stereo) {
      throw std::runtime_error("forced-instrument hard-panned pair was not marked stereo");
    }

    std::cout << "PASS: SF2 loader applies generator precedence and pan rules\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "sf2_loader_test failed: " << e.what() << "\n";
    return 1;
  }
}
