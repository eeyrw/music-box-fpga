#include "host/realtime_region_bank.h"

#include <stdexcept>
#include <string>

namespace {

class NullVoiceSink final : public render::VoiceCommandSink {
 public:
  void start_voice(int, uint32_t, const render::Region&) override {}
  void update_gain_phase(int, int, int, uint32_t) override {}
  void update_filter(int, const render::FilterConfig&) override {}
  void release_voice(int, uint32_t) override {}
  void stop_voice(int) override {}
};

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) throw std::runtime_error("expected SF2 fixture path");
  render::Sf2Data sf2 = render::load_sf2(argv[1]);
  host::RealtimeRegionBank bank(sf2, 48000, 240, 1, 64);
  NullVoiceSink sink;
  render::McuModel mcu(sink, bank.regions());

  const std::vector<int>& first = bank.regions_for_preset(0, 0, 60, 100, mcu);
  if (first.empty()) throw std::runtime_error("fixture C4 preset was empty");
  const int active_region = first.front();
  render::NoteEvent note;
  note.type = render::NoteEvent::EVENT_NOTE;
  note.on = true;
  note.note = 60;
  note.velocity = 100;
  note.region = active_region;
  note.phase_inc = bank.regions().at(std::size_t(active_region)).phase_inc;
  mcu.handle_event(note);

  bool rejected = false;
  try {
    (void)bank.regions_for_preset(0, 0, 61, 100, mcu);
  } catch (const std::overflow_error&) {
    rejected = true;
  }
  if (!rejected) throw std::runtime_error("active region cache entry was evicted");

  render::NoteEvent stop;
  stop.type = render::NoteEvent::EVENT_CONTROL;
  stop.controller = 120;
  mcu.handle_event(stop);
  (void)bank.regions_for_preset(0, 0, 61, 100, mcu);
  const host::RealtimeRegionBankStats stats = bank.stats();
  if (stats.evictions != 1 || stats.rejected_lookups != 1 || stats.entries != 1) {
    throw std::runtime_error("real-time region cache accounting mismatch");
  }
  return 0;
}
