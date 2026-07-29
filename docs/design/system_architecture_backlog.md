# System Architecture Backlog

This document records unresolved architecture work for the production
voice-major wavetable synthesizer. Items here may change internal protocols,
scheduling, software-visible commands, latency, or ownership boundaries. Each
change requires a focused migration, matching contract updates, and
self-checking verification.

## Current Baseline

The production path is:

```text
SPI direct command stream or CMD_FIFO_DATA
  -> compact command FIFO and semantic validation
  -> banked mono voice state
  -> hierarchical active-voice selection
  -> voice-major blocks of up to eight output frames
  -> one persistent 32-word sample window per voice
  -> ordered 8-word DDR refill requests
  -> signed 25-bit stereo block mix
  -> chorus/reverb and return mix
  -> look-ahead compressor and master gain
  -> PCM output FIFO
  -> I2S
```

One hardware voice renders one mono sample stream. Linked SoundFont stereo
material is allocated as two mono voices by C++. A mono sample is interpolated
once and duplicated before independent left/right gain.

START installs one complete voice and clears phase and filter history. Runtime
GAIN, FILTER, PITCH, ENV, RELEASE, and STOP commands require the active
generation. PITCH changes `phase_inc` without reloading phase.

Commands enter one 1024-word FIFO through either the dedicated SPI stream or the
register plane. The renderer does not accept a block until pending commands have
drained. Commands therefore become visible at block boundaries, but the
external command format does not carry a requested target frame.

Voice state is physically split into region, event parameter, envelope
parameter, and dynamic-state BRAM banks. The renderer writes advancing phase,
envelope state, active state, and filter history back through the dynamic bank.
A two-bank block mix buffer separates fill and read ownership.

The generic memory contract is one ordered, untagged 128-bit response per
accepted 8-word request. A 32-word window refill issues four requests. On Smart
Artix, requests pass through `smart_artix_ddr3_line_reader` and
`smart_artix_ddr3_rw_arbiter` to the MIG app interface.

The Smart Artix system uses the MIG UI clock as the system clock. System reset
remains asserted until MIG calibration completes, and renderer reset remains
asserted until the asset loader publishes `asset_loaded`.

## Open Architectural Findings

### A1: SPI Transport Is Not An Atomic Packet Boundary

`spi_register_bridge` samples synchronized SPI signals in the system-clock
domain and publishes command words individually. The command FIFO protects
normal backpressure, but it does not provide:

- complete-command atomicity at the physical transport boundary;
- length and CRC validation before publication;
- sequence numbers, ACK/NACK, retry, or duplicate suppression;
- a formally constrained SCLK-to-system-clock crossing.

The transport should receive and validate a complete request in the SCLK domain,
then cross it through an explicit clock-domain-safe packet boundary. Credits
must describe complete packets or bytes rather than optimistic word capacity.

Detailed electrical and protocol tasks belong in
`spi_transport_backlog.md`.

### A2: Command Timing Is Block-Boundary Based, Not Timestamped

The command plane drains before a block is admitted. This gives deterministic
block-boundary visibility, but the host cannot request an exact future audio
frame. A command arriving during an eight-frame block waits for the next block,
and the system cannot distinguish an intentionally scheduled event from a late
event.

A timestamped scheduler should define:

- target-frame width and wrap behavior;
- scheduling horizon and host lead requirements;
- late-event policy;
- whether a block is shortened or split at an event boundary;
- ordering of simultaneous commands;
- reset, retry, and generation interaction.

### A3: The Sample Window Allows Only One Memory Transaction Sequence

The per-voice 32-word windows provide useful locality and remove cross-voice
replacement, but `voice_sample_window` has one global request state machine.
Only one refill or fallback sequence can be active at a time. A refill consumes
four ordered DDR requests before another miss can progress.

The next memory study should measure whether the current single-outstanding
contract is sufficient at qualified polyphony and DDR stalls. If it is not,
evaluate a bounded tagged interface with:

- multiple refill contexts;
- demand merging for the same voice/window;
- explicit response IDs or a proven ordered multi-request contract;
- separate demand and prefetch accounting;
- bounded storage and cancellation behavior.

Do not replace the window policy from average hit rate alone. Selection requires
worst-case deadline results and post-route resource/timing comparison.

### A4: The Long RTL DDR3 Render Is Not Board-Equivalent

`render-rtl-ddr3` exercises the production command plane, block renderer,
32-word windows, 8-word ordered transactions, and a timed DDR3 model. It does
not instantiate the Smart Artix line reader, read/write arbiter, asset writer,
register DDR master, or MIG-ready behavior in one render top.

A board-equivalent performance harness must include:

- the Smart Artix line reader and arbiter;
- playback reads competing with permitted register and loader traffic;
- representative MIG command-ready and read-return gaps;
- arbitration delay and starvation measurements;
- render deadline, output lead, and underrun accounting.

The behavioral DDR3 harness remains useful for renderer and row-timing
regression, but it is not sufficient for board capacity sign-off.

### A5: Renderer And Effects Are Not Fully Overlapped

The block mix buffer has two banks, but `voice_major_system` owns one
output block at a time and requests the next block only after the current block
has passed through effects and been released. Renderer, spatial effects,
compressor, and FIFO transfer therefore do not form a fully overlapped block
pipeline.

Evaluate whether the wrapper can safely run:

```text
renderer block N+1
effects block N
compressor/output block N-1
```

Every boundary must retain data under backpressure without duplication,
reordering, or early block release. The benefit must be measured as additional
deadline margin or reduced output lead.

### A6: Effect Sends Are Global

The renderer produces one dry stereo mix. Global chorus and reverb sends apply
to that complete mix, so MIDI and SoundFont per-voice send semantics cannot be
represented.

A complete implementation needs per-voice chorus and reverb send values and
three exact-width stereo accumulators:

```text
dry mix
chorus-send mix
reverb-send mix
```

The accumulator RAM cost, voice DSP multiplier schedule, return routing, and C++
reference contract must be designed together.

### A7: Control And Mute Depend On DDR Calibration

SPI, platform status, renderer, and audio logic run from the MIG UI clock and
share reset ownership with DDR calibration. If calibration never completes,
the control interface needed to diagnose the failure is unavailable.

The board needs an always-on island driven by a stable board clock. It should
retain:

- reset cause and calibration timeout;
- loader and memory fault status;
- output mute authority;
- a minimal readable status interface;
- controlled reset of the memory/render domain.

Clock-domain crossings and reset ordering between this island, MIG/render, and
audio must be explicit.

### A8: DDR Transactions Have No Bounded Failure Recovery

The line reader, register access master, and arbiter can wait indefinitely for
command acceptance or read completion. There is no timeout, cancellation,
local reinitialization, or specified response to calibration loss with work in
flight.

Define:

- maximum service latency for playback reads;
- arbitration guarantees for playback, loader, and diagnostics;
- command and response timeouts;
- sticky fault and first-failure information;
- cancellation or local-reset behavior;
- mute, reprime, and restart sequence.

Tests must inject missing responses, stuck ready signals, calibration loss, and
local resets.

### A9: Asset Readiness Does Not Fully Establish Address Ownership

`asset_loaded` should prove that every playable address belongs to a validated
asset. The loader and command plane currently validate local lengths and loop
relationships, but voice addresses are not checked against an authoritative
manifest-owned range.

Required work includes:

- complete header, version, flag, reserved-field, and checksum validation;
- overflow-safe proof that the loaded byte range fits installed DDR;
- a versioned manifest of valid mono sample regions;
- validation of base, length, and exclusive loop endpoints against that
  manifest;
- generation or cache-invalidation rules for diagnostic DDR writes;
- comparison of full-SF2 loading with a compact wave-bank format.

### A10: START Repeats Sample Metadata

The compact START command removes wide intermediate actions, but it still sends
base address, length, loop points, envelope parameters, and filter parameters
for each note. Layered presets and repeated notes therefore consume command
bandwidth for data that is often invariant.

Evaluate a validated descriptor table loaded with the asset. A descriptor-based
START could contain generation, descriptor ID, gains/pitch overrides, and
runtime policy. Descriptor publication must be atomic so a partially loaded
descriptor is never observable.

Descriptor loading, asset generation, command packet atomicity, and host cache
ownership must be defined as one contract.

### A11: Point Updates Are Expensive For Modulation

The host sends periodic GAIN, PITCH, and FILTER commands for controller changes,
vibrato, and modulation. At high polyphony this consumes transport bandwidth and
can produce frame-to-frame parameter steps.

Compact ramp events should define:

- target value;
- target start frame;
- duration;
- exact rounding;
- interruption and replacement rules;
- interaction with STOP, RELEASE, and generation reuse.

Gain and phase-increment ramps are the first candidates. Filter ramps require a
stability-preserving coefficient policy.

### A12: PCM16 Voice Contributions May Lose Headroom

Each voice is saturated to signed PCM16 after filter, channel gain, and envelope
gain, then accumulated into the signed 25-bit block mix. A filter-amplified voice
can clip before the global compressor or master gain can manage the sum.

Evaluate 20- and 24-bit voice contributions with:

- exact accumulator-width derivation;
- explicit internal-headroom policy;
- clipping and saturation statistics;
- listening comparisons;
- bit-exact C++/RTL regressions;
- DSP, BRAM, timing, and power comparison.

Keep PCM16 unless wider contributions demonstrate a useful audible benefit
within the implementation budget.

### A13: Audio Timeline, Clocking, And Recovery Are Incomplete

The compressor contributes 48 frames of algorithmic look-ahead and the output
FIFO normally contributes another 48 frames of scheduling lead. Rendered,
effect-complete, compressed, queued, and played positions are not represented
as one coherent timeline.

The product contract must also decide whether audio is fixed at 48 kHz or truly
sample-rate configurable. Effect delays and host presets currently assume
48 kHz.

Required decisions include:

- algorithmic delay versus underrun reservoir;
- one coherent set of audio-frame counters;
- codec MCLK, slot format, reset, configuration, and mute;
- pop-free underrun behavior;
- FIFO reprime and played-frame resynchronization;
- generation of every sample-rate-dependent constant.

### A14: Diagnostics And Timing Need Production Profiles

Detailed counters are valuable for qualification but consume routing, carry
chains, and status logic. Multiword observations are not uniformly captured at
one coherent instant, and the integrated voice-major Smart Artix top needs a
fresh implementation report.

Define:

- a small always-on health set;
- a coherent diagnostic snapshot operation;
- qualification-only performance counters;
- counter overflow and clear semantics;
- hierarchical utilization and critical-path reports;
- setup-margin targets across multiple placement seeds.

## Workstreams

### P0: Board-Equivalent Measurement

- [ ] Build a render top containing the Smart Artix line reader, arbiter, and
  representative MIG behavior.
- [ ] Include permitted register DDR traffic and loader arbitration.
- [ ] Add deterministic maximum-polyphony mono and linked-stereo-pair workloads.
- [ ] Inject qualified long stalls, ready gaps, row conflicts, and refresh.
- [ ] Record render-cycle distribution, deadline misses, minimum output lead,
  useful fetched words, refill count, fallback count, and arbitration delay.
- [ ] Produce fresh hierarchical Vivado utilization and timing reports.
- [ ] Run the required placement seeds and enforce a setup-margin target.

### P0: Reliable Control Transport

- [ ] Complete the P0 items in `spi_transport_backlog.md`.
- [ ] Define atomic packet length, sequence, CRC, ACK/NACK, and retry.
- [ ] Implement an SCLK-domain receiver and explicit CDC queues.
- [ ] Publish only validated complete commands.
- [ ] Prove duplicate retry produces exactly-once command publication.
- [ ] Establish a measured maximum SPI rate.

### P0: Clock And Fault Domains

- [ ] Define an always-on control/status/mute island.
- [ ] Specify reset ordering and CDC boundaries.
- [ ] Add DDR command and response timeouts.
- [ ] Define playback, loading, and diagnostic arbitration guarantees.
- [ ] Test calibration failure and loss, missing responses, and local reset.
- [ ] Define mute, reservoir reprime, and restart behavior.

### P0: Asset Integrity

- [ ] Validate every enabled header and content-integrity field.
- [ ] Prove the complete load range fits installed DDR without overflow.
- [ ] Define the versioned sample-region manifest.
- [ ] Validate every START or descriptor against the manifest.
- [ ] Define diagnostic-write coherency during playback.
- [ ] Compare full-SF2 and compact wave-bank loading.

### P1: Timestamped Events And Ramps

- [ ] Define target-frame and late-event semantics.
- [ ] Split or shorten blocks at event boundaries.
- [ ] Define gain and phase-increment ramp commands.
- [ ] Add exact tests for simultaneous, late, overlapping, and interrupted
  events.
- [ ] Measure command-bandwidth reduction with real MIDI/SF2 workloads.

### P1: Memory Concurrency

- [ ] Establish the worst-case capacity of the current single-outstanding
  window interface.
- [ ] Prototype bounded multi-refill contexts only if measurements require them.
- [ ] Define response ordering, IDs, cancellation, and reset behavior.
- [ ] Measure demand merging and prefetch usefulness independently.
- [ ] Compare post-route BRAM, LUT, DSP, and timing cost.

### P1: Descriptor-Based START

- [ ] Define descriptor contents and asset ownership.
- [ ] Define validated bulk descriptor loading.
- [ ] Define descriptor generation and invalidation.
- [ ] Add a compact descriptor-based START command.
- [ ] Compare command traffic and start latency against inline START.

### P1: Overlapped Audio Pipeline

- [ ] Allow the renderer to fill a free block bank while effects drain another.
- [ ] Define block ownership through effects and compressor.
- [ ] Prove backpressure, release, reset, and starvation behavior.
- [ ] Measure deadline margin and minimum FIFO lead.

### P2: Per-Voice Effect Sends

- [ ] Add chorus and reverb send values to descriptors/runtime controls.
- [ ] Carry sends through voice DSP.
- [ ] Add dry, chorus-send, and reverb-send block accumulators.
- [ ] Update C++ models and exact RTL tests.
- [ ] Add representative listening regressions.

### P2: Internal Precision

- [ ] Report per-voice pre-saturation peaks and clipping counts.
- [ ] Compare PCM16, 20-bit, and 24-bit contribution formats.
- [ ] Derive exact mix widths for supported voice counts.
- [ ] Run listening, exact arithmetic, resource, power, and timing comparisons.

### P2: Unified Audio Timeline

- [ ] Define rendered, effect-complete, compressed, queued, and played counters.
- [ ] Separate algorithmic latency from safety lead.
- [ ] Evaluate shared versus separate delay/reservoir memories.
- [ ] Specify underrun mute, reprime, and restart frame sequences.
- [ ] Freeze 48 kHz or define coherent multi-rate generation and validation.

## Dependency Order

1. Establish board-equivalent measurement and implementation baselines.
2. Define always-on control, fault recovery, and asset address ownership.
3. Fix physical command packet atomicity.
4. Define timestamped events and block-split behavior.
5. Measure the current ordered window path under qualified board stalls.
6. Add memory concurrency only if the measured deadline requires it.
7. Add descriptor-based START and parameter ramps.
8. Overlap renderer, effects, compressor, and output ownership.
9. Add per-voice effect sends and evaluate internal precision.
10. Finalize the audio clock, timeline, codec, mute, and recovery contract.

## Acceptance Gates

Every architecture change must meet the applicable gates:

1. Exact integer results match an independent C++ model for mono playback,
   linked stereo voice pairs, interpolation, loop modes, envelopes, runtime
   changes, filtering, mixing, effects, compression, rounding, and saturation.
2. Command eligibility is deterministic at block and target-frame boundaries.
3. The qualified polyphony workload meets every block deadline under the
   board-equivalent DDR and arbitration profile.
4. Output lead remains positive after startup; underrun and drop counters remain
   zero for the qualified workload.
5. Memory reports distinguish window hits, refills, fallback reads, useful
   fetched words, stalls, and outstanding occupancy.
6. Packet tests cover truncation, bad length/CRC, capacity exhaustion, ACK loss,
   duplicate retry, and clock/reset interaction.
7. `make lint` and `make test` pass with focused self-checking tests for every
   changed protocol or behavior.
8. Smart Artix implementation fits, closes setup and hold timing, and meets the
   setup-margin target across required placement seeds.
9. Register, fixed-point, memory, command, host, and verification documents are
   updated in the same change.
10. Control status remains readable and can force mute during DDR calibration
    failure, memory timeout, or recovery.
11. Asset publication proves integrity and all playable ranges fit one validated
    manifest region without overflow or MIG-address truncation.
12. Audio startup, starvation, reprime, and restart produce the specified frame
    sequence without uncontrolled output discontinuities.

## Open Decisions

- [ ] Keep the ordered single-outstanding DDR contract or introduce bounded
  tagged concurrency.
- [ ] Define the always-on clock, retained status, reset ownership, and mute
  authority.
- [ ] Define DDR timeouts, arbitration guarantees, and in-flight cancellation.
- [ ] Define the asset manifest, descriptor table, integrity fields, and
  generation behavior.
- [ ] Define target-frame width, wrap semantics, scheduling horizon, and late
  event behavior.
- [ ] Select parameters that support ramps and define interruption rules.
- [ ] Decide whether diagnostic DDR writes are forbidden during playback or
  participate in an explicit coherency protocol.
- [ ] Keep PCM16 voice contributions or adopt wider internal headroom.
- [ ] Decide whether compressor look-ahead and output lead share a logical or
  physical reservoir.
- [ ] Freeze a 48 kHz contract or define complete multi-rate generation.
- [ ] Define codec clocking, MCLK, slot format, reset, mute, and restart.
- [ ] Define always-on versus qualification-only diagnostics and coherent
  snapshot scope.
