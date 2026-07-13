# Multi-Voice Register Map

The simplified bus uses 16-bit byte addresses and 32-bit data. Transactions are
single-beat and 32-bit aligned. The 32-bit data word is the bus container; many
fields are narrower and explicitly define which bits are meaningful. Wave-memory
base addresses are 32-bit word addresses. Writes to configuration registers
update per-voice shadow state. `COMMIT` copies the selected shadow configuration
into renderer-facing active storage and stages a render-boundary commit pulse for
phase reload and filter-history clear. Writes to runtime registers do not require
`COMMIT`, update live runtime state directly, and do not reload playback phase.

`spi_register_bridge` exposes this same register bus through a simple 56-bit SPI
frame: 8-bit command, 16-bit byte address, then 32-bit data phase. Command bit 7
selects write when set and read when clear; command bits 6:0 are reserved. Read
data is shifted out most-significant bit first during the data phase. The SPI
master must leave enough system-clock cycles between the address phase and read
data phase for the bridge to complete the internal register-bus access. This is
a simulation-friendly transport, not a board timing contract.

The core exposes 32 voice slots. Slot 0 keeps the original base address. Slot N
uses `0x0100 + N * 0x80` plus the offsets below.

```text
voice_base(slot) = 0x0100 + slot * 0x80
register_addr    = voice_base(slot) + offset
```

| Offset | Name | Description |
| --- | --- | --- |
| `0x00` | CONTROL | bit 0 enable, bit 1 stereo |
| `0x04` | BASE_ADDR | left/mono 16-bit-word memory address |
| `0x08` | LENGTH | number of sample frames in bits 23:0 |
| `0x0c` | LOOP_START | first loop frame in bits 23:0 |
| `0x10` | LOOP_END | exclusive loop end frame in bits 23:0 |
| `0x14` | PHASE_INIT | unsigned Q24.8 initial position |
| `0x18` | PHASE_INC | unsigned Q24.8 frames per output sample |
| `0x1c` | GAIN_L | signed Q1.15 in bits 15:0 |
| `0x20` | GAIN_R | signed Q1.15 in bits 15:0 |
| `0x24` | COMMIT | write bit 0 as one to activate this voice slot and stage render-boundary reload |
| `0x28` | STATUS | bit 0 configuration valid for this voice slot |
| `0x2c` | ENVELOPE_LEVEL | runtime signed Q1.15 envelope level in bits 15:0 |
| `0x30` | PHASE_INC_RUNTIME | runtime unsigned Q24.8 phase increment |
| `0x34` | LOOP_MODE | bits 1:0 loop mode |
| `0x38` | FILTER_CONTROL | bit 0 shadow enable, bit 31 commits shadow filter settings to runtime |
| `0x3c` | FILTER_B0 | signed Q4.28 `b0` |
| `0x40` | FILTER_B1 | signed Q4.28 `b1` |
| `0x44` | FILTER_B2 | signed Q4.28 `b2` |
| `0x48` | FILTER_A1 | signed Q4.28 `a1` |
| `0x4c` | FILTER_A2 | signed Q4.28 `a2` |
| `0x50` | GAIN_RUNTIME | bits 15:0 left Q1.15, bits 31:16 right Q1.15 |
| `0x54` | RELEASE_CONTROL | bit 0 released runtime flag |
| `0x58` | BASE_ADDR_R | right-channel 16-bit-word memory address |
| `0x3000` | VERSION | design version, currently `0x0004_0000` |

A configuration is valid when `length != 0`. `length`, `loop_start`, and
`loop_end` are 24-bit frame counts. Looping modes additionally require
`loop_start < loop_end` and `loop_end <= length`. Invalid active configurations
do not produce memory requests or audio samples.
The maximum represented region length is `0x00ff_ffff` frames.

`LOOP_MODE` values are:

| Value | Name | Behavior |
| --- | --- | --- |
| `0` | no loop | play through `length`, then stop contributing |
| `1` | continuous loop | wrap from exclusive `loop_end` to `loop_start` |
| `2` | loop until release | loop while `released == 0`, then play through to `length` |

Configuration registers are `CONTROL`, `BASE_ADDR`, `BASE_ADDR_R`, `LENGTH`,
`LOOP_START`, `LOOP_END`, `PHASE_INIT`, `PHASE_INC`, `GAIN_L`, `GAIN_R`,
`LOOP_MODE`, and the filter registers. The resource-optimized register bank does
not preserve per-voice writeback read data for these addresses; reads from
per-voice configuration and runtime data registers return zero except for
`STATUS`. Software should treat this map as write-dominant and maintain any
needed mirror state on the host side.

Runtime registers are `ENVELOPE_LEVEL`, `PHASE_INC_RUNTIME`, `GAIN_RUNTIME`, and
`RELEASE_CONTROL`. Filter coefficient and control writes update shadow filter
state; writing `FILTER_CONTROL` with bit 31 set commits the complete shadow
filter group to runtime without a phase reload. Reads from runtime registers are
not a live-state inspection path in the resource-optimized RTL.

`RELEASE_CONTROL.released` is runtime state. Writes update the runtime released
flag without reloading phase. A commit clears the runtime released flag so a
reused voice starts in the held state. `LOOP_MODE` is a shadow configuration
field and becomes active on commit.

`ENVELOPE_LEVEL` is runtime state supplied by the MCU/control model. Writes update
the runtime value without requiring `COMMIT` and without reloading playback phase.
A commit preserves the current runtime envelope value while it loads the rest of
the voice configuration. This lets MCU firmware or a testbench model advance
attack, decay, sustain, and release curves while the FPGA pipeline keeps rendering
the same note.

`GAIN_L` and `GAIN_R` are shadow configuration fields copied into runtime gain by
`COMMIT`. `GAIN_RUNTIME` updates both runtime channel gains in one bus write
without copying shadow registers and without reloading playback phase. Use this
path for MIDI volume, expression, pan, or similar low-rate controller changes
where a two-write left/right gain update could otherwise be visible over SPI.

`PHASE_INC_RUNTIME` writes update the runtime phase increment without copying
shadow registers and without reloading runtime phase. Use this path for
pitch bend or low-rate vibrato control.

The filter registers configure a per-voice biquad IIR filter placed after
interpolation and before channel gain. `FILTER_CONTROL[0]` and `FILTER_B0` through
`FILTER_A2` form one shadow filter group. A voice `COMMIT` copies that group into
runtime filter state for a new note. During active playback, write the desired
shadow filter group first, then write `FILTER_CONTROL` with bit 31 set and bit 0
holding the desired enable value; that copies enable plus all five coefficients to
runtime together without reloading phase. Filter history is per voice and per
channel and is cleared on voice `COMMIT`. `FILTER_CONTROL.enable = 0` bypasses the
filter. The denominator convention is `1 + a1*z^-1 + a2*z^-2`; the RTL computes
`b0*x + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]` using a transposed form.

The RTL does not implement SF2 preset selection, velocity mapping, modulators, or
coefficient calculation; software writes already-quantized filter coefficients.
A value of `0x7fff` is treated as full envelope level and bypasses the extra
envelope multiply so existing full-scale voice gains are not attenuated by one
least-significant bit.

## Minimal Control Sequences

The FPGA does not allocate voices or parse MIDI. Software chooses a free slot,
loads sample metadata into that slot, and drives runtime controls over time. The
smallest useful actions are below.

### Note On

For a new note, write the runtime envelope first, then write the shadow
configuration, then commit. `COMMIT` updates the active renderer configuration,
stages `PHASE_INC` and `GAIN_L/R` into runtime pitch/gain, clears the staged
`RELEASE_CONTROL.released`, and requests phase reload from `PHASE_INIT` plus
filter-history clear at the next accepted output-frame boundary. Software should
not depend on a committed voice being rendered before that boundary pulse has
been accepted.

Minimal mono no-loop Note On for `slot`:

| Write order | Address | Data |
| ---: | --- | --- |
| 1 | `voice_base(slot) + 0x2c` `ENVELOPE_LEVEL` | initial Q1.15 level, commonly `0x0000_7fff` |
| 2 | `voice_base(slot) + 0x00` `CONTROL` | bit 0 `enable = 1`, bit 1 `stereo = 0` |
| 3 | `voice_base(slot) + 0x04` `BASE_ADDR` | first left/mono wave-memory word |
| 4 | `voice_base(slot) + 0x58` `BASE_ADDR_R` | ignored for mono; commonly mirror `BASE_ADDR` |
| 5 | `voice_base(slot) + 0x08` `LENGTH` | sample-frame count |
| 6 | `voice_base(slot) + 0x0c` `LOOP_START` | `0` for no-loop voices |
| 7 | `voice_base(slot) + 0x10` `LOOP_END` | `0` for no-loop voices |
| 8 | `voice_base(slot) + 0x14` `PHASE_INIT` | usually `0x0000_0000` |
| 9 | `voice_base(slot) + 0x18` `PHASE_INC` | Q24.8 playback increment |
| 10 | `voice_base(slot) + 0x1c` `GAIN_L` | signed Q1.15 initial left gain |
| 11 | `voice_base(slot) + 0x20` `GAIN_R` | signed Q1.15 initial right gain |
| 12 | `voice_base(slot) + 0x34` `LOOP_MODE` | `0` no loop |
| 13 | `voice_base(slot) + 0x38` `FILTER_CONTROL` | `0` to bypass filter |
| 14 | `voice_base(slot) + 0x3c` `FILTER_B0` | `0x1000_0000` unity, harmless when bypassed |
| 15 | `voice_base(slot) + 0x40` `FILTER_B1` | `0` |
| 16 | `voice_base(slot) + 0x44` `FILTER_B2` | `0` |
| 17 | `voice_base(slot) + 0x48` `FILTER_A1` | `0` |
| 18 | `voice_base(slot) + 0x4c` `FILTER_A2` | `0` |
| 19 | `voice_base(slot) + 0x24` `COMMIT` | `1` |

For stereo playback, write `CONTROL.stereo = 1`; `BASE_ADDR` names the first left
sample word and `BASE_ADDR_R` names the first right sample word. `LENGTH`, loop
points, and phase are still measured in sample frames. For continuous loop or
loop-until-release, write valid `LOOP_START`, exclusive `LOOP_END`, and
`LOOP_MODE = 1` or `2` before `COMMIT`.

### Envelope Update

To update amplitude during attack, decay, sustain, or release, write only:

```text
voice_base(slot) + 0x2c ENVELOPE_LEVEL = current Q1.15 envelope level
```

This does not require `COMMIT` and does not reload phase. The renderer samples
the live runtime value when it accepts each voice for rendering.

### Note Off

There are two common Note Off policies.

For `LOOP_MODE = 2` loop-until-release samples:

| Write order | Address | Data |
| ---: | --- | --- |
| 1 | `voice_base(slot) + 0x54` `RELEASE_CONTROL` | `1` |
| 2..N | `voice_base(slot) + 0x2c` `ENVELOPE_LEVEL` | decreasing release levels |

When the release envelope reaches zero, free the slot:

| Write order | Address | Data |
| ---: | --- | --- |
| 1 | `voice_base(slot) + 0x00` `CONTROL` | bit 0 `enable = 0`, keep bit 1 stereo as desired |
| 2 | `voice_base(slot) + 0x24` `COMMIT` | `1` |

For one-shot no-loop voices, software may either let playback naturally stop at
`LENGTH` or immediately start reducing `ENVELOPE_LEVEL` and then disable/commit
the slot when silent.

### Runtime Pitch And Gain

Pitch bend or low-rate vibrato writes:

```text
voice_base(slot) + 0x30 PHASE_INC_RUNTIME = new Q24.8 phase increment
```

Runtime gain, volume, expression, or pan writes both channels atomically:

```text
voice_base(slot) + 0x50 GAIN_RUNTIME = {right_gain[15:0], left_gain[15:0]}
```

Neither write reloads phase or changes shadow configuration. A later `COMMIT`
will overwrite runtime pitch and gain with the shadow `PHASE_INC` and `GAIN_L/R`
values staged for the next note setup.

### Reusing A Slot

Before reusing a slot, software should explicitly write the new note's
`ENVELOPE_LEVEL`, gains, pitch, loop mode, filter settings, and `CONTROL.enable`,
then `COMMIT`. Do not rely on runtime state left by the previous note except for
the documented commit behavior: commit clears `RELEASE_CONTROL.released` and
reloads phase/filter history at the next accepted output-frame boundary, but
preserves the live runtime envelope level.
