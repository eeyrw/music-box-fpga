#include "host/ch347_transport.h"
#include "host/command_scheduler.h"
#include "host/mcu_sf2_asset_runtime.h"
#include "host/realtime_midi.h"
#include "host/realtime_region_bank.h"
#include "sim/harness/control/command_control.h"
#include "sim/harness/formats/midi_parser.h"
#include "sim/harness/formats/sf2_loader.h"
#include "sim/harness/render/render_support.h"

#include <atomic>
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <filesystem>
#include <iostream>
#include <iterator>
#include <limits>
#include <memory>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

struct Args {
  std::string sf2 = "assets/soundfonts/MT6276.sf2";
  std::string midi_input;
  std::string midi_file;
  std::string mcu_asset;
  int sample_rate = 48000;
  double control_tick_ms = 5.0;
  int run_ms = 0;
  int midi_tail_ms = 1000;
  bool dry_run = false;
  host::Ch347Options ch347;
};

volatile std::sig_atomic_t stop_requested = 0;

void signal_handler(int) { stop_requested = 1; }

uint64_t monotonic_ns() {
  return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
      Clock::now().time_since_epoch()).count());
}

std::string require_value(int argc, char** argv, int& index) {
  if (++index >= argc) throw std::runtime_error("missing value after " + std::string(argv[index - 1]));
  return argv[index];
}

Args parse_args(int argc, char** argv) {
  Args args;
  for (int index = 1; index < argc; ++index) {
    const std::string option = argv[index];
    if (option == "--sf2") args.sf2 = require_value(argc, argv, index);
    else if (option == "--midi-input") args.midi_input = require_value(argc, argv, index);
    else if (option == "--midi-file") args.midi_file = require_value(argc, argv, index);
    else if (option == "--mcu-asset") args.mcu_asset = require_value(argc, argv, index);
    else if (option == "--sample-rate") args.sample_rate = std::stoi(require_value(argc, argv, index));
    else if (option == "--control-tick-ms") args.control_tick_ms = std::stod(require_value(argc, argv, index));
    else if (option == "--run-ms") args.run_ms = std::stoi(require_value(argc, argv, index));
    else if (option == "--midi-tail-ms") args.midi_tail_ms = std::stoi(require_value(argc, argv, index));
    else if (option == "--dry-run") args.dry_run = true;
    else if (option == "--library") args.ch347.library_path = require_value(argc, argv, index);
    else if (option == "--device") args.ch347.device_path = require_value(argc, argv, index);
    else if (option == "--clock-hz") args.ch347.clock_hz = std::stoi(require_value(argc, argv, index));
    else if (option == "--help") {
      std::cout
          << "usage: realtime_midi_host [--sf2 PATH] [--mcu-asset PATH]\n"
          << "       [--midi-input PATH|- | --midi-file PATH]\n"
          << "       [--dry-run] [--sample-rate HZ] [--control-tick-ms MS]\n"
          << "       [--run-ms MS] [--midi-tail-ms MS]\n"
          << "       [--library PATH] [--device PATH] [--clock-hz HZ]\n";
      std::exit(0);
    } else {
      throw std::runtime_error("unknown option: " + option);
    }
  }
  if (!args.midi_input.empty() && !args.midi_file.empty()) {
    throw std::runtime_error("--midi-input and --midi-file are mutually exclusive");
  }
  if (args.midi_input.empty() && args.midi_file.empty()) {
    args.midi_input = "/dev/snd/midiC0D0";
  }
  if (args.sample_rate <= 0 || args.control_tick_ms <= 0.0 ||
      args.run_ms < 0 || args.midi_tail_ms < 0) {
    throw std::runtime_error(
        "sample rate and control tick must be positive; run-ms and midi-tail-ms must be nonnegative");
  }
  return args;
}

std::vector<uint8_t> read_binary_file(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("cannot open MCU SF2 asset: " + path);
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(input), {});
}

int open_midi_input(const std::string& path) {
  const int fd = path == "-" ? ::dup(STDIN_FILENO)
                             : ::open(path.c_str(), O_RDONLY | O_NONBLOCK);
  if (fd < 0) {
    throw std::runtime_error("cannot open MIDI input " + path + ": " +
                             std::strerror(errno));
  }
  if (path == "-") {
    const int flags = ::fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
  }
  return fd;
}

class MidiInputWorker {
 public:
  MidiInputWorker(int fd, host::BoundedMidiEventQueue& queue)
      : fd_(fd), queue_(queue), worker_(&MidiInputWorker::run, this) {}
  ~MidiInputWorker() { stop(); }

  void stop() {
    stopping_.store(true);
    if (worker_.joinable()) worker_.join();
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
  }
  bool disconnected() const { return disconnected_.load(); }
  bool lifecycle_overflow() const { return lifecycle_overflow_.load(); }
  uint64_t read_errors() const { return read_errors_.load(); }

 private:
  void run() {
    host::MidiStreamDecoder decoder;
    std::array<uint8_t, 256> bytes{};
    while (!stopping_.load()) {
      pollfd descriptor{fd_, POLLIN, 0};
      const int ready = ::poll(&descriptor, 1, 20);
      if (ready < 0) {
        if (errno == EINTR) continue;
        ++read_errors_;
        disconnected_.store(true);
        return;
      }
      if (ready == 0) continue;
      if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 &&
          (descriptor.revents & POLLIN) == 0) {
        disconnected_.store(true);
        return;
      }
      const ssize_t count = ::read(fd_, bytes.data(), bytes.size());
      const uint64_t ingress_ns = monotonic_ns();
      if (count == 0) {
        disconnected_.store(true);
        return;
      }
      if (count < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
        ++read_errors_;
        disconnected_.store(true);
        return;
      }
      for (ssize_t index = 0; index < count; ++index) {
        host::TimestampedMidiEvent event;
        if (!decoder.feed(bytes[std::size_t(index)], ingress_ns, event)) continue;
        const auto result = queue_.push(event);
        if (result == host::BoundedMidiEventQueue::PushResult::kLifecycleOverflow) {
          lifecycle_overflow_.store(true);
          return;
        }
      }
    }
  }

  int fd_ = -1;
  host::BoundedMidiEventQueue& queue_;
  std::atomic<bool> stopping_{false};
  std::atomic<bool> disconnected_{false};
  std::atomic<bool> lifecycle_overflow_{false};
  std::atomic<uint64_t> read_errors_{0};
  std::thread worker_;
};

void all_sound_off(render::McuModel& mcu,
                   host::AsyncCommandScheduler& scheduler) {
  auto batch = scheduler.batch();
  for (int channel = 0; channel < 16; ++channel) {
    render::NoteEvent event;
    event.type = render::NoteEvent::EVENT_CONTROL;
    event.channel = channel;
    event.controller = 120;
    event.value = 0;
    mcu.handle_event(event);
  }
}

struct RuntimeStats {
  uint64_t note_on_events = 0;
  uint64_t unmapped_note_ons = 0;
  uint64_t note_on_enqueue_total_ns = 0;
  uint64_t note_on_enqueue_max_ns = 0;
  uint64_t scheduling_jitter_max_ns = 0;
};

void handle_midi_event(const host::TimestampedMidiEvent& input,
                       host::RealtimeRegionBank& region_bank,
                       render::McuModel& mcu,
                       host::AsyncCommandScheduler& scheduler,
                       uint64_t& next_note_instance,
                       RuntimeStats& stats) {
  if (input.event.type != render::NoteEvent::EVENT_NOTE || !input.event.on) {
    auto batch = scheduler.batch();
    mcu.handle_event(input.event);
    return;
  }

  ++stats.note_on_events;
  const int bank = input.event.channel == 9 ? 128 : input.event.bank;
  const std::vector<int>& regions = region_bank.regions_for_preset(
      input.event.program, bank, input.event.note, input.event.velocity, mcu);
  if (regions.empty()) {
    ++stats.unmapped_note_ons;
  } else {
    auto batch = scheduler.batch();
    const uint64_t note_instance = ++next_note_instance;
    for (int region_index : regions) {
      render::NoteEvent event = input.event;
      event.bank = bank;
      event.region = region_index;
      event.phase_inc = region_bank.regions().at(std::size_t(region_index)).phase_inc;
      event.note_instance = note_instance;
      mcu.handle_event(event);
    }
  }
  const uint64_t elapsed = monotonic_ns() - input.timestamp_ns;
  stats.note_on_enqueue_total_ns += elapsed;
  stats.note_on_enqueue_max_ns = std::max(stats.note_on_enqueue_max_ns, elapsed);
}

void handle_compiled_midi_event(const host::TimestampedMidiEvent& input,
                                host::McuSf2AssetRuntime& compiled,
                                host::AsyncCommandScheduler& scheduler,
                                RuntimeStats& stats) {
  auto batch = scheduler.batch();
  const auto& event = input.event;
  if (event.type == render::NoteEvent::EVENT_NOTE) {
    if (event.on && event.velocity != 0) {
      ++stats.note_on_events;
      const int bank = event.channel == 9 ? 128 : event.bank;
      if (compiled.note_on(uint8_t(event.channel), uint16_t(event.program),
                           uint16_t(bank), uint8_t(event.note),
                           uint8_t(event.velocity)) == 0) {
        ++stats.unmapped_note_ons;
      }
      const uint64_t elapsed = monotonic_ns() - input.timestamp_ns;
      stats.note_on_enqueue_total_ns += elapsed;
      stats.note_on_enqueue_max_ns = std::max(stats.note_on_enqueue_max_ns, elapsed);
    } else {
      compiled.note_off(uint8_t(event.channel), uint8_t(event.note));
    }
  } else if (event.type == render::NoteEvent::EVENT_CONTROL) {
    compiled.control_change(uint8_t(event.channel), uint8_t(event.controller),
                            uint8_t(event.value));
  } else if (event.type == render::NoteEvent::EVENT_PITCH_BEND) {
    compiled.pitch_bend(uint8_t(event.channel), int16_t(event.pitch_bend));
  } else if (event.type == render::NoteEvent::EVENT_CHANNEL_PRESSURE) {
    compiled.channel_pressure(uint8_t(event.channel), uint8_t(event.value));
  } else if (event.type == render::NoteEvent::EVENT_KEY_PRESSURE) {
    compiled.key_pressure(uint8_t(event.channel), uint8_t(event.note),
                          uint8_t(event.value));
  }
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const Args args = parse_args(argc, argv);
    const int tick_samples = std::max(
        1, int(std::llround(args.control_tick_ms * double(args.sample_rate) / 1000.0)));
    const auto tick_period = std::chrono::nanoseconds(
        std::max<int64_t>(1, int64_t(std::llround(args.control_tick_ms * 1000000.0))));

    // File parsing, SF2 loading, and compiled lookup construction all finish
    // before the real-time clock starts or a raw MIDI device is opened.
    std::vector<render::NoteEvent> midi_file_events;
    if (!args.midi_file.empty()) {
      midi_file_events = render::parse_midi(args.midi_file);
    }
    render::Sf2Data sf2 = render::load_sf2(args.sf2);
    std::vector<uint8_t> compiled_asset_bytes;
    std::unique_ptr<render::McuSf2AssetView> compiled_asset_view;
    if (!args.mcu_asset.empty()) {
      compiled_asset_bytes = read_binary_file(args.mcu_asset);
      compiled_asset_view = std::make_unique<render::McuSf2AssetView>(
          compiled_asset_bytes.data(), compiled_asset_bytes.size());
      if (!compiled_asset_view->matches_source(
              sf2, std::filesystem::file_size(args.sf2))) {
        throw std::runtime_error("MCU SF2 sidecar/source identity mismatch");
      }
    }

    std::unique_ptr<render::CommandWordSink> transport;
    if (args.dry_run) {
      transport = std::make_unique<host::DryRunCommandTransport>();
    } else {
      transport = std::make_unique<host::Ch347CommandTransport>(args.ch347);
    }
    host::AsyncCommandScheduler scheduler(std::move(transport));
    render::RenderDiagnostics diagnostics;
    std::unique_ptr<host::RealtimeRegionBank> region_bank;
    std::unique_ptr<render::CommandVoiceControl> command_control;
    std::unique_ptr<render::McuModel> mcu;
    std::unique_ptr<host::McuSf2AssetRuntime> compiled_runtime;
    if (compiled_asset_view) {
      compiled_runtime = std::make_unique<host::McuSf2AssetRuntime>(
          *compiled_asset_view, scheduler);
    } else {
      region_bank = std::make_unique<host::RealtimeRegionBank>(
          sf2, args.sample_rate, tick_samples);
      command_control = std::make_unique<render::CommandVoiceControl>(scheduler);
      mcu = std::make_unique<render::McuModel>(
          *command_control, region_bank->regions(), &diagnostics,
          render::ControlUpdateRates{1, 1, 4});
    }

    host::BoundedMidiEventQueue midi_queue;
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    RuntimeStats runtime;
    uint64_t next_note_instance = 0;
    bool fatal = false;
    const auto start = Clock::now();
    const uint64_t start_ns = uint64_t(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            start.time_since_epoch()).count());
    std::unique_ptr<MidiInputWorker> midi_input;
    std::unique_ptr<host::MidiFilePlayback> midi_file;
    if (args.midi_file.empty()) {
      midi_input = std::make_unique<MidiInputWorker>(
          open_midi_input(args.midi_input), midi_queue);
    } else {
      midi_file = std::make_unique<host::MidiFilePlayback>(
          std::move(midi_file_events), start_ns);
    }
    auto next_tick = start + tick_period;
    while (stop_requested == 0) {
      const auto now = Clock::now();
      const uint64_t now_ns = uint64_t(
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              now.time_since_epoch()).count());
      if (args.run_ms != 0 && now - start >= std::chrono::milliseconds(args.run_ms)) break;
      if (midi_file) midi_file->enqueue_due(now_ns, midi_queue);
      const bool lifecycle_overflow =
          midi_input ? midi_input->lifecycle_overflow()
                     : midi_file->lifecycle_overflow();
      if (lifecycle_overflow) {
        std::cerr << "error: lifecycle MIDI queue reserve exhausted\n";
        fatal = true;
        break;
      }
      if (scheduler.stats().consecutive_transport_errors >= 100) {
        std::cerr << "error: CH347 command transport failed 100 consecutive times\n";
        fatal = true;
        break;
      }

      const uint64_t elapsed_ns = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
          now - start).count());
      const uint64_t sample =
          (elapsed_ns / 1000000000ull) * uint64_t(args.sample_rate) +
          ((elapsed_ns % 1000000000ull) * uint64_t(args.sample_rate)) /
              1000000000ull;
      if (mcu) mcu->set_current_sample(uint32_t(sample));

      host::TimestampedMidiEvent event;
      while (midi_queue.pop(event)) {
        try {
          if (compiled_runtime) {
            handle_compiled_midi_event(event, *compiled_runtime, scheduler, runtime);
          } else {
            handle_midi_event(event, *region_bank, *mcu, scheduler,
                              next_note_instance, runtime);
          }
        } catch (const std::exception& error) {
          std::cerr << "error: MIDI event handling failed: " << error.what() << '\n';
          fatal = true;
          break;
        }
      }
      if (fatal) break;

      auto tick_now = Clock::now();
      if (tick_now >= next_tick) {
        runtime.scheduling_jitter_max_ns = std::max(
            runtime.scheduling_jitter_max_ns,
            uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
                tick_now - next_tick).count()));
        {
          auto batch = scheduler.batch();
          if (compiled_runtime) compiled_runtime->advance_samples(uint32_t(tick_samples));
          else mcu->control_tick();
        }
        next_tick += tick_period;
        if (next_tick <= tick_now) next_tick = tick_now + tick_period;
      }
      const uint32_t midi_queue_depth = midi_queue.stats().depth;
      if (midi_input && midi_input->disconnected() && midi_queue_depth == 0) {
        break;
      }
      if (midi_file && midi_file->finished() && midi_queue_depth == 0) {
        const uint64_t tail_ns = uint64_t(args.midi_tail_ms) * 1000000ull;
        const uint64_t stop_ns =
            midi_file->end_timestamp_ns() >
                    std::numeric_limits<uint64_t>::max() - tail_ns
                ? std::numeric_limits<uint64_t>::max()
                : midi_file->end_timestamp_ns() + tail_ns;
        if (now_ns >= stop_ns) break;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    if (midi_input) midi_input->stop();
    try {
      if (compiled_runtime) {
        auto batch = scheduler.batch();
        for (int channel = 0; channel < 16; ++channel) {
          compiled_runtime->all_sound_off(uint8_t(channel));
        }
      } else {
        all_sound_off(*mcu, scheduler);
      }
    } catch (const std::exception& error) {
      std::cerr << "error: failed to queue all-sound-off recovery: " << error.what() << '\n';
      fatal = true;
    }
    const bool drained = scheduler.wait_idle(std::chrono::seconds(2));
    if (!drained) fatal = true;
    scheduler.shutdown();

    const host::MidiEventQueueStats midi_stats = midi_queue.stats();
    const host::CommandSchedulerStats command_stats = scheduler.stats();
    const host::RealtimeRegionBankStats region_stats =
        region_bank ? region_bank->stats() : host::RealtimeRegionBankStats{};
    const host::McuSf2AssetRuntimeStats compiled_stats = compiled_runtime
        ? compiled_runtime->stats() : host::McuSf2AssetRuntimeStats{};
    const uint64_t average_note_on_ns = runtime.note_on_events == 0 ? 0 :
        runtime.note_on_enqueue_total_ns / runtime.note_on_events;
    const bool midi_disconnected = midi_input && midi_input->disconnected();
    const uint64_t midi_read_errors = midi_input ? midi_input->read_errors() : 0;
    const bool midi_file_complete = midi_file && midi_file->finished();
    const std::size_t midi_file_event_count =
        midi_file ? midi_file->event_count() : 0;
    const std::size_t midi_file_scheduled_count =
        midi_file ? midi_file->scheduled_count() : 0;
    std::cout
        << "{\"midi_source\":\"" << (midi_file ? "file" : "raw") << "\""
        << ",\"midi_disconnected\":" << (midi_disconnected ? "true" : "false")
        << ",\"midi_read_errors\":" << midi_read_errors
        << ",\"midi_file_complete\":" << (midi_file_complete ? "true" : "false")
        << ",\"midi_file_event_count\":" << midi_file_event_count
        << ",\"midi_file_scheduled_count\":" << midi_file_scheduled_count
        << ",\"midi_queue_high_water\":" << midi_stats.high_water
        << ",\"midi_dropped_note_on\":" << midi_stats.dropped_note_on
        << ",\"midi_dropped_replaceable\":" << midi_stats.dropped_replaceable
        << ",\"note_on_events\":" << runtime.note_on_events
        << ",\"unmapped_note_ons\":" << runtime.unmapped_note_ons
        << ",\"note_on_enqueue_average_ns\":" << average_note_on_ns
        << ",\"note_on_enqueue_max_ns\":" << runtime.note_on_enqueue_max_ns
        << ",\"scheduling_jitter_max_ns\":" << runtime.scheduling_jitter_max_ns
        << ",\"compiled_asset\":" << (compiled_runtime ? "true" : "false")
        << ",\"active_voices\":" << (compiled_runtime ? compiled_stats.active_voices
                                                            : diagnostics.control_active_voices)
        << ",\"maximum_active_voices\":"
        << (compiled_runtime ? compiled_stats.maximum_active_voices
                             : diagnostics.control_max_active_voices)
        << ",\"voice_steals\":" << (compiled_runtime ? compiled_stats.stolen_voices
                                                          : diagnostics.voice_steals)
        << ",\"command_queue_high_water\":" << command_stats.queue_high_water
        << ",\"coalesced_commands\":" << command_stats.coalesced_updates
        << ",\"dropped_replaceable_commands\":" << command_stats.dropped_replaceable_updates
        << ",\"transport_errors\":" << command_stats.transport_errors
        << ",\"abandoned_commands\":" << command_stats.abandoned_commands
        << ",\"maximum_command_age_ns\":" << command_stats.maximum_command_age_ns
        << ",\"maximum_driver_ns\":" << command_stats.driver_max_ns
        << ",\"maximum_transaction_words\":" << command_stats.maximum_transaction_words
        << ",\"region_cache_hits\":" << region_stats.hits
        << ",\"region_cache_misses\":" << region_stats.misses
        << ",\"region_cache_evictions\":" << region_stats.evictions
        << ",\"drained\":" << (drained ? "true" : "false") << "}\n";
    return fatal ? 1 : 0;
  } catch (const std::exception& error) {
    std::cerr << "error: " << error.what() << '\n';
    return 1;
  }
}
