# Music Box FPGA

An open SystemVerilog wavetable synthesizer core. The project currently targets
self-checking simulation paths for the core datapath, memory subsystem, and
board-facing SPI/I2S adapter layer before board-specific timing and synthesis are
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
- Transport-independent register bus for host, MCU, soft-core, or simulation control
- Common board/peripheral adapters for SPI register transport and I2S output
- One-cycle behavioral wave-memory model
- Self-checking SystemVerilog regression test

The current core intentionally does not implement board-level SPI electrical
timing, physical NOR Flash timing, DDR controller timing, I2S codec integration,
complete SF2 preset/modulator/velocity behavior, filter coefficient calculation,
or vendor-specific FPGA logic.
See [`docs/README.md`](docs/README.md) for the current documentation map and
[`docs/design/system_design.md`](docs/design/system_design.md) for the architecture
and roadmap notes.

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
```

Board wrappers connect the register bus to a physical control transport such as
SPI, UART, or a soft-core bus, generate `sample_tick`, attach memory controllers,
and serialize PCM to board audio pins when needed.

PCM data is signed 16-bit. Playback phase uses unsigned Q16.16 sample-frame
units, and channel gains use signed Q1.15. Mono waves contain one word per frame;
stereo waves use independent absolute left/right base addresses and sample-window
metadata. Detailed contracts are documented in [`docs/`](docs/).

## Repository Layout

```text
rtl/                    Generic synthesizable SystemVerilog core
  pkg/                  Shared types and constants
  control/              Shadow, active, and runtime voice register storage
  memory/               Abstract line-cache memory subsystem
  voice/                Multi-voice phase, fetch, and render sequencing
  dsp/                  Interpolation, filters, gain, envelope, and mixing
  audio/                Output FIFO for rendered PCM frames
  top/                  Register-bus and line-memory core wrappers

sim/                    Simulation-only code
  models/               Behavioral models that are not synthesis sources
  tb/                   Self-checking SystemVerilog testbenches
  harness/              C++ render harness code
    apps/               C++ render executable entry points
    formats/            SF2, MIDI, and byte-stream parsers
    render/             Shared render types, MCU policy, and reference synth
    control/            Register-control sequencing shared by sim and host tools
    dut/                C++ DUT adapters around Verilated top modules
    common/             WAV writer, memory profiles, and small shared helpers
    board_loader/       Smart Artix SD-to-DDR loader render harness support
    generated/          Generated C++ register-map constants

fpga/                   Board-specific FPGA integration workspace
  common/               Reusable board/peripheral adapters
    rtl/                SPI bridge, debug regs, tick gen, I2S TX, pin wrapper
  board_template/       Starting point for future board ports
  smart_artix/          XC7A50T Smart Artix board path
    rtl/                Board adapters for SD, DDR3, debug, and top level
    constraints/        Board XDC constraints
    vivado/             Versioned Vivado IP configs and batch scripts
    docs/               Local pin assignment and schematic reference files
    sim/                Smart Artix board-level simulation models/tests
    assets/             Board asset notes; generated images stay in build/

docs/                   Stable contracts and design/verification notes
spec/                   Machine-readable register map source
assets/                 Small checked-in SF2/MIDI inputs for simulation
host/                   PC-side CH347/SPI control utility code
tools/                  Python utilities for SF2/WTSF/WAV/Vivado summaries
third_party/            External vendor support files kept separate
build/                  Generated outputs only; ignored by Git
```

The synthesizer core lives under `rtl/` and exposes abstract register, memory,
and PCM/tick interfaces. Reusable physical-interface adapters live under
`fpga/common/rtl`, while concrete board tops live under `fpga/<board>/rtl`.
Board wrappers under `fpga/` may instantiate vendor IP and physical interfaces,
but simulation models stay under `sim/` or the board-specific
`fpga/<board>/sim/` directory and must not be added to synthesis file lists.
Generated Vivado projects, reports, bitstreams, render output, and SD images are
written below `build/`.

Useful learning documents start at [`docs/README.md`](docs/README.md). Key entry
points:

- [`docs/design/system_design.md`](docs/design/system_design.md): current RTL architecture and
  board-level backlog.
- [`docs/verification/simulation_design.md`](docs/verification/simulation_design.md): self-checking tests,
  SoundFont render flows, C++ harness source layout, and MIDI/SF2 render
  calculations.
- [`docs/fixed_point.md`](docs/fixed_point.md): fixed-point arithmetic contracts.
- [`docs/memory_format.md`](docs/memory_format.md): wave-memory layout and
  external line-memory interface.
- [`docs/register_map.md`](docs/register_map.md): software-visible register map.
- [`docs/host/host_control.md`](docs/host/host_control.md): reusable host-side C++ control
  boundary for future PC/CH347 SPI control.
- [`fpga/smart_artix/README.md`](fpga/smart_artix/README.md): current XC7A50T
  Smart Artix board assumptions, Vivado status, and board integration direction.
- [`docs/board/smart_artix_bringup.md`](docs/board/smart_artix_bringup.md): practical Smart
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

Check that generated register-map headers match `spec/register_map.json`:

```bash
make check-register-map
```

Build and execute the self-checking simulation:

```bash
make test
```

`make test` is split into `test-cpp-unit`, `test-rtl-core`, and
`test-rtl-peripheral`, so focused parser/control checks can run separately from
the RTL regressions when needed. A successful core regression includes:

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
make render-reference SECONDS=1
make render-rtl-core SECONDS=1
make render-memory SECONDS=2
make render-board-loader SECONDS=0.1
make render-memory MIDI=song.mid SECONDS=20
make render-memory MIDI=song.mid START_SECONDS=144 SECONDS=30
make render-memory SECONDS=1 MEMORY_PROFILE=sdram
```

Build the PC-side CH347 USB-to-SPI register-control tool:

```bash
make host-ch347
```

It reuses the same C++ register-control sequence as the simulation harnesses and
loads the CH347 vendor library at runtime. See
[`docs/host/host_control.md`](docs/host/host_control.md) for usage and integration notes.

With no `MIDI` argument, the C++ harnesses use a built-in short melody. `make
render-reference` is the pure C++ algorithm path: it parses SF2/MIDI, runs the
shared MCU policy model, renders with `ReferenceSynth`, and writes
`build/render_reference/out.wav` plus
`build/render_reference/reference_render_config.json`.

For MIDI renders, `START_SECONDS` selects a window inside the MIDI file. The
harness advances pre-window non-note MIDI events such as controller, pitch-bend,
channel-pressure, and key-pressure events to output time zero, then shifts events
inside `[START_SECONDS, START_SECONDS + SECONDS)` down to the start of the WAV.
It does not reconstruct notes that started before the window and are still
sounding at `START_SECONDS`; use a full pre-roll render when exact sustained-note
state at the cut point matters.

`make render-rtl-core` is the fast algorithm/RTL comparison path: it drives
`wavetable_render_core` with an ideal one-cycle word responder on the RTL memory
port and compares every RTL output sample against a C++ fixed-point reference
implementation. It does not use `MEMORY_PROFILE` or any external-memory timing
model. It also writes `build/render_rtl_core/out.wav` for quick listening after
the exact comparison passes.

`make render-memory` is the memory-profile render path. It parses SF2 and MIDI at
runtime, models MCU-side note allocation and Q1.15 ADSR envelope writes, and
drives `wavetable_cached_render_core` through the register interface. Wave reads pass
through the line-cache memory subsystem before the C++ external line-memory model
responds. The output WAV is `build/render_memory/out.wav`, and memory
hit/miss/latency counters are written to `build/render_memory/memory_stats.json`.
`MEMORY_PROFILE` selects a read-only external memory timing model for this target:
`ddr`, `sdram`, or `parallel-nor`.

`make render-board-loader` verifies the board asset-load path before rendering. It
constructs a raw SD image from the selected SF2, drives the native-SD command/data
loader RTL into a DDR byte model, checks that the loaded DDR bytes exactly match
the SF2 image, then renders through `wavetable_cached_render_core` and compares every RTL
sample against the C++ fixed-point reference. The output WAV is
`build/render_board_loader/out.wav`, and the summary JSON is
`build/render_board_loader/board_loader_render_config.json`.

The C++ render harnesses handle `Ctrl+C` as a graceful interrupt. If a long run
is stopped, the harness exits at the next sample boundary, rewrites the WAV
header for the samples already produced, records `interrupted: true` in the
summary when that target writes one, and exits with status 130 instead of
reporting PASS.

For board bring-up, generate and verify the raw SD image expected by the Smart
Artix loader:

```bash
make wtsf-image SF2=assets/soundfonts/MT6276.sf2
make verify-wtsf-image
```

To write it to an SDHC/SDXC card, pass the whole-card block device explicitly:

```bash
make flash-wtsf-sd SD_DEVICE=/dev/sdX
```

See `docs/board/smart_artix_bringup.md` for the full hardware checklist and loader
status registers.

Representative MIDI smoke-test inputs live under `assets/midi/`. The older
Python-generated SystemVerilog MIDI render flow has been removed.

## Current Register Interface

The core bus is a single-beat 32-bit register interface with `valid`, `write`,
`address`, `wdata`, `rdata`, `ready`, and `error` signals. Configuration writes
modify shadow state for one voice slot. Writing that slot's commit register
atomically replaces the active voice configuration. Runtime writes such as
envelope, gain, pitch, and release do not require commit and are sampled at
output-frame render boundaries. `fpga/common/rtl/spi_register_bridge.sv`
provides one simple SPI transport for this bus using an 8-bit command, 16-bit
byte address, and 32-bit data phase; future UART or bus adapters should target
the same abstract register-bus contract.

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
