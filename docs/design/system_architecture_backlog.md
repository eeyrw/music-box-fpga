# System Architecture Backlog

This document records unresolved architecture work for the production
voice-major wavetable synthesizer. It is not an implementation plan for work
that has already landed. Current module ownership and stable contracts remain
in `system_design.md`, `rtl_module_map.md`, `../fixed_point.md`,
`../memory_format.md`, and `../register_map.md`.

The status in this document was refreshed against the production RTL and the
measured simulation and Vivado results on 2026-07-30.

## Current Baseline

The production path is:

```text
SPI opcode-0xa5 production command stream
  -> 1024-word command FIFO, parser, and generation validation
  -> banked mono voice state
  -> ascending scan of all configured voice IDs
  -> voice-major blocks of up to 16 output frames
  -> single-context envelope frontend and 8-entry voice-job storage
  -> per-voice endpoint planning into ordered line descriptors
  -> one persistent 32-word sample window per voice
  -> ordered 8-word DDR requests
  -> fixed eight-lane DSP barrel and signed 25-bit stereo block mix
  -> global chorus/reverb and return mix
  -> look-ahead compressor and master gain
  -> PCM output FIFO
  -> I2S
```

`CMD_FIFO_DATA` reaches the same parser but is a debug-only injection register,
not an alternate production command-submit path.

One hardware voice renders one mono sample stream. Linked SoundFont stereo
material is allocated as two mono voices by C++. A mono sample is interpolated
once and duplicated before independent left/right gain.

`VOICE_START_MONO` installs one complete voice and clears phase and filter
history. Runtime GAIN, FILTER, PITCH, ENV, RELEASE, and STOP commands require the
active 16-bit generation. PITCH changes `phase_inc` without reloading phase.
Commands are visible at render-block boundaries; the external command format
does not carry a requested target frame.

The renderer no longer uses the earlier hierarchical active-voice selector or
dynamic eight-slot scheduler. It scans voice IDs 0 through 511, skips inactive
synchronous snapshots, and stores up to eight prepared jobs. Job payload,
endpoint samples, and ordered line descriptors use synchronous BRAM. A fixed
eight-lane modulo barrel covers filter feedback latency without a dynamic
hazard search.

The generic memory contract remains ordered and untagged: one 128-bit response
per accepted 8-word request. `voice_sample_window` owns one request state
machine and one current miss/refill context, but it may issue all four requests
of a 32-word refill before their responses return. On Smart Artix,
`smart_artix_ddr3_line_reader` has eight request/response entries and the
read/write arbiter tracks up to 16 accepted render reads while preserving
response order.

The Smart Artix arbiter is not intended to share sustained loader, playback,
and debug bandwidth concurrently. The asset loader runs only during system
initialization while the render core is held in reset. After `asset_loaded`,
render reads have fixed priority and the register DDR aperture provides only
sparse, short diagnostic accesses. A diagnostic request may wait for the
current finite render-read sequence to drain; fairness for continuous debug
traffic is not a product requirement.

`voice_major_system` owns one draining output block while independently tracking
one active render request. After block N is published and owned for drain, it
may request block N+1 into the free mix bank before N reaches the effects input
or is released. A completed N+1 remains published under backpressure until N is
released and output ownership can advance in order.

The Smart Artix top uses the MIG 100 MHz UI clock as the render, control, and
audio system clock. System reset remains asserted until MIG calibration
completes, and renderer reset remains asserted until the SD asset loader
publishes `asset_loaded`.

## Measured Baseline

The current project defaults are 512 voices, 16-frame blocks, eight job entries,
100 MHz system clock, and 48 kHz output.

The 2026-07-29 one-second timed-DDR3 renderer stress reached 512 active voices
and 48,000 output frames with zero renderer deadline misses. Its maximum
renderer latency was 29,164 clocks in the measured DDR phase. This is useful
renderer evidence, but the simulation bridge is not board-equivalent.

The 2026-07-30 one-second timed-DDR3 plus production RTL effects stress also
reached 512 active voices and produced 48,000 frames. This was the serialized
pre-overlap harness baseline; it measured:

| Metric | Result |
| --- | ---: |
| Maximum renderer latency | 31,905 clocks |
| Maximum render-to-effects-release latency | 33,228 clocks |
| Renderer deadline misses | 0 |
| End-to-end deadline misses | 4 |
| Effects maximum processing cost | 87 clocks/frame |
| DDR reads / row misses | 3,864,271 / 1,405,786 |

The four end-to-end misses were short eight-frame blocks cut by the simulation
harness at MIDI/control boundaries. The board wrapper always requests 16-frame
blocks. More importantly, the old harness waited for effects release before
submitting the next block, so its 33,228-clock end-to-end value was a serialized
initiation interval rather than an unavoidable renderer limit.

A directed 2026-07-30 RTL test then enabled chorus, reverb, and compressor for
512 looping voices over timed DDR3 and issued four fixed 16-frame blocks using
the split render/drain ownership rule. It measured a maximum renderer latency
of 27,999 clocks, a maximum block initiation interval of 28,000 clocks, and a
maximum request-to-release latency of 29,307 clocks. Block N+1 started 1,307
clocks before block N was released. Thus effects drain remains part of each
block's end-to-end latency, but no longer extends the steady-state render
initiation interval when the other mix bank is free. This directed test proves
the overlap contract; it does not replace the one-second real-SF2 stress.

On 2026-07-31 the timed-DDR effects harness was changed to share
`voice_major_block_output_manager` with the production scheduler. C++ supplies
MIDI/control-aligned block requests and observes PCM, but no longer waits for
mix-bank release or tracks overlapping bank ownership. A one-second real-SF2
regression used SGM v2.01, `polyphony_stress_512.mid`, the hall chorus/reverb
preset, and the compressor. It completed 48,000 frames and reached 512 active
voices with these RTL-handshake measurements:

| Metric | Shared-manager result |
| --- | ---: |
| Maximum renderer latency | 30,061 clocks |
| Renderer deadline misses | 0 |
| Maximum request-to-release latency | 31,385 clocks |
| Maximum accepted-request interval | 35,805 clocks |
| Effects maximum processing cost | 87 clocks/frame |
| DDR reads / row misses | 3,865,900 / 1,412,058 |
| Whole simulation core cycles | 85,117,393 |

The accepted-request interval includes time spent writing MIDI/control command
bursts before the next request is presented; it is not renderer compute
latency. Two release-deadline misses remain on the 78 short eight-frame boundary
blocks. There were 2,961 full 16-frame blocks. Compared with the serialized
harness's 89,085,874 core cycles, shared RTL overlap removes 3,968,481 cycles
(4.455%) for the same audio workload and output count.

The 2026-07-30 block-overlap and explicit signed-25 accumulator experiment used
a fresh synthesis with the same strategy. It changed whole-chip utilization
from 25,938 to 25,923 LUTs and from 25,562 to 25,567 FFs; BRAM remained 46,
DSP remained 39, and post-synthesis WNS remained +0.400 ns. The mix-buffer
hierarchy remained 1,063 LUTs / 1,671 FFs, showing that synthesis had already
trimmed the unobservable upper seven accumulator bits in the former signed-32
declaration. A fresh implementation result is still pending.

The latest forced Smart Artix implementation fits and closes the constrained
internal 100 MHz domain:

| Item | Post-route result |
| --- | ---: |
| Slice LUTs | 24,365 / 32,600 (74.74%) |
| Slice registers | 25,525 / 65,200 (39.15%) |
| DSP48E1 | 39 / 120 (32.50%) |
| Block RAM tiles | 46 / 75 (61.33%) |
| Setup WNS / TNS | +0.194 ns / 0 ns |
| Hold WHS / THS | +0.056 ns / 0 ns |
| Routed nets / DRC errors | 45,561 of 45,561 / 0 |

This is the 2026-07-30 implementation after compacting the ordered descriptor.
Against the preceding implementation it removes 1,268 LUTs, 1,349 registers,
and four BRAM tiles while leaving DSP use unchanged. Setup WNS improves by
0.147 ns, and the worst setup path moves out of descriptor storage into the
compressor output path. This establishes fit and internal timing closure for
the current source and constraints. It does not close the reported external
SPI/I2S delay gaps, physical DDR/SD/audio qualification, multiple placement
seeds, or architecture growth margin.

## Closed Since The Previous Baseline

These items should not be carried as open architecture work:

- The project default and command voice ID now support 512 voices.
- Render requests use up to 16 frames; the default was selected from an 8/16
  timed-DDR3 comparison.
- The dynamic slot scheduler was replaced by bounded job storage, a
  single-context frontend, ordered line descriptors, and a fixed DSP barrel.
- Renderer working records and line descriptors were moved to synchronous BRAM.
- The Smart Artix line reader now queues eight requests/responses and the
  arbiter supports multiple ordered render reads.
- Control, rendering, effects, and audio intentionally use the MIG UI clock.
  DDR calibration is a prerequisite for the complete system; an independent
  always-on control island is not required, avoiding otherwise unnecessary CDC
  and reset-domain complexity.
- RTL DDR3 renders can instantiate the production chorus, reverb, compressor,
  and master-gain path and report renderer and end-to-end latency separately.
- A fresh 512-voice Smart Artix implementation fits, is fully routed, and closes
  the currently constrained internal setup and hold checks.

## Open Architectural Findings

### A1: SPI Transport Is Not An Atomic Packet Boundary

`spi_register_bridge` samples synchronized SPI signals in the system-clock
domain and publishes command words individually. The command FIFO protects
normal backpressure, but it does not provide complete-command atomicity at the
physical boundary, pre-publication length/CRC validation, sequence numbers,
ACK/NACK, retry, duplicate suppression, or a formally constrained SCLK CDC.

The immediate requirement is all-or-nothing visibility for one CS-delimited
`0xa5` transaction. A bounded staging buffer can provide that while preserving
the current wire format. Sequence, CRC, ACK/NACK, retry, and an SCLK-domain
packet protocol are a larger optional design if the selected MCU requires
unsupervised DMA or exactly-once retry. Detailed choices remain in
`spi_transport_backlog.md`.

### A2: Command Timing Is Block-Boundary Based, Not Timestamped

The command plane drains before a block is admitted. This gives deterministic
block-boundary visibility, but the host cannot request an exact future audio
frame. The fixed board wrapper always requests 16 frames, while simulation may
shorten blocks at MIDI/control boundaries; neither path carries an event target
frame in the hardware command.

A timestamped scheduler must define target width and wrap, scheduling horizon,
late-event policy, simultaneous ordering, generation interaction, and whether a
block is shortened or split at an event boundary.

### A3: Core Memory Service Has One Miss/Refill Context

Board-side single-outstanding service is no longer the limitation: the line
reader and arbiter accept multiple ordered reads. The remaining serialization
is inside `voice_sample_window`. It accepts one client lookup at a time and one
miss or refill sequence owns its state machine until the response sequence
completes. A 32-word refill can have four ordered reads in flight, but another
job cannot begin an independent lookup or miss during that sequence.

First measure the current context under a board-equivalent memory profile. If
deadlines require more concurrency, evaluate a bounded number of core miss
contexts, same-window demand merging, response identification, cancellation,
and reset behavior. Do not replace the window policy from average hit rate
alone; require worst-case deadline and post-route comparisons.

### A4: The Long RTL DDR3 Render Is Not Board-Equivalent

`render-rtl-ddr3` covers the production command plane, renderer, windows,
ordered transactions, timed DDR3 behavior, and optionally the production RTL
effects chain. It still does not instantiate the Smart Artix line reader,
arbiter, asset writer, register DDR master, or MIG-ready behavior in one long
render top.

A board-equivalent performance harness must include the asset-load-to-playback
ownership transition, representative MIG command/return gaps, and occasional
single diagnostic DDR transactions during playback. It should verify response
ownership and ordering, debug completion after finite render bursts, render
deadlines, output lead, and underrun accounting. Loader/playback concurrency and
sustained diagnostic traffic are not required workloads. Directed unit tests of
the reader and arbiter do not replace this integrated workload.

### A5: Renderer And Effects Block Overlap Implemented, Workload Pending

The 2026-07-30 scheduler change removes the explicit serialization in
`voice_major_system`. A render request for block N+1 may now occupy the free mix
bank while block N drains into the effects chain. Renderer completion timing is
captured when completion first becomes valid, even if output ownership is still
backpressured by block N.

The next throughput experiment must evaluate:

```text
renderer block N+1
effects and output ingestion for block N
compressor/output FIFO work from earlier frames
```

Every boundary must retain data under backpressure without duplication,
reordering, or early release. Acceptance requires the same 512-voice timed-DDR3
plus RTL-effects workload and a meaningful margin below the 33,333-clock full
block deadline.

### A6: Render Hierarchy Hides Ownership And Resource Hotspots

The routed hierarchy is reasonable at the board boundary: MIG, DDR/SD service,
platform registers, and the common synth system are separate top-level blocks.
The problematic branch is inside `voice_major_render_core`. The nominal
controller owns 10,505 LUTs only because it instantiates both the 9,375-LUT
voice engine and the 1,101-LUT mix buffer; the controller's own logic is only
35 LUTs. The engine then nests envelope, sample-window, and DSP work under one
more wrapper. This makes scheduler ownership and synthesis attribution harder
to read without providing an architectural boundary.

Refactor behavior-preservingly toward sibling ownership:

```text
voice_major_render_core
+- command_plane
+- voice_state_store
+- block_scheduler          # traversal and outstanding-work policy only
+- envelope_frontend
+- sample_fetch_pipeline
|  +- voice_sample_window
+- voice_dsp_pipeline
+- block_mix_buffer
```

Do not add cosmetic wrappers. First extract the scheduling FSM from
`voice_major_block_controller`, then remove `block_mono_voice_engine` only when
the explicit ready/valid connections can be owned by the core or a genuine
pipeline boundary. Preserve exact backpressure and block-publication behavior
with the existing focused tests. Compare post-route hierarchy, timing, and LUT
combining before claiming a resource improvement; the primary goal is ownership
clarity, not an assumed area reduction.

The 2026-07-30 ordinary-synthesis experiment reduced a narrower hotspot without
changing that hierarchy. Removing redundant voice/generation/final-state fields
from the DSP tail and expressing signed saturation as sign-extension overflow
detection produced this fresh A/B with identical 512-voice directed throughput:

| Metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Full-device Slice LUT | 27,414 | 27,136 | -278 |
| Full-device Slice FF | 27,043 | 26,775 | -268 |
| Voice engine LUT | 9,903 | 9,655 | -248 |
| DSP pipeline LUT / FF | 3,645 / 1,229 | 3,418 / 954 | -227 / -275 |
| Post-synthesis WNS | +0.400 ns | +0.400 ns | unchanged |

All ideal-memory and timed-DDR3 filter-off/on runs remained at 28,000 clocks,
8,192 DSP issues, and 8,192 contributions for a 16-frame block. This is a useful
local area result, not post-route signoff, and it does not close the ownership
refactor described above.

The follow-up descriptor compaction kept the planner at one frame pair per
clock and retained its maximum two descriptor emits in one clock. Moving the
two 3-bit word offsets into one `128 x 6` per-job distributed RAM reduced each
ordered descriptor from 157 to 61 bits. A second compaction used the planner's
ordered-run invariant: each descriptor now stores only the 29-bit line address
and inclusive 5-bit last endpoint, while a per-work cursor supplies the first
endpoint. This reduced the descriptor to 34 bits and removed the 32-bit mask
priority scan from response gathering. Fresh ordinary synthesis produced:

| Metric | 157-bit | 61-bit | 34-bit | Total delta |
| --- | ---: | ---: | ---: | ---: |
| Full-device Slice LUT | 27,136 | 26,261 | 25,938 | -1,198 |
| Full-device Slice FF | 26,775 | 25,770 | 25,562 | -1,213 |
| Block RAM tiles | 50 | 47 | 46 | -4 |
| Voice engine LUT | 9,655 | 8,782 | 8,459 | -1,196 |
| Renderer LUT / FF | 8,513 / 9,093 | 7,631 / 8,088 | 7,315 / 7,880 | -1,198 / -1,213 |
| Post-synthesis WNS | +0.400 ns | +0.171 ns | +0.400 ns | unchanged |

Both descriptor banks now map as `128 x 34`, one RAMB18 each; the offset table
uses four RAM64M primitives. The same four 512-voice ideal/timed-DDR3 runs stay
at 28,000 clocks, 8,192 DSP issues, and 8,192 contributions. A focused renderer
test skips one block frame, forces a dual emit, and checks fractional sampling
across three lines. A default 16-frame, 0.02-second SGM v2.01 SF2 and
`polyphony_stress_512.mid` smoke also passed with 465 peak active voices,
26,847 maximum render clocks, zero deadline misses, 58,804 DDR reads, and
18,752 row misses. No 8/16 A/B was rerun. This is a retained area win, not
updated implementation signoff.

### A7: Effect Sends Are Global

The renderer produces one dry stereo mix. Global chorus and reverb sends apply
to that complete mix, so MIDI and SoundFont per-voice send semantics cannot be
represented. A complete design needs per-voice send values and separate dry,
chorus-send, and reverb-send stereo accumulators. Accumulator RAM, multiplier
scheduling, return routing, and the C++ reference contract must be designed
together.

### A8: DDR Transactions Have No Bounded Failure Recovery

The line reader and register access master can wait indefinitely for MIG command
acceptance or read completion. Queue depth bounds occupancy, not latency. This
is distinct from arbitration fairness: sparse debug traffic is allowed to wait
behind render reads, and the loader does not overlap playback. There is no
timeout, cancellation, local reinitialization, or defined response to
calibration loss with work in flight.

Decide whether missing MIG progress should leave the system held, reset the
system, or raise sticky first-failure status before reset. If bounded recovery
is required, define command/response timeouts, cancellation or local reset, and
mute/reprime/restart behavior. Tests must then inject missing responses, stuck
ready, calibration loss, and local resets.

### A9: Asset Readiness Does Not Establish Address Ownership

The native-SD loader now has substantial protocol and retry coverage and
publishes `asset_loaded` only after its raw-image load completes. That still
does not prove that every later START address belongs to a validated playable
sample. Voice commands validate local length and loop relationships but not an
authoritative manifest-owned region.

Remaining work includes complete image integrity validation, overflow-safe DDR
range proof, a versioned manifest of playable mono regions, START/descriptor
validation against that manifest, and coherency rules for diagnostic DDR
writes. Full-SF2 loading should also be compared with a compact wave-bank
format.

### A10: START Repeats Sample Metadata

Compact START still sends base address, length, loop points, envelope, and
filter parameters for each note. Layered presets and repeated notes consume
transport bandwidth for mostly invariant data.

Evaluate an atomically published, asset-owned descriptor table. A descriptor
START could carry generation, descriptor ID, gains/pitch overrides, and runtime
policy. Descriptor loading, manifest validation, command-transaction atomicity,
generations, and host cache ownership form one contract.

### A11: Point Updates Are Expensive For Modulation

Periodic GAIN, PITCH, and FILTER commands consume transport bandwidth and
produce parameter steps. Compact ramp events should define target, start frame,
duration, exact rounding, replacement rules, and interaction with STOP,
RELEASE, and generation reuse. Gain and phase-increment ramps are the first
candidates; filter ramps need a stability-preserving coefficient policy.

### A12: PCM16 Voice Contributions May Lose Headroom

Each voice is saturated to PCM16 after filter, channel gain, and envelope gain,
then accumulated exactly into the signed 25-bit block mix. A filter-amplified
voice can therefore clip before the compressor or master gain sees the sum.

Keep PCM16 unless measured 20- or 24-bit contributions demonstrate audible
benefit. Any change requires an exact accumulator-width derivation, clip/peak
statistics, bit-exact C++/RTL tests, listening comparisons, and post-route
resource/timing results.

### A13: Audio Timeline, Clocking, And Recovery Are Incomplete

The compressor contributes 48 frames of algorithmic look-ahead and the output
FIFO normally contributes another 48 frames of scheduling lead. Rendered,
effect-complete, compressed, queued, and played positions are not represented
as one coherent timeline. The current effects and host presets assume 48 kHz.

Define algorithmic delay versus safety reservoir, coherent frame counters,
sample-rate policy, codec clock/slot/reset/mute requirements, pop-free underrun,
FIFO reprime, and played-frame resynchronization.

### A14: Diagnostics Need Profiles And Coherent Capture

Fresh hierarchical utilization and post-route timing reports now exist, so the
old request for an integrated report is closed. The remaining diagnostic issue
is architectural: multiword observations are not uniformly captured at one
instant, and detailed qualification counters consume routing and carry chains.

Define a small health set in the existing system domain, a coherent snapshot
operation, qualification-only counters, overflow/clear semantics, and a
repeatable multi-seed implementation margin target.

## Immediate Next Change

A5 block ownership overlap is implemented in RTL and its focused scheduler test.
The immediate task is to measure it in the timed-DDR3 plus RTL-effects workload;
the pre-change result left only 105 clocks below a full 16-frame deadline.

The first implementation should remain narrowly scoped:

- retain completed blocks and effect input data under backpressure;
- release each buffer only after its final frame is accepted exactly once;
- preserve command visibility at the next admitted render-block boundary;
- quantify whether overlap restores useful full-block timing margin.

Focused tests must cover consecutive blocks, effects backpressure, output FIFO
pressure, reset in each ownership state, exact frame ordering, and absence of
duplicate or early releases. Then repeat the existing 512-voice timed-DDR3 plus
RTL-effects workload and report both renderer latency and render-to-effects
release latency. A4 board-equivalent integration follows as validation of the
same scheduler change, not as a prerequisite for removing the known
serialization.

## Prioritized Workstreams

### P0: Block Overlap And Board-Equivalent Validation

- [x] Allow rendering into the free mix-buffer bank while effects drain the
  published bank.
- [x] Prove consecutive request overlap, completion backpressure, release, reset,
  and frame ordering with focused self-checking tests.
- [ ] Re-run the 512-voice timed-DDR3 plus RTL-effects workload and require a
  meaningful end-to-end margin below the full-block deadline.
- [ ] Build a long render top containing the Smart Artix line reader, arbiter,
  register master, asset-load-to-playback transition, and representative MIG
  behavior.
- [ ] Replay maximum-polyphony mono and linked-stereo workloads with long
  stalls, ready gaps, row conflicts, refresh, and sparse diagnostic accesses.
- [ ] Record render/effects-release distributions, deadline misses, output lead,
  underruns, useful fetched words, refill/fallback counts, queue occupancy, and
  diagnostic completion latency.
- [ ] Re-run fresh implementation and required placement seeds after the
  scheduler ownership change.

### P0: Reliable Control And DDR Fault Handling

- [ ] Complete the compatible transaction-staging and SPI physical-timing work
  in `spi_transport_backlog.md`; add a new packet protocol only if required.
- [ ] Decide whether missing DDR progress requires a timeout/reset contract and
  sticky fault data.
- [ ] Define calibration-loss, mute, reservoir-reprime, and restart behavior.
- [ ] Test SPI truncation/capacity rejection, missing DDR responses, stuck
  ready, calibration failure/loss, and local reset; add CRC/sequence retry tests
  only if the optional packet protocol is selected.

### P0: Asset Integrity

- [ ] Prove the complete loaded range fits installed DDR without overflow.
- [ ] Define the versioned sample-region manifest and integrity fields.
- [ ] Validate every START or descriptor against the manifest.
- [ ] Define diagnostic-write coherency during playback.
- [ ] Compare full-SF2 and compact wave-bank loading.

### P1: Timestamped Events, Ramps, And Descriptors

- [ ] Define target-frame, wrap, ordering, and late-event semantics.
- [ ] Split or shorten blocks at event boundaries without invalidating in-flight
  work.
- [ ] Define exact gain and phase-increment ramp commands and interruption rules.
- [ ] Define atomically loaded descriptors, generations, and compact START.
- [ ] Measure transport reduction and latency with real MIDI/SF2 workloads.

### P1: Core Memory Concurrency

- [ ] Measure the one-context window under the board-equivalent profile.
- [ ] Prototype bounded multi-context lookup/refill only if deadlines require it.
- [ ] Define response IDs or prove sufficient ordered association, plus reset
  and cancellation behavior.
- [ ] Compare demand merging, prefetch utility, and post-route cost.

### P2: Effects, Precision, Timeline, And Diagnostics

- [ ] Design per-voice chorus and reverb sends with three mix accumulators.
- [ ] Compare PCM16, 20-bit, and 24-bit contribution formats with peak/clip
  telemetry and exact models.
- [ ] Define the unified audio timeline, underrun mute/reprime sequence, and
  fixed-48-kHz or coherent multi-rate policy.
- [ ] Split production health from qualification diagnostics and add coherent
  snapshots in the existing system domain.

## Dependency Order

1. Overlap renderer and effects block ownership, then re-run the existing
   timed-DDR3 plus RTL-effects stress.
2. Establish the integrated Smart Artix memory/effects capacity baseline and
   add core memory contexts only if that evidence still requires more margin.
3. Define DDR fault recovery and asset address ownership within the existing
   system clock domain.
4. Fix CS-delimited command transaction atomicity before expanding command
   semantics.
5. Add timestamped events, ramps, and descriptor-based START on the validated
   transport and asset contracts.
6. Add per-voice effect sends and evaluate wider contribution precision only
   after resource and timing margin is known.
7. Finalize the audio timeline, codec, mute, and recovery contract.

## Acceptance Gates

Every architecture change must meet the applicable gates:

1. Exact integer results match an independent C++ model for playback, looping,
   envelopes, filtering, mixing, effects, compression, rounding, and saturation.
2. Command eligibility is deterministic at block and target-frame boundaries.
3. Qualified 512-voice workloads meet every full and shortened-block deadline
   under the board-equivalent DDR profile with sparse debug accesses.
4. Output lead stays positive after startup and underrun/drop counters stay zero.
5. Memory reports distinguish window hits, refills, fallback reads, stalls,
   useful words, diagnostic completion latency, and outstanding occupancy.
6. Compatible SPI tests cover truncation, capacity exhaustion, atomic commit,
   and clock/reset interaction. If packet transport is selected, they also
   cover bad length/CRC, ACK loss, and duplicate retry.
7. `make lint` and `make test` pass with focused self-checking tests for every
   changed protocol or behavior.
8. Smart Artix fits, closes setup and hold, is fully routed, has no DRC errors,
   and meets the selected multi-seed margin target.
9. Register, numeric, memory, command, host, board, and verification documents
   change with their matching contracts.
10. DDR timeout or calibration loss drives the system to its specified reset or
    mute state without accepting further playback work.
11. Asset publication proves integrity and every playable range belongs to one
    validated manifest region without overflow or MIG-address truncation.
12. Startup, starvation, reprime, and restart produce the specified frame
    sequence without uncontrolled output discontinuities.

## Open Decisions

- [ ] Is block-level render/effects overlap sufficient, or is deeper output
  pipeline decoupling required?
- [ ] Does the core window need multiple miss contexts after board-equivalent
  measurement, and if so how are responses associated and cancelled?
- [ ] Does missing MIG progress require a timeout, and if so what reset and
  recovery sequence follows it?
- [ ] What manifest/descriptor format and integrity/generation contract owns
  playable addresses?
- [ ] What are target-frame width, wrap, horizon, late-event, and ramp rules?
- [ ] Are diagnostic DDR writes forbidden during playback or coherent with it?
- [ ] Do measured clips justify wider-than-PCM16 voice contributions?
- [ ] Is 48 kHz fixed, or must every effect/audio constant support multiple
  rates?
- [ ] What codec clocking, slot, reset, mute, and restart behavior is required?
- [ ] Which diagnostics remain in production, which are qualification-only, and
  what is the coherent snapshot scope?
