#include "debug_console.h"
#include "i2s_capture.h"
#include "midi_ingress_queue.h"
#include "midi_sysex_reset.h"
#include "rp2040_spi_dma_transport.h"
#include "synth_controller.h"
#include "usb_audio_config.h"
#include "usb_audio_rate_match.h"

#include "hardware/sync.h"
#include "hardware/clocks.h"
#include "hardware/uart.h"
#include "hardware/watchdog.h"
#include "hardware/structs/watchdog.h"
#include "pico/binary_info.h"
#include "pico/multicore.h"
#include "pico/stdio_uart.h"
#include "pico/stdlib.h"
#include "tusb.h"

#include <inttypes.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdint.h>

#ifndef APP_ENABLE_DETAILED_DIAGNOSTICS
#define APP_ENABLE_DETAILED_DIAGNOSTICS 0
#endif

#if APP_ENABLE_DETAILED_DIAGNOSTICS
#define APP_DETAILED(...) do { __VA_ARGS__; } while (0)
#else
#define APP_DETAILED(...) do {} while (0)
#endif

static repeating_timer_t app_timer;
static app_usb_audio_stream_state usb_audio_stream = {
    .resync_pending = true,
};
static int16_t usb_audio_samples[APP_USB_AUDIO_MAX_FRAMES * 2u];
static _Atomic uint32_t usb_midi_rx_callback_count;
static _Atomic uint32_t usb_midi_available_event_count;
static _Atomic uint32_t usb_midi_packet_count;
static _Atomic uint32_t usb_midi_offline_discard_count;
static _Atomic uint32_t usb_midi_last_packet;
static _Atomic bool usb_midi_panic_active;
static midi_ingress_queue usb_midi_ingress;
static midi_sysex_reset_parser usb_midi_sysex_parser;
static _Atomic bool usb_midi_mounted_snapshot;
static _Atomic bool usb_device_ready_snapshot;
static _Atomic bool i2s_clock_valid_snapshot;
static _Atomic uint32_t i2s_buffered_frames_snapshot;
static _Atomic uint32_t app_millisecond_count;
static uint32_t app_i2s_millisecond_cursor;
static uint32_t app_i2s_time_cursor_us;
static _Atomic uint32_t app_control_core_heartbeat_ms;
static _Atomic int app_control_fault;
static uint32_t app_control_core_stack[2048] __attribute__((aligned(8)));

typedef struct app_usb_audio_diagnostics {
    _Atomic uint32_t callbacks;
    _Atomic uint32_t capture_packets;
    _Atomic uint32_t capture_frames;
    _Atomic uint32_t startup_silence_packets;
    _Atomic uint32_t discard_packets;
    _Atomic uint32_t clock_invalid_packets;
    _Atomic uint32_t resync_packets;
    _Atomic uint32_t underflow_packets;
    _Atomic uint32_t short_writes;
    _Atomic uint32_t short_write_bytes;
    _Atomic uint32_t minimum_available_frames;
} app_usb_audio_diagnostics;

static app_usb_audio_diagnostics usb_audio_diagnostics = {
    .minimum_available_frames = UINT32_MAX,
};

#define APP_USB_MIDI_PACKET_BUDGET 8u
#define APP_CONTROL_MIDI_PACKET_BUDGET 16u
#define APP_CONTROL_MIDI_TIME_BUDGET_US 1000u
#define APP_CONTROL_CORE_READY UINT32_C(0x434f5245)
static _Atomic uint32_t usb_midi_budget_hit_count;

#define debug_uart_queue_text debug_console_write
#define debug_uart_queue_printf debug_console_printf
#define debug_uart_tx_dropped_bytes debug_console_dropped_bytes()

typedef struct app_runtime_timing {
    _Atomic uint32_t maximum_i2s_us;
    _Atomic uint32_t maximum_tusb_us;
    _Atomic uint32_t maximum_midi_us;
    _Atomic uint32_t maximum_midi_packet_us;
    _Atomic uint32_t maximum_midi_ingress_us;
    _Atomic uint32_t maximum_synth_us;
    _Atomic uint32_t maximum_synth_monitor_us;
    _Atomic uint32_t maximum_synth_control_us;
    _Atomic uint32_t maximum_command_flush_us;
    _Atomic uint32_t maximum_uart_us;
    _Atomic uint32_t maximum_loop_us;
    _Atomic uint32_t maximum_control_loop_us;
    _Atomic uint32_t loop_overrun_count;
} app_runtime_timing;

static app_runtime_timing runtime_timing;

static void update_maximum(_Atomic uint32_t *maximum, uint32_t elapsed);

#if APP_ENABLE_DETAILED_DIAGNOSTICS
static void update_minimum(_Atomic uint32_t *minimum, uint32_t value) {
    uint32_t observed = atomic_load_explicit(minimum, memory_order_relaxed);
    while (value < observed &&
           !atomic_compare_exchange_weak_explicit(
               minimum, &observed, value, memory_order_relaxed,
               memory_order_relaxed)) {}
}
#endif

static uint32_t diagnostic_time_us(void) {
#if APP_ENABLE_DETAILED_DIAGNOSTICS
    return time_us_32();
#else
    return 0u;
#endif
}

enum app_watchdog_stage {
    APP_WATCHDOG_STAGE_LOOP = UINT32_C(0x4d420001),
    APP_WATCHDOG_STAGE_UART = UINT32_C(0x4d420002),
    APP_WATCHDOG_STAGE_I2S = UINT32_C(0x4d420003),
    APP_WATCHDOG_STAGE_TUSB = UINT32_C(0x4d420004),
    APP_WATCHDOG_STAGE_MIDI = UINT32_C(0x4d420005),
    APP_WATCHDOG_STAGE_SYNTH = UINT32_C(0x4d420006),
    APP_WATCHDOG_STAGE_FATAL = UINT32_C(0x4d42ffff),
};

static void set_watchdog_breadcrumb(uint32_t stage, int result) {
    (void)result;
#if APP_ENABLE_DETAILED_DIAGNOSTICS
    if (get_core_num() == 0u) {
        watchdog_hw->scratch[0] = stage;
        watchdog_hw->scratch[2] = atomic_load_explicit(
            &usb_midi_packet_count, memory_order_relaxed);
    } else {
        watchdog_hw->scratch[1] = stage;
    }
#else
    if (stage == APP_WATCHDOG_STAGE_FATAL) {
        watchdog_hw->scratch[get_core_num()] = stage;
    }
#endif
}

_Static_assert(APP_USB_AUDIO_SAMPLE_RATE_HZ % 1000u == 0u,
               "nominal USB packet must contain an integral frame count");
_Static_assert(APP_USB_AUDIO_NOMINAL_FRAMES ==
                   APP_USB_AUDIO_SAMPLE_RATE_HZ / 1000u,
               "USB nominal packet size disagrees with sample rate");
_Static_assert(APP_USB_AUDIO_EP_MAX_PACKET ==
                   APP_USB_AUDIO_MAX_FRAMES * 2u * sizeof(int16_t),
               "USB endpoint cannot hold the largest stereo audio packet");
_Static_assert(APP_DEBUG_UART_TX_PIN != APP_DEBUG_UART_RX_PIN,
               "debug UART TX and RX pins must be distinct");
_Static_assert(APP_DEBUG_UART_TX_PIN != APP_I2S_BCLK_PIN &&
                   APP_DEBUG_UART_TX_PIN != APP_I2S_LRCLK_PIN &&
                   APP_DEBUG_UART_TX_PIN != APP_I2S_DATA_PIN &&
                   APP_DEBUG_UART_RX_PIN != APP_I2S_BCLK_PIN &&
                   APP_DEBUG_UART_RX_PIN != APP_I2S_LRCLK_PIN &&
                   APP_DEBUG_UART_RX_PIN != APP_I2S_DATA_PIN,
               "debug UART pins overlap the I2S input pins");

bi_decl(bi_program_description(
    "USB MIDI synth controller and stereo FPGA I2S capture"));
bi_decl(bi_program_feature("USB MIDI 1.0 input"));
bi_decl(bi_program_feature("USB Audio Class 2 stereo 48 kHz capture"));
bi_decl(bi_4pins_with_names(
    PICO_DEFAULT_SPI_CSN_PIN, "FPGA SPI CS",
    PICO_DEFAULT_SPI_SCK_PIN, "FPGA SPI SCLK",
    PICO_DEFAULT_SPI_TX_PIN, "FPGA SPI MOSI",
    PICO_DEFAULT_SPI_RX_PIN, "FPGA SPI MISO"));
bi_decl(bi_3pins_with_names(
    APP_I2S_BCLK_PIN, "FPGA I2S BCLK",
    APP_I2S_LRCLK_PIN, "FPGA I2S LRCLK",
    APP_I2S_DATA_PIN, "FPGA I2S SDATA"));
bi_decl(bi_2pins_with_names(
    APP_DEBUG_UART_TX_PIN, "Debug UART TX",
    APP_DEBUG_UART_RX_PIN, "Debug UART RX"));

void platform_delay_ms(uint32_t milliseconds) {
    sleep_ms(milliseconds);
}

uint32_t platform_irq_save(void) {
    return save_and_disable_interrupts();
}

void platform_irq_restore(uint32_t state) {
    restore_interrupts(state);
}

static void update_maximum(_Atomic uint32_t *maximum, uint32_t elapsed) {
#if APP_ENABLE_DETAILED_DIAGNOSTICS
    uint32_t observed = atomic_load_explicit(maximum, memory_order_relaxed);
    while (elapsed > observed &&
           !atomic_compare_exchange_weak_explicit(
               maximum, &observed, elapsed, memory_order_relaxed,
               memory_order_relaxed)) {}
#else
    (void)maximum;
    (void)elapsed;
#endif
}

static void debug_uart_print_status(void) {
    const app_synth_diagnostics *diagnostics = app_synth_get_diagnostics();
    rp2040_spi_diagnostics spi;
    rp2040_spi_get_diagnostics(&spi);
    debug_uart_queue_printf(
        "SPI init=%d last=%d flush=%d reset=%d attempts=%" PRIu32 "\r\n",
        diagnostics->init_result, diagnostics->last_spi_result,
        diagnostics->flush_result, diagnostics->session_reset_result,
        diagnostics->register_attempts);
    debug_uart_queue_printf(
        "FPGA version=%08" PRIx32 " status=%08" PRIx32
        " sf2_size=%" PRIu32 " ready=%u disconnects=%" PRIu32
        " recoveries=%" PRIu32 " epoch=%" PRIu32 " resets=%" PRIu32 "\r\n",
        diagnostics->version, diagnostics->platform_status,
        diagnostics->sf2_size, diagnostics->fpga_session_ready,
        diagnostics->fpga_disconnect_count,
        diagnostics->fpga_recovery_count, diagnostics->session_epoch,
        diagnostics->session_reset_count);
    debug_uart_queue_printf(
        "SPI writes=%" PRIu32 " exchanges=%" PRIu32
        " bytes=%" PRIu32 " errors=%" PRIu32
        " uart_tx_dropped=%" PRIu32 "\r\n",
        spi.write_transactions, spi.exchange_transactions, spi.bytes, spi.errors,
        debug_uart_tx_dropped_bytes);
    debug_uart_queue_printf(
        "SPI DMA idle=%u pending=%u high=%u enqueue_timeouts=%" PRIu32 "\r\n",
        rp2040_spi_dma_idle() ? 1u : 0u, spi.queue_depth,
        spi.queue_high_water, spi.enqueue_timeouts);
    debug_uart_queue_printf(
        "CONTROL last_ms=%" PRIu32 " max_interval_ms=%" PRIu32
        " completed_ticks=%" PRIu32 " jobs=%" PRIu32
        " max_job_ms=%" PRIu32 " fault=%d\r\n",
        diagnostics->control_last_update_ms,
        diagnostics->control_maximum_interval_ms,
        diagnostics->control_completed_ticks,
        diagnostics->control_completed_jobs,
        diagnostics->control_maximum_job_duration_ms,
        atomic_load_explicit(&app_control_fault, memory_order_acquire));
    debug_uart_queue_printf(
        "VOICES active=%u maximum=%u evaluations=%" PRIu32
        " updates=%" PRIu32 "\r\n",
        diagnostics->active_voices, diagnostics->maximum_active_voices,
        diagnostics->control_voice_evaluations,
        diagnostics->controller_voice_updates);
    debug_uart_queue_printf(
        "VOICE DEPS static=%u gain=%u pitch=%u filter=%u\r\n",
        diagnostics->static_voices, diagnostics->periodic_gain_voices,
        diagnostics->periodic_pitch_voices,
        diagnostics->periodic_filter_voices);
    debug_uart_queue_printf(
        "FPGA COMMAND errors=%" PRIu32 " stale=%" PRIu32
        " monitor_failures=%" PRIu32 "\r\n",
        diagnostics->command_error_count,
        diagnostics->stale_generation_count,
        diagnostics->transport_monitor_failures);
    debug_uart_queue_printf(
        "MIDI offline_discards=%" PRIu32 "\r\n",
        atomic_load_explicit(&usb_midi_offline_discard_count,
                             memory_order_relaxed));
}

static void debug_uart_read_register(const char *name, uint16_t address) {
    uint32_t value = 0u;
    const int result = app_fpga_debug_read_register(address, &value);
    debug_uart_queue_printf(
        "REG %-19s [%04x] result=%d value=%08" PRIx32 "\r\n",
        name, address, result, value);
}

static void debug_uart_print_help(void) {
    debug_uart_queue_text("Debug commands:\r\n");
    debug_uart_queue_text("  ? help, s status, v VERSION, p PLATFORM_STATUS\r\n");
    debug_uart_queue_text(
        "  z PLATFORM_SF2_SIZE, c CMD_FIFO_STATUS, d FPGA/I2S diagnostics\r\n");
    debug_uart_queue_text(
        "  e COMMAND_ERROR_COUNT, g STALE_GENERATION_COUNT, h SESSION_EPOCH\r\n");
    debug_uart_queue_text("  m MIDI, u USB audio\r\n");
#if APP_ENABLE_DETAILED_DIAGNOSTICS
    debug_uart_queue_text(
        "  t timing, T reset timing, w START, r START DDR, R DDR[0]\r\n");
#endif
    debug_uart_queue_text(
        "  a FPGA panic/reset, l RELEASE all MCU-owned voices, n/o C4, f FLUSH\r\n");
}

static int app_operator_panic(void) {
    int result;
    uint32_t discarded;

    atomic_store_explicit(&usb_midi_panic_active, true, memory_order_release);
    midi_sysex_reset_parser_init(&usb_midi_sysex_parser);
    discarded = midi_ingress_queue_discard_all(&usb_midi_ingress);
    result = app_synth_render_session_reset();
    discarded += midi_ingress_queue_discard_all(&usb_midi_ingress);
    atomic_fetch_add_explicit(&usb_midi_offline_discard_count, discarded,
                              memory_order_relaxed);
    if (result == 0) {
        i2s_capture_request_resync();
        atomic_store_explicit(&usb_midi_panic_active, false,
                              memory_order_release);
    }
    return result;
}

static void debug_uart_print_midi_status(void) {
    const uint32_t last_packet = atomic_load_explicit(
        &usb_midi_last_packet, memory_order_acquire);
    debug_uart_queue_printf(
        "USB MIDI mounted=%u ready=%u callbacks=%" PRIu32
        " available=%" PRIu32 " packets=%" PRIu32 " budget_hits=%" PRIu32
        " queue=%" PRIu32 " queue_high=%" PRIu32 " queue_overflow=%" PRIu32
        " last=%02x %02x %02x %02x\r\n",
        atomic_load_explicit(&usb_midi_mounted_snapshot, memory_order_acquire)
            ? 1u : 0u,
        atomic_load_explicit(&usb_device_ready_snapshot, memory_order_acquire)
            ? 1u : 0u,
        atomic_load_explicit(&usb_midi_rx_callback_count, memory_order_relaxed),
        atomic_load_explicit(&usb_midi_available_event_count,
                             memory_order_relaxed),
        atomic_load_explicit(&usb_midi_packet_count, memory_order_relaxed),
        atomic_load_explicit(&usb_midi_budget_hit_count, memory_order_relaxed),
        midi_ingress_queue_depth(&usb_midi_ingress),
        atomic_load_explicit(&usb_midi_ingress.high_water,
                             memory_order_relaxed),
        atomic_load_explicit(&usb_midi_ingress.overflow_count,
                             memory_order_relaxed),
        (uint8_t)last_packet, (uint8_t)(last_packet >> 8),
        (uint8_t)(last_packet >> 16), (uint8_t)(last_packet >> 24));
}

#if APP_ENABLE_DETAILED_DIAGNOSTICS
static void debug_uart_print_timing(void) {
    rp2040_spi_diagnostics spi;
    rp2040_spi_get_diagnostics(&spi);
    debug_uart_queue_printf(
        "TIMING max_us i2s=%" PRIu32 " tusb=%" PRIu32
        " midi_ingress=%" PRIu32 " midi_control=%" PRIu32
        " midi_packet=%" PRIu32 " synth=%" PRIu32 " spi=%" PRIu32
        " synth_monitor=%" PRIu32 " synth_control=%" PRIu32
        " command_flush=%" PRIu32
        " uart=%" PRIu32 " loop=%" PRIu32
        " control_loop=%" PRIu32
        " loop_over_1ms=%" PRIu32 "\r\n",
        atomic_load_explicit(&runtime_timing.maximum_i2s_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.maximum_tusb_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.maximum_midi_ingress_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.maximum_midi_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.maximum_midi_packet_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.maximum_synth_us,
                             memory_order_relaxed),
        spi.maximum_dma_us,
        atomic_load_explicit(&runtime_timing.maximum_synth_monitor_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.maximum_synth_control_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.maximum_command_flush_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.maximum_uart_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.maximum_loop_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.maximum_control_loop_us,
                             memory_order_relaxed),
        atomic_load_explicit(&runtime_timing.loop_overrun_count,
                             memory_order_relaxed));
}
#endif

static void debug_uart_print_usb_audio(void) {
    uint32_t minimum_available = atomic_load_explicit(
        &usb_audio_diagnostics.minimum_available_frames, memory_order_relaxed);
    if (minimum_available == UINT32_MAX) minimum_available = 0u;
    debug_uart_queue_printf(
        "USB AUDIO callbacks=%" PRIu32 " capture_packets=%" PRIu32
        " capture_frames=%" PRIu32 " startup_silence=%" PRIu32
        " discard=%" PRIu32 " clock_invalid=%" PRIu32
        " resync=%" PRIu32 " underflow=%" PRIu32 "\r\n",
        atomic_load_explicit(&usb_audio_diagnostics.callbacks,
                             memory_order_relaxed),
        atomic_load_explicit(&usb_audio_diagnostics.capture_packets,
                             memory_order_relaxed),
        atomic_load_explicit(&usb_audio_diagnostics.capture_frames,
                             memory_order_relaxed),
        atomic_load_explicit(&usb_audio_diagnostics.startup_silence_packets,
                             memory_order_relaxed),
        atomic_load_explicit(&usb_audio_diagnostics.discard_packets,
                             memory_order_relaxed),
        atomic_load_explicit(&usb_audio_diagnostics.clock_invalid_packets,
                             memory_order_relaxed),
        atomic_load_explicit(&usb_audio_diagnostics.resync_packets,
                             memory_order_relaxed),
        atomic_load_explicit(&usb_audio_diagnostics.underflow_packets,
                             memory_order_relaxed));
    debug_uart_queue_printf(
        "USB AUDIO min_available=%" PRIu32 " short_writes=%" PRIu32
        " short_bytes=%" PRIu32 " pio_rx_stalls=%" PRIu32
        " ring_overruns=%" PRIu32 " lost_frames=%" PRIu32 "\r\n",
        minimum_available,
        atomic_load_explicit(&usb_audio_diagnostics.short_writes,
                             memory_order_relaxed),
        atomic_load_explicit(&usb_audio_diagnostics.short_write_bytes,
                             memory_order_relaxed),
        i2s_capture_rx_stall_count(), i2s_capture_overrun_count(),
        i2s_capture_lost_frame_count());
}

#if APP_ENABLE_DETAILED_DIAGNOSTICS
static void reset_usb_audio_diagnostics(void) {
    atomic_store_explicit(&usb_audio_diagnostics.callbacks, 0u,
                          memory_order_relaxed);
    atomic_store_explicit(&usb_audio_diagnostics.capture_packets, 0u,
                          memory_order_relaxed);
    atomic_store_explicit(&usb_audio_diagnostics.capture_frames, 0u,
                          memory_order_relaxed);
    atomic_store_explicit(&usb_audio_diagnostics.startup_silence_packets, 0u,
                          memory_order_relaxed);
    atomic_store_explicit(&usb_audio_diagnostics.discard_packets, 0u,
                          memory_order_relaxed);
    atomic_store_explicit(&usb_audio_diagnostics.clock_invalid_packets, 0u,
                          memory_order_relaxed);
    atomic_store_explicit(&usb_audio_diagnostics.resync_packets, 0u,
                          memory_order_relaxed);
    atomic_store_explicit(&usb_audio_diagnostics.underflow_packets, 0u,
                          memory_order_relaxed);
    atomic_store_explicit(&usb_audio_diagnostics.short_writes, 0u,
                          memory_order_relaxed);
    atomic_store_explicit(&usb_audio_diagnostics.short_write_bytes, 0u,
                          memory_order_relaxed);
    atomic_store_explicit(&usb_audio_diagnostics.minimum_available_frames,
                          UINT32_MAX, memory_order_relaxed);
    i2s_capture_reset_diagnostics();
}
#endif

static void debug_uart_dump_fpga(void) {
    debug_uart_queue_printf(
        "I2S clock_valid=%u buffered_frames=%" PRIu32 "\r\n",
        atomic_load_explicit(&i2s_clock_valid_snapshot, memory_order_acquire)
            ? 1u : 0u,
        atomic_load_explicit(&i2s_buffered_frames_snapshot,
                             memory_order_acquire));
    debug_uart_read_register("SYSTEM_STATUS", UINT16_C(0x9010));
    debug_uart_read_register("PLATFORM_ERRORS", UINT16_C(0x9044));
    debug_uart_read_register("PLATFORM_BYTES_LOADED", UINT16_C(0x9048));
    debug_uart_read_register("PLATFORM_CURRENT_LBA", UINT16_C(0x9058));
    debug_uart_read_register("PLATFORM_DDR_STATUS", UINT16_C(0x905c));
    debug_uart_read_register("COMMON_EVENT_FLAGS", UINT16_C(0x9014));
    debug_uart_read_register("PIPELINE_LATENCY", UINT16_C(0x901c));
    debug_uart_read_register("UNDERRUN_COUNT", UINT16_C(0x9024));
    debug_uart_read_register("SAMPLE_DROP_COUNT", UINT16_C(0x9028));
    debug_uart_read_register("DEADLINE_MISS_COUNT", UINT16_C(0x902c));
    debug_uart_read_register("CURRENT_SAMPLE", UINT16_C(0x9030));
    debug_uart_read_register("CMD_FIFO_STATUS", UINT16_C(0x9034));
    debug_uart_read_register("MEM_RESPONSE_COUNT", UINT16_C(0x9038));
    debug_uart_read_register("AUDIO_FIFO_DIAG", UINT16_C(0x9088));
    debug_uart_read_register("AUDIO_LEAD", UINT16_C(0x908c));
    debug_uart_read_register("COMPRESSOR_STATUS", UINT16_C(0x910c));
    debug_uart_read_register("COMPRESSOR_PEAK", UINT16_C(0x9118));
    debug_uart_read_register("COMPRESSOR_MAX_PEAK", UINT16_C(0x9120));
    debug_uart_read_register("COMPRESSOR_INPUTS", UINT16_C(0x9124));
    debug_uart_read_register("COMPRESSOR_OUTPUTS", UINT16_C(0x9128));
    debug_uart_read_register("WINDOW_REQUESTS", UINT16_C(0x9160));
    debug_uart_read_register("WINDOW_HITS", UINT16_C(0x9164));
    debug_uart_read_register("WINDOW_REFILLS", UINT16_C(0x9168));
    debug_uart_read_register("WINDOW_FALLBACKS", UINT16_C(0x916c));
}

#if APP_ENABLE_DETAILED_DIAGNOSTICS
static void debug_uart_print_last_start(void) {
    const app_synth_command_snapshot *snapshot = app_synth_get_last_start();
    uint8_t index;
    debug_uart_queue_printf("LAST START sequence=%" PRIu32 " words=%u\r\n",
                            snapshot->sequence, snapshot->word_count);
    for (index = 0u; index < snapshot->word_count; ++index) {
        debug_uart_queue_printf("  [%02u]=%08" PRIx32 "\r\n", index,
                                snapshot->words[index]);
    }
}

static void debug_uart_dump_last_start_ddr(void) {
    const app_synth_command_snapshot *snapshot = app_synth_get_last_start();
    uint32_t data[4];
    uint32_t addresses[4];
    unsigned address_index;
    if (snapshot->word_count < 3u) {
        debug_uart_queue_text("DDR dump unavailable: no START captured\r\n");
        return;
    }
    addresses[0] = (snapshot->words[2] << 1) & ~UINT32_C(0x0f);
    addresses[1] = addresses[0] + UINT32_C(0x100);
    addresses[2] = ((snapshot->words[2] + snapshot->words[3] / 2u) << 1) &
                   ~UINT32_C(0x0f);
    addresses[3] = ((snapshot->words[2] + snapshot->words[3] - 8u) << 1) &
                   ~UINT32_C(0x0f);
    for (address_index = 0u; address_index < 4u; ++address_index) {
        const int result = app_fpga_debug_read_ddr_line(
            addresses[address_index], data);
        debug_uart_queue_printf(
            "DDR line byte_addr=%08" PRIx32 " result=%d words16=",
            addresses[address_index], result);
        if (result == 0) {
            unsigned word;
            for (word = 0u; word < 4u; ++word) {
                debug_uart_queue_printf(
                    "%04x %04x ",
                    (unsigned)(data[word] & UINT32_C(0xffff)),
                    (unsigned)(data[word] >> 16));
            }
        }
        debug_uart_queue_text("\r\n");
    }
}

static void debug_uart_dump_ddr_zero(void) {
    uint32_t data[4];
    const int result = app_fpga_debug_read_ddr_line(0u, data);
    debug_uart_queue_printf(
        "DDR line byte_addr=00000000 result=%d words16=", result);
    if (result == 0) {
        unsigned word;
        for (word = 0u; word < 4u; ++word) {
            debug_uart_queue_printf("%04x %04x ",
                                    (unsigned)(data[word] & UINT32_C(0xffff)),
                                    (unsigned)(data[word] >> 16));
        }
    }
    debug_uart_queue_text("\r\n");
}
#endif

static void debug_uart_handle_character(void *context, int character) {
    (void)context;
    switch (character) {
            case '?': debug_uart_print_help(); break;
            case 's': debug_uart_print_status(); break;
            case 'v': debug_uart_read_register("VERSION", UINT16_C(0x9000)); break;
            case 'p':
                debug_uart_read_register("PLATFORM_STATUS", UINT16_C(0x9040));
                break;
            case 'z':
                debug_uart_read_register("PLATFORM_SF2_SIZE", UINT16_C(0x9050));
                break;
            case 'c':
                debug_uart_read_register("CMD_FIFO_STATUS", UINT16_C(0x9034));
                break;
            case 'd': debug_uart_dump_fpga(); break;
            case 'e':
                debug_uart_read_register("COMMAND_ERROR_COUNT", UINT16_C(0x9090));
                break;
            case 'g':
                debug_uart_read_register("STALE_GENERATION_COUNT",
                                         UINT16_C(0x9094));
                break;
            case 'h':
                debug_uart_read_register("RENDER_SESSION_EPOCH",
                                         UINT16_C(0x9098));
                break;
            case 'm': debug_uart_print_midi_status(); break;
            case 'u': debug_uart_print_usb_audio(); break;
#if APP_ENABLE_DETAILED_DIAGNOSTICS
            case 't': debug_uart_print_timing(); break;
            case 'T':
                atomic_store_explicit(&runtime_timing.maximum_i2s_us, 0u,
                                      memory_order_relaxed);
                atomic_store_explicit(&runtime_timing.maximum_tusb_us, 0u,
                                      memory_order_relaxed);
                atomic_store_explicit(
                    &runtime_timing.maximum_midi_ingress_us, 0u,
                    memory_order_relaxed);
                atomic_store_explicit(&runtime_timing.maximum_midi_us, 0u,
                                      memory_order_relaxed);
                atomic_store_explicit(
                    &runtime_timing.maximum_midi_packet_us, 0u,
                    memory_order_relaxed);
                atomic_store_explicit(&runtime_timing.maximum_synth_us, 0u,
                                      memory_order_relaxed);
                atomic_store_explicit(
                    &runtime_timing.maximum_synth_monitor_us, 0u,
                    memory_order_relaxed);
                atomic_store_explicit(
                    &runtime_timing.maximum_synth_control_us, 0u,
                    memory_order_relaxed);
                atomic_store_explicit(
                    &runtime_timing.maximum_command_flush_us, 0u,
                    memory_order_relaxed);
                atomic_store_explicit(&runtime_timing.maximum_uart_us, 0u,
                                      memory_order_relaxed);
                atomic_store_explicit(&runtime_timing.maximum_loop_us, 0u,
                                      memory_order_relaxed);
                atomic_store_explicit(
                    &runtime_timing.maximum_control_loop_us, 0u,
                    memory_order_relaxed);
                atomic_store_explicit(&runtime_timing.loop_overrun_count, 0u,
                                      memory_order_relaxed);
                atomic_store_explicit(&usb_midi_budget_hit_count, 0u,
                                      memory_order_relaxed);
                reset_usb_audio_diagnostics();
                debug_uart_queue_text("TIMING reset\r\n");
                break;
            case 'w': debug_uart_print_last_start(); break;
            case 'r': debug_uart_dump_last_start_ddr(); break;
            case 'R': debug_uart_dump_ddr_zero(); break;
#endif
            case 'a':
                debug_uart_queue_printf("FPGA render-session reset result=%d\r\n",
                                        app_operator_panic());
                break;
            case 'l':
                debug_uart_queue_printf("MIDI release-all result=%d\r\n",
                                        app_midi_release_all());
                break;
            case 'n':
                debug_uart_queue_printf("MIDI note-on result=%d\r\n",
                                        app_midi_note_on(0u, 60u, 100u));
                break;
            case 'o':
                debug_uart_queue_printf("MIDI note-off result=%d\r\n",
                                        app_midi_note_off(0u, 60u));
                break;
            case 'f':
                debug_uart_queue_printf("SPI flush result=%d\r\n",
                                        app_fpga_debug_flush());
                break;
            case '\r':
            case '\n': break;
            default:
                debug_uart_queue_printf(
                    "Unknown command '%c'; send ? for help\r\n", character);
                break;
    }
}

static bool app_timer_callback(repeating_timer_t *timer) {
    (void)timer;
    atomic_fetch_add_explicit(&app_millisecond_count, 1u,
                              memory_order_relaxed);
    return true;
}

static void service_i2s_clock_monitor(uint32_t millisecond_count) {
    const uint32_t elapsed_ms = millisecond_count - app_i2s_millisecond_cursor;
    uint32_t now_us;
    if (elapsed_ms == 0u) return;
    app_i2s_millisecond_cursor = millisecond_count;
    now_us = time_us_32();
    i2s_capture_advance_us(now_us - app_i2s_time_cursor_us);
    app_i2s_time_cursor_us = now_us;
}

static int dispatch_midi_packet(const uint8_t packet[4]) {
    /* USB-MIDI 1.0 packets are [Cable/CIN, status, data1, data2]. There is one
     * embedded cable, so routing needs no cable lookup. */
    const midi_sysex_action sysex_action =
        midi_sysex_reset_process_usb_packet(&usb_midi_sysex_parser, packet);
    const uint8_t status = packet[1];
    const uint8_t channel = status & 0x0fu;
    const uint8_t data_1 = packet[2] & 0x7fu;
    const uint8_t data_2 = packet[3] & 0x7fu;

    if (sysex_action == MIDI_SYSEX_ACTION_RESET_SESSION) {
        return app_operator_panic();
    }
    if (status == 0xffu) return app_midi_system_reset();

    switch (status & 0xf0u) {
        case 0x80u:
            return app_midi_note_off(channel, data_1);
        case 0x90u:
            if (data_2 == 0u) {
                return app_midi_note_off(channel, data_1);
            }
            return app_midi_note_on(channel, data_1, data_2);
        case 0xa0u:
            return app_midi_key_pressure(channel, data_1, data_2);
        case 0xb0u:
            return app_midi_control_change(channel, data_1, data_2);
        case 0xc0u:
            app_midi_program_change(channel, data_1);
            return 0;
        case 0xd0u:
            return app_midi_channel_pressure(channel, data_1);
        case 0xe0u:
            return app_midi_pitch_bend(channel, data_1, data_2);
        default:
            return 0;
    }
}

void tud_midi_rx_cb(uint8_t interface) {
    (void)interface;
    atomic_fetch_add_explicit(&usb_midi_rx_callback_count, 1u,
                              memory_order_relaxed);
}

static int service_usb_midi_ingress(void) {
    uint8_t packet[4];
    unsigned packet_budget = APP_USB_MIDI_PACKET_BUDGET;
    while (packet_budget-- != 0u && tud_midi_available() != 0u &&
           !midi_ingress_queue_full(&usb_midi_ingress)) {
        uint32_t packed;
        atomic_fetch_add_explicit(&usb_midi_available_event_count, 1u,
                                  memory_order_relaxed);
        if (!tud_midi_packet_read(packet)) break;
        atomic_fetch_add_explicit(&usb_midi_packet_count, 1u,
                                  memory_order_relaxed);
        packed = (uint32_t)packet[0] | ((uint32_t)packet[1] << 8) |
                 ((uint32_t)packet[2] << 16) | ((uint32_t)packet[3] << 24);
        atomic_store_explicit(&usb_midi_last_packet, packed,
                              memory_order_release);
        if (atomic_load_explicit(&usb_midi_panic_active,
                                 memory_order_acquire)) {
            atomic_fetch_add_explicit(&usb_midi_offline_discard_count, 1u,
                                      memory_order_relaxed);
        } else if (!midi_ingress_queue_push(&usb_midi_ingress, packet)) {
            break;
        }
    }
    if (tud_midi_available() != 0u) {
        atomic_fetch_add_explicit(&usb_midi_budget_hit_count, 1u,
                                  memory_order_relaxed);
    }
    return 0;
}

static int service_control_midi(void) {
    uint8_t packet[4];
    unsigned budget = APP_CONTROL_MIDI_PACKET_BUDGET;
    const uint32_t batch_start_us = time_us_32();
    while (budget-- != 0u && midi_ingress_queue_pop(&usb_midi_ingress, packet)) {
        const uint32_t packet_start_us = diagnostic_time_us();
        const int result = dispatch_midi_packet(packet);
        update_maximum(&runtime_timing.maximum_midi_packet_us,
                       diagnostic_time_us() - packet_start_us);
        if (result < 0) return result;
        if (time_us_32() - batch_start_us >= APP_CONTROL_MIDI_TIME_BUDGET_US) {
            break;
        }
    }
    return 0;
}

static void discard_offline_control_midi(void) {
    uint8_t packet[4];
    while (midi_ingress_queue_pop(&usb_midi_ingress, packet)) {
        atomic_fetch_add_explicit(&usb_midi_offline_discard_count, 1u,
                                  memory_order_relaxed);
    }
}

static size_t fill_usb_audio_silence(
    int16_t samples[APP_USB_AUDIO_MAX_FRAMES * 2u]) {
    size_t sample;
    for (sample = 0u; sample < APP_USB_AUDIO_NOMINAL_FRAMES * 2u; ++sample) {
        samples[sample] = 0;
    }
    return APP_USB_AUDIO_NOMINAL_FRAMES;
}

static size_t fill_usb_audio_packet(
    int16_t samples[APP_USB_AUDIO_MAX_FRAMES * 2u]) {
    size_t available = i2s_capture_available();
    size_t requested;
    size_t captured;
    const bool clock_valid = i2s_capture_clock_valid();
    const bool was_resync_pending = usb_audio_stream.resync_pending;
    const bool was_started = usb_audio_stream.started;
    app_usb_audio_packet_action action;

    APP_DETAILED(atomic_fetch_add_explicit(&usb_audio_diagnostics.callbacks, 1u,
                                           memory_order_relaxed));
    APP_DETAILED(update_minimum(
        &usb_audio_diagnostics.minimum_available_frames, (uint32_t)available));

    action = app_usb_audio_stream_plan(
        &usb_audio_stream, clock_valid, available, &requested);
    if (action == APP_USB_AUDIO_PACKET_DISCARD_AND_SILENCE) {
        atomic_fetch_add_explicit(&usb_audio_diagnostics.discard_packets, 1u,
                                  memory_order_relaxed);
        if (!clock_valid) {
            atomic_fetch_add_explicit(
                &usb_audio_diagnostics.clock_invalid_packets, 1u,
                memory_order_relaxed);
        } else if (was_resync_pending) {
            atomic_fetch_add_explicit(&usb_audio_diagnostics.resync_packets,
                                      1u, memory_order_relaxed);
        } else if (was_started &&
                   available < APP_USB_AUDIO_NOMINAL_FRAMES - 1u) {
            atomic_fetch_add_explicit(&usb_audio_diagnostics.underflow_packets,
                                      1u, memory_order_relaxed);
        }
        i2s_capture_discard();
        return fill_usb_audio_silence(samples);
    }
    if (action == APP_USB_AUDIO_PACKET_SILENCE) {
        atomic_fetch_add_explicit(
            &usb_audio_diagnostics.startup_silence_packets, 1u,
            memory_order_relaxed);
        return fill_usb_audio_silence(samples);
    }

    /* Once 2 ms of fresh I2S data is available, vary packet length rather than
     * modifying samples:
     *
     *   low fill  -> 47 frames, allowing the capture ring to gain one frame
     *   nominal   -> 48 frames
     *   high fill -> 49 frames, draining one extra frame
     *
     * USB 2.0 permits an isochronous payload shorter than wMaxPacketSize, and
     * UAC2 asynchronous IN endpoints are specifically intended for a source
     * clock independent of SOF. This preserves every FPGA sample; it does not
     * drop a frame or duplicate the previous one to correct clock drift. */
    captured = i2s_capture_read(samples, requested);
    APP_DETAILED(atomic_fetch_add_explicit(
        &usb_audio_diagnostics.capture_packets, 1u, memory_order_relaxed));
    APP_DETAILED(atomic_fetch_add_explicit(
        &usb_audio_diagnostics.capture_frames, (uint32_t)captured,
        memory_order_relaxed));
    return captured;
}

bool tud_audio_tx_done_pre_load_cb(uint8_t rhport, uint8_t function_id,
                                   uint8_t endpoint, uint8_t alternate) {
    size_t frame_count;
    uint16_t written;
    (void)rhport;
    (void)function_id;
    (void)endpoint;
    (void)alternate;
    frame_count = fill_usb_audio_packet(usb_audio_samples);
    const uint16_t requested_bytes =
        (uint16_t)(frame_count * 2u * sizeof(usb_audio_samples[0]));
    written = tud_audio_write(usb_audio_samples, requested_bytes);
    if (written != requested_bytes) {
        atomic_fetch_add_explicit(&usb_audio_diagnostics.short_writes, 1u,
                                  memory_order_relaxed);
        atomic_fetch_add_explicit(&usb_audio_diagnostics.short_write_bytes,
                                  requested_bytes - written,
                                  memory_order_relaxed);
    }
    return true;
}

bool tud_audio_get_req_entity_cb(uint8_t rhport,
                                 const tusb_control_request_t *request) {
    static const audio_desc_channel_cluster_t input_channels = {
        .bNrChannels = 2u,
        .bmChannelConfig = AUDIO_CHANNEL_CONFIG_FRONT_LEFT |
                           AUDIO_CHANNEL_CONFIG_FRONT_RIGHT,
        .iChannelNames = 0u,
    };
    static const uint32_t sample_rate = APP_USB_AUDIO_SAMPLE_RATE_HZ;
    static uint8_t clock_valid;
    static const struct {
        uint16_t count;
        uint32_t minimum;
        uint32_t maximum;
        uint32_t resolution;
    } __attribute__((packed)) sample_rate_range = {
        1u, APP_USB_AUDIO_SAMPLE_RATE_HZ, APP_USB_AUDIO_SAMPLE_RATE_HZ, 0u
    };
    const uint8_t entity = (uint8_t)(request->wIndex >> 8);
    const uint8_t control = (uint8_t)(request->wValue >> 8);

    /* All controls in this topology are master controls. UAC2 section 5.2.2
     * requires an unsupported Channel Number to stall the control pipe. */
    if (!app_usb_audio_control_channel_supported(request->wValue)) return false;

    /* Input Terminal 1 advertises its Connector Control as read-only. Return
     * the same two-channel cluster encoded in the terminal and AS descriptors. */
    if (entity == APP_USB_AUDIO_INPUT_TERMINAL_ID &&
        control == AUDIO_TE_CTRL_CONNECTOR &&
        request->bRequest == AUDIO_CS_REQ_CUR) {
        return tud_audio_buffer_and_schedule_control_xfer(
            rhport, request, (void *)&input_channels, sizeof(input_channels));
    }
    /* External Clock Source 3 is nominally 48 kHz and not programmable. UAC2
     * still requires CUR and RANGE for Frequency; only CUR exists for Validity. */
    if (entity != APP_USB_AUDIO_CLOCK_SOURCE_ID) return false;
    if (control == AUDIO_CS_CTRL_SAM_FREQ) {
        if (request->bRequest == AUDIO_CS_REQ_CUR) {
            return tud_audio_buffer_and_schedule_control_xfer(
                rhport, request, (void *)&sample_rate, sizeof(sample_rate));
        }
        if (request->bRequest == AUDIO_CS_REQ_RANGE) {
            return tud_control_xfer(rhport, request,
                                    (void *)&sample_rate_range,
                                    sizeof(sample_rate_range));
        }
    } else if (control == AUDIO_CS_CTRL_CLK_VALID &&
               request->bRequest == AUDIO_CS_REQ_CUR) {
        clock_valid = i2s_capture_clock_valid() ? 1u : 0u;
        return tud_control_xfer(rhport, request, (void *)&clock_valid,
                                sizeof(clock_valid));
    }
    return false;
}

bool tud_audio_set_itf_close_EP_cb(uint8_t rhport,
                                   const tusb_control_request_t *request) {
    (void)rhport;
    (void)request;
    app_usb_audio_stream_reset(&usb_audio_stream);
    return true;
}

void tud_umount_cb(void) {
    app_usb_audio_stream_reset(&usb_audio_stream);
}

void tud_suspend_cb(bool remote_wakeup_enabled) {
    (void)remote_wakeup_enabled;
    app_usb_audio_stream_reset(&usb_audio_stream);
}

static void fatal_blink(const char *reason, int result) {
    set_watchdog_breadcrumb(APP_WATCHDOG_STAGE_FATAL, result);
    printf("FATAL %s result=%d\r\n", reason, result);
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
    while (true) {
        gpio_xor_mask(1u << PICO_DEFAULT_LED_PIN);
        sleep_ms(100u);
    }
}

static void app_control_core_main(void) {
    uint32_t command_flush_millisecond = atomic_load_explicit(
        &app_millisecond_count, memory_order_relaxed);
    rp2040_spi_dma_init();
    multicore_fifo_push_blocking(APP_CONTROL_CORE_READY);
    while (true) {
        const uint32_t millisecond_count = atomic_load_explicit(
            &app_millisecond_count, memory_order_relaxed);
        const uint32_t loop_start_us = diagnostic_time_us();
        uint32_t stage_start_us;
        uint32_t elapsed_us;
        int result;

        atomic_store_explicit(&app_control_core_heartbeat_ms,
                              millisecond_count, memory_order_relaxed);
        if (atomic_load_explicit(&app_control_fault, memory_order_acquire) == 0) {
            set_watchdog_breadcrumb(APP_WATCHDOG_STAGE_SYNTH, 0);
            stage_start_us = diagnostic_time_us();
            result = app_synth_monitor_transport(millisecond_count);
            elapsed_us = diagnostic_time_us() - stage_start_us;
            update_maximum(&runtime_timing.maximum_synth_us, elapsed_us);
            update_maximum(&runtime_timing.maximum_synth_monitor_us, elapsed_us);
            if (result != 0) {
                atomic_store_explicit(&app_control_fault, result,
                                      memory_order_release);
            }

            set_watchdog_breadcrumb(APP_WATCHDOG_STAGE_MIDI, 0);
            stage_start_us = diagnostic_time_us();
            if (result == 0 && app_synth_session_ready()) {
                result = service_control_midi();
            } else if (result == 0) {
                discard_offline_control_midi();
            }
            update_maximum(&runtime_timing.maximum_midi_us,
                           diagnostic_time_us() - stage_start_us);

            set_watchdog_breadcrumb(APP_WATCHDOG_STAGE_SYNTH, 0);
            stage_start_us = diagnostic_time_us();
            if (result == 0 && app_synth_session_ready()) {
                result = app_synth_service(millisecond_count);
            }
            elapsed_us = diagnostic_time_us() - stage_start_us;
            update_maximum(&runtime_timing.maximum_synth_us, elapsed_us);
            update_maximum(&runtime_timing.maximum_synth_control_us, elapsed_us);
            stage_start_us = diagnostic_time_us();
            if (result == 0 &&
                millisecond_count != command_flush_millisecond) {
                command_flush_millisecond = millisecond_count;
                result = app_synth_flush_commands();
            }
            elapsed_us = diagnostic_time_us() - stage_start_us;
            update_maximum(&runtime_timing.maximum_synth_us, elapsed_us);
            update_maximum(&runtime_timing.maximum_command_flush_us, elapsed_us);
            if (result != 0) {
                atomic_store_explicit(&app_control_fault, result,
                                      memory_order_release);
            }
        }

        set_watchdog_breadcrumb(APP_WATCHDOG_STAGE_UART, 0);
        stage_start_us = diagnostic_time_us();
        debug_console_service(debug_uart_handle_character, NULL);
        update_maximum(&runtime_timing.maximum_uart_us,
                       diagnostic_time_us() - stage_start_us);
        elapsed_us = diagnostic_time_us() - loop_start_us;
        update_maximum(&runtime_timing.maximum_control_loop_us, elapsed_us);
        atomic_store_explicit(
            &app_control_core_heartbeat_ms,
            atomic_load_explicit(&app_millisecond_count, memory_order_relaxed),
            memory_order_release);
        tight_loop_contents();
    }
}

int main(void) {
    int result;
    uint32_t previous_core0_stage;
    uint32_t previous_core1_stage;
    uint32_t previous_midi_packets;
    uint32_t previous_spi_writes;
    bool watchdog_reboot;
    bool watchdog_timeout;
    tusb_rhport_init_t usb_init = {
        .role = TUSB_ROLE_DEVICE,
        .speed = TUSB_SPEED_AUTO,
    };

    if (!set_sys_clock_khz(APP_SYS_CLOCK_KHZ, true)) {
        fatal_blink("system-clock", -1);
    }
    watchdog_reboot = watchdog_caused_reboot();
    watchdog_timeout = watchdog_enable_caused_reboot();
    previous_core0_stage = watchdog_hw->scratch[0];
    previous_core1_stage = watchdog_hw->scratch[1];
    previous_midi_packets = watchdog_hw->scratch[2];
    previous_spi_writes = watchdog_hw->scratch[3];
    stdio_uart_init_full(uart0, APP_DEBUG_UART_BAUD, APP_DEBUG_UART_TX_PIN,
                         APP_DEBUG_UART_RX_PIN);
    printf("\r\nMusic Box RP2040 boot; debug UART %u 8N1 TX=GP%u RX=GP%u\r\n",
           APP_DEBUG_UART_BAUD, APP_DEBUG_UART_TX_PIN, APP_DEBUG_UART_RX_PIN);
    printf("RESET watchdog=%u timeout=%u core0_stage=%08" PRIx32
           " core1_stage=%08" PRIx32 " midi_packets=%" PRIu32
           " spi_writes=%" PRIu32 "\r\n",
           watchdog_reboot ? 1u : 0u, watchdog_timeout ? 1u : 0u,
           previous_core0_stage, previous_core1_stage, previous_midi_packets,
           previous_spi_writes);
    set_watchdog_breadcrumb(APP_WATCHDOG_STAGE_LOOP, 0);
    midi_ingress_queue_init(&usb_midi_ingress);
    midi_sysex_reset_parser_init(&usb_midi_sysex_parser);
    rp2040_spi_bus_init();
    i2s_capture_init();
    result = app_synth_init();
    if (result == 0) i2s_capture_request_resync();
    debug_uart_print_status();
    if (result != 0) fatal_blink("synth-init", result);
    app_i2s_time_cursor_us = time_us_32();
    if (!add_repeating_timer_ms(-1, app_timer_callback, NULL, &app_timer)) {
        fatal_blink("control-timer", -1);
    }
    if (!tusb_init(BOARD_TUD_RHPORT, &usb_init)) fatal_blink("tinyusb-init", -1);
    /* A firmware fault must not leave Linux blocked forever in a synchronous
     * USB audio ioctl. The watchdog pauses under SWD so normal debugging still
     * works, but resets a genuinely wedged main loop within two seconds. */
    watchdog_enable(2000u, true);
    atomic_store_explicit(
        &app_control_core_heartbeat_ms,
        atomic_load_explicit(&app_millisecond_count, memory_order_relaxed),
        memory_order_relaxed);
    multicore_launch_core1_with_stack(app_control_core_main,
                                      app_control_core_stack,
                                      sizeof(app_control_core_stack));
    if (multicore_fifo_pop_blocking() != APP_CONTROL_CORE_READY) {
        fatal_blink("control-core-start", -1);
    }

    while (true) {
        const uint32_t millisecond_count = atomic_load_explicit(
            &app_millisecond_count, memory_order_relaxed);
        const uint32_t loop_start_us = diagnostic_time_us();
        uint32_t stage_start_us;
        uint32_t elapsed_us;
        if (millisecond_count - atomic_load_explicit(
                                    &app_control_core_heartbeat_ms,
                                    memory_order_acquire) < 500u) {
            watchdog_update();
        }
        set_watchdog_breadcrumb(APP_WATCHDOG_STAGE_I2S, 0);
        stage_start_us = diagnostic_time_us();
        service_i2s_clock_monitor(millisecond_count);
        i2s_capture_task();
        atomic_store_explicit(&i2s_clock_valid_snapshot,
                              i2s_capture_clock_valid(), memory_order_release);
        atomic_store_explicit(&i2s_buffered_frames_snapshot,
                              (uint32_t)i2s_capture_available(),
                              memory_order_release);
        update_maximum(&runtime_timing.maximum_i2s_us,
                       diagnostic_time_us() - stage_start_us);
        set_watchdog_breadcrumb(APP_WATCHDOG_STAGE_TUSB, 0);
        stage_start_us = diagnostic_time_us();
        tud_task();
        atomic_store_explicit(&usb_midi_mounted_snapshot, tud_midi_mounted(),
                              memory_order_release);
        atomic_store_explicit(&usb_device_ready_snapshot, tud_ready(),
                              memory_order_release);
        update_maximum(&runtime_timing.maximum_tusb_us,
                       diagnostic_time_us() - stage_start_us);
        set_watchdog_breadcrumb(APP_WATCHDOG_STAGE_MIDI, 0);
        stage_start_us = diagnostic_time_us();
        result = service_usb_midi_ingress();
        update_maximum(&runtime_timing.maximum_midi_ingress_us,
                       diagnostic_time_us() - stage_start_us);
        (void)result;
        elapsed_us = diagnostic_time_us() - loop_start_us;
        update_maximum(&runtime_timing.maximum_loop_us, elapsed_us);
        if (elapsed_us > 1000u) {
            atomic_fetch_add_explicit(&runtime_timing.loop_overrun_count, 1u,
                                      memory_order_relaxed);
        }
        set_watchdog_breadcrumb(APP_WATCHDOG_STAGE_LOOP, 0);
        tight_loop_contents();
    }
}
