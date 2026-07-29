# Render Command Reference

Run these commands from the repository root. Quote `SF2`, `MIDI`, and output
paths when they contain spaces or non-ASCII characters. Give comparison renders
different output directories because each render writes `out.wav` and
`reference_render_config.json` into its selected directory.

## C++ Reference Render

Render the built-in short melody with the default SoundFont:

```bash
make render-reference SECONDS=2
```

Render a complete MIDI file with an explicit SoundFont and 1 ms MCU control
updates:

```bash
make render-reference \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  START_SECONDS=0 \
  SECONDS=300 \
  CONTROL_TICK_MS=1 \
  RENDER_REFERENCE_OUT_DIR=build/song_reference
```

Render only a time window. Events before the window are used to reconstruct
controller state, but notes that started before the window are not reconstructed:

```bash
make render-reference \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  START_SECONDS=120 \
  SECONDS=30 \
  CONTROL_TICK_MS=1 \
  RENDER_REFERENCE_OUT_DIR=build/song_120s_150s
```

## Compressor Render

The `render-reference` Make target defaults to a transparent protection mode:
-2 dBFS threshold, 4:1 ratio, immediate attack, and a 5000 ms full-range
release setting. The following command uses those defaults:

```bash
make render-reference \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  START_SECONDS=0 \
  SECONDS=300 \
  CONTROL_TICK_MS=1 \
  RENDER_REFERENCE_OUT_DIR=build/song_protection_compressor
```

Render an uncompressed control using the same input and time window:

```bash
make render-reference \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  START_SECONDS=0 \
  SECONDS=300 \
  CONTROL_TICK_MS=1 \
  COMPRESSOR_ENABLE=0 \
  RENDER_REFERENCE_OUT_DIR=build/song_uncompressed
```

The compressor-related Make variables are:

| Variable | Meaning | Default |
| --- | --- | ---: |
| `COMPRESSOR_ENABLE` | Enable the C++ fixed-point lookahead compressor | `1` |
| `COMPRESSOR_THRESHOLD_CB` | Positive centibels below full scale; `20` means -2 dBFS | `20` |
| `COMPRESSOR_RATIO` | Compression ratio; `4` means 4:1 | `4` |
| `COMPRESSOR_ATTACK_MS` | Milliseconds to traverse the full 100 dB control range | `0` |
| `COMPRESSOR_RELEASE_MS` | Milliseconds to traverse the full 100 dB control range | `5000` |
| `MASTER_VOLUME` | Linear post-compressor gain in the range `0..1`; `1` is unity | `1` |

The C++ model uses the same 48-frame lookahead length, fixed-point LUTs,
configuration command payload, and gain arithmetic as RTL. Increasing
`MASTER_VOLUME` above one is rejected because the hardware Q1.15 field is an
attenuator with unity as its maximum. The attack and release controls become a
fixed centibel step per frame; consequently a transition smaller than 100 dB
finishes proportionally sooner than the specified full-range time.

At 48 kHz the compressor contributes a fixed 48-frame (1 ms) sample delay. The
common hardware output FIFO retains its separate default 48-frame lead, making
the default integrated RTL sample-domain latency 96 frames (2 ms). The C++ WAV
render flushes the lookahead and still writes exactly the requested number of
output frames; it does not model the final I2S FIFO lead.

## Chorus And Reverb Listening Render

The C++ reference render can place the bit-exact global chorus, FDN reverb, and
return mixer before the compressor. Effects default to `off`, which preserves
the existing dry render path. The initial listening presets are:

| Preset | Intended use | Chorus | Reverb RT60 |
| --- | --- | --- | ---: |
| `chorus` | classic musical thickening and stereo width | light | off |
| `studio` | restrained room and stereo width | very light | 1.0 s |
| `hall` | clear concert-hall space without chorus coloration | off | 4.5 s |
| `chorus-max` | chorus identification/stress check | maximum | off |
| `reverb-max` | maximum wet-level stress/listening check | off | 8.0 s |

All presets use the generated RTL delay lengths and command-field limits.
They currently require a 48 kHz render because the hardware delay contract is
defined at that rate. Render a full song plus five seconds of effect tail with:

```bash
make render-reference \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  SECONDS=300 \
  CONTROL_TICK_MS=1 \
  EFFECTS_PRESET=hall \
  CHORUS_ENABLE=auto \
  REVERB_ENABLE=auto \
  EFFECTS_TAIL_SECONDS=5 \
  RENDER_REFERENCE_OUT_DIR=build/song_hall
```

`EFFECTS_TAIL_SECONDS` adds output frames only when chorus or reverb remains
enabled after applying the explicit overrides. During that interval the
synthesizer and effects continue advancing,
so note releases and the spatial tail are both retained. The summary JSON
records the selected preset, tail length, effect validity, configuration-clamp
state, and saturation counters.

`CHORUS_ENABLE` and `REVERB_ENABLE` accept `auto`, `on`, or `off`. The default
`auto` follows the selected preset. An explicit `off` disables that processor;
for example, `EFFECTS_PRESET=studio CHORUS_ENABLE=off` renders only the short
room reverb. Explicit `on` verifies that the selected preset already contains
parameters for that processor and is rejected otherwise. This prevents an
`off` or chorus-only preset from silently enabling an all-zero reverb setup.

`reverb-max` sets the global reverb send and return to the maximum Q1.15 value
and disables chorus so the reverb is easy to judge. Its feedback coefficients
target an 8-second RT60 but remain below the non-decaying stability boundary.
`chorus-max` disables reverb and sets chorus send/return to maximum. Its two
quarter-cycle-offset stereo taps sweep approximately 10 through 26 ms at
0.8 Hz with 0.4 feedback. It is intentionally stronger than a normal musical
preset so modulation, thickening, and stereo widening are easy to identify.

The musical `chorus` preset follows the classic low-feedback, low-depth region:
8 ms center delay, 1.5 ms depth, 0.6 Hz rate, 0.04 feedback, and 0.28 return.
`studio` uses still less chorus plus a short, damped 1-second room tail. `hall`
disables chorus to avoid moving comb coloration and uses a 4.5-second FDN tail,
35 ms pre-delay, and a clearly audible but sub-maximum wet return.

The preset categories and starting ranges are based on vendor algorithm
documentation, while the exact fixed-point values above are project listening
choices. JUCE describes chorus as a modulated delay that creates moving notches
and identifies approximately 7--8 ms center delay with low depth and feedback
as a classic chorus region; it also notes that shorter delay plus substantial
feedback approaches flanging. Roland documents chorus pre-delay through 40 ms
and describes longer values as a doubling effect. Roland's reverb controls
separate room/hall/plate type, decay time, pre-delay, density, and damping, which
is why `hall` uses pre-delay and decay rather than chorus to create width.
The complete mathematical mapping, exact preset table, and unsupported-control
list are recorded in
[`../design/effects_parameter_mapping.md`](../design/effects_parameter_mapping.md).

Primary references:

- [JUCE Chorus class](https://docs.juce.com/master/classjuce_1_1dsp_1_1Chorus.html)
- [Roland GX-100 Prime Chorus parameters](https://static.roland.com/manuals/gx-100_parameter/eng/25630354.html)
- [Roland GX-100 Reverb parameters](https://static.roland.com/manuals/gx-100_parameter/eng/25630401.html)
- [Roland SH-4d Reverb parameters](https://static.roland.com/manuals/sh-4d/eng/66978025.html)

## Diagnostics

Compressor diagnostics are collected whenever the compressor path is enabled.
`DETAILED_DIAGNOSTICS=1` separately enables the more expensive per-voice synth
diagnostics:

```bash
make render-reference \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  SECONDS=30 \
  CONTROL_TICK_MS=1 \
  COMPRESSOR_ENABLE=1 \
  DETAILED_DIAGNOSTICS=1 \
  RENDER_REFERENCE_OUT_DIR=build/song_detailed_diagnostics
```

Extract the main compressor fields from a completed render:

```bash
jq '{
  compressor_enable,
  diagnostics_compressor_max_detector_peak,
  diagnostics_compressor_max_gain_reduction_cb_q12_20,
  diagnostics_compressor_input_frame_count,
  diagnostics_compressor_output_frame_count,
  diagnostics_compressor_compressed_frame_count,
  diagnostics_compressor_saturation_count
}' build/song_protection_compressor/reference_render_config.json
```

Compare WAV mean and peak levels with FFmpeg:

```bash
ffmpeg -hide_banner -nostats \
  -i build/song_protection_compressor/out.wav \
  -af volumedetect -f null -

ffmpeg -hide_banner -nostats \
  -i build/song_uncompressed/out.wav \
  -af volumedetect -f null -
```

## Control Update Modes

Use periodic 1 ms MCU-side modulation and control updates for the normal
realistic render:

```bash
make render-reference SECONDS=10 CONTROL_TICK_MS=1
```

Use sample-accurate updates when isolating control-rate artifacts. This ignores
`CONTROL_TICK_MS` and costs more PC simulation time:

```bash
make render-reference SECONDS=10 SAMPLE_ACCURATE_CONTROL=1
```

## RTL DDR3 Render

Render the current voice-major RTL with its 32-word sample window and timed DDR3
model:

```bash
make render-rtl-ddr3 \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  SECONDS=10 \
  CONTROL_TICK_MS=1 \
  RENDER_RTL_OUT_DIR=build/song_rtl_ddr3
```

Inspect the integrated report with:

```bash
jq '{render_target, output_samples, region_count:(.regions | length),
     rtl_core_cycles, rtl_render_blocks, rtl_render_frames,
     rtl_window_words, rtl_window_refills, ddr_reads,
     timing_render_ms}' \
  build/song_rtl_ddr3/rtl_ddr3_render_config.json
```

This target uses the shared `render_session` input preparation and
`render_report` schema, then appends RTL, sample-window, DDR3, deadline, and
render-timing statistics. Superseded direct-core, cached-memory, and board-loader
renderer sources are retained under `sim/legacy` without current Make targets.

### 512-Voice DDR3 Stress

The deterministic stress generator starts 320 simultaneous MIDI notes across
all channels and then changes notes and programs every 25 ms. Stereo SF2 regions
expand MIDI notes into separate mono voices, allowing the workload to fill the
512-voice allocator while producing nonlocal DDR accesses.

```bash
g++ -std=c++17 -Wall -Wextra -Werror \
  tools/generate_polyphony_stress_midi.cpp \
  -o build/generate_polyphony_stress_midi
build/generate_polyphony_stress_midi build/polyphony_stress_512.mid

make render-rtl-ddr3 \
  SF2='/path/to/SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2' \
  MIDI=build/polyphony_stress_512.mid \
  SECONDS=3 CONTROL_TICK_MS=1 DETAILED_DIAGNOSTICS=0 \
  RENDER_RTL_OUT_DIR=build/polyphony_stress_rtl_ddr3
```

Keep detailed diagnostics disabled for this workload. The summary JSON already
contains peak active voices, maximum render latency, deadline misses, sample-
window traffic, and DDR row statistics; per-event diagnostics make the
cycle-accurate run unnecessarily slow.

The 2026-07-29 run used the 310 MB
`SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2`, 512 voices, eight work slots, and the
timed DDR3 model. It completed all 144,000 output frames with these results:

| Metric | Result |
| --- | ---: |
| Peak active mono voices | 512 |
| Maximum render cycles per 8-frame block | 9,217 |
| Maximum deadline utilization | 55.302% |
| Deadline misses | 0 |
| Window refills / fallback reads | 1,814,897 / 2,188,664 |
| DDR reads | 9,448,252 |
| DDR row hits / misses | 5,775,172 / 3,673,080 |
| Stale parameter updates | 0 |

The high fallback and row-miss counts are intentional consequences of random
program/note churn. Passing this test demonstrates useful latency margin under
that trace; it does not replace longer musical renders or board-level MIG and
audio-underrun qualification.

## Output Files

`render-reference` produces:

- `out.wav`: signed PCM16 stereo output at the selected sample rate.
- `reference_render_config.json`: inputs, timing, output counts, synthesizer
  diagnostics, and compressor diagnostics.

`render-rtl-ddr3` produces `out.wav` and `rtl_ddr3_render_config.json`, including
shared session diagnostics plus RTL/window/DDR3 timing statistics.

Generated render output belongs under `build/` and must not be committed.
