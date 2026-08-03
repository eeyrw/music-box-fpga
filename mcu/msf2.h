#ifndef MSF2_H
#define MSF2_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MSF2_MAX_LAYERS 4u
#define MSF2_GENERATOR_COUNT 61u

typedef enum msf2_result {
    MSF2_OK = 0,
    MSF2_ERR_ARGUMENT,
    MSF2_ERR_HEADER,
    MSF2_ERR_PROFILE,
    MSF2_ERR_CRC,
    MSF2_ERR_DIRECTORY,
    MSF2_ERR_RECORD,
    MSF2_ERR_CAPACITY
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

#ifdef __cplusplus
}
#endif

#endif
