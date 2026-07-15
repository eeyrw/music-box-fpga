---
name: fpga-verification
description: Use when verifying or exploring this wavetable FPGA project with make lint, make test, render-quick, render-memory, render-full-system, or Vivado synthesis/resource reports.
---

# FPGA Verification Workflow

Use this skill when changing or evaluating the wavetable FPGA RTL, simulation
harnesses, render behavior, memory path, I2S output, or Smart Artix synthesis
flow.

## Ground Rules

- Read `AGENTS.md` before changing RTL interfaces or numeric behavior.
- For behavior changes, run at least `make lint` and `make test`.
- For audio/render changes, run a C++ reference comparison with `make render-quick`.
- For memory-subsystem changes, run `make render-memory` with the relevant
  `MEMORY_PROFILE`.
- For pin-level or I2S integration changes, run `make render-full-system`.
- For area/timing claims, use Vivado reports under `build/fpga/smart_artix/vivado/reports/`.
- Generated outputs belong under `build/` and should not be committed.

## Fast RTL Sanity

Run synthesizable RTL lint:

```bash
make lint
```

What it does:

- Verilator lint over synthesizable `RTL_SOURCES` only.
- Checks the main wrappers: `wavetable_core`, `wavetable_core_spi`,
  `wavetable_core_memory`, `wavetable_core_system`, `wave_memory_subsystem`, and
  `i2s_tx`.

Known non-fatal warnings currently include unused low interpolation product bits,
unused package parameters in narrow top modules, and testbench-only warnings when
building tests. Treat new warnings in touched RTL as suspicious.

Run the focused regression suite:

```bash
make test
```

What it does:

- Builds C++ unit tests for MIDI parsing, register control, SF2 loading, and
  render support.
- Runs `tb_wavetable_core` against tiny exact synthetic wave data.
- Runs focused SPI register bridge, wave memory subsystem, and I2S transmitter
  testbenches.

Use this before considering RTL behavior changes complete. The SystemVerilog
testbenches are self-checking and should exit nonzero on mismatch.

## Exact Audio Reference Comparison

Run the fast C++ reference-vs-RTL render:

```bash
make render-quick
```

Useful overrides:

```bash
make render-quick SECONDS=10
make render-quick NUM_VOICES=16 SECONDS=5
make render-quick SF2="/path/to/file.sf2" MIDI="/path/to/song.mid" SECONDS=30 RENDER_QUICK_OUT_DIR="build/render_quick_case"
```

What it does:

- Builds a Verilated `wavetable_core` fast harness.
- Parses SF2 and optional MIDI at runtime.
- Drives the RTL register interface and direct word-memory model.
- Compares every RTL stereo output sample against the C++ fixed-point reference.
- Writes metrics to `quick_render_config.json` in the selected output directory.

Important metrics:

- `rtl_avg_render_cycles`: average cycles from `sample_tick` to `sample_valid`.
- `rtl_max_render_cycles`: worst per-sample render latency.
- `rtl_avg_render_memory_reads` and `rtl_max_render_memory_reads`: memory pressure.
- `rtl_max_enabled_voices`, `rtl_max_filtered_voices`, `rtl_max_stereo_voices`:
  workload shape.

Representative stress command used during voice-pipeline work:

```bash
make render-quick \
  SF2="/home/yuan/下载/MS_Basic.sf2" \
  MIDI="/media/yuan/60AE34D2AE34A308/Users/yuan/Desktop/midi合集/Hedwigs_Themefinished.mid" \
  SECONDS=30 \
  RENDER_QUICK_OUT_DIR="build/render_quick_hedwig_ms_basic_30s"
```

Use `render-quick` for algorithmic equivalence and cycle comparisons. It is not
a memory-controller timing signoff because it uses the quick direct-memory model.

## Memory-Profile Render

Run the memory-path render:

```bash
make render-memory
```

Useful overrides:

```bash
make render-memory SECONDS=2 MEMORY_PROFILE=ddr
make render-memory SECONDS=2 MEMORY_PROFILE=sdram
make render-memory SECONDS=2 MEMORY_PROFILE=parallel-nor
make render-memory SF2="/path/to/file.sf2" MIDI="/path/to/song.mid" SECONDS=20 RENDER_MEMORY_OUT_DIR="build/render_memory_case"
```

What it does:

- Builds a Verilated `wavetable_core_memory` harness.
- Drives real register programming and the `wave_memory_subsystem` line-cache path.
- Uses a C++ external line-memory model selected by `MEMORY_PROFILE`.
- Produces `out.wav` and memory statistics.

Read these outputs:

- `build/render_memory/out.wav` or the chosen output directory's `out.wav`.
- `memory_stats.json` for hit/miss/latency counters.

Use this when changing line cache behavior, memory request/response handshakes,
memory profiling, address generation, or wavetable layout.

## Full-System Render

Run the pin-level integration harness:

```bash
make render-full-system
```

Useful overrides:

```bash
make render-full-system SECONDS=0.1
make render-full-system SF2="/path/to/file.sf2" MIDI="/path/to/song.mid" SECONDS=2 RENDER_FULL_SYSTEM_OUT_DIR="build/render_full_system_case"
```

What it does:

- Builds a Verilated `wavetable_core_system` harness.
- Programs the core through an SPI master model at the top-level SPI pins.
- Serves the external line-memory interface from a C++ storage model.
- Decodes I2S output pins back into WAV samples.
- Writes `out.wav` from the decoded I2S stream.

Use this after touching SPI top-level wiring, I2S serialization, output FIFO,
system wrapper integration, or pin-level behavior.

## Single-Instrument Render

List instruments in the configured SF2:

```bash
make list-instruments
```

Render one instrument through the older testbench path:

```bash
make render-instrument INSTRUMENT=0 KEY=60 SECONDS=1
```

What it does:

- Extracts one SF2 instrument zone with `tools/sf2_extract.py`.
- Generates simulation inputs under `build/render/`.
- Runs `tb_render_wavetable_core`.
- Converts raw PCM to `build/render/out.wav`.

Use this for quick manual listening of a single region. Prefer `render-quick`
for exact reference-vs-RTL comparisons.

## Voice-Count And Performance Exploration

Use `NUM_VOICES` to compile both RTL and C++ harnesses with a different voice
count:

```bash
make render-quick NUM_VOICES=8 MIDI=assets/midi/dense_many_notes.mid SECONDS=5
make render-quick NUM_VOICES=16 MIDI=assets/midi/dense_many_notes.mid SECONDS=5
make render-quick NUM_VOICES=32 MIDI=assets/midi/dense_many_notes.mid SECONDS=5
```

Keep SF2, MIDI, sample rate, and duration fixed when comparing cycle counts.
Changing voice count can change musical behavior because the MCU model steals
voices earlier when the pool is smaller.

For deadline thinking, compare `rtl_max_render_cycles` against:

```text
system_clk_hz / output_sample_rate
```

Examples:

```text
100 MHz / 48 kHz = about 2083 cycles/sample
25 MHz  / 48 kHz = about 520 cycles/sample
```

## Vivado Area And Timing

Use the Smart Artix Vivado flow when resource or timing claims matter. The
installed Vivado path on this workstation has been:

```text
/opt/Xilinx2051.1/2025.2/Vivado/bin/vivado
```

The project flow is under:

```text
fpga/smart_artix/vivado/scripts/
```

Preferred reports after synthesis live under:

```text
build/fpga/smart_artix/vivado/reports/post_synth_utilization.rpt
build/fpga/smart_artix/vivado/reports/post_synth_utilization_hier.rpt
build/fpga/smart_artix/vivado/reports/post_synth_utilization_hier_depth4.rpt
build/fpga/smart_artix/vivado/reports/post_synth_timing.rpt
```

Read `post_synth_utilization_hier_depth4.rpt` first when looking for resource
ownership. Read `post_synth_timing.rpt` to distinguish core `ui_clk` timing from
MIG/DDR PHY or board-level timing groups.

Post-synthesis timing is useful for architecture feedback, but hardware signoff
requires implementation with real pins, external I/O timing constraints, and the
final board memory setup.

## Interpreting Common Results

- `make lint` passing means the synthesizable source set is structurally clean
  enough for Verilator lint. It does not prove behavior.
- `make test` passing means small exact integer regressions, SPI transport,
  memory subsystem, and I2S serialization passed their focused checks.
- `render-quick` passing means exact RTL/reference audio equivalence for the
  selected SF2/MIDI workload.
- `render-memory` passing means the line-cache memory path works for the selected
  memory profile and workload.
- `render-full-system` passing means SPI programming, external memory model, FIFO,
  and I2S pin-level output are coherent in simulation.
- Vivado synthesis passing means the selected RTL and IP can synthesize and gives
  area/timing estimates. It is not board signoff.

## Before Finalizing A Change

For narrow RTL edits:

```bash
make lint
make test
```

For voice renderer, DSP, register, or fixed-point behavior:

```bash
make lint
make test
make render-quick RENDER_QUICK_OUT_DIR="build/render_quick_<case>"
```

For memory path changes:

```bash
make lint
make test
make render-memory MEMORY_PROFILE=ddr RENDER_MEMORY_OUT_DIR="build/render_memory_<case>"
```

For top-level SPI/I2S/system wrapper changes:

```bash
make lint
make test
make render-full-system RENDER_FULL_SYSTEM_OUT_DIR="build/render_full_system_<case>"
```

For area/timing changes, also run the Smart Artix Vivado flow and compare the
flat and hierarchical reports against the previous snapshot.
