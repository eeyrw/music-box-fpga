# Throughput Voice Pipeline Plan

This note records a future architecture direction for turning the current
latency-splitting voice renderer into a throughput pipeline. It is not the
current RTL behavior.

## Current Baseline

`multi_voice_pipeline` now splits interpolation, biquad filter math, gain, and
accumulation across registered states. This improves timing because one active
voice no longer performs the full filtered DSP chain in one cycle.

The current renderer is still not an overlapped throughput pipeline. One active
voice owns the state machine from endpoint fetch through `ACCUMULATE`; only then
does the scheduler advance to the next voice. The current design therefore trades
extra per-voice latency for shorter combinational paths, but it does not retire
one voice contribution per cycle.

## Target Shape

A throughput pipeline should allow different voices to occupy different compute
stages at the same time:

```text
cycle N:     voice 0 FILTER_MUL_X
cycle N+1:   voice 0 FILTER_Y      + voice 1 FILTER_MUL_X
cycle N+2:   voice 0 FILTER_MUL_Y  + voice 1 FILTER_Y      + voice 2 FILTER_MUL_X
```

The useful target is one retired voice contribution per cycle after fill, subject
to memory and register-bank read availability. The final sample still becomes
valid only after all active voices for that output frame retire into the mix
accumulator.

## Required Design Changes

### Per-Stage Context

Every pipeline stage must carry the voice context it needs. The current RTL has
many single global registers such as `voice_index`, `current_gain_l/r`,
`current_filter_*`, `interp_stage_l/r`, and `filter_next_*`. In a throughput
pipeline, those values must become fields in per-stage registers:

```text
stage.valid
stage.frame_id
stage.voice_index
stage.last_issued_voice
stage.stereo
stage.gain_l/r
stage.envelope_level
stage.filter_enable
stage.filter_coefficients
stage.filter_state_snapshot
stage.sample_l/r
stage.phase or frame/fraction snapshot
```

Without this context, voice N's filter, gain, or writeback data can be overwritten
by voice N+1 before voice N retires.

### Scheduler and DSP Separation

The current module combines voice scanning, register-bank reads, memory fetch,
interpolation, filter math, gain/envelope scaling, accumulation, phase update,
and filter-state writeback. A throughput implementation should separate these
responsibilities:

```text
voice issue scheduler
  -> memory fetch / endpoint assembly
  -> fixed-latency voice_dsp_pipeline
  -> retirement, filter-state writeback, accumulator update
```

This split keeps the DSP pipeline fixed-latency and makes stalls explicit at the
issue or memory boundary instead of spreading them through the compute stages.

### Memory Request Context

The current memory interface is one request at a time and has no response tag.
That limits throughput because endpoint fetches cannot be freely overlapped with
DSP execution. A practical throughput renderer needs at least an internal context
FIFO for in-order memory responses:

```text
voice_index
frame_id
channel
endpoint_index
frame_0/frame_1/fraction
captured runtime/config fields
```

If the memory subsystem later supports multiple outstanding reads, the external
memory response should also carry a tag:

```text
mem_req_tag
mem_rsp_tag
```

Adding tags affects `wave_memory_subsystem`, simulation models, testbenches, and
the memory-format documentation.

### Accumulator Retirement

The final mix should still saturate only once, after all voice contributions for
the frame have been added. A throughput retire stage can keep the existing signed
32-bit stereo accumulator if contributions retire in issue order. Each retired
result should carry `frame_id` and a `last_voice` or `last_issued_voice` marker:

```text
if result.valid:
  accum_l += result.sample_l
  accum_r += result.sample_r
  if result.last_voice:
    sample_l/r <= saturate_pcm(accum_l/r)
    sample_valid <= 1
```

If future work overlaps multiple output frames, accumulators must be banked by
`frame_id` or protected by a frame scoreboard.

### Phase and Filter-State Hazards

For the current one-frame-at-a-time renderer, phase can still update at issue
time because each voice is issued at most once per output frame. The frame and
fraction used for memory fetch must be carried in the issued context.

Filter state is different because the next state is produced at retirement. The
scheduler must not reissue the same voice before its prior filter-state writeback
has completed. In a one-frame-at-a-time design this is naturally true if the next
frame waits for the pipeline to drain. If frames are overlapped later, add a
per-voice busy scoreboard:

```text
filter_state_busy[voice]
```

### Register-Bank Port Pressure

Issuing one voice per cycle requires the register bank to provide one render
context per cycle. The current render read path can do that only if it has a
stable synchronous read schedule and if writeback/readback activity does not
steal the same port. Runtime state that is both software-readable and renderer-
readable may require one of these approaches:

- independent render/readback ports,
- replicated narrow state RAMs,
- arbitration that can insert issue bubbles,
- or moving more live state into the throughput pipeline context at issue time.

### Fixed-Latency DSP Unit

The DSP portion should become a module with explicit valid propagation:

```systemverilog
voice_dsp_pipeline dsp (
  .clk,
  .rst,
  .valid_i,
  .context_i,
  .valid_o,
  .result_o
);
```

The first version can be valid-only with no backpressure after issue. If a later
stage needs `ready`, every pipeline register must support holding context and
data without duplicating retire events.

## Suggested Implementation Phases

1. Extract a fixed-latency `voice_dsp_pipeline` from the existing compute states.
   Keep the current one-voice-at-a-time scheduler. This validates context packing
   and preserves behavior with limited risk.

2. Add per-stage valid/context propagation inside `voice_dsp_pipeline`. The module
   should accept a new voice every cycle in isolation tests, even if the top-level
   scheduler still feeds it sparsely.

3. Add an issue queue after register-bank reads and memory endpoint assembly.
   Keep memory responses in order at first; allow DSP stages to overlap once a
   complete endpoint pair is ready.

4. Retire one contribution per cycle into the accumulator and filter-state
   writeback path. Add ordering assertions so `sample_valid` fires only after the
   last issued voice for the frame retires.

5. Only after the in-order design is stable, consider memory request tags and
   multiple outstanding reads. This is the point where throughput gains can extend
   beyond the DSP block and into the memory subsystem.

## Verification Requirements

The existing exact-output tests remain necessary but are not sufficient. Add
focused tests for:

- consecutive active voices occupying adjacent pipeline cycles,
- disabled voices creating bubbles without corrupting following voice context,
- mono and stereo voices interleaved in one frame,
- filter-state writeback to the correct voice,
- phase update and loop wrapping with overlapped DSP execution,
- memory response stalls before a context enters DSP,
- accumulator ordering and one final saturation per output frame,
- `sample_valid` only after the last issued contribution retires,
- reset while the pipeline contains valid contexts.

Use exact integer expected results. Do not rely on waveform inspection as the
pass criterion.

## Open Tradeoffs

- A throughput DSP pipeline increases FF use because each stage carries full voice
  context.
- Memory bandwidth and endpoint fetch latency may dominate after DSP overlap is
  added; a tagged or per-voice cache-aware memory path may be required for real
  benefit.
- Overlapping output frames complicates filter-state hazards and accumulator
  ownership. The first implementation should drain one frame before starting the
  next.
- Sharing one filter unit across left/right channels reduces DSP use but lowers
  maximum throughput. Keeping left/right parallel preserves the current audio
  math shape at higher DSP cost.
