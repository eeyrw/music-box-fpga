# SPI Voice Active Status

Interface version 17 makes FPGA voice activity authoritative. The FPGA exposes
the current 512-bit `voice_valid` state through one fixed SPI transaction. This
is a sampled state interface, not a completion-event queue: it has no pending
bits, sequence numbers, acknowledgements, or per-voice records.

A bit remains set while its FPGA slot is active, including during a nonzero
release envelope. Natural sample/envelope termination, a generation-matched
`VOICE_STOP`, or a zero-step `VOICE_RELEASE` clears it. Render-session reset
clears all bits.

## Transaction

Opcode `0x5c` is one fixed 88-byte SPI mode-0 transaction under one assertion
of CS. All multi-byte integers and bitmap words are big-endian on the wire.

| Bytes | MOSI request | MISO response |
| ---: | --- | --- |
| `0..3` | opcode followed by three reserved zero bytes | ignored |
| `4..11` | eight zero turnaround bytes | ignored |
| `12..83` | zero | response words `0..17` |
| `84..87` | zero | CRC32 over response bytes `12..83` |

The fixed turnaround gives the 100 MHz bridge time to snapshot the bitmap and
cross a snapshot toggle into the SCLK domain. The 72-byte response payload is
then shifted directly in the SCLK domain. CRC32 is accumulated one byte at a
time as those payload bits are transmitted, finalized with the last payload
byte, and shifted during the final four bytes. At 30 MHz the complete frame
takes about 23.5 microseconds.

The response words are:

| Word | Meaning |
| ---: | --- |
| `0` | status, protocol version `1`, flags `0`, reserved `0`; one byte each |
| `1` | render-session epoch |
| `2..17` | current 512-bit active bitmap |
| `18` | response CRC32 |

Bitmap word 2 maps voice 0 to bit 0 and voice 31 to bit 31; word 17 maps voice
480 to bit 0 and voice 511 to bit 31. Status `0` is success and status `1`
means the three request-reserved bytes were nonzero.

## MCU Reconciliation

The RP2040 reads the bitmap once per millisecond after pending command traffic
has reached the SPI transport. For each locally owned slot whose FPGA bit is
zero, it returns that slot to the allocator's free stack. MCU elapsed time never
predicts release completion.

A newly emitted START receives a one-millisecond landing guard. This guard only
prevents a status sample taken before that queued START reaches the FPGA from
freeing the new local generation; it is not a release-duration estimate.

At full 512-voice capacity, allocation does not wait for a status round trip.
The MCU selects a victim and sends a new-generation START, which atomically
replaces the FPGA slot. If the old slot was still active its bitmap bit remains
set; if it had just become inactive, the landing guard protects the replacement
until START is installed.

Generation remains part of the command and dynamic-state contracts. It rejects
late runtime commands and renderer writeback after a slot has been replaced.
The wide `generation_tag` shadow discussed in the renderer optimization plan
was a former duplicate of dynamic RAM state and has already been removed; that
resource optimization does not remove the 16-bit per-voice generation itself.

## Implementation And Hardware Qualification

The bridge holds one 576-bit payload snapshot, a 575-bit transmit shift
register, and a streaming 32-bit CRC accumulator. It does not build or retain a
second complete response frame. In the 2026-08-08 Smart Artix implementation,
the `spi_bridge` hierarchy used 1,896 LUTs and 2,123 flip-flops after physical
optimization, down from the initial status implementation's approximately
2,259 LUTs and 3,294 flip-flops.

The fresh post-route design used 28,798 of 32,600 LUTs and 28,249 of 65,200
flip-flops. All 50,899 routable nets were routed, DRC reported no errors, and
setup/hold timing passed with WNS `+0.008 ns`, TNS `0`, WHS `+0.035 ns`, and THS
`0`. The setup margin is valid but too narrow to treat later RTL changes as
timing-neutral; every production RTL change still requires a fresh
implementation.

FPGA and RP2040 hardware were programmed from that build and the requested
`debussy_bergamasque_03.mid` file was played completely at 30 MHz SPI. The run
reached 143 simultaneous voices and ended with zero active voices after 5,944
FPGA-authoritative reclaims. UART diagnostics reported 373,118 status polls,
378,397 total SPI exchanges, 33,445,700 transferred bytes, and zero SPI errors,
status failures, bitmap/local-state errors, stale commands, command errors, or
DMA enqueue timeouts. This qualifies the implemented polling path under that
real MIDI workload; it is not a maximum-rate synthetic command-stream
qualification.
