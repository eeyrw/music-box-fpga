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
| `wavetable_line_memory_core` | `rtl/top/wavetable_line_memory_core.sv` | You want the generic render core plus the current one-line wave-memory cache. It exposes the register bus, `sample_tick`, mixed PCM output, and an external line-read interface. |
| `wavetable_system_core` | `fpga/common/rtl/wavetable_system_core.sv` | You want the line-memory render core as a reusable system block with an abstract register bus and PCM frame output, but without SPI or I2S. |
| `wavetable_i2s_output` | `fpga/common/rtl/wavetable_i2s_output.sv` | You want to adapt a PCM frame stream to the current FIFO-backed I2S transmitter. |
| `wavetable_demo_system` | `fpga/common/rtl/wavetable_demo_system.sv` | You want the current pin-level demo composition that wires SPI control, debug registers, the reusable system core, and I2S output together. |

For most generic RTL work, start at `wavetable_render_core`. For memory-adapter
work, start at `wavetable_line_memory_core` or `wave_memory_subsystem`. For
pin-level SPI/I2S integration, start in `fpga/common/rtl/` instead of `rtl/`.

## Directory Ownership

| Directory | Directory top | Contents | Instantiated by |
| --- | --- | --- | --- |
| `rtl/pkg` | none | Shared packages, constants, packed structs, and generated register constants. Packages are imported, not instantiated. | Imported throughout `rtl/`, `fpga/common/rtl`, and simulation code. |
| `rtl/top` | `wavetable_render_core`, `wavetable_line_memory_core` | Generic core composition modules. | Testbenches, C++ Verilator harnesses, and `fpga/common/rtl/wavetable_system_core.sv`. |
| `rtl/control` | `voice_register_bank` | Register decode, shadow descriptor storage, commit sequencing, active renderer snapshots, and runtime control storage. | `wavetable_render_core`. |
| `rtl/voice` | `multi_voice_pipeline` | Per-output-frame voice scheduler, phase/loop calculation, endpoint request sequencing, phase/filter-state writeback, and stereo accumulation. | `wavetable_render_core`. |
| `rtl/dsp` | `voice_dsp_pipeline` | Fixed-latency per-voice sample interpolation, optional filter arithmetic, gain, envelope, saturation, and result formatting. | `multi_voice_pipeline`. |
| `rtl/memory` | `wave_memory_subsystem` | Adapter from the core's one-word PCM read interface to an external line-read interface with a one-line cache. | `wavetable_line_memory_core`, focused memory tests, and some render testbenches. |
| `rtl/audio` | `output_sample_fifo` | Generic synchronous PCM frame FIFO for wrappers that decouple render output from audio serialization. | `fpga/common/rtl/wavetable_i2s_output.sv`; not used by the bare `rtl/top` cores. |

There is currently no `rtl/bus` source file. The generic register and memory
ports are explicit ready/valid signals on module interfaces rather than a shared
SystemVerilog interface.

## Generic Core Tree

The generic render core is composed like this:

```text
wavetable_render_core
+- voice_register_bank
|  +- voice_active_store
|  |  +- voice_bram_1r1w
|  +- voice_runtime_store
|  |  +- voice_bram_1w2r
|  |  +- voice_bram_1w2r
|  |  +- voice_bram_1w2r
|  |  +- voice_bram_1r1w
|  +- voice_commit_engine
|  +- voice_descriptor_store
|     +- voice_bram_1r1w
+- multi_voice_pipeline
   +- voice_phase_frame
   +- voice_endpoint_fetch
   +- voice_dsp_pipeline
      +- linear_interpolator
      +- linear_interpolator
      +- gain_saturate
      +- gain_saturate
      +- gain_saturate
      +- gain_saturate
```

`wavetable_line_memory_core` wraps that tree and adds the memory adapter:

```text
wavetable_line_memory_core
+- wavetable_render_core
+- wave_memory_subsystem
```

The reusable system core keeps SPI and I2S out of the synthesis engine boundary:

```text
wavetable_system_core
+- wavetable_line_memory_core
   +- wavetable_render_core
   +- wave_memory_subsystem
```

The I2S adapter is a separate audio-output consumer:

```text
wavetable_i2s_output
+- output_sample_fifo
+- i2s_tx
```

The demo board/common wrapper adds transport, debug, tick generation, and I2S
around those reusable blocks. It also exposes a debug-register extension hook
that board wrappers can use for platform-specific status windows:

```text
wavetable_demo_system
+- wavetable_system_debug_regs
+- spi_register_bridge
+- fractional_tick_gen
+- wavetable_system_core
+- wavetable_i2s_output
```

`spi_register_bridge`, `wavetable_system_debug_regs`, `fractional_tick_gen`,
`i2s_tx`, `wavetable_system_core`, `wavetable_i2s_output`, and
`wavetable_demo_system` live under `fpga/common/rtl/`, not under generic `rtl/`.

The current Smart Artix board top keeps SD loading, DDR3 arbitration, line reads,
and DDR debug traffic behind a board-specific subsystem:

```text
smart_artix_top
+- smart_artix_ddr3_subsystem
|  +- smart_artix_sd_native_pin_asset_loader
|  +- smart_artix_ddr3_rw_arbiter
|  +- smart_artix_ddr3_debug_master
|  +- smart_artix_ddr3_line_reader
+- smart_artix_platform_debug_regs
+- wavetable_demo_system
```

## Package Layer

`rtl/pkg/synth_pkg.sv` owns the hardware-wide data contracts:

- PCM, phase, address, filter-state, and voice-count widths.
- Loop-mode constants.
- `voice_config_t`, the committed static renderer configuration.
- `voice_shadow_t`, the software-visible shadow descriptor.
- `voice_runtime_t`, runtime controls sampled by the renderer.
- `voice_dsp_context_t` and `voice_dsp_result_t`, the typed boundary between
  endpoint fetching, DSP, and result retirement.

`rtl/pkg/synth_register_pkg.sv` is generated from `spec/register_map.json` and
owns the register address constants, bit masks, default software constants, and
`reg_voice_addr()`. Do not edit it by hand; run `make generate-register-map`
after changing the JSON spec.

Board-facing packages stay with their board integration code instead of the
generic package layer. For example, `fpga/smart_artix/rtl/smart_artix_pkg.sv`
owns the Smart Artix DDR3 app-channel structs, line-read request/response
structs, platform status, and DDR debug request/status structs used between
`smart_artix_top`, `smart_artix_ddr3_subsystem`, and the board debug adapter.

## Control Layer

`voice_register_bank` is the top of `rtl/control`. It is the only generic RTL
module that talks directly to the external register bus. It owns:

- Voice address decoding and global `VERSION` reads.
- Routing writes to shadow descriptor state or runtime state.
- Starting voice commits and filter commits.
- Multi-cycle synchronous readback from the per-voice stores.
- Renderer-facing read ports for active configuration and runtime controls.

Internal control modules are split by ownership:

| Module | Role |
| --- | --- |
| `voice_descriptor_store` | Stores software-written shadow voice descriptors and normalizes register fields into `voice_shadow_t`. |
| `voice_commit_engine` | Reads a complete shadow descriptor and emits the sequenced writes needed for atomic active/runtime commit. |
| `voice_active_store` | Stores committed static renderer configuration and per-voice valid bits. The renderer reads this through a synchronous RAM-style port. |
| `voice_runtime_store` | Stores runtime phase increment, gains, envelope level, release state, filter enable, and coefficients. Runtime writes do not reload phase. |
| `voice_bram_1r1w` | Small inferred synchronous RAM helper with one read and one write port. |
| `voice_bram_1w2r` | Small inferred synchronous RAM helper with one write and two read ports. |

`voice_bram_1r1w` and `voice_bram_1w2r` are local storage primitives for the
control layer. They are not protocol tops.

## Voice Layer

`multi_voice_pipeline` is the top of `rtl/voice`. It owns one complete output
frame at a time:

- Accepts `sample_tick` when idle.
- Scans committed voice slots in index order.
- Reads active configuration and runtime state through `voice_register_bank`.
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
| `linear_interpolator` | Interpolates between two signed PCM16 endpoints using the phase fraction and saturates back to PCM16. |
| `gain_saturate` | Applies signed Q1.15 gain to a signed PCM16 sample and saturates back to PCM16. |

`multi_voice_pipeline` does not duplicate the per-voice DSP arithmetic. It
delegates interpolation, filter arithmetic, gain, envelope, and PCM saturation to
`voice_dsp_pipeline`.

## Memory Layer

`wave_memory_subsystem` is the top and only module in `rtl/memory`. It adapts:

```text
core one-word PCM read request
  -> one-line cache lookup
  -> external aligned line read on miss
  -> one-word PCM response
```

It is intentionally policy-light. The renderer still issues absolute word
addresses, and responses return in accepted-request order. Future cache policy
work should keep phase and DSP arithmetic out of this adapter.

## Audio Layer

`output_sample_fifo` is the only module in `rtl/audio`. It is a synchronous
stereo PCM FIFO with push/pop controls and level/empty/full status. The bare
generic render tops do not instantiate it; the current SPI/I2S system wrapper
uses it to decouple `sample_valid` from I2S sample consumption.

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
