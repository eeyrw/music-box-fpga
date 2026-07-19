#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace render {

std::vector<uint8_t> read_file_bytes(const std::string& path);
std::vector<uint8_t> make_raw_sd_image(const std::vector<uint8_t>& sf2_bytes,
                                       uint64_t sf2_start_lba);
std::vector<int16_t> words_from_bytes(const std::vector<uint8_t>& bytes,
                                      size_t byte_count);

}  // namespace render
