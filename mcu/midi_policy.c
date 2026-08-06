#include "midi_policy.h"

#include <stdint.h>

#define MIDI_NRPN_SF2_MSB 120u
#define SF2_GEN_MOD_LFO_TO_PITCH 5u
#define SF2_GEN_VIB_LFO_TO_PITCH 6u
#define SF2_GEN_MOD_ENV_TO_PITCH 7u
#define SF2_GEN_INITIAL_FILTER_FC 8u
#define SF2_GEN_MOD_LFO_TO_FILTER_FC 10u
#define SF2_GEN_MOD_ENV_TO_FILTER_FC 11u
#define SF2_GEN_MOD_LFO_TO_VOLUME 13u
#define SF2_GEN_PAN 17u
#define SF2_GEN_INITIAL_ATTENUATION 48u
#define SF2_GEN_COARSE_TUNE 51u
#define SF2_GEN_FINE_TUNE 52u
#define MIDI_PERCUSSION_CHANNEL 9u
#define MIDI_PERCUSSION_BANK 128u

static void reset_policy_channel(midi_channel_policy *channel) {
    *channel = (midi_channel_policy){0};
    channel->rpn_msb = 127u;
    channel->rpn_lsb = 127u;
    channel->nrpn_msb = 127u;
    channel->nrpn_generator = -1;
}

static int32_t nrpn_span(uint8_t generator) {
    switch (generator) {
        case SF2_GEN_INITIAL_FILTER_FC:
        case SF2_GEN_MOD_LFO_TO_PITCH:
        case SF2_GEN_VIB_LFO_TO_PITCH:
        case SF2_GEN_MOD_ENV_TO_PITCH:
        case SF2_GEN_MOD_LFO_TO_FILTER_FC:
        case SF2_GEN_MOD_ENV_TO_FILTER_FC:
            return 6000;
        case SF2_GEN_MOD_LFO_TO_VOLUME:
            return 1920;
        case SF2_GEN_PAN:
            return 1000;
        case SF2_GEN_INITIAL_ATTENUATION:
            return 1440;
        case SF2_GEN_COARSE_TUNE:
            return 240;
        case SF2_GEN_FINE_TUNE:
            return 198;
        default:
            return 0;
    }
}

static msf2_result apply_data_entry(midi_policy *policy, uint8_t channel) {
    midi_channel_policy *state = &policy->channels[channel];
    uint16_t data14 = (uint16_t)(((uint16_t)state->data_entry_msb << 7) |
                                 state->data_entry_lsb);

    if (state->data_entry_is_nrpn != 0u &&
        state->nrpn_msb == MIDI_NRPN_SF2_MSB &&
        state->nrpn_generator >= 0 &&
        state->nrpn_generator < (int16_t)MSF2_GENERATOR_COUNT) {
        int32_t span = nrpn_span((uint8_t)state->nrpn_generator);
        if (span != 0) {
            int32_t offset = (int32_t)(((int64_t)((int32_t)data14 - 8192) *
                                        span * 65536) / 8192);
            return msf2_runtime_set_generator_offset(
                policy->runtime, channel, (uint8_t)state->nrpn_generator, offset);
        }
        return MSF2_OK;
    }

    if (state->data_entry_is_nrpn == 0u && state->rpn_msb == 0u) {
        if (state->rpn_lsb == 0u) {
            uint8_t cents = state->data_entry_lsb > 99u ? 99u :
                                                             state->data_entry_lsb;
            return msf2_runtime_set_pitch_bend_range(
                policy->runtime, channel, state->data_entry_msb, cents);
        }
        if (state->rpn_lsb == 1u) {
            int32_t offset = (int32_t)(((int64_t)((int32_t)data14 - 8192) *
                                        100 * 65536) / 8192);
            return msf2_runtime_set_generator_offset(
                policy->runtime, channel, SF2_GEN_FINE_TUNE, offset);
        }
        if (state->rpn_lsb == 2u) {
            int32_t offset = ((int32_t)state->data_entry_msb - 64) * 100 * 65536;
            return msf2_runtime_set_generator_offset(
                policy->runtime, channel, SF2_GEN_COARSE_TUNE, offset);
        }
    }
    return MSF2_OK;
}

msf2_result midi_policy_init(midi_policy *policy, msf2_runtime *runtime) {
    unsigned channel;
    if (policy == NULL || runtime == NULL) return MSF2_ERR_ARGUMENT;
    *policy = (midi_policy){0};
    policy->runtime = runtime;
    for (channel = 0u; channel < MSF2_CHANNEL_COUNT; ++channel) {
        reset_policy_channel(&policy->channels[channel]);
    }
    policy->channels[MIDI_PERCUSSION_CHANNEL].bank = MIDI_PERCUSSION_BANK;
    return MSF2_OK;
}

msf2_result midi_policy_note_on(midi_policy *policy, uint8_t channel,
                                uint8_t key, uint8_t velocity,
                                uint8_t *started_layers) {
    if (policy == NULL || channel >= MSF2_CHANNEL_COUNT) return MSF2_ERR_ARGUMENT;
    return msf2_runtime_note_on(policy->runtime, channel,
                                policy->channels[channel].program,
                                channel == MIDI_PERCUSSION_CHANNEL
                                    ? MIDI_PERCUSSION_BANK
                                    : policy->channels[channel].bank,
                                key, velocity,
                                started_layers);
}

msf2_result midi_policy_note_off(midi_policy *policy, uint8_t channel,
                                 uint8_t key) {
    if (policy == NULL) return MSF2_ERR_ARGUMENT;
    return msf2_runtime_note_off(policy->runtime, channel, key);
}

msf2_result midi_policy_control_change(midi_policy *policy, uint8_t channel,
                                       uint8_t controller, uint8_t value) {
    midi_channel_policy *state;
    msf2_result result;
    if (policy == NULL || channel >= MSF2_CHANNEL_COUNT || controller > 127u ||
        value > 127u) return MSF2_ERR_ARGUMENT;
    state = &policy->channels[channel];

    result = msf2_runtime_control_change(policy->runtime, channel, controller, value);
    if (result != MSF2_OK) return result;

    switch (controller) {
        case 0u:
            if (channel != MIDI_PERCUSSION_CHANNEL) {
                state->bank = (uint16_t)(((uint16_t)value << 7) |
                                         (state->bank & UINT16_C(0x007f)));
            }
            break;
        case 32u:
            if (channel != MIDI_PERCUSSION_CHANNEL) {
                state->bank = (uint16_t)((state->bank & UINT16_C(0x3f80)) | value);
            }
            break;
        case 98u:
            state->nrpn_generator = value < 100u
                                        ? (int16_t)(state->nrpn_base + value)
                                        : -1;
            if (value == 100u) state->nrpn_base = 100u;
            else if (value == 101u) state->nrpn_base = 1000u;
            else if (value == 102u) state->nrpn_base = 10000u;
            else if (value < 100u) state->nrpn_base = 0u;
            state->data_entry_is_nrpn = 1u;
            break;
        case 99u:
            state->nrpn_msb = value;
            state->data_entry_is_nrpn = 1u;
            if (value != MIDI_NRPN_SF2_MSB) state->nrpn_generator = -1;
            break;
        case 100u:
            state->rpn_lsb = value;
            state->data_entry_is_nrpn = 0u;
            break;
        case 101u:
            state->rpn_msb = value;
            state->data_entry_is_nrpn = 0u;
            break;
        case 6u:
            state->data_entry_msb = value;
            return apply_data_entry(policy, channel);
        case 38u:
            state->data_entry_lsb = value;
            return apply_data_entry(policy, channel);
        case 96u:
            if (state->data_entry_msb < 127u) ++state->data_entry_msb;
            return apply_data_entry(policy, channel);
        case 97u:
            if (state->data_entry_msb > 0u) --state->data_entry_msb;
            return apply_data_entry(policy, channel);
        case 121u:
            reset_policy_channel(state);
            if (channel == MIDI_PERCUSSION_CHANNEL) {
                state->bank = MIDI_PERCUSSION_BANK;
            }
            break;
        default:
            break;
    }
    return MSF2_OK;
}

msf2_result midi_policy_program_change(midi_policy *policy, uint8_t channel,
                                       uint8_t program) {
    if (policy == NULL || channel >= MSF2_CHANNEL_COUNT || program > 127u) {
        return MSF2_ERR_ARGUMENT;
    }
    policy->channels[channel].program = program;
    return MSF2_OK;
}

msf2_result midi_policy_system_reset(midi_policy *policy) {
    unsigned channel;
    if (policy == NULL) return MSF2_ERR_ARGUMENT;
    for (channel = 0u; channel < MSF2_CHANNEL_COUNT; ++channel) {
        msf2_result result = msf2_runtime_all_sound_off(policy->runtime,
                                                        (uint8_t)channel);
        if (result != MSF2_OK) return result;
        result = msf2_runtime_reset_controllers(policy->runtime, (uint8_t)channel);
        if (result != MSF2_OK) return result;
        reset_policy_channel(&policy->channels[channel]);
        if (channel == MIDI_PERCUSSION_CHANNEL) {
            policy->channels[channel].bank = MIDI_PERCUSSION_BANK;
        }
    }
    return MSF2_OK;
}

msf2_result midi_policy_release_all(midi_policy *policy) {
    if (policy == NULL) return MSF2_ERR_ARGUMENT;
    return msf2_runtime_release_all(policy->runtime);
}
