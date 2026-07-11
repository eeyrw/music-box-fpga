# Music Box FPGA

An open SystemVerilog wavetable synthesizer core. The project currently targets
a hardware-independent, self-checking simulation path before SPI, parallel NOR
Flash timing, I2S, and board integration are introduced.

The current milestone implements 32 stereo output voice slots with configurable
variable-length wavetable playback, simple loop modes, one-pole per-voice
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
- Per-voice one-pole low-pass filter with runtime coefficients
- Linear interpolation and signed 16-bit saturated output
- Shared multi-voice rendering pipeline and saturated stereo mixer
- Ready/valid abstract memory interface
- One-cycle behavioral wave-memory model
- Self-checking SystemVerilog regression test

The current core intentionally does not implement physical SPI or NOR Flash
timing, SF2 preset/modulator/velocity behavior, filter coefficient calculation,
I2S output, or
vendor-specific FPGA logic.
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

Useful learning documents:

- [`docs/system_design.md`](docs/system_design.md): current RTL architecture and
  data path.
- [`docs/simulation_design.md`](docs/simulation_design.md): self-checking tests
  and SoundFont render flow.
- [`docs/audio_render_calculation.md`](docs/audio_render_calculation.md): detailed
  MIDI-to-audio render calculations across the MCU model and RTL pipeline.
- [`docs/performance_budget.md`](docs/performance_budget.md): cycle, memory
  bandwidth, and pipeline direction notes for scaling toward 32 voices.

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

The flow extracts the selected SF2 instrument sample, converts linked left/right
samples to the core's interleaved stereo memory format, runs the Verilator render
testbench, and writes `build/render/out.wav`.

Render a simple MIDI-driven score through the multi-voice core:

```bash
make render-midi SECONDS=2
make render-midi MIDI=song.mid SECONDS=20
```

With no `MIDI` argument, the C++ render harness uses a built-in short melody. It
parses SF2 and MIDI at runtime, models MCU-side note allocation and Q1.15 ADSR
envelope writes, and drives `wavetable_core` through the register and memory
ports. The RTL handles wavetable playback, loop modes, optional LPF, and mixing.
The output WAV is `build/render_midi/out.wav`.

Representative MIDI smoke-test inputs live under `assets/midi/`. The older
Python-generated SystemVerilog MIDI render flow has been removed.

## Current Register Interface

The simulation bus is a single-beat 32-bit register interface with `valid`,
`write`, `address`, `wdata`, `rdata`, `ready`, and `error` signals. Writes modify
shadow state for one voice slot. Writing that slot's commit register atomically
replaces the active voice configuration. SPI will later be implemented only as a
bridge to this bus.

See [the register map](docs/register_map.md) for addresses and validation rules.

## Roadmap

1. Broaden multi-voice backpressure and memory-latency verification.
2. Add I2S serialization and an I2S receiver test model.
3. Add simplified SPI and parallel NOR Flash controllers.
4. Introduce board-specific clocks, constraints, and synthesis projects.

Contributors and coding agents should read [AGENTS.md](AGENTS.md) before changing
RTL interfaces or numeric behavior.
