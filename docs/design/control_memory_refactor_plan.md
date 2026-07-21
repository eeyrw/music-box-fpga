# Control And Memory Refactor Plan

This note records the destructive refactor direction for the wavetable synth
control plane and wave-memory subsystem. The project is still in a stage where
interface changes are acceptable when they make the core easier to control,
verify, and eventually synthesize on the board target.

## Current Decision

The per-voice register map must be directly readable. Control software should
not need a host-side mirror or a staged register-access readback window to recover or
inspect voice state.

The `READBACK_ADDR` and `READBACK_DATA` registers were removed from the core
register contract. Their former addresses are now unsupported core addresses and
must report a bus error when routed to `voice_register_bank`. System common
status registers begin at `0x9010`.

Per-voice reads use synchronous RAM read paths and therefore may complete after
multiple `clk` cycles. Register-bus and SPI masters must hold the request until
`bus_ready` is asserted.

## Problems Being Addressed

The previous register bank had three issues:

- Software-visible registers were write-dominant. Most per-voice direct reads
  returned zero, which made normal synthesizer control and hardware-state
  recovery awkward.
- Shadow, active, runtime, filter, release, and validity state were spread across
  one large module with several RAMs and bit arrays. The implementation saved
  some readback mux area, but the ownership boundaries were unclear.
- The staged readback window was a second access path with different semantics
  from the normal map. It was useful as a temporary area optimization, but it
  made the external contract harder to reason about.

The wave-memory subsystem has a separate scaling problem:

- `wave_memory_subsystem` currently has one global cached line and one
  outstanding core request.
- A polyphonic wavetable renderer interleaves many mostly sequential voice
  streams, so one global line is easily evicted by another voice.
- The current untagged word request interface hides voice locality from the
  memory adapter.

## Completed First Step

The first destructive step keeps the existing register offsets and render
algorithm but changes the read contract:

- Normal per-voice configuration reads return shadow register state.
- Runtime reads return live runtime scalar state for `ENVELOPE_RUNTIME`,
  `PHASE_INC_RUNTIME`, `GAIN_RUNTIME`, and `RELEASE_CONTROL`.
- `STATUS` returns active configuration validity.
- `VOICE_CONTROL[4]` and `FILTER_A2[16]` are write-only commit strobes and read
  as zero with their reserved bits.
- Unsupported addresses return a bus error.
- The SPI register-bridge test now checks direct per-voice readback and verifies
  that the old `0x3004` and `0x3008` addresses are rejected.

Verification after this step:

```bash
make lint
make test
```

Both commands passed. Existing lint warnings unrelated to this change remain.

## Completed Descriptor Store Split

The first ownership split moved host-visible shadow register storage and
software write-value normalization into `voice_descriptor_store`.
`voice_register_bank` still owns address decode, runtime routing, active storage,
and commit sequencing for now, but descriptor RAM access is now behind a named
module boundary.

Verification after this step:

```bash
make lint
make test
```

Both commands passed. Existing lint warnings unrelated to this change remain.

## Completed Voice Stride Repacking

The per-voice register stride is `0x80`. Slot 0 still starts at `0x0100`; slot N
starts at `0x0100 + N * 0x80`. This keeps all current offsets, through
`STATUS = 0x54`, inside each slot while allowing the default 256-voice build to
fit in the 16-bit register address space.

The RTL address decode, C++ harness constants, SystemVerilog tests, and
`docs/register_map.md` were updated together.

Verification after this step:

```bash
make lint
make test
```

Both commands passed. Existing lint warnings unrelated to this change remain.

## Completed Commit Engine Split

The voice and filter commit microsequencer was moved out of
`voice_register_bank` into `voice_commit_engine`. The register bank now starts a
commit, grants the descriptor-store read port to the commit engine while it is
busy, and consumes the engine's active/runtime/filter write pulses when the
decoded snapshot is ready.

The commit engine owns the 21-step voice commit walk, the 6-step filter commit
walk, descriptor field capture, loop/length validity calculation, runtime
initialization values, release clear on full voice commit, and filter enable /
coefficient apply.

Verification after this step:

```bash
make lint
make test
```

Both commands passed. Existing lint warnings unrelated to this change remain.

## Completed Descriptor Grouping And Store Split

The per-voice descriptor layout is grouped inside the `0x80` slot instead
of preserving the historical register order:

- `0x00` to `0x1c`: region descriptor.
- `0x20` to `0x2c`: playback setup, packed initial gain, and initial envelope.
- `0x30` to `0x40`: filter controls, coefficients, filter commit, and voice commit.
- `0x44` to `0x50`: runtime pitch, gain, envelope, and release flag.
- `0x54`: status.
- `0x58` to `0xff`: reserved.

`VOICE_CONTROL` owns stereo, loop policy, enable, and the voice commit strobe at
`0x40`.

The renderer-facing state is split out of `voice_register_bank`:

- `voice_active_store` owns committed static renderer configuration, active
  validity, pending commit bits, and render-boundary commit pulses.
- `voice_runtime_store` owns runtime pitch, runtime gain, envelope, release,
  filter enable, and filter coefficients. Runtime writes update this store
  without reloading phase.

`voice_register_bank` is reduced to address decode, global `VERSION`, bus
arbitration, and wiring between the descriptor, commit, active, and runtime
stores. The host-visible descriptor RAM remains the readable software mirror;
the active/runtime stores are arranged by renderer access pattern instead of by
software register order.

Verification after this step:

```bash
make lint
make test
```

Both commands passed. Existing lint warnings unrelated to this change remain.

## Target Control Architecture

The remaining control-plane refactor should keep shrinking normal control-state
ownership out of `voice_register_bank` and keep renderer-owned state near the
renderer.

Recommended modules:

- `voice_descriptor_store`
  - Owns host-visible per-voice register words.
  - Provides direct bus read/write access.
  - Stores the software descriptor or shadow state in a predictable 32-bit word
    layout.
  - Normal reads return what software wrote after field masking/sign extension.

- `voice_commit_engine`
  - Owns `VOICE_CONTROL[4]` and `FILTER_A2[16]` sequencing.
  - Reads a complete descriptor from `voice_descriptor_store`.
  - Validates length, stereo length, and loop boundaries.
  - Writes coherent active/runtime/filter snapshots.
  - Emits render-boundary commit pulses for phase reload and filter-history
    clear.

- `voice_active_store`
  - Owns renderer-facing committed static state: enable, stereo, base
    addresses, lengths, loop points, loop mode, and phase init.
  - Optimized for one renderer read by voice index.
  - Does not need to match software field order.
  - Implemented.

- `voice_runtime_store`
  - Owns live pitch, gain, envelope, release, filter enable, and filter
    coefficients.
  - Supports runtime bus writes without phase reload.
  - Supports direct bus reads and renderer reads without stealing the renderer
    port.
  - Implemented.

- `voice_render_state_store`
  - Belongs near `multi_voice_pipeline`, not the register bank.
  - Owns phase, right-channel phase, filter history, and per-voice internal valid
    bits.
  - Software access, if needed, should be explicitly status oriented rather
    than part of normal voice control.

This split keeps the software-visible control contract stable while allowing the
renderer-facing layout to be repacked for timing and resource use.

## Register Map Direction

The current per-voice stride is `0x80`. Current group layout inside each slot:

- `0x00` to `0x1c`: region descriptor.
- `0x20` to `0x2c`: playback setup, packed initial gain, and initial envelope.
- `0x30` to `0x40`: filter controls, coefficients, and voice commit.
- `0x44` to `0x50`: runtime pitch, gain, envelope, and release.
- `0x54`: status.
- `0x58` to `0xff`: reserved for future modulation/envelope controls and status registers.

## BRAM Strategy

Storage should be chosen by access pattern, not by historical field ownership.

Recommended direction:

- Keep a host-visible descriptor RAM as the one readable control mirror.
- Avoid one very wide small BRAM unless it improves timing after synthesis.
- Pack runtime scalar fields when they share access timing.
- Keep filter coefficients separate from scalar runtime state, because they are
  wide and lower update rate.
- Keep one-bit state such as release and filter-enable as bit vectors unless
  post-implementation data shows this is a problem.
- Keep renderer phase and filter history outside the control register bank.

Expected tradeoff: direct per-voice reads cost bus latency, not a large
combinational readback mux. That is acceptable because control reads are
low-rate compared with rendering.

## Target Wave-Memory Architecture

The current global one-line cache should remain only as a simple baseline.

The next memory subsystem should exploit the access pattern:

- Each active voice walks through one or two sequential sample streams.
- Mono needs two interpolation endpoints from one stream.
- Stereo needs two endpoints from each of two independent streams.
- Loop wrapping can make `frame_1` jump to `loop_start`.

Recommended first optimized design:

- Add `voice_id` to the core memory-request context, or move the cache into
  `voice_endpoint_fetch` where the current voice index and frame context are
  already known.
- Give each voice at least two small cached lines per channel stream: current
  line and next/prefetch line.
- Treat demand reads as higher priority than prefetches.
- Detect `L0`/`L1` same-line cases and satisfy both endpoints from one line fill.
- Track line tags separately for left and right linked-stereo streams.
- Preserve ordered word responses at the renderer boundary for the first pass,
  unless the endpoint-fetch interface is deliberately changed at the same time.

A more aggressive later interface can return endpoint pairs instead of single
words:

```text
voice_id, channel, base_addr, frame_0, frame_1, loop context -> sample_0, sample_1
```

That interface would simplify endpoint fetch and give the memory subsystem full
visibility into locality, but it is a larger contract change and should come
after the control-plane split is stable.

## Next Implementation Steps

1. Align the documented RTL ownership rules with the current tree.
   Add `rtl/memory` to the agent/developer ownership notes, keep the generic
   memory adapter policy-light, and keep board-specific memory controllers under
   `fpga/`.

2. Normalize the phase-format contract across documentation.
   The current RTL uses unsigned Q24.8 sample-frame phase and phase increments.
   Update any stale Q16.16 references before changing phase, loop, or pitch
   behavior.

3. Move renderer-owned state into a named store.
   Keep phase and filter history close to `multi_voice_pipeline`, and expose only
   explicit status reads if needed.

4. Split the frame scheduler from per-voice render state.
   Keep `multi_voice_pipeline` as a composition layer around the scheduler,
   phase/frame calculation, endpoint fetch, DSP pipeline, and mixer. The
   scheduler should own voice scanning, prefetch/read latency handling,
   outstanding-context accounting, and frame completion policy.

5. Extract reusable DSP arithmetic from `voice_dsp_pipeline`.
   Start with the biquad filter arithmetic and shared PCM/filter-state
   saturation helpers. Keep DSP primitives free of voice scanning, register
   decode, and memory-request policy.

6. Add module-level contract comments at the major boundaries.
   Document what `multi_voice_pipeline`, the new renderer state store, the
   scheduler, `voice_endpoint_fetch`, and `voice_dsp_pipeline` own and explicitly
   do not own.

7. Add focused tests before or alongside each split.
   Prioritize `tb_voice_endpoint_fetch`, `tb_voice_dsp_pipeline`, and a focused
   test for the new renderer-owned state store. Keep exact integer checks for
   interpolation, filter, gain, envelope, saturation, mono/stereo fetch order,
   commit reset behavior, and runtime updates that must not reload phase.

8. Re-run Smart Artix synthesis for the grouped descriptor and active/runtime
   store split.
   Record LUT, register, BRAM, DSP, and timing deltas against the previous
   voice-bank resource pass before making further area/timing claims.

9. Design the first per-voice wave cache.
   Add metrics before changing policy: demand hit/miss, prefetch hit, line fill
   count, external request count, response latency, render latency, deadline
   misses, and underruns.

10. Compare against the current memory baseline.
   Use `make render-memory` with the existing DDR, SDRAM, and parallel-NOR
   profiles. Require identical PCM output and better or clearly explained memory
   statistics before replacing the baseline.

## Required Tests

Control-plane tests:

- Direct readback for every per-voice configuration register.
- Direct readback for runtime envelope, phase increment, gain, and release.
- Unsupported old readback-window addresses report bus errors.
- Commit isolation: shadow writes do not affect active playback before commit.
- Commit atomicity: active snapshot never observes a partial descriptor.
- Runtime updates do not reload phase.
- Filter coefficient writes do not affect runtime filtering before a
  `FILTER_A2[16]` commit strobe.
- Reset returns status, runtime defaults, and descriptor defaults to documented
  values.

Memory tests:

- Mono same-line `L0`/`L1` endpoint fetch.
- Mono cross-line interpolation fetch.
- Stereo independent left/right cache lines.
- Loop-wrap endpoint fetch where `frame_1 == loop_start`.
- Backpressure from external line memory.
- Demand priority over prefetch.
- Flush/reset invalidates cache state.
- Full render output remains exact against existing reference tests.

## Open Decisions

- Whether active static fields should remain one packed wide RAM or split into
  narrower banks after synthesis data.
- Whether runtime filter enable should stay as a bit vector or be packed with
  scalar runtime state.
- Whether the first optimized memory cache should preserve the untagged ordered
  word-response contract or change the endpoint-fetch contract directly.
