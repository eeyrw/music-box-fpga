#include "command_batch.h"

#include <stddef.h>

void command_batch_init(command_batch *batch) {
    batch->word_count = 0u;
}

int command_batch_flush(command_batch *batch, command_batch_send_fn send,
                        void *context) {
    int result;
    if (batch == NULL || send == NULL) return -1;
    if (batch->word_count == 0u) return 0;
    result = send(context, batch->words, batch->word_count);
    if (result != 0) return result;
    batch->word_count = 0u;
    return 0;
}

int command_batch_append(command_batch *batch, const uint32_t *words,
                         uint8_t word_count, command_batch_send_fn send,
                         void *context) {
    uint8_t index;
    if (batch == NULL || words == NULL || send == NULL || word_count == 0u ||
        word_count > FPGA_SPI_MAX_COMMAND_WORDS ||
        (uint8_t)(words[0] & UINT32_C(0xff)) + 1u != word_count) return -1;
    if ((uint16_t)batch->word_count + word_count > FPGA_SPI_MAX_COMMAND_WORDS &&
        command_batch_flush(batch, send, context) != 0) return -1;
    for (index = 0u; index < word_count; ++index) {
        batch->words[batch->word_count++] = words[index];
    }
    return 0;
}
