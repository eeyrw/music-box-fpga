#include "render_support.h"
#include "reference_synth.h"

#include <cstdint>
#include <cmath>
#include <fstream>
#include <iostream>
#include <iterator>
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
  int gain_count = 0;
  int phase_count = 0;
  int last_initial_envelope = -1;
  int last_commit_voice = -1;
  int filter_count = 0;
  render::FilterConfig last_filter;
  std::vector<int> envelopes;

  void set_envelope(int, int level) override { envelopes.push_back(level); }
  void set_gain(int, int gain_l, int gain_r) override {
    ++gain_count;
    last_gain_l = gain_l;
    last_gain_r = gain_r;
  }
  void set_phase_inc(int, uint32_t phase_inc) override {
    ++phase_count;
    last_phase_inc = phase_inc;
  }
  void set_filter(int, const render::FilterConfig& filter) override {
    ++filter_count;
    last_filter = filter;
  }
  void commit_voice(int voice, int enable, uint32_t phase_inc, const render::Region& region) override {
    ++commit_count;
    if (!enable) ++disable_count;
    last_commit_voice = voice;
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
    render::NoteEvent expression;
    expression.time_seconds = 0.055;
    expression.channel = 0;
    expression.type = render::NoteEvent::EVENT_CONTROL;
    expression.controller = 11;
    expression.value = 32;
    events.push_back(expression);
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
    regions[0].preset = "Melodic \"Preset\"";
    regions[0].sample_right = "PianoC\\R";
    regions[0].modulators.push_back({0x00db, 16, 300, 0, 0});
    regions[0].modulators.push_back({0x00dd, 15, 800, 0, 0});
    regions[0].modulators.push_back({0x0102, 8, -1100, 0x0d02, 0});
    render::write_summary("build/render_support_summary_test.json", regions, 48000, 16, int(events.size()), "");
    std::ifstream summary("build/render_support_summary_test.json");
    std::string summary_text((std::istreambuf_iterator<char>(summary)), std::istreambuf_iterator<char>());
    if (summary_text.find("\"preset\": \"Melodic \\\"Preset\\\"\"") == std::string::npos ||
        summary_text.find("\"right\": {\"sample\": \"PianoC\\\\R\"") == std::string::npos) {
      throw std::runtime_error("summary JSON did not escape nested sample metadata");
    }
    if (summary_text.find("\"sf2_loader\": {\"mono_regions\": 2") == std::string::npos ||
        summary_text.find("\"stereo_source\": \"mono\"") == std::string::npos ||
        summary_text.find("\"gain\": {\"pan\":") == std::string::npos ||
        summary_text.find("\"volume_envelope\": {\"delay_ticks\":") == std::string::npos ||
        summary_text.find("\"filter\": {\"enable\":") == std::string::npos ||
        summary_text.find("\"loop_mode\":") == std::string::npos ||
        summary_text.find("\"modulation\": {\"generators\":") == std::string::npos ||
        summary_text.find("\"modulators\": [") == std::string::npos ||
        summary_text.find("\"name\": \"cc7Volume\"") == std::string::npos ||
        summary_text.find("\"direction\": \"negative\"") == std::string::npos ||
        summary_text.find("\"polarity\": \"unipolar\"") == std::string::npos ||
        summary_text.find("\"dest\": {\"raw\": 48, \"name\": \"initialAttenuation\"}") == std::string::npos ||
        summary_text.find("\"name\": \"cc91ReverbSend\"") == std::string::npos ||
        summary_text.find("\"dest\": {\"raw\": 16, \"name\": \"reverbEffectsSend\"}") == std::string::npos ||
        summary_text.find("\"name\": \"cc93ChorusSend\"") == std::string::npos ||
        summary_text.find("\"dest\": {\"raw\": 15, \"name\": \"chorusEffectsSend\"}") == std::string::npos ||
        summary_text.find("\"hex\": \"0x0d02\", \"name\": \"noteOnVelocity\"") == std::string::npos) {
      throw std::runtime_error("summary JSON did not include loader stats and grouped controls");
    }
    std::vector<int16_t> hot_memory{32767, 32767, 32767, 32767};
    render::RenderDiagnostics hot_diag;
    render::ReferenceSynth hot_synth(hot_memory, &hot_diag);
    render::Region hot_region;
    hot_region.length = 4;
    hot_region.loop_end = 4;
    hot_region.phase_inc = render::kPhaseFracScale;
    hot_region.gain_l = render::kQ15Full;
    hot_region.gain_r = render::kQ15Full;
    hot_region.initial_envelope = render::kQ15Full;
    hot_region.filter_enable = true;
    hot_region.filter_b0 = 1 << 30;
    hot_region.filter_a1 = -32768;
    hot_synth.commit_voice(0, 1, hot_region.phase_inc, hot_region);
    hot_synth.commit_voice(1, 1, hot_region.phase_inc, hot_region);
    hot_synth.render_sample();
    if (hot_diag.max_abs_filter_y_input <= ((uint64_t(1) << 19) - 1) ||
        hot_diag.max_abs_filter_state_input <= ((uint64_t(1) << 33) - 1) ||
        hot_diag.max_abs_voice_contribution_input_l <= 32767 ||
        hot_diag.max_abs_voice_contribution_input_r <= 32767 ||
        hot_diag.max_abs_mix_input_l <= 32767 ||
        hot_diag.max_abs_mix_input_r <= 32767) {
      throw std::runtime_error("saturation diagnostics did not record pre-saturation maxima");
    }
    std::string diagnostics_text = render::diagnostics_json_fields(hot_diag);
    if (diagnostics_text.find("diagnostics_max_abs_filter_y_input") == std::string::npos ||
        diagnostics_text.find("diagnostics_max_abs_voice_contribution_input_l") == std::string::npos ||
        diagnostics_text.find("diagnostics_max_abs_mix_input_r") == std::string::npos ||
        diagnostics_text.find("diagnostics_max_voice_steal_score") == std::string::npos ||
        diagnostics_text.find("diagnostics_runtime_envelope_updates") == std::string::npos ||
        diagnostics_text.find("diagnostics_max_runtime_envelope_jump_tick") == std::string::npos) {
      throw std::runtime_error("diagnostics JSON did not include pre-saturation maxima");
    }
    render::Args input_args;
    input_args.sf2 = "/tmp/example.sf2";
    input_args.midi = "/tmp/example.mid";
    input_args.instrument = "Piano";
    input_args.key = 64;
    input_args.seconds = 12.5;
    input_args.adsr_tick_ms = 1.0;
    std::string input_json = render::render_input_json_fields(input_args, 48);
    if (input_json.find("\"sf2_path\": \"/tmp/example.sf2\"") == std::string::npos ||
        input_json.find("\"midi_path\": \"/tmp/example.mid\"") == std::string::npos ||
        input_json.find("\"uses_default_melody\": false") == std::string::npos ||
        input_json.find("\"instrument_override\": \"Piano\"") == std::string::npos ||
        input_json.find("\"adsr_tick_samples\": 48") == std::string::npos ||
        input_json.find("\"render_num_voices\": ") == std::string::npos) {
      throw std::runtime_error("input JSON fields did not include render provenance");
    }
    input_args.midi.clear();
    input_args.instrument.clear();
    input_json = render::render_input_json_fields(input_args, 240);
    if (input_json.find("\"midi_path\": null") == std::string::npos ||
        input_json.find("\"uses_default_melody\": true") == std::string::npos ||
        input_json.find("\"instrument_override\": null") == std::string::npos) {
      throw std::runtime_error("input JSON fields did not mark default inputs");
    }
    for (const auto& e : events) {
      if (e.on && e.note == 61) throw std::runtime_error("unmapped melodic note-on was not silenced");
    }

    RecordingSink sink;
    render::McuModel mcu(sink, regions);
    bool checked_bend = false;
    bool checked_volume = false;
    bool checked_expression = false;
    for (const auto& e : events) {
      mcu.handle_event(e);
      if (e.type == render::NoteEvent::EVENT_NOTE && e.on && e.channel == 0 && e.note == 60) {
        int expected_gain = int(std::round(double(regions[0].gain_l) *
                                           double(render::concave_attenuation_q15(64)) /
                                           double(render::kQ15Full)));
        if (sink.last_gain_l != expected_gain) {
          throw std::runtime_error("CC7 volume did not use SF2 concave attenuation");
        }
        checked_volume = true;
      }
      if (e.type == render::NoteEvent::EVENT_CONTROL && e.channel == 0 && e.controller == 11) {
        int expected_gain = int(std::round(double(regions[0].gain_l) *
                                           double(render::concave_attenuation_q15(64)) *
                                           double(render::concave_attenuation_q15(32)) /
                                           double(render::kQ15Full) /
                                           double(render::kQ15Full)));
        if (sink.last_gain_l != expected_gain) {
          throw std::runtime_error("CC11 expression did not use SF2 concave attenuation");
        }
        checked_expression = true;
      }
      if (e.type == render::NoteEvent::EVENT_PITCH_BEND && e.channel == 0) {
        uint32_t bent = uint32_t(std::round(double(regions[0].phase_inc) * std::pow(2.0, 100.0 / 1200.0)));
        if (sink.last_phase_inc != bent) throw std::runtime_error("pitch bend did not update active phase increment");
        checked_bend = true;
      }
    }
    if (!checked_volume) throw std::runtime_error("test did not observe the controlled melodic note");
    if (!checked_expression) throw std::runtime_error("test did not observe the expression event");
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
    if (mod_sink.last_phase_inc != mod_region.phase_inc) {
      throw std::runtime_error("mod LFO did not start its ramp at zero excursion");
    }
    mod_mcu.envelope_tick();
    if (mod_sink.last_phase_inc <= mod_region.phase_inc) {
      throw std::runtime_error("mod LFO pitch generator did not raise runtime phase increment on the next tick");
    }
    if (mod_sink.filter_count == 0) {
      throw std::runtime_error("mod LFO filter generator did not issue runtime filter updates");
    }

    render::Region velocity_filter_region;
    velocity_filter_region.length = 4;
    velocity_filter_region.loop_end = 4;
    velocity_filter_region.phase_inc = render::kPhaseFracScale;
    velocity_filter_region.gain_l = 0x4000;
    velocity_filter_region.gain_r = 0x4000;
    velocity_filter_region.initial_filter_fc = 6900;
    velocity_filter_region.output_sample_rate = 48000;
    std::vector<render::Region> velocity_filter_regions{velocity_filter_region};
    render::NoteEvent high_velocity_note;
    high_velocity_note.on = true;
    high_velocity_note.velocity = 127;
    high_velocity_note.phase_inc = render::kPhaseFracScale;
    RecordingSink high_velocity_sink;
    render::McuModel high_velocity_mcu(high_velocity_sink, velocity_filter_regions);
    high_velocity_mcu.handle_event(high_velocity_note);
    render::NoteEvent low_velocity_note = high_velocity_note;
    low_velocity_note.velocity = 1;
    RecordingSink low_velocity_sink;
    render::McuModel low_velocity_mcu(low_velocity_sink, velocity_filter_regions);
    low_velocity_mcu.handle_event(low_velocity_note);
    if (high_velocity_sink.last_filter.b0 == low_velocity_sink.last_filter.b0) {
      throw std::runtime_error("default velocity-to-filter-cutoff did not change filter coefficients");
    }

    render::Region steady_filter_region;
    steady_filter_region.length = 4;
    steady_filter_region.loop_end = 4;
    steady_filter_region.phase_inc = render::kPhaseFracScale;
    steady_filter_region.gain_l = 0x4000;
    steady_filter_region.gain_r = 0x4000;
    steady_filter_region.initial_filter_fc = 6900;
    steady_filter_region.output_sample_rate = 48000;
    std::vector<render::Region> steady_filter_regions{steady_filter_region};
    RecordingSink steady_filter_sink;
    render::RenderDiagnostics steady_filter_diag;
    render::McuModel steady_filter_mcu(steady_filter_sink, steady_filter_regions, &steady_filter_diag);
    render::NoteEvent steady_filter_note;
    steady_filter_note.on = true;
    steady_filter_note.velocity = 100;
    steady_filter_note.phase_inc = steady_filter_region.phase_inc;
    steady_filter_mcu.handle_event(steady_filter_note);
    int steady_filter_writes = steady_filter_sink.filter_count;
    steady_filter_mcu.envelope_tick();
    steady_filter_mcu.envelope_tick();
    if (steady_filter_sink.filter_count != steady_filter_writes) {
      throw std::runtime_error("unchanged runtime filter coefficients were written again");
    }
    if (steady_filter_diag.runtime_filter_updates != uint64_t(steady_filter_writes)) {
      throw std::runtime_error("filter diagnostics counted skipped runtime filter writes");
    }

    render::Region steady_runtime_region;
    steady_runtime_region.length = 4;
    steady_runtime_region.loop_end = 4;
    steady_runtime_region.phase_inc = render::kPhaseFracScale;
    steady_runtime_region.gain_l = 0x4000;
    steady_runtime_region.gain_r = 0x4000;
    steady_runtime_region.output_sample_rate = 48000;
    std::vector<render::Region> steady_runtime_regions{steady_runtime_region};
    RecordingSink steady_runtime_sink;
    render::RenderDiagnostics steady_runtime_diag;
    render::McuModel steady_runtime_mcu(steady_runtime_sink, steady_runtime_regions, &steady_runtime_diag);
    render::NoteEvent steady_runtime_note;
    steady_runtime_note.on = true;
    steady_runtime_note.velocity = 100;
    steady_runtime_note.phase_inc = steady_runtime_region.phase_inc;
    steady_runtime_mcu.handle_event(steady_runtime_note);
    int steady_gain_writes = steady_runtime_sink.gain_count;
    int steady_phase_writes = steady_runtime_sink.phase_count;
    int steady_filter_runtime_writes = steady_runtime_sink.filter_count;
    steady_runtime_mcu.envelope_tick();
    steady_runtime_mcu.envelope_tick();
    if (steady_runtime_sink.gain_count != steady_gain_writes ||
        steady_runtime_sink.phase_count != steady_phase_writes ||
        steady_runtime_sink.filter_count != steady_filter_runtime_writes) {
      throw std::runtime_error("unchanged runtime control values were written again");
    }
    if (steady_runtime_diag.runtime_gain_updates != uint64_t(steady_gain_writes) ||
        steady_runtime_diag.runtime_phase_updates != uint64_t(steady_phase_writes) ||
        steady_runtime_diag.runtime_filter_updates != uint64_t(steady_filter_runtime_writes)) {
      throw std::runtime_error("runtime diagnostics counted skipped control writes");
    }

    render::Region envelope_jump_region;
    envelope_jump_region.length = 4;
    envelope_jump_region.loop_end = 4;
    envelope_jump_region.phase_inc = render::kPhaseFracScale;
    envelope_jump_region.gain_l = 0x4000;
    envelope_jump_region.gain_r = 0x4000;
    envelope_jump_region.attack_ticks = 2;
    envelope_jump_region.output_sample_rate = 48000;
    std::vector<render::Region> envelope_jump_regions{envelope_jump_region};
    RecordingSink envelope_jump_sink;
    render::RenderDiagnostics envelope_jump_diag;
    render::McuModel envelope_jump_mcu(envelope_jump_sink, envelope_jump_regions, &envelope_jump_diag);
    render::NoteEvent envelope_jump_note;
    envelope_jump_note.on = true;
    envelope_jump_note.velocity = 127;
    envelope_jump_note.phase_inc = envelope_jump_region.phase_inc;
    envelope_jump_mcu.handle_event(envelope_jump_note);
    envelope_jump_mcu.envelope_tick();
    envelope_jump_mcu.envelope_tick();
    if (envelope_jump_diag.runtime_envelope_updates != uint64_t(envelope_jump_sink.envelopes.size()) ||
        envelope_jump_diag.max_runtime_envelope_jump == 0 ||
        envelope_jump_diag.max_runtime_envelope_jump_voice != 0 ||
        envelope_jump_diag.max_runtime_envelope_jump_tick != 0) {
      throw std::runtime_error("envelope diagnostics did not record runtime jumps");
    }

    render::Region bend_range_region;
    bend_range_region.length = 4;
    bend_range_region.loop_end = 4;
    bend_range_region.phase_inc = render::kPhaseFracScale;
    bend_range_region.gain_l = 0x4000;
    bend_range_region.gain_r = 0x4000;
    std::vector<render::Region> bend_range_regions{bend_range_region};
    RecordingSink bend_range_sink;
    render::McuModel bend_range_mcu(bend_range_sink, bend_range_regions);
    render::NoteEvent rpn_msb;
    rpn_msb.type = render::NoteEvent::EVENT_CONTROL;
    rpn_msb.controller = 101;
    rpn_msb.value = 0;
    render::NoteEvent rpn_lsb = rpn_msb;
    rpn_lsb.controller = 100;
    render::NoteEvent data_entry = rpn_msb;
    data_entry.controller = 6;
    data_entry.value = 12;
    bend_range_mcu.handle_event(rpn_msb);
    bend_range_mcu.handle_event(rpn_lsb);
    bend_range_mcu.handle_event(data_entry);
    render::NoteEvent bend_range_note;
    bend_range_note.on = true;
    bend_range_note.velocity = 127;
    bend_range_note.phase_inc = render::kPhaseFracScale;
    bend_range_mcu.handle_event(bend_range_note);
    render::NoteEvent wide_bend;
    wide_bend.type = render::NoteEvent::EVENT_PITCH_BEND;
    wide_bend.pitch_bend = 4096;
    bend_range_mcu.handle_event(wide_bend);
    double wide_bend_cents = 12700.0 * (4096.0 / 8192.0) * (12.0 / 128.0);
    uint32_t wide_bent = uint32_t(std::round(double(render::kPhaseFracScale) *
                                             std::pow(2.0, wide_bend_cents / 1200.0)));
    if (bend_range_sink.last_phase_inc != wide_bent) {
      throw std::runtime_error("RPN pitch-bend sensitivity did not widen bend range");
    }

    render::Region default_vibrato_region;
    default_vibrato_region.length = 4;
    default_vibrato_region.loop_end = 4;
    default_vibrato_region.phase_inc = render::kPhaseFracScale;
    default_vibrato_region.gain_l = 0x4000;
    default_vibrato_region.gain_r = 0x4000;
    default_vibrato_region.vib_lfo_step = 0x4000;
    std::vector<render::Region> default_vibrato_regions{default_vibrato_region};
    RecordingSink default_vibrato_sink;
    render::McuModel default_vibrato_mcu(default_vibrato_sink, default_vibrato_regions);
    render::NoteEvent mod_wheel;
    mod_wheel.type = render::NoteEvent::EVENT_CONTROL;
    mod_wheel.controller = 1;
    mod_wheel.value = 127;
    default_vibrato_mcu.handle_event(mod_wheel);
    render::NoteEvent default_vibrato_note;
    default_vibrato_note.on = true;
    default_vibrato_note.velocity = 127;
    default_vibrato_note.phase_inc = render::kPhaseFracScale;
    default_vibrato_mcu.handle_event(default_vibrato_note);
    if (default_vibrato_sink.last_phase_inc != render::kPhaseFracScale) {
      throw std::runtime_error("default vibrato LFO did not start at zero excursion");
    }
    default_vibrato_mcu.envelope_tick();
    if (default_vibrato_sink.last_phase_inc <= render::kPhaseFracScale) {
      throw std::runtime_error("CC1 default modulator did not add vibrato pitch depth");
    }

    render::Region custom_mod_region;
    custom_mod_region.length = 4;
    custom_mod_region.loop_end = 4;
    custom_mod_region.phase_inc = render::kPhaseFracScale;
    custom_mod_region.gain_l = 0x4000;
    custom_mod_region.gain_r = 0x4000;
    custom_mod_region.vib_lfo_step = 0x4000;
    custom_mod_region.modulators.push_back({0x0081, 6, 200, 0, 0});
    std::vector<render::Region> custom_mod_regions{custom_mod_region};
    RecordingSink custom_mod_sink;
    render::McuModel custom_mod_mcu(custom_mod_sink, custom_mod_regions);
    custom_mod_mcu.handle_event(mod_wheel);
    render::NoteEvent custom_mod_note = default_vibrato_note;
    custom_mod_mcu.handle_event(custom_mod_note);
    custom_mod_mcu.envelope_tick();
    double custom_mod_cents = 200.0 * (127.0 / 128.0);
    uint32_t custom_mod_phase = uint32_t(std::round(double(render::kPhaseFracScale) *
                                                    std::pow(2.0, custom_mod_cents / 1200.0)));
    if (custom_mod_sink.last_phase_inc != custom_mod_phase) {
      throw std::runtime_error("custom SF2 modulator did not drive vibrato pitch depth");
    }

    render::Region tremolo_region;
    tremolo_region.length = 4;
    tremolo_region.loop_end = 4;
    tremolo_region.phase_inc = render::kPhaseFracScale;
    tremolo_region.base_gain = 0x1000;
    tremolo_region.mod_lfo_step = 0x4000;
    tremolo_region.mod_lfo_to_volume = 100;
    std::vector<render::Region> tremolo_regions{tremolo_region};
    RecordingSink tremolo_sink;
    render::McuModel tremolo_mcu(tremolo_sink, tremolo_regions);
    render::NoteEvent tremolo_note;
    tremolo_note.on = true;
    tremolo_note.velocity = 127;
    tremolo_note.phase_inc = render::kPhaseFracScale;
    tremolo_mcu.handle_event(tremolo_note);
    tremolo_mcu.envelope_tick();
    int tremolo_gain = int(std::round(double(0x1000) * std::pow(10.0, 100.0 / 200.0)));
    if (tremolo_sink.last_gain_l != tremolo_gain || tremolo_sink.last_gain_r != tremolo_gain) {
      throw std::runtime_error("modLfoToVolume did not boost runtime gain on positive LFO excursion");
    }
    tremolo_mcu.envelope_tick();
    tremolo_mcu.envelope_tick();
    int tremolo_dip = int(std::round(double(0x1000) * std::pow(10.0, -100.0 / 200.0)));
    if (tremolo_sink.last_gain_l != tremolo_dip || tremolo_sink.last_gain_r != tremolo_dip) {
      throw std::runtime_error("modLfoToVolume did not attenuate runtime gain on negative LFO excursion");
    }

    render::Region pedal_region;
    pedal_region.length = 4;
    pedal_region.loop_end = 4;
    pedal_region.phase_inc = render::kPhaseFracScale;
    pedal_region.base_gain = 0x4000;
    std::vector<render::Region> pedal_regions{pedal_region};
    RecordingSink soft_sink;
    render::McuModel soft_mcu(soft_sink, pedal_regions);
    render::NoteEvent soft_on;
    soft_on.type = render::NoteEvent::EVENT_CONTROL;
    soft_on.controller = 66;
    soft_on.value = 127;
    soft_mcu.handle_event(soft_on);
    soft_mcu.handle_event(tremolo_note);
    int soft_gain = int(std::round(double(0x4000) * std::pow(10.0, -30.0 / 200.0)));
    if (soft_sink.last_gain_l != soft_gain || soft_sink.last_gain_r != soft_gain) {
      throw std::runtime_error("CC66 soft pedal did not attenuate runtime gain");
    }

    RecordingSink sostenuto_sink;
    render::McuModel sostenuto_mcu(sostenuto_sink, pedal_regions);
    sostenuto_mcu.handle_event(tremolo_note);
    render::NoteEvent sostenuto_on = soft_on;
    sostenuto_on.controller = 67;
    sostenuto_mcu.handle_event(sostenuto_on);
    render::NoteEvent pedal_note_off = tremolo_note;
    pedal_note_off.on = false;
    sostenuto_mcu.handle_event(pedal_note_off);
    if (sostenuto_sink.release_count != 0) {
      throw std::runtime_error("CC67 sostenuto released a captured note too early");
    }
    render::NoteEvent sostenuto_off = sostenuto_on;
    sostenuto_off.value = 0;
    sostenuto_mcu.handle_event(sostenuto_off);
    if (sostenuto_sink.release_count != 1) {
      throw std::runtime_error("CC67 sostenuto did not release captured note");
    }

    render::Region poly_pressure_region;
    poly_pressure_region.length = 4;
    poly_pressure_region.loop_end = 4;
    poly_pressure_region.phase_inc = render::kPhaseFracScale;
    poly_pressure_region.vib_lfo_step = 0x4000;
    poly_pressure_region.modulators.push_back({0x000a, 6, 200, 0, 0});
    std::vector<render::Region> poly_pressure_regions{poly_pressure_region};
    RecordingSink poly_pressure_sink;
    render::McuModel poly_pressure_mcu(poly_pressure_sink, poly_pressure_regions);
    render::NoteEvent poly_note = tremolo_note;
    poly_note.note = 60;
    poly_pressure_mcu.handle_event(poly_note);
    render::NoteEvent poly_pressure;
    poly_pressure.type = render::NoteEvent::EVENT_KEY_PRESSURE;
    poly_pressure.note = 60;
    poly_pressure.value = 127;
    poly_pressure_mcu.handle_event(poly_pressure);
    double poly_pressure_cents = 200.0 * (127.0 / 128.0);
    uint32_t poly_pressure_phase = uint32_t(std::round(double(render::kPhaseFracScale) *
                                                       std::pow(2.0, poly_pressure_cents / 1200.0)));
    if (poly_pressure_sink.last_phase_inc != poly_pressure_phase) {
      throw std::runtime_error("polyphonic key pressure did not feed custom modulator");
    }

    RecordingSink nrpn_sink;
    render::McuModel nrpn_mcu(nrpn_sink, pedal_regions);
    nrpn_mcu.handle_event(tremolo_note);
    render::NoteEvent nrpn;
    nrpn.type = render::NoteEvent::EVENT_CONTROL;
    nrpn.controller = 99;
    nrpn.value = 120;
    nrpn_mcu.handle_event(nrpn);
    nrpn.controller = 98;
    nrpn.value = 17;
    nrpn_mcu.handle_event(nrpn);
    nrpn.controller = 38;
    nrpn.value = 0;
    nrpn_mcu.handle_event(nrpn);
    nrpn.controller = 6;
    nrpn.value = 96;
    nrpn_mcu.handle_event(nrpn);
    if (nrpn_sink.last_gain_l != 0 || nrpn_sink.last_gain_r != render::kQ15Full) {
      throw std::runtime_error("SF2 NRPN pan offset did not update runtime gain");
    }

    render::Region curve_region;
    curve_region.length = 4;
    curve_region.loop_end = 4;
    curve_region.attack_ticks = 4;
    curve_region.decay_ticks = 4;
    curve_region.sustain_level = render::kQ15Full / 16;
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
    int expected_attack = int(std::round(double(render::kQ15Full) / 4.0));
    if (curve_sink.envelopes.empty() || std::abs(curve_sink.envelopes.back() - expected_attack) > 1) {
      throw std::runtime_error("volume envelope attack did not use a linear-amplitude SF2 approximation");
    }
    for (int i = 0; i < 4; ++i) curve_mcu.envelope_tick();
    int first_decay = curve_sink.envelopes.back();
    int linear_decay = int(std::round(double(render::kQ15Full) +
                                      double(curve_region.sustain_level - render::kQ15Full) / 4.0));
    if (first_decay >= linear_decay) {
      throw std::runtime_error("volume envelope decay did not use a dB-linear curve");
    }
    render::NoteEvent curve_off = curve_note;
    curve_off.on = false;
    curve_mcu.handle_event(curve_off);
    curve_mcu.envelope_tick();
    int first_release = curve_sink.envelopes.back();
    int linear_release = int(std::round(double(first_decay) * 3.0 / 4.0));
    if (first_release >= linear_release) {
      throw std::runtime_error("volume envelope release did not use a dB-linear curve");
    }

    render::Region pan_region;
    pan_region.length = 4;
    pan_region.loop_end = 4;
    pan_region.phase_inc = render::kPhaseFracScale;
    pan_region.base_gain = 0x4000;
    pan_region.pan = 250;
    std::vector<render::Region> pan_regions{pan_region};
    RecordingSink pan_sink;
    render::McuModel pan_mcu(pan_sink, pan_regions);
    render::NoteEvent pan_note;
    pan_note.on = true;
    pan_note.velocity = 127;
    pan_note.phase_inc = render::kPhaseFracScale;
    pan_mcu.handle_event(pan_note);
    if (pan_sink.last_gain_l != 8192 || pan_sink.last_gain_r != 24576) {
      throw std::runtime_error("SF2 pan did not set initial runtime balance");
    }
    render::NoteEvent pan_cc = pan_note;
    pan_cc.type = render::NoteEvent::EVENT_CONTROL;
    pan_cc.controller = 10;
    pan_cc.value = 0;
    pan_mcu.handle_event(pan_cc);
    if (pan_sink.last_gain_l != render::kQ15Full || pan_sink.last_gain_r != 0) {
      throw std::runtime_error("CC10 pan did not add to SF2 pan before clamping");
    }

    render::Region stereo_gain_region;
    stereo_gain_region.length = 4;
    stereo_gain_region.loop_end = 4;
    stereo_gain_region.phase_inc = render::kPhaseFracScale;
    stereo_gain_region.stereo = true;
    stereo_gain_region.base_gain = 0x4000;
    stereo_gain_region.base_gain_l = 0x4000;
    stereo_gain_region.base_gain_r = 0x2000;
    stereo_gain_region.pan = 0;
    std::vector<render::Region> stereo_gain_regions{stereo_gain_region};
    RecordingSink stereo_gain_sink;
    render::McuModel stereo_gain_mcu(stereo_gain_sink, stereo_gain_regions);
    render::NoteEvent stereo_gain_note;
    stereo_gain_note.on = true;
    stereo_gain_note.velocity = 127;
    stereo_gain_note.phase_inc = render::kPhaseFracScale;
    stereo_gain_mcu.handle_event(stereo_gain_note);
    if (stereo_gain_sink.last_gain_l != 0x4000 || stereo_gain_sink.last_gain_r != 0x2000) {
      throw std::runtime_error("stereo region did not use independent per-side base gains");
    }

    render::Region exclusive_region;
    exclusive_region.length = 4;
    exclusive_region.loop_end = 4;
    exclusive_region.phase_inc = render::kPhaseFracScale;
    exclusive_region.gain_l = 0x4000;
    exclusive_region.gain_r = 0x4000;
    exclusive_region.program = 0;
    exclusive_region.bank = 128;
    exclusive_region.preset = "Drums";
    exclusive_region.exclusive_class = 7;
    std::vector<render::Region> exclusive_regions{exclusive_region};
    RecordingSink exclusive_sink;
    render::McuModel exclusive_mcu(exclusive_sink, exclusive_regions);
    render::NoteEvent first_exclusive;
    first_exclusive.on = true;
    first_exclusive.channel = 0;
    first_exclusive.note = 42;
    first_exclusive.velocity = 127;
    first_exclusive.phase_inc = render::kPhaseFracScale;
    render::NoteEvent second_exclusive = first_exclusive;
    second_exclusive.channel = 1;
    second_exclusive.note = 46;
    exclusive_mcu.handle_event(first_exclusive);
    exclusive_mcu.handle_event(second_exclusive);
    if (exclusive_sink.release_count != 1) {
      throw std::runtime_error("exclusiveClass did not terminate same-preset voice on another channel");
    }

    render::Region steal_region;
    steal_region.length = 4;
    steal_region.loop_end = 4;
    steal_region.phase_inc = render::kPhaseFracScale;
    steal_region.gain_l = 0x4000;
    steal_region.gain_r = 0x4000;
    steal_region.release_ticks = 64;
    std::vector<render::Region> steal_regions{steal_region};
    RecordingSink steal_sink;
    render::McuModel steal_mcu(steal_sink, steal_regions);
    render::NoteEvent steal_note;
    steal_note.on = true;
    steal_note.velocity = 127;
    steal_note.phase_inc = render::kPhaseFracScale;
    for (int i = 0; i < render::kNumVoices; ++i) {
      steal_note.note = 40 + i;
      steal_mcu.handle_event(steal_note);
    }
    render::NoteEvent release_newer = steal_note;
    release_newer.on = false;
    release_newer.note = 40 + render::kNumVoices - 1;
    steal_mcu.handle_event(release_newer);
    steal_note.note = 100;
    steal_mcu.handle_event(steal_note);
    if (steal_sink.last_commit_voice != render::kNumVoices - 1) {
      throw std::runtime_error("voice steal did not prefer the released slot over the oldest active slot");
    }

    render::Region loud_region = steal_region;
    loud_region.base_gain = 0x4000;
    render::Region quiet_region = steal_region;
    quiet_region.base_gain = 1;
    std::vector<render::Region> audible_steal_regions{loud_region, quiet_region};
    RecordingSink audible_steal_sink;
    render::RenderDiagnostics audible_steal_diag;
    render::McuModel audible_steal_mcu(audible_steal_sink, audible_steal_regions, &audible_steal_diag);
    render::NoteEvent audible_note = steal_note;
    audible_note.on = true;
    audible_note.velocity = 127;
    audible_note.phase_inc = render::kPhaseFracScale;
    for (int i = 0; i < render::kNumVoices; ++i) {
      audible_note.note = 40 + i;
      audible_note.region = (i == render::kNumVoices - 1) ? 1 : 0;
      audible_steal_mcu.handle_event(audible_note);
    }
    audible_steal_mcu.envelope_tick();
    audible_note.note = 100;
    audible_note.region = 0;
    audible_steal_mcu.handle_event(audible_note);
    if (audible_steal_sink.last_commit_voice != render::kNumVoices - 1) {
      throw std::runtime_error("voice steal did not prefer the quietest audible slot over the oldest slot");
    }
    if (audible_steal_diag.voice_steals != 1 ||
        audible_steal_diag.max_voice_steal_voice != render::kNumVoices - 1 ||
        audible_steal_diag.max_voice_steal_level != uint32_t(render::kQ15Full) ||
        audible_steal_diag.max_voice_steal_gain_l != 1 ||
        audible_steal_diag.max_voice_steal_gain_r != 1 ||
        audible_steal_diag.max_voice_steal_score != uint64_t(render::kQ15Full) ||
        audible_steal_diag.max_voice_steal_tick != 1) {
      throw std::runtime_error("voice steal diagnostics did not record stolen voice audibility");
    }

    std::cout << "PASS: render support maps channel-10 percussion to SF2 bank 128 and silences unmapped notes\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "render_support_test failed: " << e.what() << "\n";
    return 1;
  }
}
