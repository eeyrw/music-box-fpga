# System Design Notes

This document explains the current multi-voice wavetable synthesizer core as it
exists in this repository. It is written as a learning guide for reading the RTL,
not as a future feature list.

## Goal

The current system plays several configured waves from an abstract 16-bit sample
memory and produces signed 16-bit stereo PCM samples. The design focuses on the
hardware-independent audio core before board-specific clocks, Flash timing, SPI,
and I2S are added.

At this stage, the system is intentionally small:

- One system clock, rising-edge triggered.
- Synchronous active-high reset.
- Four active voice slots.
- One abstract memory request/response port.
- One sample output per `sample_tick` request.
- Register writes update shadow state until software explicitly commits them.
- One shared multi-voice rendering pipeline and saturated stereo mixer.

## Top-Level Blocks

```text
Register Bus
    |
    v
voice_register_bank
    | active voice configs + valid/commit bits
    v
multi_voice_pipeline
    |                      ^
    | mem_req_valid/addr   | mem_rsp_valid/data
    v                      |
Abstract Wave Memory ------+
    |
    v
envelope + saturated mixer -> sample_valid + sample_l/sample_r
```

The top-level module is `rtl/top/wavetable_core.sv`. It connects two major RTL
blocks:

- `voice_register_bank`: owns bus decoding, per-voice shadow registers, active
  registers, and commit behavior.
- `multi_voice_pipeline`: owns per-voice runtime phase, sample fetch sequencing,
  interpolation, current envelope level, saturated mixing, and output timing.

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

The important design choice is shadow-vs-active state for each voice slot:

- Bus writes update that slot's `shadow_config`.
- Playback reads only that slot's `active_config`.
- Writing the slot's commit register copies the complete shadow config to active
  config.
- The commit also emits a one-cycle `commit_pulse` so that slot can reload
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

## Multi-Voice Pipeline

The multi-voice pipeline is a time-multiplexed renderer. It does not instantiate
one full fetch/interpolate/gain datapath per voice. Instead, it keeps per-voice
runtime phase registers, scans voice slots in index order on each `sample_tick`,
skips disabled or invalid slots, renders each active slot through one shared DSP
datapath, and accumulates the result into a signed 32-bit stereo mixer.

This is a sequential functional baseline, not a fully overlapped CPU-style
pipeline. Throughput and 32-voice scaling considerations are discussed in
`docs/performance_budget.md`.

This matches the current single-port wave-memory interface. At any moment the
core issues at most one memory request. More voices increase the latency between
`sample_tick` and `sample_valid`, but they do not change the external memory
handshake.

```text
IDLE
START_VOICE
REQ_L0  -> WAIT_L0
REQ_L1  -> WAIT_L1
REQ_R0  -> WAIT_R0   only for stereo
REQ_R1  -> WAIT_R1   only for stereo
ACCUMULATE
FINISH
IDLE
```

The states have these responsibilities:

- `IDLE`: wait for `sample_tick`.
- `START_VOICE`: select the current slot, skip it if disabled or invalid, or
  capture phase-derived frame indices for rendering.
- `REQ_L0`/`WAIT_L0`: request and capture the first left or mono endpoint.
- `REQ_L1`/`WAIT_L1`: request and capture the second left or mono endpoint.
- `REQ_R0`/`WAIT_R0`: request and capture the first right endpoint for stereo
  waves only.
- `REQ_R1`/`WAIT_R1`: request and capture the second right endpoint for stereo
  waves only.
- `ACCUMULATE`: apply interpolation, channel gain, current envelope level, and
  add the voice contribution into the mixer accumulator.
- `FINISH`: saturate the mixer accumulator to signed 16-bit stereo PCM and raise
  `sample_valid` for one cycle.

Each voice slot has its own runtime phase register inside
`multi_voice_pipeline`. A `COMMIT` pulse for one slot reloads only that slot's
phase from `phase_init`. `ENVELOPE_LEVEL` is active runtime state in the register
bank: writes update it immediately, and commits preserve it while replacing the
rest of the active voice configuration. Runtime envelope writes do not assert
`COMMIT` and do not affect phase.

For each active voice in the requested output sample, the pipeline captures two
source frame indices:

```text
frame_0  = phase[31:16]
frame_1  = frame_0 + 1, or loop_start if that crosses loop_end
fraction = phase[15:0]
```

It then fetches the two interpolation endpoints for each needed channel. Mono
mode fetches only left endpoints and copies them to the right raw endpoints.
Stereo mode fetches four memory words: left frame 0, left frame 1, right frame 0,
and right frame 1. Memory responses must arrive in request order.

After memory responses arrive, the combinational DSP blocks calculate:

```text
interpolated = sample_0 + ((sample_1 - sample_0) * fraction >> 16)
gained       = saturate(interpolated * gain >> 15)
enveloped    = gained, when envelope_level == 0x7fff
enveloped    = saturate(gained * envelope_level >> 15), otherwise
mix_accum   += enveloped
```

The state machine raises `sample_valid` for one cycle in `FINISH` after
saturating the stereo mixer accumulator back to signed 16-bit PCM.

For a step-by-step numerical trace of event timing, phase increment, envelope,
interpolation, gain, and mixing, see `docs/audio_render_calculation.md`.

## MCU-Controlled Notes And Envelopes

The FPGA core does not know about musical Note On, Note Off, voice stealing,
velocity curves, SoundFont preset lookup, or ADSR calculation. Those are MCU or
simulation-control responsibilities. The hardware contract is lower level:

- Note On: the MCU chooses a free voice slot, writes wave address, loop range,
  `phase_init`, `phase_inc`, gains, and an initial `envelope_level`, then commits
  the slot.
- Sustain or attack/decay updates: the MCU writes `ENVELOPE_LEVEL` while the slot
  is active. This write updates active runtime state immediately and does not
  reload phase.
- Note Off: the MCU starts its release calculation and continues writing smaller
  `ENVELOPE_LEVEL` values.
- Voice free: when release reaches zero, the MCU clears `CONTROL.enable` and
  commits that slot, making it available for another note.

Simulation should model this MCU behavior in the testbench or a simulation-only
controller module. The RTL is then tested through the same register bus the real
MCU will use, without moving preset or envelope policy into synthesizable audio
hardware.

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
signed Q1.15 gain or envelope level, shifts back to PCM units, and clamps to
signed 16-bit range.

Keeping these blocks stateless lets the multi-voice pipeline reuse one datapath
across all voice slots.

## Current Limitations

The current core implements multiple simultaneous voices and a saturated stereo
mixer, but it does not implement:

- SF2 preset selection, velocity mapping, modulators, or ADSR calculation.
- Output filter characteristics.
- I2S serialization.
- External Flash timing.
- SPI register transport.

The SoundFont render flow extracts sample data and loop/tuning information for
one instrument zone, then uses the existing wavetable playback hardware to render
audio. Loop points, frequency step (`phase_inc`), and current envelope level are
hardware inputs; higher-level SoundFont behavior stays on the software/control
side.
