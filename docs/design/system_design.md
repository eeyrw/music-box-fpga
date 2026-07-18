# System Design Notes

This document summarizes the current RTL architecture and the next board-facing
work. Stable external contracts live in the focused documents:

- `../fixed_point.md`: integer formats and arithmetic rules.
- `../memory_format.md`: wave-memory layout and line-memory interface.
- `../register_map.md`: software-visible register contract.
- `../verification/simulation_design.md`: test and render harness behavior.
- `../board/asset_loading.md`: planned SD raw-image to DDR3 loading contract.

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
- Mono and linked-stereo sample playback with independent left/right base addresses
  and sample-window metadata.
- Loop modes: no loop, continuous loop, and loop-until-release.
- Per-channel Q1.15 gain, runtime envelope level, optional biquad IIR filter, and
  saturated stereo mixing.
- Abstract one-word memory request/response interface.
- Minimal one-line cache/burst adapter through `wave_memory_subsystem`.
- Output sample FIFO for wrappers that consume rendered PCM frames.

Board/common wrapper pieces under `fpga/common/rtl` provide the current
simulation and board-facing transport shape:

- `spi_register_bridge` adapts SPI pins to the abstract register bus.
- `fractional_tick_gen` derives sample and bit-clock ticks from a system clock.
- `i2s_tx` serializes stereo PCM to I2S pins.
- `wavetable_system_debug_regs` exposes system, audio, memory, and platform
  observability registers.
- `wavetable_spi_audio_system` composes those adapters around the generic
  register-bus and line-memory core.

## Top-Level Variants

For a directory-by-directory RTL reading map and full instantiation tree, see
`rtl_module_map.md`.

`rtl/top/wavetable_render_core.sv` is the core datapath wrapper:

```text
register bus -> voice_register_bank -> multi_voice_pipeline
                                      -> one-word memory request/response
                                      -> sample_valid + sample_l/sample_r
```

`rtl/top/wavetable_line_memory_core.sv` adds the line-memory subsystem:

```text
wavetable_render_core -> wave_memory_subsystem -> external line-read interface
```

`fpga/common/rtl/wavetable_spi_audio_system.sv` is the current pin-level wrapper:

```text
SPI pins -> spi_register_bridge -> system debug registers
                              \-> wavetable_line_memory_core -> i2s_tx -> I2S pins
                                                    |
                                                    v
                                           external line-memory pins
```

It defaults to a `100 MHz` system clock and derives `sample_tick` and I2S timing
from fractional phase-accumulator dividers. It is a simulation integration wrapper, not a board
constraint or PLL specification.
The system debug register window is implemented by
`fpga/common/rtl/wavetable_system_debug_regs.sv`, which keeps status counters,
render-latency accounting, and DDR debug-control registers out of the pin-level
wrapper.

The wrapper has two reset levels. `rst` resets the SPI bridge and system debug
registers. `core_rst` resets only playback-facing blocks: sample tick generation,
the memory-backed core, output FIFO, I2S transmitter, and render-latency state.
Debug registers remain readable while `core_rst` is asserted; non-debug core
register accesses return a bus error rather than holding the SPI transaction open.

## Rendering Pipeline

`multi_voice_pipeline` is a one-frame-at-a-time throughput renderer. On each
accepted `sample_tick`, the renderer scans voice slots in index order, reads
configuration/runtime snapshots through the register bank's synchronous read
path, asks `voice_phase_frame` for the current interpolation frames, next phase,
loop wrap, and done decisions, issues endpoint fetch contexts through
`voice_endpoint_fetch`, issues completed contexts into a fixed-latency DSP
pipeline, and retires DSP results into a signed 32-bit stereo mixer. The scan is
intentionally sequential: invalid voice slots cost a clock, but the renderer
avoids a wide per-frame priority encoder and next-voice mux.

The core state sequence is:

```text
IDLE
SCAN_VOICE
READ_VOICE
WAIT_VOICE
START_VOICE
PROCESS_VOICE
DSP_START  advance scheduler while endpoint fetch and DSP work drains
DRAIN
FINISH
IDLE
```

`voice_endpoint_fetch` serializes L0/L1/R0/R1 endpoint requests internally.
Accepted requests push compact response metadata, ordered `mem_rsp_valid` pulses
fill RAM-backed fetch slots, and a complete `voice_dsp_context_t` is pushed into a
small DSP context queue when the last required endpoint arrives. `DRAIN` waits for
the fetch engine and issued DSP contexts to empty before `FINISH` emits the mixed
sample.

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

`START_VOICE` snapshots the selected voice's configuration, runtime controls,
commit bit, and phase. `PROCESS_VOICE` advances phase after capturing the current
frame indexes. Loop wrapping uses one subtraction, so valid V1 looped voices
require `phase_inc < (loop_end - loop_start) << 8`. The extra stage keeps the
Artix-7 board implementation on the MIG `100 MHz` `ui_clk` without adding a CDC
bridge between the core and MIG app interface. Per-voice phase and biquad history
are stored behind synchronous RAM-style read paths and valid bits, so reset and
commit semantics do not force wide resettable flip-flop arrays.

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
See `../host/host_control.md` for the intended split.

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

- Note On writes wave address or linked-stereo addresses, per-channel length and
  loop range, `REGION_MODE`, phase increment, gains, runtime envelope, then
  enables and commits the slot.
- Envelope updates write only `ENVELOPE_LEVEL`; they do not reload phase.
- Runtime gain, pitch, release, and committed filter updates do not reload phase
  and update the runtime state sampled by the renderer when it accepts each voice
  snapshot.
- Note Off for loop-until-release samples writes the runtime released flag and
  then continues envelope release updates.
- When release reaches zero, software clears `CONTROL.enable` and commits the
  slot.

## Real-Time Budget

The generic simulation wrapper and current Smart Artix board wrapper both use a
`100 MHz` system clock by default. A 48 kHz output frame has about 2083 core
cycles on average with the fractional sample-tick divider. The renderer is
sequential: more active voices and more memory misses increase the latency
between `sample_tick` and `sample_valid`.

`fractional_tick_gen` owns the phase-accumulator divider used for both output
frame ticks and I2S BCLK edges when `SYS_CLK_HZ` is not an integer multiple of
the requested audio clocks. This keeps the long-term sample rate aligned to
`SAMPLE_RATE_HZ` in the single `100 MHz` domain, at the cost of one-system-clock
edge placement jitter.

The optional biquad filter arithmetic is implemented inside
`voice_dsp_pipeline`, which is the single RTL owner for interpolation, filter
coefficient multiplies, PCM saturation, gain, envelope scaling, and next filter
state calculation. The voice scheduler still owns per-voice filter state arrays
and state writeback.

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
   inferred RAM. Per-voice configuration and runtime registers are directly
   readable through multi-cycle synchronous bus reads instead of through a
   separate debug indirection. Further savings for one-bit runtime release
   and filter-enable state should be handled only if post-implementation resource
   or timing data justifies the added control complexity.

3. Design a wavetable-optimized memory subsystem.
   The current `wave_memory_subsystem` is a minimal single-line cache. A later
   revision should exploit the predictable per-voice Q24.8 phase stride with
   per-voice small line caches, demand-priority fills, and low-priority prefetch
   for the next interpolated frame or loop-wrapped frame. This likely requires
   adding a voice identifier to the core memory-request interface, or extending
   `voice_endpoint_fetch` with locality policy while keeping phase and DSP
   algorithms out of the memory adapter. Use `render-memory` hit/miss,
   response-latency, render-latency, and deadline-miss counters to compare any
   new policy against the current one-line baseline.

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

7. Keep vendor build flows incremental where the tool benefits from it.
   The Smart Artix Vivado synthesis flow now preserves the generated project,
   IP output products, and completed `synth_smart_artix_top` run under `build/` and reuses an
   up-to-date run. Source changes still reset and rerun stale completed synthesis
   runs. Future implementation scripts should use checkpoint-based incremental
   implementation where it provides a larger runtime benefit than synthesis
   project reuse.

8. Extend the audio interface.
   Add codec-facing behavior as needed: MCLK, 24-bit or 32-bit slots, mute,
   startup sequencing, reset/config policy, and BCLK/LRCLK ratio assertions.

9. Harden the SD-to-DDR3 asset-loading path on hardware.
   The Smart Artix RTL now connects native 4-bit SD loading to the DDR3 write
   side before playback starts, and `make render-board-loader` verifies raw SD
   image loading into a DDR byte model followed by exact RTL/reference rendering.
   Remaining board work is schematic-verified pins, SD clock constraints,
   generated MIG integration on real hardware, load-time/error status exposure,
   and host/MCU-owned SF2 metadata and voice policy. Runtime `.sf2` parsing remains
   outside the generic wavetable core.

10. Strengthen full-system pass/fail checks.
   Compare I2S-decoded PCM against the `render-quick` reference on short exact
   cases, record SPI transaction counts and memory stall cycles, and run longer
   high-polyphony stress cases.
