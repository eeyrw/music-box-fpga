# Music Box FPGA

An open SystemVerilog wavetable synthesizer core. The project currently targets
a hardware-independent, self-checking simulation path before SPI, parallel NOR
Flash timing, I2S, and board integration are introduced.

The current milestone implements one stereo output voice with configurable
variable-length wavetable playback.

## Implemented

- Synthesizable single-clock SystemVerilog RTL
- Shadow and active voice registers with atomic commit
- Unsigned Q16.16 playback phase and fractional phase increments
- Variable wave length and exclusive loop boundaries
- Mono PCM duplication to left and right channels
- Interleaved stereo PCM playback
- Per-channel signed Q1.15 gain
- Linear interpolation and signed 16-bit saturated output
- Ready/valid abstract memory interface
- One-cycle behavioral wave-memory model
- Self-checking SystemVerilog regression test

The current core intentionally does not implement physical SPI or NOR Flash
timing, multiple voices, a mixer, I2S output, or vendor-specific FPGA logic.
See [the design specification](WaveTable_Synth_FPGA_Design_Spec_V1.md) for the
long-term architecture and roadmap.

## Data Path

```text
Register Bus
    |
Shadow Registers -> Commit -> Active Voice Configuration
                                    |
                              Phase Generator
                                    |
                         Abstract Wave Memory
                                    |
                         Linear Interpolation
                                    |
                           Left/Right Gain
                                    |
                  sample_valid + sample_l/sample_r
```

PCM data is signed 16-bit. Playback phase uses unsigned Q16.16 sample-frame
units, and channel gains use signed Q1.15. Mono waves contain one word per frame;
stereo waves are interleaved left then right. Detailed contracts are documented
in [`docs/`](docs/).

## Repository Layout

```text
rtl/pkg/       Shared types and constants
rtl/bus/       Register-bus protocol declarations
rtl/control/   Shadow and active control registers
rtl/voice/     Playback phase and sample-fetch sequencing
rtl/dsp/       Interpolation and gain processing
rtl/top/       Hardware-independent core integration
sim/models/    Simulation-only behavioral models
sim/tb/        Self-checking SystemVerilog testbenches
docs/          Fixed-point, memory, and register contracts
```

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
PASS: single-voice wavetable core
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

The flow extracts the selected SF2 instrument sample, converts linked left/right
samples to the core's interleaved stereo memory format, runs the Verilator render
testbench, and writes `build/render/out.wav`.

## Current Register Interface

The simulation bus is a single-beat 32-bit register interface with `valid`,
`write`, `address`, `wdata`, `rdata`, `ready`, and `error` signals. Writes modify
shadow state. Writing the commit register atomically replaces the active voice
configuration. SPI will later be implemented only as a bridge to this bus.

See [the register map](docs/register_map.md) for addresses and validation rules.

## Roadmap

1. Broaden single-voice boundary and backpressure verification.
2. Add the voice scheduler and 32-voice mixer.
3. Add I2S serialization and an I2S receiver test model.
4. Add simplified SPI and parallel NOR Flash controllers.
5. Introduce board-specific clocks, constraints, and synthesis projects.

Contributors and coding agents should read [AGENTS.md](AGENTS.md) before changing
RTL interfaces or numeric behavior.
