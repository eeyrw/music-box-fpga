# Simulation Design Notes

This document explains how the repository verifies and renders the current
multi-voice wavetable core.

For stable fixed-point arithmetic rules, see `docs/fixed_point.md`.

There are five simulation intents:

- A self-checking regression using tiny synthetic sample data.
- A fast C++ reference-vs-RTL SoundFont/MIDI comparison path.
- A C++ SoundFont/MIDI memory-profile render harness that produces a playable WAV
  file.
- A pin-level full-system render harness whose WAV output is decoded from I2S.
- Focused peripheral tests such as SPI register transport, wave-memory subsystem,
  and I2S serialization.

All RTL paths use Verilator and the same synthesizable RTL sources.

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

## C++ Quick RTL/Reference Flow

`make render-quick` is the fast SF2/MIDI algorithm-verification path. It parses
the same SF2 and MIDI inputs as the render harness, runs the shared MCU policy
model, and drives two backends from the same control writes:

- `ReferenceSynth`: a C++ fixed-point model of the current wavetable playback,
  interpolation, Q1.15 gain/envelope, loop, and saturation rules.
- `QuickRtlHarness`: a Verilated `wavetable_core` instance with a direct one-word
  memory response model.

This path intentionally skips SPI, I2S, `wave_memory_subsystem`, external storage
profiles, and WAV output. Its job is to answer one question quickly: does the RTL
core produce the same integer PCM stream as the project reference algorithm?

Run the built-in smoke melody:

```bash
make render-quick SECONDS=1
```

Render a standard MIDI file through the same quick comparison:

```bash
make render-quick MIDI=song.mid SECONDS=20
```

The run writes the selected region summary to:

```text
build/render_quick/quick_render_config.json
```

Any sample mismatch reports the first few differing frames and exits nonzero.
The current comparison is exact; it does not allow tolerance windows.

## C++ Full-System I2S Render Flow

`make render-full-system` renders through `wavetable_core_system`, a pin-level RTL
wrapper that combines:

- `spi_register_bridge` for control writes.
- `wavetable_core_memory` and `wave_memory_subsystem` for the audio core and line
  memory interface.
- A fixed 49.152 MHz / 48 kHz sample-tick generator.
- `i2s_tx` for serial audio output.

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

This path currently supports only `SAMPLE_RATE=48000`, matching the fixed
49.152 MHz system clock and 48 kHz audio wrapper. A small startup underrun can be
reported before the first programmed sample is available; sample drops indicate
the core produced a frame when the I2S transmitter could not accept it and should
be treated as an integration bug.

Current full-system limitations are intentional:

- The SPI master is a C++ test harness model, not RTL intended for synthesis.
- The storage side is still a C++ line-memory model, not a parallel NOR, SPI
  Flash, SDRAM, or DDR controller.
- The wrapper has one fixed 49.152 MHz clock and does not yet model board PLLs,
  clock-domain crossings, codec MCLK, or reset sequencing.
- I2S RX exists only in the C++ harness and focused testbench; the synthesizable
  audio path is transmit-only.
- Full-system runs are smoke/integration tests today. Longer high-polyphony
  stress tests and exact I2S-decoded PCM comparisons against `render-quick` are
  tracked in `docs/system_design.md`.

## C++ Memory-Profile Render Flow

`make render-memory` renders a short score through `wavetable_core_memory`, which
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
- Calculate each event's Q16.16 `phase_inc` from MIDI note, SF2 root key,
  tuning, and output sample rate.
- Convert SF2 volume envelope attack, decay, sustain, release, and sampleModes
  into per-region control values used by the C++ MCU model.
- Drive `wavetable_core_memory` through its public Verilated ports, including the
  external line-memory request/response interface.

Each `make render-memory` run writes memory subsystem counters to:

```text
build/render_memory/memory_stats.json
```

The recorded fields are `profile`, `line_words`, `random_latency_cycles`,
`sequential_latency_cycles`, `ready_gap_cycles`, `hits`, `misses`, `hit_rate`,
`external_line_requests`, `sequential_line_requests`, `responses`,
`avg_response_latency_cycles`, and `max_response_latency_cycles`. The supported
read-only timing profiles are `ddr`, `sdram`, and `parallel-nor`.

The C++ path intentionally reads standard MIDI files directly; no intermediate
event file or generated MIDI SystemVerilog include is part of the current flow.

## MIDI/SF2 Render Calculation

The C++ harnesses share the same preparation and MCU policy code in
`sim/harness/render_support.cpp`.

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
                  * 65536)
```

`root_key`, tuning, and sample rate come from the selected SF2 instrument zone and
sample header. The RTL receives only the resulting unsigned Q16.16 `PHASE_INC`.

Voice allocation is MCU-side policy:

- Prefer the first silent slot.
- If all 32 slots are active, steal the oldest allocated slot.
- Runtime envelope level is set before committing a new Note On voice so phase is
  loaded exactly once.
- Repeated Note On events for the same channel/note can occupy multiple slots;
  Note Off releases all matching active slots.

The current envelope model converts SF2 volume-envelope generators into linear
Q1.15 attack, decay, sustain, and release steps. It runs every
`adsr_tick_ms` milliseconds, defaulting to 5 ms. This is intentionally simpler
than the full SF2 envelope curve, but it exercises the hardware contract: runtime
`ENVELOPE_LEVEL` writes update active gain without commit and without reloading
phase.

The normal Note On register sequence is:

```text
ENVELOPE_LEVEL = 0
CONTROL        = enable + mono/stereo
BASE_ADDR      = selected memory word address
LENGTH         = sample frames
LOOP_START     = first loop frame
LOOP_END       = exclusive loop end
PHASE_INIT     = 0
PHASE_INC      = generated Q16.16 increment
GAIN_L/R       = selected Q1.15 channel gains
PLAYBACK_MODE  = no loop / continuous / loop-until-release
COMMIT         = 1
```

At Note Off, loop-until-release samples receive `PLAYBACK_MODE.released = 1`.
The MCU model then continues release envelope writes and eventually disables and
commits the slot when the envelope reaches zero.

`sim/harness/render_support.cpp` models the MCU at the precision used by this FPGA
project: 32 voice slots and Q1.15 runtime envelope levels. It uses SF2
volume-envelope step values, free-voice-first allocation, and oldest-voice
stealing when all slots are busy. On Note On it writes the selected slot's
wave/loop/phase/gain registers and commits. On each ADSR tick it writes
`ENVELOPE_LEVEL`. On Note Off it matches channel plus note, sets the runtime
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
- Required `pdta` chunk presence, record-size, terminal-record, and index-table
  consistency checks for `phdr`, `pbag`, `pmod`, `pgen`, `inst`, `ibag`, `imod`,
  `igen`, and `shdr`.
- MIDI program and bank-select lookup into SF2 presets.
- Preset-zone and instrument-zone selection by key range and velocity range.
- Global-zone plus local-zone merging for presets and instruments, with
  instrument-level generators treated as absolute and preset-level value
  generators treated as additive where supported.
- Mono samples and common linked-stereo samples. Linked stereo is repacked into
  the RTL memory format `left0, right0, left1, right1, ...`.
- Sample header `start`, `end`, `startLoop`, `endLoop`, `sampleRate`,
  `originalPitch`, and `pitchCorrection` fields.
- Sample-address offset generators `startAddrsOffset`, `endAddrsOffset`,
  `startloopAddrsOffset`, `endloopAddrsOffset`, and their coarse variants.
- `overridingRootKey`, `fineTune`, `coarseTune`, `scaleTuning`, and `keynum`
  generators for Q16.16 `phase_inc` calculation.
- `pan` and `initialAttenuation` generators for left/right Q1.15 gain setup.
- Volume-envelope `attackVolEnv`, `decayVolEnv`, `sustainVolEnv`, and
  `releaseVolEnv` generators, converted to software ADSR tick steps.
- `sampleModes` values for no loop, continuous loop, and loop-until-release.

Known SF2/MIDI gaps to implement later are listed below. These are gaps against
the SoundFont 2.04 specification, not necessarily blockers for RTL wavetable-core
regression testing.

SF2 file-format and sample-data gaps:

- `sm24` 24-bit sample extension is not loaded. Rendering uses only the upper
  16-bit `smpl` chunk. A correct SF2.04 renderer should combine `smpl` and
  `sm24` when the file version and chunk size permit it, and ignore `sm24` in the
  spec-defined fallback cases.
- `INFO` metadata chunks are not validated. The harness currently does not check
  `ifil`, `isng`, or `INAM`, and therefore does not distinguish SF2 versions or
  use version-specific behavior except by ignoring `sm24`.
- ROM samples are not supported. `irom` and `iver` are not parsed, and ROM sample
  types are treated as normal sample-type flags after masking. A conforming
  loader should reject or silence ROM sample use unless the referenced ROM is
  available and verified.
- Linked sample type `linkedSample = 8` is not implemented. The harness supports
  mono, left, and right sample headers plus the common left/right `sampleLink`
  pair, but not a circular linked-sample list.
- Structural validation is still partial. The loader checks required chunk
  presence, record sizes, and table index consistency, but it does not yet enforce
  every spec constraint such as `keyRange`/`velRange` legality across all bad
  placements, sample minimum loop size, sample guard points, duplicate preset
  numbering policy, or every illegal enumerator rule.

Generator gaps:

- Filter generators are parsed only as uninterpreted generator records and are
  not converted into RTL filter settings. This includes `initialFilterFc`,
  `initialFilterQ`, `modLfoToFilterFc`, and `modEnvToFilterFc`.
- LFO and modulation-envelope generators are not modeled. This includes
  `delayModLFO`, `freqModLFO`, `delayVibLFO`, `freqVibLFO`, the modulation
  envelope ADSR generators, and their pitch/filter routing amounts.
- Volume-envelope `delayVolEnv`, `holdVolEnv`, `keynumToVolEnvHold`, and
  `keynumToVolEnvDecay` are not modeled. Attack, decay, sustain, and release are
  simplified into MCU-side Q1.15 control ticks.
- Volume-envelope curves are simplified. The SF2 volume envelope is specified in
  perceptual units with convex attack and dB-like decay/release behavior; the
  harness uses linear Q1.15 level steps.
- Effects sends are ignored. `chorusEffectsSend` and `reverbEffectsSend` do not
  affect the rendered output because the RTL path has no effects processor.
- `velocity` substitution is not applied. `keynum` substitution is used for pitch,
  but velocity substitution is not currently fed into envelope level or modulator
  calculations.
- `exclusiveClass` is not implemented. New notes do not terminate other sounding
  notes in the same exclusive class, so hi-hat style mutual exclusion is absent.
- Generator precedence is implemented only for the subset consumed by the current
  harness. Unsupported value generators may be carried in the merged zone but do
  not affect audio. Unsupported preset-level sample/substitution generators are
  ignored where the loader recognizes them as illegal.

Modulator gaps:

- `pmod` and `imod` chunks are validated for presence and record size but their
  records are not parsed into runtime behavior.
- Default SF2 modulators are not implemented. Missing behavior includes MIDI
  velocity to initial attenuation, velocity to filter cutoff, channel pressure and
  modulation wheel to vibrato depth, CC7 volume, CC10 pan, CC11 expression, CC91
  reverb send, CC93 chorus send, and pitch wheel to pitch.
- Custom modulator source mapping, polarity, direction, concave/convex/switch
  curves, secondary amount sources, transforms, and linked modulators are not
  implemented.
- Modulator precedence rules between default, instrument global/local, and preset
  global/local modulators are not implemented.

MIDI and controller-policy gaps:

- Velocity is used for zone selection and Note On peak level only. The current
  peak level is a simple linear mapping, not the SF2 default velocity-to-volume
  concave attenuation curve.
- Channel 10 percussion currently falls back to bank 0 and does not implement the
  General MIDI percussion bank convention, drum-note maps, or preset-specific
  percussion policy.
- Pitch bend, sustain pedal, sostenuto, soft pedal, expression, volume, pan,
  aftertouch, modulation wheel, RPN, NRPN, All Sound Off, and All Notes Off are
  not modeled as SF2/MIDI controller behavior. Some RTL hooks exist, such as
  runtime `PHASE_INC_RUNTIME`, but the C++ MCU policy does not yet drive them as
  a complete SF2-compatible controller layer.
- Bank-select policy is minimal. CC0 and CC32 are parsed into a 14-bit bank value,
  but SF2-specific bank conventions beyond simple preset lookup are not modeled.

Stereo and region-selection gaps:

- Linked stereo is repacked as one interleaved RTL region using one selected zone's
  generators. The SF2 spec expects left/right sample headers in a stereo pair to
  play synchronously, with pitch controlled by the right sample's generators and
  non-pitch generators applied normally. Complex SoundFonts with separate left
  and right zones may therefore render differently.
- If multiple preset or instrument zones overlap the same key and velocity, the
  harness selects one region. A complete synthesizer may need to trigger multiple
  matching zones for layered sounds.
- Zone selection currently treats lack of a key/velocity match as an error for the
  selected preset or instrument. That is useful for regression visibility, but a
  production player may choose to silence only that note while continuing playback.

RTL integration gaps implied by complete SF2 support:

- A full SF2 filter path would need MCU-side coefficient calculation and verified
  mapping into the existing RTL one-pole filter, or a different RTL filter if the
  target is closer to the SF2 resonant low-pass model.
- LFOs, modulation envelope, and most real-time modulators can be implemented in
  MCU/software by periodically updating existing runtime registers only up to the
  bandwidth and resolution those registers support. Higher-rate or per-sample
  modulation would require new RTL behavior.
- Reverb and chorus require new audio processing outside the current dry stereo
  wavetable path.

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
and memory values in `tb_wavetable_core.sv`.

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
- Complete SF2 velocity curves, modulators, controller policy, envelope curves,
  and filter coefficient calculation.

Those are good future test areas as the 32-voice core moves toward board-level
integration.
