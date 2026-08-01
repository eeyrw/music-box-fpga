#include "mcu_sf2_asset.h"

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

std::string json_string(const std::string& value) {
  std::string result = "\"";
  for (unsigned char c : value) {
    if (c == '\\') result += "\\\\";
    else if (c == '"') result += "\\\"";
    else if (c == '\n') result += "\\n";
    else if (c == '\r') result += "\\r";
    else if (c == '\t') result += "\\t";
    else if (c < 0x20) throw std::runtime_error("control character in JSON path");
    else result += char(c);
  }
  result += '"';
  return result;
}

std::vector<uint8_t> read_file(const std::string& path) {
  std::ifstream source(path, std::ios::binary);
  if (!source) throw std::runtime_error("cannot open MCU SF2 asset: " + path);
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(source), {});
}

render::McuSf2AssetSelection read_selection(const std::string& path) {
  render::McuSf2AssetSelection selection;
  if (path.empty()) return selection;
  std::ifstream input(path);
  if (!input) throw std::runtime_error("cannot open MCU preset set: " + path);
  std::string line;
  int line_number = 0;
  while (std::getline(input, line)) {
    ++line_number;
    const size_t comment = line.find('#');
    if (comment != std::string::npos) line.erase(comment);
    std::istringstream fields(line);
    int bank = -1;
    int program = -1;
    if (!(fields >> bank)) continue;
    if (!(fields >> program) || bank < 0 || bank > 16383 ||
        program < 0 || program > 127) {
      throw std::runtime_error("invalid MCU preset set line " +
                               std::to_string(line_number));
    }
    std::string extra;
    if (fields >> extra) {
      throw std::runtime_error("extra field in MCU preset set line " +
                               std::to_string(line_number));
    }
    selection.presets.emplace_back(uint16_t(bank), uint16_t(program));
  }
  if (selection.presets.empty()) {
    throw std::runtime_error("MCU preset set is empty; omit it to select all presets");
  }
  return selection;
}

void write_file(const std::string& path, const std::vector<uint8_t>& data) {
  std::ofstream output(path, std::ios::binary);
  if (!output) throw std::runtime_error("cannot create MCU SF2 asset: " + path);
  output.write(reinterpret_cast<const char*>(data.data()), std::streamsize(data.size()));
  if (!output) throw std::runtime_error("failed writing MCU SF2 asset: " + path);
}

void write_report(const char* action, const std::string& asset_path,
                  const render::McuSf2AssetView& view, size_t image_size,
                  bool source_checked) {
  uint16_t maximum_layers = 0;
  uint16_t maximum_modulation_terms = 0;
  for (size_t index = 0; index < view.velocity_span_count(); ++index) {
    maximum_layers = std::max(maximum_layers, view.velocity_span(index).layer_count);
  }
  for (size_t index = 0; index < view.modulation_program_count(); ++index) {
    maximum_modulation_terms = std::max(maximum_modulation_terms,
                                        view.modulation_program(index).term_count);
  }
  std::cout << "{\n"
            << "  \"schema\": \"mcu-sf2-asset-report-v1\",\n"
            << "  \"action\": \"" << action << "\",\n"
            << "  \"profile\": \""
            << render::reference_mcu_sf2_asset_profile().id << "\",\n"
            << "  \"asset_path\": " << json_string(asset_path) << ",\n"
            << "  \"image_bytes\": " << image_size << ",\n"
            << "  \"source_bytes\": " << view.source_size_bytes() << ",\n"
            << "  \"source_crc32\": " << view.source_crc32() << ",\n"
            << "  \"source_checked\": " << (source_checked ? "true" : "false") << ",\n"
            << "  \"selection_crc32\": " << view.selection_crc32() << ",\n"
            << "  \"selected_presets\": " << view.selected_preset_count() << ",\n"
            << "  \"presets\": " << view.preset_count() << ",\n"
            << "  \"candidates\": " << view.candidate_count() << ",\n"
            << "  \"generators\": " << view.generator_count() << ",\n"
            << "  \"modulators\": " << view.modulator_count() << ",\n"
            << "  \"samples\": " << view.sample_count() << ",\n"
            << "  \"preset_dispatch\": " << view.preset_dispatch_count() << ",\n"
            << "  \"key_dispatch\": " << view.key_dispatch_count() << ",\n"
            << "  \"velocity_spans\": " << view.velocity_span_count() << ",\n"
            << "  \"layer_references\": " << view.layer_reference_count() << ",\n"
            << "  \"mono_descriptors\": " << view.mono_descriptor_count() << ",\n"
            << "  \"start_words\": " << view.start_word_count() << ",\n"
            << "  \"candidate_programs\": " << view.candidate_program_count() << ",\n"
            << "  \"modulation_programs\": " << view.modulation_program_count() << ",\n"
            << "  \"modulation_terms\": " << view.modulation_term_count() << ",\n"
            << "  \"source_curve_values\": " << view.source_curve_value_count() << ",\n"
            << "  \"maximum_layers\": " << maximum_layers << ",\n"
            << "  \"maximum_modulation_terms\": " << maximum_modulation_terms << "\n"
            << "}\n";
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc < 3 || argc > 5) {
      throw std::runtime_error(
          "usage: mcu_sf2_asset build <source.sf2> <output.msf2> [preset-set.txt] | "
          "verify <asset.msf2> [source.sf2]");
    }
    const std::string action = argv[1];
    if (action == "build") {
      if (argc != 4 && argc != 5) {
        throw std::runtime_error("build requires source and output paths");
      }
      const uint64_t source_size = std::filesystem::file_size(argv[2]);
      render::Sf2Data sf2 = render::load_sf2(argv[2]);
      const render::McuSf2AssetSelection selection =
          read_selection(argc == 5 ? argv[4] : "");
      const std::vector<uint8_t> image =
          render::build_mcu_sf2_asset(sf2, source_size,
                                      render::reference_mcu_sf2_asset_profile(), selection);
      write_file(argv[3], image);
      const render::McuSf2AssetView view(image.data(), image.size());
      if (!view.matches_source(sf2, source_size)) {
        throw std::runtime_error("generated MCU SF2 asset does not match source");
      }
      write_report("build", argv[3], view, image.size(), true);
      return 0;
    }
    if (action == "verify") {
      if (argc > 4) throw std::runtime_error("verify accepts only an optional source path");
      const std::vector<uint8_t> image = read_file(argv[2]);
      const render::McuSf2AssetView view(image.data(), image.size());
      bool source_checked = false;
      if (argc == 4) {
        const uint64_t source_size = std::filesystem::file_size(argv[3]);
        const render::Sf2Data sf2 = render::load_sf2(argv[3]);
        if (!view.matches_source(sf2, source_size)) {
          throw std::runtime_error("MCU SF2 asset source identity mismatch");
        }
        source_checked = true;
      }
      write_report("verify", argv[2], view, image.size(), source_checked);
      return 0;
    }
    throw std::runtime_error("unknown MCU SF2 asset action: " + action);
  } catch (const std::exception& error) {
    std::cerr << "mcu_sf2_asset failed: " << error.what() << '\n';
    return 1;
  }
}
