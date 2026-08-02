# RTL Module Map

This is the reading map for the current mono voice-major implementation.
Behavioral contracts remain in `../fixed_point.md`, `../memory_format.md`, and
`../register_map.md`.

## Entry Points

| Top | File | Role |
| --- | --- | --- |
| `voice_major_render_core` | `rtl/top/voice_major_render_core.sv` | Generic command-controlled block renderer with ordered line-memory traffic. |
| `voice_major_system` | `fpga/common/rtl/voice_major_system.sv` | SPI/register fabric, render scheduling, global effects, FIFO, and I2S composition. |
| `smart_artix_top` | `fpga/smart_artix/rtl/smart_artix_top.sv` | Board top connecting the common system to SD loading and the MIG DDR3 app interface. |
| `voice_major_render_harness` | `sim/models/voice_major_render_harness.sv` | Verilator top using the same command plane plus the behavioral DDR3 model. |

The former `wavetable_render_core` family is not a production or compatibility
target. Its RTL, common wrappers, simulation harnesses, and board template have
been removed. Use Git history only when investigating that implementation.

## Production Tree

```text
voice_major_render_core
+- voice_major_command_plane
|  +- control_word_fifo
+- block_voice_state_store
+- voice_major_block_controller
   +- block_mono_voice_engine
      +- block_interleaved_envelope_frontend
      +- block_interleaved_voice_renderer
      |  +- mono_phase_frame
      |  +- voice_sample_window
      |  +- block_interleaved_voice_dsp
      +- block_mix_buffer
```

The board/common composition is:

```text
smart_artix_top
+- smart_artix_ddr3_subsystem
|  +- smart_artix_sd_native_asset_loader
|  +- smart_artix_ddr3_asset_writer
|  +- smart_artix_ddr3_reg_access_master
|  +- smart_artix_ddr3_line_reader
|  +- smart_artix_ddr3_rw_arbiter
|     +- MIG app interface
+- smart_artix_platform_regs
+- voice_major_system
   +- spi_register_bridge
   +- wavetable_register_fabric
   +- wavetable_common_status_regs
   +- voice_major_render_core
   +- global_audio_effects_chain
   |  +- global_effects_chain
   |  |  +- stereo_chorus
   |  |  +- fdn_reverb
   |  |  +- effect_return_mixer
   |  +- lookahead_compressor
   +- wavetable_i2s_output
      +- output_sample_fifo
      +- i2s_tx
```

## Ownership

| Directory | Current ownership |
| --- | --- |
| `rtl/pkg` | Shared widths, packed records, commands, render blocks, and generated register constants. |
| `rtl/control` | Unified command FIFO/parser, global audio configuration, generation checks, active voice state, and runtime event application. |
| `rtl/voice` | Block traversal, envelope advancement, mono phase/loop calculation, windowed sample access, DSP issue, and block mixing. |
| `rtl/dsp` | Interpolation, biquad, gain/envelope scaling, and contribution formatting. |
| `rtl/memory` | Per-voice 32-word sample window and ordered 8-word refill interface. |
| `rtl/audio` | Chorus, reverb, return mix, compressor/master processing, scheduling, and output FIFO. |
| `fpga/common/rtl` | Reusable SPI, register routing, status, effects-to-I2S composition, SD protocol, and serializer blocks. |
| `fpga/smart_artix/rtl` | MIG, SD pins, asset loading, DDR register access, line reads, and DDR arbitration. |
| `sim/models` | Behavioral DDR3 timing/store adapters; never synthesis inputs. |

## Control Layer

`voice_major_command_plane` is the only production voice/global command decoder.
It accepts the dedicated command stream into one FIFO as its only ingress. It
parses the compact version-10
header, validates complete commands, and dispatches only while the renderer is
idle.

`block_voice_state_store` owns active mono state and arbitrates renderer
snapshots, START installs, runtime events, and renderer writeback. Generation is
16 bits; voice ID is 10 bits in the command header. There is no prepared state,
stereo descriptor, typed simulation install port, or per-voice debug register
aperture.

## Voice And DSP Layers

`voice_major_block_controller` scans every configured voice ID in ascending
order for one requested block, skips snapshots whose dynamic state is inactive,
and publishes a completed mix buffer. `block_mono_voice_engine` overlaps the
single-context envelope frontend, sample-window traffic, fixed-lane DSP
execution, and accumulation.

`mono_phase_frame` derives the two interpolation endpoints and next phase for
one mono voice. START clears phase to zero. Runtime PITCH changes only
`phase_inc`. LOOP_MODE 0 stops at length, mode 1 wraps continuously, and mode 2
wraps until RELEASE.

`block_interleaved_voice_dsp` duplicates the interpolated mono sample before
independent left/right gain, then applies filter/envelope arithmetic. Its input
is selected by a modulo eight-lane barrel; it does not search ready contexts or
maintain a dynamic filter-hazard scoreboard. Linked SF2 stereo material has
already become two mono voices in the host render flow.

## Memory Layer

`voice_sample_window` stores 32 mono words per voice. A miss issues ordered
aligned 8-word refills. The 8-word object is a DDR transaction width, not the old
one-line cache policy.

On Smart Artix the refill path is:

```text
voice_sample_window
  -> smart_artix_ddr3_line_reader
  -> smart_artix_ddr3_rw_arbiter
  -> MIG app request/response
```

The arbiter also serves asset loading and the DDR register inspection master.
The behavioral `ordered_line_ddr3_bridge_model` exists only in simulation.

## Register And Package Layers

`synth_register_pkg.sv` and `sim/harness/generated/register_map.h` are generated
from `spec/register_map.json`. The common register fabric preserves platform,
DDR, common status, compressor, and effect diagnostic ownership while forwarding
generic command/status addresses to `voice_major_command_plane`.

Run `make generate-register-map` after editing the JSON and
`make check-register-map` before committing.
