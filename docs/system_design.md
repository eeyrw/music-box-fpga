# System Design Notes

This document explains the current single-voice wavetable synthesizer core as it
exists in this repository. It is written as a learning guide for reading the RTL,
not as a future feature list.

## Goal

The current system plays one configured wave from an abstract 16-bit sample
memory and produces signed 16-bit stereo PCM samples. The design focuses on the
hardware-independent audio core before board-specific clocks, Flash timing, SPI,
I2S, multiple voices, and mixing are added.

At this stage, the system is intentionally small:

- One system clock, rising-edge triggered.
- Synchronous active-high reset.
- One active voice.
- One abstract memory request/response port.
- One sample output per `sample_tick` request.
- Register writes update shadow state until software explicitly commits them.

## Top-Level Blocks

```text
Register Bus
    |
    v
voice_register_bank
    | active_config + config_valid + commit_pulse
    v
voice_pipeline
    |                      ^
    | mem_req_valid/addr   | mem_rsp_valid/data
    v                      |
Abstract Wave Memory ------+
    |
    v
sample_valid + sample_l + sample_r
```

The top-level module is `rtl/top/wavetable_core.sv`. It connects two major RTL
blocks:

- `voice_register_bank`: owns bus decoding, shadow registers, active registers,
  and commit behavior.
- `voice_pipeline`: owns playback phase, sample fetch sequencing, interpolation,
  gain, and output sample timing.

The memory is not implemented inside the core. The core only issues abstract
ready/valid memory requests. This keeps the audio logic independent from the
eventual storage implementation.

## Numeric Formats

The shared types live in `rtl/pkg/synth_pkg.sv`.

PCM samples are signed 16-bit integers:

```text
-32768 .. +32767
```

Playback phase uses unsigned Q16.16 sample-frame units:

```text
phase[31:16] = integer sample frame index
phase[15:0]  = fractional position between frame and next frame
```

A `phase_inc` of `0x0001_0000` means the voice advances by exactly one source
sample frame for each output sample. Smaller values slow playback down; larger
values speed playback up.

Gains use signed Q1.15. The normal unity gain value is `0x7fff`, which is just
under mathematical 1.0. A gain of `0x4000` is approximately 0.5.

## Register Configuration

The register map is documented in `docs/register_map.md` and implemented by
`rtl/control/voice_register_bank.sv`.

The important design choice is shadow-vs-active state:

- Bus writes update `shadow_config`.
- Playback reads only `active_config`.
- Writing the commit register copies the complete shadow config to active config.
- The commit also emits a one-cycle `commit_pulse` so the voice can reload
  runtime phase from `phase_init`.

This prevents half-written settings from affecting a running voice. For example,
software can write a new base address, length, loop range, phase increment, and
gains in any order. The voice does not see the new setup until the final commit.

## Valid Configuration

A committed configuration is valid when:

```text
length != 0
loop_start < loop_end
loop_end <= length
```

`loop_end` is exclusive. A loop from `loop_start=10` to `loop_end=20` contains
frames 10 through 19.

The current V1 contract also requires:

```text
phase_inc < (loop_end - loop_start) << 16
```

That rule means one output sample can cross the loop boundary at most once, so
the phase wrap logic only needs one subtraction.

## Wave Memory Layout

Wave memory addresses identify signed 16-bit words.

Mono memory uses one word per frame:

```text
addr(frame n) = base_addr + n
```

Stereo memory is left/right interleaved:

```text
left(frame n)  = base_addr + 2*n
right(frame n) = base_addr + 2*n + 1
```

The `stereo` bit in the active config selects the addressing mode. Mono samples
are duplicated to both channels before left and right gains are applied.

## Voice Pipeline

The voice pipeline has one small state machine:

```text
IDLE
REQ_L0  -> WAIT_L0
REQ_L1  -> WAIT_L1
REQ_R0  -> WAIT_R0   only for stereo
REQ_R1  -> WAIT_R1   only for stereo
PRODUCE
IDLE
```

For each requested output sample, the pipeline captures two source frame indices:

```text
frame_0  = phase[31:16]
frame_1  = frame_0 + 1, or loop_start if that crosses loop_end
fraction = phase[15:0]
```

It then fetches the two interpolation endpoints for each needed channel. Mono
mode fetches only left endpoints and copies them to the right raw endpoints.

After memory responses arrive, the combinational DSP blocks calculate:

```text
interpolated = sample_0 + ((sample_1 - sample_0) * fraction >> 16)
output       = saturate(interpolated * gain >> 15)
```

The state machine raises `sample_valid` for one cycle in `PRODUCE`.

## Memory Handshake

The memory interface is deliberately abstract:

```text
request transfers when mem_req_valid && mem_req_ready
response transfers when mem_rsp_valid
responses must be in request order
```

The core does not assume asynchronous reads. The simulation model returns data
one cycle after a request, but a future memory controller can add latency as long
as it preserves the ready/valid contract and response order.

## DSP Blocks

`rtl/dsp/linear_interpolator.sv` is combinational. It keeps extra bits around the
subtraction and multiply so signed endpoints interpolate correctly.

`rtl/dsp/gain_saturate.sv` is also combinational. It multiplies signed PCM by a
signed Q1.15 gain, shifts back to PCM units, and clamps to signed 16-bit range.

Keeping these blocks stateless makes them easy to test and easy to reuse when a
future multi-voice mixer is added.

## Current Limitations

The current core does not implement:

- Multiple simultaneous voices.
- SF2 envelope, filter, modulator, velocity, or preset logic.
- A mixer.
- I2S serialization.
- External Flash timing.
- SPI register transport.

The SoundFont render flow extracts sample data and loop/tuning information for
one instrument zone, then uses the existing wavetable playback hardware to render
audio. It is a practical bridge from real sample data to the current RTL, not a
complete SoundFont synthesizer.
