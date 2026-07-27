#pragma once

#include <cstdint>

extern "C" {

int ddr3_bin_open(const char* path);
std::uint16_t ddr3_bin_read_word(int handle, std::uint64_t word_address);
std::uint64_t ddr3_bin_word_count(int handle);
void ddr3_bin_close(int handle);

}
