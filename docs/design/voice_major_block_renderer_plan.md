# Voice-Major Block Renderer Plan

This document defines the implementation plan for replacing the current
single-frame, frame-major renderer with a voice-major block renderer. The new
renderer processes up to `MAX_BLOCK_FRAMES` consecutive frames for one voice,
accumulates each contribution into the corresponding block frame, and publishes
the completed frames as one block.

This work may intentionally replace internal renderer, control-state, memory,
and scheduling interfaces. The current renderer remains the exact behavioral
reference until the replacement passes the acceptance gates in this document.
The external PCM sequence and the documented fixed-point behavior remain the
initial compatibility boundary.

## Goals

- Read a voice descriptor and its working state once per block instead of once
  per output frame.
- Generate sequential wave-memory traffic by rendering consecutive frames from
  one voice before moving to the next voice.
- Accumulate `N` independent stereo results and publish them atomically after
  every active voice has contributed.
- Reduce active-bitmap scans, descriptor reads, and control snapshots by
  approximately the selected block length.
- Allow rendering, effects, compression, and output draining to overlap through
  explicit block-buffer ownership.
- Preserve exact phase, interpolation, loop, envelope, filter, gain, mixing,
  rounding, and saturation behavior.
- Apply control events at deterministic audio-frame boundaries, including
  boundaries that fall inside a nominal block.

## Non-Goals For The First Replacement

- Changing the signed 16-bit per-voice contribution contract.
- Adding per-voice chorus or reverb sends.
- Replacing the existing effects, compressor, PCM FIFO, or I2S arithmetic.
- Selecting the final cache geometry before board-equivalent measurements are
  available.
- Requiring a block to cross a scheduled event boundary.

## Initial Design Choices

- Prototype `MAX_BLOCK_FRAMES = 8` first and keep 16 as a compile-time
  comparison variant. Do not make block size a runtime protocol mode.
- Allow `frame_count` from 1 through `MAX_BLOCK_FRAMES` so the scheduler can
  stop at an event boundary or at available output capacity.
- Keep signed 32-bit left and right accumulators for every block frame and retain
  the current signed 24-bit final mix boundary.
- Publish a completed buffer descriptor rather than driving all block samples
  over one wide combinational bus. The descriptor contains `buffer_id`,
  `start_frame`, and `frame_count`; a synchronous read port drains the selected
  buffer in frame order.
- Use two accumulator/output banks. The renderer may fill one bank while the
  downstream block drain owns the other bank.
- Start with exact in-order processing for samples from one voice. Pipeline or
  parallelize endpoint and DSP work only after the sequential implementation is
  bit exact.
- Design endpoint collection and the shared line service together around block
  jobs. The current word-request fetcher and both current cache organizations
  are baselines only and are not migration constraints.
- Use line requests and job-associated completions at the new renderer boundary.
  Do not reconstruct line locality from a stream of individual word requests.

The initial block size is a prototype choice, not the final architecture
selection. Eight Smart Artix DDR words per MIG beat does not imply eight output
frames per render block: mono interpolation needs two endpoint words per frame,
stereo needs four, and phase increments need not be contiguous.

## Proposed Block Protocol

The renderer request identifies a contiguous range on the rendered audio
timeline:

```text
render block request
  valid
  ready
  start_frame
  frame_count       1..MAX_BLOCK_FRAMES
```

After every selected voice has retired, the renderer atomically transfers
ownership of the completed bank:

```text
render block complete
  valid
  ready
  buffer_id
  start_frame
  frame_count
```

The completion payload and every published sample must remain stable while
`valid` is asserted without `ready`. A downstream drain reads indices zero
through `frame_count - 1` and returns the bank only after the last frame is
accepted. Reset invalidates both banks and discards incomplete blocks.

`start_frame` is the timeline frame represented by accumulator index zero.
Accumulator index `k` always represents `start_frame + k`; response arrival
order must not change that association.

## Target Render Flow

```text
apply events at block start
  -> clear one accumulator bank
  -> traverse active voices once
  -> read one voice descriptor, parameters, and dynamic state
  -> render voice frame 0 into accumulator[0]
  -> render voice frame 1 into accumulator[1]
  -> ...
  -> render voice frame N-1 into accumulator[N-1]
  -> write the final phase, envelope, and filter state once
  -> select the next active voice
  -> drain outstanding endpoint and DSP work
  -> publish the completed bank
```

If a no-loop voice completes at block index `k`, it contributes nothing to
indices after `k` and its inactive state is committed before the next block. An
envelope delay still advances phase and envelope state once per represented
frame without issuing sample-memory reads, matching the current contract.

## Endpoint And Line-Service Architecture

The current `voice_endpoint_fetch`, `voice_line_cache`, and
`wave_memory_subsystem` do not constrain the replacement. Their word-level,
in-order, single-request interfaces discard locality that the block renderer
already knows and do not provide a useful foundation for multi-outstanding DDR
traffic. Keep them only long enough to provide baseline measurements and remove
them after the replacement path passes its gates.

Split the new memory-facing render path into three explicit responsibilities:

```text
block endpoint planner
  -> shared line cache and miss engine
  -> endpoint assembly and ordered DSP issue
```

The block endpoint planner walks the local phase state for one voice and creates
one job for each contributing block frame. A job contains at least:

```text
job token and voice generation
block frame index
mono/stereo mode and interpolation fraction
L0/L1/R0/R1 word offsets
deduplicated aligned line addresses
DSP parameters that are constant for that frame
```

It must remove duplicate endpoint words within a frame and expose sharing across
consecutive jobs. With a phase increment near one sample, the previous frame's
second interpolation endpoint is normally the next frame's first endpoint. A
line returned for any job may therefore satisfy several endpoints and several
block frames without another request.

The shared line service is indexed only by absolute aligned memory address.
Voice ID and left/right stream ID are waiter metadata, not cache identity. On a
miss it allocates an MSHR; another demand for the same in-flight line merges into
that MSHR instead of issuing another DDR command. Each waiter records the job
token and the endpoint fields satisfied by the line. A fill updates the cache
once and wakes the attached waiters through a bounded response queue.

The endpoint assembly table tracks the pending endpoint mask for every accepted
job. It extracts requested words from returned lines and marks a job ready only
after every required endpoint is present. DDR line responses remain in accepted
request order, with a FIFO mapping each response to its MSHR. Jobs may still
become ready in a different order because a later job can hit while an earlier
job waits for a miss. Filtered samples must enter the DSP in increasing
block-frame order because each sample consumes the preceding sample's filter
history. Unfiltered samples may use the same ordered path initially; relaxing
that ordering is a later measured optimization.

Normal block completion does not cancel memory work. Reset, fault recovery, or
an explicitly defined cancellation must invalidate old completions using the
job token generation so a late DDR response cannot modify a reused assembly
slot or accumulator bank.

## State Ownership Rewrite

The current per-voice/per-frame runtime snapshot handshake is incompatible with
voice-major rendering. Replace the packed active record with banks grouped by
ownership and update frequency:

- Descriptor state: mono/stereo addresses, lengths, loop points, loop mode, and
  initial phase. It is immutable for one voice generation.
- Event-owned parameters: gain, phase increment, release state, filter enable,
  and filter coefficients. Scheduled events update these fields.
- Renderer-owned dynamic state: advancing left/right phase, envelope state,
  filter history, active state, and generation.

The renderer reads these records once before processing a voice and writes the
dynamic record once after its last block frame. START installs a new generation,
initializes phase and envelope state, and clears filter history. Runtime events
must never reload phase unless the event contract explicitly defines a new
voice generation.

## Event And Timeline Rules

Every renderer-visible event must have a target audio frame. The scheduler must
not apply an event to an entire block when its target lies inside that block.

- Determine the earliest pending event at or after the next rendered frame.
- Limit `frame_count` so a block ends immediately before that event.
- Publish the shortened block, apply all events for the next frame in source
  order, and start a new block.
- Apply START, STOP, RELEASE, gain, phase-increment, and filter updates using the
  same boundary rule.
- Reject stale voice generations before modifying parameter or dynamic state.
- Define late-event behavior before implementation. The proposed behavior is to
  apply a late event to the next frame not yet rendered and set a sticky late
  status flag.
- Define counter width and wrap comparison rules before exposing target frames
  in a stable command protocol.

The scheduler may therefore emit blocks shorter than the configured maximum.
An event exactly at `start_frame` is applied before the first voice is read. An
event exactly at `start_frame + frame_count` belongs to the next block.

## Renderer Datapath Tasks

- [ ] Add block request, block completion, buffer ownership, and indexed block
  read types to `synth_pkg` or a renderer-local package.
- [ ] Add an independent C++ block scheduler that still calculates expected
  samples one frame at a time.
- [ ] Implement the replacement initially with `MAX_BLOCK_FRAMES = 1` and prove
  exact equivalence with the current renderer.
- [ ] Add two signed 32-bit stereo accumulator banks and deterministic bank
  clear sequencing.
- [ ] Define block endpoint jobs and job-associated line-service
  demand/completion types; do not extend the old word-request type as the
  permanent interface.
- [ ] Add `block_frame_index`, job token, and voice generation to endpoint/DSP
  context and result metadata.
- [ ] Implement phase walking and endpoint-job creation for all contributing
  frames of the current voice.
- [ ] Deduplicate equal endpoint words and aligned line demands within and across
  consecutive jobs.
- [ ] Add a bounded endpoint assembly table with per-job pending masks and line
  waiter metadata.
- [ ] Reorder completed jobs into increasing block-frame order before filtered
  DSP issue.
- [ ] Render consecutive frames of one voice while keeping phase, envelope, and
  filter state local to the active working record.
- [ ] Preserve sequential filter-history dependencies; do not issue a filtered
  sample from stale history.
- [ ] Accumulate each retiring DSP result into the bank entry selected by its
  `block_frame_index`.
- [ ] Handle envelope-delay frames without memory traffic and no-loop completion
  in the middle of a block.
- [ ] Write renderer-owned dynamic state once after finishing the voice.
- [ ] Drain all endpoint and DSP work before publishing the block.
- [ ] Hold completion metadata and block contents under downstream
  backpressure.
- [ ] Raise the prototype to eight frames and compare exact output and cycle
  counts against the one-frame replacement.
- [ ] Remove `multi_voice_pipeline` only after the block replacement is the
  selected default and all exact comparisons pass.

## Active Voice Traversal Tasks

- [ ] Initially scan the active bitmap once per block to isolate the benefit of
  traversal-order reversal.
- [ ] Measure scan cycles for empty, sparse, and 256-voice workloads.
- [ ] Prototype a dense active-voice ID table with a reverse-position table.
- [ ] Define bounded START insertion, STOP removal, voice stealing, generation
  replacement, and automatic envelope-completion removal.
- [ ] Prove traversal updates are atomic with respect to the next block start.
- [ ] Compare dense traversal against a hierarchical bitmap before selecting the
  permanent implementation.

Traversal order may change only while the signed accumulator is wide enough for
exact addition to remain order independent.

## Memory And Cache Tasks

- [ ] Define the new aligned line-demand protocol before implementing the block
  endpoint planner; include job token, generation, and response association.
- [ ] Define a shared line cache from scratch with configurable line count,
  associativity, demand merging, and 2/4/8 miss-status entries. Do not preserve
  the per-voice cache layout or the one-line adapter state machines.
- [ ] Define bounded MSHR waiter storage and backpressure when either MSHRs or
  waiter entries are exhausted.
- [ ] Define the DDR line/burst protocol to allow multiple outstanding requests
  while returning responses strictly in accepted-request order.
- [ ] Add an issued-MSHR FIFO that associates each ordered DDR response with the
  miss entry that generated its request; do not expose transaction IDs on the
  board memory interface.
- [ ] Measure line demands generated, unique lines, merged demands, useful words
  per returned line, cache replacements, request stalls, response latency, and
  total block cycles against the frame-major baseline.
- [ ] Use the Smart Artix eight-word physical line geometry in qualification
  tests even when exploratory models use wider lines.
- [ ] Add sequential-progress prefetch at line boundaries and distinguish issued,
  useful, late, and discarded prefetches.
- [ ] Inject long random response delay, command-ready gaps, arbitration loss,
  adjacent-line returns, and incomplete-transaction faults.
- [ ] Select 8 or 16 block frames, cache geometry, and outstanding depth from
  worst-case deadline margin and post-route cost rather than average hit rate.

## Downstream Overlap Tasks

- [ ] Add a block drain that converts one published mix block into the existing
  per-frame effects input handshake without reordering frames.
- [ ] Return a block bank only after the final frame handshake completes.
- [ ] Separate renderer credit from effects busy so rendering may fill the other
  bank concurrently.
- [ ] Replace single-frame inflight accounting with free-bank, downstream
  capacity, and output-reservoir accounting.
- [ ] Prove backpressure cannot overwrite a published bank, drop a frame,
  duplicate a frame, or reorder blocks.
- [ ] Preserve effects, compressor look-ahead, PCM FIFO, and I2S sample ordering
  while blocks are produced with variable `frame_count`.
- [ ] Measure whether overlap permits a smaller PCM target lead without causing
  underruns under qualified memory stalls.

## Verification Tasks

- [ ] Add exact `MAX_BLOCK_FRAMES = 1` comparisons for every existing renderer
  test before enabling larger blocks.
- [ ] Cover reset during accumulation, reset while a completed bank is stalled,
  empty voice sets, partial blocks, and full blocks.
- [ ] Cover mono and stereo interpolation, fractional increments, exclusive loop
  endpoints, multiple wraps across a block, and positive/negative PCM extremes.
- [ ] Cover no-loop completion and envelope Delay, Attack, Hold, Decay, Sustain,
  and Release transitions at every block index.
- [ ] Cover START, STOP, RELEASE, gain, pitch, and filter events at block start,
  every internal index, and the following-block boundary.
- [ ] Cover filter-history and envelope-state continuity across consecutive
  blocks and START reset behavior.
- [ ] Cover multiple voices contributing to every accumulator index, including
  saturation and the highest voice ID.
- [ ] Cover response backpressure, ordered responses with multiple requests in
  flight, hit-under-miss job readiness, block output backpressure, and both
  ping-pong bank ownership directions.
- [ ] Add deterministic 256-active-voice mono and stereo stress tests with exact
  C++ expected output.
- [ ] Run real MIDI/SF2 renders with identical command/event inputs through the
  frame-major reference and block RTL paths.
- [ ] Run `make lint` and `make test` after each behavior or protocol increment.

## Measurement And Selection Gates

The block renderer becomes the default only when all of the following hold:

1. Every produced PCM frame and pre-effects signed mix matches the independent
   C++ reference exactly.
2. Event eligibility and ordering are deterministic for block boundaries,
   internal event positions, late events, stale generations, and reset.
3. Full-polyphony mono and stereo workloads meet the average 2083-clock frame
   budget under the board-equivalent qualified DDR profiles.
4. Long stress renders maintain positive output lead with zero unexpected
   underruns, drops, duplicates, or frame reordering.
5. Memory reports show useful fetched-word ratio, line requests, miss rate,
   replacements, merged demands, outstanding occupancy, and prefetch utility.
6. Forced Smart Artix implementations fit and meet the project setup-margin
   target across the required placement seeds.
7. Stable numeric, memory, command, register, host, and verification documents
   are updated with the selected protocols.

## Planned Delivery Order

1. Capture frame-major correctness and board-equivalent performance baselines.
2. Define block/timeline types and add the independent C++ block scheduler.
3. Split descriptor, event-owned parameter, and renderer-owned dynamic state.
4. Define the block endpoint, job-associated line-demand, ordered DDR response,
   MSHR waiter, and assembly protocols without preserving the old fetch/cache
   interfaces.
5. Implement the new renderer and line service with one-frame blocks and prove
   exact equivalence.
6. Enable eight-frame accumulation, cross-frame endpoint/line deduplication,
   variable block length, and atomic block publication.
7. Add timestamped event splitting and remove the per-frame runtime snapshot
   handshake.
8. Add ping-pong ownership and overlap renderer execution with downstream block
   draining.
9. Compare bitmap and dense/hierarchical active traversal implementations.
10. Enable and measure multi-outstanding DDR commands on the new line path.
11. Select block/cache geometry, pass RTL and hardware gates, then remove the
    legacy renderer, cache, and obsolete control-state structures.

## Open Decisions

- [ ] Select the final maximum block size from 8 and 16; retain shorter blocks
  for event and capacity boundaries.
- [ ] Select dense active IDs or a hierarchical bitmap.
- [ ] Select accumulator implementation as registers, distributed RAM, or BRAM
  from inference, port, timing, and reset-clear results.
- [ ] Select shared cache line count, associativity, replacement policy, and
  outstanding miss count.
- [ ] Define the target-frame width, wrap comparison, and late-event policy.
- [ ] Decide when the old DEFINE/prepared-state protocol is removed rather than
  translated. The old word fetch and cache paths will be removed, not adapted
  into the selected renderer.
