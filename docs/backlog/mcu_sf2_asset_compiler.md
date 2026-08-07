# MCU SoundFont Asset Compiler Backlog

This document proposes an offline SoundFont compiler and a packed MCU-side
metadata image for real-time MIDI control. It is a backlog design, not a current
asset or firmware contract. Stable behavior remains defined by
[`../command_stream.md`](../command_stream.md),
[`../fixed_point.md`](../fixed_point.md),
[`../memory_format.md`](../memory_format.md), and
[`../board/asset_loading.md`](../board/asset_loading.md).
The implemented compact-v2 byte format is defined separately by
[`../host/mcu_sf2_asset_format.md`](../host/mcu_sf2_asset_format.md).

Current implementation status is recorded in
[`../mcu/rp2040_firmware.md`](../mcu/rp2040_firmware.md). An RP2040 target now
embeds and parses a concrete compact-v2 image, accepts USB-MIDI, and serializes
commands to the FPGA. This backlog remains useful for unfinished capacity,
bundle-identity, overload, and end-to-end qualification work; statements below
that predate target selection do not override the current firmware contract.

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

The production qualification SoundFont is the external
`SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2`. The checked-in MT6276 file remains
the fast routine fixture; it does not replace SGM signoff.

## Goals

- Compile one SF2 into deterministic MCU metadata before deployment.
- Precompute every result whose inputs are fixed by the SF2 and selected output
  profile.
- Tabulate finite input domains when that materially reduces MCU work without
  causing uncontrolled image growth.
- Keep Note On lookup bounded by the selected preset's declared zone count.
- Represent runtime modulation as compact fixed-point data and dependency
  metadata rather than maps or general C++ objects.
- Build existing `VOICE_START_MONO`, `VOICE_RELEASE`, `VOICE_STOP`,
  `VOICE_GAIN`, `VOICE_PITCH`, and `VOICE_FILTER` commands without heap
  allocation.
- Permit the same compiled image reader and MCU policy core to run in host
  tests, the C++ reference path, and eventual MCU firmware.
- Detect incompatible metadata, wave images, and output profiles before
  enabling audio. The MCU transport checks the FPGA command interface as a
  separate startup contract.
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
  SF2 + output profile
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
    -> preset-local key + velocity zone scan
    -> fixed-capacity zone materialization
    -> note-static values + current channel modulation
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
- fixed-point/compiler numeric-policy version;
- file-attenuation compatibility policy;
- pan-law version;
- filter coefficient quantization policy;
- enabled SoundFont feature subset.

The initial target-neutral reference profile is
`generic-le32-48k-tick48-v1`, defined in
[`../../spec/mcu_asset_profiles.json`](../../spec/mcu_asset_profiles.json). It
fixes 48 kHz output, a 48-sample/1 ms control tick, little-endian 32-bit words,
and the current numeric policies. It deliberately leaves the MCU, FPGA command
interface, and metadata storage unspecified. Supporting several sample rates
in one image is not a first-version requirement. Separate images are simpler,
smaller, and make mismatch rejection unambiguous.

Changing any profile field invalidates all fields derived from it. The compiler
must rebuild the whole sidecar rather than patching individual tables.

## Packed Image Requirements

The image is a serialized format, not a dump of C or C++ structs.

- All integer widths and signedness are explicit.
- Version 2 uses little-endian integers.
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
| compiler/numeric-policy version | Identify conversion and compatibility behavior. |
| output sample rate and tick samples | Bind all derived timing values. |
| source SF2 size and digest | Match the WTSF wave image. |
| sample word offset/count | Validate every materialized sample address against loaded DDR data. |
| section directory offset/count | Locate typed tables without fixed native structs. |
| maximum layers per Note On | Size bounded MCU batches before enabling input. |
| maximum modulation terms per destination | Establish control-loop worst-case work. |
| whole-image CRC | Detect corrupt or partial storage. |

The section directory identifies section type, element stride, offset, count,
and optional CRC. Unknown optional sections may be skipped; unknown required
sections reject the image.

The current `MSF2` deployment image is format version 2 and is compact-only.
Its 96-byte header records the reference profile, a reserved-zero word, source
size and CRC32, complete image CRC32, SF2 sample span, preset-selection digest,
and a seven-entry required-section directory. The profile describes only asset
semantics; the MCU's FPGA transport implementation checks its own interface
version independently. Older format versions and nonzero reserved words are not
accepted.

The compiler still constructs the semantic IR in host memory and uses it for
exhaustive offline equivalence checks. Version 2 serializes only seven runtime
sections: presets, normalized zones, resolved generator pairs, reachable sample
headers, candidate program references, modulation programs, and modulation
terms. It contains no key dispatch, velocity spans, mono descriptors, runtime
configuration table, or stored START words. Shared source curves remain
firmware numeric-policy data and are not duplicated in each image.

## Logical Tables

### Preset Directory

Each fixed-stride preset record stores `(bank, program)` plus the offset and
count of its zones. Lookup is a bounded scan of the sparse preset directory;
the selected SGM bank-zero image has 128 entries.

### Normalized Zones

Each 20-byte zone stores inclusive key/velocity ranges, a generator
offset/count and presence bitmap, plus a reachable-sample index. Generator
amounts occupy two bytes each; their operators come from the bitmap. Key range,
velocity range, and sample ID are not duplicated in the generator stream.
Source order is preserved, so linked layers remain adjacent and one Note On
producer batch retains their ordering.

At Note On, the runtime scans only the selected preset's zones, copies at most
61 generator values into fixed local storage, materializes the command-visible
region fields, applies live channel modulation, and packs an ordinary
`VOICE_START_MONO` command into the existing 17-word fixed buffer. Active voice
state owns every value needed after Note On; it retains no pointer into a zone
or temporary materialization result.

## Precomputation Policy

Precomputation stops where retaining normalized source units is smaller and the
bounded Note On conversion can meet the target deadline. It does not require an
uncompressed table for every Cartesian product.

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
- reachable sample headers and normalized generator values;
- compact modulation programs, term ordering, constant folding, and dependency
  masks.

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

### Deployment Preset Closure

Production images must not automatically retain every preset found in the
authoring SoundFont. A deployment preset set lists exact `(bank, program)`
pairs. The compiler sorts and validates that set, rejects duplicates and missing
presets, then copies only the reachable candidates, generators, modulators, and
sample headers. All copied references are reindexed. The selection digest and
selected-preset count are part of the checked image header so two different
deployment sets cannot be confused merely because they use the same source SF2.

The checked-in `spec/mcu_preset_sets/gm_bank0.txt` set selects the 128 melodic
General MIDI programs in bank zero. Product-specific drum kits and nonzero-bank
variants are explicit additional lines; the compiler never guesses them. An
omitted set retains all presets for reference-equivalence and analysis builds.

This metadata closure does not yet compact PCM. Version 1 START addresses still
refer to the complete source SF2 wave span. A later deployment packer may copy
only reachable sample windows and rewrite their precomputed absolute addresses;
that is an offline image/loader change and does not require an RTL interface
change.

### Size-Guided Choice

The compiler has one deployment policy: `compact-v2`.
Optional compact indexes and shared records are retained only when their total
asset plus firmware cost is smaller or target timing proves them necessary.
Selected layers and command-visible results continue to be compared with the
existing dynamic host oracle during compiler tests, without serializing a
second deployment representation.

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

Source curves and modulator results use signed Q16.16. Source tables are rounded
to nearest and remain within one Q16.16 LSB of the independent double oracle for
all 2,048 curve points. A term multiplies two Q16.16 sources in signed 64-bit
intermediate precision, rounds once back to Q16.16, multiplies by the signed
16-bit SF2 amount, applies the optional absolute transform, and accumulates in
signed 64-bit Q16.16. Its declared result error limit is `abs(amount)` Q16.16
LSBs for one dynamic source, including source quantization and multiply
rounding. Generator offsets, triangle LFO values, modulation-envelope ratios,
and destination composition also remain Q16.16. Conversion to double occurs
only at the existing table-backed pitch-ratio, attenuation, and filter-
coefficient quantization boundaries.

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

The current planning class is an RP2040-class MCU with external nonvolatile
storage, not a committed part number. The image must therefore support direct
mapped/XIP reads or a bounded read-through cache and must not require complete
metadata residency in SRAM.

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

- [x] Define the target-neutral `generic-le32-48k-tick48-v1` reference profile
  with the current sample rate, control tick, SoundFont subset, and numeric
  policy.
- [x] Add a reproducible SF2 baseline that reports compiled size, exhaustive
  preset/key/velocity selection fanout, and forced-cold/warm region lookup time.
- [x] Retain the existing reproducible 128/256/512-voice MCU control benchmark
  as the reference-profile control-loop baseline.
- [ ] Select the MCU, clock, internal SRAM/flash, external metadata storage, and
  expected storage bandwidth before Phase 4 target qualification. This is
  intentionally deferred and does not block the portable image/compiler work.

Exit gate for portable work: one named target-neutral reference profile and
reproducible host baseline reports. Target-specific timing and memory signoff
remain a Phase 4 exit requirement after an MCU is selected.

The 2026-08-01 SGM reference-profile run covered 285 presets and all 4,632,960
`preset/key/velocity` selections. It found 4,153,154 playable selections,
6,342,851 ordered layer references, and at most four mono layers for one Note
On. Host load time was 1.968 seconds, exhaustive selection conversion took
8.290 seconds, and forced-cold/warm region lookup averaged 1,521/28 ns on the
development container. These timings are portable-work baselines, not MCU
qualification.

### Phase 1: Semantic IR And Packed Image

- [x] Separate the current compiled zone representation from private loader
  implementation details.
- [x] Define explicit integer semantic records without strings or native
  containers in runtime-required data.
- [x] Implement deterministic section layout, header, CRC, source digest, and
  manifest generation.
- [x] Implement an independent bounds-checking verifier and a pointer-free
  read-only image view.
- [x] Add generation, verification, and size-report Make targets.

Exit gate: exhaustive small-fixture region selection and field equivalence;
repeat builds are byte identical; malformed images are rejected.

The Phase 1 test compares every serialized record with the independent semantic
IR, rebuilds and compares the complete image, and rejects truncation, bad CRC,
misaligned sections, invalid cross-section references, profile mismatch, and
source mismatch. It passes for both MT6276 and the production SGM file. The SGM
image contains 285 presets, 15,714 candidates, 156,953 resolved generators,
170,077 resolved modulators, and 1,824 samples. It is 2,761,528 bytes versus
14,159,110 estimated bytes for the current host C++ compiled representation.

### Phase 2: Precomputed Dispatch And START Descriptors

- [x] Emit sparse preset lookup, fixed key directories, compressed velocity
  spans, ordered layer references, and mono descriptors.
- [x] Precompute output-profile phase, volume envelope, loop, base gain, pan,
  and filter
  base fields.
- [x] Add optional verified START templates without bypassing the shared command
  semantics.
- [x] Preserve layer ordering, including linked-stereo adjacency, in lookup and
  retain scheduler batching as the existing command-queue contract.
- [x] Produce semantic-only lower-bound versus precomputed dispatch size and
  operation-count comparisons.

Exit gate: Note On performs no SF2 parsing, zone merging, heap allocation,
floating-point transcendental operation, or general map lookup.

The compact dispatch test exhausts every preset, key, and Note On velocity. It
recomputes expected ordered candidate IDs from the Phase 1 semantic ranges and
compares every returned layer. Each key-specific descriptor is independently
converted through the existing `region_from_zone` path and then packed by
`CommandVoiceControl`; after normalizing the patchable voice ID and generation,
all START words must match the image. The same test passes on MT6276 and SGM.

For SGM, the precomputed image is 9,700,276 bytes and contains 285 sparse preset
records, 36,480 fixed key records, 47,101 velocity spans, 71,516 ordered layer
references, 70,052 key-specific mono descriptors, and 1,144,870 START words.
The semantic-only Phase 1 lower bound is 2,761,528 bytes but still requires zone
conversion and therefore is not eligible for the real-time path. The selected
precomputed representation removes that work while remaining below the old
14,159,110-byte C++ compiled representation. Live controller/LFO/modulation
evaluation is deliberately not encoded in START templates and remains Phase 3.

### Phase 3: Fixed-Point Modulation Programs

- [x] Add deployment preset allowlists and prune the complete reachable metadata
  closure before expanding modulation data.
- [x] Compile gain, pitch, and filter term arrays with constant folding,
  interning, note-static separation, and dependency masks.
- [x] Add shared finite-domain source curves and selected key/velocity result
  tables.
- [x] Implement fixed channel source state and active-voice modulation state.
- [x] Replace modulation source and term evaluation with documented fixed-point
  operations; retain output-conversion approximation validation separately.
- [x] Retain independent gain, pitch, and filter update rates and unchanged
  output suppression.

Exit gate: numeric sweeps pass their exact/error contracts and representative
MIDI command traces match the approved reference behavior.

The final SGM bank-zero GM deployment set contains 128 of 285 presets. Its
Phase 2 precomputed image is 4,230,916 bytes instead of the 9,700,276-byte
all-preset image (56.4% smaller): 3,658 candidates, 49,229 generators, 38,901
modulators, 1,437 reachable sample headers, 36,625 mono descriptors, and 575,142
globally interned START words. Product-specific bank variants and drum presets
will add only their measured reachable closure. PCM remains in the complete
324,800,670-byte source image at this stage.

The Phase 3 bank-zero SGM image is 4,284,724 bytes. Its 3,658 candidate program
records intern to only 32 unique programs and 106 terms; the largest program has
six terms. The 16 shared curves contribute 2,048 values. The complete C++ unit
suite preserves representative command behavior after the fixed-point hot-loop
switch, including controller, pressure, pitch-bend, independent update-rate,
and unchanged-output suppression cases.

### Phase 4: MCU Runtime Integration

- [x] Integrate the image view with MIDI channel state, allocation policy, the
  fixed command protocol, and the asynchronous command scheduler.
- [x] Remove runtime STL/heap requirements from the portable MCU control core.
- [x] Add fixed free-slot and exclusive-class indexing.
- [x] Add sidecar/SF2 identity checks and fail-closed host startup behavior.
- [ ] Measure the actual target under 128-, 256-, and 512-voice stress where the
  configured voice count permits it.

Exit gate: target timing, SRAM, stack, flash bandwidth, command age, and overload
behavior meet the deployment profile with margin.

The portable Phase 4 runtime reads records directly from the memory-mapped
image, keeps channel/voice/allocation/exclusive state in fixed arrays, and emits
complete bounded commands through `CommandWordSink`. It implements Note On,
oldest-instance Note Off, sustain, soft pedal, channel and key pressure, pitch
bend, All Sound Off, exclusive class, bounded stealing, release reclamation,
modulation LFOs, the modulation envelope, and independent gain/pitch/filter
updates. The real-time host selects this path with `--mcu-asset`; it validates
the sidecar against the complete SF2 size and CRC before constructing the
command scheduler or accepting MIDI.

Adding the interned runtime configurations increases the SGM bank-zero image
from 4,284,724 to 4,450,632 bytes. It contains 346 unique 56-byte runtime
configurations for 36,625 descriptors. On the development x86 host, the fixed
512-voice runtime object is 75,008 bytes. The host/XIP proxy benchmark measured
Note On averages of 1,205, 1,004, and 972 ns at 128, 256, and 512 voices;
full-channel controller walks measured 75,131, 153,279, and 300,006 ns. These
are functional scaling measurements only. They do not include RP2040 flash
latency, SRAM placement, stack use, transport contention, or interrupt jitter,
and therefore do not satisfy the target exit gate. The output conversion
helpers also retain host-oriented lookup/floating-point implementations until a
specific MCU and flash execution model are selected.

### Phase 5: End-To-End Qualification

- [x] Compare existing and compiled-path command streams and reference PCM on a
  checked-in fixture and a representative trace using the real SGM.
- [x] Run the normal C++ unit suite, reference renders, and focused RTL render
  integration tests.
- [ ] Verify generated bundle installation and mismatch rejection on the board.
- [x] Update stable host/tooling documentation after the format and
  deployment flow are implemented.

Exit gate: the MCU compiled-asset path is the documented production host path;
the existing RTL contracts and implementation remain unchanged.

The Phase 5 equivalence test drives the compiled and dynamic host paths through layered Note On, CC7,
pitch bend, four periodic control ticks, and oldest-instance Note Off. It
compares every command length and word, then feeds the two streams to independent
`ReferenceSynth` instances and compares 1,024 stereo PCM frames exactly across
the event boundaries. It passes with both the checked-in MT6276 fixture and the
324,800,670-byte SGM source. This test found and fixed two integration errors:
the compiled path had applied note-static attenuation a second time, and its
first periodic modulation update lagged the reference by one tick.

`make lint`, `make test`, `make check-generated`, and `make check-docs` pass.
The first `make test` invocation encountered a transient Verilator
`attempted to destroy locked Thread Pool` error while building the QSPI model;
the isolated target and the subsequent complete run both passed. No file under
`rtl/` changed. Board bundle validation and target-MCU qualification remain open
and keep the Phase 4/5 hardware exit gates unsatisfied.

## Compact MSF2 Extension

The compact objective is lexicographic: preserve exact behavior and bounded
memory first, meet the selected target's event deadline second, then minimize
total deployed asset plus format-specific firmware-table bytes. MCU arithmetic
is not treated as a defect. A precomputed field, dispatch index, or cache is
present only when the smallest representation without it misses the measured
deadline.

### Layout And Compatibility

Layout is separate from the numeric output profile. `compact-v2` uses
`generic-le32-48k-tick48-v1` and must emit the same command words as the
dynamic host oracle:

- the compiler emits only format version 2;
- the host verifier and target runtime accept only version 2;
- format, layout, source SF2 identity, preset-selection digest, and numeric
  profile remain fail-closed header checks;
- there is no MCU fallback from a rejected compact image to runtime SF2 parsing.

No compact layout field is visible to the FPGA. Sample addresses, command
payloads, WTSF contents, and every RTL interface remain unchanged.

### Compact-V2 Logical Sections

Compact version 2 is a deployment image, not a serialization of the compiler's
semantic IR. It should contain only these runtime classes:

1. A sorted sparse preset directory containing the offset and bounds of each
   independently readable preset chunk.
2. Preset-local resolved zones with key/velocity ranges, sample identity,
   non-default generator values, ordered modulation terms, and layer order.
3. Deduplicated sample/window records and shared parameter groups only where
   the reference plus table is smaller than storing the values inline.
4. Small optional lookup tables that are not already fixed firmware data and
   demonstrably reduce total asset plus firmware bytes.
5. Source/wave identity, section bounds, declared maxima, and CRC data.

The Phase 1 semantic preset, generator, raw modulator, and sample-header
sections are compiler/verifier evidence and are omitted from `compact-v2`.
Offline verification compares the compact result with the semantic IR before
writing the deployment image. Compact zones contain the final inherited SF2
meaning, but not derived FPGA command words or key/velocity-specific numeric
results. Runtime code never reconstructs preset/instrument inheritance or an
SF2 bag/generator/modulator graph.

### Compact Dispatch Encoding

The size-first baseline performs a sequential scan of only the resolved zones
in the selected preset. The measured bank-zero closure has 3,658 candidates,
an average of 28.6 candidates per preset. For each zone, the MCU performs two
unsigned range checks for key and velocity and retains matching zones in source
order. This is bounded by a per-preset `zone_count` declared in the header and
does not scan generators, instruments, or another preset.

An index is optional, not mandatory. The compiler must compare total stored
bytes and measured Note On time for:

- no index and a sequential preset-local zone scan;
- a 16-entry coarse key-bucket index, with each bucket covering eight keys;
- merged key-interval candidate lists using checked preset-local 8- or 16-bit
  references.

The smallest representation that meets the target's cold Note On deadline is
selected explicitly in the layout flags. A 129-entry key table, velocity-span
expansion, and per-key layer references are forbidden unless measurement proves
they are required to meet that deadline. Index overflow or an excessive zone
count rejects the build; it never changes encoding silently.

### Normalized Runtime Zones

A compact zone represents one fully inherited preset/instrument combination,
not one key-specific command. It retains values in compact source-like integer
units when converting them on the MCU costs less than storing their expanded
form:

- key and velocity ranges, sample ID, loop mode, stereo routing, and source
  order;
- root key, pitch correction, scale tuning, attenuation, pan, and exclusive
  class;
- envelope, LFO, and initial-filter generator values in normalized SF2 units;
- only non-default generator fields, selected by a presence bitmap;
- ordered normalized modulation terms and their source dependency masks.

The encoder must evaluate preset-base plus zone-delta records, inline records,
and one-level shared records. Delta/varint coding, narrow signed fields, and
preset-local IDs are allowed because the MCU already walks the record during
Note On. Interning is used only when the table entry plus all references is
smaller than repeated inline values. Reference chains and a runtime semantic
object graph are forbidden.

No compact zone contains a START word array, a mono descriptor, a per-key
phase increment, an expanded envelope configuration, or an initial FPGA filter
coefficient. Once a zone matches, the MCU decodes it into a fixed local
structure, computes the command-visible values, emits at most 17 words, and
copies all continuing modulation state into the allocated voice. It performs
no heap allocation and retains no pointer into asset or cache storage.

### Integer Materialization Kernel

Space reduction deliberately moves derived calculations back to Note On when
they fit the event deadline and remove net deployed bytes. Generated firmware
tables, fixed-point interpolation, multiply, divide, shifts, and saturating
arithmetic may cover:

- timecents to sample counts and envelope steps;
- root-key, correction, scale-tuning, and output-rate phase conversion;
- base attenuation and pan conversion;
- initial filter coefficient construction or lookup;
- initial evaluation of velocity, key, channel, and controller modulators;
- patching the optional START payload layout.

These calculations use the same rounding and saturation policy already checked
against `McuModel`. A compact image is invalid if it requires an unsupported
formula or an out-of-range intermediate. Direct and compact command streams
must be bit exact; a size win does not authorize a new numeric tolerance.

The firmware may spend CPU cycles where that removes asset records. It must not
use floating point or general transcendental library calls: exponent-like SF2
conversions use small shared firmware tables plus integer interpolation. Those
tables are versioned by the numeric profile and are not duplicated in every
MSF2 image. The build report lists worst-case zone comparisons, modulation
terms, arithmetic operations, and table reads per Note On so the later target
gate can set an evidence-based deadline.

The added work belongs only to Note On and cold preset acquisition. Periodic
gain, pitch, and filter evaluation continues to use the fixed integer evaluator
and active-voice state semantics; the needed normalized
terms are copied from the matched zone when the voice starts.

### Optional Block Compression

Structural compaction is implemented and measured before adding a codec. If
raw `compact-v2` still exceeds the selected flash budget, the compiler may
encode preset-local Note On data as independently decodable blocks.

The block design must satisfy all of the following:

- a small uncompressed directory locates every block and records compressed
  size, expanded size, and CRC;
- no block requires a history window from another block;
- maximum expanded block size is declared and checked before firmware starts;
- source identity and the preset directory remain directly accessible;
- modulation terms may remain inside the preset block because a started voice
  copies every term and accumulator needed by later controller ticks into its
  fixed active state;
- a started voice copies every later-needed immutable ID/value into fixed voice
  state, so a preset block may be evicted immediately after Note On;
- program change may prefetch, but correctness cannot depend on prefetch
  completing before the first Note On;
- the fixed cache has explicit entry count, replacement policy, hit/miss
  counters, and a fail-closed corrupt-block path;
- codec workspace, stack, and worst-case decode time are part of the manifest
  and target qualification.

LZ4 block, heatshrink, and an uncompressed baseline should be compared after an
MCU is selected. Zstd results above establish compressibility but do not select
zstd for firmware. Codec support is accepted only if it saves at least 25% over
raw compact data after indexes while meeting cold Note On and SRAM limits.

### Size And Performance Budgets

For the exact SGM source, `gm_bank0.txt`, and reference output profile:

- mandatory raw `compact-v2` acceptance ceiling: 1,000,000 bytes;
- raw compact design target: 512 KiB or less;
- optional block-compressed target: 384 KiB or less;
- maximum selected layers remains four;
- command buffer remains 17 words with no heap allocation;
- the build report must list logical and stored bytes per section, record
  counts/strides, interning savings, index widths, and largest cold-read block;
- the benchmark must report compact cold/warm Note On latency, zone
  comparisons, arithmetic operations, storage reads, bytes read, and commands
  emitted for the same trace;
- every optional index, interned table, cached result, or precomputed field must
  report its added bytes and saved cold/warm cycles; the selected deployment is
  the smallest measured point that passes the target timing gate.

The size ceilings are portable compiler gates. Timing, cache size, and codec
acceptance remain target-dependent until the MCU and flash interface are fixed.
If exact command equivalence cannot fit the mandatory ceiling, the compiler
must report the responsible sections and stop; it must not weaken SoundFont
behavior implicitly.

## Compact Implementation Phases

### Phase 6: Accounting And Deployment-Only Image

- [x] Add exact per-section byte accounting to the JSON manifest.
- [x] Separate verification-only semantic sections from runtime-required data.
- [x] Define the compact-only version-2 header and required-section set with
  independent malformed-image tests.
- [x] Emit a deployment image without semantic sections and remap descriptors
  directly to interned program/configuration IDs.
- [x] Re-run deterministic-build, source-mismatch, selection-mismatch, and CRC
  tests.

Exit gate: byte-identical repeat builds, exact selected layers against the
dynamic host oracle, and a compact intermediate below 3,750,000 bytes for SGM
bank zero.

The SGM bank-zero Phase 6 image is 3,726,340 bytes, meeting the intermediate
gate and reducing the previous 4,450,632-byte image by 724,292 bytes. The JSON
report accounts for every section: START words still occupy 2,300,568 bytes,
mono descriptors 732,500 bytes, and fixed key/velocity/layer dispatch 481,572
bytes. These remaining expanded sections are explicitly temporary Phase 7
inputs; the normalized-zone image does not retain them.

### Phase 7: Normalized Zones And Compute-First Runtime

- [x] Define normalized zones with generator presence bitmaps, compact integer
  fields, and no runtime record-reference chain.
- [x] Implement preset-local sequential zone scanning as the zero-index
  baseline.
- [x] Implement fixed-capacity materialization and construct START commands
  without stored START word arrays.
- [x] Reimplement phase, envelope, gain/pan, filter, and initial modulation
  conversion in the production pure-C MCU runtime using generated firmware
  LUTs and fixed-point arithmetic.
- [x] Measure the zero-index normalized representation and omit larger dispatch,
  descriptor, START-template, and runtime-configuration tables.
- [x] Exhaust every selected preset/key/velocity against the dynamic host oracle,
  including layer order, then compare every zone/key START command before live
  channel patching.

Exit gate: the SGM raw compact image is no larger than 1,000,000 bytes, targets
512 KiB, performs no heap allocation or SF2 inheritance/object-graph walk, and
emits bit-exact commands and reference PCM on checked and SGM traces. No larger
indexed or precomputed variant is selected without a measured timing need.

The SGM bank-zero normalized image is 195,664 bytes: 73,160 bytes of zones,
76,510 bytes of generator amounts, 31,614 bytes of reachable samples, 10,974
bytes of candidate program references, and 1,656 bytes of modulation programs
and terms. Header, directory, presets, and alignment account for the remaining
1,750 bytes. This is 94.7% smaller than the 3,726,340-byte Phase 6 image and is
well below both the 1,000,000-byte ceiling and 512 KiB target. Target timing
remains open, so the complete Phase 7 exit gate is not yet satisfied.

The current C++ asset view and `McuSf2AssetRuntime` are the executable format
and behavior oracle. They are retained for compiler tests, host integration,
command/PCM comparison, and rapid diagnostics; they are not the production MCU
firmware implementation.

### Phase 7B: Production Pure-C MCU Runtime

- [x] Implement a freestanding-compatible C reader for compact-v2 using only
  explicit-width integer records, caller-owned storage, and checked
  pointer/size views. It must not require C++, STL, exceptions, RTTI, `malloc`,
  or a hosted filesystem.
- [x] Implement preset lookup, sequential zone scanning, presence-bitmap
  generator decoding, fixed-capacity layer collection, voice allocation, and
  command packing behind a small C API suitable for the selected MCU HAL.
- [x] Generate versioned integer lookup tables for timecents, pitch ratios,
  attenuation, pan, LFO steps, and filter construction where table lookup plus
  interpolation is smaller or faster than retained derived asset fields.
- [x] Remove floating point and `libm` from Note On and control-tick code. Audit
  every multiply, division, rounding boundary, saturation, and intermediate
  width against the C++ oracle.
- [x] Keep all continuing modulation state in fixed caller-owned voice/channel
  arrays. Active voices must retain no pointer into temporary zone decode
  storage, and command output must use a caller-provided 17-word buffer or
  bounded sink.
- [ ] Run the pure-C implementation against the same MT6276 and SGM exhaustive
  layer/START tests, compiled-runtime command traces, and reference PCM checks.
  Cross-compile it with the production MCU compiler and report code size,
  read-only LUT bytes, static SRAM, maximum stack, cold/warm Note On time, and
  control-tick time.

Current Phase 7B implementation is [`../../mcu/msf2.c`](../../mcu/msf2.c) with
the public API in [`../../mcu/msf2.h`](../../mcu/msf2.h). It completes checked
image activation, preset lookup, bounded four-layer collection, generator
decode, static Note On materialization, filter construction, caller-owned
17-word START packing, fixed-capacity voice allocation and stealing, MIDI
channel sources, sustain/release lifecycle, LFOs, the modulation envelope, and
gain/pitch/filter control ticks. MT6276 and
`SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2` exhaustively pass every materialized
zone/key against the C++ oracle. The MT6276 runtime trace additionally covers
Note On, controller and pressure changes, pitch bend, four control ticks,
sustain release, voice reuse, and bounded stealing against the C++ runtime.
Runtime gain, pitch, and filter fields remain within the one-LSB numeric
contract. Production-MCU cross-compilation, resource reports, SGM runtime
traces, and target timing remain open, so the final checklist item is not yet
complete.

The profile-bound tables are generated by
[`../../tools/gen_dsp_lut.py`](../../tools/gen_dsp_lut.py) into
[`../../mcu/generated/msf2_lut.h`](../../mcu/generated/msf2_lut.h). A shared
256-entry interpolated `exp2` fractional table replaces separate pitch,
timecent, attenuation, sustain, and LFO-step tables; a 257-entry quarter-sine
table serves both pan and filter trigonometry through symmetry. Sixteen
128-entry Q16.16 tables cover every SoundFont source curve without `libm`.
Together they occupy 10,244 read-only bytes. A host
`-Os -ffreestanding -fno-builtin` build currently reports 24,315 total text plus
read-only bytes, zero data, and zero BSS before
link-time dead-section removal. These are host-compiler measurements, not the
still-required production MCU report.

Lookup deliberately remains bounded and simple: presets use linear search
because compact-v2 does not promise sort order; zones use a preset-local
sequential scan to preserve layer order; generator amounts use presence-bitmap
iteration; numeric tables use direct mantissa indexing and interpolation. The
stable format document's [lookup strategy](../host/mcu_sf2_asset_format.md#lookup-strategy)
records when a future explicit dispatch index would be justified.

Exit gate: the pure-C implementation accepts the same compact-v2 image and is
structurally exact with the approved C++ oracle, uses no dynamic allocation or
floating-point runtime support, and meets the selected MCU's flash, SRAM,
stack, and worst-case timing budgets. Preset/zone selection, layer order,
sample/loop addresses, modes, voice identity, and command framing are bit exact.
Continuous numeric fields use an explicit error contract: phase and Q1.15 gain
are within one destination LSB; envelope durations are within one sample or two
parts per million, whichever is larger; filter coefficients are within one
Q2.14 LSB while the enable decision remains exact. Optional compression work
does not begin until this uncompressed production path is measured.

### Phase 8: Optional Preset-Local Compression

- [ ] Measure uncompressed, LZ4-block, and heatshrink preset-local payloads with
  complete index and padding overhead included.
- [ ] Implement independently checked blocks and a fixed read/decode cache only
  if the measured saving is at least 25%.
- [ ] Add program-change prefetch, cold-first-note, corrupt-block, truncated-
  block, cache-thrash, and multitimbral tests.
- [ ] Prove that active voices retain no pointer/reference into evictable block
  storage.
- [ ] Report decoder code size, workspace, stack, expanded-block maximum, and
  cold/warm bytes read.

Exit gate: adopt a codec only when it meets the selected MCU's latency/SRAM
budget and materially improves on raw compact. Otherwise ship raw compact and
record Phase 8 as measured but rejected.

### Phase 9: Deployment Qualification

- [ ] Record compact-v2 explicitly in the product bundle manifest.
- [ ] Run exact command/PCM comparisons on complete checked-in MIDI workloads
  and representative SGM bank/program changes.
- [ ] Measure target cold/warm Note On, controller tick, cache behavior, flash
  traffic, stack, SRAM high-water, and command age.
- [ ] Verify atomic sidecar/WTSF installation and mismatch rejection on the
  board.
- [ ] Promote compact layout documentation from backlog to stable tooling/host
  contracts only after the selected target passes.

Exit gate: the deployment image meets its flash, SRAM, timing, and integrity
budgets on hardware. Compact deployment still causes no production RTL change.

## Completion Criteria

This backlog is complete only when:

- the real-time MCU never parses RIFF/SF2 metadata, resolves inheritance, or
  constructs a general-purpose semantic object graph;
- the deployed sidecar is deterministic, versioned, CRC-protected, and bound to
  the exact WTSF source image and output profile;
- all Note On lookups, modulation programs, voice state, and queues have fixed
  capacities and measured worst-case work;
- command-visible numeric behavior is exact or has an explicitly approved and
  tested fixed-point error contract;
- `compact-v2` and the dynamic host oracle produce bit-exact command streams
  and reference PCM for the same compiler profile, MIDI input, and event schedule;
- the selected compact deployment image satisfies its declared raw or
  block-compressed size ceiling with all indexes, padding, and integrity data
  included;
- any block-compressed deployment has measured fixed decoder/cache memory
  bounds, bounded cold-note work, and no active-voice reference into evictable
  storage;
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
