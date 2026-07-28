#include "board_loader_render_utils.h"

#include <algorithm>
#include <fstream>
#include <stdexcept>

namespace render {
namespace {

void put_u32le(std::vector<uint8_t>& data, size_t offset, uint32_t value) {
  for (int i = 0; i < 4; ++i) data.at(offset + size_t(i)) = uint8_t((value >> (8 * i)) & 0xff);
}

void put_u64le(std::vector<uint8_t>& data, size_t offset, uint64_t value) {
  for (int i = 0; i < 8; ++i) data.at(offset + size_t(i)) = uint8_t((value >> (8 * i)) & 0xff);
}

}  // namespace

std::vector<uint8_t> read_file_bytes(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error("failed to open " + path);
  f.seekg(0, std::ios::end);
  std::streamoff size = f.tellg();
  if (size < 0) throw std::runtime_error("failed to size " + path);
  f.seekg(0, std::ios::beg);
  std::vector<uint8_t> data(static_cast<size_t>(size));
  if (!data.empty()) f.read(reinterpret_cast<char*>(data.data()), std::streamsize(data.size()));
  if (!f && !data.empty()) throw std::runtime_error("failed to read " + path);
  return data;
}

std::vector<uint8_t> make_raw_sd_image(const std::vector<uint8_t>& sf2_bytes,
                                       uint64_t sf2_start_lba) {
  const size_t total = size_t(sf2_start_lba) * 512u + sf2_bytes.size();
  std::vector<uint8_t> image((total + 511u) & ~size_t(511u), 0);
  image[0] = 'W';
  image[1] = 'T';
  image[2] = 'S';
  image[3] = 'F';
  put_u32le(image, 0x04, 1);
  put_u32le(image, 0x08, 0x40);
  put_u32le(image, 0x0c, 0);
  put_u64le(image, 0x10, sf2_start_lba);
  put_u64le(image, 0x18, sf2_bytes.size());
  put_u64le(image, 0x20, 0);
  std::copy(sf2_bytes.begin(), sf2_bytes.end(), image.begin() + size_t(sf2_start_lba) * 512u);
  return image;
}

std::vector<int16_t> words_from_bytes(const std::vector<uint8_t>& bytes,
                                      size_t byte_count) {
  std::vector<int16_t> words;
  words.reserve((byte_count + 1) / 2);
  for (size_t i = 0; i < byte_count; i += 2) {
    uint16_t lo = bytes.at(i);
    uint16_t hi = (i + 1 < byte_count) ? bytes.at(i + 1) : 0;
    words.push_back(int16_t(lo | (hi << 8)));
  }
  return words;
}

}  // namespace render
