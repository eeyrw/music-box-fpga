# MCU SoundFont Asset Compiler Backlog

This document proposes an offline SoundFont compiler and a packed MCU-side
metadata image for real-time MIDI control. It is a backlog design, not a current
asset or firmware contract. Stable behavior remains defined by
[`../command_stream.md`](../command_stream.md),
[`../fixed_point.md`](../fixed_point.md),
[`../memory_format.md`](../memory_format.md), and
[`../board/asset_loading.md`](../board/asset_loading.md).

The central constraint is that this work must not require production RTL
changes. The compiler moves SF2 parsing, zone inheritance, finite-domain table
generation, and output-format conversion out of the MCU hot path. The MCU still
owns MIDI policy and sends the existing version-13 command stream. The FPGA
continues to own sample-rate phase, volume-envelope progression, filtering,
mixing, effects, and I2S scheduling.

## Motivation

The current C++ path already compiles important parts of a SoundFont at load
time:

- preset lookup by `(bank, program)`;
- preset and instrument global-zone expansion;
- generator precedence and modulator replacement/addition;
- key-indexed playable candidates with a remaining velocity-range check;
- modulators grouped by destination;
- a bounded cache of converted `Region` values;
- active-voice sets, dirty destination groups, numeric lookup tables, and
  output-change suppression in the control loop.

This establishes the required SoundFont semantics, but its retained
representation is a C++ process representation. It contains `std::map`,
`std::vector`, `std::string`, shared ownership, heap-backed LRU entries, and
host-sized indices. A cache miss still converts a compiled zone into a wide
`Region` containing names, maps, and values used only by diagnostics. That is
appropriate for simulation and a PC host, but not for a small deterministic
MCU runtime.

The measured SGM v2.01 baseline in [`realtime_midi_host.md`](realtime_midi_host.md)
contains 15,714 compiled preset candidates and 3,326 instrument candidates. Its
current compiled lookup alone retains approximately 14.2 MB in the host C++
representation. This is evidence that the semantic expansion is practical; it
is not the expected size of a packed image.

The proposed compiler turns that semantic result into an immutable,
pointer-free binary image. At performance time the MCU performs bounded index
lookups and small integer evaluations. It does not parse RIFF, inspect SF2 bags,
resolve zone inheritance, allocate containers, call floating-point
transcendental functions, or build a general-purpose `Region`.

## Goals

- Compile one SF2 into deterministic MCU metadata before deployment.
- Precompute every result whose inputs are fixed by the SF2 and selected output
  profile.
- Tabulate finite input domains when that materially reduces MCU work without
  causing uncontrolled image growth.
- Keep Note On lookup bounded by the selected preset's key entry and its small
  velocity partition.
- Represent runtime modulation as compact fixed-point data and dependency
  metadata rather than maps or general C++ objects.
- Build existing `VOICE_START_MONO`, `VOICE_RELEASE`, `VOICE_STOP`,
  `VOICE_GAIN`, `VOICE_PITCH`, and `VOICE_FILTER` commands without heap
  allocation.
- Permit the same compiled image reader and MCU policy core to run in host
  tests, the C++ reference path, and eventual MCU firmware.
- Detect incompatible metadata, wave images, output profiles, and command
  interface versions before enabling audio.
- Report image size, lookup fanout, worst-case work, and target-MCU timing as
  first-class build artifacts.

## Non-Goals

- Do not change synthesizable RTL, FPGA parameters, or FPGA source lists.
- Do not add a writable per-voice register window or a typed simulation bypass.
- Do not add timestamps to the command stream or change block-boundary command
  visibility.
- Do not move MIDI parsing, preset policy, voice allocation, pedal behavior, or
  runtime controller state into the FPGA.
- Do not move modulation envelopes or LFOs into the FPGA in this work.
- Do not change the current mono-voice rule. Linked SF2 stereo remains two
  adjacent host-owned mono voice starts.
- Do not require the FPGA SD loader to parse MCU metadata.
- Do not initially compact or relocate PCM sample data in DDR.
- Do not make generated MCU assets synthesis inputs or commit generated binary
  output outside `build/`.

## Preserved RTL And Board Contracts

The first implementation must preserve all of the following:

1. `VOICE_START_MONO` remains the only voice-install command. Its flags,
   optional sections, Q24.8 phase increment, Q1.15 gains, filter coefficients,
   envelope fields, and 16-bit generation retain their documented meanings.
2. Runtime gain, pitch, filter, release, and stop commands retain their current
   payloads and stale-generation behavior.
3. Commands become visible only at render-block boundaries after command drain.
4. The FPGA volume envelope remains sample-rate state. The MCU supplies only
   the converted initial parameters and the release step.
5. Wave addresses remain 16-bit word addresses into the exact byte image loaded
   by the existing WTSF flow.
6. The production SPI `0xa5` transport, transaction word limit, CRC, and command
   batching rules remain unchanged.
7. The board loader continues to receive the current WTSF image containing the
   complete SF2 byte image. The first MCU metadata image is a sidecar consumed
   only by the MCU or host.

The sidecar and WTSF image must be compiled from the same source SF2. Both carry
the same source-content digest. Firmware must refuse to start voices when the
digests or declared sample address span disagree. This prevents a valid MCU
descriptor from addressing a different wave image.

A future PCM-only WTSF payload could reduce storage and DDR load time because
the current FPGA loader treats the payload as opaque bytes. That would still
change the stable board asset contract, host tooling, address generation, and
verification. It is explicitly a separate future proposal and is not part of
this backlog's first implementation.

## Build-Time And Runtime Architecture

```text
development host
  SF2 + output profile + command interface version
    -> existing checked SF2 parser
    -> expanded preset/instrument semantic IR
    -> finite-domain precomputation and table deduplication
    -> packed image writer
    -> image verifier and manifest
          |                         |
          |                         +-> existing WTSF image, unchanged
          +-> MCU metadata sidecar

MCU startup
  verify header, CRC, profile, source digest, and table bounds
    -> create read-only asset view with no reconstruction

MCU real-time path
  MIDI event
    -> channel/preset state
    -> preset + key + velocity dispatch
    -> one or more immutable mono layer descriptors
    -> note-static table values + current channel modulation
    -> voice allocation and generation
    -> existing fixed command builder and asynchronous scheduler
    -> SPI opcode 0xa5

FPGA
  unchanged command parser -> unchanged voice-major renderer -> unchanged I2S
```

The compiler is allowed to use STL, dynamic memory, floating point, and
expensive exhaustive validation. The image reader and control-time evaluator
must not require any of them.

## Output Profile

Values such as phase increments, duration steps, LFO steps, and filter
coefficients depend on deployment choices. Each compiled image therefore names
one exact output profile:

- output sample rate;
- control-tick numerator and denominator or exact tick length in samples;
- command interface version;
- fixed-point/compiler numeric-policy version;
- file-attenuation compatibility policy;
- pan-law version;
- filter coefficient quantization policy;
- enabled SoundFont feature subset.

The initial profile should be the production configuration chosen for the
first MCU, normally 48 kHz and one fixed control-tick length. Supporting several
sample rates in one image is not a first-version requirement. Separate images
are simpler, smaller, and make mismatch rejection unambiguous.

Changing any profile field invalidates all fields derived from it. The compiler
must rebuild the whole sidecar rather than patching individual tables.

## Packed Image Requirements

The image is a serialized format, not a dump of C or C++ structs.

- All integer widths and signedness are explicit.
- Version 1 uses little-endian integers unless the final MCU requires a
  different canonical order.
- Every section is naturally aligned to at least four bytes.
- References are 32-bit image-relative byte offsets or typed 32-bit indices,
  never native pointers or `size_t`.
- Counts precede variable-length arrays, and every `offset + count * stride`
  expression is checked with widened arithmetic.
- Runtime-required tables are fixed-stride or offset/count views.
- Diagnostic strings are optional and live in a separate section that firmware
  can omit from flash.
- Empty preset/key/velocity results are encoded explicitly and require no
  allocation.
- A whole-image CRC protects storage corruption. Per-section CRCs are optional
  for diagnosis but do not replace whole-image validation.
- The writer emits sections in a stable order and canonicalizes all interning,
  so identical input and tool version produce byte-identical output.

### Proposed Header

The exact layout becomes a stable contract only when implementation begins.
The version-1 design should contain at least:

| Field | Purpose |
| --- | --- |
| magic and format version | Reject unrelated or unsupported images. |
| header size and total size | Permit compatible extension and complete bounds checks. |
| command interface version | Reject descriptors built for another command layout. |
| compiler/numeric-policy version | Identify conversion and compatibility behavior. |
| output sample rate and tick samples | Bind all derived timing values. |
| source SF2 size and digest | Match the WTSF wave image. |
| sample word offset/count | Validate every descriptor address against loaded DDR data. |
| section directory offset/count | Locate typed tables without fixed native structs. |
| maximum layers per Note On | Size bounded MCU batches before enabling input. |
| maximum modulation terms per destination | Establish control-loop worst-case work. |
| whole-image CRC | Detect corrupt or partial storage. |

The section directory identifies section type, element stride, offset, count,
and optional CRC. Unknown optional sections may be skipped; unknown required
sections reject the image.

## Logical Tables

### Preset Directory

Store only present `(bank, program)` pairs in sorted order. A compact sorted
array plus binary search is deterministic and normally preferable to a native
hash table. A generated two-level bank/program index may be selected later if
target measurements show lookup latency matters.

Each preset record points to exactly 128 key-dispatch records. Instrument-name
lookup and diagnostic names are not required by the performance firmware and
belong in an optional diagnostic section.

### Key And Velocity Dispatch

Each key-dispatch record contains an offset and count into a velocity-span
table. A span contains:

- inclusive velocity low and high bounds;
- offset and count of the ordered mono layers selected in that span;
- optional note-initialization table identifier;
- flags for an empty result or linked-stereo adjacency requirements.

Adjacent velocities with identical layer selection are represented as one
span. This preserves exact SF2 range selection without materializing a dense
`preset x 128 x 128` matrix.

The compiler must preserve source-defined layer order. Linked stereo and
compatible stereo pairs remain two adjacent mono layer references, and the MCU
scheduler must publish their START commands in one producer batch.

### Mono Layer Descriptor

A layer descriptor contains only immutable or table-selected control values:

- absolute SF2 word address, sample length, loop start, exclusive loop end, and
  loop mode;
- sample rate, root key, pitch correction, scale tuning, and precomputed base
  phase data;
- base left/right gain, pan, file attenuation, and stereo routing policy;
- fixed FPGA volume-envelope delay, attack, hold, decay, sustain, and release
  fields for the selected output profile;
- initial filter enable and coefficients;
- exclusive class and preset identity used by MCU allocation policy;
- IDs for note-initialization and runtime-modulation programs;
- compact dependency masks for gain, pitch, and filter;
- flags describing which optional START payload sections are present.

Names, generator maps, modulator vectors, `double` values, and reference-model
diagnostics do not belong in this record.

The compiler should also intern the six envelope words and three filter words
when measured data shows useful duplication. Interning is an image-size choice,
not an excuse to add unbounded runtime pointer chasing; maximum reference depth
is one table lookup.

### START Command Template

For each layer, the compiler may store a prepacked START template containing
every word that is independent of voice slot, generation, and live MIDI channel
state. The MCU patches only:

- header voice ID;
- generation;
- phase increment when live pitch state changes the base value;
- left/right gain when live attenuation or pan changes it;
- filter words when live modulation changes the initial filter.

The template must still pass through the shared `CommandVoiceControl` semantics
or a verified equivalent packer. Directly transmitting opaque compiler bytes
without validating generation and payload length would create a second command
contract and is not allowed.

## Precomputation Policy

"Precompute everything possible" means that no function of only the SF2 and
output profile remains in the MCU. It does not require an uncompressed table for
every Cartesian product.

### Always Precomputed

- RIFF validation and all `pdta` parsing.
- preset/instrument global and local zone inheritance.
- key and velocity range intersections.
- generator defaulting, precedence, addition, and range normalization.
- default/file modulator replacement and addition.
- sample address adjustment, bounds validation, loop normalization, and linked
  sample expansion.
- file-defined attenuation compatibility scaling.
- destination grouping and source-dependency masks.
- output-profile duration conversions and FPGA envelope fields.
- sample-rate ratio constants, root-key correction, base phase values, LFO
  increments, and static filter values.
- reusable source transform tables, attenuation curves, pan factors, and pitch
  ratios.
- optional START word templates.

### Finite-Domain Tables

MIDI note, velocity, CC, pressure, and pan are bounded seven-bit domains. The
compiler should evaluate these domains offline when the result can be shared or
compressed:

- the standard linear, concave, convex, switch, bipolar, and direction source
  curves use shared 128-entry tables;
- note-key contributions may use a per-program or per-modulation-program
  128-entry table when this is smaller than repeated runtime terms;
- velocity-dependent static contributions may use an interned 128-entry table;
- phase values may be stored per playable key range when that is smaller and
  faster than one multiply plus a shared ratio lookup;
- identical tables are content-addressed and stored once.

Pitch bend is a 14-bit domain. A full table is allowed only when it is shared
globally and fits the selected memory budget. Otherwise use the already
validated bounded fixed-point interpolation table. The manifest must report
which representation was selected.

### Size-Guided Choice

The compiler should support at least two policies:

- `compact`: interval dispatch, shared source tables, and small fixed-point
  runtime programs;
- `precomputed`: additionally materialize note/key/velocity tables when doing
  so removes MCU multiplies or branches within the configured image budget.

Both policies must produce the same selected layers and command-visible
quantized results. The build report compares their size and worst-case
operation counts on the target SF2. The deployment policy is selected from
measured target-MCU timing and available nonvolatile storage, not from a blanket
assumption that either arithmetic or flash is free.

## Modulation Representation

The MCU must not interpret the general SF2 object model. The compiler resolves
each candidate into at most three destination programs:

- gain and pan;
- pitch;
- filter cutoff and resonance.

Each program is an offset/count view of fixed-stride terms. A term identifies:

- primary source state slot and precompiled source curve;
- optional amount source state slot and curve;
- signed fixed-point amount;
- transform;
- destination accumulator and scale;
- note-static or live dependency classification.

The first version should prefer a typed term array over a general branch-capable
bytecode. SoundFont modulators are multiply-and-accumulate expressions; an
unrestricted virtual machine would add validation and worst-case execution
problems without representing needed behavior more compactly.

The compiler folds constants, removes zero terms, combines identical terms
where exact arithmetic permits it, and separates note-static contributions from
live channel/LFO/envelope contributions. Programs and term arrays are globally
interned.

### Runtime Source State

Each MIDI channel keeps a fixed-size source-state record containing CC values,
pitch bend, pressure, RPN-derived bend range and tuning, and pretransformed
values for sources used by any active program. A controller event updates the
raw field and only the affected transformed slots.

Each active voice keeps only:

- slot, generation, channel, note, velocity, and immutable layer ID;
- note instance and allocation-policy state;
- modulation-envelope and LFO phase/state still owned by the MCU;
- last emitted gain, phase increment, and filter tuple;
- dirty and dependency masks.

No active voice owns or copies a modulator list.

### Control Tick

The periodic loop walks the dense active-voice set. It advances only MCU-owned
modulation state, intersects dirty source groups with each layer's dependency
masks, evaluates due destinations, and suppresses unchanged command results.
Gain and pitch may run every tick; filter retains an independently configurable
slower maximum rate. Event-driven changes remain immediate.

All arithmetic in this path must be integer or fixed point. Saturation,
rounding, accumulator widths, and approximation error limits must be documented
before replacing the current C++ reference expressions.

## Work That Remains Dynamic

The following inputs are not known at asset compile time and remain MCU work:

- incoming event order and timestamps;
- current bank, program, CC, pressure, pitch bend, RPN/NRPN, and tuning state;
- voice allocation, release matching, stealing, and generation assignment;
- sustain, sostenuto, soft pedal, exclusive-class actions, and mode messages;
- the current value of MCU-owned modulation envelopes and LFOs;
- transport queue pressure, batching, retry, and command age;
- final composition of values affected by current channel or modulation state.

These operations must nevertheless have fixed capacities and bounded work.
Free-slot lookup should use a fixed free list or bitmap rather than a full scan.
Exclusive-class termination should use active-set or class indexing rather than
walking every configured silent voice. Voice stealing may inspect the active
set because its size is already a declared system capacity; its measured
worst-case cost must be reported separately from the common free-slot path.

## MCU Memory Model

The asset view is immutable. Firmware validates the complete image during
initialization, then uses checked table views without repeating bounds checks in
the real-time loop. This is permitted only because the view cannot be mutated
after validation.

Expected storage classes are:

- MCU internal flash: firmware and small shared numeric tables;
- external QSPI flash, mapped flash, or an MCU-owned SD partition: compiled
  metadata sidecar;
- MCU SRAM: channel state, fixed voice state, command queues, and small optional
  hot-table cache;
- FPGA DDR3: unchanged WTSF/SF2 byte image used for sample reads.

The design must work without loading the complete metadata sidecar into SRAM.
Every real-time lookup should require a bounded number of contiguous reads.
When the chosen storage is not memory mapped, use a fixed-size read-through
cache with explicit worst-case latency and no heap allocation.

No final byte budget can be selected before the MCU and metadata storage are
chosen. Until then, the compiler report must provide enough data to make that
decision:

- total and per-section bytes;
- descriptor, velocity-span, layer-reference, program, and term counts;
- deduplication ratios;
- maximum layers for any Note On;
- maximum velocity spans for any preset/key;
- maximum terms per gain, pitch, and filter program;
- maximum contiguous and random reads on a cold Note On;
- compact versus precomputed policy comparison.

## Wave Image Coupling

Version 1 deliberately leaves sample data in the complete SF2 byte image. The
compiler records absolute word addresses using the existing `smpl` offset and
sample-header adjustments. This keeps the generic memory interface, Smart Artix
loader, WTSF header, DDR contents, and renderer unchanged.

The sidecar header records source size, digest, `smpl_word_offset`, and
`smpl_word_count`. Its verifier checks that every layer's base, length, and loop
points lie within the source sample span and the renderer's numeric limits. The
MCU must compare the sidecar identity with the wave-image identity supplied by
the deployment manifest or board bring-up policy before releasing renderer
reset or sending START commands.

If the MCU and FPGA cannot independently observe the same digest on the final
board, deployment tooling must install the sidecar and WTSF image as one
versioned bundle and expose the selected bundle ID through the MCU's board
configuration. Adding an FPGA-visible metadata digest register is not permitted
as an implicit part of this work because it would be an RTL interface change.

## Proposed Source Ownership

Implementation should preserve current repository boundaries:

- `sim/harness/formats`: checked SF2 parsing and a transport-independent
  semantic compiler IR;
- `tools/` or `sim/harness/apps`: offline image compiler and verifier entry
  points;
- `host/`: pointer-free asset view, target-neutral MCU policy integration, and
  production-side loading;
- `sim/harness/render`: reference adapter and command/WAV equivalence tests;
- `sim/harness/control`: unchanged shared command packing;
- `build/`: generated sidecars, manifests, size reports, and test bundles.

Do not expose the current private C++ compiled structs as the disk format.
First separate an explicit semantic IR from the parser, then serialize a
versioned packed schema. Host and simulation code may share the schema reader;
production firmware should be able to implement the same reader in freestanding
C or restricted C++ without STL.

Suggested supported commands are:

```text
make mcu-sf2-asset SF2=... MCU_ASSET_PROFILE=...
make verify-mcu-sf2-asset MCU_ASSET=...
make benchmark-mcu-sf2-asset SF2_BENCHMARK=...
```

Names and arguments may change during implementation, but generation,
verification, and benchmark actions must remain separate and generated output
must stay under `build/`.

## Verification Strategy

### Parser And Image Validation

- Retain all malformed-SF2 tests from the current loader.
- Test truncated headers, sections, counts, strides, offset overflow,
  misalignment, duplicate required sections, unsupported versions, bad CRCs,
  and source-digest mismatch.
- Verify that unknown required sections reject and unknown optional sections
  skip safely.
- Generate the same image twice and require identical bytes and digest.
- Fuzz or property-test the image view independently from the SF2 parser.

### Region And Selection Equivalence

For every preset in the small checked-in fixture:

- enumerate keys `0..127` and velocities `1..127`;
- compare layer count and order with the existing compiled loader;
- compare sample address, length, loops, loop mode, base phase, gains, pan,
  envelope fields, filter fields, exclusive class, and modulation semantics;
- explicitly cover empty cells, overlapping layers, fixed key/velocity,
  percussion banks, linked stereo, and loop-until-release.

For the external SGM workload, run the same exhaustive selection comparison as
an optional benchmark/signoff job. At minimum, routine tests cover every
velocity-span boundary plus randomized interior velocities for every
preset/key.

### Numeric And Modulation Equivalence

- Exhaust all seven-bit source inputs for every supported SF2 source curve,
  direction, polarity, and transform.
- Exhaust practical combinations for amount-source multiplication and all
  saturation boundaries.
- Validate pitch, attenuation, pan, envelope, LFO, and filter conversions
  against the existing independent formulas.
- Declare exact equality where the command-visible integer result can remain
  exact. Where a bounded fixed-point approximation intentionally replaces the
  current double path, document and enforce the maximum command-field error
  before accepting WAV differences.
- Compare dirty dependency masks against observed output changes so no MIDI
  source can update a destination that its mask omits.

### Command And Render Equivalence

- Feed identical ordered MIDI traces through the existing dynamic SF2 path and
  the compiled asset path.
- Compare complete command words, generations, layer adjacency, and command
  ordering at every event and control tick.
- Run the C++ reference renderer on both command traces and require bit-exact
  WAV output while numeric policy is unchanged.
- Run focused RTL renders using the compiled path as stimulus and require the
  same output as the existing command trace. This verifies integration but does
  not imply an RTL change or require a new Vivado implementation.
- Cover sustain, sostenuto, repeated notes, exclusive class, stealing, program
  changes, pitch bend, pressure, RPN tuning, controller bursts, queue pressure,
  linked stereo, and stale generation suppression.

### MCU Capacity And Timing

Measure on the selected MCU with release compiler settings and the actual
metadata storage interface:

- cold and warm Note On latency by layer count;
- controller-event processing latency by affected active voices;
- average, percentile, and maximum control-tick duration at 128, 256, and 512
  active mono voices;
- free allocation, exclusive-class action, and full stealing-path latency;
- internal SRAM high-water mark and stack use;
- metadata flash reads, cache misses, and worst-case cold-read latency;
- generated commands, coalesced replacements, dropped replaceable updates, and
  maximum command age.

The acceptance deadline must be derived from the chosen tick rate, SPI budget,
and renderer block-boundary latency. PC benchmark results are development
evidence only and cannot qualify MCU timing.

## Failure And Compatibility Policy

- A malformed, unsupported, corrupt, profile-mismatched, or wave-mismatched
  sidecar prevents voice START commands.
- Failure does not fall back to parsing SF2 on the real-time MCU path.
- Missing preset policy remains explicit and must match the current host
  behavior; the image reader must not silently choose an arbitrary preset.
- Table-capacity overflow is a compile-time failure, never runtime truncation.
- A Note On selecting more layers than the declared maximum is an invalid image.
- Metadata cache exhaustion may reject a Note On only under a documented
  overload policy; it must not evict data still referenced by active voices.
- Runtime command-queue overload continues to preserve lifecycle commands and
  may coalesce only replaceable gain, pitch, and filter updates under the
  existing scheduler rules.

## Implementation Phases

### Phase 0: Baseline And Target Selection

- [ ] Select the MCU, clock, internal SRAM/flash, external metadata storage, and
  expected storage bandwidth.
- [ ] Freeze the initial sample rate, control tick, SoundFont feature subset,
  and command interface version.
- [ ] Record current SGM C++ compiled size, cache-miss time, Note On time, and
  control-tick work as the comparison baseline.

Exit gate: one named deployment profile and reproducible baseline reports.

### Phase 1: Semantic IR And Packed Image

- [ ] Separate the current compiled zone representation from private loader
  implementation details.
- [ ] Define explicit integer semantic records without strings or native
  containers in runtime-required data.
- [ ] Implement deterministic section layout, header, CRC, source digest, and
  manifest generation.
- [ ] Implement an independent bounds-checking verifier and a pointer-free
  read-only image view.
- [ ] Add generation, verification, and size-report Make targets.

Exit gate: exhaustive small-fixture region selection and field equivalence;
repeat builds are byte identical; malformed images are rejected.

### Phase 2: Precomputed Dispatch And START Descriptors

- [ ] Emit sparse preset lookup, fixed key directories, compressed velocity
  spans, ordered layer references, and mono descriptors.
- [ ] Precompute output-profile phase, envelope, loop, gain, pan, and filter
  base fields.
- [ ] Add optional verified START templates without bypassing the shared command
  semantics.
- [ ] Preserve linked-stereo adjacency in both lookup and scheduler batching.
- [ ] Produce compact/precomputed size and operation-count comparisons.

Exit gate: Note On performs no SF2 parsing, zone merging, heap allocation,
floating-point transcendental operation, or general map lookup.

### Phase 3: Fixed-Point Modulation Programs

- [ ] Compile gain, pitch, and filter term arrays with constant folding,
  interning, note-static separation, and dependency masks.
- [ ] Add shared finite-domain source curves and selected key/velocity result
  tables.
- [ ] Implement fixed channel source state and active-voice modulation state.
- [ ] Replace hot-path double arithmetic with documented fixed-point operations.
- [ ] Retain independent gain, pitch, and filter update rates and unchanged
  output suppression.

Exit gate: numeric sweeps pass their exact/error contracts and representative
MIDI command traces match the approved reference behavior.

### Phase 4: MCU Runtime Integration

- [ ] Integrate the image view with MIDI channel state, allocation policy,
  `CommandVoiceControl`, and the asynchronous command scheduler.
- [ ] Remove runtime STL/heap requirements from the target MCU control core.
- [ ] Add fixed free-slot and exclusive-class indexing.
- [ ] Add sidecar/WTSF identity checks and fail-closed startup behavior.
- [ ] Measure the actual target under 128-, 256-, and 512-voice stress where the
  configured voice count permits it.

Exit gate: target timing, SRAM, stack, flash bandwidth, command age, and overload
behavior meet the deployment profile with margin.

### Phase 5: End-To-End Qualification

- [ ] Compare existing and compiled-path command streams and WAVs on checked-in
  fixtures and real SGM MIDI workloads.
- [ ] Run the normal C++ unit suite, reference renders, and focused RTL render
  integration tests.
- [ ] Verify generated bundle installation and mismatch rejection on the board.
- [ ] Update stable host/tooling documentation only after the format and
  deployment flow are implemented.

Exit gate: the MCU compiled-asset path is the documented production host path;
the existing RTL contracts and implementation remain unchanged.

## Completion Criteria

This backlog is complete only when:

- the real-time MCU never parses SF2 metadata or constructs zones;
- the deployed sidecar is deterministic, versioned, CRC-protected, and bound to
  the exact WTSF source image and output profile;
- all Note On lookups, modulation programs, voice state, and queues have fixed
  capacities and measured worst-case work;
- command-visible numeric behavior is exact or has an explicitly approved and
  tested fixed-point error contract;
- complete MIDI traces preserve layer order, voice lifecycle, generation,
  controller behavior, and linked-stereo adjacency;
- target-MCU timing and memory measurements satisfy the chosen product profile;
- `make lint`, `make test`, and `make check-docs` pass for the final
  implementation;
- no production file under `rtl/`, no FPGA constraint, and no Vivado project
  input changed as part of this work.

Because this backlog changes only host-side preparation and control policy,
documentation-only or host-only phases do not require synthesis or post-route
implementation. Any later proposal that changes RTL, command words, memory
address semantics, WTSF parsing, or board-visible behavior must be reviewed as
a separate contract change and follow the complete RTL workflow.
