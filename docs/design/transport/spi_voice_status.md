# SPI Voice Completion Log

Interface version 18 makes FPGA voice completion authoritative. The FPGA records
each completed `(voice, generation)` in a 512-entry log implemented as one
true-dual-port BRAM. The renderer writes on
the 100 MHz system-clock port and the SPI response streams synchronous reads
from the 30 MHz SCLK port.

## Completion Events

The state store emits exactly one event when an active generation becomes
inactive:

| Reason | Meaning |
| ---: | --- |
| `0` | renderer writeback reports natural sample or envelope completion |
| `1` | generation-matched `VOICE_STOP` completes immediately |
| `2` | generation-matched `VOICE_RELEASE` has a zero release step |

Each 32-bit BRAM word is
`{generation[15:0], voice[8:0], 1'b0, reason[1:0], 4'b0}`. Generation remains
16 bits because it is the identity that prevents an old completion from freeing
a newer replacement in the same slot. A new-generation START may replace a
voice immediately at 512-voice capacity; it does not wait for a completion read.

The producer sequence and MCU consumer sequence are unsigned 16-bit counters.
Only their modulo difference is used, and the live log occupancy never exceeds
512, so wraparound is unambiguous.

## Transaction

Opcode `0x5d` is one fixed 93-byte SPI mode-0 transaction under one assertion
of CS. All multi-byte fields and event words are big-endian. At 30 MHz it takes
24.8 microseconds, or about 2.48 percent of SPI wire time when polled every
millisecond.

| Bytes | MOSI request | MISO response |
| ---: | --- | --- |
| `0` | opcode `0x5d` | ignored |
| `1..2` | next consumer sequence | ignored |
| `3..4` | CRC16-CCITT over bytes `0..2` | ignored |
| `5..12` | eight zero turnaround bytes | ignored |
| `13..88` | zero | 76-byte response payload |
| `89..92` | zero | CRC32 over bytes `13..88` |

The response payload is:

| Bytes | Meaning |
| ---: | --- |
| `13` | status: `0` success, `1` invalid sequence |
| `14` | response version `1` |
| `15` | flags; bit 0 is sticky log overflow, all other bits zero |
| `16` | item count, `0..16` |
| `17..20` | render-session epoch |
| `21..22` | FPGA write sequence captured for this response |
| `23..24` | response start sequence, equal to the request sequence |
| `25..88` | sixteen 32-bit event positions; unused positions are zero |
| `89..92` | response CRC32 |

For a valid response, `count` is exactly
`min(uint16(write_sequence - start_sequence), 16)`. The turnaround covers the
request crossing into the system-clock domain and the stable response metadata
crossing back. BRAM payload reads then occur directly in the SCLK domain, so no
wide snapshot or 512-bit shift register is required.

## Acknowledgement And Recovery

The request sequence acknowledges every event before that sequence and asks for
events beginning at it. A valid query advances the FPGA acknowledgement only to
the requested sequence, not beyond the returned batch. Therefore repeating the
same request after a bad response CRC returns the same events. The MCU advances
its sequence by `count` only after the complete response validates.

The FPGA never overwrites an entry at or after its acknowledged sequence. If a
new completion arrives while all 512 entries remain unacknowledged, it sets the
sticky overflow flag instead of silently losing ownership information. The MCU
must reset the render session on overflow, epoch mismatch, an invalid event, or
an impossible sequence/count combination. Session reset clears the log and both
sequences; normal transport errors retain the consumer sequence for retry.

The MCU polls once per millisecond after queued command writes are idle. It
returns a local voice to the free stack only when both the event voice and the
16-bit generation match the currently owned voice. A completion for a free slot
or an older generation is consumed but cannot affect the current owner. The MCU
does not estimate release duration and does not send a redundant STOP after a
normal release.

## Implementation Status

The fresh post-route implementation uses 28,614 of 32,600 LUTs (87.77
percent), 27,555 flip-flops, 39 DSPs, and 47 BRAM tiles. All 50,800 routable
nets are fully routed, DRC has no errors, and timing passes with WNS `+0.159 ns`
and WHS `+0.058 ns`. The completion log is inferred as one 512-by-32 true
dual-port RAMB18 and uses about 197 LUTs and 76 flip-flops; the complete SPI
bridge uses about 1,494 LUTs and 1,303 flip-flops.
