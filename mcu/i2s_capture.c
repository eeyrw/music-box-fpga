#include "i2s_capture.h"
#include "i2s_clock_monitor.h"

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
static PIO capture_pio;
static uint capture_state_machine;
static uint capture_program_offset;
static volatile uint32_t capture_completed_count;
static uint32_t capture_read_count;
static i2s_clock_monitor capture_clock_monitor;
static volatile bool capture_clock_valid;
static volatile bool capture_resync_pending;

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

static void i2s_capture_restart_hardware(void) {
    uint32_t producer_count;
    const uint32_t irq_state = save_and_disable_interrupts();

    /* Stop the producer before aborting DMA so no new FIFO word can race the
     * reset. dma_channel_abort() may report a completion IRQ, hence the channel
     * IRQ is masked and acknowledged around the operation as required by the
     * Pico SDK. All buffered data is deliberately discarded: after a clock
     * interruption its frame alignment cannot be trusted. */
    pio_sm_set_enabled(capture_pio, capture_state_machine, false);
    dma_channel_set_irq0_enabled(capture_dma_channel, false);
    dma_channel_abort(capture_dma_channel);
    dma_channel_acknowledge_irq0(capture_dma_channel);

    producer_count = capture_completed_count + I2S_RING_FRAME_COUNT -
                     dma_hw->ch[capture_dma_channel].transfer_count;
    capture_completed_count = producer_count;
    capture_read_count = producer_count;

    pio_sm_clear_fifos(capture_pio, capture_state_machine);
    pio_sm_restart(capture_pio, capture_state_machine);
    pio_sm_exec(capture_pio, capture_state_machine,
                pio_encode_jmp(capture_program_offset));

    dma_channel_set_write_addr(capture_dma_channel, capture_ring, false);
    dma_channel_set_trans_count(capture_dma_channel, I2S_RING_FRAME_COUNT, true);
    dma_channel_set_irq0_enabled(capture_dma_channel, true);
    pio_sm_set_enabled(capture_pio, capture_state_machine, true);

    i2s_clock_monitor_init(&capture_clock_monitor, producer_count);
    capture_clock_valid = false;
    capture_resync_pending = false;
    restore_interrupts(irq_state);
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
     * the next channel MSB. Synchronize once on the right-to-left transition,
     * skip that one-bit delay, then sample continuously on rising BCLK edges.
     *
     * The PIO wrap target deliberately starts at SET X, not the first LRCLK
     * WAIT. At the falling edge after the 32nd captured bit, the transmitter
     * has already changed LRCLK for the following frame and placed its left
     * MSB. Waiting for another high-to-low LRCLK transition at that point would
     * miss the frame already in progress and capture only every other frame
     * (24 kframes/s from a valid 48 kHz source). Once the initial bit alignment
     * is established, each following group of 32 BCLK rising edges is exactly
     * one stereo frame and needs no further LRCLK resynchronization.
     *
     * With shift-left input, the FIFO word is left[15:0] in bits 31:16 and
     * right[15:0] in bits 15:0. */
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
    /* Disconnected inputs must have a deterministic idle state. Without weak
     * pulls, nearby digital edges can look like an external I2S clock and make
     * UAC2 Clock Validity intermittently true while no FPGA is connected. */
    gpio_pull_down(APP_I2S_BCLK_PIN);
    gpio_pull_down(APP_I2S_LRCLK_PIN);
    gpio_pull_down(APP_I2S_DATA_PIN);

    state_machine = pio_claim_unused_sm(pio, true);
    offset = pio_add_program_at_offset(pio, &program, 0u);
    capture_pio = pio;
    capture_state_machine = state_machine;
    capture_program_offset = offset;
    config = pio_get_default_sm_config();
    sm_config_set_wrap(&config, offset + 4u, offset + 9u);
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
    i2s_clock_monitor_init(&capture_clock_monitor, capture_write_count());
}

void i2s_capture_tick_1ms(void) {
    /* This runs from the regular 1 ms alarm callback, not from USB EP0. The
     * control-request callback can therefore answer immediately even when the
     * external clock is absent or stopped at either logic level. */
    i2s_clock_monitor_tick(&capture_clock_monitor, capture_write_count());
    if (i2s_clock_monitor_recovery_ready(&capture_clock_monitor)) {
        /* Hardware reset is deferred out of this timer IRQ. USB callbacks and
         * ring reads run in the main context, so the reset cannot change their
         * read cursor halfway through a packet copy. */
        capture_resync_pending = true;
        capture_clock_valid = false;
    } else if (!capture_resync_pending) {
        capture_clock_valid = i2s_clock_monitor_valid(&capture_clock_monitor);
    }
}

void i2s_capture_task(void) {
    if (capture_resync_pending) i2s_capture_restart_hardware();
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

void i2s_capture_discard(void) {
    capture_read_count = capture_write_count();
}

bool i2s_capture_clock_valid(void) {
    return capture_clock_valid;
}
