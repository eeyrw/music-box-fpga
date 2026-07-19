#include "host/ch347_transport.h"

#include "sim/harness/control/register_control.h"

#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>

namespace {

constexpr uint16_t kVersion = render::regs::kVersion;
constexpr uint16_t kSystemStatus = render::regs::kSystemStatus;
constexpr uint16_t kDebugEventFlags = render::regs::kDebugEventFlags;
constexpr uint16_t kAudioStatus = render::regs::kAudioStatus;
constexpr uint16_t kRenderStatus = render::regs::kRenderStatus;
constexpr uint16_t kMemoryStatus = render::regs::kMemoryStatus;
constexpr uint16_t kUnderrunCount = render::regs::kUnderrunCount;
constexpr uint16_t kSampleDropCount = render::regs::kSampleDropCount;
constexpr uint16_t kRenderDeadlineMissCount = render::regs::kRenderDeadlineMissCount;
constexpr uint16_t kMemResponseCount = render::regs::kMemResponseCount;
constexpr uint16_t kPlatformStatus = render::regs::kPlatformStatus;
constexpr uint16_t kPlatformErrors = render::regs::kPlatformErrors;
constexpr uint16_t kPlatformBytesLoaded = render::regs::kPlatformBytesLoaded;
constexpr uint16_t kPlatformSf2Size = render::regs::kPlatformSf2Size;
constexpr uint16_t kPlatformCurrentLba = render::regs::kPlatformCurrentLba;
constexpr uint16_t kPlatformDdrStatus = render::regs::kPlatformDdrStatus;
constexpr uint16_t kDdrDebugControl = render::regs::kDdrDebugControl;
constexpr uint16_t kDdrDebugStatus = render::regs::kDdrDebugStatus;
constexpr uint16_t kDdrDebugAddr = render::regs::kDdrDebugAddr;
constexpr uint16_t kDdrDebugByteEnable = render::regs::kDdrDebugByteEnable;
constexpr uint16_t kDdrDebugData0 = render::regs::kDdrDebugData0;

constexpr uint32_t kPlatformDebugPresent = render::regs::kPlatformStatusDebugPresentMask;
constexpr uint32_t kPlatformErrorPresent = render::regs::kPlatformStatusErrorPresentMask;
constexpr uint32_t kPlatformDdrCalibrated = render::regs::kPlatformStatusDdrCalibratedMask;
constexpr uint32_t kPlatformDdrUiReset = render::regs::kPlatformStatusDdrUiResetMask;
constexpr uint32_t kPlatformSdInitialized = render::regs::kPlatformStatusSdInitializedMask;
constexpr uint32_t kPlatformAssetLoaded = render::regs::kPlatformStatusAssetLoadedMask;
constexpr uint32_t kDdrDebugControlStart = render::regs::kDdrDebugControlStartMask;
constexpr uint32_t kDdrDebugControlWrite = render::regs::kDdrDebugControlWriteMask;
constexpr uint32_t kDdrDebugControlClear = render::regs::kDdrDebugControlClearMask;
constexpr uint32_t kDdrDebugStatusPresent = render::regs::kDdrDebugStatusPresentMask;
constexpr uint32_t kDdrDebugStatusReady = render::regs::kDdrDebugStatusReadyMask;
constexpr uint32_t kDdrDebugStatusDone = render::regs::kDdrDebugStatusDoneMask;
constexpr uint32_t kDdrDebugStatusError = render::regs::kDdrDebugStatusErrorMask;

struct Args {
  host::Ch347Options ch347;
  bool dry_run = false;
  bool wait_ddr = false;
  bool wait_asset = false;
  bool ddr_smoke = false;
  bool voice_smoke = false;
  uint32_t poll_ms = 250;
  uint32_t timeout_ms = 10000;
  uint32_t ddr_addr = 0x00000100;
  uint32_t ddr_pattern[4] = {0x01234567, 0x89abcdef, 0x76543210, 0xfedcba98};
  int voice = 0;
  bool stereo = false;
  uint32_t base = 0;
  uint32_t base_r = 0;
  uint32_t length = 0;
  uint32_t length_r = 0;
  uint32_t phase_inc = 0x00010000;
  int gain_l = 0x2000;
  int gain_r = 0x2000;
};

class DryRunTransport : public render::RegisterWriteSink {
 public:
  void write_register(uint16_t address, uint32_t data) override {
    std::cout << "dry-run write 0x" << std::hex << std::setw(4) << std::setfill('0')
              << address << " = 0x" << std::setw(8) << data << std::dec
              << std::setfill(' ') << "\n";
  }

  uint32_t read_register(uint16_t address) {
    std::cout << "dry-run read  0x" << std::hex << std::setw(4) << std::setfill('0')
              << address << std::dec << std::setfill(' ') << "\n";
    return 0;
  }
};

uint32_t parse_u32(const std::string& text, const char* name) {
  size_t pos = 0;
  unsigned long value = std::stoul(text, &pos, 0);
  if (pos != text.size()) throw std::runtime_error(std::string("invalid ") + name + ": " + text);
  if (value > 0xfffffffful) throw std::runtime_error(std::string(name) + " out of range: " + text);
  return uint32_t(value);
}

int parse_int(const std::string& text, const char* name) {
  size_t pos = 0;
  long value = std::stol(text, &pos, 0);
  if (pos != text.size()) throw std::runtime_error(std::string("invalid ") + name + ": " + text);
  return int(value);
}

uint8_t parse_u8(const std::string& text, const char* name) {
  uint32_t value = parse_u32(text, name);
  if (value > 0xffu) throw std::runtime_error(std::string(name) + " out of range: " + text);
  return uint8_t(value);
}

std::string parse_device_path(const std::string& text) {
  bool decimal_index = !text.empty();
  for (char c : text) decimal_index = decimal_index && std::isdigit(static_cast<unsigned char>(c));
  if (decimal_index) return "/dev/ch34x_pis" + text;
  return text;
}

std::string need_arg(int argc, char** argv, int& index, const char* name) {
  if (index + 1 >= argc) throw std::runtime_error(std::string("missing value for ") + name);
  return argv[++index];
}

void print_usage(const char* argv0) {
  std::cout
      << "Usage:\n"
      << "  " << argv0 << " [transport options] [test options]\n"
      << "\nTransport options:\n"
      << "  --lib PATH              CH347 shared library path\n"
      << "  --device PATH|N         CH347 device path; N maps to /dev/ch34x_pisN\n"
      << "  --clock-hz HZ           SPI clock request, default 1000000\n"
      << "  --mode N                SPI mode 0..3, default 0\n"
      << "  --cs-mask VALUE         CH347 chip-select mask, default 0x80\n"
      << "  --dry-run               Print register accesses without opening CH347\n"
      << "\nTest options:\n"
      << "  --wait-ddr              Poll until DDR calibration and DDR debug ready\n"
      << "  --wait-asset            Poll until SD asset load completes or an error appears\n"
      << "  --timeout-ms N          Poll timeout, default 10000\n"
      << "  --poll-ms N             Poll interval, default 250\n"
      << "  --ddr-smoke             Write/read one 16-byte DDR debug beat\n"
      << "  --ddr-addr ADDR         16-byte aligned DDR byte address, default 0x100\n"
      << "  --ddr-pattern D0 D1 D2 D3\n"
      << "                          Four 32-bit words for --ddr-smoke\n"
      << "  --voice-smoke           Program one conservative mono/stereo voice\n"
      << "  --voice N               Voice slot, default 0\n"
      << "  --stereo 0|1            Voice stereo flag, default 0\n"
      << "  --base ADDR             Left/mono wave-memory word address\n"
      << "  --base-r ADDR           Right wave-memory word address, default --base\n"
      << "  --length FRAMES         Sample-frame length required by --voice-smoke\n"
      << "  --length-r FRAMES       Right-channel length, default --length\n"
      << "  --phase-inc Q16_16      Playback increment, default 0x00010000\n"
      << "  --gain-l Q1_15          Default 0x2000\n"
      << "  --gain-r Q1_15          Default 0x2000\n";
}

Args parse_args(int argc, char** argv) {
  Args args;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--help" || a == "-h") {
      print_usage(argv[0]);
      std::exit(0);
    } else if (a == "--lib") {
      args.ch347.library_path = need_arg(argc, argv, i, "--lib");
    } else if (a == "--device") {
      args.ch347.device_path = parse_device_path(need_arg(argc, argv, i, "--device"));
    } else if (a == "--clock-hz") {
      args.ch347.clock_hz = parse_int(need_arg(argc, argv, i, "--clock-hz"), "clock-hz");
    } else if (a == "--mode") {
      args.ch347.spi_mode = parse_int(need_arg(argc, argv, i, "--mode"), "mode");
    } else if (a == "--cs-mask") {
      args.ch347.chip_select_mask = parse_u8(need_arg(argc, argv, i, "--cs-mask"), "cs-mask");
    } else if (a == "--dry-run") {
      args.dry_run = true;
    } else if (a == "--wait-ddr") {
      args.wait_ddr = true;
    } else if (a == "--wait-asset") {
      args.wait_asset = true;
    } else if (a == "--timeout-ms") {
      args.timeout_ms = parse_u32(need_arg(argc, argv, i, "--timeout-ms"), "timeout-ms");
    } else if (a == "--poll-ms") {
      args.poll_ms = parse_u32(need_arg(argc, argv, i, "--poll-ms"), "poll-ms");
    } else if (a == "--ddr-smoke") {
      args.ddr_smoke = true;
    } else if (a == "--ddr-addr") {
      args.ddr_addr = parse_u32(need_arg(argc, argv, i, "--ddr-addr"), "ddr-addr");
    } else if (a == "--ddr-pattern") {
      for (int word = 0; word < 4; ++word) {
        std::ostringstream name;
        name << "ddr-pattern word " << word;
        args.ddr_pattern[word] = parse_u32(need_arg(argc, argv, i, "--ddr-pattern"), name.str().c_str());
      }
    } else if (a == "--voice-smoke") {
      args.voice_smoke = true;
    } else if (a == "--voice") {
      args.voice = parse_int(need_arg(argc, argv, i, "--voice"), "voice");
    } else if (a == "--stereo") {
      args.stereo = parse_int(need_arg(argc, argv, i, "--stereo"), "stereo") != 0;
    } else if (a == "--base") {
      args.base = parse_u32(need_arg(argc, argv, i, "--base"), "base");
    } else if (a == "--base-r") {
      args.base_r = parse_u32(need_arg(argc, argv, i, "--base-r"), "base-r");
    } else if (a == "--length") {
      args.length = parse_u32(need_arg(argc, argv, i, "--length"), "length");
    } else if (a == "--length-r") {
      args.length_r = parse_u32(need_arg(argc, argv, i, "--length-r"), "length-r");
    } else if (a == "--phase-inc") {
      args.phase_inc = parse_u32(need_arg(argc, argv, i, "--phase-inc"), "phase-inc");
    } else if (a == "--gain-l") {
      args.gain_l = parse_int(need_arg(argc, argv, i, "--gain-l"), "gain-l");
    } else if (a == "--gain-r") {
      args.gain_r = parse_int(need_arg(argc, argv, i, "--gain-r"), "gain-r");
    } else {
      throw std::runtime_error("unknown argument: " + a);
    }
  }
  return args;
}

std::string hex32(uint32_t value) {
  std::ostringstream out;
  out << "0x" << std::hex << std::setw(8) << std::setfill('0') << value;
  return out.str();
}

void print_result(const char* status, const std::string& text) {
  std::cout << '[' << status << "] " << text << "\n";
}

void print_reg(const char* name, uint16_t address, uint32_t value) {
  std::cout << "  " << std::left << std::setw(24) << name << std::right
            << " @0x" << std::hex << std::setw(4) << std::setfill('0') << address
            << " = 0x" << std::setw(8) << value << std::dec << std::setfill(' ') << "\n";
}

class BoardAccess : public render::RegisterWriteSink {
 public:
  BoardAccess(host::Ch347RegisterTransport* hardware, DryRunTransport* dry_run)
      : hardware_(hardware), dry_run_(dry_run) {}

  uint32_t read(uint16_t address) {
    if (dry_run_) return dry_run_->read_register(address);
    return hardware_->read_register(address);
  }

  void write_register(uint16_t address, uint32_t data) override {
    if (dry_run_) {
      dry_run_->write_register(address, data);
    } else {
      hardware_->write_register(address, data);
    }
  }

  void write(uint16_t address, uint32_t data) { write_register(address, data); }

 private:
  host::Ch347RegisterTransport* hardware_ = nullptr;
  DryRunTransport* dry_run_ = nullptr;
};

void decode_platform(uint32_t status, uint32_t errors) {
  uint32_t state = (status >> 11) & 0xfu;
  uint32_t sd_error = errors & 0xffu;
  uint32_t loader_error = (errors >> 8) & 0xffu;
  std::cout << "  platform bits: debug=" << ((status & kPlatformDebugPresent) ? 1 : 0)
            << " error=" << ((status & kPlatformErrorPresent) ? 1 : 0)
            << " ddr_calib=" << ((status & kPlatformDdrCalibrated) ? 1 : 0)
            << " ui_rst=" << ((status & kPlatformDdrUiReset) ? 1 : 0)
            << " sd_init=" << ((status & kPlatformSdInitialized) ? 1 : 0)
            << " asset_loaded=" << ((status & kPlatformAssetLoaded) ? 1 : 0)
            << " loader_busy=" << ((status >> 6) & 1u)
            << " mig_rdy=" << ((status >> 7) & 1u)
            << " mig_wdf_rdy=" << ((status >> 8) & 1u)
            << " loader_state=" << state << "\n";
  std::cout << "  errors: sd=" << sd_error << " loader=" << loader_error
            << " state=" << ((errors >> 16) & 0xfu) << "\n";
}

bool read_snapshot(BoardAccess& board, bool dry_run) {
  std::cout << "\n== Snapshot ==\n";
  uint32_t version = board.read(kVersion);
  uint32_t system = board.read(kSystemStatus);
  uint32_t events = board.read(kDebugEventFlags);
  uint32_t audio = board.read(kAudioStatus);
  uint32_t render = board.read(kRenderStatus);
  uint32_t memory = board.read(kMemoryStatus);
  uint32_t platform = board.read(kPlatformStatus);
  uint32_t errors = board.read(kPlatformErrors);
  uint32_t bytes_loaded = board.read(kPlatformBytesLoaded);
  uint32_t sf2_size = board.read(kPlatformSf2Size);
  uint32_t current_lba = board.read(kPlatformCurrentLba);
  uint32_t ddr = board.read(kPlatformDdrStatus);
  uint32_t ddr_debug = board.read(kDdrDebugStatus);

  print_reg("VERSION", kVersion, version);
  print_reg("SYSTEM_STATUS", kSystemStatus, system);
  print_reg("DEBUG_EVENT_FLAGS", kDebugEventFlags, events);
  print_reg("AUDIO_STATUS", kAudioStatus, audio);
  print_reg("RENDER_STATUS", kRenderStatus, render);
  print_reg("MEMORY_STATUS", kMemoryStatus, memory);
  print_reg("PLATFORM_STATUS", kPlatformStatus, platform);
  print_reg("PLATFORM_ERRORS", kPlatformErrors, errors);
  print_reg("PLATFORM_BYTES_LOADED", kPlatformBytesLoaded, bytes_loaded);
  print_reg("PLATFORM_SF2_SIZE", kPlatformSf2Size, sf2_size);
  print_reg("PLATFORM_CURRENT_LBA", kPlatformCurrentLba, current_lba);
  print_reg("PLATFORM_DDR_STATUS", kPlatformDdrStatus, ddr);
  print_reg("DDR_DEBUG_STATUS", kDdrDebugStatus, ddr_debug);
  decode_platform(platform, errors);

  if (dry_run) {
    print_result("DRY", "Snapshot register reads were emitted without hardware checks");
    return true;
  }

  bool bus_stuck_high = version == 0xffffffffu && system == 0xffffffffu &&
                        events == 0xffffffffu && platform == 0xffffffffu &&
                        errors == 0xffffffffu && ddr_debug == 0xffffffffu;
  if (bus_stuck_high) {
    print_result("FAIL", "All sampled registers read 0xffffffff; CH347 is present, but no valid FPGA SPI target responded");
    return false;
  } else if (platform & kPlatformDebugPresent) {
    print_result("PASS", "SPI reached the Smart Artix platform debug window");
  } else {
    print_result("FAIL", "PLATFORM_STATUS[0] is not set; check bitstream, reset, SPI pins, and MIG UI clock");
    return false;
  }
  if (platform & kPlatformDdrCalibrated) {
    print_result("PASS", "DDR calibration is complete");
  } else {
    print_result("WARN", "DDR calibration is not complete yet");
  }
  if (platform & kPlatformErrorPresent) {
    print_result("FAIL", "Platform reports SD or loader error; decode PLATFORM_ERRORS above");
  }
  if (sf2_size != 0 && bytes_loaded == sf2_size && (platform & kPlatformAssetLoaded)) {
    print_result("PASS", "Asset byte count matches SF2 size and asset_loaded is set");
  }
  return true;
}

bool poll_until(BoardAccess& board, const Args& args, const std::string& label,
                bool asset) {
  std::cout << "\n== Wait: " << label << " ==\n";
  uint32_t elapsed = 0;
  while (elapsed <= args.timeout_ms) {
    uint32_t platform = board.read(kPlatformStatus);
    uint32_t errors = board.read(kPlatformErrors);
    uint32_t bytes_loaded = board.read(kPlatformBytesLoaded);
    uint32_t sf2_size = board.read(kPlatformSf2Size);
    uint32_t ddr_debug = board.read(kDdrDebugStatus);
    std::cout << "  t=" << elapsed << "ms platform=" << hex32(platform)
              << " errors=" << hex32(errors) << " bytes=" << bytes_loaded
              << "/" << sf2_size << " ddr_debug=" << hex32(ddr_debug) << "\n";

    if (platform & kPlatformErrorPresent) {
      print_result("FAIL", "Platform error appeared while polling");
      return false;
    }
    bool ddr_ready = (platform & kPlatformDdrCalibrated) &&
                     ((ddr_debug & (kDdrDebugStatusPresent | kDdrDebugStatusReady)) ==
                      (kDdrDebugStatusPresent | kDdrDebugStatusReady));
    bool asset_ready = ddr_ready && (platform & kPlatformSdInitialized) &&
                       (platform & kPlatformAssetLoaded) &&
                       (sf2_size != 0) && (bytes_loaded == sf2_size);
    if ((!asset && ddr_ready) || (asset && asset_ready)) {
      print_result("PASS", label + " is ready");
      return true;
    }

    if (args.dry_run) {
      print_result("DRY", label + " polling sequence emitted once");
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(args.poll_ms));
    elapsed += args.poll_ms;
  }
  print_result("FAIL", label + " timed out");
  return false;
}

uint32_t wait_ddr_done(BoardAccess& board, uint32_t timeout_ms, uint32_t poll_ms) {
  uint32_t elapsed = 0;
  while (elapsed <= timeout_ms) {
    uint32_t status = board.read(kDdrDebugStatus);
    if (status & kDdrDebugStatusError) {
      throw std::runtime_error("DDR debug command failed, status=" + hex32(status));
    }
    if (status & kDdrDebugStatusDone) return status;
    std::this_thread::sleep_for(std::chrono::milliseconds(poll_ms));
    elapsed += poll_ms;
  }
  throw std::runtime_error("DDR debug command timed out");
}

void run_ddr_smoke(BoardAccess& board, const Args& args) {
  if ((args.ddr_addr & 0xfu) != 0) throw std::runtime_error("DDR smoke address must be 16-byte aligned");
  std::cout << "\n== DDR Smoke ==\n";
  board.write(kDdrDebugControl, kDdrDebugControlClear);
  uint32_t status = board.read(kDdrDebugStatus);
  if (!args.dry_run && ((status & kDdrDebugStatusReady) == 0)) {
    throw std::runtime_error("DDR debug window is not ready, status=" + hex32(status));
  }
  board.write(kDdrDebugAddr, args.ddr_addr);
  board.write(kDdrDebugByteEnable, 0xffff);
  for (int word = 0; word < 4; ++word) {
    board.write(uint16_t(kDdrDebugData0 + word * 4), args.ddr_pattern[word]);
  }
  board.write(kDdrDebugControl, kDdrDebugControlStart | kDdrDebugControlWrite);
  if (!args.dry_run) (void)wait_ddr_done(board, args.timeout_ms, args.poll_ms);

  board.write(kDdrDebugControl, kDdrDebugControlClear);
  board.write(kDdrDebugAddr, args.ddr_addr);
  board.write(kDdrDebugControl, kDdrDebugControlStart);
  if (!args.dry_run) (void)wait_ddr_done(board, args.timeout_ms, args.poll_ms);

  bool match = true;
  uint32_t data[4] = {};
  for (int word = 0; word < 4; ++word) {
    data[word] = board.read(uint16_t(kDdrDebugData0 + word * 4));
    if (data[word] != args.ddr_pattern[word]) match = false;
  }
  std::cout << "  readback = " << hex32(data[3]) << '_' << hex32(data[2]) << '_'
            << hex32(data[1]) << '_' << hex32(data[0]) << "\n";
  if (args.dry_run) {
    print_result("DRY", "DDR debug write/read access sequence emitted");
  } else if (match) {
    print_result("PASS", "DDR debug write/read pattern matched");
  } else {
    print_result("FAIL", "DDR debug readback did not match written pattern");
    throw std::runtime_error("DDR smoke mismatch");
  }
}

void run_voice_smoke(BoardAccess& board, const Args& args) {
  if (args.voice < 0 || args.voice >= render::kNumVoices) throw std::runtime_error("voice index out of range");
  if (args.length == 0) throw std::runtime_error("--voice-smoke requires --length");

  std::cout << "\n== Voice Smoke ==\n";
  board.write(kDebugEventFlags, 0x0fu);

  render::Region region;
  region.stereo = args.stereo;
  region.base_addr = args.base;
  region.base_addr_r = args.base_r ? args.base_r : args.base;
  region.length = args.length;
  region.length_r = args.length_r ? args.length_r : args.length;
  region.loop_start = 0;
  region.loop_start_r = 0;
  region.loop_end = 0;
  region.loop_end_r = 0;
  region.loop_mode = 0;
  region.gain_l = args.gain_l;
  region.gain_r = args.gain_r;
  region.filter_enable = false;
  region.filter_b0 = 0x10000000;

  render::RegisterVoiceControl voice_control(board);
  voice_control.set_envelope(args.voice, 0x7fff);
  voice_control.commit_voice(args.voice, 1, args.phase_inc, region);
  print_result("PASS", "Voice configuration writes completed");

  if (!args.dry_run) std::this_thread::sleep_for(std::chrono::milliseconds(250));
  uint32_t events = board.read(kDebugEventFlags);
  uint32_t audio = board.read(kAudioStatus);
  uint32_t memory = board.read(kMemoryStatus);
  uint32_t mem_rsp_count = board.read(kMemResponseCount);
  print_reg("DEBUG_EVENT_FLAGS", kDebugEventFlags, events);
  print_reg("AUDIO_STATUS", kAudioStatus, audio);
  print_reg("MEMORY_STATUS", kMemoryStatus, memory);
  print_reg("MEM_RESPONSE_COUNT", kMemResponseCount, mem_rsp_count);

  if (events & (1u << 3)) {
    print_result("PASS", "Voice caused memory response activity");
  } else {
    print_result("WARN", "No memory activity observed yet; check base address, length, and asset load");
  }
  if (events & 0x7u) {
    print_result("WARN", "Audio underrun/drop/deadline flags are set; inspect timing and FIFO status");
  }
}

void read_counters(BoardAccess& board) {
  std::cout << "\n== Event Counters ==\n";
  print_reg("UNDERRUN_COUNT", kUnderrunCount, board.read(kUnderrunCount));
  print_reg("SAMPLE_DROP_COUNT", kSampleDropCount, board.read(kSampleDropCount));
  print_reg("RENDER_DEADLINE_MISS_COUNT", kRenderDeadlineMissCount, board.read(kRenderDeadlineMissCount));
  print_reg("MEM_RESPONSE_COUNT", kMemResponseCount, board.read(kMemResponseCount));
}

}  // namespace

int main(int argc, char** argv) {
  try {
    Args args = parse_args(argc, argv);
    if (args.poll_ms == 0) throw std::runtime_error("--poll-ms must be nonzero");

    std::unique_ptr<host::Ch347RegisterTransport> hardware;
    DryRunTransport dry_run;
    if (!args.dry_run) hardware.reset(new host::Ch347RegisterTransport(args.ch347));
    BoardAccess board(hardware.get(), args.dry_run ? &dry_run : nullptr);

    if (!read_snapshot(board, args.dry_run)) return 2;
    if (args.wait_ddr) {
      if (!poll_until(board, args, "DDR calibration and debug window", false)) return 2;
    }
    if (args.wait_asset) {
      if (!poll_until(board, args, "SD asset load", true)) return 2;
    }
    if (args.ddr_smoke) run_ddr_smoke(board, args);
    if (args.voice_smoke) run_voice_smoke(board, args);
    read_counters(board);
  } catch (const std::exception& e) {
    std::cerr << "error: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
