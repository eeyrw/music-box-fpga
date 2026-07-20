#include "render_support.h"

#include <cstdint>
#include <cmath>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct RecordingSink : public render::VoiceControlSink {
  int commit_count = 0;
  int release_count = 0;
  int disable_count = 0;
  int last_gain_l = -1;
  int last_gain_r = -1;
  uint32_t last_phase_inc = 0;
  int last_initial_envelope = -1;
  int filter_count = 0;
  std::vector<int> envelopes;

  void set_envelope(int, int level) override { envelopes.push_back(level); }
  void set_gain(int, int gain_l, int gain_r) override {
    last_gain_l = gain_l;
    last_gain_r = gain_r;
  }
  void set_phase_inc(int, uint32_t phase_inc) override { last_phase_inc = phase_inc; }
  void set_filter(int, const render::FilterConfig&) override { ++filter_count; }
  void commit_voice(int, int enable, uint32_t phase_inc, const render::Region& region) override {
    ++commit_count;
    if (!enable) ++disable_count;
    last_phase_inc = phase_inc;
    last_initial_envelope = region.initial_envelope;
  }
  void release_voice(int, const render::Region&) override { ++release_count; }
};

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
    render::NoteEvent volume;
    volume.time_seconds = 0.04;
    volume.channel = 0;
    volume.type = render::NoteEvent::EVENT_CONTROL;
    volume.controller = 7;
    volume.value = 64;
    events.push_back(volume);
    render::NoteEvent bend;
    bend.time_seconds = 0.06;
    bend.channel = 0;
    bend.type = render::NoteEvent::EVENT_PITCH_BEND;
    bend.pitch_bend = 4096;
    events.push_back(bend);
    render::NoteEvent all_notes_off;
    all_notes_off.time_seconds = 0.07;
    all_notes_off.channel = 0;
    all_notes_off.type = render::NoteEvent::EVENT_CONTROL;
    all_notes_off.controller = 123;
    events.push_back(all_notes_off);

    std::vector<render::Region> regions;
    std::vector<int16_t> wave_memory = sf2.file_words;
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

    RecordingSink sink;
    render::McuModel mcu(sink, regions);
    bool checked_bend = false;
    bool checked_volume = false;
    for (const auto& e : events) {
      mcu.handle_event(e);
      if (e.type == render::NoteEvent::EVENT_NOTE && e.on && e.channel == 0 && e.note == 60) {
        if (sink.last_gain_l <= 0 || sink.last_gain_l >= regions[0].gain_l) {
          throw std::runtime_error("CC7 volume did not reduce active voice gain");
        }
        checked_volume = true;
      }
      if (e.type == render::NoteEvent::EVENT_PITCH_BEND && e.channel == 0) {
        uint32_t bent = uint32_t(std::round(double(regions[0].phase_inc) * std::pow(2.0, 100.0 / 1200.0)));
        if (sink.last_phase_inc != bent) throw std::runtime_error("pitch bend did not update active phase increment");
        checked_bend = true;
      }
    }
    if (!checked_volume) throw std::runtime_error("test did not observe the controlled melodic note");
    if (!checked_bend) throw std::runtime_error("test did not observe the pitch-bend event");
    if (sink.release_count == 0) throw std::runtime_error("All Notes Off did not release active melodic voices");

    render::Region mod_region;
    mod_region.length = 4;
    mod_region.loop_end = 4;
    mod_region.phase_inc = render::kPhaseFracScale;
    mod_region.gain_l = 0x4000;
    mod_region.gain_r = 0x4000;
    mod_region.mod_lfo_step = 0x4000;
    mod_region.mod_lfo_to_pitch = 1200;
    mod_region.mod_lfo_to_filter_fc = -1200;
    mod_region.initial_filter_fc = 6900;
    mod_region.output_sample_rate = 48000;
    std::vector<render::Region> mod_regions{mod_region};
    RecordingSink mod_sink;
    render::McuModel mod_mcu(mod_sink, mod_regions);
    render::NoteEvent mod_note;
    mod_note.on = true;
    mod_note.velocity = 100;
    mod_note.phase_inc = mod_region.phase_inc;
    mod_mcu.handle_event(mod_note);
    if (mod_sink.last_phase_inc <= mod_region.phase_inc) {
      throw std::runtime_error("mod LFO pitch generator did not raise runtime phase increment");
    }
    if (mod_sink.filter_count == 0) {
      throw std::runtime_error("mod LFO filter generator did not issue runtime filter updates");
    }

    render::Region curve_region;
    curve_region.length = 4;
    curve_region.loop_end = 4;
    curve_region.attack_ticks = 4;
    curve_region.decay_ticks = 1;
    curve_region.release_ticks = 4;
    curve_region.gain_l = 0x4000;
    curve_region.gain_r = 0x4000;
    std::vector<render::Region> curve_regions{curve_region};
    RecordingSink curve_sink;
    render::McuModel curve_mcu(curve_sink, curve_regions);
    render::NoteEvent curve_note;
    curve_note.on = true;
    curve_note.velocity = 127;
    curve_note.phase_inc = render::kPhaseFracScale;
    curve_mcu.handle_event(curve_note);
    curve_mcu.envelope_tick();
    if (curve_sink.last_initial_envelope != 0) {
      throw std::runtime_error("volume envelope initial level was not staged in commit");
    }
    if (curve_sink.envelopes.empty() || curve_sink.envelopes.back() >= render::kQ15Full / 4) {
      throw std::runtime_error("volume envelope attack did not use a convex curve");
    }

    std::cout << "PASS: render support maps channel-10 percussion to SF2 bank 128 and silences unmapped notes\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render_support_test failed: " << e.what() << "\n";
    return 1;
  }
}
