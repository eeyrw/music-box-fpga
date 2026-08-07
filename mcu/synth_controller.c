/* Production compact-v2 MSF2 control plane. */

#include "msf2.h"
#include "synth_controller.h"
#include "audio_session_defaults.h"
#include "command_batch.h"
#include "fpga_spi_transport.h"
#include "midi_policy.h"
#include "transport_health_policy.h"

#include <stddef.h>
#include <stdint.h>

#ifndef APP_ENABLE_DETAILED_DIAGNOSTICS
#define APP_ENABLE_DETAILED_DIAGNOSTICS 0
#endif

#ifndef APP_VOICE_COUNT
#define APP_VOICE_COUNT MSF2_MAX_VOICE_COUNT
#endif
#define APP_MAX_COMMAND_PAYLOAD_WORDS 16u
#define APP_MAX_COMMAND_WORDS (1u + APP_MAX_COMMAND_PAYLOAD_WORDS)
#define APP_FPGA_INTERFACE_VERSION UINT32_C(0x00100000)
#define APP_FPGA_PLATFORM_STATUS_ADDRESS UINT16_C(0x9040)
#define APP_FPGA_SF2_SIZE_ADDRESS UINT16_C(0x9050)
#define APP_FPGA_COMMAND_ERROR_ADDRESS UINT16_C(0x9090)
#define APP_FPGA_STALE_GENERATION_ADDRESS UINT16_C(0x9094)
#define APP_FPGA_SESSION_EPOCH_ADDRESS UINT16_C(0x9098)
#define APP_FPGA_SESSION_RESET_POLL_LIMIT 32u
#ifndef APP_CONTROL_UPDATE_PERIOD_MS
#define APP_CONTROL_UPDATE_PERIOD_MS 5u
#endif
#define APP_CONTROL_VOICE_SLICE 16u

_Static_assert(APP_VOICE_COUNT > 0u,
               "firmware must allocate at least one FPGA voice");
_Static_assert(APP_VOICE_COUNT <= MSF2_MAX_VOICE_COUNT,
               "firmware voice capacity exceeds the FPGA command protocol");
_Static_assert(APP_CONTROL_UPDATE_PERIOD_MS > 0u,
               "control update period must be positive");

/* The linker script may expose an MSF2 blob stored in internal flash or XIP
 * memory. Replace these symbols with the selected MCU's asset mechanism. */
extern const uint8_t app_msf2_image_start[];
extern const uint8_t app_msf2_image_end[];

/* Board HAL: transmit one complete buffer using SPI mode 0 (CPOL=0, CPHA=0),
 * MSB first, on the FPGA command-port chip select.
 *
 * CS must go low before byte zero and stay low until the final byte has been
 * clocked. This call must be synchronous: bytes points to a stack buffer which
 * becomes invalid when the function returns. A DMA-based HAL must therefore
 * wait for completion here, or first copy the frame to a DMA-owned queue.
 * Return zero after a complete successful transfer and nonzero on failure. */
extern int platform_spi_write_mode0_cs0(const uint8_t *bytes,
                                        size_t byte_count);
extern int platform_spi_enqueue_mode0_cs0(const uint8_t *bytes,
                                          size_t byte_count);
extern int platform_spi_exchange_mode0_cs0(const uint8_t *tx_bytes,
                                           uint8_t *rx_bytes,
                                           size_t byte_count);
extern int platform_spi_wait_idle(uint32_t timeout_us);
extern void platform_delay_ms(uint32_t milliseconds);
extern uint32_t platform_irq_save(void);
extern void platform_irq_restore(uint32_t state);

static int app_spi_write(void *context, const uint8_t *bytes,
                         size_t byte_count) {
    (void)context;
    return platform_spi_write_mode0_cs0(bytes, byte_count);
}

static int app_spi_exchange(void *context, const uint8_t *tx_bytes,
                            uint8_t *rx_bytes, size_t byte_count) {
    (void)context;
    return platform_spi_exchange_mode0_cs0(tx_bytes, rx_bytes, byte_count);
}

static int app_spi_enqueue(void *context, const uint8_t *bytes,
                           size_t byte_count) {
    (void)context;
    return platform_spi_enqueue_mode0_cs0(bytes, byte_count);
}

static msf2_view app_view;
static msf2_runtime app_runtime;
static msf2_channel_state app_channels[MSF2_CHANNEL_COUNT];
static msf2_voice_state app_voices[APP_VOICE_COUNT];
static uint16_t app_free_stack[APP_VOICE_COUNT];
static midi_policy app_midi;
static app_synth_diagnostics app_diagnostics;
#if APP_ENABLE_DETAILED_DIAGNOSTICS
static app_synth_command_snapshot app_last_start;
#endif

static uint32_t app_last_control_millisecond;
static command_batch app_command_batch;
static uint32_t app_transport_monitor_millisecond;
static uint32_t app_transport_diagnostics_millisecond;
static uint8_t app_transport_monitor_consecutive_failures;
static struct {
    uint32_t start_millisecond;
    uint32_t target_millisecond;
    uint32_t elapsed_ticks;
    uint16_t voice_cursor;
    uint8_t active;
    msf2_control_voice_snapshot voices[APP_VOICE_COUNT];
    uint32_t channel_dirty_revisions[MSF2_CHANNEL_COUNT];
} app_control_job;

static int app_command_sink(void *context, const uint32_t *words,
                            uint8_t word_count);

static msf2_result app_reset_local_session(void) {
    msf2_result result;
    command_batch_init(&app_command_batch);
    result = msf2_runtime_init(&app_runtime, &app_view, app_channels,
                               app_voices, app_free_stack, APP_VOICE_COUNT,
                               app_command_sink, NULL);
    if (result == MSF2_OK) result = midi_policy_init(&app_midi, &app_runtime);
    app_control_job.active = 0u;
    app_diagnostics.control_voice_evaluations = 0u;
    app_diagnostics.controller_voice_updates = 0u;
    app_diagnostics.control_completed_jobs = 0u;
    app_diagnostics.control_maximum_job_duration_ms = 0u;
    app_diagnostics.active_voices = 0u;
    app_diagnostics.maximum_active_voices = 0u;
    return result;
}

static int app_mark_session_offline(void) {
    if (app_diagnostics.fpga_session_ready == 0u) return 0;
    app_diagnostics.fpga_session_ready = 0u;
    ++app_diagnostics.fpga_disconnect_count;
    return app_reset_local_session() == MSF2_OK ? 0 : -(int)MSF2_ERR_SINK;
}

static int app_perform_render_session_reset(void) {
    msf2_result local_result;
    uint32_t default_words[AUDIO_SESSION_DEFAULT_WORD_COUNT];

    app_diagnostics.fpga_session_ready = 0u;
    app_control_job.active = 0u;
    command_batch_init(&app_command_batch);
    if (platform_spi_wait_idle(UINT32_C(100000)) != 0) {
        app_diagnostics.session_reset_result = -1;
        return -1;
    }
    app_diagnostics.session_reset_result = fpga_spi_reset_session(
        app_spi_write, app_spi_exchange, NULL,
        APP_FPGA_SESSION_EPOCH_ADDRESS, &app_diagnostics.session_epoch,
        APP_FPGA_SESSION_RESET_POLL_LIMIT, 8u);
    if (app_diagnostics.session_reset_result != 0) return -1;

    local_result = app_reset_local_session();
    if (local_result != MSF2_OK) {
        app_diagnostics.session_reset_result = -(int)local_result;
        return app_diagnostics.session_reset_result;
    }
    audio_session_defaults_build(default_words);
    app_diagnostics.session_reset_result = fpga_spi_send_commands(
        app_spi_write, NULL, default_words, AUDIO_SESSION_DEFAULT_WORD_COUNT);
    if (app_diagnostics.session_reset_result != 0) return -1;
    ++app_diagnostics.session_reset_count;
    app_diagnostics.fpga_session_ready = 1u;
    return 0;
}

static int app_send_command_words(void *context, const uint32_t *words,
                                  uint8_t word_count) {
    (void)context;
    return fpga_spi_send_commands(app_spi_enqueue, NULL, words, word_count);
}

int app_synth_flush_commands(void) {
    if (app_diagnostics.fpga_session_ready == 0u) {
        command_batch_init(&app_command_batch);
        return 0;
    }
    return command_batch_flush(&app_command_batch, app_send_command_words, NULL);
}

static int app_command_sink(void *context, const uint32_t *words,
                            uint8_t word_count) {
    uint8_t payload_words;
    (void)context;
    if (words == NULL || word_count == 0u || word_count > APP_MAX_COMMAND_WORDS) {
        return -1;
    }
    payload_words = (uint8_t)(words[0] & UINT32_C(0xff));
    if (payload_words > APP_MAX_COMMAND_PAYLOAD_WORDS ||
        word_count != (uint8_t)(payload_words + 1u)) return -1;
#if APP_ENABLE_DETAILED_DIAGNOSTICS
    if (word_count <= APP_SYNTH_DEBUG_MAX_COMMAND_WORDS &&
        (uint8_t)(words[0] >> 24) == UINT8_C(0x10)) {
        uint8_t index;
        ++app_last_start.sequence;
        app_last_start.word_count = word_count;
        for (index = 0u; index < word_count; ++index) {
            app_last_start.words[index] = words[index];
        }
    }
#endif
    return command_batch_append(&app_command_batch, words, word_count,
                                app_send_command_words, NULL);
}

int app_synth_init(void) {
    const size_t image_size = (size_t)(app_msf2_image_end - app_msf2_image_start);
    const uint16_t version_address = UINT16_C(0x9000);
    const uint32_t platform_error_mask = UINT32_C(0x00000002);
    const uint32_t asset_loaded_mask = UINT32_C(0x00000020);
    uint32_t attempt;
    msf2_result result;
    app_diagnostics = (app_synth_diagnostics){
        .init_result = -(int)MSF2_ERR_SINK,
        .last_spi_result = -1,
        .flush_result = -1,
        .session_reset_result = -1,
    };
    command_batch_init(&app_command_batch);
    result = msf2_view_init(&app_view, app_msf2_image_start, image_size);
    if (result != MSF2_OK) {
        /* Fail closed: do not accept MIDI or fall back to parsing SF2. */
        app_diagnostics.init_result = -(int)result;
        return app_diagnostics.init_result;
    }
    if (app_view.source_size_bytes > UINT32_MAX) {
        app_diagnostics.init_result = -(int)MSF2_ERR_PROFILE;
        return app_diagnostics.init_result;
    }
    for (attempt = 0u; attempt < 30000u; ++attempt) {
        uint32_t version;
        uint32_t platform_status;
        uint32_t sf2_size;
        app_diagnostics.register_attempts = attempt + 1u;
        app_diagnostics.last_spi_result = fpga_spi_read_register(
            app_spi_write, app_spi_exchange, NULL, version_address, &version, 8u);
        if (app_diagnostics.last_spi_result != 0) {
            platform_delay_ms(1u);
            continue;
        }
        app_diagnostics.version = version;
        if (version != APP_FPGA_INTERFACE_VERSION) {
            app_diagnostics.init_result = -(int)MSF2_ERR_PROFILE;
            return app_diagnostics.init_result;
        }
        app_diagnostics.last_spi_result = fpga_spi_read_register(
            app_spi_write, app_spi_exchange, NULL,
            APP_FPGA_PLATFORM_STATUS_ADDRESS,
            &platform_status, 8u);
        if (app_diagnostics.last_spi_result != 0) {
            platform_delay_ms(1u);
            continue;
        }
        app_diagnostics.platform_status = platform_status;
        if ((platform_status & platform_error_mask) != 0u) {
            app_diagnostics.init_result = -(int)MSF2_ERR_SINK;
            return app_diagnostics.init_result;
        }
        if ((platform_status & asset_loaded_mask) == 0u) {
            platform_delay_ms(1u);
            continue;
        }
        app_diagnostics.last_spi_result = fpga_spi_read_register(
            app_spi_write, app_spi_exchange, NULL, APP_FPGA_SF2_SIZE_ADDRESS,
            &sf2_size,
            8u);
        if (app_diagnostics.last_spi_result != 0) {
            platform_delay_ms(1u);
            continue;
        }
        app_diagnostics.sf2_size = sf2_size;
        if (sf2_size != (uint32_t)app_view.source_size_bytes) {
            app_diagnostics.init_result = -(int)MSF2_ERR_PROFILE;
            return app_diagnostics.init_result;
        }
        break;
    }
    if (attempt == 30000u) return app_diagnostics.init_result;
    if (app_perform_render_session_reset() != 0) {
        app_diagnostics.init_result = -(int)MSF2_ERR_SINK;
        return app_diagnostics.init_result;
    }
    result = MSF2_OK;
    if (result == MSF2_OK &&
        fpga_spi_read_register(app_spi_write, app_spi_exchange, NULL,
                               APP_FPGA_COMMAND_ERROR_ADDRESS,
                               &app_diagnostics.command_error_count, 8u) != 0) {
        result = MSF2_ERR_SINK;
    }
    if (result == MSF2_OK &&
        fpga_spi_read_register(app_spi_write, app_spi_exchange, NULL,
                               APP_FPGA_STALE_GENERATION_ADDRESS,
                               &app_diagnostics.stale_generation_count, 8u) != 0) {
        result = MSF2_ERR_SINK;
    }
    app_last_control_millisecond = 0u;
    app_transport_monitor_millisecond = 0u;
    app_transport_diagnostics_millisecond = 0u;
    app_transport_monitor_consecutive_failures = 0u;
    app_diagnostics.fpga_session_ready = result == MSF2_OK ? 1u : 0u;
    app_diagnostics.init_result = result == MSF2_OK ? 0 : -(int)result;
    return app_diagnostics.init_result;
}

const app_synth_diagnostics *app_synth_get_diagnostics(void) {
    uint16_t active;
    app_diagnostics.static_voices = 0u;
    app_diagnostics.periodic_gain_voices = 0u;
    app_diagnostics.periodic_pitch_voices = 0u;
    app_diagnostics.periodic_filter_voices = 0u;
    for (active = 0u; active < app_runtime.active_count; ++active) {
        const msf2_voice_state *voice =
            &app_runtime.voices[app_runtime.active_voice_indices[active]];
        if (voice->periodic_groups == 0u) ++app_diagnostics.static_voices;
        if ((voice->periodic_groups & MSF2_CONTROL_GROUP_GAIN) != 0u) {
            ++app_diagnostics.periodic_gain_voices;
        }
        if ((voice->periodic_groups & MSF2_CONTROL_GROUP_PITCH) != 0u) {
            ++app_diagnostics.periodic_pitch_voices;
        }
        if ((voice->periodic_groups & MSF2_CONTROL_GROUP_FILTER) != 0u) {
            ++app_diagnostics.periodic_filter_voices;
        }
    }
    return &app_diagnostics;
}

#if APP_ENABLE_DETAILED_DIAGNOSTICS
const app_synth_command_snapshot *app_synth_get_last_start(void) {
    return &app_last_start;
}
#endif

int app_fpga_debug_read_register(uint16_t address, uint32_t *data) {
    if (app_synth_flush_commands() != 0) return -1;
    if (platform_spi_wait_idle(UINT32_C(100000)) != 0) return -1;
    app_diagnostics.last_spi_result = fpga_spi_read_register(
        app_spi_write, app_spi_exchange, NULL, address, data, 8u);
    return app_diagnostics.last_spi_result;
}

#if APP_ENABLE_DETAILED_DIAGNOSTICS
int app_fpga_debug_write_register(uint16_t address, uint32_t data) {
    if (app_synth_flush_commands() != 0) return -1;
    if (platform_spi_wait_idle(UINT32_C(100000)) != 0) return -1;
    app_diagnostics.last_spi_result = fpga_spi_write_register(
        app_spi_write, app_spi_exchange, NULL, address, data, 8u);
    return app_diagnostics.last_spi_result;
}

int app_fpga_debug_read_ddr_line(uint32_t byte_address, uint32_t data[4]) {
    const uint16_t control_address = UINT16_C(0x9060);
    const uint16_t status_address = UINT16_C(0x9064);
    const uint16_t address_address = UINT16_C(0x9068);
    const uint16_t data_address = UINT16_C(0x9070);
    uint32_t status = 0u;
    unsigned attempt;
    unsigned word;
    int result;
    if (data == NULL || (byte_address & UINT32_C(0x0f)) != 0u) return -1;
    result = app_fpga_debug_write_register(control_address, UINT32_C(0x04));
    if (result != 0) return result;
    result = app_fpga_debug_write_register(address_address, byte_address);
    if (result != 0) return result;
    result = app_fpga_debug_read_register(status_address, &status);
    if (result != 0 || (status & UINT32_C(0x02)) == 0u) return -1;
    result = app_fpga_debug_write_register(control_address, UINT32_C(0x01));
    if (result != 0) return result;
    for (attempt = 0u; attempt < 1000u; ++attempt) {
        result = app_fpga_debug_read_register(status_address, &status);
        if (result != 0) return result;
        if ((status & UINT32_C(0x10)) != 0u) return -1;
        if ((status & UINT32_C(0x08)) != 0u) break;
    }
    if (attempt == 1000u) return -1;
    for (word = 0u; word < 4u; ++word) {
        result = app_fpga_debug_read_register(
            (uint16_t)(data_address + word * 4u), &data[word]);
        if (result != 0) return result;
    }
    return 0;
}
#endif

int app_fpga_debug_flush(void) {
    if (app_synth_flush_commands() != 0) return -1;
    if (platform_spi_wait_idle(UINT32_C(100000)) != 0) return -1;
    app_diagnostics.flush_result = fpga_spi_flush(app_spi_write, NULL);
    return app_diagnostics.flush_result;
}

int app_synth_render_session_reset(void) {
    return app_perform_render_session_reset();
}

/* Call regularly from the single-owner control core. Logical time is derived
 * directly from the wrapping millisecond counter. Only active voices are
 * visited by the runtime. */
int app_synth_service(uint32_t millisecond_count) {
    uint16_t slice_count;
    msf2_result result;
    if (app_diagnostics.fpga_session_ready == 0u) {
        app_control_job.active = 0u;
        app_last_control_millisecond = millisecond_count;
        return 0;
    }
    if (app_control_job.active == 0u) {
        const uint32_t elapsed_ticks =
            millisecond_count - app_last_control_millisecond;
        if (elapsed_ticks < APP_CONTROL_UPDATE_PERIOD_MS) return 0;
        app_control_job.target_millisecond = millisecond_count;
        app_control_job.start_millisecond = millisecond_count;
        app_control_job.elapsed_ticks = elapsed_ticks;
        app_control_job.voice_cursor = 0u;
        app_control_job.active = 1u;
        msf2_runtime_capture_control_snapshot(
            &app_runtime, app_control_job.voices,
            app_control_job.channel_dirty_revisions);
        if (app_runtime.active_count == 0u) {
            app_control_job.voice_cursor = APP_VOICE_COUNT;
        }
    }
    slice_count = (uint16_t)(APP_VOICE_COUNT - app_control_job.voice_cursor);
    if (slice_count > APP_CONTROL_VOICE_SLICE) {
        slice_count = APP_CONTROL_VOICE_SLICE;
    }
    result = slice_count == 0u ? MSF2_OK :
        msf2_runtime_advance_control_slice(
            &app_runtime, app_control_job.voices,
            app_control_job.voice_cursor, slice_count,
            app_control_job.elapsed_ticks);
    if (result != MSF2_OK) return -(int)result;
    app_control_job.voice_cursor =
        (uint16_t)(app_control_job.voice_cursor + slice_count);
    if (app_control_job.voice_cursor != APP_VOICE_COUNT) return 0;
    msf2_runtime_complete_control(
        &app_runtime, app_control_job.elapsed_ticks,
        app_control_job.channel_dirty_revisions);
    app_last_control_millisecond = app_control_job.target_millisecond;
    app_diagnostics.control_last_update_ms =
        app_control_job.target_millisecond;
    if (app_control_job.elapsed_ticks >
        app_diagnostics.control_maximum_interval_ms) {
        app_diagnostics.control_maximum_interval_ms =
            app_control_job.elapsed_ticks;
    }
    app_diagnostics.control_completed_ticks += app_control_job.elapsed_ticks;
    ++app_diagnostics.control_completed_jobs;
    {
        const uint32_t duration =
            millisecond_count - app_control_job.start_millisecond;
        if (duration > app_diagnostics.control_maximum_job_duration_ms) {
            app_diagnostics.control_maximum_job_duration_ms = duration;
        }
    }
    app_diagnostics.control_voice_evaluations =
        app_runtime.stats.control_voice_evaluations;
    app_diagnostics.controller_voice_updates =
        app_runtime.stats.controller_voice_updates;
    app_diagnostics.active_voices = app_runtime.stats.active_voices;
    app_diagnostics.maximum_active_voices =
        app_runtime.stats.maximum_active_voices;
    app_control_job.active = 0u;
    return 0;
}

int app_synth_monitor_transport(uint32_t millisecond_count) {
    uint32_t version = 0u;
    uint32_t platform_status = 0u;
    uint32_t sf2_size = 0u;
    uint32_t command_errors;
    uint32_t stale_generations;
    fpga_session_observation observation;
    transport_health_result health;
    int version_result = 0;
    int status_result = -1;
    int result;
    uint8_t recovered_session = 0u;
    if (millisecond_count - app_transport_monitor_millisecond < 100u) return 0;
    if (app_command_batch.word_count != 0u) return 0;
    if (platform_spi_wait_idle(UINT32_C(1000)) != 0) return 0;
    app_transport_monitor_millisecond = millisecond_count;
    if (app_diagnostics.fpga_session_ready != 0u) {
        version = APP_FPGA_INTERFACE_VERSION;
    } else {
        version_result = fpga_spi_read_register(
            app_spi_write, app_spi_exchange, NULL, UINT16_C(0x9000), &version,
            8u);
    }
    if (version_result == 0) {
        status_result = fpga_spi_read_register(
            app_spi_write, app_spi_exchange, NULL,
            APP_FPGA_PLATFORM_STATUS_ADDRESS, &platform_status, 8u);
    }
    observation = fpga_session_classify(
        version_result, version, APP_FPGA_INTERFACE_VERSION, status_result,
        platform_status);
    app_diagnostics.last_spi_result = version_result != 0 ? version_result :
                                      status_result;
    if (version_result == 0) app_diagnostics.version = version;
    if (status_result == 0) app_diagnostics.platform_status = platform_status;
    if (observation == FPGA_SESSION_UNREACHABLE) {
        ++app_diagnostics.transport_monitor_failures;
        if (++app_transport_monitor_consecutive_failures < 2u) return 0;
    } else {
        app_transport_monitor_consecutive_failures = 0u;
    }
    if (observation == FPGA_SESSION_UNREACHABLE ||
        observation == FPGA_SESSION_LOADING) {
        return app_mark_session_offline();
    }
    if (observation == FPGA_SESSION_PLATFORM_FAULT ||
        observation == FPGA_SESSION_INCOMPATIBLE) {
        return -(int)MSF2_ERR_PROFILE;
    }
    if (app_diagnostics.fpga_session_ready != 0u &&
        millisecond_count - app_transport_diagnostics_millisecond < 500u) {
        return 0;
    }
    if (app_diagnostics.fpga_session_ready == 0u) {
        result = fpga_spi_read_register(
            app_spi_write, app_spi_exchange, NULL, APP_FPGA_SF2_SIZE_ADDRESS,
            &sf2_size, 8u);
        if (result != 0) {
            ++app_diagnostics.transport_monitor_failures;
            return 0;
        }
        app_diagnostics.sf2_size = sf2_size;
        if (sf2_size != (uint32_t)app_view.source_size_bytes) {
            return -(int)MSF2_ERR_PROFILE;
        }
        result = app_perform_render_session_reset();
        if (result != 0) return 0;
        recovered_session = 1u;
        app_last_control_millisecond = millisecond_count;
    }
    app_transport_diagnostics_millisecond = millisecond_count;
    result = fpga_spi_read_register(
        app_spi_write, app_spi_exchange, NULL, APP_FPGA_COMMAND_ERROR_ADDRESS,
        &command_errors, 8u);
    if (result == 0) {
        result = fpga_spi_read_register(
            app_spi_write, app_spi_exchange, NULL,
            APP_FPGA_STALE_GENERATION_ADDRESS, &stale_generations, 8u);
    }
    if (result != 0) return 0;
    if (recovered_session != 0u) {
        app_diagnostics.command_error_count = command_errors;
        app_diagnostics.stale_generation_count = stale_generations;
        ++app_diagnostics.fpga_recovery_count;
        return 0;
    }
    health = transport_health_classify(
        app_diagnostics.command_error_count,
        app_diagnostics.stale_generation_count, command_errors,
        stale_generations);
    app_diagnostics.command_error_count = command_errors;
    app_diagnostics.stale_generation_count = stale_generations;
    if (health == TRANSPORT_HEALTH_COMMAND_FAULT) {
        return -(int)MSF2_ERR_SINK;
    }
    return 0;
}

int app_synth_session_ready(void) {
    return app_diagnostics.fpga_session_ready != 0u;
}

int app_midi_note_on(uint8_t channel, uint8_t key, uint8_t velocity) {
    uint8_t started_layers = 0u;
    msf2_result result;
    if (channel >= MSF2_CHANNEL_COUNT) return -(int)MSF2_ERR_ARGUMENT;
    result = midi_policy_note_on(&app_midi, channel, key, velocity,
                                 &started_layers);
    if (result != MSF2_OK) return -(int)result;
    return (int)started_layers; /* Zero means the selected preset/key was unmapped. */
}

int app_midi_note_off(uint8_t channel, uint8_t key) {
    return -(int)midi_policy_note_off(&app_midi, channel, key);
}

int app_midi_control_change(uint8_t channel, uint8_t controller, uint8_t value) {
    if (channel >= MSF2_CHANNEL_COUNT || controller > 127u || value > 127u) {
        return -(int)MSF2_ERR_ARGUMENT;
    }

    return -(int)midi_policy_control_change(&app_midi, channel, controller, value);
}

void app_midi_program_change(uint8_t channel, uint8_t program) {
    (void)midi_policy_program_change(&app_midi, channel, program);
}

int app_midi_pitch_bend(uint8_t channel, uint8_t lsb, uint8_t msb) {
    const int32_t unsigned_value = ((int32_t)(msb & 0x7fu) << 7) | (lsb & 0x7fu);
    return -(int)msf2_runtime_pitch_bend(&app_runtime, channel,
                                        (int16_t)(unsigned_value - 8192));
}

int app_midi_channel_pressure(uint8_t channel, uint8_t pressure) {
    return -(int)msf2_runtime_channel_pressure(&app_runtime, channel, pressure);
}

int app_midi_key_pressure(uint8_t channel, uint8_t key, uint8_t pressure) {
    return -(int)msf2_runtime_key_pressure(&app_runtime, channel, key, pressure);
}

int app_midi_system_reset(void) {
    return -(int)midi_policy_system_reset(&app_midi);
}

int app_midi_all_sound_off(void) {
    uint8_t channel;
    for (channel = 0u; channel < MSF2_CHANNEL_COUNT; ++channel) {
        msf2_result result = msf2_runtime_all_sound_off(&app_runtime, channel);
        if (result != MSF2_OK) return -(int)result;
    }
    return 0;
}

int app_midi_release_all(void) {
    return -(int)midi_policy_release_all(&app_midi);
}
