#include "midi_policy.h"

#include <stdint.h>
#include <stdio.h>

typedef struct command_log {
    uint8_t opcode[64];
    unsigned count;
} command_log;

static int record_command(void *context, const uint32_t *words,
                          uint8_t word_count) {
    command_log *log = context;
    if (word_count == 0u || log->count >= 64u) return -1;
    log->opcode[log->count++] = (uint8_t)(words[0] >> 24);
    return 0;
}

static void activate_voice(msf2_runtime *runtime, uint16_t voice,
                           uint8_t channel, uint8_t note,
                           uint32_t note_instance) {
    msf2_voice_state *state = &runtime->voices[voice];
    *state = (msf2_voice_state){0};
    state->stage = MSF2_VOICE_ACTIVE;
    state->channel = channel;
    state->note = note;
    state->generation = (uint16_t)(voice + 1u);
    state->note_instance = note_instance;
    state->release_samples = 100u;
    state->release_step = 7u;
    state->candidate = 0u;
    state->active_position = runtime->active_count;
    runtime->active_voice_indices[runtime->active_count++] = voice;
    --runtime->free_count;
    ++runtime->stats.active_voices;
}

static int saw_opcode(const command_log *log, uint8_t opcode) {
    unsigned index;
    for (index = 0u; index < log->count; ++index) {
        if (log->opcode[index] == opcode) return 1;
    }
    return 0;
}

int main(void) {
    static const uint8_t no_programs[3] = {UINT8_MAX, UINT8_MAX, UINT8_MAX};
    msf2_view view = {0};
    msf2_runtime runtime;
    msf2_channel_state channels[MSF2_CHANNEL_COUNT];
    msf2_voice_state voices[4];
    uint16_t free_stack[4];
    command_log log = {{0}, 0u};
    midi_policy policy;

    view.sections[4].data = no_programs;
    view.sections[4].count = 1u;
    view.sections[4].stride = 3u;
    if (msf2_runtime_init(&runtime, &view, channels, voices, free_stack, 4u,
                          record_command, &log) != MSF2_OK ||
        midi_policy_init(&policy, &runtime) != MSF2_OK ||
        policy.channels[9].bank != 128u) {
        fputs("runtime initialization failed\n", stderr);
        return 1;
    }

    activate_voice(&runtime, 0u, 0u, 60u, 1u);
    {
        const unsigned before = log.count;
        if (msf2_runtime_control_change(&runtime, 0u, 7u, 91u) != MSF2_OK ||
            msf2_runtime_pitch_bend(&runtime, 0u, 2048) != MSF2_OK ||
            msf2_runtime_channel_pressure(&runtime, 0u, 44u) != MSF2_OK ||
            msf2_runtime_key_pressure(&runtime, 0u, 60u, 55u) != MSF2_OK ||
            log.count != before || channels[0].cc[7] != 91u ||
            channels[0].pitch_bend != 2048 ||
            channels[0].channel_pressure != 44u ||
            channels[0].key_pressure[60] != 55u) {
            fputs("continuous controller work was not deferred\n", stderr);
            return 1;
        }
    }
    if (midi_policy_control_change(&policy, 0u, 64u, 127u) != MSF2_OK ||
        midi_policy_note_off(&policy, 0u, 60u) != MSF2_OK ||
        voices[0].stage != MSF2_VOICE_SUSTAIN_HELD ||
        midi_policy_control_change(&policy, 0u, 64u, 0u) != MSF2_OK ||
        voices[0].stage != MSF2_VOICE_RELEASED || !saw_opcode(&log, 0x14u)) {
        fputs("sustain release behavior failed\n", stderr);
        return 1;
    }

    activate_voice(&runtime, 1u, 0u, 61u, 2u);
    if (midi_policy_control_change(&policy, 0u, 66u, 127u) != MSF2_OK ||
        voices[1].sostenuto_held == 0u ||
        midi_policy_note_off(&policy, 0u, 61u) != MSF2_OK ||
        voices[1].stage != MSF2_VOICE_SUSTAIN_HELD ||
        midi_policy_control_change(&policy, 0u, 64u, 127u) != MSF2_OK ||
        midi_policy_control_change(&policy, 0u, 66u, 0u) != MSF2_OK ||
        voices[1].stage != MSF2_VOICE_SUSTAIN_HELD ||
        midi_policy_control_change(&policy, 0u, 64u, 0u) != MSF2_OK ||
        voices[1].stage != MSF2_VOICE_RELEASED) {
        fputs("sostenuto capture behavior failed\n", stderr);
        return 1;
    }

    activate_voice(&runtime, 2u, 1u, 62u, 3u);
    if (midi_policy_control_change(&policy, 1u, 123u, 0u) != MSF2_OK ||
        voices[2].stage != MSF2_VOICE_RELEASED) {
        fputs("All Notes Off behavior failed\n", stderr);
        return 1;
    }

    if (midi_policy_control_change(&policy, 2u, 101u, 0u) != MSF2_OK ||
        midi_policy_control_change(&policy, 2u, 100u, 0u) != MSF2_OK ||
        midi_policy_control_change(&policy, 2u, 6u, 12u) != MSF2_OK ||
        midi_policy_control_change(&policy, 2u, 38u, 34u) != MSF2_OK ||
        channels[2].pitch_bend_range_semitones != 12u ||
        channels[2].pitch_bend_range_cents != 34u) {
        fputs("RPN pitch-bend sensitivity failed\n", stderr);
        return 1;
    }
    if (midi_policy_control_change(&policy, 2u, 99u, 120u) != MSF2_OK ||
        midi_policy_control_change(&policy, 2u, 98u, 17u) != MSF2_OK ||
        midi_policy_control_change(&policy, 2u, 6u, 65u) != MSF2_OK ||
        channels[2].generator_offsets_q16[17] <= 0) {
        fputs("SoundFont NRPN generator offset failed\n", stderr);
        return 1;
    }
    if (midi_policy_control_change(&policy, 2u, 0u, 3u) != MSF2_OK ||
        midi_policy_control_change(&policy, 2u, 32u, 5u) != MSF2_OK ||
        midi_policy_program_change(&policy, 2u, 42u) != MSF2_OK ||
        policy.channels[2].bank != 389u || policy.channels[2].program != 42u) {
        fputs("bank/program selection failed\n", stderr);
        return 1;
    }
    if (midi_policy_control_change(&policy, 9u, 0u, 3u) != MSF2_OK ||
        midi_policy_control_change(&policy, 9u, 32u, 5u) != MSF2_OK ||
        midi_policy_program_change(&policy, 9u, 30u) != MSF2_OK ||
        policy.channels[9].bank != 128u || policy.channels[9].program != 30u ||
        midi_policy_control_change(&policy, 9u, 121u, 0u) != MSF2_OK ||
        policy.channels[9].bank != 128u) {
        fputs("percussion channel escaped SoundFont bank 128\n", stderr);
        return 1;
    }
    if (midi_policy_control_change(&policy, 2u, 121u, 0u) != MSF2_OK ||
        channels[2].cc[7] != 127u || channels[2].cc[10] != 64u ||
        channels[2].pitch_bend_range_semitones != 2u ||
        channels[2].generator_offsets_q16[17] != 0 ||
        policy.channels[2].rpn_msb != 127u) {
        fputs("Reset All Controllers behavior failed\n", stderr);
        return 1;
    }

    voices[3].release_samples = 0u;
    activate_voice(&runtime, 3u, 3u, 63u, 4u);
    voices[3].release_samples = 0u;
    if (midi_policy_system_reset(&policy) != MSF2_OK ||
        voices[3].stage != MSF2_VOICE_FREE || !saw_opcode(&log, 0x15u) ||
        policy.channels[2].bank != 0u || policy.channels[2].program != 0u ||
        policy.channels[9].bank != 128u) {
        fputs("MIDI System Reset behavior failed\n", stderr);
        return 1;
    }

    activate_voice(&runtime, 3u, 3u, 63u, 5u);
    {
        const unsigned before = log.count;
        if (midi_policy_release_all(&policy) != MSF2_OK ||
            voices[3].stage != MSF2_VOICE_RELEASED ||
            log.count != before + 1u || log.opcode[before] != 0x14u) {
            fputs("MCU-owned release-all behavior failed\n", stderr);
            return 1;
        }
    }

    puts("PASS: MCU MIDI policy and channel modes");
    return 0;
}
