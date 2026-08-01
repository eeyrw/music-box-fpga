#include "generated/register_map.h"
#include "sf2_loader.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <set>
#include <stdexcept>
#include <string>
#include <sys/resource.h>
#include <utility>

namespace {

using Clock = std::chrono::steady_clock;

constexpr int kSampleRate = 48000;
constexpr int kControlTickSamples = 48;
constexpr const char* kProfile = "generic-le32-48k-tick48-v13";

struct LookupKey {
  int program = 0;
  int bank = 0;
  int key = 0;
  int velocity = 1;
};

uint64_t peak_rss_bytes() {
  rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0) {
    throw std::runtime_error("getrusage failed");
  }
#if defined(__APPLE__)
  return uint64_t(usage.ru_maxrss);
#else
  return uint64_t(usage.ru_maxrss) * 1024u;
#endif
}

std::string json_string(const std::string& value) {
  std::string result = "\"";
  for (unsigned char c : value) {
    switch (c) {
      case '\\': result += "\\\\"; break;
      case '"': result += "\\\""; break;
      case '\n': result += "\\n"; break;
      case '\r': result += "\\r"; break;
      case '\t': result += "\\t"; break;
      default:
        if (c < 0x20) throw std::runtime_error("control character in JSON string");
        result += char(c);
        break;
    }
  }
  result += '"';
  return result;
}

uint64_t region_checksum(const std::shared_ptr<const std::vector<render::Region>>& regions) {
  uint64_t checksum = regions->size();
  for (const auto& region : *regions) {
    checksum = checksum * 1315423911u + region.base_addr;
    checksum = checksum * 1315423911u + region.length;
  }
  return checksum;
}

struct LookupTiming {
  uint64_t iterations = 0;
  uint64_t total_ns = 0;
  uint64_t max_ns = 0;
  uint64_t checksum = 0;
};

template <typename Lookup>
LookupTiming measure_lookup(uint64_t iterations, Lookup lookup) {
  LookupTiming timing;
  timing.iterations = iterations;
  for (uint64_t iteration = 0; iteration < iterations; ++iteration) {
    const auto start = Clock::now();
    const auto regions = lookup(iteration);
    const uint64_t elapsed = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        Clock::now() - start).count());
    timing.total_ns += elapsed;
    timing.max_ns = std::max(timing.max_ns, elapsed);
    timing.checksum = timing.checksum * 1099511628211ull +
                      region_checksum(regions) + iteration;
  }
  return timing;
}

void write_timing(const char* name, const LookupTiming& timing, bool trailing_comma) {
  const uint64_t average = timing.iterations == 0 ? 0 : timing.total_ns / timing.iterations;
  std::cout << "    \"" << name << "\": {\"iterations\": " << timing.iterations
            << ", \"average_ns\": " << average
            << ", \"max_ns\": " << timing.max_ns
            << ", \"checksum\": " << timing.checksum << "}"
            << (trailing_comma ? "," : "") << "\n";
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 2) {
      std::cerr << "usage: mcu_sf2_baseline <soundfont.sf2>\n";
      return 2;
    }
    if (render::regs::kVersionValue != 0x000d0000u) {
      throw std::runtime_error("reference MCU asset profile requires command interface 13");
    }

    const std::string path = argv[1];
    const uint64_t file_bytes = std::filesystem::file_size(path);
    const auto load_start = Clock::now();
    render::Sf2Data sf2 = render::load_sf2(path);
    const uint64_t load_ns = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        Clock::now() - load_start).count());
    const render::Sf2LoaderStats loader = render::sf2_loader_stats(sf2);

    std::set<std::pair<int, int>> presets;
    if (!sf2.presets.empty()) {
      for (size_t index = 0; index + 1 < sf2.presets.size(); ++index) {
        presets.emplace(sf2.presets[index].bank, sf2.presets[index].preset);
      }
    }

    uint64_t selection_count = 0;
    uint64_t playable_selection_count = 0;
    uint64_t layer_reference_count = 0;
    size_t maximum_layers = 0;
    LookupKey first_playable;
    bool have_first_playable = false;
    render::Sf2RegionCache scan_cache(sf2, kSampleRate, kControlTickSamples, 1);
    const auto scan_start = Clock::now();
    for (const auto& preset : presets) {
      for (int key = 0; key < 128; ++key) {
        for (int velocity = 1; velocity < 128; ++velocity) {
          const auto regions = scan_cache.regions_for_preset(
              preset.second, preset.first, key, velocity);
          ++selection_count;
          if (regions->empty()) continue;
          ++playable_selection_count;
          layer_reference_count += regions->size();
          maximum_layers = std::max(maximum_layers, regions->size());
          if (!have_first_playable) {
            first_playable = {preset.second, preset.first, key, velocity};
            have_first_playable = true;
          }
        }
      }
    }
    const uint64_t scan_ns = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        Clock::now() - scan_start).count());
    if (!have_first_playable) throw std::runtime_error("SoundFont has no playable preset region");

    render::Sf2RegionCache warm_cache(sf2, kSampleRate, kControlTickSamples, 4);
    (void)warm_cache.regions_for_preset(first_playable.program, first_playable.bank,
                                        first_playable.key, first_playable.velocity);
    const LookupTiming warm = measure_lookup(10000, [&](uint64_t) {
      return warm_cache.regions_for_preset(first_playable.program, first_playable.bank,
                                           first_playable.key, first_playable.velocity);
    });

    LookupKey alternate = first_playable;
    alternate.key ^= 1;
    render::Sf2RegionCache cold_cache(sf2, kSampleRate, kControlTickSamples, 1);
    const LookupTiming cold = measure_lookup(1000, [&](uint64_t iteration) {
      const LookupKey& lookup = (iteration & 1u) == 0 ? first_playable : alternate;
      return cold_cache.regions_for_preset(
          lookup.program, lookup.bank, lookup.key, lookup.velocity);
    });

    std::cout << std::fixed << std::setprecision(3)
              << "{\n"
              << "  \"schema\": \"mcu-sf2-baseline-v1\",\n"
              << "  \"profile\": \"" << kProfile << "\",\n"
              << "  \"command_interface_version\": \"0x000d0000\",\n"
              << "  \"sample_rate\": " << kSampleRate << ",\n"
              << "  \"control_tick_samples\": " << kControlTickSamples << ",\n"
              << "  \"path\": " << json_string(path) << ",\n"
              << "  \"file_bytes\": " << file_bytes << ",\n"
              << "  \"load_ms\": " << double(load_ns) / 1000000.0 << ",\n"
              << "  \"peak_rss_bytes\": " << peak_rss_bytes() << ",\n"
              << "  \"retained_bytes\": " << loader.retained_bytes << ",\n"
              << "  \"compiled_retained_bytes\": " << loader.compiled_retained_bytes << ",\n"
              << "  \"compiled_preset_candidates\": "
              << loader.compiled_preset_candidate_count << ",\n"
              << "  \"compiled_instrument_candidates\": "
              << loader.compiled_instrument_candidate_count << ",\n"
              << "  \"selection_scan\": {\n"
              << "    \"preset_count\": " << presets.size() << ",\n"
              << "    \"selection_count\": " << selection_count << ",\n"
              << "    \"playable_selection_count\": " << playable_selection_count << ",\n"
              << "    \"layer_reference_count\": " << layer_reference_count << ",\n"
              << "    \"maximum_layers\": " << maximum_layers << ",\n"
              << "    \"elapsed_ms\": " << double(scan_ns) / 1000000.0 << "\n"
              << "  },\n"
              << "  \"region_lookup\": {\n";
    write_timing("warm", warm, true);
    write_timing("forced_cold", cold, false);
    std::cout << "  }\n}\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "mcu_sf2_baseline failed: " << error.what() << '\n';
    return 1;
  }
}
