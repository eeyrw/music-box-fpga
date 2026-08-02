#include "host/ch347_transport.h"

#include "sim/harness/control/command_control.h"

#include <array>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {

namespace regs = render::regs;

constexpr uint32_t kEventErrorMask =
    regs::kCommonEventFlagsUnderrunMask |
    regs::kCommonEventFlagsSampleDropMask |
    regs::kCommonEventFlagsRenderDeadlineMissMask;
constexpr uint32_t kCommandErrorMask =
    regs::kCmdFifoStatusCommandErrorMask |
    regs::kCmdFifoStatusStaleGenerationMask;
constexpr uint32_t kDdrReadyMask =
    regs::kDdrAccessStatusPresentMask |
    regs::kDdrAccessStatusReadyMask;

struct Args {
  host::Ch347Options ch347;
  bool dry_run = false;
  bool wait_ddr = false;
  bool wait_asset = false;
  bool ddr_smoke = false;
  bool voice_smoke = false;
  uint32_t poll_ms = 100;
  uint32_t timeout_ms = 10000;
  uint32_t ddr_addr = 0x00000100;
  std::array<uint32_t, 4> ddr_pattern = {
      0x01234567, 0x89abcdef, 0x76543210, 0xfedcba98};
  int voice = 0;
  uint32_t base = 0;
  uint32_t length = 0;
  uint32_t phase_inc = 0x00000100;
  int gain_l = 0x2000;
  int gain_r = 0x2000;
};

struct Snapshot {
  uint32_t version = 0;
  bool core_regs_available = false;
  uint32_t system_status = 0;
  uint32_t event_flags = 0;
  uint32_t pipeline_latency = 0;
  uint32_t command_status = 0;
  uint32_t platform_status = 0;
  uint32_t platform_errors = 0;
  uint32_t bytes_loaded = 0;
  uint32_t sf2_size = 0;
  uint32_t current_lba = 0;
  uint32_t platform_ddr_status = 0;
  uint32_t ddr_access_status = 0;
  uint32_t underrun_count = 0;
  uint32_t sample_drop_count = 0;
  uint32_t deadline_miss_count = 0;
  uint32_t memory_response_count = 0;
};

uint32_t parse_u32(const std::string& text, const char* name) {
  size_t pos = 0;
  const unsigned long value = std::stoul(text, &pos, 0);
  if (pos != text.size() || value > 0xfffffffful) {
    throw std::runtime_error(std::string("invalid ") + name + ": " + text);
  }
  return uint32_t(value);
}

int parse_int(const std::string& text, const char* name) {
  size_t pos = 0;
  const long value = std::stol(text, &pos, 0);
  if (pos != text.size() || value < std::numeric_limits<int>::min() ||
      value > std::numeric_limits<int>::max()) {
    throw std::runtime_error(std::string("invalid ") + name + ": " + text);
  }
  return int(value);
}

uint8_t parse_u8(const std::string& text, const char* name) {
  const uint32_t value = parse_u32(text, name);
  if (value > 0xffu) {
    throw std::runtime_error(std::string(name) + " out of range: " + text);
  }
  return uint8_t(value);
}

std::string parse_device_path(const std::string& text) {
  bool decimal_index = !text.empty();
  for (char c : text) {
    decimal_index = decimal_index &&
        std::isdigit(static_cast<unsigned char>(c));
  }
  return decimal_index ? "/dev/ch34x_pis" + text : text;
}

std::string need_arg(int argc, char** argv, int& index, const char* name) {
  if (index + 1 >= argc) {
    throw std::runtime_error(std::string("missing value for ") + name);
  }
  return argv[++index];
}

void print_usage(const char* argv0) {
  std::cout
      << "Usage: " << argv0 << " [transport options] [actions]\n\n"
      << "Transport options:\n"
      << "  --lib PATH              CH347 shared library path\n"
      << "  --device PATH|N         N maps to /dev/ch34x_pisN\n"
      << "  --clock-hz HZ           Requested SPI clock, default 1000000\n"
      << "  --cs-mask VALUE         CH347 chip-select mask, default 0x80\n"
      << "  --dry-run               Execute against a synthetic board and trace I/O\n\n"
      << "Actions:\n"
      << "  (none)                  Validate interface version and print status\n"
      << "  --wait-ddr              Wait for MIG calibration and DDR debug readiness\n"
      << "  --wait-asset            Wait for DDR, SD initialization, and asset load\n"
      << "  --ddr-smoke             Write and read one 16-byte DDR debug beat\n"
      << "  --voice-smoke           Start, observe, and stop one mono voice\n"
      << "  --timeout-ms N          Action timeout, default 10000\n"
      << "  --poll-ms N             Poll interval, default 100\n\n"
      << "DDR smoke options:\n"
      << "  --ddr-addr ADDR         16-byte aligned byte address, default 0x100\n"
      << "  --ddr-pattern D0 D1 D2 D3\n\n"
      << "Voice smoke options:\n"
      << "  --voice N               Mono voice slot, default 0\n"
      << "  --base ADDR             Wave-memory word address\n"
      << "  --length FRAMES         Required sample-frame length\n"
      << "  --phase-inc Q24_8       Default 0x00000100\n"
      << "  --gain-l Q1_15          Default 0x2000\n"
      << "  --gain-r Q1_15          Default 0x2000\n";
}

Args parse_args(int argc, char** argv) {
  Args args;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--help" || arg == "-h") {
      print_usage(argv[0]);
      std::exit(0);
    } else if (arg == "--lib") {
      args.ch347.library_path = need_arg(argc, argv, i, "--lib");
    } else if (arg == "--device") {
      args.ch347.device_path =
          parse_device_path(need_arg(argc, argv, i, "--device"));
    } else if (arg == "--clock-hz") {
      args.ch347.clock_hz =
          parse_int(need_arg(argc, argv, i, "--clock-hz"), "clock-hz");
    } else if (arg == "--cs-mask") {
      args.ch347.chip_select_mask =
          parse_u8(need_arg(argc, argv, i, "--cs-mask"), "cs-mask");
    } else if (arg == "--dry-run") {
      args.dry_run = true;
    } else if (arg == "--wait-ddr") {
      args.wait_ddr = true;
    } else if (arg == "--wait-asset") {
      args.wait_asset = true;
    } else if (arg == "--timeout-ms") {
      args.timeout_ms =
          parse_u32(need_arg(argc, argv, i, "--timeout-ms"), "timeout-ms");
    } else if (arg == "--poll-ms") {
      args.poll_ms =
          parse_u32(need_arg(argc, argv, i, "--poll-ms"), "poll-ms");
    } else if (arg == "--ddr-smoke") {
      args.ddr_smoke = true;
    } else if (arg == "--ddr-addr") {
      args.ddr_addr =
          parse_u32(need_arg(argc, argv, i, "--ddr-addr"), "ddr-addr");
    } else if (arg == "--ddr-pattern") {
      for (size_t word = 0; word < args.ddr_pattern.size(); ++word) {
        args.ddr_pattern[word] = parse_u32(
            need_arg(argc, argv, i, "--ddr-pattern"), "ddr-pattern");
      }
    } else if (arg == "--voice-smoke") {
      args.voice_smoke = true;
    } else if (arg == "--voice") {
      args.voice = parse_int(need_arg(argc, argv, i, "--voice"), "voice");
    } else if (arg == "--base") {
      args.base = parse_u32(need_arg(argc, argv, i, "--base"), "base");
    } else if (arg == "--length") {
      args.length =
          parse_u32(need_arg(argc, argv, i, "--length"), "length");
    } else if (arg == "--phase-inc") {
      args.phase_inc =
          parse_u32(need_arg(argc, argv, i, "--phase-inc"), "phase-inc");
    } else if (arg == "--gain-l") {
      args.gain_l =
          parse_int(need_arg(argc, argv, i, "--gain-l"), "gain-l");
    } else if (arg == "--gain-r") {
      args.gain_r =
          parse_int(need_arg(argc, argv, i, "--gain-r"), "gain-r");
    } else {
      throw std::runtime_error("unknown argument: " + arg);
    }
  }
  if (args.poll_ms == 0) throw std::runtime_error("--poll-ms must be nonzero");
  return args;
}

std::string hex32(uint32_t value) {
  std::ostringstream out;
  out << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
  return out.str();
}

void result(const char* status, const std::string& text) {
  std::cout << '[' << status << "] " << text << '\n';
}

void print_register(const char* name, uint16_t address, uint32_t value) {
  std::cout << "  " << std::left << std::setw(29) << name << std::right
            << " @0x" << std::hex << std::setw(4) << std::setfill('0')
            << address << " = 0x" << std::setw(8) << value << std::dec
            << std::setfill(' ') << '\n';
}

class SyntheticBoard final : public host::RegisterIo,
                             public render::CommandWordSink {
 public:
  SyntheticBoard() {
    values_[regs::kVersion] = regs::kVersionValue;
    values_[regs::kPlatformStatus] =
        regs::kPlatformStatusPlatformRegsPresentMask |
        regs::kPlatformStatusDdrCalibratedMask |
        regs::kPlatformStatusSdInitializedMask |
        regs::kPlatformStatusAssetLoadedMask;
    values_[regs::kPlatformBytesLoaded] = 4096;
    values_[regs::kPlatformSf2Size] = 4096;
    values_[regs::kPlatformDdrStatus] =
        regs::kPlatformDdrStatusDdrCalibratedMask |
        regs::kPlatformDdrStatusMigAppReadyMask |
        regs::kPlatformDdrStatusMigWriteDataReadyMask;
    values_[regs::kDdrAccessStatus] =
        kDdrReadyMask | regs::kDdrAccessStatusDoneMask;
    values_[regs::kCmdFifoStatus] =
        regs::kCmdFifoStatusWordEmptyMask |
        regs::kCmdFifoStatusParserIdleMask;
  }

  void write_register(uint16_t address, uint32_t data) override {
    std::cout << "  [REG-W] 0x" << std::hex << std::setw(4)
              << std::setfill('0') << address << " <- 0x" << std::setw(8)
              << data << std::dec << std::setfill(' ') << '\n';
    if (address == regs::kCommonEventFlags) {
      values_[address] &= ~data;
    } else {
      values_[address] = data;
    }
    if (address == regs::kDdrAccessControl) {
      values_[regs::kDdrAccessStatus] = kDdrReadyMask;
      if ((data & regs::kDdrAccessControlStartMask) != 0) {
        values_[regs::kDdrAccessStatus] |= regs::kDdrAccessStatusDoneMask;
      }
    }
  }

  uint32_t read_register(uint16_t address) override {
    const uint32_t value = values_[address];
    std::cout << "  [REG-R] 0x" << std::hex << std::setw(4)
              << std::setfill('0') << address << " -> 0x" << std::setw(8)
              << value << std::dec << std::setfill(' ') << '\n';
    return value;
  }

  void write_command_words(render::CommandWordView words) override {
    host::Ch347RegisterTransport::validate_command_transaction(words);
    const uint16_t crc =
        host::Ch347RegisterTransport::command_transaction_crc16(words);
    std::cout << "  [CMD] words=" << words.size() << " crc16=0x" << std::hex
              << std::setw(4) << std::setfill('0') << crc;
    for (uint32_t word : words) std::cout << " 0x" << std::setw(8) << word;
    std::cout << std::dec << std::setfill(' ') << '\n';
    if (uint8_t(words.front() >> 24) == 0x10) {
      values_[regs::kCommonEventFlags] |=
          regs::kCommonEventFlagsMemResponseMask;
      ++values_[regs::kMemResponseCount];
    }
  }

 private:
  std::unordered_map<uint16_t, uint32_t> values_;
};

Snapshot read_snapshot(host::RegisterIo& io) {
  Snapshot snapshot;
  snapshot.version = io.read_register(regs::kVersion);
  snapshot.platform_status = io.read_register(regs::kPlatformStatus);
  snapshot.platform_errors = io.read_register(regs::kPlatformErrors);
  snapshot.bytes_loaded = io.read_register(regs::kPlatformBytesLoaded);
  snapshot.sf2_size = io.read_register(regs::kPlatformSf2Size);
  snapshot.current_lba = io.read_register(regs::kPlatformCurrentLba);
  snapshot.platform_ddr_status = io.read_register(regs::kPlatformDdrStatus);
  snapshot.ddr_access_status = io.read_register(regs::kDdrAccessStatus);
  snapshot.core_regs_available =
      (snapshot.platform_status & regs::kPlatformStatusAssetLoadedMask) != 0;
  if (snapshot.core_regs_available) {
    snapshot.system_status = io.read_register(regs::kSystemStatus);
    snapshot.event_flags = io.read_register(regs::kCommonEventFlags);
    snapshot.pipeline_latency = io.read_register(regs::kPipelineLatencyStatus);
    snapshot.command_status = io.read_register(regs::kCmdFifoStatus);
    snapshot.underrun_count = io.read_register(regs::kUnderrunCount);
    snapshot.sample_drop_count = io.read_register(regs::kSampleDropCount);
    snapshot.deadline_miss_count =
        io.read_register(regs::kRenderDeadlineMissCount);
    snapshot.memory_response_count = io.read_register(regs::kMemResponseCount);
  }
  return snapshot;
}

void print_snapshot(const Snapshot& s) {
  std::cout << "\n== Board Snapshot ==\n";
  print_register("VERSION", regs::kVersion, s.version);
  print_register("PLATFORM_STATUS", regs::kPlatformStatus, s.platform_status);
  print_register("PLATFORM_ERRORS", regs::kPlatformErrors, s.platform_errors);
  print_register("PLATFORM_BYTES_LOADED", regs::kPlatformBytesLoaded,
                 s.bytes_loaded);
  print_register("PLATFORM_SF2_SIZE", regs::kPlatformSf2Size, s.sf2_size);
  print_register("PLATFORM_CURRENT_LBA", regs::kPlatformCurrentLba,
                 s.current_lba);
  print_register("PLATFORM_DDR_STATUS", regs::kPlatformDdrStatus,
                 s.platform_ddr_status);
  print_register("DDR_ACCESS_STATUS", regs::kDdrAccessStatus,
                 s.ddr_access_status);
  if (s.core_regs_available) {
    print_register("SYSTEM_STATUS", regs::kSystemStatus, s.system_status);
    print_register("COMMON_EVENT_FLAGS", regs::kCommonEventFlags, s.event_flags);
    print_register("PIPELINE_LATENCY_STATUS", regs::kPipelineLatencyStatus,
                   s.pipeline_latency);
    print_register("CMD_FIFO_STATUS", regs::kCmdFifoStatus, s.command_status);
    print_register("UNDERRUN_COUNT", regs::kUnderrunCount, s.underrun_count);
    print_register("SAMPLE_DROP_COUNT", regs::kSampleDropCount,
                   s.sample_drop_count);
    print_register("RENDER_DEADLINE_MISS_COUNT",
                   regs::kRenderDeadlineMissCount, s.deadline_miss_count);
    print_register("MEM_RESPONSE_COUNT", regs::kMemResponseCount,
                   s.memory_response_count);
  } else {
    std::cout << "  core register window unavailable while asset reset is asserted\n";
  }

  const uint32_t word_level =
      (s.command_status >> regs::kCmdFifoStatusWordLevelLsb) & 0x3fffu;
  std::cout << "  decoded: ddr_calibrated="
            << ((s.platform_status &
                 regs::kPlatformStatusDdrCalibratedMask) != 0)
            << " sd_initialized="
            << ((s.platform_status &
                 regs::kPlatformStatusSdInitializedMask) != 0)
            << " asset_loaded="
            << ((s.platform_status &
                 regs::kPlatformStatusAssetLoadedMask) != 0)
            << " loader_busy="
            << ((s.platform_status &
                 regs::kPlatformStatusAssetLoaderBusyMask) != 0)
            << " command_words=";
  if (s.core_regs_available)
    std::cout << word_level;
  else
    std::cout << "unavailable";
  std::cout << '\n';
}

void validate_identity(const Snapshot& snapshot) {
  if (snapshot.version == 0xffffffffu) {
    throw std::runtime_error(
        "SPI returned 0xffffffff; no valid FPGA target responded");
  }
  if (snapshot.version != regs::kVersionValue) {
    throw std::runtime_error(
        "interface version mismatch: expected " + hex32(regs::kVersionValue) +
        ", received " + hex32(snapshot.version));
  }
  if ((snapshot.platform_status &
       regs::kPlatformStatusPlatformRegsPresentMask) == 0) {
    throw std::runtime_error(
        "platform register window is absent; check bitstream, reset, and MIG UI clock");
  }
  result("PASS", "SPI mailbox and current interface version are responding");
  if ((snapshot.platform_status & regs::kPlatformStatusErrorPresentMask) != 0) {
    result("WARN", "platform reports an SD or asset-loader error");
  }
  if (snapshot.core_regs_available &&
      (snapshot.command_status & kCommandErrorMask) != 0) {
    result("WARN", "command parser reports an existing error summary");
  }
}

template <typename Predicate>
uint32_t poll_register(host::RegisterIo& io, uint16_t address,
                       const Args& args, const std::string& label,
                       Predicate predicate) {
  const auto deadline = std::chrono::steady_clock::now() +
      std::chrono::milliseconds(args.timeout_ms);
  while (true) {
    const uint32_t value = io.read_register(address);
    if (predicate(value)) return value;
    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error(label + " timed out, last value=" + hex32(value));
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(args.poll_ms));
  }
}

void wait_platform(host::RegisterIo& io, const Args& args, bool require_asset) {
  std::cout << "\n== Wait For "
            << (require_asset ? "Asset" : "DDR") << " ==\n";
  const auto deadline = std::chrono::steady_clock::now() +
      std::chrono::milliseconds(args.timeout_ms);
  while (true) {
    const uint32_t status = io.read_register(regs::kPlatformStatus);
    const uint32_t errors = io.read_register(regs::kPlatformErrors);
    const uint32_t ddr_access = io.read_register(regs::kDdrAccessStatus);
    const uint32_t loaded = io.read_register(regs::kPlatformBytesLoaded);
    const uint32_t size = io.read_register(regs::kPlatformSf2Size);
    if (require_asset &&
        (status & regs::kPlatformStatusErrorPresentMask) != 0) {
      throw std::runtime_error("platform error while waiting: " + hex32(errors));
    }
    const bool ddr_ready =
        (status & regs::kPlatformStatusDdrCalibratedMask) != 0 &&
        (ddr_access & kDdrReadyMask) == kDdrReadyMask;
    const bool asset_ready = ddr_ready &&
        (status & regs::kPlatformStatusSdInitializedMask) != 0 &&
        (status & regs::kPlatformStatusAssetLoadedMask) != 0 &&
        size != 0 && loaded == size;
    if (ddr_ready && (!require_asset || asset_ready)) {
      result("PASS", require_asset ? "asset is loaded" : "DDR is ready");
      return;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      throw std::runtime_error(require_asset ? "asset load timed out" :
                                               "DDR readiness timed out");
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(args.poll_ms));
  }
}

void wait_ddr_done(host::RegisterIo& io, const Args& args) {
  (void)poll_register(
      io, regs::kDdrAccessStatus, args, "DDR debug access",
      [](uint32_t status) {
        if ((status & regs::kDdrAccessStatusErrorMask) != 0) {
          throw std::runtime_error(
              "DDR debug access failed, status=" + hex32(status));
        }
        return (status & regs::kDdrAccessStatusDoneMask) != 0;
      });
}

void run_ddr_smoke(host::RegisterIo& io, const Args& args) {
  std::cout << "\n== DDR Mailbox Smoke ==\n";
  wait_platform(io, args, false);

  io.write_register(regs::kDdrAccessControl,
                    regs::kDdrAccessControlClearMask);
  io.write_register(regs::kDdrAccessAddr, args.ddr_addr);
  io.write_register(regs::kDdrAccessByteEnable, 0xffffu);
  io.write_registers(regs::kDdrAccessData0,
                     std::vector<uint32_t>(args.ddr_pattern.begin(),
                                           args.ddr_pattern.end()));
  io.write_register(regs::kDdrAccessControl,
                    regs::kDdrAccessControlStartMask |
                    regs::kDdrAccessControlWriteMask);
  wait_ddr_done(io, args);

  io.write_register(regs::kDdrAccessControl,
                    regs::kDdrAccessControlClearMask);
  io.write_register(regs::kDdrAccessAddr, args.ddr_addr);
  io.write_register(regs::kDdrAccessControl,
                    regs::kDdrAccessControlStartMask);
  wait_ddr_done(io, args);

  std::array<uint32_t, 4> readback{};
  for (size_t word = 0; word < readback.size(); ++word) {
    readback[word] = io.read_register(
        uint16_t(regs::kDdrAccessData0 + uint16_t(word * 4)));
  }
  if (readback != args.ddr_pattern) {
    throw std::runtime_error("DDR readback mismatch");
  }
  result("PASS", "16-byte DDR write/read pattern matched");
}

void wait_command_idle(host::RegisterIo& io, const Args& args) {
  (void)poll_register(
      io, regs::kCmdFifoStatus, args, "command drain",
      [](uint32_t status) {
        if ((status & kCommandErrorMask) != 0) {
          throw std::runtime_error(
              "command parser rejected the transaction, status=" +
              hex32(status));
        }
        return (status & regs::kCmdFifoStatusWordEmptyMask) != 0 &&
               (status & regs::kCmdFifoStatusParserIdleMask) != 0 &&
               (status & regs::kCmdFifoStatusActionPendingMask) == 0;
      });
}

void validate_voice_args(const Args& args) {
  if (args.voice < 0 || args.voice >= render::kNumVoices) {
    throw std::runtime_error("voice index out of range");
  }
  if (args.length == 0 || args.length > 0x00ffffffu) {
    throw std::runtime_error(
        "--voice-smoke requires a 1..0xffffff frame --length");
  }
  if (args.gain_l < 0 || args.gain_l > 0x7fff ||
      args.gain_r < 0 || args.gain_r > 0x7fff) {
    throw std::runtime_error("voice gains must be in the Q1.15 range 0..0x7fff");
  }
}

void run_voice_smoke(host::RegisterIo& io, render::CommandWordSink& commands,
                     const Args& args) {
  std::cout << "\n== Atomic Command Smoke ==\n";
  wait_platform(io, args, false);
  wait_command_idle(io, args);
  const uint32_t responses_before =
      io.read_register(regs::kMemResponseCount);
  io.write_register(regs::kCommonEventFlags, 0x0fu);

  render::Region region;
  region.stereo = false;
  region.base_addr = args.base;
  region.length = args.length;
  region.gain_l = args.gain_l;
  region.gain_r = args.gain_r;
  region.filter_enable = false;
  region.filter_b0 = 0x4000;

  render::CommandVoiceControl voice_control(commands);
  voice_control.start_voice(args.voice, args.phase_inc, region);
  wait_command_idle(io, args);

  const auto deadline = std::chrono::steady_clock::now() +
      std::chrono::milliseconds(args.timeout_ms);
  bool memory_seen = false;
  while (std::chrono::steady_clock::now() < deadline) {
    const uint32_t events = io.read_register(regs::kCommonEventFlags);
    const uint32_t responses = io.read_register(regs::kMemResponseCount);
    if ((events & kEventErrorMask) != 0) {
      voice_control.stop_voice(args.voice);
      throw std::runtime_error(
          "audio error occurred during voice smoke, events=" + hex32(events));
    }
    if ((events & regs::kCommonEventFlagsMemResponseMask) != 0 ||
        responses != responses_before) {
      memory_seen = true;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(args.poll_ms));
  }

  voice_control.stop_voice(args.voice);
  wait_command_idle(io, args);
  if (!memory_seen) {
    throw std::runtime_error(
        "voice command drained but no memory response was observed");
  }
  result("PASS", "mono START and STOP transactions completed without errors");

  print_register("SAMPLE_WINDOW_REQUEST_COUNT",
                 regs::kSampleWindowRequestCount,
                 io.read_register(regs::kSampleWindowRequestCount));
  print_register("SAMPLE_WINDOW_HIT_COUNT", regs::kSampleWindowHitCount,
                 io.read_register(regs::kSampleWindowHitCount));
  print_register("SAMPLE_WINDOW_REFILL_COUNT", regs::kSampleWindowRefillCount,
                 io.read_register(regs::kSampleWindowRefillCount));
  print_register("SAMPLE_WINDOW_MEMORY_READ_COUNT",
                 regs::kSampleWindowMemoryReadCount,
                 io.read_register(regs::kSampleWindowMemoryReadCount));
  print_register("SAMPLE_WINDOW_STALL_CYCLE_COUNT",
                 regs::kSampleWindowStallCycleCount,
                 io.read_register(regs::kSampleWindowStallCycleCount));
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const Args args = parse_args(argc, argv);
    if (args.ddr_smoke && (args.ddr_addr & 0xfu) != 0) {
      throw std::runtime_error("DDR smoke address must be 16-byte aligned");
    }
    if (args.voice_smoke) validate_voice_args(args);
    const int selected_clock =
        host::Ch347RegisterTransport::selected_clock_hz(args.ch347.clock_hz);
    std::cout << "CH347 SPI requested=" << args.ch347.clock_hz
              << " Hz selected=" << selected_clock
              << " Hz mode=0 protocol=v13-mailbox/v12-command\n";

    std::unique_ptr<host::Ch347RegisterTransport> hardware;
    std::unique_ptr<SyntheticBoard> synthetic;
    host::RegisterIo* register_io = nullptr;
    render::CommandWordSink* command_sink = nullptr;
    if (args.dry_run) {
      synthetic = std::make_unique<SyntheticBoard>();
      register_io = synthetic.get();
      command_sink = synthetic.get();
      result("DRY", "using synthetic ready board; no CH347 device was opened");
    } else {
      hardware = std::make_unique<host::Ch347RegisterTransport>(args.ch347);
      register_io = hardware.get();
      command_sink = hardware.get();
    }

    const Snapshot initial = read_snapshot(*register_io);
    print_snapshot(initial);
    validate_identity(initial);

    if (args.wait_ddr) wait_platform(*register_io, args, false);
    if (args.wait_asset) wait_platform(*register_io, args, true);
    if (args.ddr_smoke) run_ddr_smoke(*register_io, args);
    if (args.voice_smoke) {
      run_voice_smoke(*register_io, *command_sink, args);
    }

    if (args.wait_ddr || args.wait_asset || args.ddr_smoke ||
        args.voice_smoke) {
      const Snapshot final = read_snapshot(*register_io);
      print_snapshot(final);
      validate_identity(final);
    }
  } catch (const std::exception& error) {
    std::cerr << "error: " << error.what() << '\n';
    return 1;
  }
  return 0;
}
