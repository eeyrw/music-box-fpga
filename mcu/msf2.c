#include "msf2.h"
#include "generated/msf2_lut.h"

#include <limits.h>

#define MSF2_HEADER_SIZE 96u
#define MSF2_DIRECTORY_OFFSET 96u
#define MSF2_SECTION_COUNT 7u
#define MSF2_DIRECTORY_ENTRY_SIZE 16u
#define MSF2_PROFILE_CRC32 UINT32_C(0xc0126f87)
#define MSF2_COMMAND_INTERFACE UINT32_C(0x000f0000)
#define MSF2_SAMPLE_RATE 48000u
#define MSF2_CONTROL_TICK_SAMPLES 48u
#define MSF2_VALID_DEPENDENCIES UINT16_C(0x001f)

static uint16_t read_u16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static uint32_t read_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t read_u64(const uint8_t *p) {
    return (uint64_t)read_u32(p) | ((uint64_t)read_u32(p + 4) << 32);
}

static uint32_t crc32_image(const uint8_t *data, size_t size) {
    uint32_t crc = UINT32_MAX;
    size_t index;
    for (index = 0; index < size; ++index) {
        uint32_t value = (index >= 36u && index < 40u) ? 0u : data[index];
        unsigned bit;
        crc ^= value;
        for (bit = 0; bit < 8u; ++bit) {
            crc = (crc >> 1) ^ ((crc & 1u) != 0u ? UINT32_C(0xedb88320) : 0u);
        }
    }
    return crc ^ UINT32_MAX;
}

static unsigned popcount64(uint64_t value) {
    unsigned count = 0;
    while (value != 0u) {
        value &= value - 1u;
        ++count;
    }
    return count;
}

static int range_fits(uint32_t first, uint32_t count, uint32_t total) {
    return first <= total && count <= total - first;
}

static const uint8_t *record(const msf2_view *view, unsigned section,
                             uint32_t index) {
    const msf2_section_view *value;
    if (view == NULL || section >= MSF2_SECTION_COUNT) return NULL;
    value = &view->sections[section];
    if (index >= value->count) return NULL;
    return value->data + (size_t)index * value->stride;
}

static uint16_t source_dependencies(uint16_t source) {
    unsigned index;
    if (source == 0u) return 0u;
    if ((source & UINT16_C(0x0080)) != 0u) return UINT16_C(0x0002);
    index = source & UINT16_C(0x007f);
    if (index == 2u || index == 3u) return UINT16_C(0x0001);
    if (index == 10u || index == 13u) return UINT16_C(0x0008);
    if (index == 14u) return UINT16_C(0x0004);
    if (index == 16u) return UINT16_C(0x0010);
    return 0u;
}

static int destination_matches(uint16_t destination, uint8_t family) {
    if (family == 0u) return destination == 13u || destination == 17u || destination == 48u;
    if (family == 1u) return destination == 0u || destination == 5u ||
                              destination == 6u || destination == 7u;
    return destination == 8u || destination == 10u || destination == 11u;
}

static int16_t signed_amount(uint16_t value) {
    return (int16_t)value;
}

static int has_generator(uint64_t presence, unsigned oper) {
    return (presence & (UINT64_C(1) << oper)) != 0u;
}

static int32_t clamp_i32(int32_t value, int32_t low, int32_t high) {
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

static uint32_t ratio_scaled_q24(uint64_t multiplier, uint32_t divisor,
                                 int64_t exponent_q24, uint32_t minimum) {
    int64_t octave = exponent_q24 / (INT64_C(1) << 24);
    int64_t fraction = exponent_q24 % (INT64_C(1) << 24);
    uint32_t table_index;
    uint32_t interpolation;
    uint64_t lower;
    uint64_t upper;
    uint64_t ratio;
    uint64_t numerator;
    uint64_t denominator = (UINT64_C(1) << 32) * divisor;
    uint64_t quotient;
    uint64_t residual;
    if (fraction < 0) {
        fraction += INT64_C(1) << 24;
        --octave;
    }
    table_index = (uint32_t)(fraction >> 16);
    interpolation = (uint32_t)(fraction & UINT32_C(0xffff));
    lower = (UINT64_C(1) << 32) |
            msf2_lut_exp2_fraction_q32[table_index];
    upper = table_index == 255u ? (UINT64_C(2) << 32) :
            ((UINT64_C(1) << 32) |
             msf2_lut_exp2_fraction_q32[table_index + 1u]);
    ratio = lower + (((upper - lower) * interpolation + UINT32_C(0x8000)) >> 16);
    if (multiplier != 0u && ratio > UINT64_MAX / multiplier) return UINT32_MAX;
    numerator = multiplier * ratio;
    quotient = numerator / denominator;
    residual = numerator % denominator;
    if (octave >= 0) {
        int64_t shift;
        if (octave >= 63) return UINT32_MAX;
        for (shift = 0; shift < octave; ++shift) {
            if (quotient > UINT32_MAX / 2u) return UINT32_MAX;
            quotient *= 2u;
            residual *= 2u;
            if (residual >= denominator) {
                residual -= denominator;
                ++quotient;
            }
        }
        if (residual * 2u >= denominator) ++quotient;
    } else {
        uint32_t shift = (uint32_t)(-octave);
        if (shift >= 63u) quotient = 0u;
        else {
            const uint64_t mask = (UINT64_C(1) << shift) - 1u;
            const uint64_t lower = quotient & mask;
            quotient >>= shift;
            if (lower >= (UINT64_C(1) << (shift - 1u))) ++quotient;
        }
    }
    if (quotient < minimum) return minimum;
    return quotient > UINT32_MAX ? UINT32_MAX : (uint32_t)quotient;
}

static int64_t cents_exponent_q24(int32_t cents) {
    return ((int64_t)cents << 24) / 1200;
}

static uint32_t timecent_samples(int32_t timecents, int present, int32_t maximum,
                                 uint32_t cap) {
    uint32_t value;
    if (!present) timecents = -12000;
    if (timecents <= INT16_MIN) return 0u;
    timecents = clamp_i32(timecents, -12000, maximum);
    value = ratio_scaled_q24(MSF2_LUT_SAMPLE_RATE, 1u,
                             cents_exponent_q24(timecents), 1u);
    if (value > cap) value = cap;
    return value;
}

static uint32_t clamp_position(int64_t value, uint32_t low, uint32_t high) {
    if (value < (int64_t)low) return low;
    if (value > (int64_t)high) return high;
    return (uint32_t)value;
}

static uint32_t pan_sine_q30(uint32_t position) {
    const uint32_t scaled = position * 256u;
    const uint32_t index = scaled / 1000u;
    const uint32_t fraction = scaled % 1000u;
    uint32_t lower;
    uint32_t upper;
    if (index >= 256u) return msf2_lut_pan_quarter_sine_q30[256];
    lower = msf2_lut_pan_quarter_sine_q30[index];
    upper = msf2_lut_pan_quarter_sine_q30[index + 1u];
    return lower + (uint32_t)(((uint64_t)(upper - lower) * fraction + 500u) / 1000u);
}

static uint32_t quarter_sine_index_q16(uint32_t index_q16) {
    uint32_t index = index_q16 >> 16;
    uint32_t fraction = index_q16 & UINT32_C(0xffff);
    uint32_t lower;
    uint32_t upper;
    if (index >= 256u) return msf2_lut_pan_quarter_sine_q30[256];
    lower = msf2_lut_pan_quarter_sine_q30[index];
    upper = msf2_lut_pan_quarter_sine_q30[index + 1u];
    return lower + (uint32_t)(((uint64_t)(upper - lower) * fraction + 0x8000u) >> 16);
}

static uint32_t sine_index_q16(uint32_t index_q16) {
    const uint32_t half_turn = 512u << 16;
    if (index_q16 > half_turn) index_q16 = half_turn;
    if (index_q16 <= (256u << 16)) return quarter_sine_index_q16(index_q16);
    return quarter_sine_index_q16(half_turn - index_q16);
}

static int32_t cosine_index_q16(uint32_t index_q16) {
    const uint32_t quarter_turn = 256u << 16;
    if (index_q16 <= quarter_turn) {
        return (int32_t)quarter_sine_index_q16(quarter_turn - index_q16);
    }
    return -(int32_t)quarter_sine_index_q16(index_q16 - quarter_turn);
}

static int32_t round_divide(int64_t numerator, uint64_t denominator) {
    if (numerator >= 0) return (int32_t)((numerator + (int64_t)(denominator / 2u)) /
                                        (int64_t)denominator);
    return (int32_t)((numerator - (int64_t)(denominator / 2u)) /
                     (int64_t)denominator);
}

static uint32_t ceil_divide(uint64_t numerator, uint32_t denominator) {
    if (denominator == 0u) return 0u;
    numerator = (numerator + denominator - 1u) / denominator;
    return numerator > UINT32_MAX ? UINT32_MAX : (uint32_t)numerator;
}

static uint32_t pack_pair(int32_t high, int32_t low) {
    return ((uint32_t)(uint16_t)high << 16) | (uint16_t)low;
}

uint32_t msf2_preset_count(const msf2_view *view) {
    return view == NULL ? 0u : view->sections[0].count;
}

uint32_t msf2_zone_count(const msf2_view *view) {
    return view == NULL ? 0u : view->sections[1].count;
}

msf2_result msf2_get_preset(const msf2_view *view, uint32_t index,
                            msf2_preset *preset) {
    const uint8_t *p = record(view, 0u, index);
    if (p == NULL || preset == NULL) return MSF2_ERR_ARGUMENT;
    preset->program = read_u16(p);
    preset->bank = read_u16(p + 2);
    preset->first_zone = read_u32(p + 4);
    preset->zone_count = read_u32(p + 8);
    return MSF2_OK;
}

msf2_result msf2_get_zone(const msf2_view *view, uint32_t index,
                          msf2_zone *zone) {
    const uint8_t *p = record(view, 1u, index);
    if (p == NULL || zone == NULL) return MSF2_ERR_ARGUMENT;
    zone->key_low = p[0];
    zone->key_high = p[1];
    zone->velocity_low = p[2];
    zone->velocity_high = p[3];
    zone->first_generator = read_u32(p + 4);
    zone->generator_count = read_u16(p + 8);
    zone->sample_index = read_u16(p + 10);
    zone->generator_presence = read_u64(p + 12);
    return MSF2_OK;
}

msf2_result msf2_get_sample(const msf2_view *view, uint32_t index,
                            msf2_sample *sample) {
    const uint8_t *p = record(view, 3u, index);
    if (p == NULL || sample == NULL) return MSF2_ERR_ARGUMENT;
    sample->start = read_u32(p);
    sample->end = read_u32(p + 4);
    sample->loop_start = read_u32(p + 8);
    sample->loop_end = read_u32(p + 12);
    sample->sample_rate = read_u32(p + 16);
    sample->original_pitch = p[20];
    sample->pitch_correction = (int8_t)p[21];
    return MSF2_OK;
}

msf2_result msf2_view_init(msf2_view *view, const void *raw, size_t size) {
    static const uint32_t strides[MSF2_SECTION_COUNT] = {12u, 20u, 2u, 22u, 3u, 12u, 12u};
    const uint8_t *data = (const uint8_t *)raw;
    uint64_t previous_end;
    uint32_t index;
    if (view == NULL || data == NULL) return MSF2_ERR_ARGUMENT;
    *view = (msf2_view){0};
    if (size < MSF2_HEADER_SIZE || data[0] != 'M' || data[1] != 'S' ||
        data[2] != 'F' || data[3] != '2' || read_u16(data + 4) != 2u ||
        read_u16(data + 6) != MSF2_HEADER_SIZE || read_u32(data + 8) != size) {
        return MSF2_ERR_HEADER;
    }
    if (read_u32(data + 12) != MSF2_COMMAND_INTERFACE ||
        read_u32(data + 16) != MSF2_SAMPLE_RATE ||
        read_u32(data + 20) != MSF2_CONTROL_TICK_SAMPLES ||
        read_u32(data + 56) != MSF2_PROFILE_CRC32) return MSF2_ERR_PROFILE;
    if (read_u32(data + 36) != crc32_image(data, size)) return MSF2_ERR_CRC;
    if (read_u32(data + 40) != MSF2_DIRECTORY_OFFSET ||
        read_u16(data + 44) != MSF2_SECTION_COUNT || read_u32(data + 60) != 1u ||
        size < MSF2_DIRECTORY_OFFSET + MSF2_SECTION_COUNT * MSF2_DIRECTORY_ENTRY_SIZE) {
        return MSF2_ERR_DIRECTORY;
    }
    view->data = data;
    view->size = size;
    view->source_size_bytes = read_u64(data + 24);
    view->source_crc32 = read_u32(data + 32);
    view->sample_word_offset = read_u32(data + 48);
    view->sample_word_count = read_u32(data + 52);
    view->selection_crc32 = read_u32(data + 64);
    if (((uint64_t)view->sample_word_offset + view->sample_word_count) * 2u >
        view->source_size_bytes) return MSF2_ERR_RECORD;
    previous_end = MSF2_HEADER_SIZE + MSF2_SECTION_COUNT * MSF2_DIRECTORY_ENTRY_SIZE;
    for (index = 0u; index < MSF2_SECTION_COUNT; ++index) {
        const uint8_t *entry = data + MSF2_DIRECTORY_OFFSET + index * MSF2_DIRECTORY_ENTRY_SIZE;
        uint32_t offset = read_u32(entry + 4);
        uint32_t count = read_u32(entry + 8);
        uint32_t stride = read_u32(entry + 12);
        uint64_t end = (uint64_t)offset + (uint64_t)count * stride;
        if (read_u16(entry) != index + 1u || read_u16(entry + 2) != 1u ||
            stride != strides[index] || (offset & 3u) != 0u ||
            offset < previous_end || end > size) return MSF2_ERR_DIRECTORY;
        view->sections[index].data = data + offset;
        view->sections[index].count = count;
        view->sections[index].stride = stride;
        previous_end = end;
    }
    if (read_u32(data + 68) != view->sections[0].count ||
        view->sections[4].count != view->sections[1].count) return MSF2_ERR_RECORD;
    for (index = 0u; index < view->sections[0].count; ++index) {
        msf2_preset preset;
        (void)msf2_get_preset(view, index, &preset);
        if (preset.program > 127u || preset.bank > 16383u ||
            !range_fits(preset.first_zone, preset.zone_count, view->sections[1].count)) {
            return MSF2_ERR_RECORD;
        }
    }
    for (index = 0u; index < view->sections[1].count; ++index) {
        msf2_zone zone;
        const uint64_t valid_presence = ((UINT64_C(1) << 61) - 1u) &
            ~(UINT64_C(1) << 43) & ~(UINT64_C(1) << 44) & ~(UINT64_C(1) << 53);
        (void)msf2_get_zone(view, index, &zone);
        if (zone.key_low > zone.key_high || zone.key_high > 127u ||
            zone.velocity_low > zone.velocity_high || zone.velocity_high > 127u ||
            zone.generator_count > MSF2_GENERATOR_COUNT ||
            zone.sample_index >= view->sections[3].count ||
            (zone.generator_presence & ~valid_presence) != 0u ||
            popcount64(zone.generator_presence) != zone.generator_count ||
            !range_fits(zone.first_generator, zone.generator_count, view->sections[2].count)) {
            return MSF2_ERR_RECORD;
        }
    }
    for (index = 0u; index < view->sections[3].count; ++index) {
        msf2_sample sample;
        (void)msf2_get_sample(view, index, &sample);
        if (sample.start > sample.end || sample.end > view->sample_word_count ||
            sample.loop_start < sample.start || sample.loop_start > sample.loop_end ||
            sample.loop_end > sample.end || sample.sample_rate == 0u) return MSF2_ERR_RECORD;
    }
    for (index = 0u; index < view->sections[4].count; ++index) {
        const uint8_t *refs = record(view, 4u, index);
        unsigned family;
        for (family = 0u; family < 3u; ++family) {
            if (refs[family] != UINT8_MAX && refs[family] >= view->sections[5].count) {
                return MSF2_ERR_RECORD;
            }
        }
    }
    for (index = 0u; index < view->sections[5].count; ++index) {
        const uint8_t *program = record(view, 5u, index);
        uint32_t first = read_u32(program);
        uint16_t count = read_u16(program + 4);
        uint16_t note_count = read_u16(program + 6);
        uint16_t expected_or = read_u16(program + 8);
        uint16_t observed_or = 0u;
        uint8_t family = program[10];
        uint32_t local;
        if (family > 2u || program[11] != 0u || note_count > count ||
            (expected_or & ~MSF2_VALID_DEPENDENCIES) != 0u ||
            !range_fits(first, count, view->sections[6].count)) return MSF2_ERR_RECORD;
        for (local = 0u; local < count; ++local) {
            const uint8_t *term = record(view, 6u, first + local);
            uint16_t dependencies = read_u16(term + 10);
            uint16_t calculated = source_dependencies(read_u16(term)) |
                                  source_dependencies(read_u16(term + 6));
            if (!destination_matches(read_u16(term + 2), family) ||
                (read_u16(term + 8) != 0u && read_u16(term + 8) != 2u) ||
                dependencies != calculated ||
                (local < note_count && (dependencies & ~UINT16_C(0x0001)) != 0u)) {
                return MSF2_ERR_RECORD;
            }
            observed_or |= dependencies;
        }
        if (observed_or != expected_or) return MSF2_ERR_RECORD;
    }
    return MSF2_OK;
}

int32_t msf2_find_preset(const msf2_view *view, uint16_t program, uint16_t bank) {
    uint32_t index;
    if (view == NULL || program > 127u || bank > 16383u) return -1;
    for (index = 0u; index < view->sections[0].count; ++index) {
        msf2_preset preset;
        (void)msf2_get_preset(view, index, &preset);
        if (preset.program == program && preset.bank == bank) return (int32_t)index;
    }
    return -1;
}

msf2_result msf2_collect_layers(const msf2_view *view, uint32_t preset_index,
                                uint8_t key, uint8_t velocity,
                                msf2_layers *layers) {
    msf2_preset preset;
    uint32_t local;
    if (layers == NULL || key > 127u || velocity > 127u ||
        msf2_get_preset(view, preset_index, &preset) != MSF2_OK) return MSF2_ERR_ARGUMENT;
    layers->count = 0u;
    for (local = 0u; local < preset.zone_count; ++local) {
        uint32_t index = preset.first_zone + local;
        msf2_zone zone;
        (void)msf2_get_zone(view, index, &zone);
        if (key < zone.key_low || key > zone.key_high ||
            velocity < zone.velocity_low || velocity > zone.velocity_high) continue;
        if (layers->count == MSF2_MAX_LAYERS) return MSF2_ERR_CAPACITY;
        layers->zone_index[layers->count++] = index;
    }
    return MSF2_OK;
}

msf2_result msf2_decode_generators(const msf2_view *view, uint32_t zone_index,
                                   uint16_t amounts[MSF2_GENERATOR_COUNT],
                                   uint64_t *presence) {
    msf2_zone zone;
    uint32_t amount_index = 0u;
    unsigned oper;
    if (amounts == NULL || msf2_get_zone(view, zone_index, &zone) != MSF2_OK) {
        return MSF2_ERR_ARGUMENT;
    }
    for (oper = 0u; oper < MSF2_GENERATOR_COUNT; ++oper) amounts[oper] = 0u;
    for (oper = 0u; oper < MSF2_GENERATOR_COUNT; ++oper) {
        if ((zone.generator_presence & (UINT64_C(1) << oper)) == 0u) continue;
        amounts[oper] = read_u16(record(view, 2u, zone.first_generator + amount_index));
        ++amount_index;
    }
    if (presence != NULL) *presence = zone.generator_presence;
    return MSF2_OK;
}

msf2_result msf2_materialize_note(const msf2_view *view, uint32_t zone_index,
                                  uint8_t key, msf2_note_params *params) {
    uint16_t gen[MSF2_GENERATOR_COUNT];
    uint64_t presence;
    msf2_zone zone;
    msf2_sample sample;
    uint32_t start;
    uint32_t end;
    uint32_t loop_start;
    uint32_t loop_end;
    int32_t effective_key;
    int32_t root_key;
    int32_t scale_tuning;
    int32_t cents;
    int32_t pan;
    int32_t attenuation;
    uint32_t pan_index;
    int32_t hold_tc;
    int32_t decay_tc;
    int32_t sustain_cb;
    int32_t cutoff_cents;
    int32_t resonance_cb;
    if (params == NULL || key > 127u ||
        msf2_get_zone(view, zone_index, &zone) != MSF2_OK ||
        msf2_get_sample(view, zone.sample_index, &sample) != MSF2_OK ||
        msf2_decode_generators(view, zone_index, gen, &presence) != MSF2_OK) {
        return MSF2_ERR_ARGUMENT;
    }
    *params = (msf2_note_params){0};
    start = clamp_position((int64_t)sample.start + signed_amount(gen[0]) +
                           (int64_t)signed_amount(gen[4]) * 32768, sample.start, sample.end);
    end = clamp_position((int64_t)sample.end + signed_amount(gen[1]) +
                         (int64_t)signed_amount(gen[12]) * 32768, start, sample.end);
    loop_start = clamp_position((int64_t)sample.loop_start + signed_amount(gen[2]) +
                                (int64_t)signed_amount(gen[45]) * 32768, start, end);
    loop_end = clamp_position((int64_t)sample.loop_end + signed_amount(gen[3]) +
                              (int64_t)signed_amount(gen[50]) * 32768, loop_start, end);
    params->base_addr = view->sample_word_offset + start;
    params->length = end - start;
    if (params->length > UINT32_C(0x00ffffff)) params->length = UINT32_C(0x00ffffff);
    params->loop_start = loop_start > start ? loop_start - start : 0u;
    if (params->loop_start >= params->length && params->length != 0u) {
        params->loop_start = params->length - 1u;
    }
    params->loop_end = loop_end > start ? loop_end - start : 0u;
    if (params->loop_end > params->length) params->loop_end = params->length;
    if (params->loop_end <= params->loop_start) params->loop_end = params->loop_start + 1u;
    if (params->loop_start >= params->loop_end || params->loop_end > params->length) {
        params->loop_start = 0u;
        params->loop_end = params->length;
    }
    params->loop_mode = (uint8_t)(gen[54] & 3u);
    if (params->loop_mode == 3u) params->loop_mode = 2u;
    else if (params->loop_mode != 1u) params->loop_mode = 0u;

    effective_key = key;
    if (has_generator(presence, 46u) && signed_amount(gen[46]) >= 0 &&
        signed_amount(gen[46]) <= 127) effective_key = signed_amount(gen[46]);
    root_key = sample.original_pitch <= 127u ? sample.original_pitch : 60;
    if (has_generator(presence, 58u) && signed_amount(gen[58]) >= 0 &&
        signed_amount(gen[58]) <= 127) root_key = signed_amount(gen[58]);
    scale_tuning = has_generator(presence, 56u) ? signed_amount(gen[56]) : 100;
    scale_tuning = clamp_i32(scale_tuning, 0, 1200);
    cents = (effective_key - root_key) * scale_tuning + sample.pitch_correction;
    if (has_generator(presence, 52u)) cents += signed_amount(gen[52]);
    if (has_generator(presence, 51u)) cents += signed_amount(gen[51]) * 100;
    params->phase_inc = ratio_scaled_q24((uint64_t)sample.sample_rate * 256u,
                                         MSF2_LUT_SAMPLE_RATE,
                                         cents_exponent_q24(cents), 1u);

    attenuation = has_generator(presence, 48u) ? signed_amount(gen[48]) : 0;
    attenuation = clamp_i32(attenuation, 0, 3600);
    pan = has_generator(presence, 17u) ? signed_amount(gen[17]) : 0;
    pan = clamp_i32(pan, -500, 500);
    pan_index = (uint32_t)(pan + 500);
    {
        const uint64_t right_q30 = pan_sine_q30(pan_index);
        const uint64_t left_q30 = pan_sine_q30(1000u - pan_index);
        const uint32_t base_gain = ratio_scaled_q24(0x4000u, 1u,
            -(int64_t)attenuation * 111465, 0u);
        params->gain_l = (uint16_t)((base_gain * left_q30 + (UINT64_C(1) << 29)) >> 30);
    params->gain_r = (uint16_t)((base_gain * right_q30 + (UINT64_C(1) << 29)) >> 30);
    }

    cutoff_cents = has_generator(presence, 8u) ? signed_amount(gen[8]) : 13500;
    cutoff_cents = clamp_i32(cutoff_cents, 1500, 13500);
    resonance_cb = has_generator(presence, 9u) ? signed_amount(gen[9]) : 0;
    resonance_cb = clamp_i32(resonance_cb, 0, 960);
    {
        const uint32_t angle_q16 = ratio_scaled_q24(
            UINT64_C(548682072), MSF2_LUT_SAMPLE_RATE,
            cents_exponent_q24(cutoff_cents), 0u);
        const int32_t sin_q30 = (int32_t)sine_index_q16(angle_q16);
        const int32_t cos_q30 = cosine_index_q16(angle_q16);
        const uint32_t inv_2q_q30 = ratio_scaled_q24(
            UINT32_C(759250125), 1u, -(int64_t)resonance_cb * 278664, 0u);
        const int32_t alpha_q30 = (int32_t)(((int64_t)sin_q30 * inv_2q_q30 +
                                             (INT64_C(1) << 29)) >> 30);
        const uint64_t a0_q30 = (UINT64_C(1) << 30) + alpha_q30;
        const int64_t one_minus_cos = (INT64_C(1) << 30) - cos_q30;
        params->filter_enable = 1u;
        params->filter_b0 = (int16_t)round_divide(one_minus_cos * 8192, a0_q30);
        params->filter_b1 = (int16_t)round_divide(one_minus_cos * 16384, a0_q30);
        params->filter_b2 = params->filter_b0;
        params->filter_a1 = (int16_t)round_divide(-(int64_t)cos_q30 * 32768, a0_q30);
        params->filter_a2 = (int16_t)round_divide(
            ((INT64_C(1) << 30) - alpha_q30) * 16384, a0_q30);
    }

    params->delay_samples = timecent_samples(signed_amount(gen[33]),
        has_generator(presence, 33u), 5000, UINT32_C(0x00ffffff));
    params->attack_samples = timecent_samples(signed_amount(gen[34]),
        has_generator(presence, 34u), 8000, UINT32_MAX);
    hold_tc = has_generator(presence, 35u) ? signed_amount(gen[35]) : 0;
    if (has_generator(presence, 39u)) hold_tc += signed_amount(gen[39]) * (60 - key);
    params->hold_samples = timecent_samples(hold_tc,
        has_generator(presence, 35u) || has_generator(presence, 39u),
        5000, UINT32_C(0x00ffffff));
    decay_tc = has_generator(presence, 36u) ? signed_amount(gen[36]) : 0;
    if (has_generator(presence, 40u)) decay_tc += signed_amount(gen[40]) * (60 - key);
    sustain_cb = has_generator(presence, 37u) ? signed_amount(gen[37]) : 0;
    sustain_cb = clamp_i32(sustain_cb, 0, 1440);
    if ((!has_generator(presence, 36u) && !has_generator(presence, 40u)) ||
        decay_tc <= INT16_MIN || sustain_cb == 0) {
        params->decay_samples = 0u;
    } else {
        uint32_t fraction = (uint32_t)(sustain_cb > 1000 ? 1000 : sustain_cb);
        decay_tc = clamp_i32(decay_tc, -12000, 8000);
        params->decay_samples = ratio_scaled_q24(
            (uint64_t)MSF2_LUT_SAMPLE_RATE * fraction, 1000u,
            cents_exponent_q24(decay_tc), 1u);
    }
    params->sustain_cb_q12_20 = (uint32_t)(sustain_cb > 1000 ? 1000 : sustain_cb) << 20;
    params->release_samples = timecent_samples(signed_amount(gen[38]),
        has_generator(presence, 38u), 8000, UINT32_MAX);
    return MSF2_OK;
}

msf2_result msf2_pack_start(uint16_t voice, uint16_t generation,
                            const msf2_note_params *params,
                            uint32_t words[17], uint8_t *word_count) {
    uint8_t flags;
    uint8_t payload_words;
    uint8_t count = 0u;
    int has_loop;
    int has_envelope;
    if (params == NULL || words == NULL || word_count == NULL || voice >= 512u) {
        return MSF2_ERR_ARGUMENT;
    }
    has_loop = params->loop_mode != 0u;
    has_envelope = params->delay_samples != 0u || params->attack_samples != 0u ||
        params->hold_samples != 0u || params->decay_samples != 0u ||
        params->sustain_cb_q12_20 != 0u || params->release_samples != 0u;
    flags = params->loop_mode & 3u;
    if (params->filter_enable != 0u) flags |= 1u << 2;
    if (has_envelope) flags |= 1u << 3;
    payload_words = (uint8_t)(5u + (has_loop ? 2u : 0u) +
        (params->filter_enable != 0u ? 3u : 0u) + (has_envelope ? 6u : 0u));
    words[count++] = (UINT32_C(0x10) << 24) | ((uint32_t)voice << 14) |
                     ((uint32_t)flags << 8) | payload_words;
    words[count++] = generation;
    words[count++] = params->base_addr;
    words[count++] = params->length;
    if (has_loop) {
        words[count++] = params->loop_start;
        words[count++] = params->loop_end;
    }
    words[count++] = params->phase_inc;
    words[count++] = pack_pair(params->gain_r, params->gain_l);
    if (params->filter_enable != 0u) {
        words[count++] = pack_pair(params->filter_b1, params->filter_b0);
        words[count++] = pack_pair(params->filter_a1, params->filter_b2);
        words[count++] = (uint16_t)params->filter_a2 | UINT32_C(0x00010000);
    }
    if (has_envelope) {
        words[count++] = params->delay_samples;
        words[count++] = ceil_divide(UINT32_MAX, params->attack_samples);
        words[count++] = params->hold_samples;
        words[count++] = ceil_divide(params->sustain_cb_q12_20, params->decay_samples);
        words[count++] = params->sustain_cb_q12_20;
        words[count++] = ceil_divide(UINT64_C(1000) << 20, params->release_samples);
    }
    *word_count = count;
    return MSF2_OK;
}
