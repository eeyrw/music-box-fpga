# System Design Notes

This document summarizes the current RTL architecture and the next board-facing
work. Stable external contracts live in the focused documents:

- `docs/fixed_point.md`: integer formats and arithmetic rules.
- `docs/memory_format.md`: wave-memory layout and line-memory interface.
- `docs/register_map.md`: software-visible register contract.
- `docs/simulation_design.md`: test and render harness behavior.
- `docs/asset_loading.md`: planned SD raw-image to DDR3 loading contract.

## Current Scope

The repository contains a synthesizable, single-clock wavetable playback core and
simulation wrappers for SPI control, line-memory traffic, and I2S output. The
generic RTL is intentionally independent of board PLLs, physical Flash timing,
vendor memory IP, and FPGA constraints.

Implemented RTL pieces:

- 32 committed voice slots with shadow configuration and BRAM-backed active
  renderer snapshots.
- Separate per-voice configuration state and runtime control state, with runtime
  updates sampled at output-frame boundaries.
- Unsigned Q24.8 playback phase and runtime phase-increment updates.
- Mono and linked-stereo sample playback with independent left/right base addresses.
- Loop modes: no loop, continuous loop, and loop-until-release.
- Per-channel Q1.15 gain, runtime envelope level, optional biquad IIR filter, and
  saturated stereo mixing.
- Abstract one-word memory request/response interface.
- Minimal one-line cache/burst adapter through `wave_memory_subsystem`.
- Simulation-friendly SPI register transport through `spi_register_bridge`.
- Fixed 48 kHz stereo I2S transmit path through `i2s_tx`.
- Output sample FIFO and render-deadline observability in the full-system wrapper.

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

`multi_voice_pipeline` is a time-multiplexed renderer. On each accepted
`sample_tick`, the renderer scans voice slots in index order, reads each active
configuration/runtime snapshot through the register bank's synchronous read path,
skips disabled or invalid slots, fetches the needed interpolation endpoints,
processes one voice through the shared DSP path, and accumulates into a signed
32-bit stereo mixer.

The core state sequence is:

```text
IDLE
READ_VOICE
WAIT_VOICE
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
frame_0      = phase[31:8]
frame_1      = next frame, clamped or loop-wrapped as needed
fraction     = phase[7:0]
interpolated = sample_0 + ((sample_1 - sample_0) * fraction >>> 8)
gained       = saturate(interpolated * gain >>> 15)
enveloped    = gained when envelope_level == 0x7fff
enveloped    = saturate(gained * envelope_level >>> 15) otherwise
mix_accum   += enveloped
```

Phase is advanced after capturing the current frame indexes. Loop wrapping uses
one subtraction, so valid V1 looped voices require `phase_inc < (loop_end -
loop_start) << 8`.

## Control Model

The RTL does not parse MIDI or SoundFont data. A host, MCU, soft core, or
simulation model owns:

- preset and region lookup,
- voice allocation and stealing,
- Note On and Note Off policy,
- envelope stepping,
- MIDI controller policy,
- asset loading into wave memory.

The current C++ render harness keeps this policy in reusable host-side code.
`McuModel` owns voice allocation and envelope stepping, while
`RegisterVoiceControl` converts voice operations into register writes through a
small `RegisterWriteSink` interface. A PC tool using CH347 USB-to-SPI should
reuse that policy layer and provide only the hardware-backed register transport.
See `docs/host_control.md` for the intended split.

The SF2 feature boundary is intentionally split by update rate and audio-path
ownership. SF2 filter audio processing belongs in RTL because it operates on each
voice's PCM stream; software calculates cutoff/Q/modulation values and writes the
filter controls. Pitch bend, vibrato, tremolo, and modulation-envelope effects are
host-driven first through runtime register updates because the SPI path is
expected to have enough bandwidth for the initial implementation. If those
updates need sample-accurate timing or produce audible stepping, the LFO/envelope
state machines can move into RTL later. Reverb/chorus, strict complex linked
stereo pairing, and higher-polyphony layered playback are deferred architecture
items.

The hardware contract is register-level:

- Note On writes wave address or linked-stereo addresses, length, loop range, phase increment, gains,
  runtime envelope, `LOOP_MODE`, then commits the slot.
- Envelope updates write only `ENVELOPE_LEVEL`; they do not reload phase.
- Runtime gain, pitch, release, and committed filter updates do not reload phase
  and update the runtime state sampled by the renderer when it accepts each voice
  snapshot.
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
- steady-state `render_deadline_miss_pulse == 0`,
- high-polyphony MIDI/SF2 stress cases with stereo samples and release tails.

## Board-Level Backlog

The current `make render-full-system` path verifies the pin-level integration of
SPI control, line-memory traffic, fixed 48 kHz audio ticks, and I2S output. It
still uses idealized C++ models around the RTL. The next board-proximity tasks
are, in priority order:

Board-specific synthesis and bring-up files belong under `fpga/`. The current
`fpga/board_template/` directory is a starting point for a concrete board
directory; it records the required top-level wrapper, clocking, constraints,
memory-controller, audio, asset-image, and tool-flow decisions without binding
the generic RTL to one vendor flow.

1. Strengthen output FIFO and deadline accounting.
   The full-system wrapper now records render latency, FIFO level, deadline
   misses, I2S underruns, and sample drops. Next, fail longer full-system stress
   tests on steady-state deadline misses, underruns, or sample drops.

2. Continue voice-control storage reduction where it is worth the protocol cost.
   The latest register-bank passes moved active configuration, shadow register
   state, runtime filter coefficients, and runtime phase/gain/envelope state into
   inferred RAM and removed large direct per-voice readback muxes from the main
   bus path. The staged readback window preserves low-rate inspection without
   restoring the old direct mux. Further savings for one-bit runtime release and
   filter-enable state should be handled only if post-implementation resource or
   timing data justifies the added control complexity.

3. Design a wavetable-optimized memory subsystem.
   The current `wave_memory_subsystem` is a minimal single-line cache. A later
   revision should exploit the predictable per-voice Q24.8 phase stride with
   per-voice small line caches, demand-priority fills, and low-priority prefetch
   for the next interpolated frame or loop-wrapped frame. This likely requires
   adding a voice identifier to the core memory-request interface, or otherwise
   moving the cache closer to `multi_voice_pipeline` so the memory subsystem can
   preserve locality across interleaved voices. Use `render-memory` hit/miss,
   response-latency, render-latency, and deadline-miss counters to compare this
   against the current one-line baseline.

4. Replace the C++ storage model with concrete DDR3 controller models.
   The current board target is a Micron `MT41K256M16TW` DDR3 device behind a
   Xilinx MIG wrapper. Model burst alignment, calibration delay, cache misses,
   prefetch, and request backpressure before relying on hardware timing.

5. Split board clocks and reset sequencing.
   Separate system/control, memory, and audio clocks where the board requires it,
   then add CDC or asynchronous FIFOs at each boundary.

6. Harden SPI timing assumptions.
   Define the supported SPI mode, SCLK-to-system-clock timing limits, CS
   setup/hold, read turnaround timing, and any board wrapper synchronizers.

7. Extend the audio interface.
   Add codec-facing behavior as needed: MCLK, 24-bit or 32-bit slots, mute,
   startup sequencing, reset/config policy, and BCLK/LRCLK ratio assertions.

8. Implement the SD-to-DDR3 asset-loading path.
   `docs/asset_loading.md` defines the first board contract: an SD raw image with
   a small header, FPGA-side sector reads and DDR3 write DMA, and host/MCU-owned
   SF2 metadata and voice policy. Runtime `.sf2` parsing remains outside the
   generic wavetable core.

9. Strengthen full-system pass/fail checks.
   Compare I2S-decoded PCM against the `render-quick` reference on short exact
   cases, record SPI transaction counts and memory stall cycles, and run longer
   high-polyphony stress cases.
