#ifndef MIDI_POLICY_H
#define MIDI_POLICY_H

#include "msf2.h"

#include <stdint.h>

typedef struct midi_channel_policy {
    uint16_t bank;
    uint8_t program;
    uint8_t rpn_msb;
    uint8_t rpn_lsb;
    uint8_t nrpn_msb;
    int16_t nrpn_generator;
    uint16_t nrpn_base;
    uint8_t data_entry_msb;
    uint8_t data_entry_lsb;
    uint8_t data_entry_is_nrpn;
} midi_channel_policy;

typedef struct midi_policy {
    msf2_runtime *runtime;
    midi_channel_policy channels[MSF2_CHANNEL_COUNT];
} midi_policy;

msf2_result midi_policy_init(midi_policy *policy, msf2_runtime *runtime);
msf2_result midi_policy_note_on(midi_policy *policy, uint8_t channel,
                                uint8_t key, uint8_t velocity,
                                uint8_t *started_layers);
msf2_result midi_policy_note_off(midi_policy *policy, uint8_t channel,
                                 uint8_t key);
msf2_result midi_policy_control_change(midi_policy *policy, uint8_t channel,
                                       uint8_t controller, uint8_t value);
msf2_result midi_policy_program_change(midi_policy *policy, uint8_t channel,
                                       uint8_t program);
msf2_result midi_policy_system_reset(midi_policy *policy);
msf2_result midi_policy_release_all(midi_policy *policy);

#endif
