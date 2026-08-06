#include "fpga_spi_transport.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct capture {
    uint8_t bytes[FPGA_SPI_MAX_FRAME_BYTES];
    size_t size;
    unsigned writes;
} capture;

typedef struct mailbox_capture {
    capture request;
    uint16_t address;
    uint32_t data;
    unsigned exchanges;
    int malformed_fetch;
    uint8_t response_operation;
} mailbox_capture;

static int capture_write(void *context, const uint8_t *bytes, size_t byte_count) {
    capture *output = context;
    if (byte_count > sizeof(output->bytes)) return -1;
    memcpy(output->bytes, bytes, byte_count);
    output->size = byte_count;
    ++output->writes;
    return 0;
}

static uint16_t reference_crc(const uint8_t *bytes, size_t size) {
    uint16_t crc = UINT16_C(0xffff);
    size_t index;
    for (index = 0u; index < size; ++index) {
        unsigned bit;
        crc ^= (uint16_t)bytes[index] << 8;
        for (bit = 0u; bit < 8u; ++bit) {
            crc = (crc & UINT16_C(0x8000)) != 0u
                      ? (uint16_t)((crc << 1) ^ UINT16_C(0x1021))
                      : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

static uint32_t reference_crc32(const uint8_t *bytes, size_t size) {
    uint32_t crc = UINT32_C(0xffffffff);
    size_t index;
    for (index = 0u; index < size; ++index) {
        unsigned bit;
        crc ^= bytes[index];
        for (bit = 0u; bit < 8u; ++bit) {
            crc = (crc & 1u) != 0u
                      ? (crc >> 1) ^ UINT32_C(0xedb88320)
                      : crc >> 1;
        }
    }
    return crc ^ UINT32_C(0xffffffff);
}

static int mailbox_write(void *context, const uint8_t *bytes,
                         size_t byte_count) {
    mailbox_capture *mailbox = context;
    return capture_write(&mailbox->request, bytes, byte_count);
}

static int mailbox_exchange(void *context, const uint8_t *tx, uint8_t *rx,
                            size_t byte_count) {
    mailbox_capture *mailbox = context;
    uint32_t crc;
    if (byte_count != 16u || tx[0] != 0x5bu) return -1;
    memset(rx, 0, byte_count);
    rx[4] = mailbox->exchanges++ == 0u ? 2u : 0u;
    rx[5] = mailbox->response_operation;
    rx[6] = (uint8_t)(mailbox->address >> 8);
    rx[7] = (uint8_t)mailbox->address;
    if (rx[4] == 0u) {
        rx[8] = (uint8_t)(mailbox->data >> 24);
        rx[9] = (uint8_t)(mailbox->data >> 16);
        rx[10] = (uint8_t)(mailbox->data >> 8);
        rx[11] = (uint8_t)mailbox->data;
    }
    crc = reference_crc32(rx + 4u, 8u);
    rx[12] = (uint8_t)(crc >> 24);
    rx[13] = (uint8_t)(crc >> 16);
    rx[14] = (uint8_t)(crc >> 8);
    rx[15] = (uint8_t)crc;
    if (mailbox->malformed_fetch != 0) ++rx[15];
    return 0;
}

int main(void) {
    static const uint32_t words[2] = {UINT32_C(0x10000001),
                                      UINT32_C(0x12345678)};
    static const uint8_t payload[9] = {2u, 0x10u, 0u, 0u, 1u,
                                       0x12u, 0x34u, 0x56u, 0x78u};
    static const uint8_t flush[4] = {0xa6u, 0u, 0xaau, 0xd7u};
    static const uint32_t malformed[2] = {UINT32_C(0x10000002), 0u};
    capture output = {{0}, 0u, 0u};
    mailbox_capture mailbox = {{{0}, 0u, 0u}, UINT16_C(0x9050),
                               UINT32_C(0x12345678), 0u, 0, 0u};
    uint16_t crc;
    uint32_t register_data;

    if (fpga_spi_send_commands(capture_write, &output, words, 2u) != 0 ||
        output.writes != 1u || output.size != 12u || output.bytes[0] != 0xa5u ||
        memcmp(output.bytes + 4u, payload + 1u, 8u) != 0) {
        fputs("SPI command frame layout mismatch\n", stderr);
        return 1;
    }
    crc = reference_crc(payload, sizeof(payload));
    if (output.bytes[1] != 2u || output.bytes[2] != (uint8_t)(crc >> 8) ||
        output.bytes[3] != (uint8_t)crc) {
        fputs("SPI command CRC mismatch\n", stderr);
        return 1;
    }
    if (fpga_spi_flush(capture_write, &output) != 0 || output.size != 4u ||
        memcmp(output.bytes, flush, sizeof(flush)) != 0) {
        fputs("SPI FLUSH frame mismatch\n", stderr);
        return 1;
    }
    if (fpga_spi_send_commands(capture_write, &output, words, 0u) == 0 ||
        fpga_spi_send_commands(NULL, &output, words, 2u) == 0 ||
        fpga_spi_send_commands(capture_write, &output, malformed, 2u) == 0) {
        fputs("SPI transport accepted invalid arguments\n", stderr);
        return 1;
    }
    if (fpga_spi_read_register(mailbox_write, mailbox_exchange, &mailbox,
                               mailbox.address, &register_data, 3u) != 0 ||
        register_data != mailbox.data || mailbox.exchanges != 2u ||
        mailbox.request.size != 12u || mailbox.request.bytes[0] != 0x5au ||
        mailbox.request.bytes[1] != 0u || mailbox.request.bytes[2] != 0x90u ||
        mailbox.request.bytes[3] != 0x50u ||
        reference_crc32(mailbox.request.bytes, 8u) !=
            ((uint32_t)mailbox.request.bytes[8] << 24 |
             (uint32_t)mailbox.request.bytes[9] << 16 |
             (uint32_t)mailbox.request.bytes[10] << 8 |
             mailbox.request.bytes[11])) {
        fputs("SPI register mailbox read failed\n", stderr);
        return 1;
    }
    mailbox.exchanges = 0u;
    mailbox.malformed_fetch = 0;
    mailbox.response_operation = 1u;
    mailbox.address = UINT16_C(0x9068);
    mailbox.data = 0u;
    if (fpga_spi_write_register(mailbox_write, mailbox_exchange, &mailbox,
                                UINT16_C(0x9068), UINT32_C(0x12345670), 3u) != 0 ||
        mailbox.exchanges != 2u || mailbox.request.size != 12u ||
        mailbox.request.bytes[0] != 0x5au || mailbox.request.bytes[1] != 1u ||
        mailbox.request.bytes[2] != 0x90u || mailbox.request.bytes[3] != 0x68u ||
        mailbox.request.bytes[4] != 0x12u || mailbox.request.bytes[5] != 0x34u ||
        mailbox.request.bytes[6] != 0x56u || mailbox.request.bytes[7] != 0x70u ||
        reference_crc32(mailbox.request.bytes, 8u) !=
            ((uint32_t)mailbox.request.bytes[8] << 24 |
             (uint32_t)mailbox.request.bytes[9] << 16 |
             (uint32_t)mailbox.request.bytes[10] << 8 |
             mailbox.request.bytes[11])) {
        fputs("SPI register mailbox write failed\n", stderr);
        return 1;
    }
    mailbox.exchanges = 0u;
    mailbox.malformed_fetch = 1;
    if (fpga_spi_read_register(mailbox_write, mailbox_exchange, &mailbox,
                               mailbox.address, &register_data, 2u) == 0) {
        fputs("SPI register mailbox accepted corrupt response CRC\n", stderr);
        return 1;
    }
    puts("PASS: FPGA SPI command, FLUSH, and register mailbox transport");
    return 0;
}
