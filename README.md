# Music Box FPGA

An open SystemVerilog wavetable synthesizer core. The project currently targets
self-checking simulation paths for the core datapath, memory subsystem, SPI
register transport, and I2S output before board-specific timing and synthesis are
introduced.

The current milestone implements 32 stereo output voice slots with configurable
variable-length wavetable playback, simple loop modes, per-voice biquad IIR
filtering, and saturated mixing.

## Implemented

- Synthesizable single-clock SystemVerilog RTL
- Per-voice shadow and active registers with atomic commit
- Unsigned Q16.16 playback phase and fractional phase increments
- Runtime phase-increment updates for pitch control without phase reload
- Variable wave length, exclusive loop boundaries, and no-loop/loop/release-loop modes
- Mono PCM duplication to left and right channels
- Interleaved stereo PCM playback
- Per-channel signed Q1.15 gain
- Per-voice current envelope level supplied through registers
- Per-voice biquad IIR filter with runtime coefficients
- Linear interpolation and signed 16-bit saturated output
- Shared multi-voice rendering pipeline and saturated stereo mixer
- Ready/valid abstract memory interface
- Minimal line-cache memory subsystem and external line-read interface
- SPI register bridge for simulation-friendly control transport
- I2S transmitter for fixed 48 kHz stereo output
- One-cycle behavioral wave-memory model
- Self-checking SystemVerilog regression test

The current core intentionally does not implement board-level SPI electrical
timing, physical NOR Flash timing, complete SF2 preset/modulator/velocity
behavior, filter coefficient calculation, or vendor-specific FPGA logic.
See [the design specification](WaveTable_Synth_FPGA_Design_Spec_V1.md) for the
long-term architecture and roadmap.

## Data Path

```text
Register Bus
    |
Shadow Registers -> Commit -> Active Voice Configurations
                                    |
                         Multi-Voice Phase/Fetch
                                    |
                         Abstract Wave Memory
                                    |
                         Linear Interpolation
                                    |
                         LPF + Gain + Envelope + Mixer
                                    |
                  sample_valid + sample_l/sample_r
                                     |
                                  I2S TX
```

PCM data is signed 16-bit. Playback phase uses unsigned Q16.16 sample-frame
units, and channel gains use signed Q1.15. Mono waves contain one word per frame;
stereo waves use independent absolute left/right base addresses and sample-window
metadata. Detailed contracts are documented in [`docs/`](docs/).

## Repository Layout

```text
rtl/pkg/       Shared types and constants
rtl/bus/       Register-bus protocol declarations
rtl/control/   Shadow and active control registers
rtl/voice/     Playback phase and sample-fetch sequencing
rtl/dsp/       Interpolation and gain processing
rtl/audio/     Audio serializers and output timing blocks
rtl/top/       Core and full-system simulation integration
fpga/          Board-specific synthesis and bring-up templates
sim/models/    Simulation-only behavioral models
sim/tb/        Self-checking SystemVerilog testbenches
docs/          Fixed-point, memory, and register contracts
```

Useful learning documents:

- [`docs/system_design.md`](docs/system_design.md): current RTL architecture and
  board-level backlog.
- [`docs/simulation_design.md`](docs/simulation_design.md): self-checking tests
  SoundFont render flows, and MIDI/SF2 render calculations.
- [`docs/fixed_point.md`](docs/fixed_point.md): fixed-point arithmetic contracts.
- [`docs/memory_format.md`](docs/memory_format.md): wave-memory layout and
  external line-memory interface.
- [`docs/register_map.md`](docs/register_map.md): software-visible register map.
- [`docs/host_control.md`](docs/host_control.md): reusable host-side C++ control
  boundary for future PC/CH347 SPI control.
- [`docs/board_target_smart_artix.md`](docs/board_target_smart_artix.md): current
  XC7A50T Smart Artix board assumptions and board integration direction.
- [`docs/smart_artix_bringup.md`](docs/smart_artix_bringup.md): practical Smart
  Artix hardware bring-up sequence and debug checklist.
- [`fpga/smart_artix/`](fpga/smart_artix/): Smart Artix XC7A50T synthesis and
  bring-up skeleton.

## Requirements

- GNU Make
- Verilator 5 or newer
- A C++ compiler supported by Verilator

On Debian or Ubuntu:

```bash
sudo apt install make verilator g++
```

## Build And Test

Run RTL lint:

```bash
make lint
```

Build and execute the self-checking simulation:

```bash
make test
```

A successful regression ends with:

```text
PASS: multi-voice wavetable core
```

Generated files are written below `build/` and are ignored by Git. Use
`make clean` to remove them.

## Render A SoundFont Instrument

The repository includes `assets/soundfonts/MT6276.sf2` for simulation rendering.
List available instruments:

```bash
make list-instruments
```

Render one instrument through the RTL core at 48 kHz:

```bash
make render-instrument INSTRUMENT=0 KEY=60 SECONDS=1
```

The flow maps the selected SF2 instrument sample to absolute addresses in the
full SF2 file image, runs the Verilator render testbench, and writes
`build/render/out.wav`.

Render a simple MIDI-driven score through one of the C++ harnesses:

```bash
make render-quick SECONDS=1
make render-memory SECONDS=2
make render-full-system SECONDS=0.1
make render-board-loader SECONDS=0.1
make render-memory MIDI=song.mid SECONDS=20
make render-memory SECONDS=1 MEMORY_PROFILE=sdram
```

Build the PC-side CH347 USB-to-SPI register-control tool:

```bash
make host-ch347
```

It reuses the same C++ register-control sequence as the simulation harnesses and
loads the CH347 vendor library at runtime. See
[`docs/host_control.md`](docs/host_control.md) for usage and integration notes.

With no `MIDI` argument, the C++ harnesses use a built-in short melody. `make
render-quick` is the fast algorithm/RTL comparison path: it drives `wavetable_core`
with a direct word-memory model and compares every RTL output sample against a C++
fixed-point reference implementation. It also writes `build/render_quick/out.wav`
for quick listening after the exact comparison passes.

`make render-memory` is the memory-profile render path. It parses SF2 and MIDI at
runtime, models MCU-side note allocation and Q1.15 ADSR envelope writes, and
drives `wavetable_core_memory` through the register interface. Wave reads pass
through the line-cache memory subsystem before the C++ external line-memory model
responds. The output WAV is `build/render_memory/out.wav`, and memory
hit/miss/latency counters are written to `build/render_memory/memory_stats.json`.
`MEMORY_PROFILE` selects a read-only external memory timing model: `ddr`, `sdram`,
or `parallel-nor`.

`make render-full-system` is the pin-level integration path. The C++ harness uses
an SPI master model to program the top-level SPI pins, serves the external line
memory interface as a storage model, decodes the I2S output pins, and writes
`build/render_full_system/out.wav` from that I2S receiver. The current full-system
wrapper uses a `100 MHz` system clock and fractional 48 kHz audio timing.

`make render-board-loader` verifies the board asset-load path before rendering. It
constructs a raw SD image from the selected SF2, drives the native-SD command/data
loader RTL into a DDR byte model, checks that the loaded DDR bytes exactly match
the SF2 image, then renders through `wavetable_core_memory` and compares every RTL
sample against the C++ fixed-point reference. The output WAV is
`build/render_board_loader/out.wav`, and the summary JSON is
`build/render_board_loader/board_loader_render_config.json`.

Representative MIDI smoke-test inputs live under `assets/midi/`. The older
Python-generated SystemVerilog MIDI render flow has been removed.

## Current Register Interface

The simulation bus is a single-beat 32-bit register interface with `valid`,
`write`, `address`, `wdata`, `rdata`, `ready`, and `error` signals. Configuration
writes modify shadow state for one voice slot. Writing that slot's commit
register atomically replaces the active voice configuration. Runtime writes such
as envelope, gain, pitch, and release do not require commit and are sampled at
output-frame render boundaries. `spi_register_bridge` provides a simple SPI
transport for this bus using an 8-bit command, 16-bit byte address, and 32-bit

See [the register map](docs/register_map.md) for addresses and validation rules.

## Roadmap

1. Broaden multi-voice backpressure and memory-latency verification.
2. Replace the C++ DDR/SD storage models with concrete board-memory controller
   and pin-level long-run checks.
3. Add board-level timing constraints for native SD, SPI control, I2S, and DDR3.
4. Move host/MCU voice allocation and preset selection from simulation policy into
   board-control firmware or software.

Contributors and coding agents should read [AGENTS.md](AGENTS.md) before changing
RTL interfaces or numeric behavior.
