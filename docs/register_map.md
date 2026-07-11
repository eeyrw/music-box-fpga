# Single-Voice Register Map

The simplified bus uses 16-bit byte addresses and 32-bit data. Transactions are
single-beat and 32-bit aligned. Writes update shadow registers. Reads return
shadow registers except for status and identification registers.

| Address | Name | Description |
| --- | --- | --- |
| `0x0100` | CONTROL | bit 0 enable, bit 1 stereo |
| `0x0104` | BASE_ADDR | 16-bit-word memory address |
| `0x0108` | LENGTH | number of sample frames |
| `0x010c` | LOOP_START | first loop frame |
| `0x0110` | LOOP_END | exclusive loop end frame |
| `0x0114` | PHASE_INIT | unsigned Q16.16 initial position |
| `0x0118` | PHASE_INC | unsigned Q16.16 frames per output sample |
| `0x011c` | GAIN_L | signed Q1.15 in bits 15:0 |
| `0x0120` | GAIN_R | signed Q1.15 in bits 15:0 |
| `0x0124` | COMMIT | write bit 0 as one to atomically activate shadow state |
| `0x0128` | STATUS | bit 0 configuration valid |
| `0x3000` | VERSION | design version, currently `0x0001_0000` |

A configuration is valid when `length != 0`, `loop_start < loop_end`, and
`loop_end <= length`. Invalid active configurations do not produce memory
requests or audio samples.
