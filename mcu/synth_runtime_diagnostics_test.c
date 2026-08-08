#include "synth_runtime_diagnostics.h"

#include <stdint.h>
#include <stdio.h>

int main(void) {
    msf2_runtime runtime = {0};
    msf2_voice_state voices[3] = {{0}};
    synth_runtime_diagnostics_snapshot snapshot;

    runtime.voices = voices;
    runtime.active_count = 3u;
    runtime.active_voice_indices[0] = 2u;
    runtime.active_voice_indices[1] = 0u;
    runtime.active_voice_indices[2] = 1u;
    runtime.stats.control_voice_evaluations = UINT32_C(1234);
    runtime.stats.controller_voice_updates = UINT32_C(56);
    runtime.stats.stolen_voices = UINT32_C(7);
    runtime.stats.active_voices = 3u;
    runtime.stats.maximum_active_voices = 9u;
    voices[0].periodic_groups =
        MSF2_CONTROL_GROUP_GAIN | MSF2_CONTROL_GROUP_PITCH;
    voices[1].periodic_groups = MSF2_CONTROL_GROUP_FILTER;
    voices[2].periodic_groups = 0u;

    synth_runtime_diagnostics_capture(&runtime, &snapshot);
    if (snapshot.control_voice_evaluations != UINT32_C(1234) ||
        snapshot.controller_voice_updates != UINT32_C(56) ||
        snapshot.stolen_voices != UINT32_C(7) ||
        snapshot.active_voices != 3u || snapshot.maximum_active_voices != 9u ||
        snapshot.static_voices != 1u ||
        snapshot.periodic_gain_voices != 1u ||
        snapshot.periodic_pitch_voices != 1u ||
        snapshot.periodic_filter_voices != 1u) {
        fputs("runtime diagnostics snapshot mismatch\n", stderr);
        return 1;
    }
    runtime.active_count = 0u;
    runtime.stats.active_voices = 0u;
    synth_runtime_diagnostics_capture(&runtime, &snapshot);
    if (snapshot.active_voices != 0u || snapshot.static_voices != 0u ||
        snapshot.periodic_gain_voices != 0u ||
        snapshot.periodic_pitch_voices != 0u ||
        snapshot.periodic_filter_voices != 0u) {
        fputs("runtime diagnostics retained stale voice counts\n", stderr);
        return 1;
    }
    puts("PASS: synth runtime diagnostics snapshot");
    return 0;
}
