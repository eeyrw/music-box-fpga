#ifndef SPI_DMA_QUEUE_H
#define SPI_DMA_QUEUE_H

#include "fpga_spi_transport.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SPI_DMA_QUEUE_CAPACITY 16u

typedef struct spi_dma_queue {
    uint8_t frames[SPI_DMA_QUEUE_CAPACITY][FPGA_SPI_MAX_FRAME_BYTES];
    uint16_t lengths[SPI_DMA_QUEUE_CAPACITY];
    uint8_t read_index;
    uint8_t write_index;
    uint8_t count;
    uint8_t high_water;
    uint32_t overflow_count;
} spi_dma_queue;

void spi_dma_queue_init(spi_dma_queue *queue);
bool spi_dma_queue_push(spi_dma_queue *queue, const uint8_t *bytes,
                        size_t byte_count);
const uint8_t *spi_dma_queue_front(const spi_dma_queue *queue,
                                   uint16_t *byte_count);
void spi_dma_queue_pop(spi_dma_queue *queue);

#endif
