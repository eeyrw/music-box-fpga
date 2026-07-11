# Audio Render Calculation

This document traces the current simulation render path numerically. It explains
what the MCU-side simulation calculates, what the FPGA RTL calculates, and where
fixed-point conversions happen.

The current path is intentionally limited:

- The MIDI preparation step maps Note On events to SF2 preset/instrument sample
  regions and loads the used sample regions into wave memory.
- MIDI or JSON note events are decoded by simulation software.
- A simulation-only MCU model performs voice allocation, Note On, Note Off, and
  SF2 volume-envelope stepping from generated per-region control values.
- The RTL core performs looped wavetable playback, interpolation, gain,
  runtime-envelope multiplication, and saturated stereo mixing.

The RTL does not implement MIDI parsing, SF2 preset lookup, velocity curves,
modulators, filter coefficient calculation, or ADSR policy. It can consume an
already calculated per-voice one-pole LPF coefficient.

## Render Inputs

`make render-midi` uses `tools/midi_render_prepare.py` to generate:

```text
build/render_midi/wave.memh
build/render_midi/midi_render_config.svh
build/render_midi/midi_render_config.json
```

`wave.memh` contains signed 16-bit PCM words in the documented wave-memory
format. Mono waves use one word per frame. Stereo waves use interleaved left then
right words.

`midi_render_config.svh` contains localparams consumed by
`sim/tb/tb_render_midi_core.sv`:

```text
MIDI_SAMPLE_COUNT
MIDI_MEMORY_DEPTH
MIDI_REGION_COUNT
MIDI_ADSR_*_STEP
MIDI_EVENT_* arrays
MIDI_REGION_* arrays
```

## Event Timing

For a standard MIDI file, the preparation tool reads tempo events and converts
MIDI ticks to seconds. For JSON note lists, `start` and `duration` are already in
seconds.

Each event time is converted to an output sample index:

```text
event_sample = round(event_time_seconds * output_sample_rate)
```

During simulation, before each output sample is requested, the MCU model handles
all events whose `event_sample <= produced_sample_count`.

## Pitch To Phase Increment

Playback phase uses unsigned Q16.16 sample-frame units. A phase increment of
`0x0001_0000` advances one source frame for each output sample.

The preparation tool calculates one `phase_inc` per note event:

```text
cents = (midi_note - root_key) * 100
      + pitch_correction
      + fine_tune
      + coarse_tune * 100

rate_ratio = source_sample_rate / output_sample_rate
           * 2^(cents / 1200)

phase_inc = round(rate_ratio * 65536)
```

`root_key`, tuning, and sample rate come from the selected SF2 instrument zone and
sample header. The generated `phase_inc` is written into the voice slot during
Note On.

## MCU Voice Allocation

The simulation MCU model tracks one small state record per FPGA voice slot:

```text
voice_note
voice_channel    MIDI channel that owns the slot
voice_region     generated SF2 sample region index
voice_state       SILENT / ATTACK / DECAY / SUSTAIN / RELEASE
voice_level       current Q1.15 envelope level
voice_target      velocity-scaled peak Q1.15 level
voice_sustain     SF2 sustain level scaled by velocity
voice_stamp       allocation timestamp
```

On Note On:

```text
1. Find the first SILENT slot.
2. If none is free, steal the oldest allocated slot.
3. Set envelope level to 0.
4. Write wave, loop, phase_inc, gain, and enable fields.
5. Write COMMIT, which reloads that slot's runtime phase to phase_init.
6. Enter ATTACK state.
```

On Note Off:

```text
1. Find every non-SILENT slot matching the MIDI channel and note.
2. Change each matching slot to RELEASE.
3. Write the runtime released flag so loop-until-release samples can play through.
4. Continue updating ENVELOPE_LEVEL until it reaches zero.
5. Disable and commit the slot when release completes.
```

This mirrors the firmware boundary: Note On/Off policy is outside the FPGA, but
the FPGA sees the exact register writes that firmware would issue.

## Envelope Calculation

The render testbench uses a linear Q1.15 implementation of the SF2 volume
envelope generators. It consumes per-region attack, decay, sustain, and release
values generated from the selected SF2 preset/instrument region.

Velocity maps linearly to peak level:

```text
voice_target = round(velocity * 0x7fff / 127)
voice_sustain = voice_target * sf2_sustain_level / 0x7fff
```

The ADSR update runs every `MIDI_ADSR_TICK_SAMPLES` output samples. With the
default 48 kHz output rate and 5 ms control tick:

```text
MIDI_ADSR_TICK_SAMPLES = round(48000 * 0.005) = 240
```

The preparation tool converts SF2 timecents and sustain centibels to Q1.15 step
sizes and levels:

```text
seconds = 2^(timecents / 1200)
sustain_level = round(0x7fff * 10^(-sustain_centibels / 200))
step = round(0x7fff / max(1, seconds / adsr_tick_seconds))
```

`delayVolEnv`, `holdVolEnv`, and key-number envelope scaling generators are not
yet modeled.

The MCU model applies the state machine:

```text
ATTACK:
  level += attack_step
  if level >= target: level = target, state = DECAY

DECAY:
  level -= decay_step
  if level <= sustain: level = sustain, state = SUSTAIN

SUSTAIN:
  level holds until Note Off

RELEASE:
  level -= release_step
  if level <= 0: level = 0, state = SILENT, disable voice
```

Every envelope update writes the voice slot's runtime `ENVELOPE_LEVEL` register.
That register updates the active value immediately and does not reload phase.

## Voice Register Programming

For voice slot `v`, the register base is:

```text
voice_base = 0x0100 + v * 0x40
```

Note On writes:

```text
CONTROL        enable + stereo
BASE_ADDR      wave-memory base word address
LENGTH         sample-frame count
LOOP_START     first loop frame
LOOP_END       exclusive loop end frame
PHASE_INIT     usually 0 for a new note
PHASE_INC      generated per MIDI note
GAIN_L/R       channel gains, currently 0x4000 by default in render-midi
PLAYBACK_MODE  sampleModes-derived loop behavior
COMMIT         1
```

Envelope ticks write only:

```text
ENVELOPE_LEVEL current Q1.15 level
```

Release completion writes `CONTROL.enable = 0` and commits the slot.

## Per-Voice RTL Rendering

The RTL multi-voice pipeline scans voice slots in index order on each
`sample_tick`. Disabled or invalid slots are skipped.

For each active voice, the current phase selects the interpolation endpoints:

```text
frame_0  = phase[31:16]
fraction = phase[15:0]

if frame_0 + 1 >= loop_end:
  frame_1 = loop_start
else:
  frame_1 = frame_0 + 1
```

Then the phase advances:

```text
phase_sum = phase + phase_inc

if phase_sum >= (loop_end << 16):
  phase = phase_sum - ((loop_end - loop_start) << 16)
else:
  phase = phase_sum
```

V1 requires `phase_inc < (loop_end - loop_start) << 16`, so one subtraction is
sufficient for wrapping.

## Memory Addressing

Wave memory addresses identify signed 16-bit words.

Mono:

```text
addr_l0 = base_addr + frame_0
addr_l1 = base_addr + frame_1
```

The fetched mono endpoints are duplicated to right-channel endpoints before gain.

Stereo:

```text
addr_l0 = base_addr + 2 * frame_0
addr_l1 = base_addr + 2 * frame_1
addr_r0 = base_addr + 2 * frame_0 + 1
addr_r1 = base_addr + 2 * frame_1 + 1
```

The memory interface is ready/valid request plus in-order response. The pipeline
issues at most one memory request at a time.

## Linear Interpolation

For each channel, `linear_interpolator.sv` computes:

```text
delta = sample_1 - sample_0
interpolated = sample_0 + ((delta * fraction) >>> 16)
```

The samples are signed 16-bit PCM. `fraction` is unsigned Q0.16. Intermediate
values keep extra sign bits so positive and negative endpoints interpolate
correctly.

## Gain And Envelope

Channel gain and envelope level both use signed Q1.15 values.

Channel gain:

```text
gained_l = saturate16((interpolated_l * gain_l) >>> 15)
gained_r = saturate16((interpolated_r * gain_r) >>> 15)
```

Runtime envelope:

```text
if envelope_level == 0x7fff:
  enveloped = gained
else:
  enveloped = saturate16((gained * envelope_level) >>> 15)
```

The full-level bypass avoids the one-LSB loss that would otherwise happen because
`0x7fff` is just below mathematical unity in Q1.15.

## Mixing

Each rendered voice contributes signed 16-bit left and right samples. The
multi-voice pipeline accumulates them in signed 32-bit registers:

```text
mix_l += enveloped_l
mix_r += enveloped_r
```

After all active slots have been processed, the mixer saturates once to signed
16-bit PCM:

```text
sample_l = clamp(mix_l, -32768, 32767)
sample_r = clamp(mix_r, -32768, 32767)
sample_valid = 1 for one cycle
```

The render testbench writes each output frame as little-endian stereo PCM. The
Python `pcm_to_wav.py` tool wraps those bytes in a WAV container.

## Worked Example

Assume a mono voice has:

```text
sample_0 = 1000
sample_1 = 2000
fraction = 0x8000
gain_l = gain_r = 0x4000
envelope_level = 0x4000
```

Interpolation:

```text
delta = 2000 - 1000 = 1000
interpolated = 1000 + ((1000 * 32768) >> 16)
             = 1000 + 500
             = 1500
```

Channel gain:

```text
gained = (1500 * 0x4000) >> 15
       = (1500 * 16384) >> 15
       = 750
```

Envelope:

```text
enveloped = (750 * 0x4000) >> 15
          = 375
```

For a mono wave, left and right receive the same raw sample before independent
channel gains, so this voice contributes:

```text
L = 375
R = 375
```

If another active voice contributes `L=500, R=500`, the mixer output before final
saturation is:

```text
mix_l = 875
mix_r = 875
```

Since both values are inside signed 16-bit range, the final output sample is
`875, 875`.
