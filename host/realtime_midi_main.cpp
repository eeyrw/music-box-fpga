#include "host/ch347_transport.h"
#include "host/command_scheduler.h"
#include "host/realtime_midi.h"
#include "host/realtime_region_bank.h"
#include "sim/harness/control/command_control.h"
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
#include <iostream>
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
  std::string midi_input = "/dev/snd/midiC0D0";
  int sample_rate = 48000;
  double control_tick_ms = 5.0;
  int run_ms = 0;
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
    else if (option == "--sample-rate") args.sample_rate = std::stoi(require_value(argc, argv, index));
    else if (option == "--control-tick-ms") args.control_tick_ms = std::stod(require_value(argc, argv, index));
    else if (option == "--run-ms") args.run_ms = std::stoi(require_value(argc, argv, index));
    else if (option == "--dry-run") args.dry_run = true;
    else if (option == "--library") args.ch347.library_path = require_value(argc, argv, index);
    else if (option == "--device") args.ch347.device_path = require_value(argc, argv, index);
    else if (option == "--clock-hz") args.ch347.clock_hz = std::stoi(require_value(argc, argv, index));
    else if (option == "--help") {
      std::cout
          << "usage: realtime_midi_host [--sf2 PATH] [--midi-input PATH|-] [--dry-run]\n"
          << "       [--sample-rate HZ] [--control-tick-ms MS] [--run-ms MS]\n"
          << "       [--library PATH] [--device PATH] [--clock-hz HZ]\n";
      std::exit(0);
    } else {
      throw std::runtime_error("unknown option: " + option);
    }
  }
  if (args.sample_rate <= 0 || args.control_tick_ms <= 0.0 || args.run_ms < 0) {
    throw std::runtime_error("sample rate and control tick must be positive; run-ms must be nonnegative");
  }
  return args;
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

}  // namespace

int main(int argc, char** argv) {
  try {
    const Args args = parse_args(argc, argv);
    const int tick_samples = std::max(
        1, int(std::llround(args.control_tick_ms * double(args.sample_rate) / 1000.0)));
    const auto tick_period = std::chrono::nanoseconds(
        std::max<int64_t>(1, int64_t(std::llround(args.control_tick_ms * 1000000.0))));

    // Loading and compiled lookup construction finish before the MIDI device is opened.
    render::Sf2Data sf2 = render::load_sf2(args.sf2);
    host::RealtimeRegionBank region_bank(sf2, args.sample_rate, tick_samples);

    std::unique_ptr<render::CommandWordSink> transport;
    if (args.dry_run) {
      transport = std::make_unique<host::DryRunCommandTransport>();
    } else {
      transport = std::make_unique<host::Ch347RegisterTransport>(args.ch347);
    }
    host::AsyncCommandScheduler scheduler(std::move(transport));
    render::CommandVoiceControl command_control(scheduler);
    render::RenderDiagnostics diagnostics;
    render::McuModel mcu(command_control, region_bank.regions(), &diagnostics,
                         {1, 1, 4});

    host::BoundedMidiEventQueue midi_queue;
    MidiInputWorker midi_input(open_midi_input(args.midi_input), midi_queue);
    std::signal(SIGINT, signal_handler);
    std::signal(SIGTERM, signal_handler);

    RuntimeStats runtime;
    uint64_t next_note_instance = 0;
    bool fatal = false;
    const auto start = Clock::now();
    auto next_tick = start + tick_period;
    while (stop_requested == 0) {
      const auto now = Clock::now();
      if (args.run_ms != 0 && now - start >= std::chrono::milliseconds(args.run_ms)) break;
      if (midi_input.lifecycle_overflow()) {
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
      mcu.set_current_sample(uint32_t(sample));

      host::TimestampedMidiEvent event;
      while (midi_queue.pop(event)) {
        try {
          handle_midi_event(event, region_bank, mcu, scheduler,
                            next_note_instance, runtime);
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
          mcu.control_tick();
        }
        next_tick += tick_period;
        if (next_tick <= tick_now) next_tick = tick_now + tick_period;
      }
      if (midi_input.disconnected() && midi_queue.stats().depth == 0) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }

    midi_input.stop();
    try {
      all_sound_off(mcu, scheduler);
    } catch (const std::exception& error) {
      std::cerr << "error: failed to queue all-sound-off recovery: " << error.what() << '\n';
      fatal = true;
    }
    const bool drained = scheduler.wait_idle(std::chrono::seconds(2));
    if (!drained) fatal = true;
    scheduler.shutdown();

    const host::MidiEventQueueStats midi_stats = midi_queue.stats();
    const host::CommandSchedulerStats command_stats = scheduler.stats();
    const host::RealtimeRegionBankStats region_stats = region_bank.stats();
    const uint64_t average_note_on_ns = runtime.note_on_events == 0 ? 0 :
        runtime.note_on_enqueue_total_ns / runtime.note_on_events;
    std::cout
        << "{\"midi_disconnected\":" << (midi_input.disconnected() ? "true" : "false")
        << ",\"midi_read_errors\":" << midi_input.read_errors()
        << ",\"midi_queue_high_water\":" << midi_stats.high_water
        << ",\"midi_dropped_note_on\":" << midi_stats.dropped_note_on
        << ",\"midi_dropped_replaceable\":" << midi_stats.dropped_replaceable
        << ",\"note_on_events\":" << runtime.note_on_events
        << ",\"unmapped_note_ons\":" << runtime.unmapped_note_ons
        << ",\"note_on_enqueue_average_ns\":" << average_note_on_ns
        << ",\"note_on_enqueue_max_ns\":" << runtime.note_on_enqueue_max_ns
        << ",\"scheduling_jitter_max_ns\":" << runtime.scheduling_jitter_max_ns
        << ",\"active_voices\":" << diagnostics.control_active_voices
        << ",\"maximum_active_voices\":" << diagnostics.control_max_active_voices
        << ",\"voice_steals\":" << diagnostics.voice_steals
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
