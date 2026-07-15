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
- Wave memory still uses the existing one-request-at-a-time ready/valid read
  interface.
- `sample_valid` still marks the completed mixed stereo output sample.

## Voice Count Configuration

The default build uses 32 voices. Simulation builds can override the voice count
from `make`:

```bash
make render-quick NUM_VOICES=8 MIDI=assets/midi/dense_many_notes.mid SECONDS=5
make render-quick NUM_VOICES=16 MIDI=assets/midi/dense_many_notes.mid SECONDS=5
make render-quick NUM_VOICES=32 MIDI=assets/midi/dense_many_notes.mid SECONDS=5
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
  -> channel gain
  -> envelope gain or full-level bypass
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
the external `sample_tick`/`sample_valid` contract and the one-request-at-a-time
memory interface, but it separates these internal concerns:

```text
active-slot scheduler and register snapshot
  -> next-valid voice prefetch during endpoint fetch
  -> endpoint fetch FSM
  -> fixed-latency voice_dsp_pipeline
  -> retire accumulator and filter-state writeback
  -> DRAIN
  -> FINISH
```

The scheduler issues at most one complete voice context into DSP per cycle. The
DSP pipeline can accept back-to-back contexts, and the retire path can consume one
result per cycle. In practice, the endpoint fetch FSM usually feeds the DSP pipe
more slowly because mono interpolation still needs two memory responses and stereo
interpolation needs four.

The renderer now overlaps work inside a single output frame:

- After a voice's endpoints are assembled, `DSP_START` presents a complete
  immutable `voice_dsp_context_t` to `voice_dsp_pipeline`.
- While the current voice fetches endpoints, a single-entry prefetch scanner may
  advance `render_index` to the next valid voice and let the synchronous
  register-bank and local phase/filter RAM outputs settle early.
- If that prefetch is ready at `DSP_START`, the front end jumps directly to the
  next voice's `START_VOICE` instead of paying `SCAN_VOICE`, `READ_VOICE`, and
  `WAIT_VOICE` after the DSP issue cycle.
- The front end continues scanning and fetching later voices instead of waiting
  for the issued voice to finish DSP.
- DSP results return later on `dsp_valid`; the retire path updates the stereo
  accumulator and writes the result voice's filter state.
- `DRAIN` waits until all issued contexts have retired before final mix
  saturation in `FINISH`.

Only one output frame is in flight. The next `sample_tick` is accepted only after
the prior frame has drained and `sample_valid` has been emitted. This keeps phase,
filter-state, and accumulator ownership simple.

This should not be read as a CPU-style global N-stage pipeline. The renderer has
two different timing domains inside one clock domain:

- The outer voice-render front end is an FSM with variable latency. It scans voice
  slots, waits for synchronous register-bank reads, issues one wave-memory request
  at a time, and assembles interpolation endpoints. It also has a single-entry
  next-valid prefetch path that can prepare one later voice's register outputs
  while the current voice is fetching endpoints.
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
  fetch L0/L1[/R0/R1] endpoints
  package voice_dsp_context_t
  |
  v
fixed-latency 5-stage DSP pipe
  interpolate
  filter products
  filter output
  filter state
  gain/envelope
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
does not guarantee one voice per cycle because endpoint fetch is still serialized
through the existing memory interface. The front end can overlap later voice
register prefetch and endpoint fetch with earlier DSP work, but bubbles are
expected when memory sequencing cannot supply a complete context every cycle.

The current control flow for one output frame is:

```text
sample_tick
   |
   v
+--------+
|  IDLE  |
+--------+
   |
   v
+-------------+      invalid slot
| SCAN_VOICE  |--------------------+
+-------------+                    |
   | valid slot                    |
   v                               |
+-------------+                    |
| READ_VOICE  |  set render_index  |
+-------------+                    |
   |                               |
   v                               |
+-------------+                    |
| WAIT_VOICE  |  sync RAM outputs  |
+-------------+                    |
   |                               |
   v                               |
+-------------+
| START_VOICE |  snapshot config/runtime/phase/filter state
+-------------+
   |
   v
+---------------+
| PROCESS_VOICE |
+---------------+
   | disabled/done
   |------------------------------+
   | enabled                      |
   v                              |
+--------+    +---------+          |
| REQ_L0 | -> | WAIT_L0 |          |
+--------+    +---------+          |
                 |                 |
                 v                 |
+--------+    +---------+          |
| REQ_L1 | -> | WAIT_L1 |          |
+--------+    +---------+          |
                 | mono            |
                 |-------------------------+
                 | stereo                  |
                 v                         |
+--------+    +---------+                  |
| REQ_R0 | -> | WAIT_R0 |                  |
+--------+    +---------+                  |
                 |                         |
                 v                         |
+--------+    +---------+                  |
| REQ_R1 | -> | WAIT_R1 |                  |
+--------+    +---------+                  |
                 |                         |
                 +-----------+-------------+
                             |
                             v
                      +-------------+
                      |  DSP_START  | issue context
                      +-------------+
                             |
                             v
                      +-------------+
                      | next voice? |
                      +-------------+
                  | prefetched     | scan needed       | no more
                  v                v                   v
             +-------------+  +------------+        +--------+
             | START_VOICE |  | SCAN_VOICE |        | DRAIN  |
             +-------------+  +------------+        +--------+
                                                        |
                                                        v
                                                     +--------+
                                                     | FINISH |
                                                     +--------+
                                                        |
                                                        v
                                                  sample_valid
```

A typical overlap inside one output frame looks like this:

```text
cycle:        N        N+1      N+2      N+3      N+4      N+5      N+6

front end:    fetch V0  fetch V0  issue V0 start V1 fetch V1 fetch V1 issue V1
prefetch:     scan V1   read V1   ready

DSP pipe:                         V0 S0    V0 S1    V0 S2    V0 S3    V0 S4

retire:                                                                  V0 result
```

This overlap hides the fixed DSP latency behind later front-end work, but it does
not make the memory fetch path itself a one-voice-per-cycle pipeline. The current
prefetch removes much of the register-read bubble between adjacent valid voices;
a fuller CPU-like render pipeline would still need separate front-end stages or
queues for slot scan, endpoint request/response assembly, DSP issue, and retire,
plus enough memory bandwidth or tagging to keep those stages fed.

## Pipeline Stages

One `sample_tick` starts one complete output-frame render. The pipeline selects
valid voice slots in increasing index order, skipping invalid entries through the
`config_valid` active-slot mask, then emits one mixed stereo sample in `FINISH`.

Current front-end state sequence:

| Stage | Purpose | Main registered outputs |
| --- | --- | --- |
| `IDLE` | Wait for `sample_tick`. | Clears `accum_l/r`, latches `config_commit`, finds the first valid voice slot, and presents its render read index. |
| `READ_VOICE` | Give the register bank a stable `voice_read_index`. | Starts the conservative synchronous render-read sequence. |
| `WAIT_VOICE` | Wait for RAM-backed fields to reach the register-bank render outputs. | Holds the selected read index before context capture. |
| `START_VOICE` | Snapshot render config/runtime for the selected voice. | `current_*` config snapshot and current phase snapshot. |
| `PROCESS_VOICE` | Skip disabled/done voices or derive endpoint frames and advance phase. | `frame_0`, `frame_1`, `fraction`, updated phase writeback. |
| `REQ_L0` | Issue left or mono endpoint-0 memory request. | Memory request address for `frame_0`. |
| `WAIT_L0` | Wait for endpoint-0 response. | `raw_l0`. |
| `REQ_L1` | Issue left or mono endpoint-1 memory request. | Memory request address for `frame_1`. |
| `WAIT_L1` | Wait for endpoint-1 response. For mono, duplicate left samples into right raw registers. | `raw_l1`; mono also sets `raw_r0/raw_r1`. |
| `REQ_R0` | Stereo only: issue right endpoint-0 memory request. | Memory request address for right `frame_0`. |
| `WAIT_R0` | Stereo only: wait for right endpoint-0 response. | `raw_r0`. |
| `REQ_R1` | Stereo only: issue right endpoint-1 memory request. | Memory request address for right `frame_1`. |
| `WAIT_R1` | Stereo only: wait for right endpoint-1 response. | `raw_r1`. |
| `DSP_START` | Issue a complete `voice_dsp_context_t` to the DSP pipe. | Increments outstanding context count and either starts a prefetched next voice, falls back to scanning, or advances to `DRAIN`. |
| `DRAIN` | Wait for issued DSP contexts to retire. | Holds until outstanding count reaches zero. |
| `FINISH` | Saturate the 32-bit stereo accumulators to signed 16-bit PCM. | `sample_l/r`, `sample_valid`. |

Disabled and completed voices skip from `PROCESS_VOICE` to the next active slot
or to `DRAIN`. Invalid slots are not selected by the active-slot scanner. For
enabled mono voices, `REQ_R0`, `WAIT_R0`, `REQ_R1`, and `WAIT_R1` are skipped
because `WAIT_L1` duplicates the mono raw samples into the right-channel raw
registers.

## DSP Pipeline Stages

`rtl/dsp/voice_dsp_pipeline.sv` owns pure per-voice sample math. It has an
explicit `valid_i`/`valid_o` contract and no side effects on phase, filter state
arrays, or the frame accumulator. Every stage carries enough immutable context to
retire the result for the correct voice.

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
| `S2_FILTER_Y` | Compute `y = b0*x + z1`, saturate to PCM, and preserve feed-forward products for feedback state. | Saturated `y`, bypass sample, feedback inputs. |
| `S3_FILTER_STATE` | Compute and saturate next `z1/z2`; select filtered or bypass sample for gain. | Next filter state, selected post-filter sample, gain/envelope context. |
| `S4_GAIN` | Apply left/right channel gain. | Gained samples and next filter state. |
| Output | Apply envelope or full-level bypass and emit `voice_dsp_result_t`. | Voice index, filter enable, next filter state, final contribution. |

The DSP pipe can accept a new complete context every cycle when the front end can
provide one. With the current memory interface it normally sees bubbles, but the
valid-shift structure is already in place for a future endpoint queue.

## Issue, Retire, And Drain

`multi_voice_pipeline` tracks issued-but-not-retired contexts with
`outstanding_count`. `DSP_START` adds one outstanding context and `dsp_valid`
subtracts one. The retire path is independent of the front-end state machine:

```text
if dsp_valid:
  if result.filter_enable:
    filter_z*[result.voice_index] <= result.next_z*
  accum_l/r <= accum_l/r + result.contribution_l/r
```

Because endpoint fetch remains in order and the DSP pipe is fixed latency,
results retire in issue order. The accumulator is shared for one output frame, so
`DRAIN` must observe `outstanding_count == 0` before `FINISH` saturates the final
PCM output.

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

`wavetable_core` only asserts the frame-boundary input when `sample_tick` arrives
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

Configuration writes still update shadow state. `COMMIT` writes the selected
shadow entry into active configuration storage immediately and stages a
frame-boundary reload/clear pulse for the renderer. Runtime writes such as
envelope, gain, pitch, release, and runtime filter updates do not reload phase.
The `START_VOICE` capture defines the per-voice render context for the in-flight
output sample.

## Filter State Handling

Biquad state is stored as signed 48-bit values per voice and per channel:

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

Enabled voices no longer block the front end while they traverse DSP. Once
endpoints are available, `DSP_START` issues the context and the scheduler moves on
to the next selected voice. The fixed-latency DSP pipe then retires the result in
parallel with later voice fetch work. The remaining per-voice bottleneck is memory
endpoint assembly: mono voices need two memory responses and stereo voices need
four.

The single-entry next-valid prefetch reduces the register-read bubble between
adjacent valid voices when endpoint fetch takes long enough to hide the
prefetch-read latency. On the 30-second Hedwig/MS_Basic quick-render workload, the
measured 32-voice render cost changed from `250.278` average and `375` maximum
cycles per sample to `195.729` average and `282` maximum cycles per sample, with
the same `32` maximum enabled and filtered voices and exact C++ reference audio
match.

The regression latency guard for the 32-voice mono render case remains
`600 + NUM_VOICES` cycles. This is a structural regression limit, not a
board-level real-time deadline. It allows the fixed DSP pipeline, synchronous
register-bank reads, and memory handshakes while still catching accidental large
latency regressions.

## Timing Benefit

For filtered voices, the long DSP calculation is now split across
`voice_dsp_pipeline` stages:

- interpolation is separated from filter coefficient multiplication,
- feed-forward multiplication, output saturation, feedback multiplication, and
  next-state saturation occupy separate pipeline stages,
- channel gain is isolated from envelope scaling,
- envelope scaling and final contribution generation happen at the DSP output,
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
- Channel gain and envelope gain still use signed Q1.15 multiplication and the
  same saturation behavior.
- `0x7fff` envelope level still bypasses envelope multiplication.
- Filter coefficients remain signed Q4.28 and use the same transposed direct-form
  II equation.
- Filter state is cleared on voice commit and is not updated for disabled filter
  voices.
- Mono samples are still duplicated before independent left/right gain.
- Stereo samples are fetched from independent absolute left/right sample regions.
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
output, multi-voice mixing, and the 32-voice latency bound.

The lint run still reports existing non-fatal warnings such as unused parameters,
unused low product bits in interpolation, and testbench blocking-clock assignment
warnings. No fatal lint or simulation failures remain.

## Cycle Accounting

`render-quick` records RTL cycle counts in
`build/render_quick/quick_render_config.json` after a successful render. These
fields are intended for architecture comparisons and regression tracking:

| Field | Meaning |
| --- | --- |
| `rtl_total_cycles` | Total `QuickRtlHarness::tick()` cycles from reset through the completed quick render, including reset, register writes, envelope updates, memory handshakes, and sample rendering. |
| `rtl_total_memory_reads` | Total wave-memory word reads accepted by the quick harness during the full run. |
| `rtl_render_cycles_sum` | Sum of per-output-sample render cycles measured from the `sample_tick` cycle through the cycle where `sample_valid` is observed. |
| `rtl_avg_render_cycles` | `rtl_render_cycles_sum / output_samples`. |
| `rtl_max_render_cycles` | Maximum per-output-sample render latency observed during the quick render. |
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
the current abstract one-cycle memory response model used by `render-quick`. They
are cycle counts, not absolute time. Converting them into real-time margin still
requires a target system clock and the final memory profile.

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

## Voice-Count Scaling

The following measurements used the same workload for each build:

```bash
make clean && make render-quick NUM_VOICES=<N> \
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
same `render-quick` commands after throughput changes before using this table for
new cycle comparisons.

## Limitations

This is not yet a fully streaming multi-frame audio engine. It is a throughput
pipeline only within one output frame and only after complete endpoint samples are
available. Therefore:

- It can overlap DSP execution for voice `N` with scanning and endpoint fetch for
  voice `N + 1`.
- It can retire one DSP result per cycle when the DSP pipe is full.
- It does not overlap frame `N + 1` with frame `N`; `DRAIN` must complete first.
- It does not change the one-outstanding-request memory interface.

In the current architecture, memory traffic remains the major throughput limiter.
Mono interpolation needs two sample reads per active voice, and stereo
interpolation needs four sample reads per active voice. Without prefetching,
multiple outstanding requests, a wider memory path, or a cache that can return
both endpoints efficiently, DSP pipelining alone cannot remove that bottleneck.

## Future Work

A higher-throughput renderer should separate fetch and compute with an explicit
voice token, for example:

```text
voice scheduler
  -> memory fetch queue
  -> endpoint response queue
  -> DSP pipeline with valid/voice_index/config snapshot
  -> ordered mixer/writeback stage
```

That design would allow the memory subsystem to fetch endpoints for later voices
while the DSP pipeline processes earlier voices. To do that safely, the token
must carry enough information to decouple computation from live register-array
reads:

- `voice_index`
- stereo/mono mode
- interpolation fraction
- gain and envelope values
- filter enable and coefficients
- loop and phase-derived endpoint frame addresses
- captured filter state or a controlled filter-state read/write slot

The mixer/writeback stage would then update the correct accumulator and filter
state when the token completes. If responses can return out of order in a future
memory system, the token and reorder policy must make output accumulation
deterministic.

Potential next steps, in increasing complexity:

1. Add focused throughput counters for issued contexts, retired contexts,
   DSP-stage occupancy, invalid-slot scan cycles, and memory stalls.
2. Add a small endpoint FIFO between memory fetch and DSP compute.
3. Decouple endpoint assembly from front-end state names so ready contexts can
   feed `voice_dsp_pipeline` whenever the pipe can accept them.
4. Rework the memory subsystem for paired endpoint reads or cache-line extraction
   that returns both interpolation endpoints for common sequential access.

## Resource Optimization Notes

The first Artix-7 resource pass removed the full per-frame `voice_config` and
`voice_runtime` array copies from this module. A later pass changed playback to
Q24.8 phase, widened sample-region length and loop points to 24 bits, narrowed
per-voice biquad `z1/z2` state to signed 48 bits, split shadow and active
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

The next passes introduced a reusable `voice_bram_1r1w` synchronous RAM template
and moved the two widest renderer-facing voice-bank groups into inferred Block
RAM:

- `active_config_ram`: `32 x 172` committed active voice configuration.
- `runtime_phase_ram`: `32 x 32` runtime phase increments with independent
  renderer and readback read ports.
- `runtime_gain_ram`: `32 x 32` packed runtime left/right gains with independent
  renderer and readback read ports.
- `runtime_envelope_ram`: `32 x 16` runtime envelope levels with independent
  renderer and readback read ports.
- `runtime_filter_ram`: `32 x 160` runtime filter coefficients.

`COMMIT` now writes the selected active-config BRAM entry directly and also copies
the shadow filter coefficient group into runtime filter BRAM for new-note setup.
For active voices, `FILTER_COMMIT[0]` commits the complete shadow filter group
to runtime filter BRAM as one packed `160` bit word, avoiding mixed old/new IIR
coefficients. The frame-boundary pulse is still used by the renderer to reload
phase and clear filter history on voice commit, but the active config storage
itself no longer needs a multi-voice frame-boundary copy. Per-voice
configuration/runtime readback data was also removed from the direct per-voice
register bus path; only `STATUS` and `VERSION` remain meaningful direct read
paths. Software inspection uses the staged `READBACK_ADDR`/`READBACK_DATA` window
instead of direct per-field reads, avoiding the large combinational readback mux
on the main register path.

Vivado 2018.3 recognizes the active, shadow, runtime filter, and runtime scalar
storage as RAM templates. The latest Smart Artix synthesis run reports
`9891 / 32600` slice LUTs, `13373 / 65200` slice registers, `565` LUTs as
memory, `9 / 75` Block RAM tiles, and `26 / 120` DSPs. Post-synthesis timing is still not closed with WNS
`-10.650 ns`, so this storage change fixes the major voice-bank resource pressure
but not the remaining DSP/timing architecture.

The area-oriented renderer pass replaces the combinational next-valid-voice
search with sequential slot scanning, moves per-voice phase into a `32 x 32`
distributed RAM, and moves per-voice biquad history into four `32 x 48`
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
   biquad datapath between left and right channels. This is the next large DSP
   reduction, but it requires scheduler changes because one voice would occupy
   the filter datapath for more cycles.
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
