#ifndef SYNTH_CONTROLLER_H
#define SYNTH_CONTROLLER_H

#include <stdint.h>

#ifndef APP_ENABLE_DETAILED_DIAGNOSTICS
#define APP_ENABLE_DETAILED_DIAGNOSTICS 0
#endif

typedef struct {
    int init_result;
    int last_spi_result;
    int flush_result;
    int session_reset_result;
    uint32_t register_attempts;
    uint32_t version;
    uint32_t platform_status;
    uint32_t sf2_size;
    uint32_t control_last_update_ms;
    uint32_t control_maximum_interval_ms;
    uint32_t control_completed_ticks;
    uint32_t control_completed_jobs;
    uint32_t control_maximum_job_duration_ms;
    uint32_t control_voice_evaluations;
    uint32_t controller_voice_updates;
    uint16_t active_voices;
    uint16_t maximum_active_voices;
    uint16_t static_voices;
    uint16_t periodic_gain_voices;
    uint16_t periodic_pitch_voices;
    uint16_t periodic_filter_voices;
    uint32_t command_error_count;
    uint32_t stale_generation_count;
    uint32_t session_epoch;
    uint32_t session_reset_count;
    uint32_t transport_monitor_failures;
    uint32_t fpga_disconnect_count;
    uint32_t fpga_recovery_count;
    uint8_t fpga_session_ready;
} app_synth_diagnostics;

#if APP_ENABLE_DETAILED_DIAGNOSTICS
#define APP_SYNTH_DEBUG_MAX_COMMAND_WORDS 17u
typedef struct {
    uint32_t sequence;
    uint8_t word_count;
    uint32_t words[APP_SYNTH_DEBUG_MAX_COMMAND_WORDS];
} app_synth_command_snapshot;
#endif

int app_synth_init(void);
const app_synth_diagnostics *app_synth_get_diagnostics(void);
int app_fpga_debug_read_register(uint16_t address, uint32_t *data);
#if APP_ENABLE_DETAILED_DIAGNOSTICS
const app_synth_command_snapshot *app_synth_get_last_start(void);
int app_fpga_debug_write_register(uint16_t address, uint32_t data);
int app_fpga_debug_read_ddr_line(uint32_t byte_address, uint32_t data[4]);
#endif
int app_fpga_debug_flush(void);
int app_synth_render_session_reset(void);
int app_synth_service(uint32_t millisecond_count);
int app_synth_monitor_transport(uint32_t millisecond_count);
int app_synth_session_ready(void);
int app_synth_flush_commands(void);
int app_midi_note_on(uint8_t channel, uint8_t key, uint8_t velocity);
int app_midi_note_off(uint8_t channel, uint8_t key);
int app_midi_control_change(uint8_t channel, uint8_t controller, uint8_t value);
void app_midi_program_change(uint8_t channel, uint8_t program);
int app_midi_pitch_bend(uint8_t channel, uint8_t lsb, uint8_t msb);
int app_midi_channel_pressure(uint8_t channel, uint8_t pressure);
int app_midi_key_pressure(uint8_t channel, uint8_t key, uint8_t pressure);
int app_midi_system_reset(void);
int app_midi_all_sound_off(void);
int app_midi_release_all(void);

#endif
