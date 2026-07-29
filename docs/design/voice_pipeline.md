# Mono Voice-Major Block Pipeline

This document describes the production renderer behind
`voice_major_render_core`. Numeric and memory contracts are in
`../fixed_point.md` and `../memory_format.md`.

## Block Contract

One accepted request names a start frame and one through eight output frames.
The controller processes voices in voice-major order, accumulating every frame
of one voice before advancing to the next voice. Completion publishes one mix
buffer; the consumer reads its frames and explicitly releases it.

Commands and block requests share one boundary. A block is not accepted until
the command FIFO, parser, and pending dispatcher work are drained. No typed
simulation port can install state behind that boundary.

## State Ownership

| State | Owner |
| --- | --- |
| Active bit, generation, mono region, phase increment, gains, filter parameters, envelope parameters | `block_voice_state_store` |
| Advancing Q24.8 phase, envelope stage/value, biquad history | renderer writeback in the active state store |
| 32-word sample contents and tags | `voice_sample_window` |
| Per-block signed mix | `block_mix_buffer` |

`VOICE_START_MONO` atomically replaces one slot, clears phase to zero, clears
filter history, and starts a fresh envelope. Runtime GAIN, FILTER, PITCH, ENV,
and RELEASE require the same 16-bit generation. PITCH does not reload phase.

## Processing Flow

```text
voice snapshot
  -> envelope advance for requested frames
  -> mono phase and LOOP_MODE endpoint calculation
  -> 32-word per-voice sample-window lookup/refill
  -> linear interpolation
  -> optional biquad
  -> duplicate mono sample
  -> independent left/right gain and envelope
  -> block mix accumulation
  -> active-state writeback
```

The envelope front end and DSP renderer are interleaved so memory stalls for one
work item do not force all arithmetic to idle. All memory movement uses
ready/valid handshakes.

## Phase And Looping

Phase and increment are unsigned Q24.8 sample-frame units:

```text
frame_0  = phase[31:8]
fraction = phase[7:0]
frame_1  = frame_0 + 1, adjusted at the sample or loop boundary
next     = phase + phase_inc
```

START sets `phase=0`. `phase_inc=0x100` advances one source sample per output
frame; fractional increments drive interpolation.

LOOP_MODE is carried in compact START header flags `[1:0]`:

| Mode | Behavior |
| ---: | --- |
| 0 | No loop; stop contributing at `length`. |
| 1 | Wrap at exclusive `loop_end` to `loop_start`. |
| 2 | Wrap until RELEASE, then continue toward `length`. |
| 3 | Invalid command. |

The increment must be smaller than one loop span, so one subtraction is enough.

## Sample Window

Each voice has a 32-word mono window. The renderer requests both interpolation
endpoints; hits return locally. A miss requests aligned 8-word chunks in order
until the needed portion of the window is populated. A boundary endpoint that
falls outside the current window uses the documented fallback read path.

The external 8-word object is a refill transaction, not the removed line-cache
architecture. Smart Artix sends it through its DDR3 line reader and existing
read/write arbiter to the MIG app interface.

## DSP And Mix

`block_interleaved_voice_dsp` performs exact integer interpolation, optional
transposed direct-form-II biquad filtering, channel gain, envelope gain, and
explicit saturation. One mono result is duplicated before channel gain. There
is no dual-sample stereo voice.

For the 512-voice project configuration, signed 25-bit block mix samples preserve
the exact worst-case PCM16 sum without requiring mix headroom.

## Output

The board wrapper drains the completed block into `global_audio_effects_chain`.
Chorus, reverb/return mix, compressor, and master volume therefore remain in
series before the I2S output FIFO. Backpressure is held through each ready/valid
stage; no completed block is released before all requested frames are accepted.

## Verification

Focused coverage includes:

- phase 0 on START and fractional `phase_inc` interpolation;
- all LOOP_MODE values and exclusive boundaries;
- mono duplication with independent channel gains;
- generation rejection and IDs above 255;
- 32-word window hit/refill/fallback behavior;
- DDR3 timing, row hit/miss, refresh, and deadline accounting;
- effects-chain dispatch after block rendering;
- exact C++ reference comparison through the unified command stream.
