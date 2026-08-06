#ifndef COMMAND_BATCH_H
#define COMMAND_BATCH_H

#include "fpga_spi_transport.h"

#include <stdint.h>

typedef int (*command_batch_send_fn)(void *context, const uint32_t *words,
                                     uint8_t word_count);

typedef struct command_batch {
    uint32_t words[FPGA_SPI_MAX_COMMAND_WORDS];
    uint8_t word_count;
} command_batch;

void command_batch_init(command_batch *batch);
int command_batch_append(command_batch *batch, const uint32_t *words,
                         uint8_t word_count, command_batch_send_fn send,
                         void *context);
int command_batch_flush(command_batch *batch, command_batch_send_fn send,
                        void *context);

#endif
