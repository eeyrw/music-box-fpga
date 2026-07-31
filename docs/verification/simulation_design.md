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
test-rtl-core       compact command plane, voice state, block renderer, and DSP tests
test-rtl-peripheral SPI command transport, credit/FIFO, I2S, and common status
```

All RTL tests are self-checking and return a nonzero result on failure.

## RTL Test Ownership

| Test | Main coverage |
| --- | --- |
| `tb_voice_major_render_core` | Compact command framing, mono START, global audio dispatch, block render, memory traffic, and state continuity. |
| `tb_block_voice_state_store` | Active state banks, generation arbitration, snapshots, and writeback. |
| `tb_voice_major_throughput` | 256/512 voice IDs, block deadline, and DSP issue under always-ready, next-cycle-response memory. The reported render time is a zero-wait theoretical datapath result and does not satisfy the real-pressure `<30,000`-clock acceptance gate. |
| `tb_voice_sample_window` | 32-word per-voice hits, ordered 8-word refills, fallback reads, and backpressure. |
| `tb_ddr3_timing_model` | Row hit/miss, activate/precharge, refresh, and request/response accounting. |
| `tb_lookahead_compressor` | Fixed delay, bypass, master gain, stereo-linked compression, attack/release state, backpressure, and final saturation. |

`sim/harness/render/lookahead_compressor_model` is the bit-exact C++ model of
the same post-mix path. It consumes signed 25-bit stereo mixes, accepts the
global compressor and master-volume commands, and returns no sample while the
fixed delay primes. Its unit test uses the same exact bypass, gain, linked
detector, release, saturation, current/max state, and counter vectors as
`tb_lookahead_compressor`. When constructed with a `RenderDiagnostics` pointer,
the model also publishes those fields through the existing render JSON report.

`ReferenceSynth::render_mix()` exposes the pre-compressor signed stereo
accumulator for system-path composition. Existing bare-core comparisons continue
to use `render_sample()`, which preserves their direct PCM16 saturation and has
no look-ahead delay.
| `tb_wavetable_i2s_output` | Startup fill, FIFO flow, played/render counters, and underrun gating. |
| `tb_spi_register_bridge` | Register frames, dedicated `0xa5` command stream, and backpressure errors. |
| `tb_i2s_tx` | Exact I2S bit and channel timing. |

Waveforms may aid diagnosis but are not pass criteria.

## C++ Harness Layout

```text
sim/harness/
  apps/          render executable entry points
  formats/       MIDI, SF2, and byte-stream parsing
  render/        MCU policy, shared types, and integer reference synthesizer
  control/       compact command construction and sinks
  common/        WAV and memory-profile helpers
  generated/     generated C++ hardware constants
sim/legacy/      superseded renderer harnesses and their testbenches
```

`CommandWordSink` is the voice-control transport boundary. RTL, the integer
reference, and CH347 consume the same command words; the superseded board-loader
adapter is retained only under `sim/legacy`.
There is no C++ per-voice register compatibility adapter.

## Render Targets

See [`render_commands.md`](render_commands.md) for complete, directly reusable
commands covering real MIDI/SF2 inputs, compressor and baseline renders,
diagnostic extraction, and output-directory conventions.

```bash
make render-reference SECONDS=1
make render-rtl-ddr3 SECONDS=1
make render-rtl-ddr3 SECONDS=1 RTL_EFFECTS=1 EFFECTS_PRESET=hall
```

Common overrides include:

```bash
make render-rtl-ddr3 MIDI=assets/midi/example.mid SECONDS=10
make render-rtl-ddr3 MIDI=assets/midi/example.mid START_SECONDS=30 SECONDS=10
make render-reference SF2=assets/soundfonts/example.sf2 INSTRUMENT=0
make render-reference MIDI=assets/midi/example.mid SECONDS=10 \
  COMPRESSOR_ENABLE=0
```

`CONTROL_TICK_MS` sets the periodic MCU control-update interval used for
modulation envelopes, LFOs, and dynamic gain, pitch, and filter commands. Set
`SAMPLE_ACCURATE_CONTROL=1` to update that control model once per output sample;
in that mode `CONTROL_TICK_MS` is ignored. The reference synthesizer's volume
envelope itself always advances once per output sample in both modes.

`render-reference` uses only the C++ integer synthesizer. `render-rtl-ddr3`
drives the compact command stream into the current Verilated voice-major core,
uses the 32-word sample window and timed DDR3 model, and writes
`rtl_ddr3_render_config.json`. The report includes shared input/session data,
region diagnostics, RTL cycle counts, window/refill statistics, DDR timing, and
render timing.

`RTL_EFFECTS=1` selects `voice_major_render_effects_harness`, which drains
the renderer's production mix buffer through the synthesizable
`global_audio_effects_chain`. MIDI/SF2 parsing and effect-preset register values
remain C++ harness policy; PCM processing and timing are RTL. The JSON separates
renderer completion from the end-to-end point where the mix buffer has been
accepted by the effects chain and released, and reports the latter deadline
misses independently. The harness and `voice_major_system` share
`voice_major_block_output_manager`, so render ownership, completion
backpressure, drain, and release are RTL behavior. C++ does not wait for release
or track bank ownership; it only presents the next MIDI/control-aligned request
after renderer completion. `rtl_max_block_initiation_cycles` measures accepted
request spacing and therefore includes any command burst before the next
request is presented. The final 48-frame compressor lookahead drain is a stream
flush, not part of an individual render-block deadline.

The `render-reference` Make target enables transparent peak protection by
default: -2 dBFS, 4:1, immediate attack, and a 5000 ms full-range release. Set
`COMPRESSOR_ENABLE=0` for an uncompressed comparison. The model uses the same
fixed-point LUTs, lookahead length, compact configuration command, and gain
arithmetic as RTL. Threshold is positive centibels below full scale (`20` is
-2 dBFS), and master volume is a linear `0..1` post-compressor gain. Attack and
release milliseconds specify traversal time for the complete 100 dB control
range and are converted to a fixed centibel step per frame. The JSON report
includes current and maximum detector/gain-reduction values, delay occupancy,
input/output/compressed frame counters, and the final PCM16 saturation count.

If a requested time window contains no audible events, the harness reports that
condition rather than treating an all-zero render as success.

### FluidSynth Comparison Tool

`tools/compare_reference_fluidsynth.py` automates a dry reference comparison.
It renders the C++ reference with the normal Make target, renders the same MIDI
and SF2 through FluidSynth with chorus and reverb disabled, trims both to the
requested time window, and parses FFmpeg `astats` into `comparison.json`.
Absolute RMS is reported but not compared because FluidSynth and the reference
use different master gains; `left_minus_right_rms_db` is the cross-renderer
balance metric.

```bash
python3 tools/compare_reference_fluidsynth.py \
  --sf2 assets/soundfonts/example.sf2 --midi assets/midi/example.mid \
  --seconds 30 --control-tick-ms 1 \
  --out-dir build/example_fluid_compare

python3 tools/compare_reference_fluidsynth.py \
  --reference-wav build/reference/out.wav \
  --fluid-wav build/fluidsynth.wav \
  --out-dir build/existing_wav_compare
```

## MIDI And SoundFont Policy

The host side owns:

- MIDI parsing, tempo, programs, banks, controllers, pressure, and pitch bend;
- preservation of MIDI source order when multiple events map to the same output
  sample, including order-sensitive controller/note sequences and RPN selection
  followed by Data Entry;
- SF2 preset/instrument/zone selection and sample-address calculation;
- FluidSynth-compatible `0.4` scaling for every file-defined
  `initialAttenuation` generator, matching the EMU8k/10k behavior expected by
  existing SoundFonts; MIDI/runtime attenuation modulators retain standard
  centibel units;
- FluidSynth-compatible default CC10 pan amount `500`, resolving the SF2 text's
  inconsistent `1000` amount against the pan generator's `-500..+500` range;
- sine-table equal-power panning for mono regions. Linked stereo and compatible
  hard-panned pairs remain two mono regions with independent channel gains;
- voice allocation, layering, exclusive class, sustain, and stealing;
- fixed and real-time SF2 modulator evaluation;
- conversion of durations, gains, pitch, and filter coefficients to FPGA fields.

The FPGA owns active voice lifecycle, sample-rate volume-envelope progression,
phase, filtering, mixing, and audio scheduling.

The Standard MIDI File parser accepts format 0 and format 1 files with PPQ time
division. It requires each track to end with a zero-length End of Track event and
rejects events after it. Format 2, SMPTE time division, and synthesizer-specific
SysEx execution are outside the current render subset. The channel policy does
not currently implement portamento, Hold 2, Data Increment/Decrement, tuning
program/bank RPNs, or the actual Omni/Mono/Poly mode transitions; CC124 through
CC127 still perform their required All Notes Off action.

Repeated Note On messages for the same channel/key receive distinct FIFO note
instances. A corresponding Note Off releases one instance and all of its
SoundFont layers. All Notes Off follows normal Note Off pedal precedence, while
All Sound Off remains immediate.

Controller execution follows the MIDI 1.0 assignments: CC64 is Sustain, CC66 is
Sostenuto, and CC67 is Soft Pedal. CC123 through CC127 perform All Notes Off;
CC120 bypasses release envelopes and stops sound immediately. RPN/NRPN selection
and Data Entry are ordered channel state machines. RPN 0 implements pitch-bend
sensitivity, including CC38 cents; RPN 1 and RPN 2 implement fine and coarse
tuning. Events retain their source order even when timestamp conversion rounds
several distinct times onto one output sample.

### File Attenuation Compatibility

The SoundFont 2.04 specification defines `initialAttenuation` generator 48 in
literal centibels: `60 cB` means `6 dB`, and matching preset- and
instrument-level value generators add before reaching the synthesis parameter.
It also defines the default velocity, CC7 volume, and CC11 expression
modulators as independent `960 cB` excursions.

The EMU8k/10k hardware does not apply the literal generator-48 scale. It applies
`0.4 dB` of attenuation for each `1 dB` stored in a preset or instrument zone.
Existing SoundFonts commonly target that hardware behavior. FluidSynth therefore
multiplies every file-defined `GEN_ATTENUATION` value by `0.4` while importing the
SoundFont, before instrument/preset generator precedence and addition. This is
unconditional: FluidSynth does not branch on `isng`, SoundFont version, or a
runtime setting. Its default and file-defined modulators are not scaled by this
compatibility factor.

The harness follows that FluidSynth behavior. `sf2_loader.cpp` applies `0.4` only
when converting file-defined generator 48 into a region base gain. Standard
centibel conversion remains `10^(-cB/200)`, and the following inputs do not use
the `0.4` factor:

- velocity-to-attenuation modulators;
- MIDI CC7 volume and CC11 expression modulators;
- modulation-LFO-to-volume and runtime generator offsets;
- volume-envelope sustain and release attenuation.

This is a deliberate compatibility policy rather than the literal generator-48
scale in the SF2 specification. It matches FluidSynth's
`EMU_ATTENUATION_FACTOR` loader behavior and prevents EMU-authored banks from
rendering some presets tens of decibels quieter than intended.

On Note On, the MCU model sends one compact `VOICE_START_MONO` command. Its
payload is 5 to 16 words depending on loop, filter, and envelope groups. Linked
stereo and compatible hard-panned SF2 pairs are
two mono regions and therefore consume two commands and two voices. START carries
the 10-bit voice ID, 16-bit generation, independent Q1.15 left/right gains,
Q24.8 phase increment and only the filter/envelope groups that are needed. START
clears the phase accumulator to zero.

On Note Off, the MCU model sends `VOICE_RELEASE` with the release step calculated
from the current region/controller state. Natural release completion is owned by
the FPGA; the host does not send a redundant STOP. `VOICE_STOP` is reserved for
immediate policy actions such as all-sound-off or voice replacement.

Volume-envelope duration preparation can use a coarse MCU policy tick or one
sample per tick. In both modes the command builder converts the selected
durations to sample counts/steps before START; the FPGA still advances the volume
envelope once per rendered sample. Modulation envelopes and LFOs remain host
control-rate policy and send only changed gain/phase or filter commands.

### Volume-Envelope Execution Model

There are three distinct volume-envelope representations in the render flow:

- `McuModel` maintains a control-rate shadow envelope using floating-point Q1.15
  interpolation. It supports voice lifecycle and stealing policy and schedules
  modulation updates, but it is not multiplied into the PCM output.
- `CommandVoiceControl` converts the host-prepared durations and levels into the
  integer START and RELEASE fields consumed by the synthesizer.
- The FPGA owns the audible envelope. `ReferenceSynth` is its C++ integer model;
  both advance the audible envelope once per output sample using Q0.32 linear
  Attack, Q12.20 centibel Decay/Sustain/Release, and the same generated
  centibel/Q1.15 lookup tables.

The normal START through NOTE-OFF/RELEASE path is intended to be bit-exact
between `ReferenceSynth` and RTL. RTL implements the calculation as a BRAM and
lookup-table pipeline, while the reference evaluates it directly in the sample
loop; those scheduling differences must not change the resulting PCM.

Audible volume-envelope durations are prepared directly in output samples and
do not depend on the MCU control interval. A nominal 1 ms Attack therefore lasts
48 samples at 48 kHz in both periodic and sample-accurate control modes. The SF2
default at `-12000` timecents is approximately 0.9766 ms and rounds to 47 samples.
`SAMPLE_ACCURATE_CONTROL=1` only changes how often the host-side modulation
envelopes, LFOs, and dynamic control commands are updated.

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

Render JSON records input provenance, voice count, render cycles, window client
requests/hits/refills/fallbacks/memory reads/stalls, DDR reads and row behavior,
active/audible/stereo/filtered voice counts, queue high-water marks, and
saturation counts. `render-reference` also reports
steady-clock milliseconds for SF2 loading, event parsing, region preparation,
the sample-render loop, and the total interval from SF2 loading through the last
rendered sample. The same timing breakdown is printed to stdout so render modes
can be compared without including C++ compilation time.

Detailed per-voice diagnostics are disabled by default because collecting
pre-saturation intermediates and jump maxima in the sample loop is expensive.
Set `DETAILED_DIAGNOSTICS=1` to collect:

- audible envelope update counts and maximum sample-to-sample envelope jump;
- effective runtime gain, phase-increment, and filter update counts;
- maximum left/right gain jump;
- maximum phase-increment and filter-coefficient jump;
- filter, voice-contribution, and final-mix saturation counts and pre-saturation
  maxima.

The cheap frame count, voice-steal count, and loudest stolen-voice score remain
available in normal runs.

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

### Native SD Model Boundaries

The native SD regressions deliberately keep two card-side models because they
verify different interfaces:

- `fake_sd_native_phy_model` is a command-level model. It accepts decoded
  command descriptors and models card state, APP_CMD qualification, RCA
  selection, ACMD42/ACMD6/ACMD51 ordering, SCR CMD23 discovery, CMD6 capability
  and selection data, CMD18 block sequencing, CMD12 termination, delayed block
  delivery, and transaction completion. It is used for fast
  `sd_native_block_reader` and complete asset-loader/DDR integration tests. It
  does not generate serial CMD frames or calculate wire CRCs.
- `fake_sd_native_pin_model` is a pin-level model. It observes the serialized
  command on `sd_cmd_o/sd_cmd_oe` and drives response bits and DAT nibbles into
  `sd_native_pin_phy`. It covers command/data framing, delayed start tokens,
  CRC7/CRC16, per-block CMD18 boundaries, R1b busy, and SD clock phase behavior.
  It does not model the full
  initialization policy or DDR loading flow.

The command-level model must not be used as evidence for pin framing or timing,
and the pin-level model must not be used as evidence for card-policy coverage.
Neither model replaces post-route I/O timing analysis, oscilloscope capture, or
tests with multiple physical SDHC/SDXC card families.

Build host utilities with:

```bash
make host-ch347
make host-smart-artix-bringup
```

The low-level tool can exercise the mono command transport without hardware:

```bash
build/ch347_control --dry-run --start-voice 0 --base 0 --length 1024
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

The incremental BRAM/DSP/LUT limits above belong to the command/control
refactor checkpoint and are not whole-design limits after global effects were
added. The current complete Smart Artix implementation uses 39.5 BRAM tiles, 47
DSPs, 19,306 LUTs, and 20,750 FFs and closes the constrained internal 100 MHz
domain with WNS +0.226 ns and WHS +0.036 ns. Long memory-stall/full-polyphony
render stress and external SPI/I2S timing remain open. See
`vivado_synthesis_timing.md` for the current signoff scope and path margin.
