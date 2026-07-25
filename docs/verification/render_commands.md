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

The compressor is disabled by default. A useful starting point for music is a
-12 dBFS threshold, 4:1 ratio, immediate attack, and a 100 ms full-range
release setting:

```bash
make render-reference \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  START_SECONDS=0 \
  SECONDS=300 \
  CONTROL_TICK_MS=1 \
  COMPRESSOR_ENABLE=1 \
  COMPRESSOR_THRESHOLD_CB=120 \
  COMPRESSOR_RATIO=4 \
  COMPRESSOR_ATTACK_MS=0 \
  COMPRESSOR_RELEASE_MS=100 \
  MASTER_VOLUME=1 \
  RENDER_REFERENCE_OUT_DIR=build/song_compressor_12db_4to1
```

Render an uncompressed control using the same input and time window:

```bash
make render-reference \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  START_SECONDS=0 \
  SECONDS=300 \
  CONTROL_TICK_MS=1 \
  RENDER_REFERENCE_OUT_DIR=build/song_uncompressed
```

The compressor-related Make variables are:

| Variable | Meaning | Default |
| --- | --- | ---: |
| `COMPRESSOR_ENABLE` | Enable the C++ fixed-point lookahead compressor | `0` |
| `COMPRESSOR_THRESHOLD_CB` | Positive centibels below full scale; `120` means -12 dBFS | `120` |
| `COMPRESSOR_RATIO` | Compression ratio; `4` means 4:1 | `4` |
| `COMPRESSOR_ATTACK_MS` | Milliseconds to traverse the full 100 dB control range | `0` |
| `COMPRESSOR_RELEASE_MS` | Milliseconds to traverse the full 100 dB control range | `100` |
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
}' build/song_compressor_12db_4to1/reference_render_config.json
```

Compare WAV mean and peak levels with FFmpeg:

```bash
ffmpeg -hide_banner -nostats \
  -i build/song_compressor_12db_4to1/out.wav \
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

## RTL And Memory Renders

Compare the integer reference against the direct RTL renderer sample by sample:

```bash
make render-rtl-core \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  SECONDS=10 \
  CONTROL_TICK_MS=1 \
  RENDER_RTL_CORE_OUT_DIR=build/song_rtl_core
```

Exercise the cached RTL memory path with a timing profile:

```bash
make render-memory \
  SF2='/path/to/soundfont.sf2' \
  MIDI='/path/to/song.mid' \
  SECONDS=10 \
  MEMORY_PROFILE=ddr \
  RENDER_MEMORY_OUT_DIR=build/song_memory_ddr
```

Other supported memory profiles include `sdram`. The board-loader flow is:

```bash
make render-board-loader SECONDS=0.1
```

The compressor command-line switches currently belong to `render-reference`.
RTL compressor behavior is covered by the self-checking RTL tests and is
configured through the global command stream in integrated hardware flows.

## Output Files

`render-reference` produces:

- `out.wav`: signed PCM16 stereo output at the selected sample rate.
- `reference_render_config.json`: inputs, timing, output counts, synthesizer
  diagnostics, and compressor diagnostics.

Generated render output belongs under `build/` and must not be committed.
