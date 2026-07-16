# WaveTable Synth FPGA - Agent Guide

## Project Scope

This repository contains a synthesizable SystemVerilog wavetable playback core.
The current milestone is a multi-voice simulation path with focused SPI, memory,
and I2S interface coverage. Board-specific clocks, SPI electrical timing,
parallel NOR timing, I2S clock-domain integration, synthesis projects, and FPGA
constraints remain out of scope until the generic core behavior is covered by
self-checking tests.

Read these documents before changing interfaces:

- `docs/README.md`: documentation map and category entry points.
- `docs/design/system_design.md`: current architecture and roadmap notes.
- `docs/fixed_point.md`: numeric formats and arithmetic rules.
- `docs/memory_format.md`: mono/stereo wave storage layout.
- `docs/register_map.md`: control register addresses and commit behavior.

## Directory Ownership

- `rtl/pkg`: shared constants, packed structs, and types. Keep dependencies here
  minimal because every RTL block may import this package.
- `rtl/bus`: bus protocol declarations only.
- `rtl/control`: register decoding and shadow/active control state.
- `rtl/voice`: phase and sample-fetch sequencing.
- `rtl/dsp`: stateless or streaming fixed-point signal processing.
- `rtl/audio`: audio serializers and output timing blocks.
- `sim/models`: behavioral models that must never appear in synthesis sources.
- `sim/tb`: self-checking SystemVerilog testbenches.
- `docs`: stable external contracts, design notes, verification flows, host notes,
  and board integration documentation.

Dependencies must flow from top-level/voice code toward control, DSP, bus, and
package code. A DSP primitive must not depend on a voice controller.

## RTL Rules

- Use SystemVerilog (`.sv`), `logic`, `always_ff`, and `always_comb`.
- All production files under `rtl/` must be synthesizable.
- The design has one rising-edge system clock and synchronous active-high reset.
- Sequential state changes use nonblocking assignments.
- Combinational blocks assign every output on every path; do not infer latches.
- Width and signedness must be explicit at arithmetic boundaries.
- Do not use `real`, delays, `force`, or simulator-only system tasks under `rtl/`.
- Parameters are allowed for physical widths and capacities, not to hide
  incompatible protocols in one module.
- Keep module interfaces explicit. Add a shared interface only when more than
  one producer and consumer use the exact same handshake.

## Behavioral Contracts

- PCM samples are signed 16-bit values.
- Playback position and increment use unsigned Q16.16 sample-frame units.
- Gains use signed Q1.15. Normal operating gains are from zero through 0x7fff.
- `loop_end` is exclusive. Valid loops satisfy
  `loop_start < loop_end <= length`.
- V1 requires `phase_inc < (loop_end - loop_start) << 16`; phase wrapping
  therefore needs at most one subtraction per output sample.
- Mono samples are duplicated before independent left/right gain is applied.
- Stereo samples use independent absolute left/right base addresses, lengths, and
  loop points while sharing one runtime phase increment.
- Configuration register writes update shadow state only. A commit copies the
  complete shadow configuration to active state atomically. Runtime register
  writes update runtime state without reloading phase and are sampled by the
  renderer at output-frame boundaries.
- Runtime phase position is never writable through the register bus. Runtime
  `PHASE_INC` updates are allowed through the documented pitch-control register
  and must not reload phase.
- Memory requests and responses use ready/valid handshakes. Do not rely on a
  behavioral array being asynchronously readable.

## Planned Tasks

- Move the real MIDI/SF2 render harness from generated SystemVerilog includes to
  a C++ Verilator executable. The C++ harness should parse SF2 and MIDI at
  runtime, model MCU-side preset selection, voice allocation, envelopes,
  controller policy, wave memory, and WAV output, then drive `wavetable_core`
  through its register and memory ports. Keep the existing SystemVerilog
  self-checking tests for small exact RTL regressions.

## Verification Rules

- Every behavior change needs a focused self-checking test.
- Tests compare exact integer results, including rounding and saturation.
- Cover reset, disabled state, commit isolation, loop boundaries, mono/stereo,
  fractional phase increments, and positive/negative sample extremes.
- Do not inspect waveforms as the only pass criterion. Tests must terminate with
  a nonzero result on failure.
- Run `make lint` and `make test` before considering a change complete.
- Generated output belongs under `build/` and must not be committed.

## Change Discipline

- Preserve documented interfaces unless the task explicitly changes a contract.
- Update the matching document in the same change as an interface or numeric
  behavior change.
- Prefer the smallest module that owns the behavior; do not duplicate fixed-
  point arithmetic in testbench and RTL without an independent expected-value
  calculation.
- Do not add vendor primitives to the generic core. Isolate them under `fpga/`
  when board integration begins.
