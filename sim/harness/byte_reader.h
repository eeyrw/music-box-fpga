#pragma once

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

namespace render {

inline uint16_t read_u16le(const std::vector<uint8_t>& d, size_t p) {
  if (p + 2 > d.size()) throw std::runtime_error("truncated u16le");
  return uint16_t(d[p]) | (uint16_t(d[p + 1]) << 8);
}

inline uint32_t read_u32le(const std::vector<uint8_t>& d, size_t p) {
  if (p + 4 > d.size()) throw std::runtime_error("truncated u32le");
  return uint32_t(d[p]) | (uint32_t(d[p + 1]) << 8) |
         (uint32_t(d[p + 2]) << 16) | (uint32_t(d[p + 3]) << 24);
}

inline uint16_t read_u16be(const std::vector<uint8_t>& d, size_t p) {
  if (p + 2 > d.size()) throw std::runtime_error("truncated u16be");
  return (uint16_t(d[p]) << 8) | uint16_t(d[p + 1]);
}

inline uint32_t read_u32be(const std::vector<uint8_t>& d, size_t p) {
  if (p + 4 > d.size()) throw std::runtime_error("truncated u32be");
  return (uint32_t(d[p]) << 24) | (uint32_t(d[p + 1]) << 16) |
         (uint32_t(d[p + 2]) << 8) | uint32_t(d[p + 3]);
}

inline std::vector<uint8_t> read_file(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error("failed to open " + path);
  return std::vector<uint8_t>(std::istreambuf_iterator<char>(f),
                              std::istreambuf_iterator<char>());
}

inline std::vector<uint8_t> slice(const std::vector<uint8_t>& d, size_t p, size_t n) {
  if (p + n > d.size()) throw std::runtime_error("truncated chunk");
  return std::vector<uint8_t>(d.begin() + p, d.begin() + p + n);
}

inline std::string clean_name(const std::vector<uint8_t>& d, size_t p, size_t n) {
  std::string s;
  for (size_t i = 0; i < n && p + i < d.size() && d[p + i] != 0; ++i) {
    s.push_back(char(d[p + i]));
  }
  while (!s.empty() && s.back() == ' ') s.pop_back();
  return s;
}

}  // namespace render
