#include "render_support.h"
#include "reference_synth.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cmath>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr int kMidiChannelCount = 16;
constexpr int kCcDataEntryMsb = 6;
constexpr int kCcDataEntryLsb = 38;
constexpr int kCcSustain = 64;
constexpr int kCcSostenuto = 66;
constexpr int kCcSoftPedal = 67;
constexpr int kCcAllNotesOff = 123;
constexpr int kCcRpnLsb = 100;
constexpr int kCcRpnMsb = 101;
constexpr int kRpnPitchBendSensitivity = 0;
constexpr int kRpnFineTune = 1;
constexpr int kRpnNull = 127;
constexpr int kPitchBendRangeSemitones = 12;
constexpr int kFineTuneCenterMsb = 64;
constexpr int kHalfPositivePitchBend = 4096;
constexpr double kPitchWheelModulatorAmountCents = 12700.0;
constexpr double kPitchWheelCenter = 8192.0;
constexpr double kMidiSourceRange = 128.0;
constexpr double kCentsPerSemitone = 100.0;
constexpr double kCentsPerOctave = 1200.0;

struct RecordingSink : public render::VoiceCommandSink {
  int commit_count = 0;
  int release_count = 0;
  int disable_count = 0;
  int last_gain_l = -1;
  int last_gain_r = -1;
  uint32_t last_phase_inc = 0;
  int gain_count = 0;
  int phase_count = 0;
  int last_commit_voice = -1;
  int filter_count = 0;
  render::FilterConfig last_filter;
  void update_gain_phase(int, int gain_l, int gain_r, uint32_t phase_inc) override {
    ++gain_count;
    ++phase_count;
    last_gain_l = gain_l;
    last_gain_r = gain_r;
    last_phase_inc = phase_inc;
  }
  void update_filter(int, const render::FilterConfig& filter) override {
    ++filter_count;
    last_filter = filter;
  }
  void start_voice(int voice, uint32_t phase_inc, const render::Region& region) override {
    ++commit_count;
    last_commit_voice = voice;
    last_phase_inc = phase_inc;
    last_gain_l = region.gain_l;
    last_gain_r = region.gain_r;
    last_filter = {region.filter_enable, region.filter_b0, region.filter_b1,
                   region.filter_b2, region.filter_a1, region.filter_a2};
  }
  void release_voice(int, uint32_t) override { ++release_count; }
  void stop_voice(int) override { ++disable_count; }
};

int expected_pan_gain(int base_gain, int pan, bool left, bool center_unity = false) {
  constexpr double kPi = 3.14159265358979323846;
  int distance = left ? 500 - pan : 500 + pan;
  double normalization = center_unity ? std::sqrt(2.0) : 1.0;
  int gain = int(std::round(double(base_gain) * normalization *
                            std::sin(double(distance) * kPi / 2000.0)));
  return std::max(0, std::min(render::kQ15Full, gain));
}

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
    const render::ControlMathValidation math =
        render::validate_control_math_approximations();
    if (math.max_pitch_ratio_error > 0.05 ||
        math.max_attenuation_gain_error > 0.000001 ||
        math.max_phase_increment_error > 1 ||
        math.max_filter_coefficient_error > 96) {
      throw std::runtime_error(
          "control approximation error bounds exceeded: pitch=" +
          std::to_string(math.max_pitch_ratio_error) + " attenuation=" +
          std::to_string(math.max_attenuation_gain_error) + " phase=" +
          std::to_string(math.max_phase_increment_error) + " filter=" +
          std::to_string(math.max_filter_coefficient_error));
    }
    {
      render::Region active_region;
      active_region.length = 4;
      active_region.loop_end = 4;
      active_region.phase_inc = render::kPhaseFracScale;
      active_region.release_ticks = 1;
      std::vector<render::Region> active_regions{active_region};
      RecordingSink active_sink;
      render::RenderDiagnostics active_diagnostics;
      render::McuModel active_mcu(active_sink, active_regions,
                                  &active_diagnostics);
      render::NoteEvent active_note;
      active_note.on = true;
      active_note.note = 60;
      active_note.velocity = 100;
      active_note.phase_inc = render::kPhaseFracScale;
      active_mcu.handle_event(active_note);
      active_mcu.control_tick();
      active_note.on = false;
      active_mcu.handle_event(active_note);
      active_mcu.control_tick();
      const uint64_t dirty_after_release =
          active_diagnostics.control_dirty_group_evaluations;
      active_mcu.control_tick();
      if (active_diagnostics.control_active_voices != 0 ||
          active_diagnostics.control_max_active_voices != 1 ||
          active_diagnostics.control_tick_count != 3 ||
          active_diagnostics.control_dirty_group_evaluations !=
              dirty_after_release ||
          active_diagnostics.control_emitted_commands < 2) {
        throw std::runtime_error("bounded active-set control diagnostics mismatch");
      }
    }
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
    {
      render::Args window_args = args;
      window_args.start_seconds = 0.05;
      window_args.seconds = 0.10;
      std::vector<render::NoteEvent> window_events;
      render::NoteEvent pre_note;
      pre_note.time_seconds = 0.04;
      pre_note.note = 60;
      pre_note.on = true;
      pre_note.velocity = 100;
      pre_note.channel = 0;
      window_events.push_back(pre_note);
      render::NoteEvent pre_control;
      pre_control.time_seconds = 0.03;
      pre_control.channel = 0;
      pre_control.type = render::NoteEvent::EVENT_CONTROL;
      pre_control.controller = 7;
      pre_control.value = 90;
      window_events.push_back(pre_control);
      render::NoteEvent in_note;
      in_note.time_seconds = 0.06;
      in_note.note = 60;
      in_note.on = true;
      in_note.velocity = 100;
      in_note.channel = 0;
      window_events.push_back(in_note);
      render::NoteEvent in_off = in_note;
      in_off.time_seconds = 0.08;
      in_off.on = false;
      in_off.velocity = 0;
      window_events.push_back(in_off);
      render::NoteEvent after = in_note;
      after.time_seconds = 0.20;
      window_events.push_back(after);
      std::vector<render::Region> window_regions;
      std::vector<int16_t> window_memory = sf2.file_words;
      render::prepare_events_and_regions(window_args, sf2, 4800, 480, window_events, window_regions, window_memory);
      if (window_events.size() != 3) throw std::runtime_error("MIDI start window kept the wrong number of events");
      if (window_events[0].type != render::NoteEvent::EVENT_CONTROL || window_events[0].time_seconds != 0.0) {
        throw std::runtime_error("pre-window MIDI control was not replayed at the window start");
      }
      if (window_events[1].type != render::NoteEvent::EVENT_NOTE || !window_events[1].on ||
          std::fabs(window_events[1].time_seconds - 0.01) > 1e-9) {
        throw std::runtime_error("in-window note-on was not shifted to the render-window origin");
      }
      if (window_events[2].type != render::NoteEvent::EVENT_NOTE || window_events[2].on ||
          std::fabs(window_events[2].time_seconds - 0.03) > 1e-9) {
        throw std::runtime_error("in-window note-off was not shifted to the render-window origin");
      }
    }
    {
      std::vector<render::NoteEvent> ordered_events;
      std::vector<std::array<int, 3>> expected_controls;
      auto add_control = [&](int channel, int controller, int value) {
        render::NoteEvent control;
        control.channel = channel;
        control.type = render::NoteEvent::EVENT_CONTROL;
        control.controller = controller;
        control.value = value;
        ordered_events.push_back(control);
        expected_controls.push_back({channel, controller, value});
      };
      for (int channel = 0; channel < kMidiChannelCount; ++channel) {
        add_control(channel, kCcRpnLsb, kRpnPitchBendSensitivity);
        add_control(channel, kCcRpnMsb, 0);
        add_control(channel, kCcDataEntryMsb, kPitchBendRangeSemitones);
        add_control(channel, kCcRpnMsb, 0);
        add_control(channel, kCcRpnLsb, kRpnFineTune);
        add_control(channel, kCcDataEntryMsb, kFineTuneCenterMsb);
        add_control(channel, kCcDataEntryLsb, 0);
        add_control(channel, kCcRpnMsb, kRpnNull);
        add_control(channel, kCcRpnLsb, kRpnNull);
      }
      render::NoteEvent ordered_note;
      ordered_note.time_seconds = 0.01;
      ordered_note.channel = 7;
      ordered_note.note = 60;
      ordered_note.on = true;
      ordered_note.velocity = 100;
      ordered_events.push_back(ordered_note);
      render::NoteEvent ordered_bend;
      ordered_bend.time_seconds = 0.02;
      ordered_bend.channel = 7;
      ordered_bend.type = render::NoteEvent::EVENT_PITCH_BEND;
      ordered_bend.pitch_bend = kHalfPositivePitchBend;
      ordered_events.push_back(ordered_bend);

      std::vector<render::Region> ordered_regions;
      std::vector<int16_t> ordered_memory = sf2.file_words;
      render::prepare_events_and_regions(args, sf2, 48000, 480, ordered_events,
                                         ordered_regions, ordered_memory);
      size_t control_index = 0;
      for (const auto& event : ordered_events) {
        if (event.type != render::NoteEvent::EVENT_CONTROL) continue;
        if (control_index >= expected_controls.size() ||
            expected_controls[control_index] !=
                std::array<int, 3>{event.channel, event.controller, event.value}) {
          throw std::runtime_error("same-sample MIDI controls did not preserve source order");
        }
        ++control_index;
      }
      if (control_index != expected_controls.size()) {
        throw std::runtime_error("same-sample MIDI control sequence was truncated");
      }

      RecordingSink ordered_sink;
      render::McuModel ordered_mcu(ordered_sink, ordered_regions);
      for (const auto& event : ordered_events) ordered_mcu.handle_event(event);
      double ordered_bend_cents =
          kPitchWheelModulatorAmountCents *
          (double(ordered_bend.pitch_bend) / kPitchWheelCenter) *
          (double(kPitchBendRangeSemitones) / kMidiSourceRange);
      uint32_t expected_ordered_phase = uint32_t(std::round(
          double(ordered_regions[0].phase_inc) *
          std::pow(2.0, ordered_bend_cents / kCentsPerOctave)));
      if (ordered_sink.last_phase_inc != expected_ordered_phase) {
        throw std::runtime_error("ordered RPN sequence corrupted pitch-bend sensitivity");
      }
    }
    {
      render::NoteEvent source_note;
      source_note.note = 60;
      source_note.on = true;
      source_note.velocity = 100;
      render::NoteEvent source_sostenuto;
      source_sostenuto.type = render::NoteEvent::EVENT_CONTROL;
      source_sostenuto.controller = kCcSostenuto;
      source_sostenuto.value = 127;
      render::NoteEvent source_note_off = source_note;
      source_note_off.on = false;
      std::vector<render::NoteEvent> source_events{
          source_note, source_sostenuto, source_note_off};
      std::vector<render::Region> source_regions;
      std::vector<int16_t> source_memory = sf2.file_words;
      render::prepare_events_and_regions(args, sf2, 48000, 480, source_events,
                                         source_regions, source_memory);
      if (source_events.size() != 3 ||
          source_events[0].type != render::NoteEvent::EVENT_NOTE || !source_events[0].on ||
          source_events[1].type != render::NoteEvent::EVENT_CONTROL ||
          source_events[1].controller != kCcSostenuto ||
          source_events[2].type != render::NoteEvent::EVENT_NOTE || source_events[2].on) {
        throw std::runtime_error("same-sample MIDI events did not preserve source order");
      }
      RecordingSink source_sink;
      render::McuModel source_mcu(source_sink, source_regions);
      for (const auto& event : source_events) source_mcu.handle_event(event);
      if (source_sink.release_count != 0) {
        throw std::runtime_error("same-sample sostenuto did not capture the preceding note");
      }
      source_sostenuto.value = 0;
      source_mcu.handle_event(source_sostenuto);
      if (source_sink.release_count != 1) {
        throw std::runtime_error("same-sample sostenuto note was not released with the pedal");
      }
    }
    regions[0].preset = "Melodic \"Preset\"";
    regions[0].sample_left = "PianoC\\L";
    regions[0].modulators_by_destination[16].push_back({0x00db, 16, 300, 0, 0});
    regions[0].modulators_by_destination[15].push_back({0x00dd, 15, 800, 0, 0});
    regions[0].modulators_by_destination[8].push_back({0x0102, 8, -1100, 0x0d02, 0});
    render::write_summary("build/render_support_summary_test.json", regions, 48000, 16, int(events.size()), "");
    std::ifstream summary("build/render_support_summary_test.json");
    std::string summary_text((std::istreambuf_iterator<char>(summary)), std::istreambuf_iterator<char>());
    if (summary_text.find("\"presets\": [\"Melodic \\\"Preset\\\"\"") == std::string::npos ||
        summary_text.find("\"samples\": [\"PianoC\\\\L\"") == std::string::npos) {
      throw std::runtime_error("summary JSON did not escape nested sample metadata");
    }
    if (summary_text.find("\"report_schema_version\": 3") == std::string::npos ||
        summary_text.find("\"sf2_loader\": {\"region_count\": 2") == std::string::npos ||
        summary_text.find("\"sample_windows\": [") == std::string::npos ||
        summary_text.find("\"gain\": {\"pan\":") == std::string::npos ||
        summary_text.find("\"volume_envelopes\": [") == std::string::npos ||
        summary_text.find("\"filter\": {\"enable\":") == std::string::npos ||
        summary_text.find("\"loop_mode\":") == std::string::npos ||
        summary_text.find("\"modulation_profiles\": [") == std::string::npos ||
        summary_text.find("\"modulator_sets\": [") == std::string::npos ||
        summary_text.find("\"name\": \"cc7Volume\"") == std::string::npos ||
        summary_text.find("\"direction\": \"negative\"") == std::string::npos ||
        summary_text.find("\"polarity\": \"unipolar\"") == std::string::npos ||
        summary_text.find("{\"raw\": 48, \"name\": \"initialAttenuation\"}") == std::string::npos ||
        summary_text.find("\"name\": \"cc91ReverbSend\"") == std::string::npos ||
        summary_text.find("{\"raw\": 16, \"name\": \"reverbEffectsSend\"}") == std::string::npos ||
        summary_text.find("\"name\": \"cc93ChorusSend\"") == std::string::npos ||
        summary_text.find("{\"raw\": 15, \"name\": \"chorusEffectsSend\"}") == std::string::npos ||
        summary_text.find("\"hex\": \"0x0d02\", \"name\": \"noteOnVelocity\"") == std::string::npos) {
      throw std::runtime_error("summary JSON did not include normalized report catalogs");
    }
    std::vector<int16_t> hot_memory{32767, 32767, 32767, 32767};
    render::RenderDiagnostics hot_diag;
    hot_diag.detailed_enabled = true;
    render::ReferenceSynth hot_synth(hot_memory, &hot_diag);
    render::Region hot_region;
    hot_region.length = 4;
    hot_region.loop_end = 4;
    hot_region.phase_inc = render::kPhaseFracScale;
    hot_region.gain_l = render::kQ15Full;
    hot_region.gain_r = render::kQ15Full;
    render::CommandVoiceControl hot_control(hot_synth);
    hot_control.start_voice(0, hot_region.phase_inc, hot_region);
    hot_control.start_voice(1, hot_region.phase_inc, hot_region);
    hot_synth.render_sample();
    if (hot_diag.max_abs_mix_input_l <= 32767 ||
        hot_diag.max_abs_mix_input_r <= 32767) {
      throw std::runtime_error("saturation diagnostics did not record pre-saturation maxima");
    }
    render::RenderDiagnostics fast_diag;
    render::ReferenceSynth fast_synth(hot_memory, &fast_diag);
    render::CommandVoiceControl fast_control(fast_synth);
    fast_control.start_voice(0, hot_region.phase_inc, hot_region);
    fast_synth.render_sample();
    if (fast_diag.frames != 1 || fast_diag.max_abs_mix_input_l != 0 ||
        fast_diag.audible_envelope_updates != 0) {
      throw std::runtime_error("default diagnostics performed detailed sample-loop collection");
    }
    render::ReferenceSynth envelope_synth(hot_memory);
    render::Region envelope_region = hot_region;
    envelope_region.volume_envelope.attack_samples = 4;
    render::CommandVoiceControl envelope_control(envelope_synth);
    envelope_control.start_voice(0, envelope_region.phase_inc, envelope_region);
    envelope_synth.write_command_words(std::vector<uint32_t>{
        0x13000007u, 1u, 0u, 0x80000000u, 0u, 0u, 0u,
        render::envelope_release_step(envelope_region)});
    auto envelope_sample = envelope_synth.render_sample();
    if (envelope_sample.first < 16000 || envelope_sample.first > 17000)
      throw std::runtime_error("reference ENV_UPDATE did not replace attack step");
    envelope_synth.write_command_words(
        std::vector<uint32_t>{0x14000002u, 1u, 0u});
    if (envelope_synth.render_sample().first != 0)
      throw std::runtime_error("reference zero-step RELEASE did not stop immediately");

    std::vector<int16_t> delay_memory{0, 1000, 3000, 6000};
    render::ReferenceSynth delay_synth(delay_memory);
    delay_synth.write_command_words(std::vector<uint32_t>{
         0x10000d10u, 1u, 0u, 4u, 1u, 3u,
         0x00000180u, 0x7fff7fffu, 0x00002000u, 0x00002000u,
         0x00010000u, 2u, 0x80000000u, 0u, 0u, 0u, 0x01000000u});
    int delay_first = delay_synth.render_sample().first;
    int delay_transition = delay_synth.render_sample().first;
    int delay_attack = delay_synth.render_sample().first;
    if (delay_first != 0 || delay_transition != 0 || delay_attack != 249) {
      throw std::runtime_error("reference silent Delay outputs were " +
                               std::to_string(delay_first) + ", " +
                               std::to_string(delay_transition) + ", " +
                               std::to_string(delay_attack));
    }

    render::ReferenceSynth reverse_decay_synth(hot_memory);
    render::Region reverse_decay_region = hot_region;
    reverse_decay_region.volume_envelope.decay_samples = 1;
    reverse_decay_region.volume_envelope.sustain_cb_q12_20 = 60u << 20;
    render::CommandVoiceControl reverse_decay_control(reverse_decay_synth);
    reverse_decay_control.start_voice(0, reverse_decay_region.phase_inc, reverse_decay_region);
    reverse_decay_synth.render_sample();
    reverse_decay_synth.write_command_words(std::vector<uint32_t>{
         0x13000007u, 1u, 0u, 0xffffffffu, 0u, 10u << 20,
         20u << 20, render::envelope_release_step(reverse_decay_region)});
    int reverse_decay_first = reverse_decay_synth.render_sample().first;
    int reverse_decay_second = reverse_decay_synth.render_sample().first;
    if (reverse_decay_second <= reverse_decay_first) {
      throw std::runtime_error("reference ENV_UPDATE did not decay downward toward lower attenuation");
    }
    std::string diagnostics_text = render::diagnostics_json_fields(hot_diag);
    if (diagnostics_text.find("diagnostics_max_abs_filter_y_input") == std::string::npos ||
        diagnostics_text.find("diagnostics_max_abs_voice_contribution_input_l") == std::string::npos ||
        diagnostics_text.find("diagnostics_max_abs_mix_input_r") == std::string::npos ||
        diagnostics_text.find("diagnostics_compressor_gain_reduction_cb_q12_20") ==
            std::string::npos ||
        diagnostics_text.find("diagnostics_compressor_saturation_count") ==
            std::string::npos ||
        diagnostics_text.find("diagnostics_max_voice_steal_score") == std::string::npos ||
        diagnostics_text.find("diagnostics_max_audible_envelope_jump_frame") == std::string::npos) {
      throw std::runtime_error("diagnostics JSON did not include pre-saturation maxima");
    }
    render::Args input_args;
    input_args.sf2 = "/tmp/example.sf2";
    input_args.midi = "/tmp/example.mid";
    input_args.instrument = "Piano";
    input_args.start_seconds = 144.0;
    input_args.seconds = 12.5;
    input_args.control_tick_ms = 1.0;
    std::string input_json = render::render_input_json_fields(input_args, 48);
    if (input_json.find("\"sf2_path\": \"/tmp/example.sf2\"") == std::string::npos ||
        input_json.find("\"midi_path\": \"/tmp/example.mid\"") == std::string::npos ||
        input_json.find("\"uses_default_melody\": false") == std::string::npos ||
        input_json.find("\"instrument_override\": \"Piano\"") == std::string::npos ||
        input_json.find("\"start_seconds\": 144") == std::string::npos ||
        input_json.find("\"control_update_mode\": \"periodic\"") == std::string::npos ||
        input_json.find("\"control_tick_ms_ignored\": false") == std::string::npos ||
        input_json.find("\"control_tick_samples\": 48") == std::string::npos ||
        input_json.find("\"render_num_voices\": ") == std::string::npos) {
      throw std::runtime_error("input JSON fields did not include render provenance");
    }
    if (input_json.find("memory_profile") != std::string::npos) {
      throw std::runtime_error("generic input JSON fields included memory profile");
    }
    if (render::memory_profile_json_field(input_args).find("\"memory_profile\": \"ddr\"") == std::string::npos) {
      throw std::runtime_error("memory profile JSON field did not record memory profile");
    }
    if (render::control_tick_samples(input_args) != 48) {
      throw std::runtime_error("control tick sample count was not derived from control tick ms");
    }
    render::RenderInputs move_inputs;
    move_inputs.sf2.file_words = {1, 2, 3, 4};
    const int16_t* original_wave_data = move_inputs.sf2.file_words.data();
    std::vector<int16_t> moved_wave = render::take_sf2_wave_memory(move_inputs);
    if (!move_inputs.sf2.file_words.empty() || moved_wave.data() != original_wave_data) {
      throw std::runtime_error("SF2 wave memory was copied instead of transferred");
    }

    render::Region timeline_region;
    timeline_region.length = 4;
    timeline_region.loop_end = 4;
    timeline_region.phase_inc = render::kPhaseFracScale;
    std::vector<render::Region> timeline_regions{timeline_region};
    RecordingSink timeline_sink;
    render::McuModel timeline_mcu(timeline_sink, timeline_regions);
    render::NoteEvent timeline_on;
    timeline_on.sample = 2;
    timeline_on.on = true;
    timeline_on.velocity = 100;
    timeline_on.phase_inc = timeline_region.phase_inc;
    render::NoteEvent timeline_off = timeline_on;
    timeline_off.sample = 3;
    timeline_off.on = false;
    std::vector<render::NoteEvent> timeline_events{timeline_on, timeline_off};
    render::RenderTimeline timeline(timeline_events, 4, timeline_mcu);
    timeline.advance_to(1);
    if (timeline_sink.commit_count != 0) {
      throw std::runtime_error("render timeline dispatched an event early");
    }
    timeline.advance_to(2);
    if (timeline_sink.commit_count != 1) {
      throw std::runtime_error("render timeline missed note-on sample");
    }
    timeline.advance_to(3);
    if (timeline_sink.release_count != 1) {
      throw std::runtime_error("render timeline missed note-off sample");
    }
    input_args.sample_accurate_control = true;
    if (render::control_tick_samples(input_args) != 1) {
      throw std::runtime_error("sample-accurate control mode did not force one-sample ticks");
    }
    input_json = render::render_input_json_fields(input_args, 1);
    if (input_json.find("\"control_update_mode\": \"sample_accurate\"") == std::string::npos ||
        input_json.find("\"control_tick_ms_ignored\": true") == std::string::npos ||
        input_json.find("\"control_tick_samples\": 1") == std::string::npos) {
      throw std::runtime_error("input JSON fields did not record sample-accurate control mode");
    }
    input_args.midi.clear();
    input_args.instrument.clear();
    input_args.sample_accurate_control = false;
    input_json = render::render_input_json_fields(input_args, 240);
    if (input_json.find("\"midi_path\": null") == std::string::npos ||
        input_json.find("\"uses_default_melody\": true") == std::string::npos ||
        input_json.find("\"instrument_override\": null") == std::string::npos) {
      throw std::runtime_error("input JSON fields did not mark default inputs");
    }
    const char* sample_accurate_argv[] = {"render", "--sample-rate", "48000",
                                          "--control-tick-ms", "123",
                                          "--sample-accurate-control"};
    render::Args parsed_sample_accurate = render::parse_args(6, const_cast<char**>(sample_accurate_argv));
    if (!parsed_sample_accurate.sample_accurate_control ||
        render::control_tick_samples(parsed_sample_accurate) != 1) {
      throw std::runtime_error("sample-accurate control argument did not ignore control tick ms");
    }
    const char* start_seconds_argv[] = {"render", "--start-seconds", "144", "--seconds", "30"};
    render::Args parsed_start = render::parse_args(5, const_cast<char**>(start_seconds_argv));
    if (parsed_start.start_seconds != 144.0 || parsed_start.seconds != 30.0) {
      throw std::runtime_error("start-seconds argument was not parsed");
    }
    const char* compressor_argv[] = {
        "render", "--compressor-enable", "--compressor-threshold-cb", "120",
        "--compressor-ratio", "4", "--compressor-attack-ms", "0",
        "--compressor-release-ms", "100", "--master-volume", "0.75"};
    render::Args parsed_compressor =
        render::parse_args(12, const_cast<char**>(compressor_argv));
    if (!parsed_compressor.compressor_enable ||
        parsed_compressor.compressor_threshold_cb != 120.0 ||
        parsed_compressor.compressor_ratio != 4.0 ||
        parsed_compressor.compressor_attack_ms != 0.0 ||
        parsed_compressor.compressor_release_ms != 100.0 ||
        parsed_compressor.master_volume != 0.75) {
      throw std::runtime_error("compressor arguments were not parsed");
    }
    const char* effects_argv[] = {
        "render", "--effects-preset", "hall", "--chorus-enable", "off",
        "--reverb-enable", "on", "--effects-tail-seconds", "3.5"};
    render::Args parsed_effects =
        render::parse_args(9, const_cast<char**>(effects_argv));
    if (parsed_effects.effects_preset != "hall" ||
        parsed_effects.chorus_enable != "off" ||
        parsed_effects.reverb_enable != "on" ||
        parsed_effects.effects_tail_seconds != 3.5) {
      throw std::runtime_error("effects arguments were not parsed");
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
    mod_mcu.control_tick();
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
    steady_filter_diag.detailed_enabled = true;
    render::McuModel steady_filter_mcu(steady_filter_sink, steady_filter_regions, &steady_filter_diag);
    render::NoteEvent steady_filter_note;
    steady_filter_note.on = true;
    steady_filter_note.velocity = 100;
    steady_filter_note.phase_inc = steady_filter_region.phase_inc;
    steady_filter_mcu.handle_event(steady_filter_note);
    int steady_filter_writes = steady_filter_sink.filter_count;
    steady_filter_mcu.control_tick();
    steady_filter_mcu.control_tick();
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
    steady_runtime_diag.detailed_enabled = true;
    render::McuModel steady_runtime_mcu(steady_runtime_sink, steady_runtime_regions, &steady_runtime_diag);
    render::NoteEvent steady_runtime_note;
    steady_runtime_note.on = true;
    steady_runtime_note.velocity = 100;
    steady_runtime_note.phase_inc = steady_runtime_region.phase_inc;
    steady_runtime_mcu.handle_event(steady_runtime_note);
    int steady_gain_writes = steady_runtime_sink.gain_count;
    int steady_phase_writes = steady_runtime_sink.phase_count;
    int steady_filter_runtime_writes = steady_runtime_sink.filter_count;
    steady_runtime_mcu.control_tick();
    steady_runtime_mcu.control_tick();
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
    rpn_msb.controller = kCcRpnMsb;
    rpn_msb.value = 0;
    render::NoteEvent rpn_lsb = rpn_msb;
    rpn_lsb.controller = kCcRpnLsb;
    render::NoteEvent data_entry = rpn_msb;
    data_entry.controller = kCcDataEntryMsb;
    data_entry.value = kPitchBendRangeSemitones;
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
    wide_bend.pitch_bend = kHalfPositivePitchBend;
    bend_range_mcu.handle_event(wide_bend);
    double wide_bend_cents =
        kPitchWheelModulatorAmountCents *
        (double(wide_bend.pitch_bend) / kPitchWheelCenter) *
        (double(data_entry.value) / kMidiSourceRange);
    uint32_t wide_bent = uint32_t(std::round(double(render::kPhaseFracScale) *
                                             std::pow(2.0, wide_bend_cents / kCentsPerOctave)));
    if (bend_range_sink.last_phase_inc != wide_bent) {
      throw std::runtime_error("RPN pitch-bend sensitivity did not widen bend range");
    }
    render::NoteEvent data_entry_lsb = data_entry;
    data_entry_lsb.controller = kCcDataEntryLsb;
    data_entry_lsb.value = 50;
    bend_range_mcu.handle_event(data_entry_lsb);
    bend_range_mcu.handle_event(wide_bend);
    double fractional_range = double(data_entry.value) +
                              double(data_entry_lsb.value) / kCentsPerSemitone;
    double fractional_bend_cents =
        kPitchWheelModulatorAmountCents *
        (double(wide_bend.pitch_bend) / kPitchWheelCenter) *
        (fractional_range / kMidiSourceRange);
    uint32_t fractional_bent = uint32_t(std::round(double(bend_range_region.phase_inc) *
        std::pow(2.0, fractional_bend_cents / kCentsPerOctave)));
    if (bend_range_sink.last_phase_inc != fractional_bent) {
      throw std::runtime_error("RPN pitch-bend sensitivity ignored Data Entry LSB cents");
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
    default_vibrato_mcu.control_tick();
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
    custom_mod_region.modulators_by_destination[6].push_back({0x0081, 6, 200, 0, 0});
    std::vector<render::Region> custom_mod_regions{custom_mod_region};
    RecordingSink custom_mod_sink;
    render::McuModel custom_mod_mcu(custom_mod_sink, custom_mod_regions);
    custom_mod_mcu.handle_event(mod_wheel);
    render::NoteEvent custom_mod_note = default_vibrato_note;
    custom_mod_mcu.handle_event(custom_mod_note);
    custom_mod_mcu.control_tick();
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
    tremolo_mcu.control_tick();
    int tremolo_boosted_base = int(std::round(double(tremolo_region.base_gain) *
                                              std::pow(10.0, 100.0 / 200.0)));
    int tremolo_gain = expected_pan_gain(tremolo_boosted_base, 0, true);
    if (tremolo_sink.last_gain_l != tremolo_gain || tremolo_sink.last_gain_r != tremolo_gain) {
      throw std::runtime_error("modLfoToVolume did not boost runtime gain on positive LFO excursion");
    }
    tremolo_mcu.control_tick();
    tremolo_mcu.control_tick();
    int tremolo_attenuated_base = int(std::round(double(tremolo_region.base_gain) *
                                                 std::pow(10.0, -100.0 / 200.0)));
    int tremolo_dip = expected_pan_gain(tremolo_attenuated_base, 0, true);
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
    soft_on.controller = kCcSoftPedal;
    soft_on.value = 127;
    soft_mcu.handle_event(soft_on);
    soft_mcu.handle_event(tremolo_note);
    int soft_attenuated_base = int(std::round(double(pedal_region.base_gain) *
                                              std::pow(10.0, -30.0 / 200.0)));
    int soft_gain = expected_pan_gain(soft_attenuated_base, 0, true);
    if (soft_sink.last_gain_l != soft_gain || soft_sink.last_gain_r != soft_gain) {
      throw std::runtime_error("CC67 soft pedal did not attenuate runtime gain");
    }

    RecordingSink sostenuto_sink;
    render::McuModel sostenuto_mcu(sostenuto_sink, pedal_regions);
    sostenuto_mcu.handle_event(tremolo_note);
    render::NoteEvent sostenuto_on = soft_on;
    sostenuto_on.controller = kCcSostenuto;
    sostenuto_mcu.handle_event(sostenuto_on);
    render::NoteEvent pedal_note_off = tremolo_note;
    pedal_note_off.on = false;
    sostenuto_mcu.handle_event(pedal_note_off);
    if (sostenuto_sink.release_count != 0) {
      throw std::runtime_error("CC66 sostenuto released a captured note too early");
    }
    render::NoteEvent sostenuto_off = sostenuto_on;
    sostenuto_off.value = 0;
    sostenuto_mcu.handle_event(sostenuto_off);
    if (sostenuto_sink.release_count != 1) {
      throw std::runtime_error("CC66 sostenuto did not release captured note");
    }

    RecordingSink all_notes_sustain_sink;
    render::McuModel all_notes_sustain_mcu(all_notes_sustain_sink, pedal_regions);
    all_notes_sustain_mcu.handle_event(tremolo_note);
    render::NoteEvent sustain_on = soft_on;
    sustain_on.controller = kCcSustain;
    all_notes_sustain_mcu.handle_event(sustain_on);
    render::NoteEvent pedal_all_notes_off = sustain_on;
    pedal_all_notes_off.controller = kCcAllNotesOff;
    pedal_all_notes_off.value = 0;
    all_notes_sustain_mcu.handle_event(pedal_all_notes_off);
    if (all_notes_sustain_sink.release_count != 0) {
      throw std::runtime_error("All Notes Off overrode the sustain pedal");
    }
    sustain_on.value = 0;
    all_notes_sustain_mcu.handle_event(sustain_on);
    if (all_notes_sustain_sink.release_count != 1) {
      throw std::runtime_error("sustain release did not finish deferred All Notes Off");
    }

    for (int mode_controller = 124; mode_controller <= 127; ++mode_controller) {
      RecordingSink mode_sink;
      render::McuModel mode_mcu(mode_sink, pedal_regions);
      mode_mcu.handle_event(tremolo_note);
      render::NoteEvent mode = pedal_all_notes_off;
      mode.controller = mode_controller;
      mode_mcu.handle_event(mode);
      if (mode_sink.release_count != 1) {
        throw std::runtime_error("channel mode message did not perform All Notes Off");
      }
    }

    RecordingSink repeated_note_sink;
    render::McuModel repeated_note_mcu(repeated_note_sink, pedal_regions);
    repeated_note_mcu.handle_event(tremolo_note);
    repeated_note_mcu.handle_event(tremolo_note);
    render::NoteEvent repeated_note_off = tremolo_note;
    repeated_note_off.on = false;
    repeated_note_mcu.handle_event(repeated_note_off);
    if (repeated_note_sink.release_count != 1) {
      throw std::runtime_error("one Note Off did not release exactly one repeated Note On");
    }
    repeated_note_mcu.handle_event(repeated_note_off);
    if (repeated_note_sink.release_count != 2) {
      throw std::runtime_error("second Note Off did not release the remaining repeated Note On");
    }

    render::Region poly_pressure_region;
    poly_pressure_region.length = 4;
    poly_pressure_region.loop_end = 4;
    poly_pressure_region.phase_inc = render::kPhaseFracScale;
    poly_pressure_region.vib_lfo_step = 0x4000;
    poly_pressure_region.modulators_by_destination[6].push_back({0x000a, 6, 200, 0, 0});
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
    int nrpn_data14 = nrpn.value << 7;
    int nrpn_pan = int(std::round(double(nrpn_data14 - 0x2000) / 8192.0 * 1000.0));
    int expected_nrpn_left = expected_pan_gain(pedal_region.base_gain, nrpn_pan, true);
    int expected_nrpn_right = expected_pan_gain(pedal_region.base_gain, nrpn_pan, false);
    if (nrpn_sink.last_gain_l != expected_nrpn_left ||
        nrpn_sink.last_gain_r != expected_nrpn_right) {
      throw std::runtime_error("SF2 NRPN pan offset did not update runtime gain");
    }

    render::NoteEvent folded_attack_note;
    folded_attack_note.on = true;
    folded_attack_note.velocity = 127;
    folded_attack_note.phase_inc = render::kPhaseFracScale;

    render::Region folded_mod_attack_region;
    folded_mod_attack_region.length = 4;
    folded_mod_attack_region.loop_end = 4;
    folded_mod_attack_region.phase_inc = render::kPhaseFracScale;
    folded_mod_attack_region.mod_env_attack_ticks = 4;
    folded_mod_attack_region.mod_env_attack_sub_tick = true;
    folded_mod_attack_region.mod_env_to_pitch = 1200;
    folded_mod_attack_region.gain_l = 0x4000;
    folded_mod_attack_region.gain_r = 0x4000;
    std::vector<render::Region> folded_mod_attack_regions{folded_mod_attack_region};
    RecordingSink folded_mod_attack_sink;
    render::McuModel folded_mod_attack_mcu(folded_mod_attack_sink, folded_mod_attack_regions);
    folded_mod_attack_mcu.handle_event(folded_attack_note);
    if (folded_mod_attack_sink.last_phase_inc <= render::kPhaseFracScale * 19 / 10) {
      throw std::runtime_error("sub-tick modulation attack was not folded before initial controls");
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
    int expected_pan_left = expected_pan_gain(pan_region.base_gain, pan_region.pan, true);
    int expected_pan_right = expected_pan_gain(pan_region.base_gain, pan_region.pan, false);
    if (pan_sink.last_gain_l != expected_pan_left || pan_sink.last_gain_r != expected_pan_right) {
      throw std::runtime_error("SF2 pan did not use the equal-power runtime balance");
    }
    render::NoteEvent pan_cc = pan_note;
    pan_cc.type = render::NoteEvent::EVENT_CONTROL;
    pan_cc.controller = 10;
    pan_cc.value = 0;
    pan_mcu.handle_event(pan_cc);
    int cc10_zero_pan = pan_region.pan - 500;
    int expected_cc10_left = expected_pan_gain(pan_region.base_gain, cc10_zero_pan, true);
    int expected_cc10_right = expected_pan_gain(pan_region.base_gain, cc10_zero_pan, false);
    if (pan_sink.last_gain_l != expected_cc10_left || pan_sink.last_gain_r != expected_cc10_right) {
      throw std::runtime_error("CC10 pan did not use the FluidSynth-compatible amount");
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
    release_newer.note_instance = render::kNumVoices;
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
    audible_steal_mcu.control_tick();
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
