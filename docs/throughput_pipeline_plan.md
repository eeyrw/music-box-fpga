# Throughput Voice Pipeline Plan

This note records the throughput-pipeline architecture direction and the current
implementation status. The RTL now has a fixed-latency DSP throughput pipe,
single-frame issue/retire overlap, and sequential active-slot scanning. The
memory endpoint fetch path is still single-request and remains the main limiter
before the renderer becomes a fuller throughput engine.

## Current Baseline

`multi_voice_pipeline` now forms complete voice contexts through an in-order word
request and endpoint assembly path, then feeds them into `voice_dsp_pipeline`, a
fixed-latency valid-shift DSP pipe. The renderer keeps the generic one-word memory
contract, but internally separates request issue from response assembly: a fetch
slot captures the immutable voice context, `L0`, `L1`, `R0`, and `R1` word reads
are queued in order, response metadata fills the matching RAM-backed endpoint
fields, and the completed context enters a small DSP context queue. The front end
can continue scanning and enqueueing later voices while previous voice endpoints
are still waiting on memory and while earlier contexts move through DSP and
retire into the mix accumulator. This is a real single-frame throughput pipeline,
but it does not overlap multiple output frames.

The current implementation is therefore not a full CPU-style global N-stage
pipeline. Only the extracted DSP math is a fixed-stage pipe. The surrounding
renderer is still a variable-latency state machine, but memory endpoint requests
and responses are now buffered explicitly. The single-entry prefetch removes some
register-read bubbles between adjacent valid voices, and the word-request FIFO
lets endpoint reads for later voices proceed without waiting for each earlier
endpoint response to return.

Current structure:

```text
one output frame in flight

sample_tick
  |
  v
+--------------------------+
| variable-latency front   |
| end FSM                  |
|                          |
| - scan active slots      |
| - sync register read     |
| - phase/frame update     |
| - next-valid prefetch    |
| - word-request FIFO      |
| - in-order endpoint     |
|   response assembly      |
+--------------------------+
  |
  | complete voice_dsp_context_t
  v
+--------------------------+
| fixed-latency DSP pipe   |
|                          |
| S0 interpolate           |
| S1 filter products       |
| S2 filter output         |
| S3 filter state          |
| S4 gain/envelope         |
+--------------------------+
  |
  | voice_dsp_result_t
  v
+--------------------------+
| retire/drain             |
|                          |
| - accumulator update     |
| - filter-state writeback |
| - wait outstanding == 0  |
| - final PCM saturation   |
+--------------------------+
  |
  v
sample_valid
```

The DSP pipe has initiation interval 1 when complete contexts are available:

```text
cycle N:     V0 S0
cycle N+1:   V0 S1 + V1 S0
cycle N+2:   V0 S2 + V1 S1 + V2 S0
cycle N+3:   V0 S3 + V1 S2 + V2 S1 + V3 S0
cycle N+4:   V0 S4 + V1 S3 + V2 S2 + V3 S1 + V4 S0
```

The whole renderer does not currently sustain that pattern because endpoint
assembly normally takes multiple cycles per voice:

```text
front end:  L0 rsp + L1 req  L1 rsp  issue V0/start prefetched V1  fetch V1 ...
prefetch:   scan/read V1 while V0 endpoints are being fetched
DSP pipe:                       V0 S0  V0 S1  V0 S2  V0 S3  V0 S4
retire:                                                       V0 result
```

The intended next architectural step is to make more of the front end look like a
pipeline by adding explicit fetch/context queues, not by changing the DSP math
again first.

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

The first target should be more conservative than a fully streaming audio engine:

- one output frame in flight at a time,
- in-order voice retirement,
- no repeated issue of the same voice before its filter state writes back,
- no overlap between the retire phase of frame N and issue phase of frame N+1,
- exact integer output equivalence with the current renderer.

This preserves the existing external `sample_tick`/`sample_valid` contract while
allowing the internal DSP section to accept a new ready voice every cycle once
endpoint samples are available.

Implementation note: the first extraction step now exists as
`rtl/dsp/voice_dsp_pipeline.sv`. It keeps the top-level
`multi_voice_pipeline` external interface and preserves the existing memory
request ordering, but the interpolation, filter, gain, envelope, and DSP result
record are isolated behind an explicit `valid_i`/`valid_o` boundary. The DSP
block is now a fixed-latency valid-shift pipeline, so it can accept a new complete
voice context every cycle if the front end can provide one.

`multi_voice_pipeline` also now separates issue from retire for one output frame:
after a complete endpoint set is issued into `voice_dsp_pipeline`, the scheduler
continues scanning and fetching later voices while earlier DSP results retire into
the accumulator and filter-state arrays. The scheduler also overlaps the next
valid voice's register read with the current voice's endpoint fetch, and it can
launch the next endpoint request in the same cycle that it consumes the prior
endpoint response. This overlaps DSP latency, register-read latency, and part of
the request/response state overhead, but it is still bounded by the single
outstanding memory request interface. The next larger gain still requires Option B
style endpoint assembly/queueing or a memory path that can return interpolation
endpoints faster.

The scheduler uses `config_valid` as an active-slot mask while it walks voice
slots in index order. Empty voice slots cost one scan cycle but do not pay the
synchronous register-read and process-state overhead. This area-oriented choice
removes the earlier wide next-active priority encoder and mux. Disabled
configured voices still require a context read because `enable` lives in the
committed voice configuration.

## Expected Bottlenecks

The current DSP throughput pipeline can accept and retire one voice contribution
per cycle after fill, but frame latency only improves when the front end supplies
complete voice endpoints fast enough to keep useful contexts in the pipe. The
memory front end is still one request at a time, so endpoint assembly remains the
dominant limit for dense mono/stereo workloads.

The likely bottlenecks, in order, are:

1. Wave endpoint fetches.
   Mono voices need two sample reads and stereo voices need four sample reads.
   With a one-request-at-a-time memory interface, the DSP pipe can still see
   bubbles whenever memory latency exceeds the endpoint assembly rate.

2. Register-bank render reads.
   The active configuration and runtime fields are RAM-backed synchronous reads.
   A one-voice-per-cycle issue rate requires a steady one context read per cycle
   after the initial latency.

3. Retire/writeback bandwidth.
   One retired contribution per cycle requires one accumulator update per cycle
   and, for filtered voices, one filter-state writeback per retired voice.

4. Pipeline context width.
   Carrying full coefficients, gains, envelope, voice index, frame metadata, and
   filter state through every stage can add hundreds of flip-flops. This cost is
   acceptable only if the memory front end can actually feed the pipe.

The design should therefore measure three numbers separately: issue rate into the
DSP pipe, DSP retire rate, and memory endpoint assembly rate. A full-frame render
latency improvement is meaningful only when the first two are no longer dominated
by the third.

## Architecture Options

### Option A: DSP-Only Throughput Pipe

Keep the current one-request-at-a-time memory front end and current frame scanner,
but replace the compute states with a fixed-latency DSP pipe that can accept one
complete voice context per cycle. The scanner may still feed the pipe sparsely
because it waits for endpoint fetches.

This option is the lowest-risk refactor. It proves context propagation,
filter-state writeback, and in-order retirement without changing the memory
contract. It may not greatly reduce full-frame latency if memory dominates.

### Option B: In-Order Endpoint Queue

Add a fetch/context queue in front of the DSP pipe. The scheduler walks voices,
reads register-bank context, issues endpoint requests, and pushes a complete
context into the DSP pipe when all endpoints for that voice have returned. Memory
responses remain in order, so no external tag is required.

This option can overlap DSP execution with subsequent endpoint fetches. It is a
practical MVP because it improves throughput while keeping the memory interface
compatible with current tests and models.

### Option C: Tagged Multi-Outstanding Memory

Extend the memory request/response interface with tags and allow multiple endpoint
requests to be outstanding. The scheduler can then issue requests for several
voices while earlier requests are still waiting.

This option is the most scalable, but it changes shared interfaces and requires
new arbitration, response reorder, and cache behavior. It should follow Option B,
not precede it.

Recommended path: implement Option A as a mechanical extraction, then Option B as
the first useful throughput design. Reserve Option C for after memory profiling
shows endpoint fetches are the dominant frame-latency limit.

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

A concrete packed context can start with these fields:

```text
voice_ctx_t
  voice_index
  frame_id
  last_voice
  stereo
  filter_enable
  gain_l, gain_r
  envelope_level
  filter_b0, filter_b1, filter_b2, filter_a1, filter_a2
  filter_z1_l, filter_z2_l, filter_z1_r, filter_z2_r
  fraction
  raw_l0, raw_l1, raw_r0, raw_r1
```

The raw endpoints can be dropped after interpolation. The filter coefficients can
be dropped after the feedback multiply stage. Filter state snapshots can be
dropped after next-state saturation has been computed. Keeping separate smaller
stage structs is more work than one large context struct, but it prevents needless
FF growth once the architecture is stable.

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

The scheduler should own:

- `sample_tick` acceptance,
- frame-local `voice_index` scan,
- active/runtime context reads,
- disabled/done voice skipping,
- phase advance,
- endpoint request sequencing,
- `last_voice` marking for the final issued contribution.

The DSP pipeline should own only pure per-voice sample math:

- interpolation,
- optional biquad output and next-state calculation,
- gain and envelope scaling,
- final signed 16-bit contribution for left and right channels.

The retire stage should own side effects:

- filter-state writeback,
- accumulator update,
- final mix saturation,
- `sample_valid` generation.

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

For the in-order MVP, use a small endpoint assembly record rather than changing
the external memory interface:

```text
fetch_ctx_t
  valid
  voice_ctx_without_samples
  next_request_kind  // L0, L1, R0, R1
  raw_l0, raw_l1, raw_r0, raw_r1
```

The fetch unit requests endpoint samples in the same order as today. When the last
required endpoint returns, it pushes a complete `voice_ctx_t` into the DSP issue
queue. Mono voices skip right-channel requests and duplicate left endpoints in the
context before issue.

If a later tagged interface is added, each request should carry enough metadata
to place its response into the correct endpoint slot:

```text
mem_tag_t
  queue_slot
  channel
  endpoint_index
```

The tag should not carry the full voice context; it should index an existing
context table or FIFO entry to keep the memory bus narrow.

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

The first throughput version should require in-order retirement. That lets the
retire stage remain simple and deterministic:

```text
assert(result.frame_id == active_frame_id)
assert(result.voice_order == expected_retire_order)
```

Out-of-order retirement is only useful with tagged multi-outstanding memory or
variable-latency DSP stages. Supporting it would require either a reorder buffer
or per-frame associative accumulation, neither of which is needed for the first
implementation.

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

Phase state should be updated at issue, not retire, for the first design. The
current renderer advances phase before endpoint fetch and uses the old phase to
derive `frame_0`, `frame_1`, and `fraction`. Preserving that ordering avoids
changing loop-boundary behavior. The issued context must carry the derived frame
addresses and fraction; downstream stages should not reread mutable phase state.

Filter state should be read at issue and written at retire. Because only one
frame is in flight, a simple pipeline-drain rule prevents same-voice read-after-
write hazards:

```text
do not accept the next sample_tick until all issued contexts have retired
```

If overlapping frames becomes necessary, `filter_state_busy[voice]` must block
issue of that voice until its previous retire completes.

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

The current register bank already exposes one render-indexed config/runtime read
path. An issue scheduler can use that path like this:

```text
cycle N:   present voice_read_index = v
cycle N+1: wait for synchronous RAM outputs
cycle N+2: capture context for v, present voice_read_index = v+1
```

This gives roughly one captured context every two cycles unless the register bank
adds an output-valid pipeline or the scheduler overlaps address presentation with
context qualification. The exact issue cadence should be measured before adding
more ports. A one-context-per-two-cycle front end may still be an improvement if
DSP latency is currently much larger than two cycles per active voice.

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

A reasonable initial DSP stage table is:

| Stage | Data operation | Context action |
| --- | --- | --- |
| `D0_INTERP` | Compute left/right interpolation from raw endpoints and fraction. | Carry gains, envelope, filter enable, coefficients, filter state. |
| `D1_FILTER_X` | Multiply `x` by `b0`, `b1`, and `b2` for both channels. | Drop raw endpoints after this stage. |
| `D2_FILTER_Y` | Add `b0*x + z1`, saturate to PCM, select bypass or filtered sample. | Carry saturated `y` for feedback. |
| `D3_FILTER_FB` | Multiply `y` by `a1` and `a2` for both channels. | Drop filter coefficients after this stage. |
| `D4_FILTER_STATE` | Saturate next `z1/z2` values. | Carry next filter state for retire. |
| `D5_GAIN` | Apply left/right Q1.15 gain. | Carry envelope level. |
| `D6_ENVELOPE` | Apply envelope or full-level bypass. | Produce final contribution. |

This table intentionally keeps left and right channels parallel. A later
area-optimized variant can share one filter datapath across channels, but that
halves channel throughput and complicates stage control.

## Proposed Module Boundaries

The first implementation can keep the external `multi_voice_pipeline` interface
unchanged and introduce internal modules:

```text
multi_voice_pipeline
  voice_issue_frontend
  voice_endpoint_fetch
  voice_dsp_pipeline
  voice_retire_mixer
```

`voice_issue_frontend` can initially remain inside `multi_voice_pipeline` if a
full split would be too disruptive. The important boundary is the DSP module:
its input should be a complete immutable context, and its output should be a
complete result with no side effects.

Suggested result record:

```text
voice_result_t
  valid
  frame_id
  voice_index
  last_voice
  filter_enable
  next_z1_l, next_z2_l, next_z1_r, next_z2_r
  contribution_l, contribution_r
```

The retire module should be the only block that writes filter-state arrays or
updates the frame accumulator.

## Control and Backpressure

The minimal design should avoid ready/valid backpressure inside the DSP pipe. It
can instead apply backpressure before issue:

```text
issue_allowed = !dsp_input_full && !retire_flush_pending
```

Once a context enters the DSP pipe, it advances every cycle. This fixed-latency
contract simplifies `last_voice` handling and exact-output tests.

Backpressure is still needed at these boundaries:

- sample frame input: ignore or defer `sample_tick` while a frame is in flight,
- memory request: hold fetch state while `mem_req_ready` is low,
- endpoint issue queue: stop scanning voices if complete contexts cannot enter
  the DSP pipe,
- output: keep the existing `sample_valid` one-cycle pulse contract unless a
  downstream ready signal is added in a later interface change.

Reset must clear every valid bit in the issue queue, DSP pipe, and retire path.
Filter history arrays should retain the existing synchronous reset behavior.

## Throughput Estimate

Let:

```text
V = number of enabled voices
Lm = average cycles to assemble endpoints for one voice
Ld = DSP pipeline latency from issue to retire
Ii = average issue interval into DSP
```

The former latency-splitting design was approximately:

```text
frame_cycles ~= sum(memory_fetch_cycles_per_voice + fixed_compute_cycles_per_voice)
```

For a non-overlapped throughput DSP with in-order memory fetch:

```text
frame_cycles ~= frontend_fill + V * max(Lm, Ii) + Ld + retire_drain
```

If memory fetch remains strictly one voice at a time and `Lm` is large, the DSP
pipe will be underutilized. If endpoint assembly can produce one complete context
every one or two cycles, the DSP pipeline can retire close to one contribution per
cycle after fill. This estimate should be added to simulation counters before and
after the refactor:

- contexts issued,
- issue stall cycles by reason,
- DSP valid occupancy by stage,
- retire count,
- memory request and response stalls,
- frame cycles from `sample_tick` to `sample_valid`.

## Implementation Phases

Completed in the current RTL:

1. Extracted `voice_dsp_pipeline` from the old in-module compute states.
   The DSP block owns interpolation, optional biquad math, gain, envelope, and
   final per-voice contribution generation. It has no side effects on phase,
   filter-state arrays, or the frame accumulator.

2. Added per-stage valid/context propagation inside `voice_dsp_pipeline`.
   The DSP block is a fixed-latency valid-shift pipe and can accept a complete
   context every cycle when the front end can provide one.

3. Split issue from retire inside `multi_voice_pipeline`.
   Complete endpoint sets issue into DSP through an explicit context issue
   boundary; later `dsp_valid` results retire independently into the accumulator
   and filter-state arrays. `DRAIN` waits for all outstanding contexts before
   `FINISH` emits `sample_valid`.

4. Added area-oriented active-slot scanning.
   `config_valid` skips invalid voice slots before the synchronous render-read
   sequence. Invalid slots cost one scan cycle, but the renderer avoids a wide
   next-active search and keeps the register-bank read timing conservative.

5. Added an in-order DSP context queue at the endpoint boundary.
   The last required endpoint response builds an immutable `voice_dsp_context_t`.
   Completed contexts are stored in order and issued from the registered queue;
   direct response-to-DSP bypass was removed to cut the long response assembly to
   interpolator/DSP timing path. `DSP_START` is now a scheduler-advance state
   rather than the only DSP issue point.

6. Added a word-request FIFO and in-order endpoint assembly slots.
   The generic core memory contract remains one ordered 16-bit word response per
   request. The endpoint path can enqueue `L0`, `L1`, `R0`, and `R1` reads for
   later voices, track accepted request metadata, fill fetch slots as responses
   arrive, and issue completed contexts into the DSP context queue.

7. Mapped internal fetch/context payload storage to distributed RAM.
   The DSP context queue, fetch-slot base context, fetch-slot raw endpoint
   samples, word-request queue, and response-metadata queue are RAM-backed where
   Vivado can infer it. Control counts, pointers, and pending bits remain FFs.

Remaining phases:

1. Add focused observability for the throughput path.
   Useful checks include contexts issued, retire count, DSP valid occupancy,
   memory request/response stalls, invalid-slot scan cycles, and frame cycles from
   `sample_tick` to `sample_valid`.

2. Optimize adapter-internal memory bandwidth.
   A board or simulation memory adapter may use paired endpoint extraction,
   cache-line hits, bursts, or prefetch internally, but those optimizations must
   remain behind the core's one-word request/response interface unless a future
   milestone explicitly changes the memory contract.

3. Only after the in-order endpoint path is stable, consider request tags and
   multiple outstanding reads. That change affects the memory subsystem, models,
   and tests, so it should be justified by measured endpoint stalls.

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

Useful assertions and counters:

- every valid DSP result corresponds to exactly one issued context,
- `voice_index` is stable within a context across all DSP stages,
- retire order matches issue order in the MVP,
- accumulator clears exactly once per accepted `sample_tick`,
- `sample_valid` is emitted exactly once per accepted frame,
- no filter-state write occurs for a disabled filter context,
- reset clears all `valid` bits within one cycle,
- issue stall counters classify stalls as memory, register read, DSP input, or
  frame drain.

The reference model should remain independent of the RTL pipeline structure. Do
not compute expected samples by mirroring the new stage-by-stage RTL operations in
the testbench unless there is a separate mathematical check.

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
