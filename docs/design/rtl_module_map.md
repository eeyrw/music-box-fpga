# RTL Module Map

This note is a reading map for `rtl/`. It answers two questions:

- Which module is the top of each RTL area?
- Which modules instantiate or depend on which other modules?

It is descriptive only. Stable behavior contracts still live in
`../fixed_point.md`, `../memory_format.md`, and `../register_map.md`.

## Main Entry Points

Use one of these modules as the integration top, depending on how much of the
generic core you want to include:

| Top module | File | Use when |
| --- | --- | --- |
| `wavetable_render_core` | `rtl/top/wavetable_render_core.sv` | You want the smallest generic audio render core. It exposes the register bus, `sample_tick`, mixed PCM output, and a one-word wave-memory read interface. |
| `wavetable_cached_render_core` | `rtl/top/wavetable_cached_render_core.sv` | You want the generic render core plus the current one-line wave-memory cache. It exposes the register bus, `sample_tick`, mixed PCM output, and an external line-read interface. |
| `wavetable_system_core` | `fpga/common/rtl/wavetable_system_core.sv` | You want the render core and line-memory adapter as a reusable board-facing system block with an abstract register bus and PCM frame output, but without SPI or I2S. |
| `wavetable_i2s_output` | `fpga/common/rtl/wavetable_i2s_output.sv` | You want to adapt a PCM frame stream to the current FIFO-backed I2S transmitter. |
| `wavetable_demo_system` | `fpga/common/rtl/wavetable_demo_system.sv` | You want the current pin-level demo composition that wires SPI control, common status registers, the reusable system core, and I2S output together. |

For most generic RTL work, start at `wavetable_render_core`. For memory-adapter
work, start at `wavetable_cached_render_core` or `voice_line_cache`. For
pin-level SPI/I2S integration, start in `fpga/common/rtl/` instead of `rtl/`.

## Directory Ownership

| Directory | Directory top | Contents | Instantiated by |
| --- | --- | --- | --- |
| `rtl/pkg` | none | Shared packages, constants, packed structs, and generated register constants. Packages are imported, not instantiated. | Imported throughout `rtl/`, `fpga/common/rtl`, and simulation code. |
| `rtl/top` | `wavetable_render_core`, `wavetable_cached_render_core` | Generic core composition modules. | Testbenches, C++ Verilator harnesses, and common board wrappers. |
| `rtl/control` | `synth_control_plane` | Global command/status decode, transactional parsing, bounded action batching, and packed prepared/active voice state. | `wavetable_render_core`. |
| `rtl/voice` | `multi_voice_pipeline` | Per-output-frame voice scheduler, phase/loop calculation, endpoint request sequencing, phase/filter-state writeback, and stereo accumulation. | `wavetable_render_core`. |
| `rtl/dsp` | `voice_dsp_pipeline` | Fixed-latency per-voice sample interpolation, optional filter arithmetic, gain, envelope, saturation, and result formatting. | `multi_voice_pipeline`. |
| `rtl/memory` | `voice_line_cache`, `wave_memory_subsystem` | Adapters from the core's one-word PCM read interface to an external line-read interface. `voice_line_cache` is the current cached render path; `wave_memory_subsystem` is the older single-line baseline used by some common/board wrappers. | `wavetable_cached_render_core`, `wavetable_system_core`, focused memory tests, and render testbenches. |
| `rtl/audio` | `output_sample_fifo`, `render_credit_scheduler` | PCM buffering plus target-level render-credit generation for continuous output. | Common I2S/demo wrappers; not used by the bare `rtl/top` cores. |

There is currently no `rtl/bus` source file. The generic register and memory
ports are explicit ready/valid signals on module interfaces rather than a shared
SystemVerilog interface.

## Generic Core Tree

The generic render core is composed like this:

```text
wavetable_render_core
+- synth_control_plane
|  +- transactional_control_plane
|     +- control_word_fifo
|     +- control_action_parser
|     +- control_action_fifo
|     +- control_action_executor
|        +- voice_bram_1r1w (prepared)
|        +- voice_bram_1r1w (active/runtime/envelope)
+- multi_voice_pipeline
   +- voice_phase_frame
   +- voice_endpoint_fetch
   +- voice_dsp_pipeline
      +- linear_interpolator
      +- linear_interpolator
```

`wavetable_cached_render_core` wraps that tree and adds the cached memory adapter:

```text
wavetable_cached_render_core
+- wavetable_render_core
+- voice_line_cache
```

The reusable system core uses the same render and memory blocks directly while
keeping SPI and I2S out of the synthesis engine boundary:

```text
wavetable_system_core
+- wavetable_render_core
+- wave_memory_subsystem
```

The I2S adapter is a separate audio-output consumer:

```text
wavetable_i2s_output
+- output_sample_fifo
+- i2s_tx
```

The demo board/common wrapper adds transport, status registers, tick generation, and I2S
around those reusable blocks. It also exposes a platform-register extension hook
that board wrappers can use for platform-specific status windows:

```text
wavetable_demo_system
+- wavetable_common_status_regs
+- spi_register_bridge
+- fractional_tick_gen
+- render_credit_scheduler
+- wavetable_system_core
+- wavetable_i2s_output
```

`spi_register_bridge`, `wavetable_common_status_regs`, `fractional_tick_gen`,
`i2s_tx`, `wavetable_system_core`, `wavetable_i2s_output`, and
`wavetable_demo_system` live under `fpga/common/rtl/`, not under generic `rtl/`.

The current Smart Artix board top keeps SD loading, DDR3 arbitration, line reads,
and DDR register access traffic behind a board-specific subsystem:

```text
smart_artix_top
+- smart_artix_ddr3_subsystem
|  +- sd_native_pin_phy
|  +- smart_artix_sd_native_asset_loader
|  |  +- sd_native_block_reader
|  |  +- smart_artix_asset_loader
|  |  +- smart_artix_ddr3_asset_writer
|  +- smart_artix_ddr3_rw_arbiter
|  +- smart_artix_ddr3_reg_access_master
|  +- smart_artix_ddr3_line_reader
+- smart_artix_platform_regs
+- wavetable_demo_system
```

## Package Layer

`rtl/pkg/synth_pkg.sv` owns the hardware-wide data contracts:

- PCM, phase, address, filter-state, and voice-count widths.
- Loop-mode constants.
- `voice_config_t`, the static renderer configuration inside prepared/active state.
- `prepared_voice_t` and `active_voice_t`, the packed command-owned state.
- `voice_runtime_t`, runtime controls sampled by the renderer.
- `voice_dsp_context_t` and `voice_dsp_result_t`, the typed boundary between
  endpoint fetching, DSP, and result retirement.

`rtl/pkg/synth_register_pkg.sv` is generated from `spec/register_map.json` and
owns global register address constants, bit masks, and numeric constants. Do
not edit it by hand; run `make generate-register-map`
after changing the JSON spec.

Board-facing packages stay with their board integration code instead of the
generic package layer. For example, `fpga/smart_artix/rtl/smart_artix_pkg.sv`
owns the Smart Artix DDR3 app-channel structs, line-read request/response
structs, platform status, and DDR register access request/status structs used between
`smart_artix_top`, `smart_artix_ddr3_subsystem`, and the board register inspection adapter.

## Control Layer

`synth_control_plane` is the top of `rtl/control`. It is the only generic RTL
module that talks directly to the external register bus. It owns:

- Global command/status address decoding and `VERSION` reads.
- Accepting register-fed or dedicated-stream command words.
- Bounded action execution at renderer frame boundaries.
- Renderer-facing synchronous snapshots of packed active/runtime state.
- Coherent read-only board-debug capture using the existing voice RAM read port.

Internal control modules are split by ownership:

| Module | Role |
| --- | --- |
| `control_word_fifo` | Generic synchronous FIFO used by the 32-bit command ingress. |
| `control_action_parser` | Decodes complete transactional command headers and payloads into packed actions. |
| `control_action_fifo` | Buffers decoded actions until the next renderer frame boundary. |
| `control_action_executor` | Applies all lifecycle/runtime actions, advances the six-stage volume envelope, and owns packed prepared/active voice RAM with seq validation. |
| `transactional_control_plane` | Connects word parsing, action batching, lifecycle execution, and renderer frame release. |
| `voice_bram_1r1w` | Small inferred synchronous RAM helper with one read and one write port. |

`voice_bram_1r1w` is a local storage primitive, not a protocol top.

## Voice Layer

`multi_voice_pipeline` is the top of `rtl/voice`. It owns one complete output
frame at a time:

- Accepts `sample_tick` when idle.
- Scans active voice slots in index order.
- Reads active configuration and runtime state through `synth_control_plane`.
- Maintains renderer-owned phase and filter history.
- Uses `voice_phase_frame` to calculate frames, fraction, wrapping, done, and
  next phase.
- Uses `voice_endpoint_fetch` to convert each voice context into ordered wave
  memory word reads and a complete `voice_dsp_context_t`.
- Sends complete contexts into `voice_dsp_pipeline`.
- Retires DSP results into a stereo accumulator, writes filter state, and emits
  saturated PCM on `sample_valid`.

Internal voice modules are:

| Module | Role |
| --- | --- |
| `voice_phase_frame` | Combinational phase, loop, endpoint-frame, and done calculation for one voice snapshot. |
| `voice_endpoint_fetch` | Multi-request fetch engine for L0/L1/R0/R1 interpolation endpoints. It owns request queues, response metadata, fetch slots, and DSP-context assembly. |

## DSP Layer

`voice_dsp_pipeline` is the top of `rtl/dsp`. It is a fixed-latency valid
pipeline that receives complete endpoint contexts and produces one voice's
contribution plus next filter state.

Internal DSP primitives are:

| Module | Role |
| --- | --- |
| `linear_interpolator` | Interpolates between two signed PCM16 endpoints using the phase fraction. The result remains PCM16 for valid endpoints. |

`multi_voice_pipeline` does not duplicate the per-voice DSP arithmetic. It
delegates interpolation, filter arithmetic, combined output gain/envelope scaling,
and PCM saturation to `voice_dsp_pipeline`.

## Memory Layer

`voice_line_cache` is the current cached render adapter in `rtl/memory`. It adapts:

```text
core one-word PCM read request
  -> per-voice/per-stream two-line cache lookup
  -> external aligned line read on miss
  -> one-word PCM response
```

It keeps ordered one-word responses and one outstanding external line request,
with demand misses taking priority over conservative next-line prefetch. A
prefetch can be queued after a demand hit reaches the second half of a cache
line for the same voice/stream; phase-aware loop/channel prediction is deferred.
`stream_id` separates mono/left endpoint reads from right stereo endpoint reads
so linked stereo regions do not evict each other's cache lines while sharing one
voice id. `wave_memory_subsystem` remains as the older single-line baseline
adapter used by some common/board wrapper paths. The renderer still issues
absolute word addresses with a voice id and stream id, and responses return in
accepted-request order. Future cache policy work should keep DSP arithmetic out
of this adapter; phase-aware prefetch may need metadata from
`voice_endpoint_fetch`.

## Audio Layer

`output_sample_fifo` is a synchronous stereo PCM FIFO with push/pop controls and
level/empty/full status. `render_credit_scheduler` requests new frames until the
FIFO plus any inflight frame reaches its target level. The bare generic render
tops instantiate neither module; the common demo/I2S wrappers use them to
decouple rendering from sample consumption.

## Source Order

The generic RTL source list in `Makefile` is ordered from shared packages through
leaf/storage modules, then composition modules:

```text
rtl/pkg
rtl/control
rtl/memory
rtl/dsp
rtl/audio
rtl/voice
rtl/top
```

This order is useful for Verilator and synthesis scripts, but it is not the best
reading order. For understanding behavior, start at `rtl/top`, then follow the
instantiation tree down into `rtl/control`, `rtl/voice`, `rtl/dsp`, and
`rtl/memory`.
