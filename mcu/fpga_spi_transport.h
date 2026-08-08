#ifndef FPGA_SPI_TRANSPORT_H
#define FPGA_SPI_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

#define FPGA_SPI_MAX_COMMAND_WORDS 63u
#define FPGA_SPI_MAX_FRAME_BYTES (4u + 4u * FPGA_SPI_MAX_COMMAND_WORDS)
#define FPGA_SPI_COMPLETION_ITEMS 16u
#define FPGA_SPI_COMPLETION_FRAME_BYTES 93u

typedef struct fpga_spi_completion_item {
    uint16_t generation;
    uint16_t voice;
    uint8_t reason;
} fpga_spi_completion_item;

typedef struct fpga_spi_completion_batch {
    uint32_t session_epoch;
    uint16_t write_sequence;
    uint16_t start_sequence;
    uint8_t count;
    uint8_t overflow;
    fpga_spi_completion_item items[FPGA_SPI_COMPLETION_ITEMS];
} fpga_spi_completion_batch;

typedef int (*fpga_spi_write_fn)(void *context, const uint8_t *bytes,
                                 size_t byte_count);
typedef int (*fpga_spi_exchange_fn)(void *context, const uint8_t *tx_bytes,
                                    uint8_t *rx_bytes, size_t byte_count);

int fpga_spi_send_commands(fpga_spi_write_fn write, void *context,
                           const uint32_t *words, uint8_t word_count);
int fpga_spi_flush(fpga_spi_write_fn write, void *context);
int fpga_spi_reset_session(fpga_spi_write_fn write,
                           fpga_spi_exchange_fn exchange, void *context,
                           uint16_t epoch_address, uint32_t *new_epoch,
                           unsigned poll_limit, unsigned fetch_limit);
int fpga_spi_read_register(fpga_spi_write_fn write,
                           fpga_spi_exchange_fn exchange, void *context,
                           uint16_t address, uint32_t *data,
                           unsigned fetch_limit);
int fpga_spi_write_register(fpga_spi_write_fn write,
                            fpga_spi_exchange_fn exchange, void *context,
                            uint16_t address, uint32_t data,
                            unsigned fetch_limit);
int fpga_spi_read_completions(fpga_spi_exchange_fn exchange, void *context,
                              uint16_t sequence,
                              fpga_spi_completion_batch *batch);
int fpga_spi_read_completions_retry(fpga_spi_exchange_fn exchange,
                                    void *context, uint16_t sequence,
                                    fpga_spi_completion_batch *batch,
                                    unsigned attempt_limit,
                                    unsigned *failed_attempts);

#endif
