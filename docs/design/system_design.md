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
- Per-voice/per-stream two-line cache through `voice_line_cache` on the cached
  render path, including conservative next-line stride prefetch, plus a minimal
  single-line `wave_memory_subsystem` baseline adapter for some common/board
  wrappers.
- Output sample FIFO for wrappers that consume rendered PCM frames.

Board/common wrapper pieces under `fpga/common/rtl` provide the current
simulation and board-facing transport shape:

- `spi_register_bridge` adapts SPI pins to the abstract register bus.
- `fractional_tick_gen` derives sample and bit-clock ticks from a system clock.
- `i2s_tx` serializes stereo PCM to I2S pins.
- `sd_native_block_reader` implements the reusable native-SD command and block
  byte-stream reader.
- `sd_native_pin_phy` implements the reusable native-SD FPGA-pin PHY above
  `SD_CLK`, `CMD`, and `DAT[3:0]`.
- `wavetable_common_status_regs` exposes system, audio, memory, and render-latency
  observability registers.
- `wavetable_system_core` exposes the line-memory render core behind an abstract
  register bus and PCM frame output, without SPI or I2S transport.
- `wavetable_i2s_output` adapts PCM frames through the output FIFO and I2S
  serializer.
- `wavetable_demo_system` composes SPI control, common status registers, sample-clock
  generation, the reusable system core, and the I2S output adapter for the
  current pin-level demo path.

Generic RTL module-to-module connections use shared packed structs from
`rtl/pkg/synth_pkg.sv` where a group of fields is a stable protocol: the register
bank consumes `reg_bus_req_t` and emits `reg_bus_rsp_t`, while the core-side
wavetable read path uses `wave_word_req_t` and `wave_word_rsp_t` plus a separate
request-ready signal. External wrapper ports may keep those same fields expanded
as individual pins so Verilator harnesses, board transports, and top-level
integration points remain explicit.

## Top-Level Variants

For a directory-by-directory RTL reading map and full instantiation tree, see
`rtl_module_map.md`.

`rtl/top/wavetable_render_core.sv` is the core datapath wrapper:

```text
register bus -> voice_register_bank -> multi_voice_pipeline
                                      -> one-word memory request/response
                                      -> sample_valid + sample_l/sample_r
```

`rtl/top/wavetable_cached_render_core.sv` adds the per-voice line cache:

```text
wavetable_render_core -> voice_line_cache -> external line-read interface
```

`fpga/common/rtl/wavetable_system_core.sv` is the reusable system core:

```text
register bus -> wavetable_render_core -> wave_memory_subsystem -> external line-memory pins
                                      \
                                       -> PCM frames
```

`fpga/common/rtl/wavetable_i2s_output.sv` is the reusable audio-output adapter:

```text
PCM frames -> output_sample_fifo -> i2s_tx -> I2S pins
```

`fpga/common/rtl/wavetable_demo_system.sv` is the current pin-level demo wrapper:

```text
SPI pins -> spi_register_bridge -> common status registers
                              \-> platform register window
                              \-> wavetable_system_core -> wavetable_i2s_output
```

It defaults to a `100 MHz` system clock and derives `sample_tick` and I2S timing
from fractional phase-accumulator dividers. It is a simulation integration wrapper, not a board
constraint or PLL specification.
The common status register window is implemented by
`fpga/common/rtl/wavetable_common_status_regs.sv`, which keeps status counters,
render-latency accounting, and memory-cache counters out of the pin-level
wrapper. Board-specific platform status and DDR register-access registers are
implemented outside the common wrapper; the Smart Artix board uses
`fpga/smart_artix/rtl/smart_artix_platform_regs.sv`.

The wrapper has two reset levels. `rst` resets the SPI bridge and common status
registers. `core_rst` resets only playback-facing blocks: sample tick generation,
the memory-backed core, output FIFO, I2S transmitter, and render-latency state.
Common status registers remain readable while `core_rst` is asserted; core
register-window accesses return a bus error rather than holding the SPI
transaction open.

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
post_filter  = filter_enable ? biquad(interpolated) : sign_extend_20(interpolated)
voice_sample = saturate(post_filter * gain >>> 15) when envelope_level == 0x7fff
voice_sample = saturate(post_filter * gain * envelope_level >>> 30) otherwise
mix_accum   += voice_sample
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
  loop range, phase increment, gains, initial envelope, and filter settings, then
  writes `VOICE_CONTROL` with enable and apply set.
- Envelope updates write only `ENVELOPE_RUNTIME`; they do not reload phase.
- Runtime gain, pitch, release, and committed filter updates do not reload phase
  and update the runtime state sampled by the renderer when it accepts each voice
  snapshot.
- Note Off for loop-until-release samples writes the runtime released flag and
  then continues envelope release updates.
- When release reaches zero, software writes `VOICE_CONTROL` with enable clear
  and apply set.

## Real-Time Budget

The generic simulation wrapper and current Smart Artix board wrapper both use a
`100 MHz` system clock by default. A 48 kHz output frame has about 2083 core
cycles on average with the fractional sample-tick divider. The renderer is
sequential: more active voices and more external line requests increase the
latency between `sample_tick` and `sample_valid`.

`fractional_tick_gen` owns the phase-accumulator divider used for both output
frame ticks and I2S BCLK edges when `SYS_CLK_HZ` is not an integer multiple of
the requested audio clocks. This keeps the long-term sample rate aligned to
`SAMPLE_RATE_HZ` in the single `100 MHz` domain, at the cost of one-system-clock
edge placement jitter.

The optional biquad filter arithmetic is implemented inside
`voice_dsp_pipeline`, which is the single RTL owner for interpolation, filter
coefficient multiplies, signed 20-bit post-filter sample limiting, final PCM
saturation, gain, envelope scaling, and next filter state calculation. The voice
scheduler still owns per-voice filter state arrays and state writeback.

The practical board question is whether all active voices can render before the
I2S transmitter needs the next frame. If not, the next architecture work is an
output FIFO, deeper prefetch/cache behavior, or a more overlapped voice scheduler,
not simply increasing `NUM_VOICES`.

The current 100 MHz / 48 kHz budget is about 2083 core cycles per stereo output
frame. The arithmetic and scheduler path is estimated to fit the normal
`NUM_VOICES = 256` build if endpoint samples are served ideally, but the present
one-outstanding memory adapter is expected to limit practical polyphony before
the arithmetic pipe does. `voice_line_cache` now keeps two cached lines per
voice/stream pair, separating mono/left reads from right stereo reads; this
removed the worst linked-stereo cache self-eviction seen in the fixed DDR stress
window. The detailed method, formulas, assumptions, and caveats are recorded in
`voice_pipeline.md`.

Minimum measurements before board migration:

- worst-case `sample_valid - sample_tick` latency,
- cache hit/miss counts and memory stall cycles,
- stride-prefetch issued/filled/used/drop/late counts,
- output FIFO level and underrun count,
- steady-state `sample_drop_pulse == 0`,
- steady-state `render_deadline_miss_pulse == 0`,
- high-polyphony MIDI/SF2 stress cases with stereo samples and release tails.

### Current Stress Snapshot

The first render-counter and conservative stride-prefetch pass was checked with:

```bash
make render-memory MEMORY_PROFILE=ddr START_SECONDS=144 SECONDS=20 \
  SF2="/home/yuan/下载/SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2" \
  MIDI="/media/yuan/60AE34D2AE34A308/Users/yuan/Desktop/midi合集/Hedwigs_Themefinished.mid"
```

The run was interrupted near completion after `953,371` of `960,000` requested
stereo frames so the partial JSON could be inspected. The RTL counters had
completed `953,370` frames with `avg_render_cycles = 1441.78`,
`max_render_cycles = 2351`, `deadline_misses = 0`, `over_budget_frames = 9`, and
`max_over_budget_cycles = 268` against the 100 MHz / 48 kHz integer budget of
`2083` cycles. The cache recorded `21,239,692` demand misses,
`7,965,833` prefetches issued, and `887,025` prefetches used. That puts the
first conservative `prefetch_used / prefetch_issued` ratio at about `11.1%`.

Interpretation: the render path now has enough RTL observability to answer the
deadline question directly. This stress window did not miss deadlines, but it
still produced a small number of over-budget completed frames and the simple
second-half next-line prefetch has a low useful-prefetch ratio. The next cache
work should therefore improve prediction quality and demand stall reduction
rather than only increasing the number of speculative reads.

The follow-up stream-local cache pass was checked with the same SGM/Hedwig input
using a shorter fixed window:

```bash
make render-memory MEMORY_PROFILE=ddr START_SECONDS=164 SECONDS=5 \
  SF2="/home/yuan/下载/SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2" \
  MIDI="/media/yuan/60AE34D2AE34A308/Users/yuan/Desktop/midi合集/Hedwigs_Themefinished.mid"
```

Against the pre-stream-local baseline for that 164s to 169s window, demand
misses fell from `1,856,176` to `262,933`, external line requests fell from
`2,772,578` to `697,665`, and useful prefetch ratio improved from about `19.4%`
to about `86.7%`. Average render cycles moved from `688.391` to `645.828`, max
render cycles moved from `1251` to `1047`, and both runs had
`deadline_misses = 0` and `over_budget_frames = 0`. The next measured policy
change should therefore be phase-aware prefetch rather than more blind
speculation.

## Board-Level Backlog

The old C++ full-system render path has been removed; it was too slow and still
depended on idealized C++ models around the RTL. Board-proximity verification now
stays focused on small peripheral tests and board-loader render coverage until a
real board wrapper and timing model are ready. The next board-proximity tasks
are, in priority order:

Board-specific synthesis and bring-up files belong under `fpga/`. The current
`fpga/board_template/` directory is a starting point for a concrete board
directory; it records the required top-level wrapper, clocking, constraints,
memory-controller, audio, asset-image, and tool-flow decisions without binding
the generic RTL to one vendor flow.

1. Strengthen output FIFO and deadline accounting.
   Keep focused I2S/FIFO tests self-checking, and add small integration cases
   only when the clocking and memory models match the intended board wrapper.

2. Continue voice-control storage reduction where it is worth the protocol cost.
   The latest register-bank passes moved active configuration, shadow register
   state, runtime filter coefficients, and runtime phase/gain/envelope state into
   inferred RAM. Per-voice configuration and runtime registers are directly
   readable through multi-cycle synchronous bus reads instead of through a
   separate status-read indirection. Further savings for one-bit runtime release
   and filter-enable state should be handled only if post-implementation resource
   or timing data justifies the added control complexity.

3. Add throughput and memory-pressure observability before changing policy.
   The current render counters already separate many memory-service costs:
   word-request FIFO depth, fetch-slot pressure, DSP context queue occupancy,
   memory-stall cycles, DSP-ready/no-context cycles, demand hit/miss counts,
   prefetch issue/fill/use/drop/late counts, external line requests, response
   latency, render latency, and deadline misses. Remaining scheduler-only
   counters such as context issue/retire counts, DSP-stage occupancy, and
   invalid-slot scan cycles can be added when a scheduler change needs them.

4. Continue the wavetable-optimized memory subsystem in incremental stages.
   The optimized passes now carry both `voice_id` and `stream_id` locality into
   `voice_line_cache`, use two lines per voice/stream, satisfy same-line
   interpolation endpoints from one fill, and add conservative next-line stride
   prefetch from second-half demand hits. The next pass should use `phase_inc`
   and loop/release context to prefetch the next output frame's actual left/right
   endpoint lines, including loop-wrap cases. Larger DDR burst lines, multiple
   outstanding line fills, and tagged endpoint assembly are later steps once
   counters show that the simpler stream-local cache/prefetch design cannot meet
   the 256-stereo target.

5. Replace the C++ storage model with concrete DDR3 controller models.
   The current board target is a Micron `MT41K256M16TW` DDR3 device behind a
   Xilinx MIG wrapper. Model burst alignment, calibration delay, cache fills,
   prefetch, and request backpressure before relying on hardware timing.

6. Split board clocks and reset sequencing.
   Separate system/control, memory, and audio clocks where the board requires it,
   then add CDC or asynchronous FIFOs at each boundary.

7. Harden SPI timing assumptions.
   Define the supported SPI mode, SCLK-to-system-clock timing limits, CS
   setup/hold, read turnaround timing, and any board wrapper synchronizers.

8. Keep vendor build flows incremental where the tool benefits from it.
   The Smart Artix Vivado synthesis flow now preserves the generated project,
   IP output products, and completed `synth_smart_artix_top` run under `build/` and reuses an
   up-to-date run. Source changes still reset and rerun stale completed synthesis
   runs. Future implementation scripts should use checkpoint-based incremental
   implementation where it provides a larger runtime benefit than synthesis
   project reuse.

9. Extend the audio interface.
   Add codec-facing behavior as needed: MCLK, 24-bit or 32-bit slots, mute,
   startup sequencing, reset/config policy, and BCLK/LRCLK ratio assertions.

10. Harden the SD-to-DDR3 asset-loading path on hardware.
   The Smart Artix RTL now connects native 4-bit SD loading to the DDR3 write
   side before playback starts, and `make render-board-loader` verifies raw SD
   image loading into a DDR byte model followed by exact RTL/reference rendering.
   Remaining board work is schematic-verified pins, SD clock constraints,
   generated MIG integration on real hardware, load-time/error status exposure,
   and host/MCU-owned SF2 metadata and voice policy. Runtime `.sf2` parsing remains
   outside the generic wavetable core.

10. Strengthen board-facing pass/fail checks.
   Compare board-loader render PCM against the `render-rtl-core` reference on
   short exact cases, record control transaction counts and memory stall cycles,
   and run longer high-polyphony stress cases once the board wrapper is concrete.
