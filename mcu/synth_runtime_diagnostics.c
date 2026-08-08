#include "synth_runtime_diagnostics.h"

#include <stddef.h>

void synth_runtime_diagnostics_capture(
    const msf2_runtime *runtime, synth_runtime_diagnostics_snapshot *snapshot) {
    uint16_t active;
    if (runtime == NULL || snapshot == NULL) return;
    *snapshot = (synth_runtime_diagnostics_snapshot){
        .control_voice_evaluations = runtime->stats.control_voice_evaluations,
        .controller_voice_updates = runtime->stats.controller_voice_updates,
        .stolen_voices = runtime->stats.stolen_voices,
        .active_voices = runtime->stats.active_voices,
        .maximum_active_voices = runtime->stats.maximum_active_voices,
    };
    for (active = 0u; active < runtime->active_count; ++active) {
        const msf2_voice_state *voice =
            &runtime->voices[runtime->active_voice_indices[active]];
        if (voice->periodic_groups == 0u) ++snapshot->static_voices;
        if ((voice->periodic_groups & MSF2_CONTROL_GROUP_GAIN) != 0u) {
            ++snapshot->periodic_gain_voices;
        }
        if ((voice->periodic_groups & MSF2_CONTROL_GROUP_PITCH) != 0u) {
            ++snapshot->periodic_pitch_voices;
        }
        if ((voice->periodic_groups & MSF2_CONTROL_GROUP_FILTER) != 0u) {
            ++snapshot->periodic_filter_voices;
        }
    }
}
