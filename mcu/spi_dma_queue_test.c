#include "spi_dma_queue.h"

#include <stdio.h>

static int require(int condition, const char *message) {
    if (condition) return 0;
    fprintf(stderr, "%s\n", message);
    return 1;
}

int main(void) {
    spi_dma_queue queue;
    uint8_t frame[FPGA_SPI_MAX_FRAME_BYTES];
    unsigned index;
    spi_dma_queue_init(&queue);
    for (index = 0u; index < SPI_DMA_QUEUE_CAPACITY; ++index) {
        frame[0] = (uint8_t)index;
        if (require(spi_dma_queue_push(&queue, frame, index + 1u),
                    "valid DMA frame was rejected")) return 1;
    }
    if (require(queue.high_water == SPI_DMA_QUEUE_CAPACITY &&
                    !spi_dma_queue_push(&queue, frame, 1u) &&
                    queue.overflow_count == 1u,
                "full DMA frame queue did not report overflow")) return 1;
    for (index = 0u; index < SPI_DMA_QUEUE_CAPACITY; ++index) {
        uint16_t length = 0u;
        const uint8_t *front = spi_dma_queue_front(&queue, &length);
        if (require(front != NULL && front[0] == (uint8_t)index &&
                        length == index + 1u,
                    "DMA frame queue lost FIFO order")) return 1;
        spi_dma_queue_pop(&queue);
    }
    frame[0] = 0xa5u;
    if (require(spi_dma_queue_push(&queue, frame, sizeof(frame)) &&
                    queue.count == 1u,
                "DMA frame queue failed after index wrap")) return 1;
    puts("PASS: SPI DMA frame queue capacity and FIFO order");
    return 0;
}
