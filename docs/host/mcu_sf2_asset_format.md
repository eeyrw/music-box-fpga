# Compact MSF2 Asset Format Version 2

This document is the byte-level contract for the compact MCU SoundFont sidecar
identified by the `MSF2` magic and format version 2. It is sufficient to write
an independent reader; native C or C++ structure layout is not part of the
format.

The sidecar contains normalized preset-local control metadata. PCM remains in
the complete source SF2/WTSF image defined by
[`../memory_format.md`](../memory_format.md). Materialized voices use
[`../command_stream.md`](../command_stream.md), and numeric conversion follows
[`../fixed_point.md`](../fixed_point.md) plus the selected profile in
[`../../spec/mcu_asset_profiles.json`](../../spec/mcu_asset_profiles.json).
SoundFont operator numbers retain their SoundFont 2.04 meanings; see
[`../reference/soundfont-2.04.pdf`](../reference/soundfont-2.04.pdf).

The current writer and C++ oracle reader are
[`../../sim/harness/formats/mcu_sf2_asset.cpp`](../../sim/harness/formats/mcu_sf2_asset.cpp).
Its C++ declarations in
[`../../sim/harness/formats/mcu_sf2_asset.h`](../../sim/harness/formats/mcu_sf2_asset.h)
are APIs, not serialized native structures. The freestanding production reader,
static Note On materializer, and START packer are
[`../../mcu/msf2.c`](../../mcu/msf2.c), exposed by
[`../../mcu/msf2.h`](../../mcu/msf2.h). Evolution and remaining pure-C MCU work are
tracked in
[`../backlog/mcu_sf2_asset_compiler.md`](../backlog/mcu_sf2_asset_compiler.md).

## Conventions

- All multi-byte integers are little-endian.
- `u8`, `u16`, `u32`, and `u64` are unsigned; `s8` and `s16` are two's
  complement.
- Byte offsets are relative to the first MSF2 byte. Section references are
  element indices, never pointers or byte offsets.
- Every section start and the final image size are four-byte aligned. Packed
  records may contain unaligned fields, so readers decode bytes explicitly.
- Range calculations use widened arithmetic. A reader must prove both
  `first + count <= total` and `offset + count * stride <= total_size` without
  overflow before dereferencing data.

## Image Layout

The image contains a 96-byte header, seven 16-byte directory entries, seven
required sections in directory order, and zero-valued alignment padding.

| ID | Section | Record stride |
| ---: | --- | ---: |
| 1 | presets | 12 bytes |
| 2 | zones | 20 bytes |
| 3 | generator amounts | 2 bytes |
| 4 | samples | 22 bytes |
| 5 | candidate programs | 3 bytes |
| 6 | modulation programs | 12 bytes |
| 7 | modulation terms | 12 bytes |

Version 2 contains no semantic-IR, key-dispatch, velocity-span,
mono-descriptor, runtime-configuration, string, source-curve, or stored START
section. All seven listed sections are mandatory, including empty sections.

## Header

| Offset | Size | Type | Field | Required value or meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 4 | bytes | magic | ASCII `MSF2` |
| 4 | 2 | u16 | format version | `2` |
| 6 | 2 | u16 | header size | `96` |
| 8 | 4 | u32 | total size | Exact image bytes including padding |
| 12 | 4 | u32 | command interface | Selected profile and FPGA command-interface version |
| 16 | 4 | u32 | output sample rate | Samples per second |
| 20 | 4 | u32 | control tick samples | Output samples per MCU tick |
| 24 | 8 | u64 | source size | Exact source SF2 size in bytes |
| 32 | 4 | u32 | source CRC32 | Complete source SF2 CRC |
| 36 | 4 | u32 | image CRC32 | Complete MSF2 CRC with this field treated as zero |
| 40 | 4 | u32 | directory offset | `96` |
| 44 | 2 | u16 | section count | `7` |
| 46 | 2 | bytes | reserved | Writer emits zero; v2 readers do not interpret |
| 48 | 4 | u32 | sample word offset | SF2 `smpl` payload word offset in the complete source |
| 52 | 4 | u32 | sample word count | Signed 16-bit words in the `smpl` payload |
| 56 | 4 | u32 | profile ID CRC32 | CRC of exact profile ID bytes without a terminator |
| 60 | 4 | u32 | header flags | `0x00000001`: source CRC32 is present |
| 64 | 4 | u32 | selection CRC32 | Deployment preset-set identity; zero means all presets |
| 68 | 4 | u32 | selected preset count | Equal to presets section count |
| 72 | 24 | bytes | reserved | Writer emits zero; v2 readers do not interpret |

The reference profile `generic-le32-48k-tick48-v15` specifies 48 kHz, 48
samples per tick, and command interface `0x000f0000`. A reader compares command
interface, sample rate, tick length, and profile ID CRC with its expected
profile; matching format version alone is insufficient.

## CRC And Identity

Every CRC uses reflected CRC-32/ISO-HDLC: polynomial `0xedb88320`, initial
value `0xffffffff`, and final XOR `0xffffffff`.

The image CRC covers exactly `total_size` bytes. Bytes 36 through 39 are fed as
zero. The source CRC covers exactly `source_size` SF2 bytes in file order.
Source size, source CRC, sample word offset, and sample word count bind MSF2 to
the wave image. Firmware that does not parse SF2 can compare them with an
authenticated WTSF or product-bundle manifest.

For a nonempty preset set, the compiler sorts unique `(bank, program)` pairs
and feeds each as little-endian `bank` u16 followed by `program` u16 into the
same CRC. Duplicate or missing requested presets reject the build. An empty
selection has CRC zero and retains every playable preset.

## Section Directory

The directory starts at byte 96. Entry `i` describes section ID `i + 1`.

| Entry offset | Size | Type | Field | Meaning |
| ---: | ---: | --- | --- | --- |
| 0 | 2 | u16 | type | Exact ID 1 through 7 |
| 2 | 2 | u16 | flags | `1`, required section |
| 4 | 4 | u32 | offset | Four-byte-aligned section start |
| 8 | 4 | u32 | count | Record count |
| 12 | 4 | u32 | stride | Exact stride from the image-layout table |

Sections occur in increasing ID order. Each starts at or after the preceding
directory/section end and ends within `total_size`. Version 2 does not accept
unknown, reordered, duplicate, or optional sections.

## Preset Records

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 2 | u16 | MIDI program, 0 through 127 |
| 2 | 2 | u16 | MIDI bank, 0 through 16383 |
| 4 | 4 | u32 | first zone index |
| 8 | 4 | u32 | zone count |

The zone range is contiguous and preserves layer order. Presets retain compiler
semantic order; readers currently use bounded linear lookup and must not assume
sorting.

## Zone Records

One zone is one fully inherited playable candidate. Its same-index candidate-
program record supplies modulation program IDs.

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 1 | u8 | inclusive key low, 0 through 127 |
| 1 | 1 | u8 | inclusive key high, 0 through 127 |
| 2 | 1 | u8 | inclusive velocity low, 0 through 127 |
| 3 | 1 | u8 | inclusive velocity high, 0 through 127 |
| 4 | 4 | u32 | first generator-amount index |
| 8 | 2 | u16 | generator amount count, at most 61 |
| 10 | 2 | u16 | sample index |
| 12 | 8 | u64 | generator presence bitmap |

Presence bit `n` represents SoundFont generator operator `n`. Only bits 0
through 60 are legal; bits 61 through 63 are zero. Popcount equals
`generator_count`. Amounts are consumed in increasing operator order:

```c
uint32_t amount_index = zone.first_generator;
for (uint16_t oper = 0; oper <= 60; ++oper) {
    if ((zone.generator_presence & (UINT64_C(1) << oper)) != 0) {
        apply_generator(oper, generator_amount[amount_index++]);
    }
}
```

Operators 43 (`keyRange`), 44 (`velRange`), and 53 (`sampleID`) are absent from
the bitmap because the zone stores them directly. Amounts retain raw SoundFont
u16 representation; operators defined as signed interpret the bits as s16.

## Generator-Amount Records

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 2 | u16 | Raw SoundFont generator amount |

The zone bitmap supplies operators. `first_generator + generator_count` must
fit this section.

## Sample Records

Positions are word indices relative to the SF2 `smpl` payload, not MSF2 byte
offsets or absolute DDR addresses.

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 4 | u32 | sample start |
| 4 | 4 | u32 | sample end, exclusive |
| 8 | 4 | u32 | loop start |
| 12 | 4 | u32 | loop end, exclusive |
| 16 | 4 | u32 | source sample rate |
| 20 | 1 | u8 | original MIDI pitch |
| 21 | 1 | s8 | pitch correction in cents |

Required ordering is `start <= loop_start <= loop_end <= end <=
sample_word_count`; sample rate is nonzero. Zone address generators may narrow
the window during materialization. The FPGA word address derives from
`sample_word_offset + materialized_position` under
[`../memory_format.md`](../memory_format.md).

## Candidate-Program Records

There is exactly one record per zone at the same index.

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 1 | u8 | gain program ID |
| 1 | 1 | u8 | pitch program ID |
| 2 | 1 | u8 | filter program ID |

IDs 0 through 254 index modulation programs. `0xff` means no program for that
family. The image contains at most 255 programs and never uses index 255.

## Modulation-Program Records

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 4 | u32 | first modulation-term index |
| 4 | 2 | u16 | term count |
| 6 | 2 | u16 | note-static prefix count |
| 8 | 2 | u16 | OR of all term dependency masks |
| 10 | 1 | u8 | family: 0 gain, 1 pitch, 2 filter |
| 11 | 1 | u8 | reserved, writer emits zero |

Terms retain SoundFont order after a stable partition moves note-static terms
first. `note_static_term_count <= term_count`, and the term range fits the term
section. Programs are content-interned and may be shared.

| Family | Retained SoundFont destinations |
| --- | --- |
| gain | 13 `modLfoToVolume`, 17 `pan`, 48 `initialAttenuation` |
| pitch | 0 pitch, 5 `modLfoToPitch`, 6 `vibLfoToPitch`, 7 `modEnvToPitch` |
| filter | 8 `initialFilterFc`, 10 `modLfoToFilterFc`, 11 `modEnvToFilterFc` |

## Modulation-Term Records

| Offset | Size | Type | Field |
| ---: | ---: | --- | --- |
| 0 | 2 | u16 | SoundFont source encoding |
| 2 | 2 | u16 | SoundFont destination generator |
| 4 | 2 | s16 | amount |
| 6 | 2 | u16 | SoundFont amount-source encoding |
| 8 | 2 | u16 | transform: 0 linear, 2 absolute value |
| 10 | 2 | u16 | dependency mask |

Source fields follow SoundFont 2.04. Dependency bits are MSF2 metadata:

| Bit | Mask | Dependency |
| ---: | ---: | --- |
| 0 | `0x0001` | note or Note On velocity |
| 1 | `0x0002` | MIDI CC |
| 2 | `0x0004` | pitch wheel |
| 3 | `0x0008` | key or channel pressure |
| 4 | `0x0010` | pitch-wheel sensitivity/tuning |

No other dependency bits exist in version 2. A program mask is the OR of its
term masks. A term in the note-static prefix has no dependency outside
`0x0001`.

## Required Validation

A reader validates the complete image before enabling MIDI input:

- magic, version, header size, total size, flags, expected profile, and CRC;
- fixed directory count/order/flags/strides, alignment, non-overlap, and bounds;
- selected preset count equals presets count and candidate-program count equals
  zone count;
- every preset zone range, zone generator range, and program term range fits;
- zone MIDI ranges, presence bitmap, generator count, and sample reference are
  valid;
- sample ranges are ordered, contained in `sample_word_count`, and have a
  nonzero sample rate;
- candidate program IDs are `0xff` or valid;
- program family, note-static count, reserved byte, dependency OR, and term
  references are valid;
- term transform and dependency bits are supported.

Any failure rejects the image atomically. A reader neither partially activates
an image nor falls back to runtime SF2 parsing.

## Pure-C Reader Requirements

The production MCU reader uses checked `(pointer, size)` views and caller-owned
storage. It does not depend on C++ layout, exceptions, RTTI, STL, `malloc`, a
hosted filesystem, floating point, or `libm`. Active voices copy all continuing
state out of temporary zone decode storage. Unaligned fields are assembled
byte-wise or with safe little-endian helpers.

Generated integer lookup tables are firmware/profile data, not MSF2 sections.
Their version is bound by the profile ID. They may implement phase, timecent,
attenuation, pan, LFO, and filter conversion, but emitted words must obey
[`../command_stream.md`](../command_stream.md) and match the C++ oracle.

The production C implementation may approximate continuous conversions with a
shared exponent-mantissa table and interpolation. Structural values remain bit
exact. The Phase 7B numeric contract permits one destination LSB for Q24.8
phase, Q1.15 gain, and Q2.14 filter coefficients; envelope durations permit one
sample or two parts per million, whichever is larger. Filter enable decisions,
sample and loop addresses, layer order, and command framing are exact.

## Pure-C Runtime Integration

The public runtime API in [`../../mcu/msf2.h`](../../mcu/msf2.h) uses
caller-owned channel, voice, and
free-stack arrays. `msf2_runtime_init` binds those arrays, the validated image,
and a bounded command sink. MIDI handlers call the corresponding
`msf2_runtime_note_on`, `msf2_runtime_note_off`, control-change, pitch-bend, or
pressure entry point. The runtime never reads a system clock. Firmware advances
time through `msf2_runtime_advance_samples`; the function accumulates partial
intervals and executes one control tick for every 48 elapsed output samples.
At 48 kHz this is exactly 1 ms. A serialized 1 ms timer callback may instead
call the convenience entry `msf2_runtime_control_tick`, which is exactly one
48-sample advance. MIDI and timer calls must not concurrently mutate one runtime
instance.

[`../../mcu/msf2_example.c`](../../mcu/msf2_example.c) is a compiled firmware
integration example with static storage, serialized timer service, Bank
Select/Program Change state, and MIDI event adapters. The same file implements
the complete synchronous SPI command sink. Firmware supplies:

- linker symbols for the compact-v2 image start and end;
- `platform_spi_write_mode0_cs0` for a complete SPI mode-0, MSB-first transfer;
- `platform_irq_save` and `platform_irq_restore` for timer-counter handoff;
- a 1 ms timer that calls `app_synth_1ms_timer_isr`.

The SPI HAL must keep chip select asserted across the complete transaction and
must consume or copy the stack-owned byte buffer before returning. The example
emits the command frame defined by
[`../command_stream.md`](../command_stream.md#spi-command-transaction):

```text
0xa5 | word_count | crc16_msb | crc16_lsb | word0_be | ... | wordN_be
```

CRC-16/CCITT-FALSE covers `word_count` followed by every big-endian command-word
byte; it does not cover opcode `0xa5`. The command sink rejects empty, oversized,
or internally inconsistent commands before calling the HAL. HAL failures return
through `MSF2_ERR_SINK` to the MIDI or control-service caller.

The example forwards MIDI CC values as SoundFont modulation sources and applies
runtime policy for sustain, soft pedal, and All Sound Off. Bank Select and
Program Change remain application state. RPN/NRPN selector and data-entry
sequencing is explicitly not implemented; raw selector CC forwarding is not a
complete RPN/NRPN mapping.

Each control tick advances the modulation envelope and mod/vibrato LFO state,
updates gain and pitch, evaluates filter state every fourth tick, suppresses
unchanged commands, and reclaims released voices after their sample lifetime.
The allocator takes free slots in constant time. At capacity it first prefers a
released voice, then the oldest voice in the selected lifecycle stage, emits
`VOICE_STOP`, increments the 16-bit generation, and publishes the replacement
`VOICE_START_MONO`.

## Lookup Strategy

Compact-v2 does not require preset records to be sorted, so the pure-C reader
uses bounded linear preset lookup rather than binary search. A preset's zones
are contiguous and retain compiler layer order; Note On therefore scans that
single zone range sequentially, applies key/velocity bounds, and copies at most
four matching zone indices to caller-owned storage. Generator decoding scans
the 61-bit presence bitmap in operator order and consumes the packed amount
stream without searching.

Numeric conversion is constant-time table indexing, not a table search. Pitch,
timecents, attenuation, and filter-Q conversion split an exponent into an
integer octave and an eight-bit mantissa, then use shifts plus interpolation
between adjacent `exp2` entries. Pan and filter trigonometry use direct phase
indexing, interpolation, and quarter-wave symmetry. CLZ-based mantissa lookup
is useful for the inverse direction, such as linear magnitude to centibels, but
the current Note On path already receives logarithmic SoundFont units and does
not need CLZ.

If measured target timing later makes preset lookup significant, the format
must add an explicit sorted index or fixed dispatch section. Readers must not
silently binary-search the current semantic-order preset section.

## Generation And Verification

Routine checked-in fixture:

```bash
make mcu-sf2-asset
make test-mcu-sf2-asset
make test-sf2-runtime
```

Production SGM verification is explicit because it is intentionally outside
the default test target:

```bash
make test-mcu-sf2-asset \
  SF2='/path/to/SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2'
```

Generated images and reports belong under `build/` and are not committed.
