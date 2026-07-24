# Verification And Render Flows

This document describes the current self-checking tests and C++ render harnesses.
Generated output belongs under `build/`.

## Required Checks

Run before committing behavioral or interface changes:

```bash
make generate-register-map
make lint
make test
```

`spec/register_map.json` is the register source of truth. The generator produces
`rtl/pkg/synth_register_pkg.sv` and
`sim/harness/generated/register_map.h`. Generated envelope lookup tables are
checked by the same build flow.

`make test` is split into:

```text
test-cpp-unit       C++ MIDI, SF2, command, reference, and MCU-policy tests
test-rtl-core       control parser/executor, renderer, memory, and cache tests
test-rtl-peripheral SPI command transport, credit/FIFO, I2S, and common status
```

All RTL tests are self-checking and return a nonzero result on failure.

## RTL Test Ownership

| Test | Main coverage |
| --- | --- |
| `tb_control_cmd_parser` | Header framing, payload length, reserved fields, flush, malformed commands. |
| `tb_transactional_control_plane` | DEFINE isolation, START promotion, sequence rejection, all runtime actions, envelope stages, and 16+1 action batching. |
| `tb_wavetable_render_core` | Exact mono/stereo PCM, phase, loops, filter/gain changes, highest voice, mixing, and debug snapshot. |
| `tb_voice_phase_frame` | Exact Q24.8 endpoint, loop, and done calculations. |
| `tb_wave_memory_subsystem` | Word-to-line adaptation and ready/valid behavior. |
| `tb_voice_line_cache` | Hits, misses, stream/voice isolation, prefetch, and backpressure. |
| `tb_wavetable_cached_render_core_counters` | Cache and renderer diagnostic counters. |
| `tb_render_credit_scheduler` | Target-level credits and inflight accounting. |
| `tb_wavetable_i2s_output` | Startup fill, FIFO flow, played/render counters, and underrun gating. |
| `tb_spi_register_bridge` | Register frames, dedicated `0xa5` command stream, and backpressure errors. |
| `tb_i2s_tx` | Exact I2S bit and channel timing. |
| `tb_wavetable_demo_common_status` | Common/platform register routing and sticky diagnostics. |

Waveforms may aid diagnosis but are not pass criteria.

## C++ Harness Layout

```text
sim/harness/
  apps/          render executable entry points
  formats/       MIDI, SF2, and byte-stream parsing
  render/        MCU policy, shared types, and integer reference synthesizer
  control/       transactional command construction and sinks
  dut/           adapters around Verilated RTL
  common/        WAV and memory-profile helpers
  board_loader/  Smart Artix raw-image loader simulation support
  generated/     generated C++ hardware constants
```

`CommandWordSink` is the voice-control transport boundary. RTL, the integer
reference, CH347, and board-loader adapters consume the same command words.
There is no C++ per-voice register compatibility adapter.

## Render Targets

```bash
make render-reference SECONDS=1
make render-rtl-core SECONDS=1
make render-memory SECONDS=2 MEMORY_PROFILE=sdram
make render-board-loader SECONDS=0.1
```

Common overrides include:

```bash
make render-rtl-core MIDI=assets/midi/example.mid SECONDS=10
make render-memory MIDI=assets/midi/example.mid START_SECONDS=30 SECONDS=10
make render-reference SF2=assets/soundfonts/example.sf2 INSTRUMENT=0 KEY=60
```

`render-reference` uses only the C++ integer synthesizer. `render-rtl-core`
fans identical command words to RTL and the reference and compares every output
sample exactly. `render-memory` uses the cached RTL path with a selectable
external-memory timing profile. `render-board-loader` also exercises the raw SD
image and board-loader path.

If a requested time window contains no audible events, the harness reports that
condition rather than treating an all-zero render as success.

## MIDI And SoundFont Policy

The host side owns:

- MIDI parsing, tempo, programs, banks, controllers, pressure, and pitch bend;
- SF2 preset/instrument/zone selection and sample-address calculation;
- voice allocation, layering, exclusive class, sustain, and stealing;
- fixed and real-time SF2 modulator evaluation;
- conversion of durations, gains, pitch, and filter coefficients to FPGA fields.

The FPGA owns prepared/active lifecycle, sample-rate volume-envelope progression,
phase, filtering, mixing, and audio scheduling.

On Note On, the MCU model sends DEFINE followed by START with a matching sequence.
Mono START traffic is 21 total words and stereo START traffic is 25. START carries
independent Q1.15 left/right gains, Q24.8 phase increment, and all six volume
envelope parameters.

On Note Off, the MCU model sends `VOICE_RELEASE` with the release step calculated
from the current region/controller state. Natural release completion is owned by
the FPGA; the host does not send a redundant STOP. `VOICE_STOP` is reserved for
immediate policy actions such as all-sound-off or voice replacement.

Volume-envelope duration preparation can use a coarse MCU policy tick or one
sample per tick. In both modes the command builder converts the selected
durations to sample counts/steps before START; the FPGA still advances the volume
envelope once per rendered sample. Modulation envelopes and LFOs remain host
control-rate policy and send only changed gain/phase or filter commands.

## Numeric Comparison

The C++ reference independently implements the RTL integer contract:

- signed 16-bit PCM;
- unsigned Q24.8 phase and interpolation;
- signed Q1.15 channel gain and envelope;
- signed Q2.14 biquad coefficients;
- the documented filter state widths, rounding, and saturation;
- signed 32-bit stereo accumulation and final PCM16 saturation.

Exact RTL/reference comparison is required. Floating-point SF2 policy may be
used before quantization, but expected PCM and fixed-point boundary tests use
integer calculations.

## Diagnostics

Render JSON records input provenance, voice count, render cycles, memory reads,
active/audible/stereo/filtered voice counts, queue high-water marks, cache
hits/misses, stalls, and saturation counts.

MCU diagnostics include:

- voice steals and the loudest stolen voice score;
- effective runtime gain, phase-increment, filter, and envelope-policy updates;
- maximum left/right gain jump;
- maximum phase-increment and filter-coefficient jump.

Some historical JSON field names retain `runtime_envelope_updates`. They describe
MCU envelope/modulation policy changes in the reference diagnostics, not writes
to a removed `ENVELOPE_RUNTIME` register.

## Memory Profiles

Memory-backed renders accept profiles such as zero-latency, SRAM-like, SDRAM,
and stall-heavy service. Use them to compare:

- average and maximum render cycles;
- logical word reads versus external line requests;
- demand hit/miss and prefetch usefulness;
- memory-stall cycles and queue occupancy;
- output FIFO minimum level, underruns, and drops.

A waveform that sounds correct under zero latency is not sufficient evidence for
the board path. Run at least one variable-latency profile for memory or scheduling
changes.

## Hardware-Oriented Checks

Build host utilities with:

```bash
make host-ch347
make host-smart-artix-bringup
```

The low-level tool can exercise command transport and the coherent debug snapshot
without hardware:

```bash
build/ch347_control --dry-run --start-voice 0 --base 0 --length 1024
build/ch347_control --dry-run --snapshot-voice 0
```

Simulation does not replace post-route qualification. Before declaring the
Smart Artix implementation complete, run representative full renders, long
stall/polyphony stress, post-route timing/utilization, and physical SPI/I2S
checks.

## Acceptance Boundary

The command/control refactor acceptance targets remain:

```text
additional BRAM <= 8 tiles
additional DSP  <= 2
additional LUT  <= 2500
final WNS       >= 0
average render cycles < 2083 at 100 MHz / 48 kHz
stress minimum_fifo_level > 0
steady-state sample_drop_count == 0
```

`make lint` and `make test` prove functional consistency. Only implementation
reports and long-running render stress can prove the resource and throughput
targets.
