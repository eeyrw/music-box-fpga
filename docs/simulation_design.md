# Simulation Design Notes

This document explains how the repository verifies and renders the current
single-voice wavetable core.

There are two simulation paths:

- A self-checking regression using tiny synthetic sample data.
- A SoundFont render harness that produces a playable WAV file.

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

`make render-instrument` builds the SoundFont render testbench:

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
This matters because the test covers both the register bank and the voice
pipeline, including commit isolation.

The key helper tasks are:

- `bus_write_word`: performs one register write and checks the bus response.
- `request_and_check`: pulses `sample_tick`, waits for `sample_valid`, and
  compares both output channels against exact integer expectations.
- `configure_mono`: programs a mono wave with fractional phase and 0.5 gain.
- `configure_stereo_loop`: programs stereo playback with an exclusive loop.

The test checks these behaviors:

- Mono samples are duplicated to both output channels.
- Fractional Q16.16 phase drives linear interpolation.
- Q1.15 gain scales the interpolated sample.
- Shadow register writes do not affect active playback until commit.
- Stereo samples are fetched from left/right interleaved memory.
- `loop_end` is exclusive.

The test is self-checking. A mismatch increments `errors`, and the test exits
with `$fatal` if any check fails.

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
RTL stereo bit. The voice pipeline then duplicates mono samples to both channels.

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
extractor selected. If the WAV is silent or unexpected, the issue is often in the
selected instrument zone or key range rather than in the RTL.

## What This Does Not Verify Yet

The current simulation does not yet cover:

- Memory backpressure.
- Multi-cycle variable memory latency.
- Multiple voices or mixing.
- SoundFont envelopes, filters, modulators, or preset lookup.
- I2S output timing.

Those are good future test areas once the core grows beyond the single-voice
playback milestone.
