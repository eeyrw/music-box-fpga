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
enabled voice. If the per-voice biquad filter is disabled, the filter stages act
as a registered bypass from interpolation to gain. If the filter is enabled, the
stages evaluate the biquad output, feedback products, and saturated next filter
state over multiple cycles.

Compute path after endpoint fetch:

```text
WAIT_L1 or WAIT_R1
  -> INTERPOLATE
  -> FILTER_INPUT
  -> FILTER_MUL_X
  -> FILTER_Y
  -> FILTER_MUL_Y
  -> FILTER_ACC
  -> GAIN
  -> ACCUMULATE
```

The added registers are local to `multi_voice_pipeline`:

- `interp_stage_l/r` capture the linear interpolation result and are preserved as
  explicit synthesis boundaries.
- `filter_input_l/r` capture the filter input sample so the interpolator output
  path is separated from the filter coefficient multipliers.
- `filter_b*_x_*`, `filter_a*_y_*`, and `filter_y_pcm_ext_*` capture biquad
  product and feedback inputs across the filter sub-states.
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
| `IDLE` | Wait for `sample_tick`. | Clears `accum_l/r`, selects voice 0, enters `READ_VOICE`. |
| `READ_VOICE` | Present `voice_read_index` to the register bank and runtime filter coefficient RAM. | Holds `voice_index` stable for synchronous storage reads. |
| `WAIT_VOICE` | Wait one cycle for synchronous RAM-backed fields to reach the register-bank render outputs. | Holds `voice_index` stable before `START_VOICE` samples `voice_config` and `voice_runtime`. |
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
| `FILTER_INPUT` | Register the interpolated sample before it feeds the filter coefficient multipliers. | `filter_input_l/r`. |
| `FILTER_MUL_X` | Multiply filter input by `b0`, `b1`, and `b2` and capture current filter state as sign-extended values. | `filter_b*_x_*`, `filter_z*_ext_*`. |
| `FILTER_Y` | Add `b0*x + z1`, saturate to PCM, and select filtered or bypass sample for gain. | `gain_stage_input_l/r`, `filter_y_pcm_ext_l/r`. |
| `FILTER_MUL_Y` | Multiply saturated filter output by feedback coefficients `a1` and `a2`. | `filter_a*_y_*`. |
| `FILTER_ACC` | Saturate the next biquad state from registered products. | `filter_next_z1/z2_l/r`. |
| `GAIN` | Apply left/right channel gain. | `gained_stage_l/r`. |
| `ACCUMULATE` | Apply envelope or full-level bypass, update filter state when enabled, and add the voice contribution into the stereo accumulator. | `accum_l/r`, optional `filter_z*_*[voice_index]`; advances to next voice or `FINISH`. |
| `FINISH` | Saturate the 32-bit stereo accumulators to signed 16-bit PCM. | `sample_l/r`, `sample_valid`. |

Disabled, invalid, and completed voices skip directly from `START_VOICE` to the
next voice or to `FINISH`. For enabled mono voices, `REQ_R0`, `WAIT_R0`,
`REQ_R1`, and `WAIT_R1` are skipped because `WAIT_L1` duplicates the mono raw
samples into the right-channel raw registers.

## Config Snapshot

The render pipeline drives a single `voice_read_index`, and the register bank
returns only that voice's active configuration and runtime control snapshot. The
scheduler uses `READ_VOICE` and `WAIT_VOICE` before `START_VOICE` so synchronous
BRAM-backed fields, including active configuration, runtime phase/gain/envelope,
and runtime filter coefficients, are stable before they are captured. `wavetable_core` only asserts
the frame-boundary input when `sample_tick` arrives while the pipeline is idle;
that boundary pulse reloads committed phase and clears filter history for voices
that were committed by the register bus. Runtime registers are live state and are
sampled when `START_VOICE` accepts each voice. The pipeline latches only the
per-frame commit bitmap; it does not receive or duplicate the full `voice_config`
and `voice_runtime` arrays.

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

Memory request address generation and all DSP stages use these per-voice
`current_*` registers. SPI or register-bus runtime writes that arrive while one
output sample is being rendered may affect voices that have not yet reached
`START_VOICE`; they do not affect a voice after its `current_*` registers have
been captured.

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

The filter sub-states compute the next state from the captured filter input and
current coefficients. `FILTER_MUL_X` captures the feed-forward products,
`FILTER_Y` derives the saturated output sample, `FILTER_MUL_Y` captures feedback
products, and `FILTER_ACC` stores the saturated next state in `filter_next_*`
registers. The actual per-voice filter state arrays are updated only in
`ACCUMULATE`, and only when `current_filter_enable` is set.

This preserves the rule that a voice's IIR state advances exactly once per
rendered output sample contribution. It also keeps filter state aligned with the
same `voice_index` that produced the interpolated sample.

## Latency Impact

All scanned voices spend two scheduler cycles in `READ_VOICE`/`WAIT_VOICE` before
`START_VOICE`, which allows synchronous RAM-backed register-bank fields to be
used without changing the external render contract. All enabled voices then add
seven deterministic compute cycles after endpoint fetch: `INTERPOLATE`, the five
filter sub-states, and `GAIN` before `ACCUMULATE`. The latency is hidden behind
the existing `sample_valid` completion handshake, and output sample values remain
numerically equivalent at the completed `sample_valid` boundary.

The regression latency guard for the 32-voice mono render case is now
`600 + NUM_VOICES` cycles. This is a structural regression limit, not a
board-level real-time deadline. It allows the fixed multi-stage compute pipeline
plus the synchronous register-bank read cycle while still catching accidental
large latency regressions in the scheduler or memory handshake. On the current
simulation memory model, the all-voice path has been observed around 545 cycles
for the 32-voice mono case.

## Timing Benefit

For filtered voices, the long DSP calculation is now split across stages:

- `INTERPOLATE` registers the interpolation result.
- `FILTER_INPUT` preserves a register boundary between interpolation and filter
  coefficient multiplication.
- `FILTER_MUL_X`, `FILTER_Y`, `FILTER_MUL_Y`, and `FILTER_ACC` split biquad
  feed-forward multiplication, output saturation, feedback multiplication, and
  next-state saturation.
- `GAIN` isolates channel gain from envelope scaling and final accumulation.
- `ACCUMULATE` applies envelope/full-level bypass, updates filter state, and
  adds the final voice sample into the stereo mix accumulator.

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

Recommended next optimization order:

1. Consider whether runtime release and filter-enable bits are worth moving out
   of flip-flops. They are only one bit per voice, so the likely win is small
   compared with the extra read-modify-write and readback complexity.
2. If the filter must stay enabled, move it to a multi-cycle shared DSP block.
   The current left/right biquad evaluation still expands many multiplies in one
   state. A fixed-latency filter unit with explicit valid timing should reduce
   combinational depth and make timing closure more predictable.
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
