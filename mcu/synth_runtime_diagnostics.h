#ifndef SYNTH_RUNTIME_DIAGNOSTICS_H
#define SYNTH_RUNTIME_DIAGNOSTICS_H

#include "msf2.h"

#include <stdint.h>

typedef struct synth_runtime_diagnostics_snapshot {
    uint32_t control_voice_evaluations;
    uint32_t controller_voice_updates;
    uint32_t stolen_voices;
    uint16_t active_voices;
    uint16_t maximum_active_voices;
    uint16_t static_voices;
    uint16_t periodic_gain_voices;
    uint16_t periodic_pitch_voices;
    uint16_t periodic_filter_voices;
} synth_runtime_diagnostics_snapshot;

void synth_runtime_diagnostics_capture(
    const msf2_runtime *runtime, synth_runtime_diagnostics_snapshot *snapshot);

#endif
