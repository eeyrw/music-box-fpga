# System Design Notes

This document summarizes the current RTL architecture and the next board-facing
work. Stable external contracts live in the focused documents:

- `docs/fixed_point.md`: integer formats and arithmetic rules.
- `docs/memory_format.md`: wave-memory layout and line-memory interface.
- `docs/register_map.md`: software-visible register contract.
- `docs/simulation_design.md`: test and render harness behavior.

## Current Scope

The repository contains a synthesizable, single-clock wavetable playback core and
simulation wrappers for SPI control, line-memory traffic, and I2S output. The
generic RTL is intentionally independent of board PLLs, physical Flash timing,
vendor memory IP, and FPGA constraints.

Implemented RTL pieces:

- 32 committed voice slots with shadow/active register state.
- Unsigned Q16.16 playback phase and runtime phase-increment updates.
- Mono and interleaved stereo sample playback.
- Loop modes: no loop, continuous loop, and loop-until-release.
- Per-channel Q1.15 gain, runtime envelope level, optional one-pole LPF, and
  saturated stereo mixing.
- Abstract one-word memory request/response interface.
- Minimal one-line cache/burst adapter through `wave_memory_subsystem`.
- Simulation-friendly SPI register transport through `spi_register_bridge`.
- Fixed 48 kHz stereo I2S transmit path through `i2s_tx`.

## Top-Level Variants

`rtl/top/wavetable_core.sv` is the core datapath wrapper:

```text
register bus -> voice_register_bank -> multi_voice_pipeline
                                      -> one-word memory request/response
                                      -> sample_valid + sample_l/sample_r
```

`rtl/top/wavetable_core_memory.sv` adds the line-memory subsystem:

```text
wavetable_core -> wave_memory_subsystem -> external line-read interface
```

`rtl/top/wavetable_core_spi.sv` exposes the register bus through SPI pins while
leaving the core memory and sample interfaces abstract.

`rtl/top/wavetable_core_system.sv` is the current pin-level simulation wrapper:

```text
SPI pins -> spi_register_bridge -> wavetable_core_memory -> i2s_tx -> I2S pins
                                      |
                                      v
                             external line-memory pins
```

It uses a fixed `49.152 MHz` system clock and generates one `sample_tick` every
1024 cycles for 48 kHz audio. It is a simulation integration wrapper, not a board
constraint or PLL specification.

## Rendering Pipeline

`multi_voice_pipeline` is a time-multiplexed renderer. On each `sample_tick`, it
scans voice slots in index order, skips disabled or invalid slots, fetches the
needed interpolation endpoints, processes one voice through the shared DSP path,
and accumulates into a signed 32-bit stereo mixer.

The core state sequence is:

```text
IDLE
START_VOICE
REQ_L0  -> WAIT_L0
REQ_L1  -> WAIT_L1
REQ_R0  -> WAIT_R0   stereo only
REQ_R1  -> WAIT_R1   stereo only
ACCUMULATE
FINISH
IDLE
```

The generated sample uses these integer operations:

```text
frame_0      = phase[31:16]
frame_1      = next frame, clamped or loop-wrapped as needed
fraction     = phase[15:0]
interpolated = sample_0 + ((sample_1 - sample_0) * fraction >>> 16)
gained       = saturate(interpolated * gain >>> 15)
enveloped    = gained when envelope_level == 0x7fff
enveloped    = saturate(gained * envelope_level >>> 15) otherwise
mix_accum   += enveloped
```

Phase is advanced after capturing the current frame indexes. Loop wrapping uses
one subtraction, so valid V1 looped voices require `phase_inc < (loop_end -
loop_start) << 16`.

## Control Model

The RTL does not parse MIDI or SoundFont data. A host, MCU, soft core, or
simulation model owns:

- preset and region lookup,
- voice allocation and stealing,
- Note On and Note Off policy,
- envelope stepping,
- MIDI controller policy,
- asset loading into wave memory.

The hardware contract is register-level:

- Note On writes wave address, length, loop range, phase increment, gains,
  runtime envelope, playback mode, then commits the slot.
- Envelope updates write only `ENVELOPE_LEVEL`; they do not reload phase.
- Note Off for loop-until-release samples writes the runtime released flag and
  then continues envelope release updates.
- When release reaches zero, software clears `CONTROL.enable` and commits the
  slot.

## Real-Time Budget

At 49.152 MHz and 48 kHz, one output frame has a fixed budget of 1024 system
clock cycles. The current renderer is sequential: more active voices and more
memory misses increase the latency between `sample_tick` and `sample_valid`.

The practical board question is whether all active voices can render before the
I2S transmitter needs the next frame. If not, the next architecture work is an
output FIFO, deeper prefetch/cache behavior, or a more overlapped voice scheduler,
not simply increasing `NUM_VOICES`.

Minimum measurements before board migration:

- worst-case `sample_valid - sample_tick` latency,
- cache hit/miss counts and memory stall cycles,
- output FIFO level and underrun count,
- steady-state `sample_drop_pulse == 0`,
- high-polyphony MIDI/SF2 stress cases with stereo samples and release tails.

## Board-Level Backlog

The current `make render-full-system` path verifies the pin-level integration of
SPI control, line-memory traffic, fixed 48 kHz audio ticks, and I2S output. It
still uses idealized C++ models around the RTL. The next board-proximity tasks
are, in priority order:

1. Add an output FIFO and deadline accounting.
   Record render latency, FIFO level, startup underrun, steady-state underrun, and
   sample drops. Fail full-system tests on steady-state underrun or any sample
   drop.

2. Replace the C++ storage model with concrete memory-controller models.
   Candidate first targets are parallel NOR and SPI/QSPI Flash. Model command
   overhead, bus turnaround, burst alignment, cache misses, prefetch, and request
   backpressure.

3. Split board clocks and reset sequencing.
   Separate system/control, memory, and audio clocks where the board requires it,
   then add CDC or asynchronous FIFOs at each boundary.

4. Harden SPI timing assumptions.
   Define the supported SPI mode, SCLK-to-system-clock timing limits, CS
   setup/hold, read turnaround timing, and any board wrapper synchronizers.

5. Extend the audio interface.
   Add codec-facing behavior as needed: MCLK, 24-bit or 32-bit slots, mute,
   startup sequencing, reset/config policy, and BCLK/LRCLK ratio assertions.

6. Define the asset-loading contract.
   Runtime `.sf2` parsing is simulation-only. Define a preprocessed flash image,
   region metadata tables, preset selection policy, controller handling, and how
   the MCU loads or streams those assets before programming voices.

7. Strengthen full-system pass/fail checks.
   Compare I2S-decoded PCM against the `render-quick` reference on short exact
   cases, record SPI transaction counts and memory stall cycles, and run longer
   high-polyphony stress cases.
