#include "fpga_spi_transport.h"

#include <stddef.h>
#include <stdint.h>

static uint16_t crc16_byte(uint16_t crc, uint8_t byte) {
    uint8_t bit;
    crc ^= (uint16_t)byte << 8;
    for (bit = 0u; bit < 8u; ++bit) {
        crc = (crc & UINT16_C(0x8000)) != 0u
                  ? (uint16_t)((uint16_t)(crc << 1) ^ UINT16_C(0x1021))
                  : (uint16_t)(crc << 1);
    }
    return crc;
}

static uint32_t crc32_bytes(const uint8_t *bytes, size_t size) {
    uint32_t crc = UINT32_C(0xffffffff);
    size_t index;
    for (index = 0u; index < size; ++index) {
        uint8_t bit;
        crc ^= bytes[index];
        for (bit = 0u; bit < 8u; ++bit) {
            crc = (crc & 1u) != 0u
                      ? (crc >> 1) ^ UINT32_C(0xedb88320)
                      : crc >> 1;
        }
    }
    return crc ^ UINT32_C(0xffffffff);
}

static uint32_t read_be32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) | bytes[3];
}

static void write_be32(uint8_t *bytes, uint32_t value) {
    bytes[0] = (uint8_t)(value >> 24);
    bytes[1] = (uint8_t)(value >> 16);
    bytes[2] = (uint8_t)(value >> 8);
    bytes[3] = (uint8_t)value;
}

int fpga_spi_send_commands(fpga_spi_write_fn write, void *context,
                           const uint32_t *words, uint8_t word_count) {
    uint8_t frame[FPGA_SPI_MAX_FRAME_BYTES];
    uint16_t crc = UINT16_C(0xffff);
    size_t frame_index = 4u;
    uint8_t word_index;
    uint8_t command_index;

    if (write == NULL || words == NULL || word_count == 0u ||
        word_count > FPGA_SPI_MAX_COMMAND_WORDS) {
        return -1;
    }
    command_index = 0u;
    while (command_index < word_count) {
        uint8_t payload_words = (uint8_t)words[command_index];
        uint8_t remaining = (uint8_t)(word_count - command_index - 1u);
        if (payload_words > remaining) return -1;
        command_index = (uint8_t)(command_index + payload_words + 1u);
    }

    crc = crc16_byte(crc, word_count);
    for (word_index = 0u; word_index < word_count; ++word_index) {
        uint32_t word = words[word_index];
        uint8_t shift;
        for (shift = 24u;; shift = (uint8_t)(shift - 8u)) {
            uint8_t byte = (uint8_t)(word >> shift);
            frame[frame_index++] = byte;
            crc = crc16_byte(crc, byte);
            if (shift == 0u) break;
        }
    }

    frame[0] = UINT8_C(0xa5);
    frame[1] = word_count;
    frame[2] = (uint8_t)(crc >> 8);
    frame[3] = (uint8_t)crc;
    return write(context, frame, frame_index);
}

int fpga_spi_flush(fpga_spi_write_fn write, void *context) {
    static const uint8_t frame[4] = {UINT8_C(0xa6), 0u, UINT8_C(0xaa),
                                     UINT8_C(0xd7)};
    if (write == NULL) return -1;
    return write(context, frame, sizeof(frame));
}

int fpga_spi_reset_session(fpga_spi_write_fn write,
                           fpga_spi_exchange_fn exchange, void *context,
                           uint16_t epoch_address, uint32_t *new_epoch,
                           unsigned poll_limit, unsigned fetch_limit) {
    static const uint8_t frame[4] = {UINT8_C(0xa7), 0u, UINT8_C(0x99),
                                     UINT8_C(0xe6)};
    uint32_t previous_epoch;
    unsigned attempt;

    if (write == NULL || exchange == NULL || new_epoch == NULL ||
        poll_limit == 0u || fetch_limit == 0u) {
        return -1;
    }
    if (fpga_spi_read_register(write, exchange, context, epoch_address,
                               &previous_epoch, fetch_limit) != 0) {
        return -1;
    }
    if (write(context, frame, sizeof(frame)) != 0) return -1;
    for (attempt = 0u; attempt < poll_limit; ++attempt) {
        uint32_t observed_epoch;
        if (fpga_spi_read_register(write, exchange, context, epoch_address,
                                   &observed_epoch, fetch_limit) == 0 &&
            observed_epoch != previous_epoch) {
            *new_epoch = observed_epoch;
            return 0;
        }
    }
    return -1;
}

int fpga_spi_read_register(fpga_spi_write_fn write,
                           fpga_spi_exchange_fn exchange, void *context,
                           uint16_t address, uint32_t *data,
                           unsigned fetch_limit) {
    uint8_t request[12] = {UINT8_C(0x5a), 0u, (uint8_t)(address >> 8),
                           (uint8_t)address, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u};
    uint8_t tx[16] = {UINT8_C(0x5b)};
    uint8_t rx[16];
    uint32_t crc;
    unsigned attempt;

    if (write == NULL || exchange == NULL || data == NULL || fetch_limit == 0u) {
        return -1;
    }
    crc = crc32_bytes(request, 8u);
    request[8] = (uint8_t)(crc >> 24);
    request[9] = (uint8_t)(crc >> 16);
    request[10] = (uint8_t)(crc >> 8);
    request[11] = (uint8_t)crc;
    if (write(context, request, sizeof(request)) != 0) return -1;

    for (attempt = 0u; attempt < fetch_limit; ++attempt) {
        if (exchange(context, tx, rx, sizeof(tx)) != 0) return -1;
        if (read_be32(rx + 12u) != crc32_bytes(rx + 4u, 8u)) continue;
        if (rx[4] == 2u) continue;
        if (rx[4] != 0u || rx[5] != 0u || rx[6] != (uint8_t)(address >> 8) ||
            rx[7] != (uint8_t)address) {
            return -1;
        }
        *data = read_be32(rx + 8u);
        return 0;
    }
    return -1;
}

int fpga_spi_write_register(fpga_spi_write_fn write,
                            fpga_spi_exchange_fn exchange, void *context,
                            uint16_t address, uint32_t data,
                            unsigned fetch_limit) {
    uint8_t request[12] = {UINT8_C(0x5a), UINT8_C(0x01),
                           (uint8_t)(address >> 8), (uint8_t)address};
    uint8_t tx[16] = {UINT8_C(0x5b)};
    uint8_t rx[16];
    uint32_t crc;
    unsigned attempt;

    if (write == NULL || exchange == NULL || fetch_limit == 0u) return -1;
    write_be32(request + 4u, data);
    crc = crc32_bytes(request, 8u);
    write_be32(request + 8u, crc);
    if (write(context, request, sizeof(request)) != 0) return -1;

    for (attempt = 0u; attempt < fetch_limit; ++attempt) {
        if (exchange(context, tx, rx, sizeof(tx)) != 0) return -1;
        if (read_be32(rx + 12u) != crc32_bytes(rx + 4u, 8u)) continue;
        if (rx[4] == 2u) continue;
        if (rx[4] != 0u || rx[5] != 1u || rx[6] != (uint8_t)(address >> 8) ||
            rx[7] != (uint8_t)address || read_be32(rx + 8u) != 0u) {
            return -1;
        }
        return 0;
    }
    return -1;
}
