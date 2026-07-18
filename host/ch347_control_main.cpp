#include "host/ch347_transport.h"

#include "sim/harness/register_control.h"

#include <cstdint>
#include <cstdlib>
#include <cctype>
#include <exception>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct RegisterWrite {
  uint16_t address = 0;
  uint32_t data = 0;
};

struct RegisterRead {
  uint16_t address = 0;
};

struct SetEnvelope {
  int voice = 0;
  int level = 0;
};

struct ReleaseVoice {
  int voice = 0;
};

struct CommitVoice {
  int voice = 0;
  int enable = 1;
  uint32_t phase_inc = 0x00010000;
  render::Region region;
};

struct DdrDebugWrite {
  uint32_t byte_addr = 0;
  uint32_t data[4] = {};
  uint16_t byte_enable = 0xffff;
  uint32_t timeout_polls = 10000;
};

struct DdrDebugRead {
  uint32_t byte_addr = 0;
  uint32_t timeout_polls = 10000;
};

struct Action {
  enum Type {
    WriteRegisterAction,
    ReadRegisterAction,
    SetEnvelopeAction,
    ReleaseAction,
    CommitAction,
    DdrDebugWriteAction,
    DdrDebugReadAction,
    ReadLoadProgressAction,
  } type = WriteRegisterAction;

  RegisterWrite write;
  RegisterRead read;
  SetEnvelope envelope;
  ReleaseVoice release;
  CommitVoice commit;
  DdrDebugWrite ddr_write;
  DdrDebugRead ddr_read;
};

struct Args {
  host::Ch347Options ch347;
  bool dry_run = false;
  uint16_t ddr_byte_enable = 0xffff;
  uint32_t ddr_timeout_polls = 10000;
  std::vector<Action> actions;
};

constexpr uint16_t kDdrDebugControl = render::regs::kDdrDebugControl;
constexpr uint16_t kDdrDebugStatus = render::regs::kDdrDebugStatus;
constexpr uint16_t kDdrDebugAddr = render::regs::kDdrDebugAddr;
constexpr uint16_t kDdrDebugByteEnable = render::regs::kDdrDebugByteEnable;
constexpr uint16_t kDdrDebugData0 = render::regs::kDdrDebugData0;
constexpr uint16_t kPlatformBytesLoaded = render::regs::kPlatformBytesLoaded;
constexpr uint32_t kDdrDebugControlStart = render::regs::kDdrDebugControlStartMask;
constexpr uint32_t kDdrDebugControlWrite = render::regs::kDdrDebugControlWriteMask;
constexpr uint32_t kDdrDebugControlClear = render::regs::kDdrDebugControlClearMask;
constexpr uint32_t kDdrDebugStatusReady = render::regs::kDdrDebugStatusReadyMask;
constexpr uint32_t kDdrDebugStatusDone = render::regs::kDdrDebugStatusDoneMask;
constexpr uint32_t kDdrDebugStatusError = render::regs::kDdrDebugStatusErrorMask;

class DryRunTransport : public render::RegisterWriteSink {
 public:
  void write_register(uint16_t address, uint32_t data) override {
    std::cout << "write addr=0x" << std::hex << std::setw(4) << std::setfill('0') << address
              << " data=0x" << std::setw(8) << data << std::dec << std::setfill(' ')
              << " frame=";
    uint8_t frame[7] = {0x80, uint8_t(address >> 8), uint8_t(address),
                        uint8_t(data >> 24), uint8_t(data >> 16),
                        uint8_t(data >> 8), uint8_t(data)};
    for (uint8_t byte : frame) {
      std::cout << ' ' << std::hex << std::setw(2) << std::setfill('0') << int(byte);
    }
    std::cout << std::dec << std::setfill(' ') << "\n";
  }

  void read_register(uint16_t address) {
    std::cout << "read addr=0x" << std::hex << std::setw(4) << std::setfill('0') << address
              << std::dec << std::setfill(' ') << " frame=";
    uint8_t frame[7] = {0x00, uint8_t(address >> 8), uint8_t(address), 0x00, 0x00, 0x00, 0x00};
    for (uint8_t byte : frame) {
      std::cout << ' ' << std::hex << std::setw(2) << std::setfill('0') << int(byte);
    }
    std::cout << std::dec << std::setfill(' ') << "\n";
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

uint16_t parse_u16(const std::string& text, const char* name) {
  uint32_t value = parse_u32(text, name);
  if (value > 0xffffu) throw std::runtime_error(std::string(name) + " out of range: " + text);
  return uint16_t(value);
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
      << "  " << argv0 << " [transport options] --write ADDR DATA [--write ADDR DATA ...]\n"
      << "  " << argv0 << " [transport options] --read ADDR [--read ADDR ...]\n"
      << "  " << argv0 << " [transport options] --read-load-progress\n"
      << "  " << argv0 << " [transport options] --set-envelope VOICE LEVEL\n"
      << "  " << argv0 << " [transport options] --commit-voice VOICE [voice options]\n"
      << "\nTransport options:\n"
      << "  --lib PATH              CH347 shared library path, default third_party/ch347_linux/lib/x64/libch347.so\n"
      << "  --device PATH|N         CH347 device path, default /dev/ch34x_pis0; N maps to /dev/ch34x_pisN\n"
      << "  --clock-hz HZ           SPI clock request, default 1000000\n"
      << "  --mode N                SPI mode 0..3, default 0\n"
      << "  --cs-mask VALUE         CH347 chip-select mask, default 0x80\n"
      << "  --dry-run               Print register frames without opening CH347\n"
      << "  --ddr-byte-enable MASK  Byte-enable mask for later --ddr-write, default 0xffff\n"
      << "  --ddr-timeout N         Poll limit for later DDR debug commands, default 10000\n"
      << "\nVoice options for --commit-voice:\n"
      << "  --enable 0|1            Default 1\n"
      << "  --stereo 0|1            Default 0\n"
      << "  --base ADDR             Left/mono wave-memory base word address\n"
      << "  --base-r ADDR           Right-channel wave-memory base word address\n"
      << "  --length FRAMES         Sample-frame length\n"
      << "  --length-r FRAMES       Right-channel sample-frame length, default length\n"
      << "  --loop-start FRAME      Default 0\n"
      << "  --loop-start-r FRAME    Right-channel loop start, default loop-start\n"
      << "  --loop-end FRAME        Default length\n"
      << "  --loop-end-r FRAME      Right-channel loop end, default length-r\n"
      << "  --loop-mode MODE        0 none, 1 continuous, 2 until release\n"
      << "  --phase-inc Q16_16      Default 0x00010000\n"
      << "  --gain-l Q1_15          Default 0x4000\n"
      << "  --gain-r Q1_15          Default 0x4000\n"
      << "\nOther operations:\n"
      << "  --release VOICE         Set RELEASE_CONTROL.released\n"
      << "  --read-load-progress  Read SD asset bytes-loaded progress\n"
      << "  --ddr-write ADDR D0 D1 D2 D3\n"
      << "                          Write one 16-byte DDR beat through the debug window\n"
      << "  --ddr-read ADDR         Read one 16-byte DDR beat through the debug window\n";
}

Args parse_args(int argc, char** argv) {
  Args args;
  CommitVoice current_commit;
  bool have_commit = false;
  bool commit_dirty = false;
  current_commit.region.gain_l = 0x4000;
  current_commit.region.gain_r = 0x4000;

  auto flush_commit = [&]() {
    if (!have_commit) return;
    if (current_commit.region.loop_end == 0) current_commit.region.loop_end = current_commit.region.length;
    if (current_commit.region.length_r == 0) current_commit.region.length_r = current_commit.region.length;
    if (current_commit.region.loop_start_r == 0) current_commit.region.loop_start_r = current_commit.region.loop_start;
    if (current_commit.region.loop_end_r == 0) current_commit.region.loop_end_r = current_commit.region.length_r;
    Action action;
    action.type = Action::CommitAction;
    action.commit = current_commit;
    args.actions.push_back(action);
    current_commit = CommitVoice{};
    current_commit.region.gain_l = 0x4000;
    current_commit.region.gain_r = 0x4000;
    have_commit = false;
    commit_dirty = false;
  };

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
    } else if (a == "--ddr-byte-enable") {
      args.ddr_byte_enable = parse_u16(need_arg(argc, argv, i, "--ddr-byte-enable"), "ddr-byte-enable");
    } else if (a == "--ddr-timeout") {
      args.ddr_timeout_polls = parse_u32(need_arg(argc, argv, i, "--ddr-timeout"), "ddr-timeout");
    } else if (a == "--write") {
      flush_commit();
      RegisterWrite write;
      write.address = parse_u16(need_arg(argc, argv, i, "--write address"), "address");
      write.data = parse_u32(need_arg(argc, argv, i, "--write data"), "data");
      Action action;
      action.type = Action::WriteRegisterAction;
      action.write = write;
      args.actions.push_back(action);
    } else if (a == "--read") {
      flush_commit();
      RegisterRead read;
      read.address = parse_u16(need_arg(argc, argv, i, "--read address"), "address");
      Action action;
      action.type = Action::ReadRegisterAction;
      action.read = read;
      args.actions.push_back(action);
    } else if (a == "--read-load-progress") {
      flush_commit();
      Action action;
      action.type = Action::ReadLoadProgressAction;
      args.actions.push_back(action);
    } else if (a == "--ddr-write") {
      flush_commit();
      DdrDebugWrite write;
      write.byte_addr = parse_u32(need_arg(argc, argv, i, "--ddr-write address"), "ddr address");
      for (int word = 0; word < 4; ++word) {
        std::ostringstream name;
        name << "--ddr-write data" << word;
        write.data[word] = parse_u32(need_arg(argc, argv, i, name.str().c_str()), name.str().c_str());
      }
      write.byte_enable = args.ddr_byte_enable;
      write.timeout_polls = args.ddr_timeout_polls;
      Action action;
      action.type = Action::DdrDebugWriteAction;
      action.ddr_write = write;
      args.actions.push_back(action);
    } else if (a == "--ddr-read") {
      flush_commit();
      DdrDebugRead read;
      read.byte_addr = parse_u32(need_arg(argc, argv, i, "--ddr-read address"), "ddr address");
      read.timeout_polls = args.ddr_timeout_polls;
      Action action;
      action.type = Action::DdrDebugReadAction;
      action.ddr_read = read;
      args.actions.push_back(action);
    } else if (a == "--set-envelope") {
      flush_commit();
      SetEnvelope env;
      env.voice = parse_int(need_arg(argc, argv, i, "--set-envelope voice"), "voice");
      env.level = parse_int(need_arg(argc, argv, i, "--set-envelope level"), "level");
      Action action;
      action.type = Action::SetEnvelopeAction;
      action.envelope = env;
      args.actions.push_back(action);
    } else if (a == "--release") {
      flush_commit();
      ReleaseVoice release;
      release.voice = parse_int(need_arg(argc, argv, i, "--release voice"), "voice");
      Action action;
      action.type = Action::ReleaseAction;
      action.release = release;
      args.actions.push_back(action);
    } else if (a == "--commit-voice") {
      flush_commit();
      have_commit = true;
      commit_dirty = true;
      current_commit.voice = parse_int(need_arg(argc, argv, i, "--commit-voice"), "voice");
    } else if (a == "--enable") {
      have_commit = true;
      current_commit.enable = parse_int(need_arg(argc, argv, i, "--enable"), "enable");
    } else if (a == "--stereo") {
      have_commit = true;
      current_commit.region.stereo = parse_int(need_arg(argc, argv, i, "--stereo"), "stereo") != 0;
    } else if (a == "--base") {
      have_commit = true;
      current_commit.region.base_addr = parse_u32(need_arg(argc, argv, i, "--base"), "base");
    } else if (a == "--base-r") {
      have_commit = true;
      current_commit.region.base_addr_r = parse_u32(need_arg(argc, argv, i, "--base-r"), "base-r");
    } else if (a == "--length") {
      have_commit = true;
      current_commit.region.length = parse_u32(need_arg(argc, argv, i, "--length"), "length");
    } else if (a == "--length-r") {
      have_commit = true;
      current_commit.region.length_r = parse_u32(need_arg(argc, argv, i, "--length-r"), "length-r");
    } else if (a == "--loop-start") {
      have_commit = true;
      current_commit.region.loop_start = parse_u32(need_arg(argc, argv, i, "--loop-start"), "loop-start");
    } else if (a == "--loop-start-r") {
      have_commit = true;
      current_commit.region.loop_start_r = parse_u32(need_arg(argc, argv, i, "--loop-start-r"), "loop-start-r");
    } else if (a == "--loop-end") {
      have_commit = true;
      current_commit.region.loop_end = parse_u32(need_arg(argc, argv, i, "--loop-end"), "loop-end");
    } else if (a == "--loop-end-r") {
      have_commit = true;
      current_commit.region.loop_end_r = parse_u32(need_arg(argc, argv, i, "--loop-end-r"), "loop-end-r");
    } else if (a == "--loop-mode") {
      have_commit = true;
      current_commit.region.loop_mode = parse_int(need_arg(argc, argv, i, "--loop-mode"), "loop-mode");
    } else if (a == "--phase-inc") {
      have_commit = true;
      current_commit.phase_inc = parse_u32(need_arg(argc, argv, i, "--phase-inc"), "phase-inc");
    } else if (a == "--gain-l") {
      have_commit = true;
      current_commit.region.gain_l = parse_int(need_arg(argc, argv, i, "--gain-l"), "gain-l");
    } else if (a == "--gain-r") {
      have_commit = true;
      current_commit.region.gain_r = parse_int(need_arg(argc, argv, i, "--gain-r"), "gain-r");
    } else {
      throw std::runtime_error("unknown argument: " + a);
    }
  }
  if (commit_dirty || have_commit) flush_commit();
  return args;
}

void validate_voice(int voice) {
  if (voice < 0 || voice >= render::kNumVoices) throw std::runtime_error("voice index out of range");
}

void validate_ddr_addr(uint32_t byte_addr) {
  if ((byte_addr & 0xfu) != 0) throw std::runtime_error("DDR debug address must be 16-byte aligned");
}

void write_debug_register(render::RegisterWriteSink& sink, uint16_t address, uint32_t data) {
  sink.write_register(address, data);
}

uint32_t wait_ddr_debug_done(host::Ch347RegisterTransport& transport, uint32_t timeout_polls) {
  for (uint32_t poll = 0; poll < timeout_polls; ++poll) {
    uint32_t status = transport.read_register(kDdrDebugStatus);
    if (status & kDdrDebugStatusError) {
      std::ostringstream msg;
      msg << "DDR debug command failed, status=0x" << std::hex << std::setw(8)
          << std::setfill('0') << status;
      throw std::runtime_error(msg.str());
    }
    if (status & kDdrDebugStatusDone) return status;
  }
  throw std::runtime_error("DDR debug command timed out");
}

void emit_dry_run_ddr_write(DryRunTransport& dry_run, const DdrDebugWrite& write) {
  dry_run.write_register(kDdrDebugControl, kDdrDebugControlClear);
  dry_run.write_register(kDdrDebugAddr, write.byte_addr);
  dry_run.write_register(kDdrDebugByteEnable, write.byte_enable);
  for (int word = 0; word < 4; ++word) {
    dry_run.write_register(uint16_t(kDdrDebugData0 + word * 4), write.data[word]);
  }
  dry_run.write_register(kDdrDebugControl, kDdrDebugControlStart | kDdrDebugControlWrite);
  dry_run.read_register(kDdrDebugStatus);
}

void emit_dry_run_ddr_read(DryRunTransport& dry_run, const DdrDebugRead& read) {
  dry_run.write_register(kDdrDebugControl, kDdrDebugControlClear);
  dry_run.write_register(kDdrDebugAddr, read.byte_addr);
  dry_run.write_register(kDdrDebugControl, kDdrDebugControlStart);
  dry_run.read_register(kDdrDebugStatus);
  for (int word = 0; word < 4; ++word) {
    dry_run.read_register(uint16_t(kDdrDebugData0 + word * 4));
  }
}

void emit_dry_run_load_progress(DryRunTransport& dry_run) {
  dry_run.read_register(kPlatformBytesLoaded);
}

void execute_load_progress(host::Ch347RegisterTransport* transport, DryRunTransport& dry_run,
                           bool dry_run_mode) {
  if (dry_run_mode) {
    emit_dry_run_load_progress(dry_run);
    return;
  }
  uint32_t bytes_loaded = transport->read_register(kPlatformBytesLoaded);
  std::cout << "load-progress bytes-loaded=" << bytes_loaded << " (0x" << std::hex
            << std::setw(8) << std::setfill('0') << bytes_loaded << std::dec
            << std::setfill(' ') << ")\n";
}

void execute_ddr_write(render::RegisterWriteSink& sink, host::Ch347RegisterTransport* transport,
                       DryRunTransport& dry_run, bool dry_run_mode, const DdrDebugWrite& write) {
  validate_ddr_addr(write.byte_addr);
  if (write.byte_enable == 0) throw std::runtime_error("DDR debug write byte-enable mask must be nonzero");
  if (dry_run_mode) {
    emit_dry_run_ddr_write(dry_run, write);
    return;
  }
  write_debug_register(sink, kDdrDebugControl, kDdrDebugControlClear);
  uint32_t status = transport->read_register(kDdrDebugStatus);
  if ((status & kDdrDebugStatusReady) == 0) {
    throw std::runtime_error("DDR debug window is not ready");
  }
  write_debug_register(sink, kDdrDebugAddr, write.byte_addr);
  write_debug_register(sink, kDdrDebugByteEnable, write.byte_enable);
  for (int word = 0; word < 4; ++word) {
    write_debug_register(sink, uint16_t(kDdrDebugData0 + word * 4), write.data[word]);
  }
  write_debug_register(sink, kDdrDebugControl, kDdrDebugControlStart | kDdrDebugControlWrite);
  status = wait_ddr_debug_done(*transport, write.timeout_polls);
  std::cout << "ddr-write addr=0x" << std::hex << std::setw(8) << std::setfill('0')
            << write.byte_addr << " byte-enable=0x" << std::setw(4) << write.byte_enable
            << " status=0x" << std::setw(8) << status << std::dec << std::setfill(' ') << "\n";
}

void execute_ddr_read(render::RegisterWriteSink& sink, host::Ch347RegisterTransport* transport,
                      DryRunTransport& dry_run, bool dry_run_mode, const DdrDebugRead& read) {
  validate_ddr_addr(read.byte_addr);
  if (dry_run_mode) {
    emit_dry_run_ddr_read(dry_run, read);
    return;
  }
  write_debug_register(sink, kDdrDebugControl, kDdrDebugControlClear);
  uint32_t status = transport->read_register(kDdrDebugStatus);
  if ((status & kDdrDebugStatusReady) == 0) {
    throw std::runtime_error("DDR debug window is not ready");
  }
  write_debug_register(sink, kDdrDebugAddr, read.byte_addr);
  write_debug_register(sink, kDdrDebugControl, kDdrDebugControlStart);
  status = wait_ddr_debug_done(*transport, read.timeout_polls);
  uint32_t data[4] = {};
  for (int word = 0; word < 4; ++word) {
    data[word] = transport->read_register(uint16_t(kDdrDebugData0 + word * 4));
  }
  std::cout << "ddr-read addr=0x" << std::hex << std::setw(8) << std::setfill('0')
            << read.byte_addr << " data=0x" << std::setw(8) << data[3] << '_' << std::setw(8)
            << data[2] << '_' << std::setw(8) << data[1] << '_' << std::setw(8) << data[0]
            << " status=0x" << std::setw(8) << status << std::dec << std::setfill(' ') << "\n";
}

}  // namespace

int main(int argc, char** argv) {
  try {
    Args args = parse_args(argc, argv);
    if (args.actions.empty()) {
      print_usage(argv[0]);
      return 1;
    }

    std::unique_ptr<host::Ch347RegisterTransport> transport;
    DryRunTransport dry_run;
    if (args.dry_run) {
      transport.reset();
    } else {
      transport.reset(new host::Ch347RegisterTransport(args.ch347));
    }
    render::RegisterWriteSink& sink = args.dry_run ? static_cast<render::RegisterWriteSink&>(dry_run)
                                                   : static_cast<render::RegisterWriteSink&>(*transport);
    render::RegisterVoiceControl voice_control(sink);

    for (const Action& action : args.actions) {
      if (action.type == Action::WriteRegisterAction) {
        sink.write_register(action.write.address, action.write.data);
      } else if (action.type == Action::ReadRegisterAction) {
        if (args.dry_run) {
          dry_run.read_register(action.read.address);
        } else {
          uint32_t data = transport->read_register(action.read.address);
          std::cout << "read addr=0x" << std::hex << std::setw(4) << std::setfill('0')
                    << action.read.address << " data=0x" << std::setw(8) << data
                    << std::dec << std::setfill(' ') << "\n";
        }
      } else if (action.type == Action::SetEnvelopeAction) {
        validate_voice(action.envelope.voice);
        voice_control.set_envelope(action.envelope.voice, action.envelope.level);
      } else if (action.type == Action::CommitAction) {
        validate_voice(action.commit.voice);
        voice_control.commit_voice(action.commit.voice, action.commit.enable,
                                   action.commit.phase_inc, action.commit.region);
      } else if (action.type == Action::ReleaseAction) {
        validate_voice(action.release.voice);
        render::Region r;
        voice_control.release_voice(action.release.voice, r);
      } else if (action.type == Action::DdrDebugWriteAction) {
        execute_ddr_write(sink, transport.get(), dry_run, args.dry_run, action.ddr_write);
      } else if (action.type == Action::DdrDebugReadAction) {
        execute_ddr_read(sink, transport.get(), dry_run, args.dry_run, action.ddr_read);
      } else if (action.type == Action::ReadLoadProgressAction) {
        execute_load_progress(transport.get(), dry_run, args.dry_run);
      }
    }
  } catch (const std::exception& e) {
    std::cerr << "error: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
