# Real-Time MIDI Host And SF2 Efficiency Backlog

This document tracks host-side work required to turn the current offline
MIDI/SF2 render harness into a bounded-latency PC application that sends the
existing voice command stream to the FPGA through a CH347 adapter. It also
tracks SF2 loader changes needed for the intended SGM v2.01 soundfont workload.

This is a backlog, not a current behavior contract. Command encoding and host
ownership remain defined by [`../command_stream.md`](../command_stream.md) and
[`../host/host_control.md`](../host/host_control.md). SPI electrical and
transport qualification remains in [`spi_transport.md`](spi_transport.md).

Status reviewed against the C++ loader, MCU model, command builder, and CH347
transport on 2026-07-31.

## Target And Measured Baseline

The intended production workload is the external
`SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2` file, not the small
`assets/soundfonts/MT6276.sf2` regression fixture.

The reviewed SGM file is 324,800,670 bytes. Loading it through the current C++
render path reached approximately 1,829,456 KiB peak RSS before WAV output and
took approximately 3.5 seconds for load and preparation. The main cause is
multiple owning copies of the complete `sdta/smpl` payload in addition to the
raw file, `file_words`, and `Sf2Data::smpl`.

The current real-time-relevant baseline is:

- SF2 parsing and all MIDI events are prepared before offline rendering;
- region preparation caches exact `(program or instrument, bank, key,
  velocity)` combinations only for one render session;
- the MCU control tick scans all configured voice slots and evaluates active
  modulation using floating-point transcendental functions;
- unchanged gain, pitch, and filter commands are suppressed;
- volume envelopes run in the FPGA and do not require per-frame host traffic;
- `CommandVoiceControl` allocates vectors while building commands;
- `Ch347RegisterTransport` performs a synchronous driver call for each command;
- the wire format permits multiple complete commands in one 63-word
  transaction, but current producers send one command per CS assertion.

## Priority 1: SF2 Loading Memory

- [x] Replace owning RIFF child-chunk vectors with checked non-owning byte
  ranges expressed as an offset and size into one source image.
- [x] Scan the top-level RIFF and child chunk tables once rather than separately
  locating `INFO`, `sdta`, `pdta`, and the `smpl` offset.
- [x] Remove the complete `Sf2Data::smpl` copy. Retain `smpl_word_offset` and a
  checked `smpl_word_count`; sample PCM already exists in `file_words`.
- [x] Reserve exact record counts before parsing preset, bag, generator,
  modulator, instrument, and sample-header vectors.
- [x] Keep only the complete word-addressed file image required by the FPGA and
  the compact parsed metadata after loading finishes.
- [x] Add a repeatable loader benchmark that reports file size, load time, peak
  RSS, retained bytes, and metadata record counts.
- [x] Keep the synthetic loader fixture as the required functional regression;
  make the external SGM benchmark optional and path-configurable.

First acceptance target:

- SGM peak RSS is below 700 MiB;
- retained memory is the approximately 310 MiB file image plus metadata;
- all current exact region and generator tests remain unchanged.

The completed loader plus Priority 3 compiler measured 2.032 seconds load time,
687,271,936 bytes peak RSS, and 339,445,748 estimated retained bytes for the
324,800,670-byte SGM file with the optimized benchmark build on 2026-08-01.
The compiled lookup accounts for approximately 14,159,110 retained bytes and
contains 15,714 preset candidates plus 3,326 instrument candidates.

A later streaming reader or read-only file mapping may reduce peak RSS closer
to the retained image size. It is not required for the first loader rewrite.

## Priority 2: SF2 Region Preparation

- [x] Remove linked- and unlinked-stereo merge branches that are unreachable
  under the current one-mono-region-per-voice contract.
- [x] Preserve linked stereo as two adjacent mono regions and therefore two
  voice starts.
- [x] Consolidate the duplicated preset and forced-instrument region builders
  behind one checked region-construction helper.
- [x] Remove the unused mutable wave-memory parameter from region construction
  APIs. Keep final address validation at the render/session boundary.
- [x] Separate binary table parsing, zone expansion, and numeric Region
  conversion so each layer can be tested independently.
- [x] Reject or explicitly normalize malformed sample bounds, loop bounds,
  terminal records, and duplicate chunks; add focused fixtures for each rule.

## Priority 3: Compiled SoundFont Lookup

No real-time Note On path should scan the SF2 file or rebuild global/local zone
inheritance.

- [x] Build a `(bank, program)` preset lookup during soundfont loading.
- [x] Build exact and case-folded instrument indexes during loading.
- [x] Expand preset and instrument global zones once.
- [x] Resolve generator precedence and modulator replacement/addition once per
  playable zone combination.
- [x] Index candidate zones by MIDI key so Note On only evaluates the remaining
  velocity ranges.
- [x] Group compiled modulators by destination instead of repeatedly scanning
  every modulator for gain, pan, pitch, and filter calculations.
- [x] Add a persistent bounded Region cache suitable for both offline rendering
  and a long-running host process.
- [x] Include output sample rate and control policy in cache identity wherever
  they affect converted values.
- [x] Define cache invalidation when a soundfont or output configuration changes.

The real-time lookup must have bounded work, no file access, and no unbounded
container growth. Full precomputation of every velocity is not required if a
bounded on-demand cache meets the latency target.

The compiled representation is owned by one immutable `Sf2Data` instance, so
replacing a soundfont means replacing that object and its cache together. The
bounded LRU cache stores both playable and empty lookup results, defaults to
4096 entries, and clears whenever output sample rate or control-tick length
changes. Its immutable shared results remain valid for callers after eviction.

## Priority 4: Bounded MCU Control Work

- [x] Maintain a compact active-voice set instead of scanning every silent slot
  on every control tick.
- [x] Track dirty controller and generator groups so an unrelated controller
  does not recompute all gain, pitch, and filter state.
- [x] Replace repeated pitch-ratio, attenuation, and pan transcendental calls
  with validated lookup tables or bounded fixed-point approximations.
- [x] Quantize and cache filter coefficients by cutoff, resonance, and output
  sample rate.
- [x] Retain exact output-change suppression before command generation.
- [x] Give gain, pitch, and filter independent maximum update rates. Filter
  modulation should normally run slower than pitch or gain modulation.
- [x] Add timing counters for control-tick duration, active voices, modulator
  evaluations, dirty groups, and emitted commands.
- [x] Benchmark 128, 256, and 512 active mono voices with representative SGM
  modulators and controller traffic.

Optimization must preserve the existing reference results. Approximation
tables need exhaustive or high-coverage comparison against the current
floating-point functions with documented maximum error.

The bounded implementation uses a dense active set and destination dirty masks.
Gain and pitch run at most once per tick; filter modulation defaults to once per
four ticks, while event-driven changes remain immediate. Quarter-cent pitch,
eighth-centibel attenuation, and integer-pan tables remove the repeated hot-path
transcendental calls. A 4096-entry fixed filter cache quantizes cutoff to one
cent and resonance to two centibels. The validation sweep covers quarter-cent
pitch, eighth-centibel attenuation, and filter points across 44.1, 48, and
96 kHz. Its measured maximum filter deviation is 89 Q2.14 LSB against the old
formula, below the enforced 96-LSB limit; pitch phase and attenuation are exact
on their validation grids.

On the 2026-08-01 development container, `make benchmark-mcu-control` measured
average/max tick durations of 48/115 us at 128 voices, 82/148 us at 256 voices,
and 94/125 us at 512 voices for the representative modulator/controller load.
These are host measurements, not a target-PC release qualification.

## Priority 5: Allocation-Free Command Construction

- [x] Introduce a fixed-capacity command value containing at most 17 words and
  an explicit length.
- [x] Remove the `initializer_list -> payload vector -> command vector`
  allocation chain from `CommandVoiceControl` and global audio control.
- [x] Extend or replace `CommandWordSink` with a non-owning command-word view
  while retaining adapters for existing tests and reference sinks.
- [x] Encode CH347 transactions directly into a fixed 256-byte buffer.
- [x] Replace bit-at-a-time CRC16 in the hot path with a verified table-driven
  or otherwise bounded implementation.
- [x] Keep the current CRC implementation as an independent test oracle.

Command construction and queue insertion on the control thread must not
perform heap allocation after application initialization.

`FixedCommand` owns a 17-word array and explicit length. All command consumers
accept `CommandWordView`; deferring sinks copy into fixed owned storage. The
frame-batched queue is a fixed 1024-entry ring and rejects overflow. A unit-test
allocation probe covers voice/global command construction plus queue insertion
and application. CH347 uses the final fixed transaction buffer directly, and
4096 generated transactions compare the table-driven CRC with the retained
bit-at-a-time oracle.

## Priority 6: Asynchronous CH347 Command Scheduling

The MIDI/control path must never block on a USB driver call.

```text
timestamped MIDI input
  -> bounded event queue
  -> voice allocation and control policy
  -> prioritized bounded command queue
  -> SPI worker and 63-word transaction coalescer
  -> CH347
```

- [x] Add a dedicated SPI worker that owns `Ch347RegisterTransport` and all
  blocking driver calls.
- [x] Use bounded queues with explicit overload behavior between MIDI input,
  control processing, and SPI output.
- [x] Coalesce multiple complete commands into one transaction without
  exceeding 63 words or splitting a command.
- [x] Keep the two mono starts for one linked-stereo note adjacent.
- [x] Prioritize START, RELEASE, STOP, and recovery actions over replaceable
  continuous modulation updates.
- [x] Coalesce queued gain, pitch, and filter replacements per voice and
  generation so only the newest unsent value remains.
- [x] Never discard Note Off, RELEASE, STOP, generation changes, or transport
  recovery actions as an overload shortcut.
- [x] Record queue high-water marks, coalesced updates, dropped replaceable
  updates, transaction sizes, driver latency, and maximum command age.
- [x] Provide a dry-run transport that exercises the same scheduler without
  opening hardware.

FPGA FIFO preflight and physical transport-recovery qualification remain
dependent on the open items in [`spi_transport.md`](spi_transport.md).

The completed scheduler uses fixed lifecycle and normal rings plus fixed
per-voice replacement slots. It retries the unchanged failed transaction,
records persistent-failure abandonment explicitly during shutdown, and keeps
all CH347 calls on its worker thread. The MIDI queue separately reserves 256 of
2048 entries for Note Off and mode recovery.

## Priority 7: Real-Time MIDI Application

- [x] Add a PC application entry point using the shared SF2 compiler, MCU
  policy, command builder, and CH347 scheduler rather than duplicating them.
- [x] Select a MIDI input API and define supported host platforms.
- [x] Preserve source MIDI timestamps through the event queue.
- [x] Define how timestamps map to the FPGA renderer's block-boundary command
  visibility; the current command format has no target-frame timestamp.
- [x] Load and compile the soundfont before opening the real-time performance
  path.
- [x] Retain one `CommandVoiceControl` instance for the process lifetime so
  voice generations cannot reset between events.
- [x] Reuse voice allocation, sustain, sostenuto, exclusive-class, pitch-bend,
  pressure, and controller policy from the simulation harness.
- [x] Handle MIDI-device disconnect, CH347 failure, queue overload, and explicit
  stop/reset without leaving unknown active voices.
- [x] Report Note On command latency, scheduling jitter, queue depth, transport
  errors, active voices, and voice steals.

The application supports Linux raw-MIDI character devices, standard-input byte
streams, and direct real-time playback of format 0/1 PPQ Standard MIDI Files.
Raw input timestamps each completed message with the monotonic time captured at
`read(2)`. File playback parses the complete tempo map before starting and maps
each event time to the same monotonic clock. Because commands do not contain a
target frame, delivered state is visible at the next admitted FPGA render-block
boundary. SoundFont loading, compilation, and SMF parsing finish before the
performance clock starts; the bounded region registry refuses to recycle any
region referenced by an active MCU voice.

ALSA Sequencer input, including direct `aplaymidi` routing, is still not part of
this entry point. The application can play the same SMF itself with
`--midi-file`; live Sequencer routing requires a future backend or a virtual
raw-MIDI bridge that exposes a `/dev/snd/midiC*D*` path.

## Priority 8: Bandwidth And Protocol Follow-Up

Host CPU optimization cannot compensate for an oversubscribed SPI link. The
current throughput analysis estimates approximately 11.469 Mbps for 512 voices
receiving gain, pitch, and filter updates at 50 Hz with one command per CS,
which exceeds the current 7.5 MHz stress point.

- [ ] Measure reliable CH347 command throughput at the actual 937.5 kHz,
  1.875 MHz, 3.75 MHz, and 7.5 MHz selections.
- [ ] Measure transaction gaps and USB driver latency, not only SCLK frequency.
- [ ] Establish update-rate and change-threshold budgets for gain, pitch, and
  filter traffic.
- [ ] Prove that the command queue remains bounded during the maximum supported
  polyphony and controller workload.
- [ ] Evaluate FPGA-side gain, pitch, and filter ramps if host-side coalescing
  cannot meet audible quality and bandwidth targets.
- [ ] Evaluate moving periodic LFO behavior to the FPGA only through an explicit
  command-contract and RTL change with the required verification gates.

Do not treat 7.5 MHz as a released operating rate until the physical SPI and
CDC qualification in `spi_transport.md` is complete.

## End-To-End Acceptance

- [x] `make lint`, `make test`, and documentation checks pass after each
  applicable change.
- [ ] The SGM workload loads within the memory targets and produces the same
  selected regions and exact fixed-point fields as the approved baseline.
- [x] The Note On hot path performs no file access, no unbounded allocation, and
  no synchronous USB operation.
- [ ] Control work meets its deadline for the declared maximum active voices
  with measured headroom on the target PC class.
- [x] Command queues remain bounded and lifecycle commands survive modulation
  overload.
- [ ] Dry-run, C++ reference, RTL simulation, and physical CH347 paths share the
  same command encoding and scheduling policy.
- [ ] Hardware testing records requested and selected SCLK, transaction
  latency, queue statistics, parser/transport errors, render deadline misses,
  and audio underruns.
