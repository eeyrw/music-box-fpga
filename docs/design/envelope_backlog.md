# Envelope Backlog

This document records the open SoundFont envelope compatibility and renderer
efficiency work. The reference points for the analysis are the local
`docs/sfspec24.pdf` and FluidSynth `v2.5.6-110-g29a740b2` at
`/home/yuan/fluidsynth`.

## Confirmed Contracts

SoundFont generator 33 defines `delayVolEnv` as the interval between key-on and
the start of Volume Envelope Attack. Section 9.1.7 states that the envelope
value remains zero during Delay. The volume envelope controls the final gain
amplifier after the wavetable oscillator and filter; Delay does not reserve a
separate deferred Note On event.

FluidSynth assigns the voice at Note On and advances its sample phase and loop
state while the volume envelope is in Delay. Its silent render path does not
read sample data, interpolate samples, or advance IIR filter history. The source
comment explicitly describes Delay as silent playback rather than postponing
the sound. This behavior was introduced by FluidSynth commit `186a4af9` and its
current optimized path is `fluid_rvoice_dsp_silence()`.

The current RTL agrees on lifecycle and phase semantics:

- `VOICE_START` immediately makes the slot active, so Delay consumes one voice.
- the envelope advances once per output frame and produces Q1.15 zero in Delay;
- sample phase and loop state advance during Delay.

The current RTL differs in work performed while silent. It still issues wave
memory requests, interpolates samples, runs the DSP pipeline, and advances
biquad history before multiplying the result by a zero envelope level.

## Time Ranges And Representation

The SoundFont time ranges are parameter-specific. Values in seconds below are
the exact `2^(timecents / 1200)` conversion; the specification table rounds
them to 20 or 100 seconds.

| Parameters | Maximum | Exact duration |
| --- | ---: | ---: |
| Mod/Vib LFO Delay | 5000 timecents | 17.959393 s |
| Mod/Volume Envelope Delay | 5000 timecents | 17.959393 s |
| Mod/Volume Envelope Hold | 5000 timecents | 17.959393 s |
| Mod/Volume Envelope Attack | 8000 timecents | 101.593667 s |
| Mod/Volume Envelope Decay | 8000 timecents | 101.593667 s |
| Mod/Volume Envelope Release | 8000 timecents | 101.593667 s |

Decay and Release values describe a full-scale change. Actual Decay duration is
shortened according to the sustain distance, and Release from an already
attenuated level completes sooner than a full-level Release.

FluidSynth clamps Delay and Hold to 5000 timecents and Attack, Decay, and
Release to 8000 timecents. The current loader instead routes all time parameters
through `timecents_to_seconds()`, which applies one 100-second ceiling. It
therefore permits Delay/Hold beyond the SoundFont range and truncates the top
1.593667 seconds from Attack/Decay/Release.

RTL stores durations only for Delay and Hold:

```text
delay_samples:  unsigned 24-bit sample count
hold_samples:   unsigned 24-bit sample count
attack_step:    unsigned Q0.32 linear-amplitude step
decay_step:     unsigned Q12.20 centibel step
release_step:   unsigned Q12.20 centibel step
```

The command builder temporarily represents Attack, Decay, and Release as sample
counts and converts them to non-zero ceiling-divided steps. The 100-second limit
is host policy, not an RTL step-format limit. At 48 kHz, a minimum step of one
can represent about 24.85 hours for Attack and about 6.07 hours for a full
1000 cB Decay or Release. Delay and Hold have a direct 24-bit limit of about
349.53 seconds.

## Open Work

1. Split the host timecent conversion by generator class. Clamp Delay and Hold
   to `[-12000, 5000]` and Attack, Decay, and Release to `[-12000, 8000]`, while
   preserving each generator's documented `-32768` immediate-stage semantics.
2. Remove the shared 24-bit clamp from the temporary Attack, Decay, and Release
   sample-count conversion. Apply the 24-bit limit only to RTL Delay and Hold
   fields, and retain ceiling division when producing steps.
3. Add focused loader and command-control tests at `5000`, `5001`, `8000`, and
   `8001` timecents, including key-scaled Hold/Decay and non-zero 100-second
   Attack/Decay/Release steps.
4. Add a silent Delay renderer path that advances phase and loop state without
   issuing wave-memory requests or entering `voice_dsp_pipeline`.
5. Keep the voice slot active during Delay. Do not defer `VOICE_START` or make
   the delayed note eligible as a free voice.
6. Match FluidSynth by leaving filter history unchanged during Delay, unless a
   separately documented compatibility decision and listening regression show
   that filter warm-up is preferred.
7. Add RTL tests proving that Delay consumes a voice, produces exact zero,
   advances and wraps phase correctly, performs no memory request, preserves
   filter history, and transitions to the expected first Attack sample.
8. Add a C++ reference/RTL comparison using a non-constant waveform and enabled
   filter so a postponed phase or unintended filter warm-up cannot pass as an
   all-zero Delay-only test.
