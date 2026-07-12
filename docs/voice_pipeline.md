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

The current implementation uses the same registered compute stages for every
enabled voice. If the per-voice biquad filter is disabled, the `FILTER` stage
acts as a registered bypass from interpolation to gain. If the filter is enabled,
the same stage evaluates the biquad and captures the next filter state.

Compute path after endpoint fetch:

```text
WAIT_L1 or WAIT_R1
  -> INTERPOLATE
  -> FILTER
  -> GAIN
  -> ACCUMULATE
```

The added registers are local to `multi_voice_pipeline`:

- `interp_stage_l/r` capture the linear interpolation result.
- `gain_stage_input_l/r` capture the selected post-filter sample.
- `gained_stage_l/r` capture the channel-gain result.
- `filter_next_z1/z2_l/r` hold the next biquad state until the voice reaches
  `ACCUMULATE`; these registers are only committed to the per-voice state arrays
  when `current_filter_enable` is set.

The active `voice_index` is not advanced while a voice moves through these
stages. Because of that, the pipeline is currently a latency-splitting pipeline
inside one voice, not a throughput pipeline processing multiple voices at once.
This is intentional for the first step: it reduces the longest compute timing
paths without changing memory ordering, filter state ownership, or the external
sample contract.

## Pipeline Stages

One `sample_tick` starts one complete output-frame render. The pipeline scans
`voice_index` from zero through `NUM_VOICES - 1`, then emits one mixed stereo
sample in `FINISH`.

Current state sequence:

| Stage | Purpose | Main registered outputs |
| --- | --- | --- |
| `IDLE` | Wait for `sample_tick`. | Clears `accum_l/r`, selects voice 0, enters `START_VOICE`. |
| `START_VOICE` | Qualify the current voice, snapshot render config, calculate endpoint frame numbers, and advance phase. | `current_*` config snapshot, `frame_0`, `frame_1`, `fraction`, updated `phase[voice_index]`. |
| `REQ_L0` | Issue left or mono endpoint-0 memory request. | Memory request address for `frame_0`. |
| `WAIT_L0` | Wait for endpoint-0 response. | `raw_l0`. |
| `REQ_L1` | Issue left or mono endpoint-1 memory request. | Memory request address for `frame_1`. |
| `WAIT_L1` | Wait for endpoint-1 response. For mono, duplicate left samples into right raw registers. | `raw_l1`; mono also sets `raw_r0/raw_r1`. |
| `REQ_R0` | Stereo only: issue right endpoint-0 memory request. | Memory request address for right `frame_0`. |
| `WAIT_R0` | Stereo only: wait for right endpoint-0 response. | `raw_r0`. |
| `REQ_R1` | Stereo only: issue right endpoint-1 memory request. | Memory request address for right `frame_1`. |
| `WAIT_R1` | Stereo only: wait for right endpoint-1 response. | `raw_r1`. |
| `INTERPOLATE` | Evaluate left/right linear interpolation from raw endpoints and the captured fraction. | `interp_stage_l/r`. |
| `FILTER` | If enabled, evaluate biquad output and next state. If disabled, bypass interpolated samples. | `gain_stage_input_l/r`, `filter_next_z1/z2_l/r`. |
| `GAIN` | Apply left/right channel gain. | `gained_stage_l/r`. |
| `ACCUMULATE` | Apply envelope or full-level bypass, update filter state when enabled, and add the voice contribution into the stereo accumulator. | `accum_l/r`, optional `filter_z*_*[voice_index]`; advances to next voice or `FINISH`. |
| `FINISH` | Saturate the 32-bit stereo accumulators to signed 16-bit PCM. | `sample_l/r`, `sample_valid`. |

Disabled, invalid, and completed voices skip directly from `START_VOICE` to the
next voice or to `FINISH`. For enabled mono voices, `REQ_R0`, `WAIT_R0`,
`REQ_R1`, and `WAIT_R1` are skipped because `WAIT_L1` duplicates the mono raw
samples into the right-channel raw registers.

## Config Snapshot

At the start of each output sample render, the pipeline snapshots
`voice_config`, `voice_runtime`, and `config_valid` into frame-local arrays.
`START_VOICE` reads that snapshot to decide whether a voice is enabled, whether
it is valid, whether it is done, and which phase/frame addresses should be
rendered. Once a voice is accepted, the fields needed by later stages are copied
into local `current_*` registers:

- stereo/mono mode
- wave base address
- left and right channel gain
- envelope level
- filter enable
- filter coefficients

Memory request address generation and all DSP stages use these snapshot
registers. They no longer depend on live `voice_config` or `voice_runtime` reads
after the sample render has started. SPI or register-bus writes that arrive while
one output sample is being rendered therefore affect the next output sample
render rather than a partially scanned set of voices.

This does not change the external commit contract for configuration registers.
Configuration writes still update shadow state, commits still atomically copy
shadow state to active configuration, and a commit still reloads phase and clears
filter state at a render-safe idle boundary. Runtime writes such as envelope,
gain, pitch, release, and runtime filter updates do not reload phase. The
snapshot defines the per-voice render context for the in-flight output sample. It
is a prerequisite for a future token pipeline where `voice_index` may advance
before the previous voice has completed all compute stages.

## Filter State Handling

Biquad state is stored per voice and per channel:

```text
filter_z1_l[voice]
filter_z2_l[voice]
filter_z1_r[voice]
filter_z2_r[voice]
```

The `FILTER` stage computes the next state from the captured interpolation
result and current coefficients. It stores the computed next state in
`filter_next_*` registers. The actual per-voice filter state arrays are updated
only in `ACCUMULATE`, and only when `current_filter_enable` is set.

This preserves the rule that a voice's IIR state advances exactly once per
rendered output sample contribution. It also keeps filter state aligned with the
same `voice_index` that produced the interpolated sample.

## Latency Impact

All enabled voices add three deterministic compute cycles after endpoint fetch:
`INTERPOLATE`, `FILTER`, and `GAIN` before `ACCUMULATE`. The latency is hidden
behind the existing `sample_valid` completion handshake, and output sample values
remain numerically equivalent at the completed `sample_valid` boundary.

The regression latency guard for the 32-voice mono render case is now 400 cycles.
This is a structural regression limit, not a board-level real-time deadline. It
allows the fixed multi-stage compute pipeline while still catching accidental
large latency regressions in the scheduler or memory handshake. On the current
simulation memory model, the all-voice multi-stage path has been observed around
353 cycles for the 32-voice mono case.

## Timing Benefit

For filtered voices, the long DSP calculation is now split across stages:

- `INTERPOLATE` registers the interpolation result before it feeds the biquad.
- `FILTER` isolates the biquad calculation from gain and envelope scaling.
- `GAIN` isolates channel gain from envelope scaling and final accumulation.
- `ACCUMULATE` applies envelope/full-level bypass, updates filter state, and
  adds the final voice sample into the stereo mix accumulator.

This should improve Fmax for configurations where the biquad path is the critical
path. Exact Fmax improvement must be measured in the target FPGA synthesis flow;
Verilator lint and simulation only verify structural validity and behavior.

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

- More enabled voices increase scheduler and DSP-stage cycles.
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

The 16- and 32-voice builds have the same maximum active workload for this MIDI,
but the 32-voice build still spends more cycles because the current scheduler
scans every configured voice slot, including empty slots. This identifies active
voice scheduling, such as an active bitmap or active voice list, as a better next
cycle-reduction target than adding more compute-stage registers.

## Limitations

This is not yet a full streaming multi-voice pipeline. The state machine still
holds one `voice_index` until that voice has completed fetch, DSP evaluation, and
accumulation. Therefore:

- It reduces the filtered DSP critical path.
- It does not increase the number of voices completed per cycle.
- It does not overlap memory fetch for voice `N + 1` with DSP evaluation for
  voice `N`.
- It does not change the one-outstanding-request memory interface.

In the current architecture, memory traffic remains a major throughput limiter.
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

1. Move the biquad function into a dedicated registered DSP module with an
   explicit valid/ready or fixed-latency valid pipeline.
2. Add a small endpoint FIFO between memory fetch and DSP compute.
3. Allow the scheduler to request endpoints for the next voice while the current
   voice is in DSP stages.
4. Rework the memory subsystem for paired endpoint reads or cache-line extraction
   that returns both interpolation endpoints for common sequential access.
