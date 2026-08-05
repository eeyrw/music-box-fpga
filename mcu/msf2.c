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
        if (msf2_get_preset(view, index, &preset) != MSF2_OK) return -1;
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
        msf2_result result = msf2_get_zone(view, index, &zone);
        if (result != MSF2_OK) return result;
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
    if (params == NULL || words == NULL || word_count == NULL ||
        voice >= MSF2_MAX_VOICE_COUNT) {
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

#define MSF2_MOD_ONE INT32_C(65536)
#define MSF2_GAIN_GROUP 1u
#define MSF2_PITCH_GROUP 2u
#define MSF2_FILTER_GROUP 4u
#define MSF2_ENV_DELAY 1u
#define MSF2_ENV_ATTACK 2u
#define MSF2_ENV_HOLD 3u
#define MSF2_ENV_DECAY 4u
#define MSF2_ENV_SUSTAIN 5u
#define MSF2_ENV_RELEASE 6u

/* Convert SoundFont timecents to the profile's 1 ms control domain. The audio
 * volume envelope remains sample-rate FPGA state; these tick counts drive only
 * MCU-owned modulation envelopes and LFO delay. Rounding is performed after
 * conversion to samples so it follows the same profile-bound time base as the
 * START materializer. */
static uint32_t rounded_ticks(int32_t timecents, int present, int32_t maximum,
                              int minimum_one) {
    uint32_t samples = timecent_samples(timecents, present, maximum, UINT32_MAX);
    uint32_t ticks;
    if (samples == 0u) return minimum_one != 0 ? 1u : 0u;
    ticks = (samples + MSF2_CONTROL_TICK_SAMPLES / 2u) /
            MSF2_CONTROL_TICK_SAMPLES;
    if (minimum_one != 0 && ticks == 0u) ticks = 1u;
    return ticks;
}

static uint32_t scaled_ticks(int32_t timecents, int present, int32_t amount) {
    uint32_t samples;
    uint64_t numerator;
    if (amount <= 0) return 1u;
    samples = timecent_samples(timecents, present, 8000, UINT32_MAX);
    numerator = (uint64_t)samples * (uint32_t)amount;
    numerator += (uint64_t)MSF2_CONTROL_TICK_SAMPLES * 500u;
    numerator /= (uint64_t)MSF2_CONTROL_TICK_SAMPLES * 1000u;
    if (numerator == 0u) return 1u;
    return numerator > UINT32_MAX ? UINT32_MAX : (uint32_t)numerator;
}

static uint32_t lfo_step_from_cents(int32_t cents) {
    return ratio_scaled_q24(UINT64_C(8176) * MSF2_CONTROL_TICK_SAMPLES * 65536u,
                            MSF2_SAMPLE_RATE * 1000u,
                            cents_exponent_q24(cents), 0u);
}

static void runtime_config_from_generators(const uint16_t gen[MSF2_GENERATOR_COUNT],
                                           uint64_t presence, uint8_t key,
                                           msf2_runtime_config *config) {
    int32_t hold_tc;
    int32_t decay_tc;
    int32_t sustain;
    uint32_t attack_samples;
    /* This copies every continuing generator-derived value into the voice.
     * gen[] is stack-local decode storage and must not escape Note On. */
    *config = (msf2_runtime_config){0};
    config->mod_lfo_delay_ticks = rounded_ticks(signed_amount(gen[21]),
        has_generator(presence, 21u), 5000, 0);
    config->mod_lfo_step = lfo_step_from_cents(
        has_generator(presence, 22u) ? signed_amount(gen[22]) : 0);
    config->vib_lfo_delay_ticks = rounded_ticks(signed_amount(gen[23]),
        has_generator(presence, 23u), 5000, 0);
    config->vib_lfo_step = lfo_step_from_cents(
        has_generator(presence, 24u) ? signed_amount(gen[24]) : 0);
    config->mod_lfo_to_pitch = has_generator(presence, 5u) ? signed_amount(gen[5]) : 0;
    config->vib_lfo_to_pitch = has_generator(presence, 6u) ? signed_amount(gen[6]) : 0;
    config->mod_env_to_pitch = has_generator(presence, 7u) ? signed_amount(gen[7]) : 0;
    config->mod_lfo_to_filter_fc = has_generator(presence, 10u) ? signed_amount(gen[10]) : 0;
    config->mod_env_to_filter_fc = has_generator(presence, 11u) ? signed_amount(gen[11]) : 0;
    config->mod_lfo_to_volume = has_generator(presence, 13u) ? signed_amount(gen[13]) : 0;
    config->initial_filter_fc = has_generator(presence, 8u) ? signed_amount(gen[8]) : 13500;
    config->initial_filter_q = has_generator(presence, 9u) ? signed_amount(gen[9]) : 0;
    config->mod_env_delay_ticks = rounded_ticks(signed_amount(gen[25]),
        has_generator(presence, 25u), 5000, 0);
    attack_samples = timecent_samples(signed_amount(gen[26]),
        has_generator(presence, 26u), 8000, UINT32_MAX);
    config->mod_env_attack_ticks = rounded_ticks(signed_amount(gen[26]),
        has_generator(presence, 26u), 8000, 1);
    config->mod_env_attack_sub_tick = attack_samples < MSF2_CONTROL_TICK_SAMPLES;
    hold_tc = has_generator(presence, 27u) ? signed_amount(gen[27]) : 0;
    if (has_generator(presence, 31u)) hold_tc += signed_amount(gen[31]) * (60 - key);
    config->mod_env_hold_ticks = rounded_ticks(hold_tc,
        has_generator(presence, 27u) || has_generator(presence, 31u), 5000, 0);
    decay_tc = has_generator(presence, 28u) ? signed_amount(gen[28]) : 0;
    if (has_generator(presence, 32u)) decay_tc += signed_amount(gen[32]) * (60 - key);
    sustain = has_generator(presence, 29u) ? signed_amount(gen[29]) : 0;
    sustain = clamp_i32(sustain, 0, 1000);
    config->mod_env_decay_ticks = scaled_ticks(decay_tc,
        has_generator(presence, 28u) || has_generator(presence, 32u), sustain);
    config->mod_env_release_ticks = rounded_ticks(signed_amount(gen[30]),
        has_generator(presence, 30u), 8000, 1);
    config->mod_env_sustain_level = (uint16_t)(((uint32_t)(1000 - sustain) *
                                                32767u + 500u) / 1000u);
}

static uint8_t source_curve_id(uint16_t source) {
    return (uint8_t)(((source >> 10) & 3u) |
        ((source & UINT16_C(0x0200)) != 0u ? 4u : 0u) |
        ((source & UINT16_C(0x0100)) != 0u ? 8u : 0u));
}

static int32_t source_value_q16(uint16_t source,
                                const msf2_channel_state *channel,
                                const msf2_voice_state *voice) {
    unsigned index;
    unsigned native = 0u;
    /* SoundFont source encodings are evaluated in signed Q16.16. Source zero
     * is the multiplicative identity. Curved 7-bit sources use generated data
     * so the control path never calls floating point or libm. */
    if (source == 0u) return MSF2_MOD_ONE;
    index = source & UINT16_C(0x007f);
    if ((source & UINT16_C(0x0080)) == 0u && index == 14u) {
        int32_t value = (int32_t)channel->pitch_bend * 8;
        return (source & UINT16_C(0x0100)) != 0u ? -value : value;
    }
    if ((source & UINT16_C(0x0080)) == 0u && index == 16u) {
        int32_t hundredths = (int32_t)channel->pitch_bend_range_semitones * 100 +
                             channel->pitch_bend_range_cents;
        int32_t value = (hundredths * MSF2_MOD_ONE + 50) / 100;
        if (value < 0) value = 0;
        if (value > 127 * MSF2_MOD_ONE) value = 127 * MSF2_MOD_ONE;
        if ((source & UINT16_C(0x0100)) != 0u) value = 127 * MSF2_MOD_ONE - value;
        return value / 128;
    }
    if ((source & UINT16_C(0x0080)) != 0u) native = channel->cc[index];
    else if (index == 2u) native = voice->effective_velocity >= 0 ?
        (uint8_t)voice->effective_velocity : voice->velocity;
    else if (index == 3u) native = voice->note;
    else if (index == 10u) native = channel->key_pressure[voice->note];
    else if (index == 13u) native = channel->channel_pressure;
    if (index == 2u && native == 0u) native = 1u;
    return msf2_lut_source_curve_q16[source_curve_id(source)][native];
}

static int64_t multiply_q16(int64_t a, int64_t b) {
    int64_t product = a * b;
    return (product + (product >= 0 ? INT64_C(32768) : -INT64_C(32768))) /
           MSF2_MOD_ONE;
}

static int64_t destination_sum_q16(const msf2_runtime *runtime,
                                   const msf2_voice_state *voice,
                                   uint8_t program_id, uint16_t destination,
                                   int include_note_sources) {
    const uint8_t *program;
    uint32_t first;
    uint16_t count;
    uint16_t local;
    int64_t sum = 0;
    /* Programs and terms remain in immutable MSF2 storage. Only scalar source
     * state and final sums are copied into SRAM, bounding per-tick work by the
     * verified term_count in the image. */
    if (program_id == UINT8_MAX) return 0;
    program = record(runtime->view, 5u, program_id);
    first = read_u32(program);
    count = read_u16(program + 4);
    for (local = 0u; local < count; ++local) {
        const uint8_t *term = record(runtime->view, 6u, first + local);
        int32_t source_value;
        int32_t amount_value;
        int64_t value;
        if (read_u16(term + 2) != destination ||
            (include_note_sources == 0 && (read_u16(term + 10) & 1u) != 0u)) continue;
        source_value = source_value_q16(read_u16(term),
            &runtime->channels[voice->channel], voice);
        amount_value = source_value_q16(read_u16(term + 6),
            &runtime->channels[voice->channel], voice);
        value = multiply_q16(source_value, amount_value) * (int16_t)read_u16(term + 4);
        if (read_u16(term + 8) == 2u && value < 0) value = -value;
        sum += value;
    }
    return sum;
}

static void candidate_programs(const msf2_view *view, uint32_t candidate,
                               uint8_t programs[3]) {
    const uint8_t *record_value = record(view, 4u, candidate);
    programs[0] = record_value[0];
    programs[1] = record_value[1];
    programs[2] = record_value[2];
}

static uint32_t phase_with_cents(uint32_t base, int64_t cents_q16) {
    const int64_t limit = INT64_C(24000) * MSF2_MOD_ONE;
    if (cents_q16 < -limit) cents_q16 = -limit;
    if (cents_q16 > limit) cents_q16 = limit;
    int64_t exponent_q24 = (cents_q16 * 256) / 1200;
    return ratio_scaled_q24(base, 1u, exponent_q24, 1u);
}

static void gains_with_modulation(uint16_t base_gain, int16_t base_pan,
                                  int64_t attenuation_q16, int64_t pan_q16,
                                  uint16_t *gain_l, uint16_t *gain_r) {
    /* 10^(-cB/200) is rewritten as 2^(-cB*log2(10)/200). The Q24 exponent
     * coefficient 278663 and the shared exp2 LUT avoid libm. Pan then uses the
     * generated quarter-sine table and saturates at the MIDI/SF2 endpoints. */
    int64_t exponent_q24;
    uint32_t scaled;
    int64_t combined = (int64_t)base_pan * MSF2_MOD_ONE + pan_q16;
    int32_t pan = (int32_t)((combined + (combined >= 0 ? 32768 : -32768)) /
                            MSF2_MOD_ONE);
    uint32_t position;
    uint64_t left;
    uint64_t right;
    if (attenuation_q16 < -INT64_C(2000) * MSF2_MOD_ONE) {
        attenuation_q16 = -INT64_C(2000) * MSF2_MOD_ONE;
    }
    if (attenuation_q16 > INT64_C(4000) * MSF2_MOD_ONE) {
        attenuation_q16 = INT64_C(4000) * MSF2_MOD_ONE;
    }
    exponent_q24 = -(attenuation_q16 * INT64_C(278663)) / MSF2_MOD_ONE;
    scaled = ratio_scaled_q24(base_gain, 1u, exponent_q24, 0u);
    if (scaled > 32767u) scaled = 32767u;
    pan = clamp_i32(pan, -500, 500);
    position = (uint32_t)(pan + 500);
    left = pan_sine_q30(1000u - position);
    right = pan_sine_q30(position);
    *gain_l = (uint16_t)((scaled * left + (UINT64_C(1) << 29)) >> 30);
    *gain_r = (uint16_t)((scaled * right + (UINT64_C(1) << 29)) >> 30);
}

static void filter_from_cents(int32_t cutoff_cents, int32_t resonance_cb,
                              msf2_voice_state *voice) {
    uint32_t angle_q16;
    int32_t sin_q30;
    int32_t cos_q30;
    uint32_t inv_2q_q30;
    int32_t alpha_q30;
    uint64_t a0_q30;
    int64_t one_minus_cos;
    cutoff_cents = clamp_i32(cutoff_cents, 1500, 13500);
    resonance_cb = clamp_i32(resonance_cb, 0, 960);
    resonance_cb = ((resonance_cb + 1) / 2) * 2;
    angle_q16 = ratio_scaled_q24(UINT64_C(548682072), MSF2_LUT_SAMPLE_RATE,
                                 cents_exponent_q24(cutoff_cents), 0u);
    sin_q30 = (int32_t)sine_index_q16(angle_q16);
    cos_q30 = cosine_index_q16(angle_q16);
    inv_2q_q30 = ratio_scaled_q24(UINT32_C(759250125), 1u,
        -(int64_t)resonance_cb * 278664, 0u);
    alpha_q30 = (int32_t)(((int64_t)sin_q30 * inv_2q_q30 +
                           (INT64_C(1) << 29)) >> 30);
    a0_q30 = (UINT64_C(1) << 30) + alpha_q30;
    one_minus_cos = (INT64_C(1) << 30) - cos_q30;
    voice->filter_enable = 1u;
    voice->filter_b0 = (int16_t)round_divide(one_minus_cos * 8192, a0_q30);
    voice->filter_b1 = (int16_t)round_divide(one_minus_cos * 16384, a0_q30);
    voice->filter_b2 = voice->filter_b0;
    voice->filter_a1 = (int16_t)round_divide(-(int64_t)cos_q30 * 32768, a0_q30);
    voice->filter_a2 = (int16_t)round_divide(
        ((INT64_C(1) << 30) - alpha_q30) * 16384, a0_q30);
}

static msf2_result emit_command(msf2_runtime *runtime, const uint32_t *words,
                                uint8_t count) {
    return runtime->command_sink(runtime->command_context, words, count) == 0 ?
           MSF2_OK : MSF2_ERR_SINK;
}

static msf2_result emit_short(msf2_runtime *runtime, uint8_t opcode,
                              uint16_t voice, uint16_t generation,
                              uint32_t value, int has_value) {
    uint32_t words[3];
    words[0] = ((uint32_t)opcode << 24) | ((uint32_t)voice << 14) |
               (has_value != 0 ? 2u : 1u);
    words[1] = generation;
    words[2] = value;
    return emit_command(runtime, words, (uint8_t)(has_value != 0 ? 3u : 2u));
}

static void reclaim_voice(msf2_runtime *runtime, uint16_t voice) {
    if (runtime->voices[voice].stage == MSF2_VOICE_FREE) return;
    runtime->voices[voice].stage = MSF2_VOICE_FREE;
    runtime->free_stack[runtime->free_count++] = voice;
    --runtime->stats.active_voices;
}

static msf2_result stop_voice(msf2_runtime *runtime, uint16_t voice) {
    msf2_result result;
    msf2_voice_state *state = &runtime->voices[voice];
    if (state->stage == MSF2_VOICE_FREE) return MSF2_OK;
    result = emit_short(runtime, UINT8_C(0x15), voice, state->generation, 0u, 0);
    if (result != MSF2_OK) return result;
    ++runtime->stats.stopped_voices;
    reclaim_voice(runtime, voice);
    return MSF2_OK;
}

static msf2_result release_voice(msf2_runtime *runtime, uint16_t voice) {
    msf2_result result;
    msf2_voice_state *state = &runtime->voices[voice];
    if (state->stage == MSF2_VOICE_FREE || state->stage == MSF2_VOICE_RELEASED) {
        return MSF2_OK;
    }
    if (state->release_samples == 0u) return stop_voice(runtime, voice);
    result = emit_short(runtime, UINT8_C(0x14), voice, state->generation,
                        state->release_step, 1);
    if (result != MSF2_OK) return result;
    state->stage = MSF2_VOICE_RELEASED;
    state->mod_env_stage = MSF2_ENV_RELEASE;
    state->mod_env_stage_tick = 0u;
    state->mod_env_release_start = state->mod_env_level;
    ++runtime->stats.released_voices;
    return MSF2_OK;
}

static msf2_result allocate_voice(msf2_runtime *runtime, uint16_t *voice) {
    uint16_t index;
    uint16_t victim = 0u;
    /* Free slots are O(1). At capacity, prefer a released voice; otherwise
     * steal the oldest voice in its current lifecycle stage. STOP is emitted
     * before generation is advanced, preventing late runtime commands from
     * mutating the replacement voice. */
    if (runtime->free_count != 0u) {
        *voice = runtime->free_stack[--runtime->free_count];
        return MSF2_OK;
    }
    for (index = 1u; index < runtime->voice_capacity; ++index) {
        const msf2_voice_state *candidate = &runtime->voices[index];
        const msf2_voice_state *selected = &runtime->voices[victim];
        if ((candidate->stage == MSF2_VOICE_RELEASED &&
             selected->stage != MSF2_VOICE_RELEASED) ||
            (candidate->stage == selected->stage &&
             candidate->allocation_stamp < selected->allocation_stamp)) victim = index;
    }
    if (stop_voice(runtime, victim) != MSF2_OK) return MSF2_ERR_SINK;
    --runtime->free_count;
    *voice = runtime->free_stack[runtime->free_count];
    ++runtime->stats.stolen_voices;
    return MSF2_OK;
}

static int32_t lfo_q16(uint32_t phase) {
    int32_t x = (int32_t)(phase & UINT32_C(0xffff));
    if (x < 16384) return x * 4;
    if (x < 49152) return 131072 - x * 4;
    return x * 4 - 262144;
}

static uint16_t linear_level(uint16_t start, uint16_t target,
                             uint32_t tick, uint32_t ticks) {
    int64_t delta;
    int64_t value;
    if (tick >= ticks) return target;
    if (tick == 0u) tick = 1u;
    if (ticks == 0u) ticks = 1u;
    delta = (int64_t)target - start;
    value = start + (delta * tick + (int64_t)ticks / 2) / ticks;
    if (value < 0) value = 0;
    if (value > 32767) value = 32767;
    return (uint16_t)value;
}

static msf2_result refresh_voice(msf2_runtime *runtime, uint16_t voice_index,
                                 uint8_t groups) {
    msf2_voice_state *voice = &runtime->voices[voice_index];
    uint8_t programs[3];
    int32_t mod_lfo;
    int32_t vib_lfo;
    int32_t env_q16;
    msf2_result result;
    if (voice->stage == MSF2_VOICE_FREE) return MSF2_OK;
    /* Re-evaluate only MCU-owned destinations. Each result is compared with
     * the last emitted value, so stationary controllers and envelope plateaus
     * consume no command bandwidth. */
    candidate_programs(runtime->view, voice->candidate, programs);
    mod_lfo = voice->mod_lfo_wait_ticks == 0u ? lfo_q16(voice->mod_lfo_phase) : 0;
    vib_lfo = voice->vib_lfo_wait_ticks == 0u ? lfo_q16(voice->vib_lfo_phase) : 0;
    env_q16 = (int32_t)(((int64_t)voice->mod_env_level * MSF2_MOD_ONE +
                         32767 / 2) / 32767);
    if ((groups & MSF2_PITCH_GROUP) != 0u) {
        int64_t pitch = destination_sum_q16(runtime, voice, programs[1], 0u, 1);
        uint32_t phase;
        pitch += multiply_q16(mod_lfo,
            (int64_t)voice->config.mod_lfo_to_pitch * MSF2_MOD_ONE +
            destination_sum_q16(runtime, voice, programs[1], 5u, 1));
        pitch += multiply_q16(vib_lfo,
            (int64_t)voice->config.vib_lfo_to_pitch * MSF2_MOD_ONE +
            destination_sum_q16(runtime, voice, programs[1], 6u, 1));
        pitch += multiply_q16(env_q16,
            (int64_t)voice->config.mod_env_to_pitch * MSF2_MOD_ONE +
            destination_sum_q16(runtime, voice, programs[1], 7u, 1));
        phase = phase_with_cents(voice->base_phase_increment, pitch);
        if (phase != voice->phase_increment) {
            result = emit_short(runtime, UINT8_C(0x18), voice_index,
                                voice->generation, phase, 1);
            if (result != MSF2_OK) return result;
            voice->phase_increment = phase;
            ++runtime->stats.controller_voice_updates;
        }
    }
    if ((groups & MSF2_GAIN_GROUP) != 0u) {
        int64_t attenuation;
        int64_t pan;
        uint16_t gain_l;
        uint16_t gain_r;
        voice->tremolo_attenuation_q16 = (int32_t)-multiply_q16(mod_lfo,
            (int64_t)voice->config.mod_lfo_to_volume * MSF2_MOD_ONE +
            destination_sum_q16(runtime, voice, programs[0], 13u, 1));
        attenuation = destination_sum_q16(runtime, voice, programs[0], 48u, 0) +
                      voice->tremolo_attenuation_q16 +
                      (runtime->channels[voice->channel].soft != 0u ?
                           INT64_C(30) * MSF2_MOD_ONE : 0);
        pan = destination_sum_q16(runtime, voice, programs[0], 17u, 0);
        gains_with_modulation(voice->base_gain, voice->pan, attenuation, pan,
                              &gain_l, &gain_r);
        if (gain_l != voice->gain_l || gain_r != voice->gain_r) {
            result = emit_short(runtime, UINT8_C(0x16), voice_index,
                                voice->generation, pack_pair(gain_r, gain_l), 1);
            if (result != MSF2_OK) return result;
            voice->gain_l = gain_l;
            voice->gain_r = gain_r;
            ++runtime->stats.controller_voice_updates;
        }
    }
    if ((groups & MSF2_FILTER_GROUP) != 0u) {
        int64_t cutoff = (int64_t)voice->config.initial_filter_fc * MSF2_MOD_ONE +
            destination_sum_q16(runtime, voice, programs[2], 8u, 1);
        msf2_voice_state calculated = *voice;
        uint32_t words[5];
        cutoff += multiply_q16(mod_lfo,
            (int64_t)voice->config.mod_lfo_to_filter_fc * MSF2_MOD_ONE +
            destination_sum_q16(runtime, voice, programs[2], 10u, 1));
        cutoff += multiply_q16(env_q16,
            (int64_t)voice->config.mod_env_to_filter_fc * MSF2_MOD_ONE +
            destination_sum_q16(runtime, voice, programs[2], 11u, 1));
        if (cutoff < INT64_C(1500) * MSF2_MOD_ONE) {
            cutoff = INT64_C(1500) * MSF2_MOD_ONE;
        }
        if (cutoff > INT64_C(13500) * MSF2_MOD_ONE) {
            cutoff = INT64_C(13500) * MSF2_MOD_ONE;
        }
        filter_from_cents((int32_t)((cutoff + (cutoff >= 0 ? 32768 : -32768)) /
                                   MSF2_MOD_ONE),
                          voice->config.initial_filter_q, &calculated);
        if (calculated.filter_enable != voice->filter_enable ||
            calculated.filter_b0 != voice->filter_b0 ||
            calculated.filter_b1 != voice->filter_b1 ||
            calculated.filter_b2 != voice->filter_b2 ||
            calculated.filter_a1 != voice->filter_a1 ||
            calculated.filter_a2 != voice->filter_a2) {
            words[0] = (UINT32_C(0x17) << 24) | ((uint32_t)voice_index << 14) | 4u;
            words[1] = voice->generation;
            words[2] = pack_pair(calculated.filter_b1, calculated.filter_b0);
            words[3] = pack_pair(calculated.filter_a1, calculated.filter_b2);
            words[4] = (uint16_t)calculated.filter_a2 |
                       (calculated.filter_enable != 0u ? UINT32_C(0x00010000) : 0u);
            result = emit_command(runtime, words, 5u);
            if (result != MSF2_OK) return result;
            voice->filter_enable = calculated.filter_enable;
            voice->filter_b0 = calculated.filter_b0;
            voice->filter_b1 = calculated.filter_b1;
            voice->filter_b2 = calculated.filter_b2;
            voice->filter_a1 = calculated.filter_a1;
            voice->filter_a2 = calculated.filter_a2;
            ++runtime->stats.controller_voice_updates;
        }
    }
    return MSF2_OK;
}

static msf2_result advance_voice_modulation(msf2_runtime *runtime,
                                            uint16_t voice_index) {
    msf2_voice_state *voice = &runtime->voices[voice_index];
    uint8_t groups = MSF2_GAIN_GROUP | MSF2_PITCH_GROUP;
    msf2_result result;
    if (voice->stage == MSF2_VOICE_FREE) return MSF2_OK;
    /* The modulation envelope is a control-rate shadow, distinct from the
     * sample-rate volume envelope inside the FPGA. Gain and pitch update every
     * tick; filter updates every fourth tick to preserve the established MCU
     * command-rate policy. LFO phase advances after emission, matching the C++
     * oracle's first-tick phase convention. */
    if (voice->mod_env_stage == MSF2_ENV_DELAY) {
        if (voice->mod_env_wait_ticks != 0u) --voice->mod_env_wait_ticks;
        if (voice->mod_env_wait_ticks == 0u) voice->mod_env_stage = MSF2_ENV_ATTACK;
    } else if (voice->mod_env_stage == MSF2_ENV_ATTACK) {
        ++voice->mod_env_stage_tick;
        voice->mod_env_level = linear_level(0u, 32767u,
            voice->mod_env_stage_tick, voice->config.mod_env_attack_ticks);
        if (voice->mod_env_stage_tick >= voice->config.mod_env_attack_ticks) {
            voice->mod_env_level = 32767u;
            voice->mod_env_stage_tick = 0u;
            voice->mod_env_wait_ticks = voice->config.mod_env_hold_ticks;
            voice->mod_env_stage = voice->mod_env_wait_ticks != 0u ?
                MSF2_ENV_HOLD : MSF2_ENV_DECAY;
        }
    } else if (voice->mod_env_stage == MSF2_ENV_HOLD) {
        if (voice->mod_env_wait_ticks != 0u) --voice->mod_env_wait_ticks;
        if (voice->mod_env_wait_ticks == 0u) voice->mod_env_stage = MSF2_ENV_DECAY;
    } else if (voice->mod_env_stage == MSF2_ENV_DECAY) {
        ++voice->mod_env_stage_tick;
        voice->mod_env_level = linear_level(32767u, voice->config.mod_env_sustain_level,
            voice->mod_env_stage_tick, voice->config.mod_env_decay_ticks);
        if (voice->mod_env_stage_tick >= voice->config.mod_env_decay_ticks) {
            voice->mod_env_level = voice->config.mod_env_sustain_level;
            voice->mod_env_stage_tick = 0u;
            voice->mod_env_stage = MSF2_ENV_SUSTAIN;
        }
    } else if (voice->mod_env_stage == MSF2_ENV_RELEASE) {
        ++voice->mod_env_stage_tick;
        voice->mod_env_level = linear_level(voice->mod_env_release_start, 0u,
            voice->mod_env_stage_tick, voice->config.mod_env_release_ticks);
    }
    if ((runtime->control_tick_index & 3u) == 0u) groups |= MSF2_FILTER_GROUP;
    result = refresh_voice(runtime, voice_index, groups);
    if (result != MSF2_OK) return result;
    if (voice->mod_lfo_wait_ticks != 0u) --voice->mod_lfo_wait_ticks;
    else voice->mod_lfo_phase += voice->config.mod_lfo_step;
    if (voice->vib_lfo_wait_ticks != 0u) --voice->vib_lfo_wait_ticks;
    else voice->vib_lfo_phase += voice->config.vib_lfo_step;
    return MSF2_OK;
}

msf2_result msf2_runtime_init(msf2_runtime *runtime, const msf2_view *view,
                              msf2_channel_state channels[MSF2_CHANNEL_COUNT],
                              msf2_voice_state *voices, uint16_t *free_stack,
                              uint16_t voice_capacity, msf2_command_sink sink,
                              void *sink_context) {
    uint16_t voice;
    unsigned channel;
    if (runtime == NULL || view == NULL || channels == NULL || voices == NULL ||
        free_stack == NULL || sink == NULL || voice_capacity == 0u ||
        voice_capacity > MSF2_MAX_VOICE_COUNT) return MSF2_ERR_ARGUMENT;
    *runtime = (msf2_runtime){0};
    runtime->view = view;
    runtime->channels = channels;
    runtime->voices = voices;
    runtime->free_stack = free_stack;
    runtime->voice_capacity = voice_capacity;
    runtime->free_count = voice_capacity;
    runtime->command_sink = sink;
    runtime->command_context = sink_context;
    for (channel = 0u; channel < MSF2_CHANNEL_COUNT; ++channel) {
        channels[channel] = (msf2_channel_state){0};
        channels[channel].cc[7] = 127u;
        channels[channel].cc[10] = 64u;
        channels[channel].cc[11] = 127u;
        channels[channel].pitch_bend_range_semitones = 2u;
    }
    for (voice = 0u; voice < voice_capacity; ++voice) {
        voices[voice] = (msf2_voice_state){0};
        free_stack[voice] = (uint16_t)(voice_capacity - 1u - voice);
    }
    return MSF2_OK;
}

msf2_result msf2_runtime_note_on(msf2_runtime *runtime, uint8_t channel,
                                 uint16_t program, uint16_t bank, uint8_t note,
                                 uint8_t velocity, uint8_t *started_layers) {
    int32_t preset_index;
    msf2_layers layers;
    uint8_t layer;
    uint8_t exclusive[MSF2_MAX_LAYERS] = {0u, 0u, 0u, 0u};
    uint32_t note_instance;
    if (runtime == NULL || started_layers == NULL || channel >= MSF2_CHANNEL_COUNT ||
        note > 127u || velocity > 127u) return MSF2_ERR_ARGUMENT;
    *started_layers = 0u;
    if (velocity == 0u) return msf2_runtime_note_off(runtime, channel, note);
    ++runtime->stats.note_ons;
    preset_index = msf2_find_preset(runtime->view, program, bank);
    if (preset_index < 0) {
        ++runtime->stats.unmapped_notes;
        return MSF2_OK;
    }
    if (msf2_collect_layers(runtime->view, (uint32_t)preset_index, note, velocity,
                            &layers) != MSF2_OK) return MSF2_ERR_CAPACITY;
    if (layers.count == 0u) {
        ++runtime->stats.unmapped_notes;
        return MSF2_OK;
    }
    /* Decode exclusive classes before allocating any layer. A linked/layered
     * Note On therefore releases all conflicting old voices before publishing
     * its first replacement START. */
    for (layer = 0u; layer < layers.count; ++layer) {
        uint16_t gen[MSF2_GENERATOR_COUNT];
        uint64_t presence;
        if (msf2_decode_generators(runtime->view, layers.zone_index[layer], gen,
                                   &presence) != MSF2_OK) return MSF2_ERR_RECORD;
        exclusive[layer] = has_generator(presence, 57u) ?
            (uint8_t)clamp_i32(signed_amount(gen[57]), 0, 127) : 0u;
    }
    for (layer = 0u; layer < layers.count; ++layer) {
        if (exclusive[layer] != 0u) {
            uint16_t current;
            for (current = 0u; current < runtime->voice_capacity; ++current) {
                msf2_voice_state *old = &runtime->voices[current];
                if (old->stage != MSF2_VOICE_FREE &&
                    old->exclusive_class == exclusive[layer] &&
                    old->preset_index == (uint32_t)preset_index) {
                    msf2_result result = release_voice(runtime, current);
                    if (result != MSF2_OK) return result;
                }
            }
        }
    }
    note_instance = ++runtime->next_note_instance;
    if (note_instance == 0u) note_instance = ++runtime->next_note_instance;
    for (layer = 0u; layer < layers.count; ++layer) {
        uint16_t gen[MSF2_GENERATOR_COUNT];
        uint64_t presence;
        msf2_note_params params;
        uint16_t voice_index;
        msf2_voice_state *voice;
        uint16_t previous_generation;
        uint8_t programs[3];
        int64_t pitch;
        int64_t attenuation;
        int64_t pan;
        uint32_t words[17];
        uint8_t word_count;
        msf2_result result = allocate_voice(runtime, &voice_index);
        if (result != MSF2_OK) return result;
        voice = &runtime->voices[voice_index];
        previous_generation = voice->generation;
        *voice = (msf2_voice_state){0};
        voice->stage = MSF2_VOICE_ACTIVE;
        voice->channel = channel;
        voice->note = note;
        voice->velocity = velocity;
        voice->generation = (uint16_t)(previous_generation + 1u);
        if (voice->generation == 0u) voice->generation = 1u;
        voice->preset_index = (uint32_t)preset_index;
        voice->candidate = layers.zone_index[layer];
        voice->exclusive_class = exclusive[layer];
        voice->note_instance = note_instance;
        voice->allocation_stamp = ++runtime->allocation_stamp;
        if (msf2_decode_generators(runtime->view, voice->candidate, gen, &presence) !=
                MSF2_OK ||
            msf2_materialize_note(runtime->view, voice->candidate, note, &params) !=
                MSF2_OK) return MSF2_ERR_RECORD;
        runtime_config_from_generators(gen, presence, note, &voice->config);
        voice->effective_velocity = has_generator(presence, 47u) ?
            (int8_t)clamp_i32(signed_amount(gen[47]), 0, 127) : -1;
        voice->base_phase_increment = params.phase_inc;
        voice->base_gain = (uint16_t)ratio_scaled_q24(0x4000u, 1u,
            -(int64_t)clamp_i32(has_generator(presence, 48u) ?
                signed_amount(gen[48]) : 0, 0, 3600) * 111465, 0u);
        voice->pan = (int16_t)clamp_i32(has_generator(presence, 17u) ?
            signed_amount(gen[17]) : 0, -500, 500);
        voice->release_samples = params.release_samples;
        voice->release_step = ceil_divide(UINT64_C(1000) << 20, params.release_samples);
        voice->mod_lfo_wait_ticks = voice->config.mod_lfo_delay_ticks;
        voice->vib_lfo_wait_ticks = voice->config.vib_lfo_delay_ticks;
        voice->mod_env_wait_ticks = voice->config.mod_env_delay_ticks;
        voice->mod_env_stage = voice->mod_env_wait_ticks != 0u ?
            MSF2_ENV_DELAY : MSF2_ENV_ATTACK;
        if (voice->config.mod_env_delay_ticks == 0u &&
            voice->config.mod_env_attack_sub_tick != 0u) {
            voice->mod_env_level = 32767u;
            voice->mod_env_wait_ticks = voice->config.mod_env_hold_ticks;
            voice->mod_env_stage = voice->mod_env_wait_ticks != 0u ?
                MSF2_ENV_HOLD : MSF2_ENV_DECAY;
        }
        /* Apply note-static and current channel modulation to the initial
         * phase/gain fields. Continuing LFO/envelope values are emitted by the
         * immediate first control update below and subsequent timer ticks. */
        candidate_programs(runtime->view, voice->candidate, programs);
        pitch = destination_sum_q16(runtime, voice, programs[1], 0u, 1);
        voice->phase_increment = phase_with_cents(voice->base_phase_increment, pitch);
        attenuation = destination_sum_q16(runtime, voice, programs[0], 48u, 0) +
            (runtime->channels[channel].soft != 0u ?
                 INT64_C(30) * MSF2_MOD_ONE : 0);
        pan = destination_sum_q16(runtime, voice, programs[0], 17u, 0);
        gains_with_modulation(voice->base_gain, voice->pan, attenuation, pan,
                              &voice->gain_l, &voice->gain_r);
        params.phase_inc = voice->phase_increment;
        params.gain_l = voice->gain_l;
        params.gain_r = voice->gain_r;
        voice->filter_enable = params.filter_enable;
        voice->filter_b0 = params.filter_b0;
        voice->filter_b1 = params.filter_b1;
        voice->filter_b2 = params.filter_b2;
        voice->filter_a1 = params.filter_a1;
        voice->filter_a2 = params.filter_a2;
        result = msf2_pack_start(voice_index, voice->generation, &params, words,
                                 &word_count);
        if (result != MSF2_OK) return result;
        result = emit_command(runtime, words, word_count);
        if (result != MSF2_OK) return result;
        ++runtime->stats.active_voices;
        if (runtime->stats.active_voices > runtime->stats.maximum_active_voices) {
            runtime->stats.maximum_active_voices = runtime->stats.active_voices;
        }
        ++runtime->stats.started_voices;
        result = advance_voice_modulation(runtime, voice_index);
        if (result != MSF2_OK) return result;
        ++*started_layers;
    }
    return MSF2_OK;
}

msf2_result msf2_runtime_note_off(msf2_runtime *runtime, uint8_t channel,
                                  uint8_t note) {
    uint32_t oldest = UINT32_MAX;
    uint16_t voice;
    if (runtime == NULL || channel >= MSF2_CHANNEL_COUNT || note > 127u) {
        return MSF2_ERR_ARGUMENT;
    }
    ++runtime->stats.note_offs;
    for (voice = 0u; voice < runtime->voice_capacity; ++voice) {
        const msf2_voice_state *state = &runtime->voices[voice];
        if (state->stage == MSF2_VOICE_ACTIVE && state->channel == channel &&
            state->note == note && state->note_instance < oldest) {
            oldest = state->note_instance;
        }
    }
    if (oldest == UINT32_MAX) return MSF2_OK;
    for (voice = 0u; voice < runtime->voice_capacity; ++voice) {
        msf2_voice_state *state = &runtime->voices[voice];
        msf2_result result;
        if (state->stage != MSF2_VOICE_ACTIVE || state->channel != channel ||
            state->note_instance != oldest) continue;
        if (runtime->channels[channel].sustain != 0u) {
            state->stage = MSF2_VOICE_SUSTAIN_HELD;
            continue;
        }
        result = release_voice(runtime, voice);
        if (result != MSF2_OK) return result;
    }
    return MSF2_OK;
}

static msf2_result refresh_channel(msf2_runtime *runtime, uint8_t channel) {
    uint16_t voice;
    for (voice = 0u; voice < runtime->voice_capacity; ++voice) {
        if (runtime->voices[voice].stage != MSF2_VOICE_FREE &&
            runtime->voices[voice].channel == channel) {
            msf2_result result = refresh_voice(runtime, voice,
                MSF2_GAIN_GROUP | MSF2_PITCH_GROUP | MSF2_FILTER_GROUP);
            if (result != MSF2_OK) return result;
        }
    }
    return MSF2_OK;
}

msf2_result msf2_runtime_control_change(msf2_runtime *runtime, uint8_t channel,
                                        uint8_t controller, uint8_t value) {
    msf2_channel_state *state;
    if (runtime == NULL || channel >= MSF2_CHANNEL_COUNT || controller > 127u ||
        value > 127u) return MSF2_ERR_ARGUMENT;
    state = &runtime->channels[channel];
    state->cc[controller] = value;
    if (controller == 64u) {
        uint8_t sustain = value >= 64u;
        if (state->sustain != 0u && sustain == 0u) {
            uint16_t voice;
            for (voice = 0u; voice < runtime->voice_capacity; ++voice) {
                if (runtime->voices[voice].stage == MSF2_VOICE_SUSTAIN_HELD &&
                    runtime->voices[voice].channel == channel) {
                    msf2_result result = release_voice(runtime, voice);
                    if (result != MSF2_OK) return result;
                }
            }
        }
        state->sustain = sustain;
    } else if (controller == 67u) {
        state->soft = value >= 64u;
    } else if (controller == 120u) {
        return msf2_runtime_all_sound_off(runtime, channel);
    }
    return refresh_channel(runtime, channel);
}

msf2_result msf2_runtime_pitch_bend(msf2_runtime *runtime, uint8_t channel,
                                    int16_t value) {
    if (runtime == NULL || channel >= MSF2_CHANNEL_COUNT) return MSF2_ERR_ARGUMENT;
    if (value < -8192) value = -8192;
    if (value > 8191) value = 8191;
    runtime->channels[channel].pitch_bend = value;
    return refresh_channel(runtime, channel);
}

msf2_result msf2_runtime_channel_pressure(msf2_runtime *runtime, uint8_t channel,
                                          uint8_t value) {
    if (runtime == NULL || channel >= MSF2_CHANNEL_COUNT || value > 127u) {
        return MSF2_ERR_ARGUMENT;
    }
    runtime->channels[channel].channel_pressure = value;
    return refresh_channel(runtime, channel);
}

msf2_result msf2_runtime_key_pressure(msf2_runtime *runtime, uint8_t channel,
                                      uint8_t note, uint8_t value) {
    uint16_t voice;
    if (runtime == NULL || channel >= MSF2_CHANNEL_COUNT || note > 127u ||
        value > 127u) return MSF2_ERR_ARGUMENT;
    runtime->channels[channel].key_pressure[note] = value;
    for (voice = 0u; voice < runtime->voice_capacity; ++voice) {
        if (runtime->voices[voice].stage != MSF2_VOICE_FREE &&
            runtime->voices[voice].channel == channel &&
            runtime->voices[voice].note == note) {
            msf2_result result = refresh_voice(runtime, voice,
                MSF2_GAIN_GROUP | MSF2_PITCH_GROUP | MSF2_FILTER_GROUP);
            if (result != MSF2_OK) return result;
        }
    }
    return MSF2_OK;
}

msf2_result msf2_runtime_advance_samples(msf2_runtime *runtime,
                                         uint32_t samples) {
    uint16_t voice;
    uint64_t elapsed;
    uint32_t ticks;
    if (runtime == NULL) return MSF2_ERR_ARGUMENT;

    /* Release lifetime is measured in audio samples, independently of the
       1 ms modulation tick. Subtract it before a slot can be reused. */
    for (voice = 0u; voice < runtime->voice_capacity; ++voice) {
        msf2_voice_state *state = &runtime->voices[voice];
        if (state->stage != MSF2_VOICE_RELEASED) continue;
        if (samples >= state->release_samples) reclaim_voice(runtime, voice);
        else state->release_samples -= samples;
    }

    elapsed = (uint64_t)runtime->pending_tick_samples + samples;
    runtime->pending_tick_samples = (uint32_t)(elapsed % MSF2_CONTROL_TICK_SAMPLES);
    ticks = (uint32_t)(elapsed / MSF2_CONTROL_TICK_SAMPLES);
    if (runtime->stats.active_voices == 0u) {
        runtime->control_tick_index += ticks;
        return MSF2_OK;
    }
    while (ticks-- != 0u) {
        for (voice = 0u; voice < runtime->voice_capacity; ++voice) {
            msf2_result result;
            if (runtime->voices[voice].stage == MSF2_VOICE_FREE) continue;
            result = advance_voice_modulation(runtime, voice);
            if (result != MSF2_OK) return result;
        }
        ++runtime->control_tick_index;
    }
    return MSF2_OK;
}

msf2_result msf2_runtime_control_tick(msf2_runtime *runtime) {
    return msf2_runtime_advance_samples(runtime, MSF2_CONTROL_TICK_SAMPLES);
}

msf2_result msf2_runtime_all_sound_off(msf2_runtime *runtime, uint8_t channel) {
    uint16_t voice;
    if (runtime == NULL || channel >= MSF2_CHANNEL_COUNT) return MSF2_ERR_ARGUMENT;
    for (voice = 0u; voice < runtime->voice_capacity; ++voice) {
        if (runtime->voices[voice].stage != MSF2_VOICE_FREE &&
            runtime->voices[voice].channel == channel) {
            msf2_result result = stop_voice(runtime, voice);
            if (result != MSF2_OK) return result;
        }
    }
    return MSF2_OK;
}
