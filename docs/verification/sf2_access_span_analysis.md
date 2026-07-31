# SF2 Access Span Analysis

`tools/analyze_sf2_access_span.py` models the sample-address workload produced
by mapping MIDI notes through SoundFont preset, instrument, and sample regions.
It does not render PCM. Use it to compare sample-line sizes, inspect static
phase increments, identify large loop wraps, and estimate address locality
before running the timed RTL DDR3 harness.

## Quick Start

Analyze the notes and controller workload present in a MIDI file:

```bash
python3 tools/analyze_sf2_access_span.py \
  --sf2 '/path/to/soundfont.sf2' \
  --midi build/polyphony_stress_512.mid \
  --line-words 8,16,32,64 \
  --lookahead-ms 1,2,5,10 \
  --json-out build/polyphony_stress_sf2_access_span.json \
  --md-out build/polyphony_stress_sf2_access_span.md
```

Analyze one synthetic note without MIDI:

```bash
python3 tools/analyze_sf2_access_span.py \
  --sf2 assets/soundfonts/MT6276.sf2 \
  --program 0 --bank 0 --key 60 --velocity 100 \
  --seconds 2
```

Generated reports belong under `build/`. JSON contains the complete structured
summary; Markdown is the review-oriented report and includes the main phase,
loop, line-size, lookahead, and high-pressure sample tables.

## Analysis Flow

The tool performs these steps:

1. Parse format 0 or format 1 PPQ MIDI and merge channel program/bank state
   across tracks.
2. Pair Note On and Note Off events into stream lifetimes.
3. Resolve each note through matching SF2 preset and instrument zones.
4. Derive the selected sample window, loop mode, and static Q24.8 phase
   increment from key, tuning generators, root key, and sample rate.
5. Walk each sample stream through the requested line sizes and collect address
   locality statistics.
6. Emit the same structured conclusions to terminal, JSON, and Markdown.

Stereo SF2 regions become separate mono sample streams, matching the renderer's
voice allocation model.

## Phase And Loop Metrics

`source_frames_per_output` is `phase_inc / 256`. A value below one advances by
less than one source sample per output frame; a value above one skips source
samples. The workload summary reports min, average, P50, P95, P99, max, counts
at or above 1/2/4/8 samples, and the exact streams with the largest steps.

Loop wrap is a different kind of address movement. At `loop_end`, playback
jumps backward to `loop_start`; `loop_span_words` and `loop_span_bytes` report
that potential discontinuity. The line-size results also report observed
frame-to-frame line jumps, both in lines and converted back to sample words.

## Line Metrics

Line sizes are expressed in 16-bit sample words:

- `endpoint_reads` counts the two interpolation endpoints for every active
  stream and output frame.
- `stream_line_fills` counts the first touch of a line by each stream.
- `physical_unique_lines` counts the first touch of each absolute SF2 line
  address across the analysis.
- `new_stream_lines_per_frame` and `new_physical_lines_per_frame` show burst
  pressure at output-frame granularity.
- lookahead tables group first touches into non-overlapping windows of the
  requested duration.
- line dwell estimates how many output frames a phase increment normally stays
  within one line.

These are locality and compulsory-touch metrics, not cache misses. They do not
model capacity, set conflicts, eviction, replacement, DDR row policy, or
arbitration. Use the timed RTL DDR3 render for those effects.

## Model Scope

The report records relevant MIDI controller counts and prints these limitations
in every generated Markdown report:

- stream lifetime currently follows Note On/Off pairing; sustain-pedal lifetime
  and allocator voice stealing are not modeled;
- phase increment is static at note start; RPN pitch-bend range, pitch-bend
  events, and runtime pitch updates are not applied;
- finite cache behavior and DDR timing are not modeled.

Consequently, a controller-heavy stress MIDI is useful for its note-to-sample
mapping and base locality, but its result is not a worst-case runtime pitch or
memory signoff result.

## Performance

Each requested line size is independent. By default, `--jobs 0` runs one worker
per line size, bounded by available CPUs and the number of requested sizes.
Use `--jobs 1` when memory is constrained or when collecting a single-process
profile. Progress is written to stderr as each line size finishes, and JSON and
Markdown record the worker count and total elapsed time.

For quick exploration, reduce work explicitly:

```bash
python3 tools/analyze_sf2_access_span.py \
  --sf2 '/path/to/soundfont.sf2' \
  --midi build/polyphony_stress_512.mid \
  --seconds 1 --line-words 32 --lookahead-ms 1 --jobs 1
```

`--top-streams` controls how many phase-step streams, loop regions, samples,
and line-pressure streams are retained in JSON and Markdown. It does not change
the aggregate calculations.

## Stress Workflow

Generate the deterministic workload and both reports with:

```bash
make analyze-polyphony-stress \
  SF2='/path/to/SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2'
```

The equivalent direct commands are:

```bash
make polyphony-stress-midi

python3 tools/analyze_sf2_access_span.py \
  --sf2 '/path/to/SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2' \
  --midi build/polyphony_stress_512.mid \
  --json-out build/polyphony_stress_sf2_access_span.json \
  --md-out build/polyphony_stress_sf2_access_span.md
```

Follow this with the timed `make render-rtl-ddr3` stress command in
[`render_commands.md`](render_commands.md) when cache, DDR, allocator, runtime
pitch, or deadline behavior matters.
