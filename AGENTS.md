# WaveTable Synth FPGA - Agent Guide

## Project Scope

This repository contains a synthesizable SystemVerilog wavetable playback core.
The current milestone is a multi-voice simulation path. Board-specific clocks,
SPI electrical timing, parallel NOR timing, synthesis projects, and I2S are out
of scope until the core behavior is covered by self-checking tests.

Read these documents before changing interfaces:

- `WaveTable_Synth_FPGA_Design_Spec_V1.md`: product architecture and roadmap.
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
- `sim/models`: behavioral models that must never appear in synthesis sources.
- `sim/tb`: self-checking SystemVerilog testbenches.
- `docs`: stable external contracts and design decisions.

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
- Stereo samples are interleaved left then right in memory.
- Register writes update shadow state only. A commit copies the complete shadow
  configuration to active state atomically.
- Runtime phase is never writable through the register bus.
- Memory requests and responses use ready/valid handshakes. Do not rely on a
  behavioral array being asynchronously readable.

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
