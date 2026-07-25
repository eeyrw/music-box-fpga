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
| `tb_lookahead_compressor` | Fixed delay, bypass, master gain, stereo-linked compression, attack/release state, backpressure, and final saturation. |

`sim/harness/render/lookahead_compressor_model` is the bit-exact C++ model of
the same post-mix path. It consumes signed 24-bit stereo mixes, accepts the
global compressor and master-volume commands, and returns no sample while the
fixed delay primes. Its unit test uses the same exact bypass, gain, linked
detector, release, saturation, current/max state, and counter vectors as
`tb_lookahead_compressor`. When constructed with a `RenderDiagnostics` pointer,
the model also publishes those fields through the existing render JSON report.

`ReferenceSynth::render_mix()` exposes the pre-compressor signed stereo
accumulator for system-path composition. Existing bare-core comparisons continue
to use `render_sample()`, which preserves their direct PCM16 saturation and has
no look-ahead delay.
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

See [`render_commands.md`](render_commands.md) for complete, directly reusable
commands covering real MIDI/SF2 inputs, compressor and baseline renders,
diagnostic extraction, and output-directory conventions.

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
make render-reference SF2=assets/soundfonts/example.sf2 INSTRUMENT=0
make render-reference MIDI=assets/midi/example.mid SECONDS=10 \
  COMPRESSOR_ENABLE=0
```

`CONTROL_TICK_MS` sets the periodic MCU control-update interval used for
modulation envelopes, LFOs, and dynamic gain, pitch, and filter commands. Set
`SAMPLE_ACCURATE_CONTROL=1` to update that control model once per output sample;
in that mode `CONTROL_TICK_MS` is ignored. The reference synthesizer's volume
envelope itself always advances once per output sample in both modes.

`render-reference` uses only the C++ integer synthesizer. `render-rtl-core`
fans identical command words to RTL and the reference and compares every output
sample exactly. Its reference branch queues complete commands and applies at
most 16 actions before each sample, matching `MAX_ACTION_BATCH` in the RTL
control plane. This distinction matters for simultaneous layered notes: actions
beyond the snapshot limit take effect on later frame boundaries, including the
START-defined envelope and phase origin. `render-memory` uses the cached RTL
path with a selectable external-memory timing profile. `render-board-loader`
also exercises the raw SD image and board-loader path.

`rtl_core_render_config.json` is written even when comparison mismatches cause
the executable to fail. Its `comparison_*` fields report the configured action
limit, reference actions enqueued/applied/pending, maximum queue depth, maximum
deferral in frames, mismatch count, first mismatch sample, and maximum absolute
left/right differences. A successful uninterrupted run has zero pending actions
and zero mismatches. These diagnostics separate control-boundary divergence
from arithmetic divergence without relying on waveform inspection.

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
- sine-table equal-power panning for mono regions. Collapsed stereo regions use
  the same curve normalized to unity at center because their samples are already
  hard-routed to independent left and right outputs;
- voice allocation, layering, exclusive class, sustain, and stealing;
- fixed and real-time SF2 modulator evaluation;
- conversion of durations, gains, pitch, and filter coefficients to FPGA fields.

The FPGA owns prepared/active lifecycle, sample-rate volume-envelope progression,
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

Render JSON records input provenance, voice count, render cycles, memory reads,
active/audible/stereo/filtered voice counts, queue high-water marks, cache
hits/misses, stalls, and saturation counts. `render-reference` also reports
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
