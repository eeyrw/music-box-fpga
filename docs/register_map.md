# Multi-Voice Register Map

The simplified bus uses 16-bit byte addresses and 32-bit data. Transactions are
single-beat and 32-bit aligned. Most voice writes update shadow registers. Reads
return shadow registers except for status, envelope, and identification
registers.

The core exposes four voice slots. Slot 0 keeps the original base address. Slot N
uses `0x0100 + N * 0x40` plus the offsets below.

| Offset | Name | Description |
| --- | --- | --- |
| `0x00` | CONTROL | bit 0 enable, bit 1 stereo |
| `0x04` | BASE_ADDR | 16-bit-word memory address |
| `0x08` | LENGTH | number of sample frames |
| `0x0c` | LOOP_START | first loop frame |
| `0x10` | LOOP_END | exclusive loop end frame |
| `0x14` | PHASE_INIT | unsigned Q16.16 initial position |
| `0x18` | PHASE_INC | unsigned Q16.16 frames per output sample |
| `0x1c` | GAIN_L | signed Q1.15 in bits 15:0 |
| `0x20` | GAIN_R | signed Q1.15 in bits 15:0 |
| `0x24` | COMMIT | write bit 0 as one to atomically activate this voice slot |
| `0x28` | STATUS | bit 0 configuration valid for this voice slot |
| `0x2c` | ENVELOPE_LEVEL | runtime signed Q1.15 envelope level in bits 15:0 |
| `0x3000` | VERSION | design version, currently `0x0002_0000` |

A configuration is valid when `length != 0`, `loop_start < loop_end`, and
`loop_end <= length`. Invalid active configurations do not produce memory
requests or audio samples.

`ENVELOPE_LEVEL` is runtime state supplied by the MCU/control model. Writes update
the active value immediately, without requiring `COMMIT` and without reloading
playback phase. A commit preserves the current active envelope value while it
loads the rest of the voice configuration. This lets MCU firmware or a testbench
model advance attack, decay, sustain, and release curves while the FPGA pipeline
keeps rendering the same note.

A Note On sequence normally writes sample address, loop range, `PHASE_INC`, gains,
initial `ENVELOPE_LEVEL`, then writes `COMMIT`. The initial envelope write is
runtime state, so firmware should set it explicitly before reusing a voice slot.
Later envelope updates write only `ENVELOPE_LEVEL`. A Note Off is represented by the MCU reducing
`ENVELOPE_LEVEL` through its release curve; when it reaches zero, software can
clear `CONTROL.enable` and commit the slot to free it.

The RTL does not implement SF2 preset selection, velocity mapping, modulators, or
filters. A value of `0x7fff` is treated as full level and bypasses the extra
multiply so existing full-scale voice gains are not attenuated by one
least-significant bit.
