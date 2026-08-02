#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>

#include "host/ch347_transport.h"
#include "sim/harness/generated/register_map.h"

namespace {

constexpr uint32_t kBeatBytes = 16;
constexpr uint64_t kDdrBytes = 512ull * 1024ull * 1024ull;

struct Args {
  host::Ch347Options ch347;
  uint32_t address = 0;
  uint32_t bytes = 64 * 1024;
  uint32_t timeout_polls = 10000;
  std::optional<std::string> output_path;
  std::optional<std::string> verify_path;
};

uint64_t parse_u64(const char* text, const char* name) {
  char* end = nullptr;
  const unsigned long long value = std::strtoull(text, &end, 0);
  if (end == text || *end != '\0') {
    throw std::runtime_error(std::string("invalid ") + name + ": " + text);
  }
  return value;
}

const char* need_arg(int argc, char** argv, int& index, const char* option) {
  if (++index >= argc) throw std::runtime_error(std::string("missing value for ") + option);
  return argv[index];
}

void print_usage(const char* program) {
  std::cout
      << "Usage: " << program << " [options]\n"
      << "  --device PATH       CH347 device (default /dev/ch34x_pis2)\n"
      << "  --lib PATH          CH347 shared library\n"
      << "  --clock-hz HZ       requested SPI clock (default 30000000)\n"
      << "  --cs-mask VALUE     chip-select mask (default 0x80)\n"
      << "  --address VALUE     aligned DDR byte address (default 0)\n"
      << "  --bytes VALUE       byte count, multiple of 16 (default 65536)\n"
      << "  --timeout-polls N   status polls per DDR beat (default 10000)\n"
      << "  --output PATH       save read data to a file\n"
      << "  --verify PATH       compare against this file at the same offset\n";
}

Args parse_args(int argc, char** argv) {
  Args args;
  args.ch347.clock_hz = 30000000;
  for (int i = 1; i < argc; ++i) {
    const std::string option = argv[i];
    if (option == "--help" || option == "-h") {
      print_usage(argv[0]);
      std::exit(0);
    } else if (option == "--device") {
      args.ch347.device_path = need_arg(argc, argv, i, "--device");
    } else if (option == "--lib") {
      args.ch347.library_path = need_arg(argc, argv, i, "--lib");
    } else if (option == "--clock-hz") {
      const uint64_t value = parse_u64(need_arg(argc, argv, i, "--clock-hz"), "clock-hz");
      if (value > uint64_t(std::numeric_limits<int>::max())) {
        throw std::runtime_error("clock-hz is out of range");
      }
      args.ch347.clock_hz = static_cast<int>(value);
    } else if (option == "--cs-mask") {
      const uint64_t value = parse_u64(need_arg(argc, argv, i, "--cs-mask"), "cs-mask");
      if (value > 0xff) throw std::runtime_error("cs-mask is out of range");
      args.ch347.chip_select_mask = static_cast<uint8_t>(value);
    } else if (option == "--address") {
      const uint64_t value = parse_u64(need_arg(argc, argv, i, "--address"), "address");
      if (value > std::numeric_limits<uint32_t>::max()) {
        throw std::runtime_error("address is out of range");
      }
      args.address = static_cast<uint32_t>(value);
    } else if (option == "--bytes") {
      const uint64_t value = parse_u64(need_arg(argc, argv, i, "--bytes"), "bytes");
      if (value > std::numeric_limits<uint32_t>::max()) {
        throw std::runtime_error("bytes is out of range");
      }
      args.bytes = static_cast<uint32_t>(value);
    } else if (option == "--timeout-polls") {
      const uint64_t value = parse_u64(need_arg(argc, argv, i, "--timeout-polls"),
                                       "timeout-polls");
      if (value == 0 || value > std::numeric_limits<uint32_t>::max()) {
        throw std::runtime_error("timeout-polls is out of range");
      }
      args.timeout_polls = static_cast<uint32_t>(value);
    } else if (option == "--output") {
      args.output_path = need_arg(argc, argv, i, "--output");
    } else if (option == "--verify") {
      args.verify_path = need_arg(argc, argv, i, "--verify");
    } else {
      throw std::runtime_error("unknown option: " + option);
    }
  }
  if (args.bytes == 0 || (args.address % kBeatBytes) != 0 ||
      (args.bytes % kBeatBytes) != 0) {
    throw std::runtime_error("address and bytes must describe nonempty, 16-byte-aligned data");
  }
  if (uint64_t(args.address) + args.bytes > kDdrBytes) {
    throw std::runtime_error("requested range exceeds 512 MiB DDR");
  }
  return args;
}

uint32_t wait_done(host::Ch347RegisterTransport& transport, uint32_t timeout_polls) {
  using namespace render::regs;
  for (uint32_t poll = 0; poll < timeout_polls; ++poll) {
    const uint32_t status = transport.read_register(kDdrAccessStatus);
    if ((status & kDdrAccessStatusErrorMask) != 0) {
      std::ostringstream message;
      message << "DDR read failed, status=0x" << std::hex << status;
      throw std::runtime_error(message.str());
    }
    if ((status & kDdrAccessStatusDoneMask) != 0) return status;
  }
  throw std::runtime_error("DDR read timed out");
}

std::array<uint8_t, kBeatBytes> read_beat(host::Ch347RegisterTransport& transport,
                                          uint32_t address, uint32_t timeout_polls) {
  using namespace render::regs;
  transport.write_register(kDdrAccessControl, kDdrAccessControlClearMask);
  transport.write_register(kDdrAccessAddr, address);
  transport.write_register(kDdrAccessControl, kDdrAccessControlStartMask);
  wait_done(transport, timeout_polls);

  std::array<uint8_t, kBeatBytes> bytes{};
  for (uint32_t word_index = 0; word_index < 4; ++word_index) {
    const uint32_t word = transport.read_register(
        static_cast<uint16_t>(kDdrAccessData0 + 4 * word_index));
    for (uint32_t byte_index = 0; byte_index < 4; ++byte_index) {
      bytes[4 * word_index + byte_index] = static_cast<uint8_t>(word >> (8 * byte_index));
    }
  }
  return bytes;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    const Args args = parse_args(argc, argv);
    host::Ch347RegisterTransport transport(args.ch347);

    const uint32_t initial_status = transport.read_register(render::regs::kDdrAccessStatus);
    const uint32_t required = render::regs::kDdrAccessStatusPresentMask |
                              render::regs::kDdrAccessStatusReadyMask;
    if ((initial_status & required) != required) {
      std::ostringstream message;
      message << "DDR access window is not ready, status=0x" << std::hex << initial_status;
      throw std::runtime_error(message.str());
    }

    std::ofstream output;
    if (args.output_path) {
      output.open(*args.output_path, std::ios::binary | std::ios::trunc);
      if (!output) throw std::runtime_error("cannot open output file: " + *args.output_path);
    }
    std::ifstream expected;
    if (args.verify_path) {
      expected.open(*args.verify_path, std::ios::binary);
      if (!expected) throw std::runtime_error("cannot open verify file: " + *args.verify_path);
      expected.seekg(args.address);
      if (!expected) throw std::runtime_error("cannot seek verify file to requested address");
    }

    uint64_t mismatch_count = 0;
    uint64_t first_mismatch = 0;
    uint8_t first_actual = 0;
    uint8_t first_expected = 0;
    uint32_t fnv1a = 2166136261u;
    const auto begin = std::chrono::steady_clock::now();
    for (uint32_t offset = 0; offset < args.bytes; offset += kBeatBytes) {
      const auto beat = read_beat(transport, args.address + offset, args.timeout_polls);
      if (output.is_open()) {
        output.write(reinterpret_cast<const char*>(beat.data()), beat.size());
      }
      for (uint32_t index = 0; index < beat.size(); ++index) {
        fnv1a = (fnv1a ^ beat[index]) * 16777619u;
        if (expected.is_open()) {
          char reference = 0;
          if (!expected.get(reference)) throw std::runtime_error("verify file is too short");
          const uint8_t reference_byte = static_cast<uint8_t>(reference);
          if (beat[index] != reference_byte) {
            if (mismatch_count == 0) {
              first_mismatch = uint64_t(args.address) + offset + index;
              first_actual = beat[index];
              first_expected = reference_byte;
            }
            ++mismatch_count;
          }
        }
      }
    }
    const auto end = std::chrono::steady_clock::now();
    if (output.is_open() && !output) {
      throw std::runtime_error("failed while writing output file");
    }

    const double seconds = std::chrono::duration<double>(end - begin).count();
    const double bytes_per_second = args.bytes / seconds;
    std::cout << "SPI requested=" << args.ch347.clock_hz
              << " Hz selected=" << transport.configured_clock_hz() << " Hz\n"
              << "DDR address=0x" << std::hex << std::setw(8) << std::setfill('0')
              << args.address << std::dec << std::setfill(' ') << " bytes=" << args.bytes
              << " beats=" << (args.bytes / kBeatBytes) << "\n"
              << std::fixed << std::setprecision(3) << "elapsed=" << seconds
              << " s throughput=" << (bytes_per_second / 1024.0) << " KiB/s ("
              << (bytes_per_second * 8.0 / 1000000.0) << " Mbit/s)\n"
              << "fnv1a32=0x" << std::hex << std::setw(8) << std::setfill('0') << fnv1a
              << std::dec << std::setfill(' ') << "\n";
    if (expected.is_open()) {
      std::cout << "verify=" << (mismatch_count == 0 ? "PASS" : "FAIL")
                << " mismatches=" << mismatch_count << "\n";
      if (mismatch_count != 0) {
        std::cout << "first mismatch at 0x" << std::hex << first_mismatch
                  << ": actual=0x" << unsigned(first_actual)
                  << " expected=0x" << unsigned(first_expected) << std::dec << "\n";
        return 2;
      }
    }
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "error: " << error.what() << "\n";
    return 1;
  }
}
