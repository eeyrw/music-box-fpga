# Envelope Backlog

This document records the open SoundFont envelope compatibility and renderer
efficiency work. The reference points for the analysis are the local
`docs/reference/soundfont-2.04.pdf` and FluidSynth `v2.5.6-110-g29a740b2` at
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

The RTL now also agrees on work performed while silent. It advances phase and
loop state without issuing wave-memory requests, running interpolation or DSP,
or advancing biquad history.

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
Release to 8000 timecents. The loader now applies those same parameter-specific
limits.

RTL stores durations only for Delay and Hold:

```text
delay_samples:  unsigned 24-bit sample count
hold_samples:   unsigned 24-bit sample count
attack_step:    unsigned Q0.32 linear-amplitude step
decay_step:     unsigned Q12.20 centibel step
release_step:   unsigned Q12.20 centibel step
```

The command builder temporarily represents Attack, Decay, and Release as 32-bit
sample counts and converts them to non-zero ceiling-divided steps. At 48 kHz, a
minimum step of one can represent about 24.85 hours for Attack and about 6.07
hours for a full 1000 cB Decay or Release. Delay and Hold have a direct 24-bit
limit of about 349.53 seconds.

## Completed Work

1. The host timecent conversion is split by generator class. Delay and Hold
   clamp to `[-12000, 5000]` and Attack, Decay, and Release to
   `[-12000, 8000]`, while preserving each generator's documented `-32768`
   immediate-stage semantics.
2. The shared 24-bit clamp was removed from temporary Attack, Decay, and Release
   sample counts. Only RTL Delay and Hold fields retain the 24-bit limit, and
   command steps retain ceiling division.
3. Loader and command-control tests cover `5000`, `5001`, `8000`, and
   `8001` timecents, including key-scaled Hold/Decay and non-zero 100-second
   Attack/Decay/Release steps.
4. The renderer has a silent Delay path that advances phase and loop state
   without issuing wave-memory requests or entering `voice_dsp_pipeline`.
5. The voice slot remains active during Delay; `VOICE_START` is not deferred and
   the delayed note is not eligible as a free voice.
6. Filter history remains unchanged during Delay, matching FluidSynth.
7. RTL tests prove that Delay consumes a voice, produces exact zero,
   advances and wraps phase correctly, performs no memory request, preserves
   filter history, and transitions to the expected first Attack sample.
8. The C++ reference and RTL use the same exact result with a non-constant
   waveform and enabled filter so a postponed phase or unintended filter
   warm-up cannot pass as an all-zero Delay-only test.

## Confirmed Release-State Bug

`block_voice_state_store` currently writes `ENV_RELEASE` into dynamic state as
soon as it accepts a nonzero RELEASE command. That bypasses the envelope
frontend's Attack-to-Release path, whose `q15_to_cb` conversion is selected only
when it observes `released=1` while the prior dynamic stage is still
`ENV_ATTACK`. A note released during Attack can therefore begin logarithmic
Release from zero attenuation instead of its current partial Attack level,
causing an amplitude discontinuity. The state store must preserve the prior
dynamic stage for nonzero RELEASE and publish only the released flag and release
step; a zero release step may still clear active state immediately. A focused
state-store regression is required with the RTL fix.

This optimization removes wave-memory traffic and DSP switching activity while
voices are in Delay. The shared DSP pipeline remains required for audible
voices, so this is an activity and throughput improvement rather than removal
of the synthesis DSP datapath.
