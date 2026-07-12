#include "render_support.h"

#include <cstdint>
#include <fstream>
#include <iostream>
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

void push_bag(std::vector<uint8_t>& out, uint16_t gen_index) {
  push_u16(out, gen_index);
  push_u16(out, 0);
}

void push_gen(std::vector<uint8_t>& out, uint16_t oper, uint16_t amount) {
  push_u16(out, oper);
  push_u16(out, amount);
}

void push_sample(std::vector<uint8_t>& out, const std::string& name, uint32_t start,
                 uint32_t end, uint8_t original_pitch) {
  push_name(out, name);
  push_u32(out, start);
  push_u32(out, end);
  push_u32(out, start);
  push_u32(out, end);
  push_u32(out, 48000);
  out.push_back(original_pitch);
  out.push_back(0);
  push_u16(out, 0);
  push_u16(out, 1);
}

uint16_t range_amount(uint8_t low, uint8_t high) {
  return uint16_t(low) | (uint16_t(high) << 8);
}

std::string write_percussion_sf2() {
  std::vector<uint8_t> smpl;
  for (int i = 0; i < 32; ++i) push_u16(smpl, uint16_t(int16_t((i + 1) * 100)));
  for (int i = 0; i < 46; ++i) push_u16(smpl, 0);

  std::vector<uint8_t> phdr;
  push_phdr(phdr, "Melodic", 0, 0, 0);
  push_phdr(phdr, "Drums", 0, 128, 2);
  push_phdr(phdr, "EOP", 0, 0, 3);

  std::vector<uint8_t> pbag;
  push_bag(pbag, 0);
  push_bag(pbag, 2);
  push_bag(pbag, 4);
  push_bag(pbag, 6);

  std::vector<uint8_t> pgen;
  push_gen(pgen, 43, range_amount(60, 60));
  push_gen(pgen, 41, 0);
  push_gen(pgen, 43, range_amount(60, 60));
  push_gen(pgen, 41, 2);
  push_gen(pgen, 43, range_amount(35, 35));
  push_gen(pgen, 41, 1);
  push_gen(pgen, 0, 0);

  std::vector<uint8_t> inst;
  push_inst(inst, "MelodicInst", 0);
  push_inst(inst, "DrumInst", 1);
  push_inst(inst, "HighOnly", 2);
  push_inst(inst, "EOI", 3);

  std::vector<uint8_t> ibag;
  push_bag(ibag, 0);
  push_bag(ibag, 2);
  push_bag(ibag, 4);
  push_bag(ibag, 6);

  std::vector<uint8_t> igen;
  push_gen(igen, 43, range_amount(60, 60));
  push_gen(igen, 53, 0);
  push_gen(igen, 43, range_amount(35, 35));
  push_gen(igen, 53, 1);
  push_gen(igen, 43, range_amount(88, 88));
  push_gen(igen, 53, 0);
  push_gen(igen, 0, 0);

  std::vector<uint8_t> shdr;
  push_sample(shdr, "PianoC", 0, 16, 60);
  push_sample(shdr, "Kick", 16, 32, 35);
  push_sample(shdr, "EOS", 0, 0, 0);

  std::vector<uint8_t> riff;
  riff.insert(riff.end(), {'R', 'I', 'F', 'F'});
  push_u32(riff, 0);
  riff.insert(riff.end(), {'s', 'f', 'b', 'k'});
  auto info = make_list("INFO", { {"ifil", {2, 0, 4, 0}}, {"isng", {'E', 'M', 'U'}},
                                  {"INAM", {'D', 'r', 'u', 'm', ' ', 'T', 'e', 's', 't'}} });
  auto sdta = make_list("sdta", { {"smpl", smpl} });
  auto pdta = make_list("pdta", { {"phdr", phdr}, {"pbag", pbag}, {"pmod", std::vector<uint8_t>(10, 0)},
                                  {"pgen", pgen}, {"inst", inst}, {"ibag", ibag},
                                  {"imod", std::vector<uint8_t>(10, 0)}, {"igen", igen}, {"shdr", shdr} });
  riff.insert(riff.end(), info.begin(), info.end());
  riff.insert(riff.end(), sdta.begin(), sdta.end());
  riff.insert(riff.end(), pdta.begin(), pdta.end());
  uint32_t riff_size = uint32_t(riff.size() - 8);
  riff[4] = uint8_t(riff_size);
  riff[5] = uint8_t(riff_size >> 8);
  riff[6] = uint8_t(riff_size >> 16);
  riff[7] = uint8_t(riff_size >> 24);

  const std::string path = "build/render_support_percussion_test.sf2";
  std::ofstream out(path, std::ios::binary);
  if (!out) throw std::runtime_error("failed to create " + path);
  out.write(reinterpret_cast<const char*>(riff.data()), riff.size());
  return path;
}

}  // namespace

int main() {
  try {
    render::Sf2Data sf2 = render::load_sf2(write_percussion_sf2());
    render::Args args;
    args.sample_rate = 48000;
    args.seconds = 1.0;

    std::vector<render::NoteEvent> events;
    events.push_back({0.0, 61, true, 100, 0, 0, 0});
    events.push_back({0.05, 60, true, 100, 0, 0, 0});
    events.push_back({0.1, 35, true, 100, 9, 0, 0});
    events.push_back({0.2, 35, false, 0, 9, 0, 0});

    std::vector<render::Region> regions;
    std::vector<int16_t> wave_memory;
    render::prepare_events_and_regions(args, sf2, 48000, 480, events, regions, wave_memory);

    if (regions.size() != 2) throw std::runtime_error("expected one melodic region and one playable drum region");
    if (regions[0].instrument != "MelodicInst") {
      throw std::runtime_error("matching melodic layer was not preserved when another layer missed the key");
    }
    if (regions[1].bank != 128 || regions[1].preset != "Drums" || regions[1].sample_left != "Kick") {
      throw std::runtime_error("channel-10 note did not select the SF2 percussion bank region");
    }
    for (const auto& e : events) {
      if (e.on && e.note == 61) throw std::runtime_error("unmapped melodic note-on was not silenced");
    }

    std::cout << "PASS: render support maps channel-10 percussion to SF2 bank 128 and silences unmapped notes\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render_support_test failed: " << e.what() << "\n";
    return 1;
  }
}
