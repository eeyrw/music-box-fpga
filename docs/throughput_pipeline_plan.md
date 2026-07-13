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

The first target should be more conservative than a fully streaming audio engine:

- one output frame in flight at a time,
- in-order voice retirement,
- no repeated issue of the same voice before its filter state writes back,
- no overlap between the retire phase of frame N and issue phase of frame N+1,
- exact integer output equivalence with the current renderer.

This preserves the existing external `sample_tick`/`sample_valid` contract while
allowing the internal DSP section to accept a new ready voice every cycle once
endpoint samples are available.

## Expected Bottlenecks

The current timing pipeline reduced the compute critical path, but it also made
each enabled voice spend several cycles in DSP states. A throughput pipeline only
improves frame latency if the front end can supply complete voice endpoints
faster than the current one-voice-at-a-time state machine.

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

The current latency-splitting design is approximately:

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

## Suggested Implementation Phases

1. Extract a fixed-latency `voice_dsp_pipeline` from the existing compute states.
   Keep the current one-voice-at-a-time scheduler. This validates context packing
   and preserves behavior with limited risk.

   Acceptance criteria: exact existing tests pass, the DSP module has a documented
   fixed latency, and no side-effect state is modified inside the DSP module.

2. Add per-stage valid/context propagation inside `voice_dsp_pipeline`. The module
   should accept a new voice every cycle in isolation tests, even if the top-level
   scheduler still feeds it sparsely.

   Acceptance criteria: a focused DSP-only test injects back-to-back contexts with
   different coefficients, gains, and voice indices and observes correctly ordered
   results.

3. Add an issue queue after register-bank reads and memory endpoint assembly.
   Keep memory responses in order at first; allow DSP stages to overlap once a
   complete endpoint pair is ready.

   Acceptance criteria: full-core tests show adjacent active voices occupying
   different DSP stages and final PCM remains exact.

4. Retire one contribution per cycle into the accumulator and filter-state
   writeback path. Add ordering assertions so `sample_valid` fires only after the
   last issued voice for the frame retires.

   Acceptance criteria: filter history readback tests prove each voice receives
   its own next state, including interleaved mono/stereo and disabled-voice cases.

5. Only after the in-order design is stable, consider memory request tags and
   multiple outstanding reads. This is the point where throughput gains can extend
   beyond the DSP block and into the memory subsystem.

   Acceptance criteria: memory stress tests show improved frame latency or reduced
   DSP bubbles compared with the in-order endpoint queue.

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
