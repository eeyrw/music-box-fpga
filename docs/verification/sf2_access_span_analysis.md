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

## MT6276 And SGM Comparison

The following 2026-07-31 study used the same deterministic 10-second
`build/polyphony_stress_512.mid` workload, 48 kHz output rate, line sizes of
8/16/32/64 words, and lookahead windows of 1/2/5/10 ms. The SGM baseline was
the existing report for `SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2`; MT6276 was
analyzed with:

```bash
python3 tools/analyze_sf2_access_span.py \
  --sf2 assets/soundfonts/MT6276.sf2 \
  --midi build/polyphony_stress_512.mid \
  --json-out build/polyphony_stress_mt6276_sf2_access_span.json \
  --md-out build/polyphony_stress_mt6276_sf2_access_span.md
```

Generated reports remain under `build/` and are not source-controlled.

### Mapping And Working Set

| Metric | SGM | MT6276 | MT6276 change |
| --- | ---: | ---: | ---: |
| SF2 file bytes | 324,800,670 | 1,525,780 | 99.53% smaller |
| Note On events | 3,512 | 3,512 | same workload |
| Sample streams | 5,228 | 3,611 | -30.93% |
| Unique samples | 929 | 56 | -93.97% |
| Maximum active streams/frame | 478 | 350 | -26.78% |
| Unmapped note regions | 159 | 0 | all MT6276 notes mapped |
| Looping streams | 4,284 | 3,524 | -17.74% |
| Unique loop regions | 779 | 52 | -93.32% |
| Maximum loop span, words | 226,342 | 62,076 | -72.57% |

MT6276 maps nearly every Note On to one mono stream. SGM produces more streams
despite its unmapped regions because its preset mapping contains substantially
more stereo and layered regions. MT6276 therefore presents a much smaller and
more repetitive absolute sample working set; it is not a substitute for SGM
when testing broad sample coverage or layered/stereo pressure.

At the 32-word analysis granularity, the traffic comparison was:

| Metric | SGM | MT6276 | MT6276 change |
| --- | ---: | ---: | ---: |
| Endpoint reads/s | 32,186,819.6 | 24,035,170.2 | -25.33% |
| Stream line fills/s | 198,000.3 | 28,535.2 | -85.59% |
| Physical unique lines/s | 94,662.5 | 1,273.9 | -98.65% |
| New stream lines/frame P99 / max | 15 / 488 | 4 / 342 | lower |
| New physical lines/frame P99 / max | 7 / 158 | 1 / 30 | lower |

The same trend holds at 8, 16, and 64 words: MT6276 stream-line fills are about
85.4% to 85.7% lower, while physical first touches are about 98.65% lower. These
figures describe static locality, not actual RTL cache misses.

### Phase-Step Tradeoff

MT6276 has the smaller working set but the more aggressive source-address
advance:

| Source frames/output frame | SGM | MT6276 |
| --- | ---: | ---: |
| Average | 0.8164 | 1.2403 |
| P50 | 0.7734 | 0.5156 |
| P95 | 1.9297 | 5.1953 |
| P99 | 3.4688 | 8.4648 |
| Maximum | 13.0977 | 14.6992 |
| Streams at or above 4 | 0.38% | 7.95% |
| Streams at or above 8 | 0.06% | 1.14% |

The fraction at or above four source samples per output frame is 20.8 times
the SGM fraction. MT6276's largest steps come from broadly transposed samples
such as `appls60`, `sybs36`, `gunshot60`, and `flute60`. Consequently, MT6276
is useful for large-phase-step and short-loop tests even though it is easier on
total working-set capacity.

### Effect On The Production 32-Word Window

The production renderer processes at most 16 output frames per work item and
uses linear-interpolation endpoints `sample[n]` and `sample[n+1]`. For a static
phase step `D`, the approximate inclusive source span of a full work item is:

```text
15 * D + 2 words
```

This is a sizing heuristic, not an exact hit test: integer phase truncation,
loop wrapping, inactive frame masks, and the first request's offset within its
aligned 8-word line change the exact span. It nevertheless explains the
geometry:

| Phase step `D` | Approximate 16-frame span | 32-word implication |
| ---: | ---: | --- |
| 0.5 | 10 words | comfortably resident |
| 1.0 | 17 words | normally resident |
| 2.0 | 32 words | alignment-sensitive boundary |
| 5.2 | 80 words | requires out-of-window lines |
| 8.46 | 129 words | crosses several lines/windows |

Thus a larger phase step normally reduces window hits. SGM's P95 step is near
the range a 32-word window can cover for a complete 16-frame work item, whereas
MT6276's P95 cannot fit.

`voice_sample_window` limits the cost of this case. The first descriptor of a
work item may refill the persistent window with four adjacent 8-word reads. A
later descriptor outside that window performs one 8-word fallback read without
replacing the persistent window. This prevents an interpolation endpoint just
past the boundary from evicting the useful window, but sustained large steps
still increase fallback traffic.

Do not infer the production window hit rate from `physical_unique_lines` or
from a `LINE_WORDS=32` analyzer run:

- the production storage is private per voice, so different voices cannot hit
  one another's windows even when they reference the same absolute sample;
- the analyzer counts first touches and does not model persistent-window
  replacement, four-line refills, or one-line fallback transactions;
- the real external transfer unit remains eight words, while 32 words is the
  per-voice capacity.

Compare timed RTL counters before changing the window geometry:

```text
window_client_requests - window_hits = window_refills + fallback_reads
window_memory_reads = 4 * window_refills + fallback_reads
```

In particular, `fallback_reads / client_requests` isolates the workload effect
of endpoints escaping the resident window. A 64-word window may cover more of
the MT6276 high-step tail, but it doubles per-voice sample storage. Any such
change requires a timed DDR3 A/B comparison and fresh post-route BRAM and timing
results; the static analysis alone is insufficient.
