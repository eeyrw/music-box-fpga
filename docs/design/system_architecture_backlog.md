# System Architecture Backlog

This document records architecture-level optimization opportunities discovered
while reviewing the complete control, render, memory, effects, and audio-output
paths. Unlike `rtl_refactoring_backlog.md`, the work here may intentionally
change internal protocols, scheduling granularity, software-visible command
formats, latency, and ownership boundaries. Every such change requires an
explicit contract update and an independently reviewable migration plan.

The current design remains the behavioral reference until a replacement passes
the acceptance gates below. This backlog does not assert that every proposed
change is beneficial; several items require measurement before selection.

## Current Baseline

The current system is a verification-first, single-frame renderer:

```text
SPI/register command words
  -> command parser and scheduler
  -> bounded action executor and prepared/active voice RAMs
  -> frame-major scan of all configured voice slots
  -> per-voice endpoint word requests
  -> one-line board memory adapter
  -> voice DSP and one-frame accumulation
  -> serial global chorus/reverb
  -> 48-frame look-ahead compressor
  -> PCM output reservoir
  -> I2S
```

The signed-off Smart Artix implementation uses 19,306 LUTs, 20,750 registers,
39.5 BRAM tiles, and 47 DSPs. It closes the internal 100 MHz domain with only
about 0.226 ns worst-case setup margin. Chorus and reverb histories are major
BRAM owners. The current worst setup cluster begins in action/DEFINE decode and
ends at prepared-RAM write control.

At 100 MHz and 48 kHz, one output frame has approximately 2083 system clocks.
Existing one-voice memory-render artifacts take approximately 265 to 283 clocks
per frame, but they do not represent full-polyphony or long-stall behavior. They
also use a different line geometry and cache organization from the signed-off
Smart Artix top, so they are not board-performance evidence.

## Architectural Findings

### A1: The Board Memory Path And Renderer Use Incompatible Granularity

The board-facing `wavetable_system_core` currently instantiates
`wave_memory_subsystem`. That adapter contains one global cache line and accepts
only one core request until its response has completed. Alternating voices with
different wave addresses therefore replace the global line repeatedly, and no
DDR latency can be hidden behind another outstanding request.

The alternative `voice_line_cache` avoids global-line thrashing by allocating
cache state per voice and stream. At 256 voices, two 32-word lines for each of
two streams imply a large physical working set before tags and control state.
The two current cache organizations are opposite extremes:

- one global line is too small for frame-major multi-voice traffic;
- fixed lines for every possible voice consume storage even when few voices are
  active.

A small shared cache is not sufficient by itself. With frame-major traversal,
hundreds of active voices can exceed its working set every frame. Cache design
and render traversal order must therefore be changed together.

### A2: Full Voice-Slot Scanning Is Fixed Work Per Output Frame

`multi_voice_pipeline` scans the complete configured bitmap in voice-index
order. With 256 configured slots at 48 kHz, it considers 12.288 million slots
per second regardless of active polyphony. This deliberately avoids a wide
priority encoder and is reasonable for the current milestone, but it is not an
efficient final scheduler for sparse workloads.

The active traversal should eventually use either:

- a hierarchical bitmap that skips empty groups; or
- a dense active-voice ID table plus a reverse-position table for bounded
  insertion and removal.

The accumulation result is exact signed integer addition before final
saturation, so a dense-list removal that changes voice traversal order does not
change the mathematical mix while the accumulator remains wide enough.

### A3: Single-Frame, Frame-Major Rendering Prevents Efficient Bursts

The renderer reads every active descriptor for every output sample and emits
two mono or four stereo word requests per contributing voice. DDR and line
caches are better served by processing several consecutive samples from one
voice. A voice-major block renderer can amortize descriptor reads, produce
sequential line traffic, and reuse phase, envelope, and filter state locally.

Block size is a design variable, not a fixed recommendation. Eight or sixteen
frames offer a smaller control-latency penalty than the previously proposed
48-frame block. Larger blocks improve descriptor and memory efficiency but need
timestamped control and more accumulator storage.

### A4: Dynamic Voice State Has Split Ownership

The renderer owns advancing phase and filter history, while the control
executor owns the volume-envelope state in active RAM. The renderer requests an
envelope snapshot for every processed voice and output frame, creating a
per-sample dependency from renderer to control executor and back to active RAM.

The target ownership should separate state by update source:

- immutable or rarely changed sample metadata belongs in descriptor/template
  RAM;
- host-controlled voice parameters belong in a parameter or event-owned RAM;
- phase, envelope stage/level, and filter history belong together in the voice
  render engine;
- the command scheduler commits events at an explicit audio-frame boundary and
  does not advance renderer-private state.

This change is a prerequisite for efficient voice-major block processing.

### A5: DEFINE Plus START Repeats Static Data And Creates Wide Intermediates

A stereo voice definition and start currently send 25 command words. The parser
materializes every decoded action as a fixed 512-bit `control_action_t`, and the
control plane keeps complete prepared and active records so START can promote a
validated definition atomically.

This is a defensible workaround for a non-atomic word transport, but it repeats
sample-region information for every note and creates a wide intermediate action
representation and the timing-sensitive DEFINE write path. If complete command
packets become atomic, sample/SoundFont region descriptors can be loaded once
and START can refer to a descriptor ID.

A future START event should contain only the voice generation, descriptor ID,
target audio frame, initial phase/runtime values, and any overrides. Runtime
updates should use compact opcode-specific payloads. Under that model, the
prepared RAM and DEFINE/START promotion protocol can be removed rather than
micro-optimized.

### A6: SPI Word Acceptance Is Not A Reliable Packet Transport

The current SPI bridge samples asynchronous SCLK in the 100 MHz domain. It can
discard an individual word when command capacity disappears during a CS-low
transaction, and a partial final word does not provide all-or-nothing packet
visibility. Increasing intermediate storage does not repair these correctness
defects.

The target transport should shift in the SCLK domain, validate length, sequence,
and CRC before publication, and cross complete requests and responses through
an explicit clock-domain-safe packet boundary. Packet credit, ACK/NACK, retry,
and duplicate suppression should replace word-level optimistic acceptance.
Detailed transport tasks remain in `spi_transport_backlog.md` and are
dependencies of the control architecture described here.

### A7: Renderer And Effects Are Serialized By One Global Busy Boundary

`wavetable_system_core` combines renderer, raw-mix holding, and effects activity
into one busy result. The next render is therefore not started while the global
effects chain is processing the previous frame. The effect path fits inside the
current frame budget, but this serialization adds renderer and effect latency
instead of overlapping independent engines.

A block or frame ping-pong boundary should allow renderer block N+1, effects
block N, compressor/output block N-1, and I2S playback to proceed concurrently.

### A8: Global Effect Sends Cannot Express Per-Voice MIDI/SoundFont Semantics

The current renderer produces one dry stereo mix. Global chorus and reverb send
gains are then applied to the complete mix, so all voices receive the same send
levels. A complete synthesizer should carry per-voice chorus and reverb sends
through the voice DSP and accumulate three wide stereo buses:

```text
dry mix
chorus-send mix
reverb-send mix
```

This functional improvement should be designed with the block accumulator so
the accumulator RAMs and multiplier schedule are evaluated together.

### A9: Audio Lead Is Distributed Across Independent Stages

The compressor holds 48 wide frames for its algorithm, while the post-
compressor output reservoir normally holds another 48 frames for underrun
protection. They currently provide 96 frames, or approximately 2 ms, of sample-
domain latency. The compressor delay is functionally required; the additional
PCM lead is a policy choice.

A future design should represent rendered, effect-processed, compressor-ready,
and played positions on one audio-frame timeline. A multi-reader ring may allow
the look-ahead data and real-time reservoir to share scheduling and storage, or
may prove that separate physical memories are still preferable. This must be
decided from underrun recovery and RAM-port requirements, not only total bit
count.

### A10: The Main Performance Harness Is Not Board-Equivalent

The Smart Artix top uses eight 16-bit words per 128-bit MIG beat and routes
runtime traffic through the board line reader and DDR arbiter. The principal
long render path instead uses a 32-word line and a per-voice cache wrapper.
Consequently, its cache statistics, request count, and frame-cycle distribution
do not qualify the board memory architecture.

A board-equivalent performance top must use the actual eight-word geometry,
global adapter, outstanding-transaction limit, arbiter, and representative MIG
ready/data gaps. It must also include runtime register access and any permitted
debug traffic. Architecture comparisons should use this profile in addition to
the more exploratory configurable-cache harnesses.

### A11: DDR Calibration Owns Too Much Of The System Failure Domain

The generic core, SPI control/status path, and I2S logic currently run from the
MIG UI clock. System reset remains asserted until DDR calibration completes, so
a DDR startup failure also removes the interface needed to diagnose that
failure. Loss of memory service after startup similarly has no independent
control or mute authority.

The board design should have an always-on control/status island driven from a
stable board clock. It should retain reset cause, calibration state, timeout
status, and output-mute control even when the memory/render domain is unusable.
The audio clock strategy should be treated as a separate decision rather than a
side effect of the MIG UI clock.

### A12: Memory Transactions Have No Bounded Failure Recovery

The board line reader, register access path, and DDR arbiter can wait
indefinitely for a command acceptance or read response. They do not define a
transaction timeout, cancellation, local reinitialization, or behavior when
calibration is lost with an operation in flight. Fixed arbitration priority is
also not expressed as a service-latency or starvation contract.

The memory subsystem needs explicit boot-loading, playback, and diagnostic
modes; bounded service expectations for real-time reads; timeout and sticky
fault reporting; and a documented recovery sequence. Real-time deadline tests
must include arbitration loss and injected incomplete transactions, not only
long but eventually successful delays.

### A13: Asset Readiness Does Not Yet Prove Integrity Or Address Safety

The loader checks basic image identity and SD block integrity, but it does not
fully validate all image-header fields or the optional whole-image checksums.
The DDR writer truncates a byte address to the MIG address width without first
proving that the complete `[base, base + size)` range fits physical memory.
Voice base/length/loop validation also has no authoritative loaded-asset range
against which to validate references.

`asset_loaded` should mean that a versioned asset manifest has passed header,
range, overflow, and content-integrity checks. Descriptors should reference
manifest-owned regions rather than arbitrary DDR addresses. Writes through the
diagnostic window must either be forbidden during playback or advance an asset
generation and invalidate affected cache state. A compact preprocessed wave
bank should also be evaluated against loading a complete SoundFont image to
reduce boot time and capacity pressure.

### A14: The Physical Voice Record Causes Wide Write Amplification

The active voice record combines static sample metadata, start-time parameters,
runtime controls, and frequently advancing envelope state into one wide RAM
word. An envelope advance or small runtime update therefore rewrites hundreds
of bits even when only a narrow field changes. This increases RAM banking,
decode fanout, switching activity, and routing pressure in the current critical
control region.

The logical ownership split in A4 should also become a physical banking split.
Banks should be grouped by update frequency and common access pattern, with
narrow write ports for renderer-dynamic state. Post-route comparison must
confirm the change because an excessive number of independent banks can trade
write amplification for control and address-routing cost.

### A15: Renderer Dynamic State Is Forced Into Distributed RAM

The phase and left/right filter-history arrays are explicitly mapped to
distributed RAM. At 256 voices they account for roughly 50 Kbit of state in a
design whose LUT margin is tighter than its BRAM margin. Their synchronous-read,
single-update access pattern may be compatible with BRAM inference, but port and
read-during-write semantics must be preserved exactly.

Create controlled synthesis variants using BRAM-safe 1R1W templates, both with
separate logical banks and with only fields that are always accessed together
packed into one word. Select the implementation from hierarchical utilization,
timing across multiple placement seeds, and collision tests rather than an RTL
style preference.

### A16: DSP Provisioning Does Not Match Every Data Mode

Mono playback currently performs the same interpolation independently for left
and right before applying separate gains. Filter arithmetic is also physically
present for both channels even when filtering is bypassed. Conversely, keeping
a fully parallel initiation interval may become valuable if a future block
renderer supplies endpoints much faster than the current word-at-a-time path.

Carry the mono/stereo mode into the DSP schedule so mono interpolation is done
once and duplicated before channel gain. Evaluate filter bypass scheduling and
left/right multiplier reuse only after the target renderer establishes a
measured endpoint arrival rate. Resource reduction must preserve exact rounding,
saturation, and filter-state update behavior.

### A17: Point Updates Are An Expensive Modulation Interface

The host currently approximates envelopes, controllers, vibrato, and related
modulation by periodically sending new gain, phase-increment, and filter values.
At high polyphony this consumes command bandwidth and scheduler work, while
frame-to-frame steps can create audible discontinuities.

Compact ramp events should carry a target value, start frame, and duration so
the renderer can apply deterministic sample- or frame-rate slew. Common vibrato,
tremolo, and simple modulation envelopes are candidates for local state without
moving full MIDI or SoundFont policy into RTL. Filter changes require an
explicit stability rule; arbitrary interpolation between coefficient sets must
not be assumed safe.

### A18: Per-Voice PCM16 Saturation May Discard Useful Mix Headroom

Each voice is reduced to signed 16-bit PCM after its local filter and gain,
before wide accumulation and global dynamics. A filter-amplified voice can
therefore clip before the compressor or master gain has an opportunity to
manage it. This is numerically simple and is the current exact contract, but it
may not be the best final audio-quality boundary.

Evaluate a 20- or 24-bit per-voice contribution with a correspondingly wider
exact accumulator and a documented internal-headroom policy. This is an
audio-quality experiment, not an unconditional refactor: select it only after
clipping statistics, listening comparisons, C++/RTL exact tests, DSP cost, and
post-route timing justify changing the numeric contract.

### A19: Sample Rate, Audio Clocking, And Underrun Recovery Are Incomplete As A Contract

The RTL exposes sample-rate-related parameters, but production effect delays
and host presets currently assume 48 kHz. I2S bit timing is generated by a
fractional tick in the system domain, while final codec MCLK, slot format,
configuration, reset, and mute behavior remain board-integration work. On
sample starvation, the serializer substitutes zero immediately rather than
following a defined mute ramp and restart policy.

The product must either freeze a complete 48 kHz audio contract or generate all
sample-rate-dependent effect and host parameters coherently. Board integration
should use a qualified audio clock plan, define codec startup and MCLK, and
specify pop-free underrun mute, timeline resynchronization, and restart
behavior.

### A20: Diagnostic Logic And Timing Margin Need Production Profiles

Detailed saturating counters and high-water tracking are valuable during
architecture qualification, but they also consume carry chains, routing, and
status-read logic. Multiword observations are not uniformly captured from one
coherent instant. The current implementation passes timing with little setup
margin, so a single successful placement is insufficient evidence for a large
rewrite.

Keep a small always-on health set in every build and define a coherent snapshot
mechanism for detailed performance observations. Allow qualification-only
instrumentation to be removed or sampled less frequently in a production
profile. Set an explicit timing-margin and multi-seed implementation gate rather
than accepting any result with nonnegative slack.

## Target Architecture Candidate

The leading candidate for evaluation is:

```text
always-on control/status, reset-cause, and mute island
  -> SPI SCLK-domain packet engine
  -> clock-domain-safe validated request/response transport
  -> validated asset manifest + descriptor table
  -> timestamped audio-event scheduler
  -> descriptor/template RAM + compact active-voice table
  -> 8- or 16-frame voice-major render engine
  -> shared set-associative line cache + miss-status entries
  -> multi-outstanding ID-tagged DDR line/burst interface
  -> dry/chorus-send/reverb-send block accumulators
  -> overlapped global effects
  -> compressor and audio-timeline reservoir
  -> qualified audio clock/domain and pop-free I2S output
```

This is a candidate, not a commitment. In particular, block size, cache size,
associativity, outstanding count, and audio-reservoir organization require
simulation sweeps and post-route comparison.

The detailed implementation and verification checklist for the voice-major
render stage is maintained in
[`voice_major_block_renderer_plan.md`](voice_major_block_renderer_plan.md).

## Architecture Workstreams

### P0: Measurement Before Replacement

- [ ] Add a board-equivalent Smart Artix render top using eight-word lines, the
  real line reader, global memory adapter, DDR arbiter, and one-outstanding
  transaction behavior.
- [ ] Drive that top with measured or conservatively qualified MIG command-ready,
  read-return, and arbitration-delay profiles.
- [ ] Include runtime register reads/writes and every diagnostic access permitted
  during playback in the stress workload.
- [ ] Add a 256-active-voice mono stress render and a 256-active-voice stereo
  stress render with deterministic PCM and exact expected output.
- [ ] Add memory profiles with long random latency, periodic ready gaps, bursty
  arbitration loss, and adjacent-line response patterns representative of MIG.
- [ ] Record line requests, useful words per fetched line, cache replacements,
  merged demands, outstanding depth, render-cycle distribution, deadline misses,
  and minimum audio lead.
- [ ] Produce a fresh hierarchical Vivado utilization report that identifies the
  major LUTRAM/BRAM/FF owners and critical paths.
- [ ] Run multiple placement seeds and establish a required setup-margin target
  for architecture selection.

### P0: Clock, Fault, And Memory-Service Domains

- [ ] Define an always-on board-clock control/status island that remains
  accessible before DDR calibration and after a memory-domain fault.
- [ ] Retain reset cause, calibration state, transaction-timeout cause, and mute
  authority in the always-on domain.
- [ ] Define clean clock-domain crossings between control, memory/render, and
  audio domains, including independent reset ordering.
- [ ] Specify timeouts for command acceptance and read completion and define
  cancellation or local-reset behavior for every in-flight state.
- [ ] Define boot-loading, playback, and diagnostic memory modes with explicit
  arbitration and maximum-service-latency contracts.
- [ ] Inject calibration loss, missing responses, stuck command backpressure,
  and local resets in self-checking board-level tests.

### P0: Asset Integrity And Address Ownership

- [ ] Validate header size, flags, reserved fields, image version, and all
  enabled header/content checksums before publishing an asset.
- [ ] Prove `[base, base + size)` cannot overflow, truncate at the MIG address
  boundary, or exceed the installed DDR range before issuing the first write.
- [ ] Define a versioned manifest containing valid wave regions, descriptor
  count, format, integrity result, and asset generation.
- [ ] Validate every descriptor base, length, and exclusive loop endpoint
  against one manifest-owned region.
- [ ] Forbid diagnostic DDR writes during playback or define generation update
  and cache invalidation semantics that make modified data observable.
- [ ] Compare boot time and DDR occupancy for the current complete SoundFont
  image and a compact preprocessed wave-bank format.

### P0: Reliable Packet Transport

- [ ] Complete the P0 work in `spi_transport_backlog.md`.
- [ ] Define an atomic command packet with length, sequence, target audio frame,
  payload type, and CRC.
- [ ] Add SCLK-domain packet reception and an explicit clock-domain-safe request
  and response transport.
- [ ] Define credit in complete packets/bytes, not only free 32-bit words.
- [ ] Prove retry and duplicate suppression provide exactly-once event
  publication.
- [ ] Keep a compatibility translation layer in host software while old and new
  RTL renderers are compared.

### P0: Memory And Block-Render Prototype

- [ ] Build a cycle-accurate C++ model of an 8/16/32-frame voice-major renderer
  and candidate shared caches before replacing RTL.
- [ ] Compare frame-major and voice-major traffic using the same MIDI/SF2,
  phase, interpolation, loop, and memory-latency inputs.
- [ ] Define a line/burst request carrying transaction ID and an out-of-order or
  explicitly ordered response contract.
- [ ] Implement a configurable shared cache prototype with 16/32 lines, two/four
  ways, demand merging, and 2/4/8 MSHRs.
- [ ] Add line-boundary prefetch based on actual sequential progress and measure
  useful prefetch rate separately from issued prefetches.
- [ ] Select block size and cache geometry from worst-case deadline margin and
  post-route cost, not average song hit rate.

### P1: Voice State And Active Traversal

- [ ] Define separate descriptor, host-parameter, and renderer-dynamic-state
  records.
- [ ] Physically bank static metadata, start-time parameters, runtime controls,
  and frequently written dynamic state by update frequency and access pattern.
- [ ] Measure wide-write elimination, RAM count, decode fanout, switching, and
  post-route timing against the current packed active record.
- [ ] Move phase, envelope state, and filter history under one render-engine
  owner.
- [ ] Replace the per-voice/per-frame control snapshot handshake with scheduled
  event application at an explicit audio boundary.
- [ ] Prototype both a hierarchical active bitmap and a dense active-ID table.
- [ ] Prove START, STOP, RELEASE, voice stealing, generation/sequence rejection,
  and automatic envelope completion update the active traversal atomically.
- [ ] Preserve exact phase, loop, envelope, filter, rounding, and saturation
  results across block boundaries.

### P1: Renderer State And DSP Mapping

- [ ] Build BRAM-safe 1R1W variants for phase and filter-history storage and
  verify read-during-write behavior with focused collision tests.
- [ ] Compare separate and selectively packed state banks across multiple
  implementation seeds.
- [ ] Carry mono/stereo mode into the DSP schedule and interpolate mono input
  once before independent left/right gain.
- [ ] Measure endpoint arrival rate under the selected memory/block renderer
  before choosing filter-channel multiplier reuse or a dedicated bypass lane.
- [ ] Record LUT, LUTRAM, BRAM, DSP, power estimate, initiation interval, and
  worst-case frame time for every candidate.

### P1: Descriptor-Based Control Plane

- [ ] Define an asset descriptor table for mono/stereo base addresses, lengths,
  loops, and reusable default parameters.
- [ ] Load descriptors with the wave asset or through a separately validated
  bulk-control path.
- [ ] Replace repeated DEFINE plus START traffic with an atomic descriptor-based
  START event.
- [ ] Use compact opcode-specific event payloads for gain/phase, filter,
  envelope, RELEASE, STOP, and global effects.
- [ ] Remove prepared RAM only after packet atomicity and descriptor validation
  make partial definitions unobservable.
- [ ] Compare command bandwidth, event latency, control RAM size, intermediate
  action representation, and the prepared-RAM critical path against the current
  baseline.

### P1: Timestamped Scheduling

- [ ] Define one monotonic rendered/played audio-frame counter domain.
- [ ] Give each event a target frame and specify late-event behavior.
- [ ] Ensure a block renderer stops or splits at an event boundary rather than
  applying an event to an entire block incorrectly.
- [ ] Define the host scheduling horizon from current render lead, packet latency,
  and retry margin.
- [ ] Test simultaneous events, wraparound, late arrival, retry, reset, and
  renderer underrun recovery.

### P1: Local Parameter Ramps And Modulation

- [ ] Define gain and phase-increment ramp events with target value, start
  frame, duration, rounding rule, and interruption behavior.
- [ ] Quantify command-bandwidth and scheduler-work reduction at maximum
  polyphony using the real MIDI/SoundFont harness.
- [ ] Evaluate local vibrato, tremolo, and simple modulation-envelope state
  while keeping preset selection and voice-allocation policy in host software.
- [ ] Define a stability-preserving filter-update contract before adding filter
  ramps or local cutoff modulation.
- [ ] Add exact boundary tests for overlapping ramps, STOP/RELEASE, voice reuse,
  generation rejection, and block splits.

### P1: Overlapped Audio Pipeline

- [ ] Separate renderer credit from effect-engine busy.
- [ ] Prototype ping-pong block accumulators between renderer, effects,
  compressor, and output.
- [ ] Prove each boundary holds data under backpressure without drop,
  duplication, or frame reordering.
- [ ] Measure whether overlap permits lower PCM target lead without increasing
  underrun risk.
- [ ] Preserve deterministic fixed-rate I2S behavior during startup, reset, and
  downstream starvation.

### P2: Per-Voice Effect Sends

- [ ] Add chorus and reverb send levels to descriptor/runtime event definitions.
- [ ] Carry send values through the voice DSP.
- [ ] Accumulate separate dry, chorus-send, and reverb-send stereo buses at full
  exact mix width.
- [ ] Feed the spatial effects from send buses while retaining independent
  return gains and chorus-to-reverb routing.
- [ ] Add exact C++/RTL comparisons and real MIDI/SoundFont listening regressions.

### P2: Unified Audio Timeline

- [ ] Model rendered, effect-complete, compressor-look-ahead, output-ready, and
  played positions as explicit frame counters.
- [ ] Evaluate a shared multi-reader ring against separate compressor delay and
  output-reservoir memories.
- [ ] Account for RAM port count, stored width, gain association, reset priming,
  backpressure, and underrun recovery.
- [ ] Select one explicit real-time reservoir and document which stages provide
  algorithmic delay versus scheduling safety margin.
- [ ] Target lower latency only after the worst-case DDR/effect/control workload
  maintains a positive minimum lead.

### P2: Internal Audio Precision

- [ ] Instrument the reference and RTL-compatible render paths to report
  per-voice pre-saturation peaks and clipping counts.
- [ ] Compare PCM16, 20-bit, and 24-bit voice-contribution formats with exact
  accumulator-width derivations and explicit headroom policy.
- [ ] Run exact C++/RTL regressions, representative listening comparisons, and
  post-route resource/timing comparisons before changing the numeric contract.
- [ ] Keep the current PCM16 boundary unless the wider path demonstrates a
  measurable audio benefit within the implementation budget.

### P2: Audio Clock And Recovery Contract

- [ ] Decide whether the supported product contract is fixed 48 kHz or truly
  sample-rate configurable.
- [ ] If configurable, generate or validate every sample-rate-dependent effect
  delay, compressor timing, host preset, and scheduling constant coherently.
- [ ] Define the board audio-clock source, MCLK, I2S slot format, codec reset,
  configuration, and mute sequencing.
- [ ] Specify and test pop-free underrun mute, played-frame resynchronization,
  reservoir reprime, and restart behavior.
- [ ] Separate always-on health counters from qualification-only performance
  instrumentation and add a coherent diagnostic snapshot command.

## Dependency Order

The architecture should not be implemented as one repository-wide rewrite.
Use the following dependency order:

1. Preserve a reproducible baseline and add the board-equivalent Smart Artix
   performance top before drawing further capacity conclusions.
2. Establish the always-on control/status island, bounded memory-fault behavior,
   and asset address/integrity contract.
3. Fix packet atomicity and define timestamped events and parameter ramps.
4. Model block rendering and candidate shared-cache behavior in C++.
5. Introduce the line/burst memory interface and a selectable RTL prototype.
6. Consolidate voice dynamic-state ownership, physical state banks, and active
   traversal.
7. Introduce manifest-backed descriptor START while retaining a compatibility
   host path.
8. Re-evaluate renderer state RAM mapping and DSP sharing against the selected
   endpoint supply rate.
9. Add block accumulators and overlap renderer/effects/output execution.
10. Add per-voice effect sends and evaluate wider internal voice precision.
11. Finalize the audio clock, codec, timeline, underrun mute, and restart
    contract.
12. Remove legacy command, prepared-state, word-request, and cache structures
    only after exact comparison and hardware gates pass.

Optimizing the current DSP initiation interval or intermediate endpoint/action
representations should wait until the block-render and memory decisions are
complete. Those boundaries may disappear in the target architecture.

## Acceptance Gates

Every architecture replacement must meet all applicable gates before becoming
the default path:

1. Exact integer output matches an independent C++ model for mono/stereo,
   interpolation, all loop modes, envelope stages, runtime changes, filtering,
   mixing, effects, compressor rounding, and saturation.
2. Commands have deterministic audio-frame eligibility, including block
   boundaries, late packets, retry, duplicate suppression, and sequence
   rejection.
3. Full-polyphony mono and stereo stress complete within the 2083-clock average
   frame budget in the board-equivalent Smart Artix top under the qualified DDR
   profiles, with bounded worst-case recovery and no hidden request or response
   loss.
4. Output minimum lead remains positive after startup in long stress renders;
   underrun and drop counters remain zero for the qualified workload.
5. Cache results report useful fetched-word ratio, miss rate, merged misses,
   outstanding occupancy, prefetch usefulness, and replacement behavior.
6. Packet tests exhaust CS truncation points, length and CRC corruption,
   transport-capacity exhaustion, ACK loss, duplicate retry, and clock-domain
   reset interaction.
7. `make lint` and `make test` pass, with focused self-checking RTL tests added
   for every changed protocol or behavior.
8. A forced Smart Artix implementation fits, closes setup and hold timing, and
   records hierarchical LUT/FF/DSP/BRAM changes and critical-path ownership.
   The selected architecture also passes the defined setup-margin target across
   the required placement seeds.
9. Stable contracts in `fixed_point.md`, `memory_format.md`, `register_map.md`,
   host documentation, and the C++ reference are updated in the same change.
10. The always-on control path remains readable and can force mute when DDR
    calibration fails, is lost, or a memory transaction times out.
11. Asset publication proves image integrity and all descriptor byte ranges fit
    one validated manifest region without arithmetic overflow or MIG-address
    truncation.
12. Audio startup, starvation, reprime, and restart tests produce the specified
    frame sequence without uncontrolled output discontinuities.

## Open Decisions

- [ ] Select render block size: 8, 16, 32, or adaptive to the next event.
- [ ] Select active traversal: hierarchical bitmap or dense ID table.
- [ ] Select cache geometry and outstanding miss count from measured workloads.
- [ ] Decide whether DDR responses remain ordered or carry explicit IDs.
- [ ] Define the always-on clock source, retained status set, reset ownership,
  and recovery authority.
- [ ] Define memory transaction deadlines, arbitration guarantees, and the
  behavior of in-flight work when calibration is lost.
- [ ] Define asset-manifest and descriptor-table ownership, loading format,
  integrity fields, and generation behavior.
- [ ] Decide whether diagnostic DDR writes are prohibited during playback or
  participate in a specified cache-coherency protocol.
- [ ] Define target-frame width, wrap semantics, and late-event policy.
- [ ] Define which runtime parameters support ramps and how a new event
  interrupts an active ramp.
- [ ] Decide whether compatibility DEFINE/START commands remain in a translation
  layer or are removed from the hardware protocol.
- [ ] Decide whether renderer phase/filter state remains in distributed RAM or
  moves to BRAM based on implementation results.
- [ ] Decide whether the voice-to-mix numeric boundary remains PCM16 or gains
  wider internal headroom.
- [ ] Decide whether compressor look-ahead and output buffering share a logical
  timeline while retaining separate physical RAMs.
- [ ] Freeze a 48 kHz-only audio contract or define coherent generation and
  validation of every sample-rate-dependent parameter.
- [ ] Define audio clock, codec MCLK/slot/configuration, underrun mute, and
  restart behavior for the target board.
- [ ] Define always-on versus qualification-only diagnostics and the required
  coherent snapshot scope.
- [ ] Establish the qualified maximum SPI rate and DDR stall profile from board
  measurements before freezing transport and reservoir capacities.
