#ifndef RP2040_SPI_DMA_TRANSPORT_H
#define RP2040_SPI_DMA_TRANSPORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct rp2040_spi_diagnostics {
    uint32_t write_transactions;
    uint32_t exchange_transactions;
    uint32_t bytes;
    uint32_t errors;
    uint32_t enqueue_timeouts;
    uint32_t maximum_dma_us;
    uint8_t queue_depth;
    uint8_t queue_high_water;
} rp2040_spi_diagnostics;

void rp2040_spi_bus_init(void);
void rp2040_spi_dma_init(void);
bool rp2040_spi_dma_idle(void);
void rp2040_spi_get_diagnostics(rp2040_spi_diagnostics *diagnostics);

int platform_spi_write_mode0_cs0(const uint8_t *bytes, size_t byte_count);
int platform_spi_enqueue_mode0_cs0(const uint8_t *bytes, size_t byte_count);
int platform_spi_exchange_mode0_cs0(const uint8_t *tx_bytes, uint8_t *rx_bytes,
                                     size_t byte_count);
int platform_spi_wait_idle(uint32_t timeout_us);

#endif
