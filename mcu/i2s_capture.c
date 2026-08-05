#include "i2s_capture.h"

#include "hardware/dma.h"
#include "hardware/irq.h"
#include "hardware/pio.h"
#include "hardware/pio_instructions.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"

#define I2S_RING_FRAME_COUNT 2048u
#define I2S_RING_BYTE_BITS 13u

static uint32_t capture_ring[I2S_RING_FRAME_COUNT]
    __attribute__((aligned(1u << I2S_RING_BYTE_BITS)));
static int capture_dma_channel;
static volatile uint32_t capture_completed_count;
static uint32_t capture_read_count;
static uint32_t capture_activity_count;
static absolute_time_t capture_last_activity;

_Static_assert((I2S_RING_FRAME_COUNT & (I2S_RING_FRAME_COUNT - 1u)) == 0u,
               "I2S DMA ring frame count must be a power of two");
_Static_assert(I2S_RING_FRAME_COUNT * sizeof(capture_ring[0]) ==
                   (1u << I2S_RING_BYTE_BITS),
               "I2S DMA ring size and address-wrap bits disagree");
_Static_assert(APP_I2S_BCLK_PIN <= 29u && APP_I2S_LRCLK_PIN <= 29u &&
                   APP_I2S_DATA_PIN <= 29u,
               "I2S pins must be RP2040 GPIOs");
_Static_assert(APP_I2S_BCLK_PIN != APP_I2S_LRCLK_PIN &&
                   APP_I2S_BCLK_PIN != APP_I2S_DATA_PIN &&
                   APP_I2S_LRCLK_PIN != APP_I2S_DATA_PIN,
               "I2S pins must be distinct");

static uint32_t capture_write_count(void) {
    uint32_t completed;
    uint32_t remaining;
    const uint32_t irq_state = save_and_disable_interrupts();
    completed = capture_completed_count;
    remaining = dma_hw->ch[capture_dma_channel].transfer_count;
    restore_interrupts(irq_state);
    return completed + I2S_RING_FRAME_COUNT - remaining;
}

static void __isr i2s_capture_dma_irq(void) {
    /* A bounded 2048-frame transfer avoids the RP2040 DMA channel eventually
     * stopping when a single 32-bit TRANS_COUNT expires. The ring wraps the
     * write address back to capture_ring; the RX FIFO holds up to eight frames
     * while this highest-priority handler reloads and triggers the next block. */
    dma_hw->ints0 = 1u << capture_dma_channel;
    capture_completed_count += I2S_RING_FRAME_COUNT;
    dma_channel_set_trans_count(capture_dma_channel, I2S_RING_FRAME_COUNT,
                                true);
}

void i2s_capture_init(void) {
    static uint16_t instructions[10];
    const pio_program_t program = {
        .instructions = instructions,
        .length = 10,
        .origin = 0,
        .pio_version = 0,
    };
    PIO pio = pio0;
    uint state_machine;
    uint offset;
    pio_sm_config config;
    dma_channel_config dma_config;

    /* Philips I2S changes LRCLK on a falling BCLK edge, one bit clock before
     * the next channel MSB. Synchronize on the right-to-left transition, skip
     * that one-bit delay, then sample 32 bits on rising BCLK edges. With shift
     * left, the FIFO word is left[15:0] in bits 31:16 and right[15:0] in 15:0. */
    instructions[0] = pio_encode_wait_gpio(true, APP_I2S_LRCLK_PIN);
    instructions[1] = pio_encode_wait_gpio(false, APP_I2S_LRCLK_PIN);
    instructions[2] = pio_encode_wait_gpio(true, APP_I2S_BCLK_PIN);
    instructions[3] = pio_encode_wait_gpio(false, APP_I2S_BCLK_PIN);
    instructions[4] = pio_encode_set(pio_x, 31u);
    instructions[5] = pio_encode_wait_gpio(true, APP_I2S_BCLK_PIN);
    instructions[6] = pio_encode_in(pio_pins, 1u);
    instructions[7] = pio_encode_wait_gpio(false, APP_I2S_BCLK_PIN);
    instructions[8] = pio_encode_jmp_x_dec(5u);
    instructions[9] = pio_encode_push(false, true);

    gpio_init(APP_I2S_BCLK_PIN);
    gpio_init(APP_I2S_LRCLK_PIN);
    gpio_init(APP_I2S_DATA_PIN);
    gpio_set_dir(APP_I2S_BCLK_PIN, GPIO_IN);
    gpio_set_dir(APP_I2S_LRCLK_PIN, GPIO_IN);
    gpio_set_dir(APP_I2S_DATA_PIN, GPIO_IN);

    state_machine = pio_claim_unused_sm(pio, true);
    offset = pio_add_program_at_offset(pio, &program, 0u);
    config = pio_get_default_sm_config();
    sm_config_set_wrap(&config, offset, offset + 9u);
    sm_config_set_in_pins(&config, APP_I2S_DATA_PIN);
    sm_config_set_in_shift(&config, false, false, 32u);
    sm_config_set_fifo_join(&config, PIO_FIFO_JOIN_RX);
    pio_sm_init(pio, state_machine, offset, &config);
    pio_sm_set_enabled(pio, state_machine, true);

    capture_dma_channel = dma_claim_unused_channel(true);
    dma_config = dma_channel_get_default_config(capture_dma_channel);
    channel_config_set_transfer_data_size(&dma_config, DMA_SIZE_32);
    channel_config_set_read_increment(&dma_config, false);
    channel_config_set_write_increment(&dma_config, true);
    channel_config_set_ring(&dma_config, true, I2S_RING_BYTE_BITS);
    channel_config_set_dreq(&dma_config, pio_get_dreq(pio, state_machine, false));
    dma_channel_set_irq0_enabled(capture_dma_channel, true);
    irq_set_exclusive_handler(DMA_IRQ_0, i2s_capture_dma_irq);
    irq_set_priority(DMA_IRQ_0, PICO_HIGHEST_IRQ_PRIORITY);
    irq_set_enabled(DMA_IRQ_0, true);
    dma_channel_configure(capture_dma_channel, &dma_config, capture_ring,
                          &pio->rxf[state_machine], I2S_RING_FRAME_COUNT, true);
}

size_t i2s_capture_available(void) {
    uint32_t available = capture_write_count() - capture_read_count;
    /* The producer is allowed to lap the consumer. Retain the newest 2048
     * stereo frames, because DMA has already overwritten anything older. */
    if (available > I2S_RING_FRAME_COUNT) {
        capture_read_count += available - I2S_RING_FRAME_COUNT;
        return I2S_RING_FRAME_COUNT;
    }
    return (size_t)available;
}

size_t i2s_capture_read(int16_t *stereo_samples, size_t frame_count) {
    size_t index;
    const size_t available = i2s_capture_available();
    if (frame_count > available) frame_count = available;
    for (index = 0u; index < frame_count; ++index) {
        const uint32_t packed =
            capture_ring[capture_read_count & (I2S_RING_FRAME_COUNT - 1u)];
        stereo_samples[index * 2u] = (int16_t)(packed >> 16);
        stereo_samples[index * 2u + 1u] = (int16_t)packed;
        ++capture_read_count;
    }
    return frame_count;
}

bool i2s_capture_clock_valid(void) {
    const uint32_t write_count = capture_write_count();
    const absolute_time_t now = get_absolute_time();

    if (write_count != capture_activity_count) {
        capture_activity_count = write_count;
        capture_last_activity = now;
    }
    /* At 48 kHz the producer should advance every 20.8 us. A 10 ms timeout is
     * deliberately generous, but still reports a missing/stopped FPGA clock
     * promptly when the host asks for UAC2 Clock Validity. */
    return !is_nil_time(capture_last_activity) &&
           absolute_time_diff_us(capture_last_activity, now) < 10000;
}
