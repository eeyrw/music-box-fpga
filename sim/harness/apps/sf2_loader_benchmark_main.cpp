#include "sf2_loader.h"

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/resource.h>

namespace {

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

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 2) {
      std::cerr << "usage: sf2_loader_benchmark <soundfont.sf2>\n";
      return 2;
    }
    const std::string path = argv[1];
    const uint64_t file_bytes = std::filesystem::file_size(path);
    const auto start = std::chrono::steady_clock::now();
    render::Sf2Data sf2 = render::load_sf2(path);
    const auto finish = std::chrono::steady_clock::now();
    const double load_ms = std::chrono::duration<double, std::milli>(finish - start).count();
    const render::Sf2LoaderStats stats = render::sf2_loader_stats(sf2);

    std::cout << std::fixed << std::setprecision(3)
              << "{\n"
              << "  \"path\": \"" << path << "\",\n"
              << "  \"file_bytes\": " << file_bytes << ",\n"
              << "  \"load_ms\": " << load_ms << ",\n"
              << "  \"peak_rss_bytes\": " << peak_rss_bytes() << ",\n"
              << "  \"retained_bytes\": " << stats.retained_bytes << ",\n"
              << "  \"compiled_retained_bytes\": " << stats.compiled_retained_bytes << ",\n"
              << "  \"records\": {\n"
              << "    \"presets\": " << stats.preset_count << ",\n"
              << "    \"instruments\": " << stats.instrument_count << ",\n"
              << "    \"preset_bags\": " << stats.preset_bag_count << ",\n"
              << "    \"instrument_bags\": " << stats.instrument_bag_count << ",\n"
              << "    \"preset_generators\": " << stats.preset_generator_count << ",\n"
              << "    \"instrument_generators\": " << stats.instrument_generator_count << ",\n"
              << "    \"preset_modulators\": " << stats.preset_modulator_count << ",\n"
              << "    \"instrument_modulators\": " << stats.instrument_modulator_count << ",\n"
              << "    \"samples\": " << stats.sample_count << ",\n"
              << "    \"compiled_preset_candidates\": "
              << stats.compiled_preset_candidate_count << ",\n"
              << "    \"compiled_instrument_candidates\": "
              << stats.compiled_instrument_candidate_count << "\n"
              << "  }\n"
              << "}\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "sf2_loader_benchmark failed: " << error.what() << "\n";
    return 1;
  }
}
