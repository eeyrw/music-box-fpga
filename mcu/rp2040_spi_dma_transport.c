#include "rp2040_spi_dma_transport.h"

#include "fpga_spi_transport.h"
#include "spi_dma_queue.h"

#include "hardware/dma.h"
#include "hardware/irq.h"
#include "hardware/spi.h"
#include "hardware/sync.h"
#include "pico/multicore.h"
#include "pico/stdlib.h"

#include <stdatomic.h>

#ifndef APP_ENABLE_DETAILED_DIAGNOSTICS
#define APP_ENABLE_DETAILED_DIAGNOSTICS 0
#endif

#define APP_SPI_ENQUEUE_TIMEOUT_US UINT32_C(100000)

static spi_dma_queue dma_queue;
static int tx_channel = -1;
static int rx_channel = -1;
static dma_channel_config tx_config;
static dma_channel_config rx_config;
static uint8_t rx_sink;
static bool dma_active;
#if APP_ENABLE_DETAILED_DIAGNOSTICS
static uint32_t dma_start_us;
#endif
static _Atomic uint32_t write_transactions;
static _Atomic uint32_t exchange_transactions;
static _Atomic uint32_t transferred_bytes;
static _Atomic uint32_t error_count;
static _Atomic uint32_t enqueue_timeout_count;
static _Atomic uint32_t maximum_dma_us;

#if APP_ENABLE_DETAILED_DIAGNOSTICS
static void update_maximum(_Atomic uint32_t *maximum, uint32_t value) {
    uint32_t observed = atomic_load_explicit(maximum, memory_order_relaxed);
    while (value > observed &&
           !atomic_compare_exchange_weak_explicit(
               maximum, &observed, value, memory_order_relaxed,
               memory_order_relaxed)) {}
}
#endif

static void start_next_frame(void) {
    uint16_t byte_count;
    const uint8_t *bytes = spi_dma_queue_front(&dma_queue, &byte_count);
    if (bytes == NULL) return;
    gpio_put(PICO_DEFAULT_SPI_CSN_PIN, false);
    dma_channel_configure((uint)rx_channel, &rx_config, &rx_sink,
                          &spi_get_hw(spi_default)->dr, byte_count, false);
    dma_channel_configure((uint)tx_channel, &tx_config,
                          &spi_get_hw(spi_default)->dr, bytes, byte_count, false);
#if APP_ENABLE_DETAILED_DIAGNOSTICS
    dma_start_us = time_us_32();
#endif
    dma_active = true;
    dma_start_channel_mask((1u << (uint)tx_channel) | (1u << (uint)rx_channel));
}

static void dma_irq_handler(void) {
    dma_hw->ints1 = 1u << (uint)rx_channel;
    gpio_put(PICO_DEFAULT_SPI_CSN_PIN, true);
#if APP_ENABLE_DETAILED_DIAGNOSTICS
    update_maximum(&maximum_dma_us, time_us_32() - dma_start_us);
#endif
    spi_dma_queue_pop(&dma_queue);
    dma_active = false;
    start_next_frame();
}

void rp2040_spi_bus_init(void) {
    (void)spi_init(spi_default, APP_FPGA_SPI_HZ);
    spi_set_format(spi_default, 8u, SPI_CPOL_0, SPI_CPHA_0, SPI_MSB_FIRST);
    gpio_set_function(PICO_DEFAULT_SPI_SCK_PIN, GPIO_FUNC_SPI);
    gpio_set_function(PICO_DEFAULT_SPI_TX_PIN, GPIO_FUNC_SPI);
    gpio_set_function(PICO_DEFAULT_SPI_RX_PIN, GPIO_FUNC_SPI);
    gpio_init(PICO_DEFAULT_SPI_CSN_PIN);
    gpio_put(PICO_DEFAULT_SPI_CSN_PIN, true);
    gpio_set_dir(PICO_DEFAULT_SPI_CSN_PIN, GPIO_OUT);
}

void rp2040_spi_dma_init(void) {
    spi_dma_queue_init(&dma_queue);
    tx_channel = dma_claim_unused_channel(true);
    rx_channel = dma_claim_unused_channel(true);
    tx_config = dma_channel_get_default_config((uint)tx_channel);
    channel_config_set_transfer_data_size(&tx_config, DMA_SIZE_8);
    channel_config_set_dreq(&tx_config, spi_get_dreq(spi_default, true));
    rx_config = dma_channel_get_default_config((uint)rx_channel);
    channel_config_set_transfer_data_size(&rx_config, DMA_SIZE_8);
    channel_config_set_dreq(&rx_config, spi_get_dreq(spi_default, false));
    channel_config_set_read_increment(&rx_config, false);
    channel_config_set_write_increment(&rx_config, false);
    dma_channel_set_irq1_enabled((uint)rx_channel, true);
    irq_set_exclusive_handler(DMA_IRQ_1, dma_irq_handler);
    irq_set_priority(DMA_IRQ_1, PICO_HIGHEST_IRQ_PRIORITY);
    irq_set_enabled(DMA_IRQ_1, true);
}

int platform_spi_enqueue_mode0_cs0(const uint8_t *bytes, size_t byte_count) {
    const uint32_t start_us = time_us_32();
    if (bytes == NULL || byte_count == 0u ||
        byte_count > FPGA_SPI_MAX_FRAME_BYTES || get_core_num() != 1u) return -1;
    while (true) {
        uint32_t irq_state = save_and_disable_interrupts();
        const bool full = dma_queue.count == SPI_DMA_QUEUE_CAPACITY;
        bool queued = false;
        if (!full) {
            queued = spi_dma_queue_push(&dma_queue, bytes, byte_count);
            if (queued && !dma_active) start_next_frame();
        }
        restore_interrupts(irq_state);
        if (queued) {
            atomic_fetch_add_explicit(&write_transactions, 1u,
                                      memory_order_relaxed);
            atomic_fetch_add_explicit(&transferred_bytes, (uint32_t)byte_count,
                                      memory_order_relaxed);
            return 0;
        }
        if (time_us_32() - start_us >= APP_SPI_ENQUEUE_TIMEOUT_US) {
            atomic_fetch_add_explicit(&enqueue_timeout_count, 1u,
                                      memory_order_relaxed);
            atomic_fetch_add_explicit(&error_count, 1u, memory_order_relaxed);
            return -1;
        }
        tight_loop_contents();
    }
}

int platform_spi_wait_idle(uint32_t timeout_us) {
    const uint32_t start_us = time_us_32();
    while (!rp2040_spi_dma_idle()) {
        if (time_us_32() - start_us >= timeout_us) return -1;
        tight_loop_contents();
    }
    return 0;
}

bool rp2040_spi_dma_idle(void) {
    uint32_t irq_state = save_and_disable_interrupts();
    const bool idle = !dma_active && dma_queue.count == 0u;
    restore_interrupts(irq_state);
    return idle;
}

int platform_spi_write_mode0_cs0(const uint8_t *bytes, size_t byte_count) {
    int written;
    gpio_put(PICO_DEFAULT_SPI_CSN_PIN, false);
    written = spi_write_blocking(spi_default, bytes, byte_count);
    gpio_put(PICO_DEFAULT_SPI_CSN_PIN, true);
    atomic_fetch_add_explicit(&write_transactions, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&transferred_bytes, (uint32_t)byte_count,
                              memory_order_relaxed);
    if (written == (int)byte_count) return 0;
    atomic_fetch_add_explicit(&error_count, 1u, memory_order_relaxed);
    return -1;
}

int platform_spi_exchange_mode0_cs0(const uint8_t *tx_bytes, uint8_t *rx_bytes,
                                     size_t byte_count) {
    int exchanged;
    gpio_put(PICO_DEFAULT_SPI_CSN_PIN, false);
    exchanged = spi_write_read_blocking(spi_default, tx_bytes, rx_bytes,
                                        byte_count);
    gpio_put(PICO_DEFAULT_SPI_CSN_PIN, true);
    atomic_fetch_add_explicit(&exchange_transactions, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&transferred_bytes, (uint32_t)byte_count,
                              memory_order_relaxed);
    if (exchanged == (int)byte_count) return 0;
    atomic_fetch_add_explicit(&error_count, 1u, memory_order_relaxed);
    return -1;
}

void rp2040_spi_get_diagnostics(rp2040_spi_diagnostics *diagnostics) {
    uint32_t irq_state;
    if (diagnostics == NULL) return;
    diagnostics->write_transactions = atomic_load_explicit(
        &write_transactions, memory_order_relaxed);
    diagnostics->exchange_transactions = atomic_load_explicit(
        &exchange_transactions, memory_order_relaxed);
    diagnostics->bytes = atomic_load_explicit(&transferred_bytes,
                                               memory_order_relaxed);
    diagnostics->errors = atomic_load_explicit(&error_count,
                                                memory_order_relaxed);
    diagnostics->enqueue_timeouts = atomic_load_explicit(
        &enqueue_timeout_count, memory_order_relaxed);
    diagnostics->maximum_dma_us = atomic_load_explicit(
        &maximum_dma_us, memory_order_relaxed);
    irq_state = save_and_disable_interrupts();
    diagnostics->queue_depth = dma_queue.count;
    diagnostics->queue_high_water = dma_queue.high_water;
    restore_interrupts(irq_state);
}
