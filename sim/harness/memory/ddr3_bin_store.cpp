#include "ddr3_bin_store.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

namespace fs = std::filesystem;

struct Segment {
  std::uint64_t base_word = 0;
  std::vector<std::uint8_t> bytes;

  std::uint64_t word_count() const { return bytes.size() / 2; }
  std::uint64_t end_word() const { return base_word + word_count(); }
};

struct Image {
  std::vector<Segment> segments;
  std::uint64_t loaded_words = 0;
};

std::mutex image_mutex;
std::map<int, std::unique_ptr<Image>> images;
int next_handle = 1;

std::vector<std::uint8_t> read_file(const fs::path& path) {
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  if (!stream) throw std::runtime_error("cannot open " + path.string());

  const std::streamoff length = stream.tellg();
  if (length < 0 || (length & 1) != 0) {
    throw std::runtime_error("DDR3 bin size must be an even byte count: " +
                             path.string());
  }
  if (static_cast<std::uint64_t>(length) >
      std::numeric_limits<std::size_t>::max()) {
    throw std::runtime_error("DDR3 bin is too large for this host: " +
                             path.string());
  }

  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(length));
  stream.seekg(0);
  if (!bytes.empty()) {
    stream.read(reinterpret_cast<char*>(bytes.data()), length);
    if (!stream) throw std::runtime_error("cannot read " + path.string());
  }
  return bytes;
}

bool parse_hex_word_address(std::string stem, std::uint64_t* address) {
  if (stem.rfind("0x", 0) == 0 || stem.rfind("0X", 0) == 0) stem.erase(0, 2);
  if (stem.empty() ||
      !std::all_of(stem.begin(), stem.end(), [](unsigned char character) {
        return std::isxdigit(character) != 0;
      })) {
    return false;
  }
  try {
    std::size_t parsed = 0;
    *address = std::stoull(stem, &parsed, 16);
    return parsed == stem.size();
  } catch (const std::exception&) {
    return false;
  }
}

void validate_segments(Image* image) {
  std::sort(image->segments.begin(), image->segments.end(),
            [](const Segment& lhs, const Segment& rhs) {
              return lhs.base_word < rhs.base_word;
            });
  for (std::size_t index = 1; index < image->segments.size(); ++index) {
    if (image->segments[index - 1].end_word() >
        image->segments[index].base_word) {
      throw std::runtime_error("DDR3 bin address ranges overlap");
    }
  }
}

std::unique_ptr<Image> load_image(const fs::path& path) {
  auto image = std::make_unique<Image>();
  if (fs::is_regular_file(path)) {
    auto bytes = read_file(path);
    image->loaded_words = bytes.size() / 2;
    image->segments.push_back(Segment{0, std::move(bytes)});
    return image;
  }
  if (!fs::is_directory(path)) {
    throw std::runtime_error("DDR3 image path is not a file or directory: " +
                             path.string());
  }

  std::vector<fs::path> files;
  for (const auto& entry : fs::directory_iterator(path)) {
    if (entry.is_regular_file() && entry.path().extension() == ".bin") {
      files.push_back(entry.path());
    }
  }
  std::sort(files.begin(), files.end());
  if (files.empty()) {
    throw std::runtime_error("DDR3 image directory contains no .bin files: " +
                             path.string());
  }

  bool addressed = false;
  bool concatenated = false;
  std::uint64_t next_word = 0;
  for (const auto& file : files) {
    std::uint64_t base_word = 0;
    const bool has_address =
        parse_hex_word_address(file.stem().string(), &base_word);
    addressed = addressed || has_address;
    concatenated = concatenated || !has_address;
    if (addressed && concatenated) {
      throw std::runtime_error(
          "DDR3 image directory cannot mix addressed and named .bin files");
    }

    auto bytes = read_file(file);
    if (!has_address) base_word = next_word;
    const std::uint64_t words = bytes.size() / 2;
    if (base_word > std::numeric_limits<std::uint64_t>::max() - words) {
      throw std::runtime_error("DDR3 bin address range overflows");
    }
    if (image->loaded_words >
        std::numeric_limits<std::uint64_t>::max() - words) {
      throw std::runtime_error("total DDR3 image size overflows");
    }
    image->loaded_words += words;
    image->segments.push_back(Segment{base_word, std::move(bytes)});
    next_word = base_word + words;
  }
  validate_segments(image.get());
  return image;
}

}  // namespace

extern "C" int ddr3_bin_open(const char* path) {
  try {
    if (path == nullptr || path[0] == '\0') {
      throw std::runtime_error("DDR3 image path is empty");
    }
    auto image = load_image(path);
    std::lock_guard<std::mutex> lock(image_mutex);
    const int handle = next_handle++;
    images.emplace(handle, std::move(image));
    return handle;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "ddr3_bin_open: %s\n", error.what());
    return -1;
  }
}

extern "C" std::uint16_t ddr3_bin_read_word(int handle,
                                              std::uint64_t word_address) {
  std::lock_guard<std::mutex> lock(image_mutex);
  const auto image_it = images.find(handle);
  if (image_it == images.end()) return 0;

  const auto& segments = image_it->second->segments;
  const auto segment_it = std::upper_bound(
      segments.begin(), segments.end(), word_address,
      [](std::uint64_t address, const Segment& segment) {
        return address < segment.base_word;
      });
  if (segment_it == segments.begin()) return 0;
  const Segment& segment = *std::prev(segment_it);
  if (word_address >= segment.end_word()) return 0;

  const std::size_t byte_offset =
      static_cast<std::size_t>((word_address - segment.base_word) * 2);
  return static_cast<std::uint16_t>(segment.bytes[byte_offset]) |
         (static_cast<std::uint16_t>(segment.bytes[byte_offset + 1]) << 8);
}

extern "C" std::uint64_t ddr3_bin_word_count(int handle) {
  std::lock_guard<std::mutex> lock(image_mutex);
  const auto image = images.find(handle);
  return image == images.end() ? 0 : image->second->loaded_words;
}

extern "C" void ddr3_bin_close(int handle) {
  std::lock_guard<std::mutex> lock(image_mutex);
  images.erase(handle);
}
