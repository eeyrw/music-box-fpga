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
SPI direct command stream or CMD_FIFO_DATA
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

`voice_major_system` still owns one output block at a time. It does not request
block N+1 until block N has been read through the effects input and its mix
buffer has been released. The two-bank mix buffer therefore protects ownership
and backpressure but is not yet used for render/effects block overlap.

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
reached 512 active voices and produced 48,000 frames. It measured:

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
blocks, but a full block has only 33,333 clocks at 48 kHz and the measured
33,228-clock end-to-end maximum leaves only 105 clocks of margin. The generic
renderer/effects path therefore has functional coverage but not a comfortable
capacity margin.

The latest forced Smart Artix implementation fits and closes the constrained
internal 100 MHz domain:

| Item | Post-route result |
| --- | ---: |
| Slice LUTs | 25,633 / 32,600 (78.63%) |
| Slice registers | 26,874 / 65,200 (41.22%) |
| DSP48E1 | 39 / 120 (32.50%) |
| Block RAM tiles | 50 / 75 (66.67%) |
| Setup WNS / TNS | +0.047 ns / 0 ns |
| Hold WHS / THS | +0.053 ns / 0 ns |
| Routed nets / DRC errors | 48,436 of 48,436 / 0 |

This establishes fit and internal timing closure for the current source and
constraints. It does not close external SPI/I2S delays, physical DDR/SD/audio
qualification, multiple placement seeds, or architecture growth margin.

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

The transport should receive and validate a complete request in the SCLK domain
and cross it through an explicit packet boundary. Credits must describe
complete packets or bytes. Detailed tasks remain in `spi_transport_backlog.md`.

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

### A5: Renderer And Effects Are Serialized At Block Ownership

The measured RTL-effects path confirms that effects cost and block release now
matter to the real-time budget. `voice_major_system` waits for the current block
to render, drains every frame into the effects chain, and releases it before
requesting the next block. The second mix-buffer bank is not used concurrently.

The next throughput change should evaluate:

```text
renderer block N+1
effects and output ingestion for block N
compressor/output FIFO work from earlier frames
```

Every boundary must retain data under backpressure without duplication,
reordering, or early release. Acceptance requires the same 512-voice timed-DDR3
plus RTL-effects workload and a meaningful margin below the 33,333-clock full
block deadline.

### A6: Effect Sends Are Global

The renderer produces one dry stereo mix. Global chorus and reverb sends apply
to that complete mix, so MIDI and SoundFont per-voice send semantics cannot be
represented. A complete design needs per-voice send values and separate dry,
chorus-send, and reverb-send stereo accumulators. Accumulator RAM, multiplier
scheduling, return routing, and the C++ reference contract must be designed
together.

### A7: DDR Transactions Have No Bounded Failure Recovery

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

### A8: Asset Readiness Does Not Establish Address Ownership

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

### A9: START Repeats Sample Metadata

Compact START still sends base address, length, loop points, envelope, and
filter parameters for each note. Layered presets and repeated notes consume
transport bandwidth for mostly invariant data.

Evaluate an atomically published, asset-owned descriptor table. A descriptor
START could carry generation, descriptor ID, gains/pitch overrides, and runtime
policy. Descriptor loading, manifest validation, packet atomicity, generations,
and host cache ownership form one contract.

### A10: Point Updates Are Expensive For Modulation

Periodic GAIN, PITCH, and FILTER commands consume transport bandwidth and
produce parameter steps. Compact ramp events should define target, start frame,
duration, exact rounding, replacement rules, and interaction with STOP,
RELEASE, and generation reuse. Gain and phase-increment ramps are the first
candidates; filter ramps need a stability-preserving coefficient policy.

### A11: PCM16 Voice Contributions May Lose Headroom

Each voice is saturated to PCM16 after filter, channel gain, and envelope gain,
then accumulated exactly into the signed 25-bit block mix. A filter-amplified
voice can therefore clip before the compressor or master gain sees the sum.

Keep PCM16 unless measured 20- or 24-bit contributions demonstrate audible
benefit. Any change requires an exact accumulator-width derivation, clip/peak
statistics, bit-exact C++/RTL tests, listening comparisons, and post-route
resource/timing results.

### A12: Audio Timeline, Clocking, And Recovery Are Incomplete

The compressor contributes 48 frames of algorithmic look-ahead and the output
FIFO normally contributes another 48 frames of scheduling lead. Rendered,
effect-complete, compressed, queued, and played positions are not represented
as one coherent timeline. The current effects and host presets assume 48 kHz.

Define algorithmic delay versus safety reservoir, coherent frame counters,
sample-rate policy, codec clock/slot/reset/mute requirements, pop-free underrun,
FIFO reprime, and played-frame resynchronization.

### A13: Diagnostics Need Profiles And Coherent Capture

Fresh hierarchical utilization and post-route timing reports now exist, so the
old request for an integrated report is closed. The remaining diagnostic issue
is architectural: multiword observations are not uniformly captured at one
instant, and detailed qualification counters consume routing and carry chains.

Define a small health set in the existing system domain, a coherent snapshot
operation, qualification-only counters, overflow/clear semantics, and a
repeatable multi-seed implementation margin target.

## Immediate Next Change

A5 block ownership overlap is the next implementation target. The current
timed-DDR3 plus RTL-effects result leaves only 105 clocks below a full 16-frame
deadline, and the serialization point is explicit in `voice_major_system`.
Unlike command transport, asset descriptors, per-voice sends, or wider voice
precision, this change does not require a new external contract.

The first implementation should remain narrowly scoped:

- allow the renderer to acquire the free mix-buffer bank for block N+1 while
  the output path drains block N into the effects chain;
- track render-owned and output-owned buffer IDs independently;
- retain completed blocks and effect input data under backpressure;
- release each buffer only after its final frame is accepted exactly once;
- define reset behavior for a rendering block and a draining block;
- preserve command visibility at the next admitted render-block boundary.

Focused tests must cover consecutive blocks, effects backpressure, output FIFO
pressure, reset in each ownership state, exact frame ordering, and absence of
duplicate or early releases. Then repeat the existing 512-voice timed-DDR3 plus
RTL-effects workload and report both renderer latency and render-to-effects
release latency. A4 board-equivalent integration follows as validation of the
same scheduler change, not as a prerequisite for removing the known
serialization.

## Prioritized Workstreams

### P0: Block Overlap And Board-Equivalent Validation

- [ ] Allow rendering into the free mix-buffer bank while effects drain the
  published bank.
- [ ] Prove independent bank ownership, backpressure, release, reset, and frame
  ordering with focused self-checking tests.
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

- [ ] Complete the P0 packet/CDC work in `spi_transport_backlog.md`.
- [ ] Decide whether missing DDR progress requires a timeout/reset contract and
  sticky fault data.
- [ ] Define calibration-loss, mute, reservoir-reprime, and restart behavior.
- [ ] Test truncation, CRC/sequence retry, missing DDR responses, stuck ready,
  calibration failure/loss, and local reset.

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
4. Fix physical command packet atomicity before expanding command semantics.
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
6. Packet tests cover truncation, bad length/CRC, capacity exhaustion, ACK loss,
   duplicate retry, and clock/reset interaction.
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
