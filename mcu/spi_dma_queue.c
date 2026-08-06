#include "spi_dma_queue.h"

#include <string.h>

void spi_dma_queue_init(spi_dma_queue *queue) {
    *queue = (spi_dma_queue){0};
}

bool spi_dma_queue_push(spi_dma_queue *queue, const uint8_t *bytes,
                        size_t byte_count) {
    if (queue == NULL || bytes == NULL || byte_count == 0u ||
        byte_count > FPGA_SPI_MAX_FRAME_BYTES) return false;
    if (queue->count == SPI_DMA_QUEUE_CAPACITY) {
        ++queue->overflow_count;
        return false;
    }
    memcpy(queue->frames[queue->write_index], bytes, byte_count);
    queue->lengths[queue->write_index] = (uint16_t)byte_count;
    queue->write_index =
        (uint8_t)((queue->write_index + 1u) % SPI_DMA_QUEUE_CAPACITY);
    ++queue->count;
    if (queue->count > queue->high_water) queue->high_water = queue->count;
    return true;
}

const uint8_t *spi_dma_queue_front(const spi_dma_queue *queue,
                                   uint16_t *byte_count) {
    if (queue == NULL || byte_count == NULL || queue->count == 0u) return NULL;
    *byte_count = queue->lengths[queue->read_index];
    return queue->frames[queue->read_index];
}

void spi_dma_queue_pop(spi_dma_queue *queue) {
    if (queue == NULL || queue->count == 0u) return;
    queue->read_index =
        (uint8_t)((queue->read_index + 1u) % SPI_DMA_QUEUE_CAPACITY);
    --queue->count;
}
