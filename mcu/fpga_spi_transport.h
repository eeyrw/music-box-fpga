#ifndef FPGA_SPI_TRANSPORT_H
#define FPGA_SPI_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>

#define FPGA_SPI_MAX_COMMAND_WORDS 63u
#define FPGA_SPI_MAX_FRAME_BYTES (4u + 4u * FPGA_SPI_MAX_COMMAND_WORDS)
#define FPGA_SPI_VOICE_STATUS_WORDS 16u
#define FPGA_SPI_VOICE_STATUS_FRAME_BYTES 88u

typedef struct fpga_spi_voice_status {
    uint32_t session_epoch;
    uint32_t active_bitmap[FPGA_SPI_VOICE_STATUS_WORDS];
} fpga_spi_voice_status;

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
int fpga_spi_read_voice_status(fpga_spi_exchange_fn exchange, void *context,
                               fpga_spi_voice_status *status);

#endif
