#include "command_batch.h"

#include <stdio.h>

typedef struct capture {
    uint8_t transactions;
    uint8_t counts[3];
    uint32_t words[3][FPGA_SPI_MAX_COMMAND_WORDS];
} capture;

static int capture_send(void *context, const uint32_t *words,
                        uint8_t word_count) {
    capture *output = context;
    uint8_t index;
    if (output->transactions >= 3u) return -1;
    output->counts[output->transactions] = word_count;
    for (index = 0u; index < word_count; ++index) {
        output->words[output->transactions][index] = words[index];
    }
    ++output->transactions;
    return 0;
}

int main(void) {
    command_batch batch;
    capture output = {0};
    uint32_t command[17] = {UINT32_C(0x10000010)};
    uint8_t command_index;
    uint8_t word;
    command_batch_init(&batch);
    for (command_index = 0u; command_index < 5u; ++command_index) {
        command[0] = UINT32_C(0x10000010) | ((uint32_t)command_index << 14);
        for (word = 1u; word < 17u; ++word) {
            command[word] = (uint32_t)command_index << 16 | word;
        }
        if (command_batch_append(&batch, command, 17u, capture_send, &output) != 0) {
            fputs("batch rejected a valid complete command\n", stderr);
            return 1;
        }
    }
    if (command_batch_flush(&batch, capture_send, &output) != 0 ||
        output.transactions != 2u || output.counts[0] != 51u ||
        output.counts[1] != 34u ||
        (output.words[1][0] >> 14 & 0x3ffu) != 3u ||
        (output.words[1][17] >> 14 & 0x3ffu) != 4u) {
        fputs("batch split a command or violated the 63-word boundary\n", stderr);
        return 1;
    }
    puts("PASS: MCU command batching preserves command boundaries");
    return 0;
}
