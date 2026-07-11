# Simulation Design Notes

This document explains how the repository verifies and renders the current
multi-voice wavetable core.

For the numeric path from MIDI events to PCM samples, see
`docs/audio_render_calculation.md`.

There are two primary simulation paths:

- A self-checking regression using tiny synthetic sample data.
- A C++ SoundFont/MIDI render harness that produces a playable WAV file.

Both paths use Verilator and the same synthesizable RTL sources.

## Source Groups

The `Makefile` separates files into two groups:

```text
RTL_SOURCES = synthesizable hardware
SIM_SOURCES = behavioral memory model + self-checking testbench
```

`make lint` runs Verilator lint only on `RTL_SOURCES`. That keeps simulation-only
system tasks such as `$readmemh`, `$fopen`, and `$finish` out of the synthesizable
lint target.

`make test` builds the synthetic-data regression testbench:

```text
sim/tb/tb_wavetable_core.sv
```

`make render-instrument` builds the legacy single-instrument SoundFont render
testbench:

```text
sim/tb/tb_render_wavetable_core.sv
```

## Behavioral Memory Model

`sim/models/wave_memory_model.sv` is the shared simulation memory.

It contains an array of signed 16-bit words:

```systemverilog
synth_pkg::pcm_t memory [0:DEPTH-1];
```

The model always accepts requests:

```text
req_ready = 1
```

It returns response data one clock after `req_valid`. This is simple enough for
unit tests while still forcing the RTL to use a real request/response protocol
instead of assuming asynchronous array reads.

Out-of-range addresses return zero. That makes bad addresses audible as silence
and keeps simulation from failing before the testbench can report context.

## Self-Checking Regression

The regression testbench is `sim/tb/tb_wavetable_core.sv`.

It manually fills the memory model with small values:

```text
mono:   0, 1000, 2000, 3000
stereo: L/R interleaved pairs starting at word address 16
```

Then it programs the core through the same register bus used by normal software.
This matters because the test covers both the register bank and the multi-voice
pipeline, including commit isolation.

The key helper tasks are:

- `bus_write_word`: performs one register write and checks the bus response.
- `request_and_check`: pulses `sample_tick`, waits for `sample_valid`, and
  compares both output channels against exact integer expectations.
- `configure_mono`: programs a mono wave with fractional phase and 0.5 gain.
- `configure_stereo_loop`: programs stereo playback with an exclusive loop.
- `configure_mono_slot`: programs one voice slot for multi-voice mixing checks.

The test checks these behaviors:

- Mono samples are duplicated to both output channels.
- Fractional Q16.16 phase drives linear interpolation.
- Q1.15 gain scales the interpolated sample.
- Shadow register writes do not affect active playback until commit.
- Stereo samples are fetched from left/right interleaved memory.
- `loop_end` is exclusive.
- Two active voice slots render from one `sample_tick` and mix together.
- Per-voice `envelope_level` scales the current sample before mixing.
- Runtime `ENVELOPE_LEVEL` writes take effect without commit and without
  reloading voice phase.

The test is self-checking. A mismatch increments `errors`, and the test exits
with `$fatal` if any check fails.

## MCU Behavior In Simulation

Note allocation, Note Off, and envelope generation are intentionally modeled
outside synthesizable RTL. A testbench or simulation-only MCU model should drive
the register bus like firmware:

- Note On: allocate a voice slot, write sample/loop/tuning/gain fields and an
  initial `ENVELOPE_LEVEL`, then write `COMMIT`.
- Envelope update: write only `ENVELOPE_LEVEL`; this is a runtime register and
  does not reset phase.
- Note Off: continue writing release values to `ENVELOPE_LEVEL`.
- Voice release complete: clear the slot's enable bit and commit that slot.

The current regression implements this pattern directly with bus-write tasks.
Future tests can factor those tasks into a reusable `mcu_model` module when the
sequence coverage grows.

## SoundFont Render Flow

The render flow starts from a real SoundFont file:

```text
assets/soundfonts/MT6276.sf2
```

Run:

```bash
make list-instruments
make render-instrument INSTRUMENT=0 KEY=60 SECONDS=1
```

The render target performs three steps.

Step 1: Extract an instrument zone.

```bash
python3 tools/sf2_extract.py ...
```

The extractor reads these SF2 chunks:

```text
sdta/smpl: raw signed 16-bit PCM sample data
pdta/inst: instrument list
pdta/ibag: instrument zone ranges
pdta/igen: instrument zone generators
pdta/shdr: sample headers, loop points, sample rate, linked sample info
```

It writes:

```text
build/render/wave.memh
build/render/render_config.svh
build/render/render_config.json
```

`wave.memh` is loaded by `$readmemh`. `render_config.svh` is included by the
SystemVerilog render testbench. `render_config.json` is for human inspection.

Step 2: Render through RTL.

```bash
verilator --binary ... tb_render_wavetable_core
build/render_obj_dir/Vtb_render_wavetable_core
```

The render testbench programs the core registers from generated localparams,
then requests a fixed number of output samples. Each valid output sample is
written as little-endian stereo signed 16-bit PCM:

```text
build/render/out.pcm
```

Step 3: Wrap PCM as WAV.

```bash
python3 tools/pcm_to_wav.py ...
```

This creates:

```text
build/render/out.wav
```

The WAV file contains the exact sample stream produced by the RTL simulation.

## C++ MIDI-Driven Render Flow

`make render-midi` renders a short score through the same RTL core. The C++
harness parses SF2 and MIDI at runtime, models the MCU-side policy, drives the
register bus, serves the wave-memory ready/valid interface, and writes the WAV
file directly. The FPGA still sees only voice-slot configuration, runtime
envelope writes, wave-memory responses, and sample requests.

Run the built-in smoke melody:

```bash
make render-midi SECONDS=2
```

Render a standard MIDI file:

```bash
make render-midi MIDI=song.mid SECONDS=20
```

The C++ harness performs only simulation-side work:

- Convert MIDI events to sample timestamps.
- Track MIDI channel program and bank-select state for Note On events.
- Map each event to an SF2 preset, instrument zone, and sample region, then
  append the selected sample data into one C++ wave-memory image.
- Calculate each event's Q16.16 `phase_inc` from MIDI note, SF2 root key,
  tuning, and output sample rate.
- Convert SF2 volume envelope attack, decay, sustain, release, and sampleModes
  into per-region control values used by the C++ MCU model.
- Drive `wavetable_core` directly through its public Verilated ports.

The C++ path intentionally reads standard MIDI files directly; no intermediate
event file or generated MIDI SystemVerilog include is part of the current flow.

`sim/harness/render_midi_main.cpp` models the MCU at the precision used by this
FPGA project: 32 voice slots and Q1.15 runtime envelope levels. It uses SF2
volume-envelope step values, free-voice-first allocation, and oldest-voice
stealing when all slots are busy. On Note On it writes the selected slot's
wave/loop/phase/gain registers and commits. On each ADSR tick it writes
`ENVELOPE_LEVEL`. On Note Off it matches channel plus note, sets the runtime
released flag for loop-until-release samples, and when the envelope reaches zero
it disables and commits the slot.

Some MIDI files begin with silence before their first Note On. Events exactly at
the render endpoint are outside the produced sample range, so if `SECONDS` ends
at or before the first note event, the harness reports that no MIDI events fall
inside the requested render window. It also fails an all-zero PCM render instead
of reporting success; use a longer render window for those files.

This is intentionally not a complete MIDI synthesizer. It handles MIDI channel
program changes and bank select only far enough to choose an SF2 preset for each
Note On. It still ignores pedals, pitch bend, most controllers, drum-note maps,
SF2 modulators, volume-envelope delay/hold, and key-number envelope scaling. SF2
filter coefficient calculation also belongs in a richer MCU/control simulation;
the FPGA core only consumes an already calculated one-pole LPF alpha.

## Linked Stereo Samples

SoundFont stereo samples are commonly stored as two linked mono sample headers,
not as one interleaved sample. The extractor handles this before simulation.

If the selected sample is a left sample, `sampleLink` points to the right sample.
If the selected sample is a right sample, `sampleLink` points to the left sample.

The extractor converts the pair into the memory format required by the RTL:

```text
left(0), right(0), left(1), right(1), ...
```

If the selected sample is mono, the extractor writes mono memory and clears the
RTL stereo bit. The multi-voice pipeline then duplicates mono samples to both
channels.

## Tuning And Phase Increment

The extractor converts SoundFont tuning metadata to Q16.16 `phase_inc`.

Conceptually:

```text
phase_inc = source_sample_rate / output_sample_rate
          * pitch_ratio
          * 65536
```

The pitch ratio comes from:

```text
requested MIDI key
root key or originalPitch
pitchCorrection
fineTune
coarseTune
```

The default output sample rate is 48000 Hz.

## Generated Files

All render outputs are under `build/`, which is ignored by Git:

```text
build/render/wave.memh
build/render/render_config.svh
build/render/render_config.json
build/render/out.pcm
build/render/out.wav
build/render_midi/midi_render_config.json
build/render_midi/out.wav
```

The checked-in SF2 is small and intentionally stored under:

```text
assets/soundfonts/MT6276.sf2
```

## How To Read A Failing Simulation

For `make test`, start with the first `$error` line. It usually reports the
actual and expected sample value. Then inspect the programmed phase, gain, loop,
and memory values in `tb_wavetable_core.sv`.

For `make render-instrument`, inspect `build/render/render_config.json` first. It
shows which instrument, sample, loop points, sample rate, and phase increment the
extractor selected. For `make render-midi`, inspect
`build/render_midi/midi_render_config.json`; it also shows the decoded note
events. If the WAV is silent or unexpected, the issue is often in the selected
instrument zone, event timing, note range, or envelope parameters rather than in
the RTL.

## What This Does Not Verify Yet

The current simulation does not yet cover:

- Memory backpressure.
- Multi-cycle variable memory latency.
- More than two simultaneous active voices and mixer saturation boundaries.
- SoundFont preset lookup, velocity mapping, modulators, ADSR calculation, or
  filters.
- I2S output timing.

Those are good future test areas as the core scales beyond the current four-slot
simulation milestone.
