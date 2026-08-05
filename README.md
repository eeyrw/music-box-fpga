# Music Box FPGA

A synthesizable SystemVerilog wavetable synthesizer with a 512-voice mono
voice-major renderer, transactional control, timed DDR3 simulation, global audio
effects, and a source-controlled Smart Artix XC7A50T implementation flow.
Linked SoundFont stereo regions are represented by two mono hardware voices.

## Current System

```text
MIDI/SF2 host policy
  -> 32-bit transactional command stream
  -> active mono voice state and sample-rate envelopes
  -> voice-major 1..16-frame block renderer
  -> per-voice 32-word sample windows
  -> ordered 8-word DDR reads
  -> signed-25 mix
  -> chorus -> reverb -> compressor -> master gain
  -> PCM FIFO -> I2S
```

The generic core contains no vendor primitives. `fpga/common/rtl` adapts the
core to transports and audio serialization; `fpga/smart_artix` owns the clock,
MIG DDR3, SD loader, pins, and constraints. The current routed Smart Artix
baseline closes the internal 100 MHz domain, while external SPI/I2S timing and
physical board qualification remain open.

## Documentation

- [Documentation map](docs/README.md)
- [Project contracts and command quick reference](docs/project_contracts.md)
- [Current system architecture](docs/design/system_design.md)
- [Tooling architecture](docs/development/tooling.md)
- [RP2040 USB MIDI and I2S capture firmware](docs/mcu/rp2040_firmware.md)
- [Required RTL change workflow](docs/development/rtl_change_workflow.md)
- [Verification and render flows](docs/verification/simulation_design.md)
- [SF2 phase and address-span analysis](docs/verification/sf2_access_span_analysis.md)
- [Smart Artix target](fpga/smart_artix/README.md)

Read [AGENTS.md](AGENTS.md) before changing RTL, interfaces, or numeric
behavior.

## Quick Start

Requirements for the normal simulation flow are GNU Make, Verilator 5 or newer,
and a C++17 compiler.

```bash
make check-generated
make check-docs
make lint
make test
```

Common focused operations:

```bash
make render-reference SECONDS=1
make render-rtl-ddr3 SECONDS=1
make wtsf-image SF2=assets/soundfonts/MT6276.sf2
make verify-wtsf-image
python3 tools/ch347_tool.py snapshot --group all
```

Generated executables, WAV files, reports, Vivado projects, bitstreams, and SD
images belong under `build/` and are ignored by Git. Full render examples are in
[render_commands.md](docs/verification/render_commands.md); all supported tool
entry points are described in [tooling.md](docs/development/tooling.md).

## Repository Layout

```text
rtl/                 generic synthesizable core; rtl/filelist.f is authoritative
sim/models/          behavioral models, never synthesis sources
sim/tb/              self-checking SystemVerilog tests
sim/harness/         C++ parsers, control policy, reference synth, DUT adapters
fpga/common/rtl/     reusable board-facing transport/audio wrappers
fpga/smart_artix/    board RTL, XDC, Vivado Tcl/IP inputs, and board tests
host/                CH347 transport and board bring-up applications
mcu/                 RP2040 USB MIDI, MSF2 control, SPI, and I2S capture firmware
spec/                machine-readable register-map source
tools/               generators, asset builders, analyzers, report tools
docs/                contracts, current design, workflow, verification, history
assets/              small checked-in SoundFont/MIDI inputs
third_party/         isolated vendor support files
build/               generated output only
```

Dependencies flow from tops and voice control toward control, DSP, bus, and
package code. Simulation and host policy may depend on the documented hardware
contracts; production RTL must not depend on simulation, host, or tooling code.

## Board Flow

Vivado 2025.2 is used for the current Smart Artix target:

```bash
make vivado-project
make vivado-synth
VIVADO_FORCE_REBUILD=1 make vivado-impl
make vivado-summary
make vivado-analyze
```

Post-synthesis timing is not signoff. The conditions requiring a fresh routed
implementation and the evidence that must be recorded are defined in the
[RTL change workflow](docs/development/rtl_change_workflow.md).
