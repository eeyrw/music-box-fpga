# Multi-Voice Render Pipeline

This document describes the current `multi_voice_pipeline` render datapath, the
registered per-voice compute stages, and the simulation metrics used to evaluate
voice-count scaling.

## Scope

`rtl/voice/multi_voice_pipeline.sv` renders one output stereo sample when
`sample_tick` is asserted. It walks the committed voice table, fetches wave
endpoints from the abstract memory interface, evaluates each enabled voice, adds
the voice contribution into a signed 32-bit stereo accumulator, and finally
saturates the mixed result to signed 16-bit PCM.

The external module interface did not change:

- Committed configuration still arrives through `voice_config`, `config_valid`,
  and `config_commit`; runtime controls arrive separately through
  `voice_runtime`.
- Wave memory still uses the existing untagged ready/valid word-read interface;
  responses are handled in accepted-request order.
- `sample_valid` still marks the completed mixed stereo output sample.

## Voice Count Configuration

The default build uses 256 voices. Simulation builds can override the voice count
from `make`:

```bash
make render-rtl-core NUM_VOICES=8 MIDI=assets/midi/dense_many_notes.mid SECONDS=5
make render-rtl-core NUM_VOICES=16 MIDI=assets/midi/dense_many_notes.mid SECONDS=5
make render-rtl-core NUM_VOICES=32 MIDI=assets/midi/dense_many_notes.mid SECONDS=5
make render-rtl-core NUM_VOICES=256 MIDI=assets/midi/dense_many_notes.mid SECONDS=5
```

`NUM_VOICES` drives both sides of the simulation build:

- RTL receives `SYNTH_NUM_VOICES`, which sets `synth_pkg::NUM_VOICES`.
- C++ render harnesses receive `RENDER_NUM_VOICES`, which sets `kNumVoices`.

Keep the same SF2, MIDI, sample rate, and render duration when comparing cycle
results across voice counts. Changing the voice count can also change musical
behavior if the MIDI demands more concurrent notes than the configured voice
pool; in that case the MCU model steals older voices earlier.

## Baseline Datapath

Before this optimization, the renderer used a sequential state machine for voice
iteration and memory access. After memory returned the interpolation endpoints,
the `ACCUMULATE` state evaluated the full DSP chain combinationally:

```text
raw endpoints
  -> linear interpolation
  -> optional biquad IIR
  -> combined channel gain and envelope/full-level bypass
  -> signed 32-bit mix accumulator
```

That kept per-voice latency low, but the worst combinational path was long. The
heaviest case was a filtered stereo voice, because the cycle included two
interpolators, two biquad evaluations, two channel-gain multiplies, two envelope
multiplies, and the accumulator add. The biquad path is especially costly because
each channel performs multiple 32-bit coefficient multiplies and wide signed
add/subtract operations.

## Current Pipeline Shape

The current implementation is a one-frame-at-a-time throughput renderer. It keeps
the external `sample_tick`/`sample_valid` contract and the untagged ordered memory
interface, but it separates these internal concerns:

```text
active-slot scheduler and register snapshot
  -> voice_phase_frame phase/loop/frame calculation
  -> next-valid voice prefetch during endpoint fetch
  -> endpoint fetch FSM
  -> fixed-latency voice_dsp_pipeline
  -> retire accumulator and filter-state writeback
  -> DRAIN
  -> FINISH
```

The scheduler issues at most one complete voice context into DSP per cycle.
`voice_phase_frame` owns the combinational phase algorithm: it derives the
left/right endpoint frame numbers, interpolation fraction, loop-active state,
done state, and next phase values from the captured register-bank/runtime state.
The DSP pipeline can accept back-to-back contexts, and the retire path can
consume one result per cycle. Mono interpolation still needs two ordered word
responses and stereo interpolation needs four. The frontend enqueues endpoint
word requests into an internal FIFO and can move on to later voices while earlier
endpoint responses are still pending, as long as fetch slots and queues have
room.

The renderer now overlaps work inside a single output frame:

- `PROCESS_VOICE` issues the immutable voice context to `voice_endpoint_fetch`
  and advances phase when the fetch engine is ready. The fetch module serializes
  L0/L1/R0/R1 ordered word reads into its internal `word_req_queue`; mono voices
  skip the right-channel requests.
- The memory interface drains the fetch module's `word_req_queue` independently
  of the voice FSM. Each accepted request pushes compact metadata into
  `rsp_meta_queue`. Later ordered `mem_rsp_valid` pulses fill RAM-backed
  fetch-slot endpoint fields. The final endpoint response assembles a complete
  `voice_dsp_context_t` and pushes it into the DSP context queue.
- The DSP context queue is the only source for `voice_dsp_pipeline`. Completed
  contexts no longer bypass directly into DSP, which keeps the response assembly
  path registered before the interpolator/DSP chain.
- While the current voice enqueues endpoints, a single-entry prefetch scanner may
  advance `render_index` to the next valid voice and let the synchronous
  register-bank and local phase/filter RAM outputs settle early.
- If that prefetch is ready at `DSP_START`, the front end jumps directly to the
  next voice's `START_VOICE` instead of paying `SCAN_VOICE`, `READ_VOICE`, and
  `WAIT_VOICE` after the current voice's endpoint requests have been enqueued.
- The front end continues scanning and fetching later voices instead of waiting
  for the issued voice to finish DSP.
- DSP results return later on `dsp_valid`; the retire path updates the stereo
  accumulator and writes the result voice's filter state.
- `DRAIN` waits until the word-request queue, response-metadata queue, fetch slots,
  DSP context queue, and all issued DSP contexts have emptied before final mix
  saturation in `FINISH`.

Only one output frame is in flight. The next `sample_tick` is accepted only after
the prior frame has drained and `sample_valid` has been emitted. This keeps phase,
filter-state, and accumulator ownership simple.

This should not be read as a CPU-style global N-stage pipeline. The renderer has
two different timing domains inside one clock domain:

- The outer voice-render front end is an FSM with variable latency. It scans voice
  slots, waits for synchronous register-bank reads, allocates fetch slots, queues
  one-word memory requests, and assembles interpolation endpoints from ordered
  responses. It delegates phase wrap, frame clamping, loop release behavior, and
  phase writeback values to `voice_phase_frame`. It also has a single-entry
  next-valid prefetch path that can prepare one later voice's register outputs
  while current endpoint requests are being enqueued or served by memory.
- The inner `voice_dsp_pipeline` is a fixed-latency valid pipeline. Once the front
  end has a complete voice context, the DSP block can move that context through
  its stages like a conventional pipeline.

In other words, the current shape is:

```text
sample_tick
  |
  v
variable-latency front end
  scan slots
  read voice config/runtime
  advance phase
  prefetch next valid slot during endpoint fetch
  enqueue L0/L1[/R0/R1] word requests
  assemble endpoint responses into fetch slots
  queue voice_dsp_context_t
  |
  v
fixed-latency 6-stage DSP pipe
  input context capture
  interpolate
  filter products
  filter output
  raw filter state and gain input
  filter-state saturation and envelope output
  |
  v
retire/drain
  accumulator update
  filter-state writeback
  wait for outstanding DSP contexts
  final PCM16 saturation
  |
  v
sample_valid
```

The DSP pipe can accept one complete context per cycle, but the whole renderer
does not guarantee one voice per cycle because endpoint responses still arrive
through the existing ordered one-word memory interface. The front end can overlap
later voice register prefetch, endpoint request enqueueing, memory response waits,
and earlier DSP work, but bubbles are expected when memory cannot return complete
contexts fast enough.

The biquad state update is split across the last two DSP stages for timing. Stage
3 registers the raw 38-bit `z1` and `z2` expressions after the coefficient
multiply/add chain. Stage 4 saturates those raw values back to the signed 34-bit
per-voice filter-state format while the already-registered gain result advances to
the envelope step. This preserves the external `valid_i` to `valid_o` latency and
sample results while avoiding a single-cycle path from DSP48 cascade outputs
through the wide saturation compare/carry chain into the filter-state registers.
The range analysis in `../fixed_point.md` shows that the existing SoundFont
low-pass coefficient generator does not produce unusually large intermediate
values while allowing the feedback output `y` to exceed PCM16 and remain within
the signed 20-bit post-filter sample path.

The current control flow for one output frame is:

```text
sample_tick
   |
   v
+--------+ -> +------------+ -> +-----------+ -> +------------+
|  IDLE  |    | SCAN_VOICE |    | READ_VOICE|    | WAIT_VOICE |
+--------+    +------------+    +-----------+    +------------+
                                      |                 |
                                      +-----------------+
                                                |
                                                v
                                       +-------------+
                                       | START_VOICE | snapshot config/runtime/phase/filter state
                                       +-------------+
                                                |
                                                v
                                      +---------------+
                                      | PROCESS_VOICE | skip disabled/done or allocate fetch slot
                                      +---------------+
                                                |
                            disabled/done ------+------ enabled
                                                |
                                                v
                                       +----------------------+
                                       | voice_endpoint_fetch |
                                       +----------------------+
                                          enqueue ordered endpoint requests; mono skips R0/R1
                                                |
                                                v
                                          +-----------+
                                          | DSP_START | advance scheduler
                                          +-----------+
                                                |
                                +---------------+---------------+
                                |                               |
                         next voice available                 no more
                                |                               |
                                v                               v
                         START/SCAN path                    +--------+
                                                            | DRAIN  |
                                                            +--------+
                                                                |
                                                                v
                                                            +--------+
                                                            | FINISH |
                                                            +--------+
                                                                |
                                                                v
                                                          sample_valid
```

The endpoint response path runs beside that FSM:

```text
voice_endpoint_fetch:
word_req_queue -> memory request/response -> rsp_meta_queue
       -> fetch-slot endpoint RAMs -> fetch_queue -> voice_dsp_pipeline -> retire
```

A typical overlap inside one output frame looks like this:

```text
time ---->

voice N front end:
  START/PROCESS -> issue endpoint context -> DSP_START

voice N endpoint queues:
  enqueue L0/L1/R0/R1 -> word_req_queue drains to memory -> rsp_meta_queue tracks accepted reads -> fetch slot fills -> context queue

voice N+1 prefetch:
                         scan next valid -> set render_index -> sync read wait -> prefetched ready

voice N+1 front end:
                                                                                                  START/PROCESS -> issue endpoint context -> ...

DSP pipe:
                                                                                      N S0 -> N S1 -> N S2 -> N S3 -> N S4 -> N out
                                                                                                                       N+1 S0 -> ...

retire:
                                                                                                                                      N result -> accum/filter writeback
```

For a mono voice the right-channel endpoint states are skipped, so the overlap is
shorter:

```text
time ---->

voice N mono endpoint path:
  issue endpoint context -> enqueue L0/L1 -> context queue

next-valid prefetch:
            scan/read next voice while queued L0/L1 requests and responses are in flight

DSP/retire:
                            N S0 -> N S1 -> N S2 -> N S3 -> N S4 -> N result
```

This overlap hides the fixed DSP latency behind later front-end work, but it does
not make the memory fetch path itself a one-voice-per-cycle pipeline. The current
prefetch removes much of the register-read bubble between adjacent valid voices,
and endpoint request overlap removes one request-state bubble between consecutive
endpoints when the memory interface can accept the next request. A fuller CPU-like
render pipeline would still need separate front-end stages or queues for slot
scan, endpoint request/response assembly, DSP issue, and retire, plus enough
memory bandwidth or tagging to keep those stages fed.

## Pipeline Stages

One `sample_tick` starts one complete output-frame render. The pipeline selects
valid voice slots in increasing index order, skipping invalid entries through the
`config_valid` active-slot mask, then emits one mixed stereo sample in `FINISH`.

Current front-end state sequence:

| Stage | Purpose | Main registered outputs |
| --- | --- | --- |
| `IDLE` | Wait for `sample_tick`. | Clears `accum_l/r`, latches `config_commit`, starts scanning at voice 0, and presents the initial render read index. |
| `SCAN_VOICE` | Walk `config_valid` in increasing slot order. | Selects the next configured slot or enters `DRAIN` if no more slots remain. |
| `READ_VOICE` | Give the register bank a stable `voice_read_index`. | Starts the conservative synchronous render-read sequence. |
| `WAIT_VOICE` | Wait for RAM-backed fields to reach the register-bank render outputs. | Holds the selected read index before context capture. |
| `START_VOICE` | Snapshot render config/runtime for the selected voice. | `current_*` config snapshot and current phase snapshot. |
| `PROCESS_VOICE` | Skip disabled/done voices or derive endpoint frames, issue a fetch context, and advance phase when the fetch engine is ready. | `voice_endpoint_fetch` issue handshake and updated phase writeback. |
| endpoint enqueue | Runs inside `voice_endpoint_fetch`, serializing L0/L1/R0/R1 requests into the word-request FIFO; mono skips R0/R1. | Ordered endpoint request entries. |
| response assembly | Runs inside `voice_endpoint_fetch`, using accepted-request metadata to fill RAM-backed fetch-slot endpoint fields from ordered `mem_rsp_valid` pulses. | Completed mono/stereo contexts enter the DSP context queue. |
| `DSP_START` | Advance the scheduler after the current voice's endpoint requests have been queued. | Starts a prefetched next voice, falls back to scanning, or advances to `DRAIN`. |
| `DRAIN` | Wait for request FIFO, response metadata, fetch slots, context queue, and issued DSP contexts to empty. | Holds until all frame work has retired. |
| `FINISH` | Saturate the 32-bit stereo accumulators to signed 16-bit PCM. | `sample_l/r`, `sample_valid`. |

Disabled and completed voices skip from `PROCESS_VOICE` to the next active slot
or to `DRAIN`. Invalid slots are not selected by the active-slot scanner. For
enabled mono voices, `voice_endpoint_fetch` skips the right-channel endpoint
requests. The response assembler duplicates the left raw endpoints into the
right-channel fields when the mono fetch slot completes.

## DSP Pipeline Stages

`rtl/dsp/voice_dsp_pipeline.sv` owns pure per-voice sample math. It has an
explicit `valid_i`/`valid_o` contract and no side effects on phase, filter state
arrays, or the frame accumulator. Every stage carries enough immutable context to
retire the result for the correct voice.
It is also the single RTL implementation of the optional biquad arithmetic; there
is no separate standalone filter datapath in the production source list.

The DSP submodule is the part that most closely matches a conventional fixed
stage pipeline:

```text
valid_i / voice_dsp_context_t
        |
        v
+-----------+   +-------------+   +-------------+   +-----------------+   +---------+
| S0_INTERP |-->| S1_FILTER_X |-->| S2_FILTER_Y |-->| S3_FILTER_STATE |-->| S4_GAIN |
+-----------+   +-------------+   +-------------+   +-----------------+   +---------+
        |               |                |                    |                |
        |               |                |                    |                v
        |               |                |                    |       gain/envelope scale
        |               |                |                    v
        |               |                |          next z1/z2 and filter/bypass select
        |               |                v
        |               |       y = b0*x + z1, saturate y
        |               v
        |       b0*x, b1*x, b2*x, z1/z2 extend
        v
linear interpolation
                                                                                |
                                                                                v
                                                                     valid_o / voice_dsp_result_t
```

Each valid context carries its voice index, gains, envelope, filter enable,
coefficients, filter-state snapshot, and endpoint samples until the fields are no
longer needed. The result returns the voice index, final signed contributions, and
next filter state for retire-time writeback.

| Stage | Operation | Context carried forward |
| --- | --- | --- |
| `S0_INTERP` | Interpolate left and right raw endpoints using the captured fraction. | Voice index, gains, envelope, filter enable, coefficients, filter state. |
| `S1_FILTER_X` | Multiply `x` by `b0`, `b1`, and `b2`; sign-extend `z1/z2`. | Filter coefficients, filter state products, raw/bypass sample. |
| `S2_FILTER_Y` | Compute `y = b0*x + z1`, saturate to signed 20-bit, and preserve feed-forward products for feedback state. | Saturated `y`, bypass sample, feedback inputs. |
| `S3_FILTER_STATE` | Compute raw next `z1/z2`; select filtered or bypass sample for output scaling. | Raw next filter state, selected post-filter sample, gain/envelope context. |
| `S4_GAIN` | Register the selected post-filter samples and saturate raw `z1/z2` into the 34-bit filter-state format. | Selected samples and next filter state. |
| Output | Apply combined channel gain plus envelope or full-level bypass and emit `voice_dsp_result_t` when `valid_pipe[5]` is set. | Voice index, filter enable, next filter state, final contribution. |

The DSP pipe can accept a new complete context every cycle when the front end can
provide one. With the current memory interface it normally sees bubbles, but the
valid-shift structure, word-request FIFO, in-order response assembly, and
complete-context queue make those stalls explicit and allow later voice setup to
overlap memory waits.

## Issue, Retire, And Drain

`multi_voice_pipeline` tracks issued-but-not-retired contexts with
`outstanding_count`. A context issue into `voice_dsp_pipeline` increments the
count, and `dsp_valid` subtracts one. The retire path is independent of the
front-end state machine:

```text
if dsp_valid:
  if result.filter_enable:
    filter_z*[result.voice_index] <= result.next_z*
  accum_l/r <= accum_l/r + result.contribution_l/r
```

Because endpoint fetch remains in order and the DSP pipe is fixed latency,
results retire in issue order. The accumulator is shared for one output frame, so
`DRAIN` waits for the word-request FIFO, response metadata FIFO, fetch slots, DSP
context queue, and `outstanding_count` to all empty before `FINISH` saturates the
final PCM output.

## Config Snapshot

The render pipeline drives a single `voice_read_index`, and the register bank
returns only that voice's active configuration and runtime control snapshot.
`voice_read_index` is driven from a registered `render_index` selected by the
active-slot scanner. This keeps the register-bank synchronous read address stable
through `READ_VOICE` and `WAIT_VOICE` before `START_VOICE` captures the returned
configuration/runtime snapshot.

The renderer uses `READ_VOICE` and `WAIT_VOICE` before `START_VOICE` so
synchronous BRAM-backed fields, including active configuration, runtime
phase/gain/envelope, and runtime filter coefficients, are stable before they are
captured.

`wavetable_render_core` only asserts the frame-boundary input when `sample_tick` arrives
while the pipeline is idle; that boundary pulse reloads committed phase and clears
filter history for voices that were committed by the register bus. Runtime
registers are live state and are sampled when `START_VOICE` accepts each voice.
The pipeline latches only the per-frame commit bitmap; it does not receive or
duplicate the full `voice_config` and `voice_runtime` arrays.

The active-slot scanner uses `config_valid` while it walks voice slots in index
order. Empty slots cost one scan cycle but skip the render-read sequence.
Configured-but-disabled voices still require a context read because the `enable`
bit lives in the committed active configuration, not in `config_valid`.

`START_VOICE` reads the selected stable active entry to decide whether a voice is
enabled, whether it is valid, whether it is done, and which phase/frame addresses
should be rendered. Once a voice is accepted, the fields needed by later stages
are copied into local `current_*` registers:

- stereo/mono mode
- wave base address
- left and right channel gain
- envelope level
- filter enable
- filter coefficients
- filter-state snapshot

Memory request address generation uses these per-voice `current_*` registers.
The filter-state snapshot is captured before the prefetch path is allowed to move
`render_index` toward the next valid voice. When endpoint fetch completes,
`multi_voice_pipeline` packages the current register snapshot, raw endpoints,
fraction, voice index, and captured filter-state snapshot into
`voice_dsp_context_t`. SPI or register-bus runtime writes that arrive while one
output sample is being rendered may affect voices that have not yet reached
`START_VOICE`; they do not affect a voice after its context has been captured.

`voice_phase_frame` is intentionally stateless and has no memory-interface
knowledge. It makes the same Q24.8 frame/fraction decisions previously embedded
inside `multi_voice_pipeline`: `loop_end` remains exclusive, no-loop or released
until-release playback clamps interpolation to the final valid frame, and
continuous loops wrap both the endpoint frame and the next phase with one
subtraction under the documented phase-increment limit. The renderer still owns
the per-voice phase RAMs and performs the writeback only for voices that are not
complete.

Configuration writes still update shadow state. `VOICE_CONTROL.apply` writes the
selected shadow entry into active configuration storage immediately and stages a
frame-boundary reload/clear pulse for the renderer. Runtime writes such as
envelope, gain, pitch, release, and runtime filter updates do not reload phase.
The `START_VOICE` capture defines the per-voice render context for the in-flight
output sample.

## Filter State Handling

Biquad state is stored as signed 34-bit values per voice and per channel:

```text
filter_z1_l[voice]
filter_z2_l[voice]
filter_z1_r[voice]
filter_z2_r[voice]
```

The DSP pipeline computes the next filter state from the captured filter input,
coefficients, and filter-state snapshot carried in `voice_dsp_context_t`. The
actual per-voice filter state arrays are updated only by the retire path when
`dsp_valid` is asserted, and only when `result.filter_enable` is set.

This preserves the rule that a voice's IIR state advances exactly once per
rendered output sample contribution. The result carries `voice_index`, so filter
state writeback remains aligned with the same voice that produced the interpolated
sample even while later voices are already in the front end.

## Latency Impact

Each selected valid voice spends two scheduler cycles in `READ_VOICE` and
`WAIT_VOICE` before `START_VOICE`. Invalid slots cost one scan cycle and skip the
render-read sequence.

Enabled voices no longer block the front end while they traverse DSP. Once the
current voice's endpoint word requests are queued, `DSP_START` can move the
scheduler on to the next selected voice while ordered responses fill fetch slots
in the background. When a fetch slot completes, the complete context enters the
DSP context queue and is issued to DSP on a later registered queue read.
The fixed-latency DSP pipe retires the result in parallel with later voice fetch
work. The remaining per-voice bottleneck is memory service: mono voices still need
two word responses and stereo voices still need four.

The single-entry next-valid prefetch reduces the register-read bubble between
adjacent valid voices when endpoint fetch takes long enough to hide the
prefetch-read latency. Endpoint request overlap then removes one cycle between
consecutive endpoint reads when the memory interface is ready as the previous
response is consumed. On the 30-second Hedwig/MS_Basic quick-render workload, the
measured 32-voice render cost changed from the original `250.278` average and
`375` maximum cycles per sample to `195.729` average and `282` maximum after
next-valid prefetch, then to `167.710` average and `226` maximum after endpoint
request overlap. Adding the complete-context queue changed that same workload to
`167.389` average and `225` maximum cycles. Adding the word-request FIFO and
in-order endpoint assembly queue reduced it further to `149.209` average and
`195` maximum cycles while preserving the same `46.9586` average and `88` maximum
memory word reads per sample. All runs kept the same maximum enabled and
filtered voices for that workload and exact C++ reference audio match.

The regression latency guard for the all-voice mono render case remains
`600 + NUM_VOICES` cycles. This is a structural regression limit, not a
board-level real-time deadline. It allows the fixed DSP pipeline, synchronous
register-bank reads, and memory handshakes while still catching accidental large
latency regressions.

## Timing Benefit

For filtered voices, the long DSP calculation is now split across
`voice_dsp_pipeline` stages:

- interpolation is separated from filter coefficient multiplication,
- feed-forward multiplication, signed 20-bit filter output limiting, feedback multiplication, and
  next-state saturation occupy separate pipeline stages,
- selected post-filter samples are registered before output scaling,
- channel gain, envelope scaling, and final contribution generation happen at the DSP output,
- accumulator update and filter-state writeback happen only in the retire path.

Post-synthesis Smart Artix timing improved from a `clk_pll_i` setup WNS of
`-10.650 ns` before filter pipelining to `+0.670 ns` after preserving the
interpolation/filter register boundary. Hold violations remain in the early
board-level clocking/MIG paths and still require implementation and constraint
work. Verilator lint and simulation verify structural validity and behavior, not
FPGA timing closure.

## Behavioral Contracts Preserved

The change preserves these contracts:

- PCM samples remain signed 16-bit values.
- Linear interpolation math and rounding behavior are unchanged.
- Channel gain and envelope gain still use signed Q1.15 multiplication, but
  non-full envelope values are folded into one wide output product with one final
  PCM16 saturation.
- `0x7fff` envelope level still bypasses envelope multiplication.
- Filter coefficients remain signed Q2.14 and use the same transposed direct-form
  II equation.
- Filter output `y` is limited to signed 20-bit before feedback and output gain.
- Filter state is cleared on voice commit and is not updated for disabled filter
  voices.
- Mono samples are still duplicated before independent left/right gain.
- Stereo samples are fetched from independent absolute left/right sample regions
  with independent channel length and loop metadata.
- Final mix saturation still occurs once, after all voice contributions have been
  accumulated.

## Verification

The implementation was verified with:

```bash
make lint
make test
```

The regression suite covers the unchanged exact-output behavior, including mono
and stereo fetches, interpolation, looping, envelope scaling, filtered voice
output, multi-voice mixing, and the all-voice latency bound.

The lint run still reports existing non-fatal warnings such as unused parameters,
unused low product bits in interpolation, and testbench blocking-clock assignment
warnings. No fatal lint or simulation failures remain.

## Cycle Accounting

`render-rtl-core` records RTL cycle counts in
`build/render_rtl_core/rtl_core_render_config.json` after a successful render. These
fields are intended for architecture comparisons and regression tracking:

| Field | Meaning |
| --- | --- |
| `rtl_total_cycles` | Total `CoreRtlHarness::tick()` cycles from reset through the completed RTL core render, including reset, register writes, envelope updates, memory handshakes, and sample rendering. |
| `rtl_total_memory_reads` | Total wave-memory word reads accepted by the RTL core harness during the full run. |
| `rtl_render_cycles_sum` | Sum of per-output-sample render cycles measured from the `sample_tick` cycle through the cycle where `sample_valid` is observed. |
| `rtl_avg_render_cycles` | `rtl_render_cycles_sum / output_samples`. |
| `rtl_max_render_cycles` | Maximum per-output-sample render latency observed during the RTL core render. |
| `rtl_render_memory_reads_sum` | Sum of accepted wave-memory word reads during per-sample render windows. |
| `rtl_avg_render_memory_reads` | Average wave-memory word reads per output sample. Mono interpolated voices normally cost two reads; stereo interpolated voices normally cost four reads. |
| `rtl_max_render_memory_reads` | Maximum wave-memory word reads accepted during one output sample render. |
| `rtl_avg_enabled_voices` | Average number of committed enabled voice slots at the start of each output sample request. |
| `rtl_max_enabled_voices` | Maximum enabled voice slots observed at the start of a sample request. |
| `rtl_avg_audible_voices` | Average enabled voice slots with a nonzero envelope level at the start of each sample request. |
| `rtl_max_audible_voices` | Maximum enabled voice slots with nonzero envelope level. |
| `rtl_avg_filtered_voices` | Average enabled voice slots whose current region has `filter_enable` set. |
| `rtl_max_filtered_voices` | Maximum enabled filtered voice slots. |
| `rtl_avg_stereo_voices` | Average enabled voice slots whose current region is stereo. |
| `rtl_max_stereo_voices` | Maximum enabled stereo voice slots. |

The per-sample render counters measure RTL scheduler and memory-service cost for
the current abstract one-cycle memory response model used by `render-rtl-core`. They
are cycle counts, not absolute time. Converting them into real-time margin still
requires a target system clock and the final memory profile.

`render-rtl-core` waits for `sample_valid` using a timeout derived from the
configured voice count, not a fixed smoke-test limit:

```text
timeout_cycles = 64 + NUM_VOICES * 4 * 8
```

The factor of four covers the maximum word reads for one stereo interpolated
voice in the direct one-cycle memory model, and the final factor leaves pipeline
and scheduler slack around each read. A timeout is therefore still treated as a
possible RTL progress bug, but high-polyphony renders are not constrained by the
old 32-voice-era fixed limit.

These counters make it possible to separate the main costs:

- More enabled voices increase scheduler, endpoint-fetch, and retire work. DSP
  latency is overlapped after issue, but the pipe still needs a valid context for
  each rendered voice.
- More filtered voices do not add extra states in the current fixed pipeline, but
  they exercise the heavier `FILTER` combinational path and therefore matter for
  Fmax.
- More stereo voices increase memory traffic because stereo interpolation reads
  four words per voice instead of two.
- `rtl_max_render_cycles` is the deadline number to compare against
  `system_clk_hz / output_sample_rate` for the tested workload.

## 100 MHz / DDR3 Polyphony Estimate

This section records the current analytical estimate for real-time polyphony
before adding a more parallel memory/cache subsystem. It is an architectural
budget, not a replacement for the `render-rtl-core` and `render-memory`
counters. Re-run those counters after any scheduler, cache, DDR wrapper, or sample
rate change.

Assumptions:

- System clock is `100 MHz`.
- Output sample rate is `48 kHz`.
- The render deadline for one stereo output frame is therefore:

```text
100,000,000 / 48,000 = 2083.33 core cycles/sample
```

- The current renderer accepts one `sample_tick` only when the prior output frame
  has drained. It does not overlap frame `N + 1` with frame `N`.
- The current `voice_dsp_pipeline` is fixed latency and can accept one complete
  `voice_dsp_context_t` per cycle once endpoint samples are available.
- The current front end still walks voices through the `multi_voice_pipeline`
  scheduler states and must snapshot config/runtime, calculate phase/frame
  values, issue endpoint fetch work, and later retire DSP results.
- The current memory-backed path uses `wave_memory_subsystem` with one global
  `LINE_WORDS = 8` cache line and one outstanding core-side word request.
- The current C++ DDR timing profile is an approximation, not a board-proven MIG
  timing model: random line latency is 10 core cycles, sequential line latency is
  4 core cycles, and ready gap is 0 cycles.

### DSP-Only Lower Bound

If endpoint samples are assumed to be immediately available and memory stalls are
ignored, the arithmetic pipe itself is not the limiting factor. A complete DSP
context takes about seven clocks to retire, but the pipe can accept another
complete context every clock. In isolation the DSP capacity would therefore be
far beyond 256 voices at 48 kHz.

The current top-level render latency is instead dominated by the voice scheduler
and endpoint issue path. For a valid enabled voice, the steady state path is
approximately:

```text
SCAN_VOICE -> READ_VOICE -> WAIT_VOICE -> START_VOICE -> PROCESS_VOICE -> DSP_START
```

That is about six scheduler clocks per rendered voice before memory effects.
After the final voice is issued, the renderer also pays the remaining endpoint,
DSP, drain, and finish tail. With ideal endpoint service, a useful first-order
estimate is:

```text
mono frame cycles   ~= 6 * active_voices + 13
stereo frame cycles ~= 6 * active_voices + 15
```

Using the 2083-cycle 48 kHz deadline:

```text
(2083 - 15) / 6 = 344 voices
```

The register map currently supports fewer voice slots than that estimate
(`REG_MAX_ADDRESSABLE_VOICES` is 286), and normal builds use `NUM_VOICES = 256`.
Therefore the current arithmetic and scheduler path is expected to fit 256 voices
at `100 MHz`/`48 kHz` when memory service is ideal.

Invalid slots are cheaper but not free. The active-slot scanner skips
`config_valid == 0` slots without reading the full voice context, but it still
spends scan cycles walking the configured voice range. Sparse workloads are
therefore closer to:

```text
frame cycles ~= NUM_VOICES + 5 * valid_slots + tail
```

### Current DDR/Profile Estimate

The memory path changes the practical limit. Mono interpolation requires two
16-bit sample words per active voice (`L0` and `L1`). Stereo interpolation
requires four words (`L0`, `L1`, `R0`, and `R1`). The current cache line holds
eight 16-bit words. A common case is that `L0` and `L1` land in the same line, so
one endpoint pair pays one line miss followed by one same-line hit. For stereo
voices, the left and right samples are usually in separate SF2 regions, so the
left pair and right pair often each pay their own line miss.

With the current DDR profile, observed response latency is about 12 core cycles
for a random line miss through the line adapter and about two core cycles for a
same-line hit response through the one-word core interface. A conservative
per-voice memory-service estimate is therefore:

```text
mono voice   ~= L miss + L hit       ~= 12 + 2 = 14 cycles
stereo voice ~= L miss + L hit
              + R miss + R hit       ~= 28 cycles
```

Dividing the 2083-cycle frame budget by those costs gives the memory-limited
upper bounds:

```text
mono, poor inter-voice locality:   2083 / 14 ~= 148 voices
stereo, poor inter-voice locality: 2083 / 28 ~= 74 voices
```

The scheduler, drain, output FIFO margin, fractional tick placement, and real DDR
controller arbitration reduce the number that should be treated as safe. Until
board measurements prove otherwise, the practical target range for the current
architecture is:

| Workload shape | Practical target at 100 MHz / 48 kHz |
| --- | ---: |
| Mostly mono samples | about 120 voices |
| Mostly stereo samples | about 60 voices |
| Mixed mono/stereo SoundFont playback | about 60-120 voices, depending on stereo ratio and cache locality |

This estimate assumes relatively poor inter-voice cache locality. If many active
voices read nearby samples inside the same cache line, the current one-line cache
can do better. If active voices walk unrelated sample regions, especially linked
stereo left/right regions, the cache line is frequently replaced and the estimate
approaches the conservative numbers above.

### SF2/MIDI Access-Span Result

The static estimate above treats line misses pessimistically. On 2026-07-22,
`tools/analyze_sf2_access_span.py` was added to measure the address stream implied
by a real SF2/MIDI pair without running RTL or rendering audio. The tool expands
MIDI Note On events through the SF2 preset/instrument/sample tables, simulates
Q24.8 sample-frame advancement for each selected sample stream, and counts cache
line reuse and prefetch-window pressure.

The following workload was analyzed:

```bash
python3 tools/analyze_sf2_access_span.py \
  --sf2 "/home/yuan/下载/SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2" \
  --midi "/media/yuan/60AE34D2AE34A308/Users/yuan/Desktop/midi合集/Hedwigs_Themefinished.mid" \
  --sample-rate 48000 \
  --line-words <N> \
  --lookahead-ms 1,2,5,10
```

The full MIDI spans `264.044 s`, contains `13,855` Note On events, and expands to
`16,679` selected sample streams in this address-only model. `183` notes had no
matching SF2 regions under the simplified selection model. The maximum active
sample-stream count was `54`, with a p99 active-stream count of `38`.

Results by cache-line size:

| `LINE_WORDS` | Endpoint reads/s | Stream line fills/s | Physical lines/s | Endpoint/stream-line reuse | New stream lines/frame max | 10 ms stream-line p99/max |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 1,187,153.7 | 60,245.6 | 2,305.2 | 19.71 | 56 | 1,955 / 2,927 |
| 16 | 1,187,153.7 | 30,152.4 | 1,152.8 | 39.37 | 54 | 977 / 1,465 |
| 32 | 1,187,153.7 | 15,105.6 | 576.6 | 78.59 | 54 | 489 / 735 |
| 64 | 1,187,153.7 | 7,587.6 | 288.5 | 156.46 | 54 | 246 / 370 |

Interpretation:

- The access pattern is still random at the DDR line level, but it is highly
  predictable and has strong line reuse inside each sample stream.
- Increasing line size from 8 to 32 words cuts stream-local line fills by about
  `4x` for this workload. Increasing from 32 to 64 words cuts them by another
  `2x`, at the cost of larger fills and potentially more wasted bandwidth on
  less sequential workloads.
- The `physical lines/s` count is far lower than the per-stream fill count
  because many notes reuse the same sample regions. Physical uniqueness is not a
  direct replacement for per-stream cache sizing, but it shows that the SF2
  working set is concentrated.
- A 10 ms lookahead window with `LINE_WORDS = 32` sees p99 `489` and max `735`
  newly needed stream-local lines. With `LINE_WORDS = 64`, the p99/max drops to
  `246`/`370`. These numbers are more useful for sizing prefetch queues and
  outstanding line-fill tracking than the average fills/s alone.
- For `LINE_WORDS = 32`, phase-driven source stride averaged `0.889` source
  frames per output frame, with p95 `1.375` and max `3.570`. The estimated
  32-word line dwell was average `39.19` output frames, p50 `34.86`, and minimum
  `8.96`. This suggests normal notes have enough lead time for prefetch, while
  the fastest notes still require demand-priority fallback and enough outstanding
  line-fill capacity.

This supports the memory-side optimization direction: a larger line size plus
voice- or stream-aware cache and stride prefetch can exploit real SF2/MIDI
locality. It does not by itself prove that DDR bandwidth is sufficient, because
the final RTL still needs concrete cache replacement, arbitration, outstanding
fill, and audio FIFO behavior.

### Result

At `100 MHz` core clock and `48 kHz` output:

- RTL arithmetic and current scheduler structure are not the first blocker for
  256 configured voices when memory is ideal.
- The current one-line, one-outstanding memory adapter is the practical limiter.
- A safe current design target is roughly 60 stereo voices or roughly 120 mono
  voices before a wider, more voice-aware memory subsystem is added.
- Stable 256-voice stereo playback requires memory-side architecture work:
  per-voice or set-associative line caching, stride-aware prefetch, larger DDR
  burst lines, multiple outstanding requests, or tagged/reordered endpoint
  assembly.

## Voice-Count Scaling

The following measurements used the same workload for each build:

```bash
make clean && make render-rtl-core NUM_VOICES=<N> \
  SF2="/home/yuan/下载/MS_Basic.sf2" \
  MIDI=assets/midi/dense_many_notes.mid \
  SECONDS=5
```

The MIDI/SF2 workload reached 12 simultaneous enabled filtered voices. Builds
with fewer configured voices use voice stealing earlier, so their audio behavior
is not identical to the 16- and 32-voice builds even though each run still matches
the C++ reference for that configured voice count.

| `NUM_VOICES` | Avg Render Cycles | Max Render Cycles | Avg Reads/Sample | Max Reads/Sample | Max Enabled Voices | Max Filtered Voices |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 4 | 20.92 | 38 | 3.73 | 8 | 4 | 4 |
| 8 | 28.54 | 74 | 4.64 | 16 | 8 | 8 |
| 16 | 38.47 | 114 | 5.12 | 24 | 12 | 12 |
| 32 | 54.47 | 130 | 5.12 | 24 | 12 | 12 |

These measurements predate the current area-oriented active-slot scanner. At that
time the 16- and 32-voice builds had the same maximum active
workload for this MIDI, but the 32-voice build still spent more cycles because
the scheduler scanned every configured voice slot, including empty slots. The
current scheduler uses `config_valid` to skip invalid slots, so these numbers are
historical baseline data rather than current throughput measurements. Re-run the
same `render-rtl-core` commands after throughput changes before using this table for
new cycle comparisons.

## Limitations

This is not yet a fully streaming multi-frame audio engine. It is a throughput
pipeline only within one output frame and only after complete endpoint samples are
available. Therefore:

- It can overlap DSP execution for voice `N` with scanning and endpoint fetch for
  voice `N + 1`.
- It can retire one DSP result per cycle when the DSP pipe is full.
- It does not overlap frame `N + 1` with frame `N`; `DRAIN` must complete first.
- It does not add tags to the external memory response path; responses are matched
  to accepted requests in order.

In the current architecture, memory traffic remains the major throughput limiter.
Mono interpolation needs two sample reads per active voice, and stereo
interpolation needs four sample reads per active voice. The internal word-request
FIFO and fetch slots can hide some latency, but without a wider memory path,
tagged/out-of-order responses, or a cache that can return both endpoints
efficiently, DSP pipelining alone cannot remove that bottleneck.

## Future Work

The fetch/compute split now exists inside `multi_voice_pipeline` and
`voice_dsp_pipeline`:

```text
voice scheduler
  -> voice_phase_frame
  -> word-request queue
  -> in-order response metadata and fetch slots
  -> DSP context queue
  -> DSP pipeline with valid/voice_index/config snapshot
  -> ordered mixer/writeback stage
```

That design lets the memory subsystem fetch endpoints for later voices while the
DSP pipeline processes earlier voices. The context records carry enough
information to decouple computation from live register-array reads:

- `voice_index`
- stereo/mono mode
- interpolation fraction
- gain and envelope values
- filter enable and coefficients
- loop and phase-derived endpoint frame addresses
- captured filter state or a controlled filter-state read/write slot

The mixer/writeback stage updates the correct accumulator and filter state when
the context completes. If responses can return out of order in a future memory
system, the token and reorder policy must make output accumulation deterministic.

Potential next steps, in increasing complexity:

1. Add focused throughput counters for issued contexts, retired contexts,
   DSP-stage occupancy, invalid-slot scan cycles, memory stalls, and per-frame
   render latency.
2. Add endpoint-fetch observability inside `voice_endpoint_fetch`: word-request
   queue depth, response-metadata occupancy, fetch-slot pressure, DSP context
   queue occupancy, context push/pop counts, and cycles where DSP is ready but no
   complete context is available.
3. Add cache-policy counters before changing the cache: demand hit/miss counts,
   same-line endpoint reuse, cross-line endpoint pairs, prefetch issued/used/drop
   counts, line-fill count, external request count, response latency, deadline
   misses, and output FIFO underruns.
4. Carry explicit locality into the memory path. The first version can add
   `voice_id` and channel metadata to internal endpoint/cache requests while
   keeping the external core-side word-response behavior ordered. If that creates
   too much interface churn, place the optimized cache inside or adjacent to
   `voice_endpoint_fetch`, where `voice_index`, stereo mode, endpoint frames,
   phase increment, and loop context are already visible.
5. Replace the global one-line cache with a per-voice cache. Each active voice
   should have at least two cached lines for the left/mono stream so `L0` and
   `L1` can cross a line boundary without evicting the current line. Stereo
   voices need independent left/right stream tags because linked SF2 samples are
   usually stored in separate regions.
6. Add demand-priority stride prefetch. After the current endpoint frames and
   next phase are known, prefetch the line or lines for the next output frame.
   Suppress redundant prefetches, handle loop-wrap targets, and stop prefetching
   no-loop or released voices as they approach completion. Demand reads must
   always outrank speculative prefetches.
7. Sweep larger DDR line sizes, such as 16 or 32 words, only after the per-voice
   cache and prefetch counters exist. Larger lines can amortize DDR command
   overhead but waste bandwidth when many voices read unrelated regions.
8. Add multiple outstanding line fills when cache misses or prefetches still
   leave the DSP context queue empty. Track each fill with request metadata so
   returning lines update the correct voice/channel cache entry and wake any
   waiting endpoint slot.
9. Add tagged or reordered endpoint assembly only if in-order responses remain
   the measured limiter. A tagged response should identify the fetch slot and
   endpoint kind directly so out-of-order DDR returns can fill endpoint RAMs
   without changing deterministic mix order.

## Throughput Plan Status

The older standalone throughput plan has been folded into this document. The
current RTL has already completed the low-risk pipeline phases:

1. Extracted `voice_dsp_pipeline` from the old in-module compute states.
2. Added fixed-latency valid/context propagation inside `voice_dsp_pipeline`.
3. Split issue from retire inside `multi_voice_pipeline`; `DRAIN` waits for all
   outstanding contexts before `FINISH` emits `sample_valid`.
4. Added area-oriented active-slot scanning using `config_valid`.
5. Added an in-order DSP context queue at the endpoint boundary.
6. Added a word-request FIFO and in-order endpoint assembly slots while preserving
   the one-word ordered memory contract.
7. Mapped internal fetch/context payload storage to distributed RAM where Vivado
   can infer it.
8. Extracted the phase, loop, done, endpoint-frame, fraction, and next-phase
   algorithm into `voice_phase_frame`, leaving `multi_voice_pipeline` focused on
   scheduling, queues, memory request/response assembly, phase RAM writeback, and
   retire.
9. Extracted endpoint request FIFOing, ordered response metadata, fetch slots,
   mono duplication, and the DSP context queue into `voice_endpoint_fetch`.
   `multi_voice_pipeline` now issues one endpoint context through a
   ready/valid boundary and waits for the fetch engine to drain before finishing
   a sample frame.

Remaining throughput work should be measurement-driven:

1. Establish the render, queue, cache, memory-stall, deadline, and underrun
   counters listed above.
2. Preserve the current ordered word-response contract for the first optimized
   cache pass where practical, but carry `voice_id` and channel locality inside
   the endpoint/cache path.
3. Implement per-voice two-line cache state before adding speculative behavior.
4. Add stride-aware prefetch with demand priority once cache hit/miss behavior is
   visible.
5. Sweep `LINE_WORDS = 16` and `LINE_WORDS = 32` against representative
   mono/stereo MIDI/SF2 renders.
6. Add multiple outstanding line fills and tagged endpoint assembly only after
   measured queue occupancy shows that the ordered single-fill path is the
   remaining blocker for the 256-stereo target.

Focused tests should still compare exact integer output and cover consecutive
active voices, disabled-voice bubbles, interleaved mono/stereo voices,
filter-state writeback to the correct voice, phase/loop behavior with overlapped
DSP execution, memory stalls before DSP issue, deterministic accumulator ordering,
single `sample_valid` emission per frame, and reset while valid contexts are in
flight.

## Resource Optimization Notes

The first Artix-7 resource pass removed the full per-frame `voice_config` and
`voice_runtime` array copies from this module. A later pass changed playback to
Q24.8 phase, widened sample-region length and loop points to 24 bits, narrowed
per-voice biquad `z1/z2` state to signed 34 bits, split shadow and active
configuration structs, and removed the duplicate pending runtime-state array.
With the Smart Artix MIG synthesis wrapper, that reduced post-synthesis register
use to about `39013 / 65200` registers, but LUT use rose to about
`26475 / 32600` LUTs. Remaining resource pressure was concentrated in the
control-state storage and large per-voice mux networks in `voice_register_bank`.

The first voice-bank storage pass changed the renderer-facing interface from
whole-array exports to an indexed read port. `multi_voice_pipeline` drives
`voice_read_index`, and `voice_register_bank` returns only `render_config` and
`render_runtime` for that voice. The intermediate implementation kept the
selected read combinational and split shadow, active, and runtime fields into
per-field arrays with distributed-RAM synthesis attributes. That removed the
cross-module exposure of full active/runtime tables but did not infer RAM for the
wide selected fields.

Post-synthesis check on Vivado 2018.3 for Smart Artix (`xc7a50tfgg484-2`) showed
that this combinational-read version did not materially reduce the board resource
pressure. The earlier 2026-07-13 synthesis run reported `26503 / 32600` slice
LUTs, `39017 / 65200` slice registers, `565` LUTs as memory, and `26 / 120` DSPs.
The final distributed-RAM mapping report only identified the output FIFO RAMs,
not the wide `voice_register_bank` fields.

The next passes introduced reusable synchronous RAM templates and moved the
host-visible and renderer-facing voice-bank groups behind explicit store
modules:

- `descriptor_ram`: `NUM_VOICES x 32 words x 32-bit` host-visible descriptor
  mirror.
- `active_config_ram`: `NUM_VOICES x 244` committed active voice configuration.
- `runtime_phase_ram`: `NUM_VOICES x 32` runtime phase increments with independent
  renderer and bus-inspection read ports.
- `runtime_gain_ram`: `NUM_VOICES x 32` packed runtime left/right gains with independent
  renderer and bus-inspection read ports.
- `runtime_envelope_ram`: `NUM_VOICES x 16` runtime envelope levels with independent
  renderer and bus-inspection read ports.
- `runtime_filter_ram`: `NUM_VOICES x 80` runtime filter coefficients.

`VOICE_CONTROL.apply` now writes the selected active-config BRAM entry directly
and also copies the shadow filter coefficient group into runtime filter BRAM for
new-note setup.
For active voices, `FILTER_A2[16]` commits the complete shadow filter group
to runtime filter BRAM as one packed `80` bit word, avoiding mixed old/new IIR
coefficients. The frame-boundary pulse is still used by the renderer to reload
phase and clear filter history on voice commit, but the active config storage
itself no longer needs a multi-voice frame-boundary copy. Per-voice
configuration and runtime scalar state now reads back through the normal
per-voice register addresses. These reads use the synchronous RAM read paths and
therefore complete as multi-cycle bus transactions, avoiding a large
combinational per-field readback mux on the main register path.

Vivado 2018.3 recognizes the active, shadow, runtime filter, and runtime scalar
storage as RAM templates. The latest recorded Smart Artix synthesis run before
the grouped-descriptor split reports
`9891 / 32600` slice LUTs, `13373 / 65200` slice registers, `565` LUTs as
memory, `9 / 75` Block RAM tiles, and `26 / 120` DSPs. Post-synthesis timing is still not closed with WNS
`-10.650 ns`, so this storage change fixes the major voice-bank resource pressure
but not the remaining DSP/timing architecture. The grouped descriptor and active
runtime store split should be re-measured in the next Smart Artix synthesis pass.

The area-oriented renderer pass replaces the combinational next-valid-voice
search with sequential slot scanning, moves per-voice phase into a `32 x 32`
distributed RAM for a 32-voice build, and moves per-voice biquad history into
four `32 x 34`
distributed RAMs plus valid bitmaps. This trades extra clocks for invalid voice
slots and RAM-read staging for a much smaller voice renderer. The Smart Artix
Vivado 2025.2 post-synthesis run reports `8272 / 32600` slice LUTs, `7882 /
65200` slice registers, `628` LUTs as distributed RAM, `9 / 75` Block RAM tiles,
and `26 / 120` DSPs. The core `ui_clk` timing group remains clean, while the
overall post-synthesis summary still includes MIG/DDR PHY timing violations.

Recommended next optimization order:

1. Consider whether runtime release and filter-enable bits are worth moving out
   of flip-flops. They are only one bit per voice, so the likely win is small
   compared with the extra read-modify-write and readback complexity.
2. If the product can afford lower filter throughput, consider sharing one
   set of biquad calculation stages between left and right channels. This is the next large DSP
   reduction, but it requires scheduler changes because one voice would occupy
   the filter calculation stages for more cycles.
3. Keep the SF2 biquad filter feature in the generic core, but consider a board
   build option only if a product image explicitly does not need it. The default
   architecture should continue to support the documented filter registers.
4. Run full implementation before treating remaining post-synthesis timing as the
   final bottleneck. After real pins, clocking, and implementation reports are
   available, add focused pipeline stages on the reported multiply/accumulate
   paths instead of changing constraints to hide them.

Do not merge these optimizations with external register-map or output-contract
changes unless the matching documentation and tests are updated in the same
change.
