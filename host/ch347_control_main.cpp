#include "host/ch347_transport.h"

#include "sim/harness/register_control.h"

#include <cstdint>
#include <cstdlib>
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

struct Action {
  enum Type {
    WriteRegisterAction,
    SetEnvelopeAction,
    ReleaseAction,
    CommitAction,
  } type = WriteRegisterAction;

  RegisterWrite write;
  SetEnvelope envelope;
  ReleaseVoice release;
  CommitVoice commit;
};

struct Args {
  host::Ch347Options ch347;
  bool dry_run = false;
  std::vector<Action> actions;
};

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

std::string need_arg(int argc, char** argv, int& index, const char* name) {
  if (index + 1 >= argc) throw std::runtime_error(std::string("missing value for ") + name);
  return argv[++index];
}

void print_usage(const char* argv0) {
  std::cout
      << "Usage:\n"
      << "  " << argv0 << " [transport options] --write ADDR DATA [--write ADDR DATA ...]\n"
      << "  " << argv0 << " [transport options] --set-envelope VOICE LEVEL\n"
      << "  " << argv0 << " [transport options] --commit-voice VOICE [voice options]\n"
      << "\nTransport options:\n"
      << "  --lib PATH              CH347 shared library path, default libch347.so\n"
      << "  --device N              CH347 device index, default 0\n"
      << "  --clock-hz HZ           SPI clock request, default 1000000\n"
      << "  --mode N                SPI mode 0..3, default 0\n"
      << "  --cs-mask VALUE         CH347 chip-select mask, default 0x80\n"
      << "  --dry-run               Print register frames without opening CH347\n"
      << "\nVoice options for --commit-voice:\n"
      << "  --enable 0|1            Default 1\n"
      << "  --stereo 0|1            Default 0\n"
      << "  --base ADDR             Wave-memory base word address\n"
      << "  --length FRAMES         Sample-frame length\n"
      << "  --loop-start FRAME      Default 0\n"
      << "  --loop-end FRAME        Default length\n"
      << "  --loop-mode MODE        0 none, 1 continuous, 2 until release\n"
      << "  --phase-inc Q16_16      Default 0x00010000\n"
      << "  --gain-l Q1_15          Default 0x4000\n"
      << "  --gain-r Q1_15          Default 0x4000\n"
      << "\nOther operations:\n"
      << "  --release VOICE         Set RELEASE_CONTROL.released\n";
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
      args.ch347.device_index = parse_u32(need_arg(argc, argv, i, "--device"), "device");
    } else if (a == "--clock-hz") {
      args.ch347.clock_hz = parse_int(need_arg(argc, argv, i, "--clock-hz"), "clock-hz");
    } else if (a == "--mode") {
      args.ch347.spi_mode = parse_int(need_arg(argc, argv, i, "--mode"), "mode");
    } else if (a == "--cs-mask") {
      args.ch347.chip_select_mask = parse_u32(need_arg(argc, argv, i, "--cs-mask"), "cs-mask");
    } else if (a == "--dry-run") {
      args.dry_run = true;
    } else if (a == "--write") {
      flush_commit();
      RegisterWrite write;
      write.address = parse_u16(need_arg(argc, argv, i, "--write address"), "address");
      write.data = parse_u32(need_arg(argc, argv, i, "--write data"), "data");
      Action action;
      action.type = Action::WriteRegisterAction;
      action.write = write;
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
    } else if (a == "--length") {
      have_commit = true;
      current_commit.region.length = parse_u32(need_arg(argc, argv, i, "--length"), "length");
    } else if (a == "--loop-start") {
      have_commit = true;
      current_commit.region.loop_start = parse_u32(need_arg(argc, argv, i, "--loop-start"), "loop-start");
    } else if (a == "--loop-end") {
      have_commit = true;
      current_commit.region.loop_end = parse_u32(need_arg(argc, argv, i, "--loop-end"), "loop-end");
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

}  // namespace

int main(int argc, char** argv) {
  try {
    Args args = parse_args(argc, argv);
    if (args.actions.empty()) {
      print_usage(argv[0]);
      return 1;
    }

    std::unique_ptr<render::RegisterWriteSink> transport;
    DryRunTransport dry_run;
    if (args.dry_run) {
      transport.reset();
    } else {
      transport.reset(new host::Ch347RegisterTransport(args.ch347));
    }
    render::RegisterWriteSink& sink = args.dry_run ? static_cast<render::RegisterWriteSink&>(dry_run) : *transport;
    render::RegisterVoiceControl voice_control(sink);

    for (const Action& action : args.actions) {
      if (action.type == Action::WriteRegisterAction) {
        sink.write_register(action.write.address, action.write.data);
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
      }
    }
  } catch (const std::exception& e) {
    std::cerr << "error: " << e.what() << "\n";
    return 1;
  }
  return 0;
}
