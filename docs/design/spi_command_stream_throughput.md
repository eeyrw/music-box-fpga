# SPI Command-Stream Throughput

This document sizes Smart Artix SPI opcode `0xa5` traffic for interface version
10. Register timing and transport correctness are documented separately in
[`spi_register_timing.md`](spi_register_timing.md) and
[`spi_transport_backlog.md`](spi_transport_backlog.md).

The status and workload assumptions were refreshed against the production RTL
and CH347 host implementation on 2026-07-30.

## Current Configuration

| Item | Value |
| --- | ---: |
| System clock | 100 MHz MIG UI clock |
| Audio sample rate | 48 kHz |
| Maximum render block | 16 frames |
| Default voice slots | 512 mono voices |
| Command word width | 32 bits |
| Command FIFO | 1024 words |
| CH347 requested default | 1 MHz |
| Sample window | 32 mono words per voice |
| DDR transaction | 8 words / 128 bits |

The renderer drains pending commands before admitting a block. Commands become
visible at a block boundary and do not carry target-frame timestamps.

## Implemented Data Path

```text
SPI mode 0, CS low, opcode 0xa5
  -> consecutive big-endian 32-bit words
  -> per-word ready check in spi_register_bridge
  -> shared 1024-word command FIFO
  -> version-10 parser and generation validation
  -> active mono voice state or global effects configuration
  -> next admitted render block
```

`CMD_FIFO_DATA` writes enter the same FIFO. A simultaneous direct SPI word has
priority and the register write is rejected. Simulation and hardware use the
same command parser; there is no typed state-install bypass.

The bridge cannot backpressure SPI after CS is asserted. It tests `cmd_ready`
only when a complete word arrives. If the FIFO becomes unavailable, it drops
that word, asserts the `spi_error` output for the transaction, and leaves any
earlier words committed. This is not packet atomic and is tracked as SPI-001 in
`spi_transport_backlog.md`.

`CMD_FIFO_STATUS[15:2]` exposes FIFO occupancy, so software can calculate:

```text
free_words = 1024 - CMD_FIFO_STATUS[15:2]
```

That is a useful diagnostic and a possible future preflight rule, but the
current `Ch347RegisterTransport::write_command_words` does not perform this
read. It sends the supplied command immediately and relies on the normal sparse
workload and FIFO capacity. Capacity preflight alone would not make the
transaction atomic because occupancy may change before or during the transfer.

## Current Host Framing

The CH347 transport has a 256-byte local transfer limit, so its byte buffer
could hold at most 63 command words:

```text
1 opcode byte + 63 * 4 data bytes = 253 bytes
```

The host API accepts one or more complete commands up to that 63-word limit. It
walks the command headers before starting the transfer, rejects an incomplete
final command, and enforces the parser's 16-word per-command payload limit.
`CommandVoiceControl` calls `write_command_words` once per command, so current
production traffic still uses one command per CS.
`FrameBatchedCommandSink` delays commands to a host frame boundary but then
sends each queued command separately. Linked stereo consequently uses two
separate mono command transactions unless a future sink explicitly coalesces
them.

## Command Sizes

Sizes include the header:

| Operation | Words | Wire bits with one `0xa5` byte |
| --- | ---: | ---: |
| `VOICE_START_MONO`, no loop/filter/envelope | 6 | 200 |
| `VOICE_START_MONO`, loop only | 8 | 264 |
| `VOICE_START_MONO`, envelope only | 12 | 392 |
| `VOICE_START_MONO`, loop/filter/envelope | 17 | 552 |
| `VOICE_ENV_UPDATE` | 8 | 264 |
| `VOICE_RELEASE` | 3 | 104 |
| `VOICE_STOP` | 2 | 72 |
| `VOICE_GAIN` | 3 | 104 |
| `VOICE_FILTER` | 5 | 168 |
| `VOICE_PITCH` | 3 | 104 |
| compressor config | 5 | 168 |
| master volume | 2 | 72 |
| chorus config | 7 | 232 |
| reverb config | 10 | 328 |
| effect clear | 2 | 72 |

Linked SoundFont stereo consumes two voices and two `VOICE_START_MONO`
commands. There is no stereo command or dual-stream hardware voice.

## Runtime Workloads

For `N` active voices, update rate `F`, and one `W`-word command per update, the
current one-command-per-CS wire rate is:

```text
wire_bits_per_second = N * F * (8 + W * 32)
```

The following table includes the `0xa5` byte on every command transaction:

| Per-voice update rate | Gain, 3 words | Pitch, 3 words | Filter, 5 words | All three groups |
| ---: | ---: | ---: | ---: | ---: |
| 50 Hz | 2.662 Mbps | 2.662 Mbps | 4.301 Mbps | 9.626 Mbps |
| 100 Hz | 5.325 Mbps | 5.325 Mbps | 8.602 Mbps | 19.251 Mbps |
| 200 Hz | 10.650 Mbps | 10.650 Mbps | 17.203 Mbps | 38.502 Mbps |

Updating every parameter group on every voice is a synthetic stress case, not
normal MIDI traffic. Gain, pitch, and filter are independent commands, and the
C++ policy suppresses unchanged groups. Envelope advancement runs in RTL and
does not require per-frame SPI updates.

The 512-voice, 50 Hz all-groups row already requires 9.626 Mbps before USB call
gaps or CS idle time. It cannot fit a 7.5 MHz link. A 15 MHz link has enough raw
bits but is not a qualified rating for the current 100 MHz oversampling bridge.
Therefore this table identifies workloads that require either lower update
density, command ramps/aggregation, or a future timing-closed transport; it
does not establish a board SCLK.

## Burst And FIFO Capacity

The 1024-word FIFO can hold 60 maximum 17-word START commands with four words
remaining, or 170 default six-word START commands with four words remaining.
These are storage limits, not guaranteed atomic burst sizes.

The current host sends one START per CS. A future coalescing sink could fit
three maximum STARTs or ten default STARTs in one 63-word CH347 frame, but it
must first solve complete-transaction reservation and rejection. Keeping linked
stereo commands adjacent is useful for ordering but does not make the pair
atomic.

## Renderer And DDR Context

Wave samples do not cross SPI. Each active hardware voice consumes one mono
sample stream. The current renderer uses 16-frame blocks, eight prepared job
entries, ordered line descriptors, and a fixed eight-lane DSP barrel. Samples
come through one persistent 32-word window per voice and queued ordered DDR
reads.

The measured one-second 512-voice timed-DDR3 render completed 48,000 frames with
zero renderer deadline misses. The RTL-effects run measured 31,905 maximum
renderer clocks and 33,228 maximum render-to-effects-release clocks. These
results qualify renderer behavior under the simulation memory profile; they do
not qualify SPI pins, physical SCLK, or the board-equivalent DDR path.

## Current Operating Position

- The host requests 1 MHz by default; the CH347 discrete table selects
  937.5 kHz for that request.
- Board bring-up should then measure requests of 2 MHz and 5 MHz, which select
  1.875 MHz and 3.75 MHz on the current CH347 mapping.
- A 10 MHz request selects 7.5 MHz and is an upper stress target for the current
  oversampling implementation, not a released rating.
- The old 15 MHz command-write target remains a throughput data point only. Do
  not use it until CDC, external timing, and physical measurements justify it.

## Hardware Qualification

Before increasing SCLK:

1. add the scoped synchronizer attributes/exceptions and physical MISO delay
   described in the board I/O backlog;
2. validate command writes separately from register reads;
3. exercise every command size, FIFO wrap, and near-full behavior;
4. inject partial words and CS termination and observe `spi_error` plus parser
   recovery;
5. run the maximum intended command workload during 512-voice rendering;
6. check command errors, render deadlines, output lead, underruns, and drops;
7. record requested and actual CH347 rates, duty cycle, wiring, voltage, and
   temperature assumptions.
