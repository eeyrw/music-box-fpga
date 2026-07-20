# Simulation Design Notes

This document explains how the repository verifies and renders the current
multi-voice wavetable core.

For stable fixed-point arithmetic rules, see `../fixed_point.md`.

There are six simulation intents:

- A self-checking regression using tiny synthetic sample data.
- A fast C++ reference-vs-RTL SoundFont/MIDI comparison path.
- A C++ SoundFont/MIDI memory-profile render harness that produces a playable WAV
  file.
- A pin-level full-system render harness whose WAV output is decoded from I2S.
- A board-loader render harness that first copies a raw SD SoundFont image into a
  DDR byte model through the Smart Artix native-SD loader RTL, then renders from
  the loaded DDR contents with exact RTL/reference comparison.
- Focused peripheral tests such as SPI register transport, wave-memory subsystem,
  and I2S serialization.

All RTL paths use Verilator and the same synthesizable RTL sources.

The C++ render harnesses (`render-quick`, `render-memory`, `render-full-system`,
and `render-board-loader`) build their Verilated fast paths with project-level
`RENDER_OPT_FAST=-O3` and `RENDER_OPT_GLOBAL=-O3` by default. These variables are
Makefile overrides, not global Verilator configuration; use `make render-quick
RENDER_OPT_FAST=-Os` to compare against Verilator's size-optimized default.

## Source Groups

The `Makefile` separates RTL and simulation sources into focused groups:

```text
RTL_SOURCES                    = synthesizable generic hardware
FPGA_COMMON_RTL_SOURCES        = reusable board-facing RTL adapters
SMART_ARTIX_RTL_SOURCES        = Smart Artix board RTL
SIM_SOURCES                    = behavioral memory model + core testbench
HARNESS_RENDER_COMMON_SRCS     = shared C++ MIDI/SF2/render/control sources
HARNESS_WAV_SRC                = shared WAV writer
HARNESS_MEMORY_PROFILE_SRC     = shared external-memory timing profile parser
HARNESS_BOARD_LOADER_SRCS      = Smart Artix board-loader C++ harness support
```

`make lint` runs Verilator lint only on `RTL_SOURCES`. That keeps simulation-only
system tasks such as `$readmemh`, `$fopen`, and `$finish` out of the synthesizable
lint target.

The software-visible register constants are generated from
`spec/register_map.json` into both SystemVerilog and C++ headers:

```text
rtl/pkg/synth_register_pkg.sv
sim/harness/generated/register_map.h
```

Run `make generate-register-map` after changing the JSON source. Run
`make check-register-map` before committing to verify the checked-in generated
files still match the JSON register contract.

`make test` is the top-level regression. It runs C++ unit tests and focused RTL
testbenches, including the synthetic-data multi-voice regression:

```text
sim/tb/tb_wavetable_render_core.sv
```

It is also split into narrower targets:

```text
test-cpp-unit       = parser, register-control, and render-preparation unit tests
test-rtl-core       = voice phase, core render, and wave-memory subsystem tests
test-rtl-peripheral = SPI bridge, I2S transmitter, and demo-common status tests
```

`make render-instrument` builds the legacy single-instrument SoundFont render
testbench:

```text
sim/tb/tb_wavetable_render_core_asset.sv
```

## C++ Harness Layout

The C++ harness code under `sim/harness/` is organized by role:

```text
apps/          Executable entry points for render-quick, render-memory,
               render-full-system, and render-board-loader.
formats/       SF2 and MIDI parsers plus shared byte-reader utilities.
render/        Shared render data types, `McuModel`, render preparation, and
               the exact fixed-point reference synthesizer.
control/       Register write sink interfaces and voice register programming.
dut/           C++ adapters around Verilated DUTs.
common/        WAV output, memory timing profiles, and small shared helpers.
board_loader/  Raw-SD image helpers and Smart Artix SD/DDR loader harness model.
generated/     Generated C++ register-map constants.
```

The directory named `dut/` is intentionally C++ simulation code. It wraps
Verilated top modules and should not be confused with synthesizable RTL under
the repository-level `rtl/` directory.

## Behavioral Memory Model

`sim/models/line_memory_model.sv` is the shared external line-memory simulation
model for SystemVerilog tests.

It contains an array of signed 16-bit words and returns packed memory lines to
`wave_memory_subsystem`:

```systemverilog
synth_pkg::pcm_t memory [0:DEPTH-1];
```

The model always accepts requests:

```text
req_ready = 1
```

It returns response data after the configured latency. This is simple enough for
unit tests while still forcing the RTL to use a real request/response protocol
instead of assuming asynchronous array reads.

Out-of-range addresses return zero. That makes bad addresses audible as silence
and keeps simulation from failing before the testbench can report context.

## Self-Checking Regression

The regression testbench is `sim/tb/tb_wavetable_render_core.sv`.

It manually fills the memory model with small values:

```text
mono:   0, 1000, 2000, 3000
stereo: left region starts at word address 16, right region starts at word address 24
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
- Fractional Q24.8 phase drives linear interpolation.
- Q1.15 gain scales the interpolated sample.
- Shadow register writes do not affect active playback until commit.
- Stereo samples are fetched from independent absolute left/right memory regions.
- `loop_end` is exclusive.
- Two active voice slots render from one `sample_tick` and mix together.
- Per-voice `envelope_level` scales the current sample before mixing.
- Runtime `ENVELOPE_RUNTIME` writes take effect without commit and without
  reloading voice phase.

The test is self-checking. A mismatch increments `errors`, and the test exits
with `$fatal` if any check fails.

## MCU Behavior In Simulation

Note allocation, Note Off, and envelope generation are intentionally modeled
outside synthesizable RTL. A testbench or simulation-only MCU model should drive
the register bus like firmware:

- Note On: allocate a voice slot, write sample/loop/tuning/gain fields and an
  initial `ENVELOPE`, then write `VOICE_CONTROL` with enable and apply set.
- Envelope update: write only `ENVELOPE_RUNTIME`; this is a runtime register and
  does not reset phase.
- Note Off: continue writing release values to `ENVELOPE_RUNTIME`.
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
verilator --binary ... tb_wavetable_render_core_asset
build/render_obj_dir/Vtb_wavetable_render_core_asset
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

## C++ Quick RTL/Reference Flow

`make render-quick` is the fast SF2/MIDI algorithm-verification path. It parses
the same SF2 and MIDI inputs as the render harness, runs the shared MCU policy
model, and drives two backends from the same control writes:

- `ReferenceSynth`: a C++ fixed-point model of the current wavetable playback,
  interpolation, Q1.15 gain/envelope, loop, and saturation rules.
- `QuickRtlHarness`: a Verilated `wavetable_render_core` instance with a direct one-word
  memory response model.

This path intentionally skips SPI, I2S, `wave_memory_subsystem`, and external
storage profiles. Its primary job is to answer one question quickly: does the RTL
core produce the same integer PCM stream as the project reference algorithm? It
also writes the matched RTL PCM stream as a WAV so real MIDI renders can be
auditioned without using the slower memory or full-system harnesses.

Run the built-in smoke melody:

```bash
make render-quick SECONDS=1
```

Render a standard MIDI file through the same quick comparison:

```bash
make render-quick MIDI=song.mid SECONDS=20
```

The run writes the selected region summary and RTL WAV output to:

```text
build/render_quick/quick_render_config.json
build/render_quick/out.wav
```

The summary includes aggregate RTL render counters and MCU-control traffic:
`register_writes_total`, `register_writes_envelope`,
`register_writes_gain_runtime`, `register_writes_phase_inc_runtime`,
`register_writes_filter`, `register_writes_commit`,
`register_writes_release`, and `register_writes_config`.

It also includes `diagnostics_*` fields for auditioning artifacts that are not
visible from final WAV peak level alone. `ReferenceSynth` records how many frames
and channel/voice occurrences hit filter output saturation, filter-state
saturation, per-voice contribution saturation, and final mix saturation. The MCU
policy records `diagnostics_voice_steals` plus the largest runtime gain,
`PHASE_INC_RUNTIME`, and filter-coefficient jumps. `render-memory` and
`render-full-system` write the same MCU-side diagnostics into their stats JSON
files; they do not currently expose RTL-internal filter/contribution saturation
because those paths do not run `ReferenceSynth` in parallel.

Any sample mismatch reports the first few differing frames and exits nonzero.
The current comparison is exact; it does not allow tolerance windows.

Two helper scripts are useful when exercising the SF2 filter path:

```bash
python3 tools/sf2_filter_report.py --sf2 assets/soundfonts/MT6276.sf2
python3 tools/make_filter_probe_assets.py --out-dir build/filter_probe
python3 tools/sf2_filter_report.py --sf2 build/filter_probe/filter_probe.sf2 \
  --write-midi build/filter_probe/generated_probe.mid
make render-quick SF2=build/filter_probe/filter_probe.sf2 \
  MIDI=build/filter_probe/generated_probe.mid SECONDS=2 \
  RENDER_QUICK_OUT_DIR=build/render_quick_filter_probe
```

`sf2_filter_report.py` scans raw `pgen`/`igen` records and merged playable
regions for `initialFilterFc`, `initialFilterQ`, `modLfoToFilterFc`, and
`modEnvToFilterFc`. The checked-in `MT6276.sf2` currently reports zero filter
generators, so the generated probe SF2/MIDI pair is the focused regression input
for static biquad filter behavior.

A real SGM-derived SoundFont such as
`SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2` does use filters heavily. A probe run
against that file reported hundreds of raw filter generators and thousands of
merged playable regions with filter settings. Some regions use very low cutoff
values after SF2 range clamping, so the RTL filter coefficients are signed Q4.28;
the earlier Q2.14 coefficient format did not preserve enough low-frequency
precision for those regions.

## C++ Full-System I2S Render Flow

`make render-full-system` renders through `wavetable_demo_system`, a pin-level RTL
wrapper that combines:

- `spi_register_bridge` for control writes.
- `wavetable_system_core`, composing the render core and line-memory adapter for
  the audio core and line-memory interface.
- `wavetable_i2s_output` for the output FIFO and I2S adapter.
- A `100 MHz` system clock with `fractional_tick_gen` instances for sample ticks
  and I2S BCLK edges.

The C++ harness does not read internal PCM signals. It interacts only with the
top-level pins:

- A C++ SPI master bit-bangs `spi_sclk`, `spi_cs_n`, and `spi_mosi` to program
  voice registers.
- A C++ storage model responds to `ext_req_valid`, `ext_req_addr`, and
  `ext_rsp_data` on the external line-memory interface.
- A C++ I2S receiver decodes `i2s_bclk`, `i2s_lrclk`, and `i2s_sdata`; the output
  WAV is written from this decoded stream.

Run a short full-system smoke render:

```bash
make render-full-system SECONDS=0.1
```

The run writes:

```text
build/render_full_system/out.wav
build/render_full_system/full_system_render_config.json
build/render_full_system/full_system_stats.json
```

`full_system_stats.json` records I2S/audio integration counters, memory hit/miss
counters, and the same register-write breakdown used by `render-quick`. The
register counters are useful for separating pin-level SPI control overhead from
audio rendering and memory traffic.

This path currently supports only `SAMPLE_RATE=48000`, using the default
`100 MHz` system clock and fractional audio timing. A small startup underrun can
be reported before the first programmed sample is available; sample drops
indicate the core produced a frame when the I2S transmitter could not accept it
and should be treated as an integration bug.

Current full-system limitations are intentional:

- The SPI master is a C++ test harness model, not RTL intended for synthesis.
- The storage side is still a C++ line-memory model, not a parallel NOR, SPI
  Flash, SDRAM, or DDR controller.
- The wrapper has one fixed `100 MHz` clock and does not yet model board PLLs,
  clock-domain crossings, codec MCLK, or reset sequencing.
- I2S RX exists only in the C++ harness and focused testbench; the synthesizable
  audio path is transmit-only.
- Full-system runs are smoke/integration tests today. Longer high-polyphony
  stress tests and exact I2S-decoded PCM comparisons against `render-quick` are
  tracked in `../design/system_design.md`.

## C++ Board-Loader Render Flow

`make render-board-loader` verifies the Smart Artix asset-loading path and the
wavetable render path in one run. The harness builds a raw SD image at runtime:
sector 0 contains the `WTSF` header from `../board/asset_loading.md`, and the selected
SF2 byte image starts at the configured LBA. It then drives a Verilated wrapper
containing:

- `smart_artix_sd_native_asset_loader`, including the native SD command-level
  block reader and DDR3 asset writer.
- `wavetable_cached_render_core`, including the line-cache memory subsystem.

The C++ side models the SD card at the command/data boundary, not at `CMD` and
`DAT[3:0]` pins. This keeps full-SF2 regressions fast enough to run regularly
while the focused SystemVerilog pin-level tests cover command framing, 4-bit data
capture, and CRC behavior. After the loader asserts `asset_loaded`, the harness
checks every loaded DDR byte against the source SF2 file before rendering.

Run a short board-loader smoke render:

```bash
make render-board-loader SECONDS=0.1
```

Useful overrides match the other render harnesses:

```bash
make render-board-loader SF2=/path/to/file.sf2 MIDI=song.mid SECONDS=10
make render-board-loader MEMORY_PROFILE=ddr RENDER_BOARD_LOADER_OUT_DIR=build/render_board_loader_case
```

The run writes:

```text
build/render_board_loader/out.wav
build/render_board_loader/board_loader_render_config.json
```

The JSON summary records the loaded SF2 byte count, raw SD image size, loader
cycle count, register-write count, memory hit/miss counters, render workload
summary, and the same `diagnostics_*` fields used by `render-quick`. The render
samples are compared exactly against `ReferenceSynth`; any mismatch fails the
run.

## C++ Memory-Profile Render Flow

`make render-memory` renders a short score through `wavetable_cached_render_core`, which
wraps the core with `wave_memory_subsystem`. The C++ harness parses SF2 and MIDI
at runtime, models the MCU-side policy, drives the register bus, serves the
external line-read memory interface, and writes the WAV file directly. The FPGA
still sees only voice-slot configuration, runtime envelope writes, memory line
responses, and sample requests.

Run the built-in smoke melody:

```bash
make render-memory SECONDS=2
```

Render a standard MIDI file:

```bash
make render-memory MIDI=song.mid SECONDS=20
make render-memory MIDI=song.mid SECONDS=20 MEMORY_PROFILE=parallel-nor
```

The C++ harness performs only simulation-side work:

- Convert MIDI events to sample timestamps.
- Track MIDI channel program and bank-select state for Note On events.
- Map each event to an SF2 preset, instrument zone, and sample region, then
  append the selected sample data into one C++ wave-memory image.
- Calculate each event's Q24.8 `phase_inc` from MIDI note, SF2 root key,
  tuning, and output sample rate.
- Convert SF2 volume and modulation envelope attack, decay, sustain, release,
  and sampleModes into per-region control values used by the C++ MCU model.
- Drive `wavetable_cached_render_core` through its public Verilated ports, including the
  external line-memory request/response interface.

Each `make render-memory` run writes memory subsystem counters to:

```text
build/render_memory/memory_stats.json
```

The recorded fields are `profile`, `line_words`, `random_latency_cycles`,
`sequential_latency_cycles`, `ready_gap_cycles`, `external_line_requests`,
`sequential_line_requests`, `responses`, `avg_response_latency_cycles`,
`max_response_latency_cycles`, and the same register-write breakdown used by
`render-quick`. The supported read-only timing profiles are `ddr`, `sdram`, and
`parallel-nor`.

The C++ path intentionally reads standard MIDI files directly; no intermediate
event file or generated MIDI SystemVerilog include is part of the current flow.

`sim/harness/render/render_support_test.cpp` is the focused regression for the
shared render-preparation policy. It builds a small synthetic SF2 with a melodic
preset, a bank-128 drum preset, and an intentionally nonmatching extra layer. The
test checks that channel-10 Note On events select the percussion bank, that a
playable layer survives when another layer misses the key range, and that a fully
unmapped Note On is silenced instead of aborting the render.

## MIDI/SF2 Render Calculation

The C++ harnesses share the same preparation and MCU policy code in
`sim/harness/render/render_support.cpp`.

Event timing:

```text
event_sample = round(event_time_seconds * output_sample_rate)
```

Before output frame `N` is requested, the MCU model handles every MIDI event with
`event_sample <= N`. A Note On at sample `N` is therefore audible in the output
requested for sample `N`, subject to the RTL pipeline latency of that harness.

Pitch calculation:

```text
phase_inc = round(source_sample_rate / output_sample_rate
                  * 2^((midi_key - root_key + tuning_cents / 100) / 12)
                  * 256)
```

`root_key`, tuning, and sample rate come from the selected SF2 instrument zone and
sample header. The RTL receives only the resulting unsigned Q24.8 `PHASE_INC`.

Voice allocation is MCU-side policy:

- Prefer the first silent slot.
- If all 32 slots are active, steal the oldest allocated slot.
- Runtime envelope level is set before committing a new Note On voice so phase is
  loaded exactly once.
- Repeated Note On events for the same channel/note can occupy multiple slots;
  Note Off releases all matching active slots.

The current envelope model converts SF2 volume-envelope generators into
control-tick Q1.15 levels. Volume attack uses a linear-amplitude ramp, while
volume decay and release use a dB-linear curve approximation by interpolating
amplitude geometrically. It runs every `adsr_tick_ms` milliseconds, defaulting
to 5 ms. This is intentionally simpler than a sample-rate SF2 envelope, but it
exercises the hardware contract: runtime `ENVELOPE_RUNTIME` writes update
runtime amplitude without commit and without reloading phase.

The normal Note On register sequence is:

```text
ENVELOPE       = selected initial Q1.15 envelope, normally 0 for ADSR Note On
BASE_ADDR      = selected left/mono memory word address
BASE_ADDR_R    = selected right memory word address for stereo
LENGTH         = left/mono sample frames
LENGTH_R       = right sample frames for stereo
LOOP_START     = left/mono first loop frame
LOOP_START_R   = right first loop frame for stereo
LOOP_END       = left/mono exclusive loop end
LOOP_END_R     = right exclusive loop end for stereo
PHASE_INIT     = 0
PHASE_INC      = generated Q24.8 increment
GAIN           = packed selected Q1.15 channel gains, {right, left}
VOICE_CONTROL  = mono/stereo + loop mode + enable + apply
```

At Note Off, loop-until-release samples receive `RELEASE_CONTROL.released = 1`.
The MCU model then continues release envelope writes and eventually disables and
commits the slot when the envelope reaches zero.

`sim/harness/render/render_support.cpp` models the MCU at the precision used by
this FPGA project: 32 voice slots and Q1.15 runtime envelope levels. It uses SF2
volume-envelope step values, free-voice-first allocation, and oldest-voice
stealing when all slots are busy. On Note On it writes the selected slot's
wave/loop/phase/gain registers and commits. On each ADSR tick it writes
`ENVELOPE_RUNTIME`. On Note Off it matches channel plus note, sets the runtime
released flag for loop-until-release samples, and when the envelope reaches zero
it disables and commits the slot. `render-quick` and `render-memory` share this MCU
model so algorithm comparisons and memory-profile renders use the same control
policy.

Some MIDI files begin with silence before their first Note On. Events exactly at
the render endpoint are outside the produced sample range, so if `SECONDS` ends
at or before the first note event, the harness reports that no MIDI events fall
inside the requested render window. It also fails an all-zero PCM render instead
of reporting success; use a longer render window for those files.

This is intentionally not a complete MIDI/SoundFont synthesizer. The current
harness is a sample-region extractor plus a simplified MCU policy model. Its
purpose is to choose plausible SF2 samples, program the RTL voice slots, and
exercise wavetable playback through realistic register and memory traffic.

Current SF2 support:

- RIFF/sfbk container parsing for `sdta/smpl` and `pdta`.
- Required `INFO/ifil`, `INFO/isng`, and `INFO/INAM` parsing and validation.
- `sdta/smpl` 16-bit sample playback. `sdta/sm24` 24-bit extension data is
  ignored because the current RTL memory path consumes signed 16-bit PCM words.
- Required `pdta` chunk presence, record-size, terminal-record, and index-table
  consistency checks for `phdr`, `pbag`, `pmod`, `pgen`, `inst`, `ibag`, `imod`,
  `igen`, and `shdr`.
- MIDI program and bank-select lookup into SF2 presets.
- General MIDI channel-10 percussion lookup into SF2 percussion bank 128.
- Preset-zone and instrument-zone selection by key range and velocity range.
- Global-zone plus local-zone merging for presets and instruments, with
  instrument-level generators treated as absolute and preset-level value
  generators treated as additive where supported.
- Mono samples and common linked-stereo samples. Linked stereo keeps separate
  left/right absolute sample addresses, lengths, and loop points; when both
  linked zones match, pitch and pitch-routing generators come from the right
  sample zone while non-pitch addressing and gain setup follow the selected zone.
- Sample header `start`, `end`, `startLoop`, `endLoop`, `sampleRate`,
  `originalPitch`, and `pitchCorrection` fields.
- Sample-address offset generators `startAddrsOffset`, `endAddrsOffset`,
  `startloopAddrsOffset`, `endloopAddrsOffset`, and their coarse variants.
- `overridingRootKey`, `fineTune`, `coarseTune`, `scaleTuning`, and `keynum`
  generators for Q24.8 `phase_inc` calculation.
- `pan` and `initialAttenuation` generators for left/right Q1.15 gain setup.
- Default MIDI velocity-to-initial-attenuation is approximated with a concave
  centibel curve before the software envelope target is quantized to Q1.15.
  Default MIDI velocity-to-filter-cutoff is also modeled as a linear negative
  unipolar source with a -2400 cent range.
- Modulation and vibrato LFO generators `delayModLFO`, `freqModLFO`,
  `delayVibLFO`, and `freqVibLFO`, plus routing generators
  `modLfoToPitch`, `vibLfoToPitch`, `modLfoToFilterFc`, and
  `modLfoToVolume`. The C++ MCU model advances them once per ADSR tick and
  writes runtime phase, runtime gain, and committed filter-control updates.
  `modLfoToVolume` is applied as a logarithmic centibel volume delta, so a
  positive generator value raises volume on the positive modulation-LFO
  excursion and lowers it on the negative excursion.
- Modulation-envelope `delayModEnv`, `attackModEnv`, `holdModEnv`,
  `decayModEnv`, `sustainModEnv`, `releaseModEnv`, `keynumToModEnvHold`, and
  `keynumToModEnvDecay`, plus `modEnvToPitch` and `modEnvToFilterFc` routing.
  `sustainModEnv` is interpreted as the SF2 0.1% drop-from-peak unit.
- Volume-envelope `delayVolEnv`, `attackVolEnv`, `holdVolEnv`, `decayVolEnv`,
  `sustainVolEnv`, `releaseVolEnv`, `keynumToVolEnvHold`, and
  `keynumToVolEnvDecay` generators, converted to software ADSR tick steps.
- `sampleModes` values for no loop, continuous loop, and loop-until-release.
- `velocity` substitution for the current software velocity-to-envelope target
  calculation.
- `exclusiveClass` for MCU-side mutual exclusion within the selected preset.
- MIDI CC1 modulation wheel, CC7 volume, CC10 pan, CC11 expression, CC64 sustain
  pedal, CC66 soft pedal, CC67 sostenuto as named by the SF2 2.04 controller
  table, CC98/99 plus CC6/38 SoundFont NRPN generator offsets, CC100/101 plus
  CC6/38 RPN pitch-bend sensitivity/fine-tune/coarse-tune, CC120 All Sound Off,
  CC121 Reset All Controllers, CC123 All Notes Off, polyphonic key pressure,
  channel pressure, and pitch bend. CC7 and CC11 use the same concave centibel
  attenuation approximation as Note On velocity. CC1 and channel pressure add the
  SF2 default vibrato-LFO pitch-depth modulation. CC10 and SoundFont NRPN `pan`
  offsets are added at the SF2 `pan` summing node and clamped before left/right
  gain conversion. Soft pedal is modeled as a fixed initial-attenuation increase
  for the current dry path. These are MCU-side controller policy events that
  drive runtime gain, envelope/release, and `PHASE_INC_RUNTIME` writes. Runtime
  left/right gain updates use one packed register write so SPI cannot expose a
  half-updated stereo gain pair.
- Multiple overlapping matching preset/instrument zones for layered Note On
  playback.
- `pmod` and `imod` records for generator destinations that can affect the
  current dry wavetable path. The loader parses SF2 modulator source polarity,
  direction, linear/concave/convex/switch source type, secondary amount source,
  linear/absolute transform, and default/instrument/preset global/local
  precedence. The MCU evaluator applies the resulting modulator set to initial
  attenuation, pan, initial pitch, pitch-routing amounts, and filter cutoff.
- Standard MIDI renders silence Note On events whose selected preset/instrument
  has no matching key/velocity region, while still treating all-zero renders as
  failures.

Channel-10 percussion and unmapped-zone behavior deserve a precise note because
they are easy to confuse with corrupt SoundFont data. MIDI note numbers are always
encoded in the range 0 through 127, but the SF2 format does not require every
preset to define a playable region for every one of those keys. A General MIDI
compatible SoundFont usually covers the musically useful range for each melodic
preset, and drum presets usually cover the standard drum-note range, but both are
implemented through ordinary SF2 key/velocity ranges. Missing coverage for an
extreme key, an unused velocity layer, or a nonstandard drum note is legal SF2
data; a player should normally silence that one Note On rather than fail the
entire song.

The `MS_Basic.sf2` investigation exposed a more specific loader bug. The failing
Beethoven MIDI did not require a completely absent region in the first 10 seconds.
Instead, `Grand Piano` selected multiple preset layers for the same Note On. Some
layers resolved to playable instrument zones, while another layer resolved to an
instrument such as `Piano MF-high` whose local key ranges covered only high notes
around 88 through 108. The old loader called the matching helper once per selected
layer and threw `no SF2 zone matches key/velocity` as soon as any one layer had no
instrument-zone match, even when other layers for the same Note On were valid.
The current policy skips only the nonmatching layer, keeps all matching layers,
and reports an error only if no playable region remains for a direct extraction or
if a standard MIDI render contains no playable Note On events at all.

For percussion, MIDI channel 10 is channel index 9 in the parser. The render
policy maps that channel to SF2 bank 128, then uses normal preset, key-range, and
velocity-range selection. This implements the common General MIDI/SoundFont drum
bank convention without inventing a separate drum-note table in the harness.

Known SF2/MIDI gaps to implement later are listed below. These are gaps against
the SoundFont 2.04 specification, not necessarily blockers for RTL wavetable-core
regression testing.

SF2 file-format and sample-data gaps:

- ROM samples are not supported. `irom` and `iver` are not parsed, and ROM sample
  use is rejected when a selected sample region references ROM data. A conforming
  loader with external ROM access would need to validate and serve the referenced
  ROM instead.
- Linked sample type `linkedSample = 8` is not implemented. The harness supports
  mono, left, and right sample headers plus the common left/right `sampleLink`
  pair, but not a circular linked-sample list.
- Structural validation is still partial. The loader checks required chunk
  presence, record sizes, table index consistency, duplicate preset/bank pairs,
  selected range legality, basic sample bounds, sample rate, sample-link bounds,
  and sample-type enumerators, but it does not yet enforce every spec constraint
  such as sample minimum loop size, sample guard points, or every illegal
  enumerator rule.

Generator gaps:

- LFO and modulation-envelope generators are modeled at the MCU control-tick
  rate, not at audio-sample rate. Very fast modulation or audio-rate modulation
  will therefore be approximated by stepped runtime `PHASE_INC_RUNTIME` and
  filter-coefficient writes.
- Volume and modulation envelopes use control-tick curve approximations. Volume
  attack is linear in amplitude, and volume decay/release are dB-linear
  approximations from the current stage level. Modulation-envelope stages are
  linear in their modulation-depth domain. This is closer to SF2 perceptual
  envelope behavior than the old linear Q1.15 volume decay/release steps, but it
  is still not a sample-rate implementation of every SF2 envelope transform
  detail.
- Effects sends are ignored. `chorusEffectsSend` and `reverbEffectsSend` do not
  affect the rendered output because the RTL path has no effects processor.
- Generator precedence is implemented only for the subset consumed by the current
  harness. Unsupported value generators may be carried in the merged zone but do
  not affect audio. Unsupported preset-level sample/substitution generators are
  ignored where the loader recognizes them as illegal.

Modulator gaps:

- Linked modulator chains, where one modulator destination feeds another
  modulator source, are parsed as valid records but not evaluated.
- Effects-send modulators such as CC91 reverb send and CC93 chorus send are not
  audible because the current dry RTL path has no effects processor.
- Unsupported or future modulator source/controller enumerators and destination
  generators are ignored, as allowed by the SF2 error-handling rules.

MIDI and controller-policy gaps:

- Velocity is used for zone selection and Note On peak level. The current peak
  level approximates the SF2 default velocity-to-volume concave attenuation
  curve before the Q1.15 envelope model is applied.
- Channel 10 percussion uses the General MIDI/SF2 convention of bank 128 and then
  relies on normal SF2 key-range selection for drum-note maps. More advanced
  preset-specific percussion policy is not modeled.
- The SoundFont NRPN controller path is implemented only for generator
  destinations that can affect the current dry wavetable path: pitch/fine/coarse
  tune, initial attenuation, pan, filter cutoff, modulation-LFO/modulation-
  envelope pitch and filter routing, and `modLfoToVolume`. NRPN destinations
  requiring unsupported runtime synthesis resources are ignored.
- Broader GM2 or device-specific controller policy is still intentionally small.
  CC96/97 Data Increment/Decrement, detailed soft-pedal filter behavior, effects
  controller conventions without a dry-path effect, and MIDI-mode/system
  behavior beyond the parsed events are not modeled.
- Pitch bend uses the General MIDI default +/-2 semitone range until RPN 0
  updates the channel range. RPN 1 and RPN 2 are modeled as channel fine-tune and
  coarse-tune generator offsets.
- Bank-select policy is minimal. CC0 and CC32 are parsed into a 14-bit bank value,
  but SF2-specific bank conventions beyond simple preset lookup are not modeled.

Stereo and region-selection gaps:

- If multiple preset or instrument zones overlap the same key and velocity, the
  harness triggers each matching region as a separate RTL voice. This exercises
  layered playback, subject to the current 32-voice allocation policy.
- Direct region extraction still treats lack of a key/velocity match as an error
  for the selected preset or instrument. Standard MIDI render preparation instead
  silences only the unmapped Note On and continues playback.

RTL integration gaps implied by complete SF2 support:

- SF2 static filter support is an RTL feature. The project uses a per-voice
  biquad IIR stage and host-calculated coefficients for `initialFilterFc` and
  `initialFilterQ`. Dynamic cutoff modulation remains host-controlled initially
  and may move into RTL if update rate or zipper noise becomes a problem.
- Pitch bend, vibrato, tremolo, and modulation-envelope routing initially remain
  host-controlled through runtime register updates, including
  `PHASE_INC_RUNTIME`, `ENVELOPE_RUNTIME`, and filter-control writes. SPI bandwidth
  is expected to be sufficient for the first implementation. If update rate,
  jitter, or audible zippering becomes a problem, move the high-rate LFO/envelope
  accumulators into RTL as a later optimization.
- Reverb and chorus sends remain unsupported for now. They require a separate DSP
  effects path, wet/dry mixing, and delay memory that are outside the current dry
  stereo wavetable core.
- Complex linked-stereo SoundFonts with circular `linkedSample = 8` sample lists
  remain unsupported. Ordinary left/right `sampleLink` pairs use strict right
  sample pitch control in the C++ loader and one shared RTL phase increment.
  A left/right link is accepted only when the target is the opposite side and
  links back to the selected header; invalid or stale links render as independent
  mono regions instead of being paired with unrelated sample data.
- Higher polyphony for heavily layered SF2 presets remains a pipeline and memory
  bandwidth optimization item. The current harness can trigger overlapping zones,
  but the RTL still exposes 32 voice slots. When all slots are busy, the MCU
  policy now prefers released or key-released voices, then the lowest estimated
  audible contribution from envelope level and runtime gain, before falling back
  to age.

## Linked Stereo Samples

SoundFont stereo samples are commonly stored as two linked mono sample headers,
not as one interleaved sample. The extractor now preserves that layout by writing
separate left and right base addresses.

If the selected sample is a left sample, `sampleLink` points to the right sample.
If the selected sample is a right sample, `sampleLink` points to the left sample.

The extractor converts the pair into the memory format required by the RTL:

```text
left(0), right(0), left(1), right(1), ...
```

If the selected sample is mono, the extractor writes mono memory and clears the
RTL stereo bit. The multi-voice pipeline then duplicates mono samples to both
channels.

## Generated Files

All render outputs are under `build/`, which is ignored by Git:

```text
build/render/wave.memh
build/render/render_config.svh
build/render/render_config.json
build/render/out.pcm
build/render/out.wav
build/render_quick/quick_render_config.json
build/render_memory/midi_render_config.json
build/render_memory/out.wav
build/render_memory/memory_stats.json
build/render_full_system/full_system_render_config.json
build/render_full_system/full_system_stats.json
build/render_full_system/out.wav
```

The checked-in SF2 is small and intentionally stored under:

```text
assets/soundfonts/MT6276.sf2
```

## How To Read A Failing Simulation

For `make test`, start with the first `$error` line. It usually reports the
actual and expected sample value. Then inspect the programmed phase, gain, loop,
and memory values in `tb_wavetable_render_core.sv`.

For `make render-instrument`, inspect `build/render/render_config.json` first. It
shows which instrument, sample, loop points, sample rate, and phase increment the
extractor selected. For `make render-memory`, inspect
`build/render_memory/midi_render_config.json`; it also shows the decoded note
events. If the WAV is silent or unexpected, the issue is often in the selected
instrument zone, event timing, note range, or envelope parameters rather than in
the RTL.

## What This Does Not Verify Yet

The current simulation still does not cover:

- A concrete board-memory controller or physical Flash command protocol.
- Long full-system MIDI runs at high polyphony.
- Output FIFO sizing and sustained underrun policy beyond startup behavior.
- More exhaustive mixer saturation boundaries.
- Exhaustive SF2 source-curve edge cases, linked modulator chains, broader MIDI
  controller policy, envelope edge cases, and dynamic filter modulation stress.

Those are good future test areas as the 32-voice core moves toward board-level
integration.
