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
    capture session_reset;
    uint16_t address;
    uint32_t data;
    unsigned exchanges;
    int malformed_fetch;
    uint8_t response_operation;
    uint32_t epoch_after_reset;
    int hold_epoch;
} mailbox_capture;

typedef struct completion_capture {
    uint8_t request[FPGA_SPI_COMPLETION_FRAME_BYTES];
    unsigned corrupt_responses;
    unsigned exchanges;
    int empty_overflow;
} completion_capture;

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
    if (byte_count == 4u && bytes[0] == UINT8_C(0xa7)) {
        int result = capture_write(&mailbox->session_reset, bytes, byte_count);
        if (result == 0 && mailbox->hold_epoch == 0) {
            mailbox->data = mailbox->epoch_after_reset;
        }
        return result;
    }
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

static int completion_exchange(void *context, const uint8_t *tx, uint8_t *rx,
                               size_t byte_count) {
    completion_capture *capture = context;
    const uint16_t start_sequence = (uint16_t)((uint16_t)tx[1] << 8 | tx[2]);
    const uint32_t first_item = UINT32_C(0x12340280);
    const uint32_t second_item = UINT32_C(0xbeefffa0);
    uint32_t crc;
    if (byte_count != FPGA_SPI_COMPLETION_FRAME_BYTES) return -1;
    ++capture->exchanges;
    memcpy(capture->request, tx, byte_count);
    memset(rx, 0, byte_count);
    rx[13] = 0u;
    rx[14] = 1u;
    rx[15] = capture->empty_overflow != 0 ? 1u : 0u;
    rx[16] = capture->empty_overflow != 0 ? 0u : 2u;
    rx[17] = 0x12u;
    rx[18] = 0x34u;
    rx[19] = 0x56u;
    rx[20] = 0x78u;
    rx[21] = (uint8_t)((start_sequence +
                        (capture->empty_overflow != 0 ? 0u : 2u)) >> 8);
    rx[22] = (uint8_t)(start_sequence +
                       (capture->empty_overflow != 0 ? 0u : 2u));
    rx[23] = (uint8_t)(start_sequence >> 8);
    rx[24] = (uint8_t)start_sequence;
    if (capture->empty_overflow == 0) {
        rx[25] = (uint8_t)(first_item >> 24);
        rx[26] = (uint8_t)(first_item >> 16);
        rx[27] = (uint8_t)(first_item >> 8);
        rx[28] = (uint8_t)first_item;
        rx[29] = (uint8_t)(second_item >> 24);
        rx[30] = (uint8_t)(second_item >> 16);
        rx[31] = (uint8_t)(second_item >> 8);
        rx[32] = (uint8_t)second_item;
    }
    crc = reference_crc32(rx + 13u, 76u);
    rx[89] = (uint8_t)(crc >> 24);
    rx[90] = (uint8_t)(crc >> 16);
    rx[91] = (uint8_t)(crc >> 8);
    rx[92] = (uint8_t)crc;
    if (capture->corrupt_responses != 0u) {
        --capture->corrupt_responses;
        ++rx[92];
    }
    return 0;
}

int main(void) {
    static const uint32_t words[2] = {UINT32_C(0x10000001),
                                      UINT32_C(0x12345678)};
    static const uint8_t payload[9] = {2u, 0x10u, 0u, 0u, 1u,
                                       0x12u, 0x34u, 0x56u, 0x78u};
    static const uint8_t flush[4] = {0xa6u, 0u, 0xaau, 0xd7u};
    static const uint8_t session_reset[4] = {0xa7u, 0u, 0x99u, 0xe6u};
    static const uint32_t malformed[2] = {UINT32_C(0x10000002), 0u};
    capture output = {{0}, 0u, 0u};
    mailbox_capture mailbox = {{{0}, 0u, 0u}, {{0}, 0u, 0u},
                               UINT16_C(0x9050), UINT32_C(0x12345678),
                               0u, 0, 0u, 0u, 0};
    uint16_t crc;
    uint32_t register_data;
    uint32_t session_epoch;
    completion_capture completion = {{0}, 0u, 0u, 0};
    fpga_spi_completion_batch batch;
    unsigned failed_completion_attempts;

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
    mailbox.address = UINT16_C(0x9098);
    mailbox.data = UINT32_C(7);
    mailbox.epoch_after_reset = UINT32_C(8);
    mailbox.exchanges = 0u;
    mailbox.malformed_fetch = 0;
    mailbox.response_operation = 0u;
    if (fpga_spi_reset_session(mailbox_write, mailbox_exchange, &mailbox,
                               mailbox.address, &session_epoch, 3u, 3u) != 0 ||
        session_epoch != UINT32_C(8) || mailbox.session_reset.writes != 1u ||
        mailbox.session_reset.size != sizeof(session_reset) ||
        memcmp(mailbox.session_reset.bytes, session_reset,
               sizeof(session_reset)) != 0) {
        fputs("SPI render-session reset acknowledgement failed\n", stderr);
        return 1;
    }
    mailbox.data = UINT32_C(8);
    mailbox.epoch_after_reset = UINT32_C(9);
    mailbox.hold_epoch = 1;
    mailbox.exchanges = 0u;
    if (fpga_spi_reset_session(mailbox_write, mailbox_exchange, &mailbox,
                               mailbox.address, &session_epoch, 2u, 2u) == 0) {
        fputs("SPI render-session reset accepted unchanged epoch\n", stderr);
        return 1;
    }
    mailbox.hold_epoch = 0;
    mailbox.address = UINT16_C(0x9050);
    mailbox.data = UINT32_C(0x12345678);
    mailbox.exchanges = 0u;
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
    if (fpga_spi_read_completions(completion_exchange, &completion,
                                  UINT16_C(0x3456), &batch) != 0 ||
        completion.request[0] != 0x5du || completion.request[1] != 0x34u ||
        completion.request[2] != 0x56u ||
        ((uint16_t)completion.request[3] << 8 | completion.request[4]) !=
            reference_crc(completion.request, 3u) ||
        memcmp(completion.request + 5u,
               (uint8_t[FPGA_SPI_COMPLETION_FRAME_BYTES - 5u]){0},
               FPGA_SPI_COMPLETION_FRAME_BYTES - 5u) != 0 ||
        batch.session_epoch != UINT32_C(0x12345678) || batch.count != 2u ||
        batch.start_sequence != UINT16_C(0x3456) ||
        batch.write_sequence != UINT16_C(0x3458) || batch.overflow != 0u ||
        batch.items[0].generation != UINT16_C(0x1234) ||
        batch.items[0].voice != 5u || batch.items[0].reason != 0u ||
        batch.items[1].generation != UINT16_C(0xbeef) ||
        batch.items[1].voice != 511u || batch.items[1].reason != 2u) {
        fputs("SPI completion log read failed\n", stderr);
        return 1;
    }
    completion.corrupt_responses = 1u;
    if (fpga_spi_read_completions(completion_exchange, &completion,
                                  UINT16_C(0x3456), &batch) == 0) {
        fputs("SPI completion log accepted corrupt response CRC\n", stderr);
        return 1;
    }
    completion.corrupt_responses = 2u;
    completion.exchanges = 0u;
    if (fpga_spi_read_completions_retry(
            completion_exchange, &completion, UINT16_C(0x3456), &batch, 3u,
            &failed_completion_attempts) != 0 ||
        failed_completion_attempts != 2u || completion.exchanges != 3u ||
        batch.session_epoch != UINT32_C(0x12345678)) {
        fputs("SPI completion log did not recover after transient bad frames\n",
              stderr);
        return 1;
    }
    completion.corrupt_responses = 3u;
    completion.exchanges = 0u;
    if (fpga_spi_read_completions_retry(
            completion_exchange, &completion, UINT16_C(0x3456), &batch, 3u,
            &failed_completion_attempts) == 0 ||
        failed_completion_attempts != 3u || completion.exchanges != 3u) {
        fputs("SPI completion log accepted exhausted retries\n", stderr);
        return 1;
    }
    completion.corrupt_responses = 0u;
    completion.empty_overflow = 1;
    if (fpga_spi_read_completions(completion_exchange, &completion,
                                  UINT16_C(0x3456), &batch) != 0 ||
        batch.overflow != 1u || batch.count != 0u ||
        batch.start_sequence != UINT16_C(0x3456) ||
        batch.write_sequence != UINT16_C(0x3456)) {
        fputs("SPI completion log rejected empty overflow state\n", stderr);
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
    mailbox.exchanges = 0u;
    mailbox.malformed_fetch = 0;
    if (fpga_spi_read_register(mailbox_write, mailbox_exchange, &mailbox,
                               mailbox.address, &register_data, 2u) == 0) {
        fputs("SPI register mailbox accepted wrong response operation\n",
              stderr);
        return 1;
    }
    if (fpga_spi_read_register(NULL, mailbox_exchange, &mailbox,
                               mailbox.address, &register_data, 2u) == 0 ||
        fpga_spi_read_register(mailbox_write, NULL, &mailbox,
                               mailbox.address, &register_data, 2u) == 0 ||
        fpga_spi_read_register(mailbox_write, mailbox_exchange, &mailbox,
                               mailbox.address, NULL, 2u) == 0 ||
        fpga_spi_read_register(mailbox_write, mailbox_exchange, &mailbox,
                               mailbox.address, &register_data, 0u) == 0 ||
        fpga_spi_write_register(NULL, mailbox_exchange, &mailbox,
                                mailbox.address, 0u, 2u) == 0 ||
        fpga_spi_write_register(mailbox_write, NULL, &mailbox,
                                mailbox.address, 0u, 2u) == 0 ||
        fpga_spi_write_register(mailbox_write, mailbox_exchange, &mailbox,
                                mailbox.address, 0u, 0u) == 0) {
        fputs("SPI register mailbox accepted invalid arguments\n", stderr);
        return 1;
    }
    puts("PASS: FPGA SPI command, completion, reset, and mailbox transport");
    return 0;
}
