#ifndef MSF2_H
#define MSF2_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MSF2_MAX_LAYERS 4u
#define MSF2_MAX_VOICE_COUNT 512u
#define MSF2_GENERATOR_COUNT 61u
#define MSF2_CHANNEL_COUNT 16u
#define MSF2_MIDI_VALUE_COUNT 128u

typedef enum msf2_result {
    MSF2_OK = 0,
    MSF2_ERR_ARGUMENT,
    MSF2_ERR_HEADER,
    MSF2_ERR_PROFILE,
    MSF2_ERR_CRC,
    MSF2_ERR_DIRECTORY,
    MSF2_ERR_RECORD,
    MSF2_ERR_CAPACITY,
    MSF2_ERR_SINK
} msf2_result;

typedef struct msf2_section_view {
    const uint8_t *data;
    uint32_t count;
    uint32_t stride;
} msf2_section_view;

typedef struct msf2_view {
    const uint8_t *data;
    size_t size;
    msf2_section_view sections[7];
    uint64_t source_size_bytes;
    uint32_t source_crc32;
    uint32_t sample_word_offset;
    uint32_t sample_word_count;
    uint32_t selection_crc32;
} msf2_view;

typedef struct msf2_preset {
    uint16_t program;
    uint16_t bank;
    uint32_t first_zone;
    uint32_t zone_count;
} msf2_preset;

typedef struct msf2_zone {
    uint8_t key_low;
    uint8_t key_high;
    uint8_t velocity_low;
    uint8_t velocity_high;
    uint32_t first_generator;
    uint16_t generator_count;
    uint16_t sample_index;
    uint64_t generator_presence;
} msf2_zone;

typedef struct msf2_sample {
    uint32_t start;
    uint32_t end;
    uint32_t loop_start;
    uint32_t loop_end;
    uint32_t sample_rate;
    uint8_t original_pitch;
    int8_t pitch_correction;
} msf2_sample;

typedef struct msf2_layers {
    uint32_t zone_index[MSF2_MAX_LAYERS];
    uint8_t count;
} msf2_layers;

typedef struct msf2_note_params {
    uint32_t base_addr;
    uint32_t length;
    uint32_t loop_start;
    uint32_t loop_end;
    uint32_t phase_inc;
    uint16_t gain_l;
    uint16_t gain_r;
    uint8_t loop_mode;
    uint8_t filter_enable;
    int16_t filter_b0;
    int16_t filter_b1;
    int16_t filter_b2;
    int16_t filter_a1;
    int16_t filter_a2;
    uint32_t delay_samples;
    uint32_t attack_samples;
    uint32_t hold_samples;
    uint32_t decay_samples;
    uint32_t sustain_cb_q12_20;
    uint32_t release_samples;
} msf2_note_params;

/* Receives one complete command (header plus payload). The callback must copy
 * or consume the words before returning; the buffer is owned by the runtime.
 * Return zero on success. A nonzero return stops the current operation with
 * MSF2_ERR_SINK so firmware can apply its queue-overload policy. */
typedef int (*msf2_command_sink)(void *context, const uint32_t *words,
                                 uint8_t word_count);

typedef enum msf2_voice_stage {
    MSF2_VOICE_FREE = 0,
    MSF2_VOICE_ACTIVE,
    MSF2_VOICE_SUSTAIN_HELD,
    MSF2_VOICE_RELEASED
} msf2_voice_stage;

typedef struct msf2_channel_state {
    /* All storage is caller-owned and may live in static SRAM. Values are MIDI
     * native units except pitch_bend (-8192..8191). */
    uint8_t cc[MSF2_MIDI_VALUE_COUNT];
    uint8_t key_pressure[MSF2_MIDI_VALUE_COUNT];
    int16_t pitch_bend;
    uint8_t channel_pressure;
    uint8_t pitch_bend_range_semitones;
    uint8_t pitch_bend_range_cents;
    uint8_t sustain;
    uint8_t soft;
} msf2_channel_state;

typedef struct msf2_runtime_config {
    /* Immutable per-note generator conversion copied from temporary zone
     * decode storage. Delays and envelope durations are 1 ms control ticks;
     * LFO steps use the low 16 bits as one cycle. */
    /* LFO delay is in control ticks. Step is Q0.16 cycles per tick and wraps
     * naturally in the low 16 bits of the corresponding voice phase. */
    uint32_t mod_lfo_delay_ticks;
    uint32_t mod_lfo_step;
    uint32_t vib_lfo_delay_ticks;
    uint32_t vib_lfo_step;
    /* Generator depths retain native SoundFont units: pitch/filter in cents,
     * volume in centibels. */
    int16_t mod_lfo_to_pitch;
    int16_t vib_lfo_to_pitch;
    int16_t mod_env_to_pitch;
    int16_t mod_lfo_to_filter_fc;
    int16_t mod_env_to_filter_fc;
    int16_t mod_lfo_to_volume;
    /* Base low-pass cutoff is absolute cents; Q is centibels. */
    int16_t initial_filter_fc;
    int16_t initial_filter_q;
    /* Modulation-envelope durations are control ticks; sustain is Q1.15. */
    uint32_t mod_env_delay_ticks;
    uint32_t mod_env_hold_ticks;
    uint32_t mod_env_attack_ticks;
    uint32_t mod_env_decay_ticks;
    uint32_t mod_env_release_ticks;
    uint16_t mod_env_sustain_level;
    uint8_t mod_env_attack_sub_tick;
} msf2_runtime_config;

typedef struct msf2_voice_state {
    /* Continuing state for one hardware voice. No field points into a decoded
     * zone; only candidate identifies immutable records in the validated MSF2
     * image. Firmware allocates voice_capacity entries. */
    /* MIDI identity and FPGA stale-command generation. */
    uint8_t stage;
    uint8_t channel;
    uint8_t note;
    uint8_t velocity;
    uint8_t exclusive_class;
    int8_t effective_velocity;
    uint16_t generation;
    /* Immutable image identity plus monotonic allocation metadata. */
    uint32_t preset_index;
    uint32_t candidate;
    /* Remaining FPGA volume-envelope release lifetime and packed release step. */
    uint32_t release_samples;
    uint32_t release_step;
    /* Last emitted and unmodulated Q24.8 phase increments. */
    uint32_t phase_increment;
    uint32_t base_phase_increment;
    /* Last emitted gains, unpanned base gain, and base pan (-500..500). */
    uint16_t gain_l;
    uint16_t gain_r;
    uint16_t base_gain;
    int16_t pan;
    /* Oldest-instance Note Off and deterministic steal ordering. */
    uint32_t note_instance;
    uint32_t allocation_stamp;
    /* Continuing control-rate LFO and modulation-envelope state. */
    uint32_t mod_lfo_phase;
    uint32_t vib_lfo_phase;
    uint32_t mod_lfo_wait_ticks;
    uint32_t vib_lfo_wait_ticks;
    uint32_t mod_env_stage_tick;
    uint32_t mod_env_wait_ticks;
    uint16_t mod_env_level;
    uint16_t mod_env_release_start;
    uint8_t mod_env_stage;
    int32_t tremolo_attenuation_q16;
    /* Last emitted Q2.14 biquad configuration for change suppression. */
    uint8_t filter_enable;
    int16_t filter_b0;
    int16_t filter_b1;
    int16_t filter_b2;
    int16_t filter_a1;
    int16_t filter_a2;
    msf2_runtime_config config;
} msf2_voice_state;

typedef struct msf2_runtime_stats {
    /* Saturation is not applied to diagnostic counters. Firmware may reset the
     * complete structure at a quiescent point if wraparound matters. */
    uint32_t note_ons;
    uint32_t note_offs;
    uint32_t started_voices;
    uint32_t released_voices;
    uint32_t stopped_voices;
    uint32_t stolen_voices;
    uint32_t unmapped_notes;
    uint32_t controller_voice_updates;
    uint16_t active_voices;
    uint16_t maximum_active_voices;
} msf2_runtime_stats;

typedef struct msf2_runtime {
    /* Runtime descriptor over caller-owned channel, voice, and free-stack
     * arrays. The object performs no allocation and reads no wall clock. */
    const msf2_view *view;
    msf2_channel_state *channels;
    msf2_voice_state *voices;
    uint16_t *free_stack;
    uint16_t voice_capacity;
    uint16_t free_count;
    uint32_t next_note_instance;
    uint32_t allocation_stamp;
    uint32_t control_tick_index;
    uint32_t pending_tick_samples;
    msf2_command_sink command_sink;
    void *command_context;
    msf2_runtime_stats stats;
} msf2_runtime;

msf2_result msf2_view_init(msf2_view *view, const void *data, size_t size);
uint32_t msf2_preset_count(const msf2_view *view);
uint32_t msf2_zone_count(const msf2_view *view);
msf2_result msf2_get_preset(const msf2_view *view, uint32_t index,
                            msf2_preset *preset);
msf2_result msf2_get_zone(const msf2_view *view, uint32_t index,
                          msf2_zone *zone);
msf2_result msf2_get_sample(const msf2_view *view, uint32_t index,
                            msf2_sample *sample);
int32_t msf2_find_preset(const msf2_view *view, uint16_t program,
                         uint16_t bank);
msf2_result msf2_collect_layers(const msf2_view *view, uint32_t preset_index,
                                uint8_t key, uint8_t velocity,
                                msf2_layers *layers);
msf2_result msf2_decode_generators(const msf2_view *view, uint32_t zone_index,
                                   uint16_t amounts[MSF2_GENERATOR_COUNT],
                                   uint64_t *presence);
msf2_result msf2_materialize_note(const msf2_view *view, uint32_t zone_index,
                                  uint8_t key, msf2_note_params *params);
msf2_result msf2_pack_start(uint16_t voice, uint16_t generation,
                            const msf2_note_params *params,
                            uint32_t words[17], uint8_t *word_count);
/* Initializes a runtime and resets every supplied channel/voice element.
 * voice_capacity is both the array length and the legal allocator range. */
msf2_result msf2_runtime_init(msf2_runtime *runtime, const msf2_view *view,
                              msf2_channel_state channels[MSF2_CHANNEL_COUNT],
                              msf2_voice_state *voices, uint16_t *free_stack,
                              uint16_t voice_capacity, msf2_command_sink sink,
                              void *sink_context);
/* MIDI event entry points. note_on returns the number of started mono layers;
 * zero is a valid unmapped result. A velocity-zero Note On is a Note Off. */
msf2_result msf2_runtime_note_on(msf2_runtime *runtime, uint8_t channel,
                                 uint16_t program, uint16_t bank, uint8_t note,
                                 uint8_t velocity, uint8_t *started_layers);
msf2_result msf2_runtime_note_off(msf2_runtime *runtime, uint8_t channel,
                                  uint8_t note);
/* Every CC is retained as a SoundFont modulation source. CC64, CC67, and CC120
 * additionally implement sustain, soft pedal, and All Sound Off policy. This
 * API does not interpret RPN/NRPN selector/data-entry sequences. */
msf2_result msf2_runtime_control_change(msf2_runtime *runtime, uint8_t channel,
                                        uint8_t controller, uint8_t value);
msf2_result msf2_runtime_pitch_bend(msf2_runtime *runtime, uint8_t channel,
                                    int16_t value);
msf2_result msf2_runtime_channel_pressure(msf2_runtime *runtime, uint8_t channel,
                                          uint8_t value);
msf2_result msf2_runtime_key_pressure(msf2_runtime *runtime, uint8_t channel,
                                      uint8_t note, uint8_t value);
/* Advances elapsed audio time. The function accumulates partial intervals and
 * runs one modulation/control tick per 48 samples (1 ms at the bound 48 kHz
 * profile). The HAL may call it from an audio-frame counter and must serialize
 * it with MIDI event calls. Large sample counts catch up all elapsed ticks
 * deterministically. */
msf2_result msf2_runtime_advance_samples(msf2_runtime *runtime,
                                         uint32_t samples);
/* Convenience entry for a serialized 1 ms timer callback in the reference
 * profile. It is exactly equivalent to advance_samples(runtime, 48). */
msf2_result msf2_runtime_control_tick(msf2_runtime *runtime);
msf2_result msf2_runtime_all_sound_off(msf2_runtime *runtime, uint8_t channel);

#ifdef __cplusplus
}
#endif

#endif
