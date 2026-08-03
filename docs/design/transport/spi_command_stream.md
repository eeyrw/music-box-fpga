# SPI Command-Stream Throughput

This document defines Smart Artix SPI opcode `0xa5` command traffic and opcode
`0xa6` command recovery for interface version 15. It retains the version-10
command encoding behind the version-12 aligned length/CRC16 transaction header.
Register timing and
transport correctness are documented separately in
[`spi_register_mailbox.md`](spi_register_mailbox.md) and
[`../../backlog/spi_transport.md`](../../backlog/spi_transport.md).

The status and workload assumptions were refreshed against the production RTL
and CH347 host implementation on 2026-08-03.

## Current Configuration

| Item | Value |
| --- | ---: |
| Request-receiver clock | 100 MHz MIG UI clock |
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
SPI mode 0, CS low, aligned {0xa5, word_count, CRC16} header
  -> bounded staging of consecutive big-endian 32-bit words
  -> length, command-boundary, and optional CRC validation after CS rises
  -> held ready/valid commit in spi_register_bridge
  -> shared 1024-word command FIFO
  -> version-10 parser and generation validation
  -> active mono voice state or global effects configuration
  -> next admitted render block
```

Version 14 removes the former debug register injection path. All command words
enter through complete `0xa5` transactions. Simulation and hardware use the
same command parser; there is no typed state-install bypass.

Version 15 adds a separate `0xa6` FLUSH transaction. It does not enter the
63-word staging RAM as a command word:

```text
SPI mode 0, CS low, {0xa6, 0x00, CRC16}, CS high
  -> cancel any unpublished staging commit
  -> held request/ack sideband into the command plane
  -> clear the 1024-word FIFO and reset the parser to READ_HEADER
```

CRC-16/CCITT-FALSE covers both bytes `0xa6, 0x00`; the fixed valid frame is
`a6 00 aa d7`. Reserved flags must be zero. When CRC checking is enabled, a
corrupt frame is rejected without cancellation. A pending flush also causes a
new `0xa5` transaction to be rejected as a whole.

FLUSH preserves active voice state, already accepted state-store actions,
global audio configuration, effect history, and diagnostics. It cannot recall
commands still queued by the host, so software must quiesce or clear its local
producer before issuing FLUSH. The current recovery entry point is
`tools/ch347_tool.py flush`.

The bridge cannot backpressure SPI after CS is asserted, so it receives the
complete declared transaction into a 63-word synchronous block RAM. A valid
transaction is committed only after CS rises; downstream `cmd_ready`
backpressure holds the current staged word instead of dropping it. Synchronous
RAM read-ahead adds one system-clock cycle before the first committed word and
then sustains one word per system clock while `cmd_ready` remains asserted. A
new command transaction that arrives before the prior staged commit drains is
rejected as a whole.

`CMD_FIFO_STATUS[15:2]` exposes FIFO occupancy, so software can calculate:

```text
free_words = 1024 - CMD_FIFO_STATUS[15:2]
```

The current `Ch347CommandTransport::write_command_words` does not perform this
read. It sends the supplied command immediately; bridge staging decouples SPI
reception from temporary command-FIFO backpressure. Capacity preflight remains
useful for avoiding a busy rejection when a prior staged transaction has not
finished committing, but it is no longer the transaction-atomicity mechanism.

## Current Host Framing

The CH347 transport has a 256-byte local transfer limit, so its byte buffer
could hold at most 63 command words:

```text
4 header bytes + 63 * 4 data bytes = 256 bytes
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

The aligned header is `{8'ha5, word_count[7:0], payload_crc16[15:0]}`.
CRC-16/CCITT-FALSE covers the count byte followed by all payload bytes in
big-endian order. The wire field is always present; FPGA parameter
`CHECK_COMMAND_CRC` may disable comparison.

The same parameter controls FLUSH CRC comparison without changing the `0xa6`
wire format. The Python transport exposes `flush_command_stream()`, and
`tools/ch347_tool.py flush` sends this operation directly.

## Command Sizes

Sizes include the header:

| Operation | Words | Wire bits with the four-byte transport header |
| --- | ---: | ---: |
| `VOICE_START_MONO`, no loop/filter/envelope | 6 | 224 |
| `VOICE_START_MONO`, loop only | 8 | 288 |
| `VOICE_START_MONO`, envelope only | 12 | 416 |
| `VOICE_START_MONO`, loop/filter/envelope | 17 | 576 |
| `VOICE_ENV_UPDATE` | 8 | 288 |
| `VOICE_RELEASE` | 3 | 128 |
| `VOICE_STOP` | 2 | 96 |
| `VOICE_GAIN` | 3 | 128 |
| `VOICE_FILTER` | 5 | 192 |
| `VOICE_PITCH` | 3 | 128 |
| compressor config | 5 | 192 |
| master volume | 2 | 96 |
| chorus config | 7 | 256 |
| reverb config | 10 | 352 |
| effect clear | 2 | 96 |

Linked SoundFont stereo consumes two voices and two `VOICE_START_MONO`
commands. There is no stereo command or dual-stream hardware voice.

## Runtime Workloads

For `N` active voices, update rate `F`, and one `W`-word command per update, the
current one-command-per-CS wire rate is:

```text
wire_bits_per_second = N * F * (32 + W * 32)
```

The following table includes the four-byte header on every command transaction:

| Per-voice update rate | Gain, 3 words | Pitch, 3 words | Filter, 5 words | All three groups |
| ---: | ---: | ---: | ---: | ---: |
| 50 Hz | 3.277 Mbps | 3.277 Mbps | 4.915 Mbps | 11.469 Mbps |
| 100 Hz | 6.554 Mbps | 6.554 Mbps | 9.830 Mbps | 22.938 Mbps |
| 200 Hz | 13.107 Mbps | 13.107 Mbps | 19.661 Mbps | 45.875 Mbps |

Updating every parameter group on every voice is a synthetic stress case, not
normal MIDI traffic. Gain, pitch, and filter are independent commands, and the
C++ policy suppresses unchanged groups. Envelope advancement runs in RTL and
does not require per-frame SPI updates.

The 512-voice, 50 Hz all-groups row already requires 11.469 Mbps before USB call
gaps or CS idle time. It cannot fit a 7.5 MHz link. The mailbox/DDR path has
passed at 30 MHz with SCLK on `J20`, but opcode-`0xa5` command streaming still
requires a separate hardware stress run before that rate is claimed for command
traffic. Request reception remains a 100 MHz oversampling path, so the 60 MHz
CH347 step is structurally unsupported.
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
- With SCLK on clock-capable header pin 14 / `J20`, the mailbox/DDR path passed
  300/300 exact hardware rounds at the actual 30 MHz CH347 step.
- The 60 MHz CH347 step is structurally unsupported by the remaining 100 MHz
  oversampling request receiver; the available adapter steps do not locate a
  finer threshold between 30 MHz and the receiver's limit below 50 MHz.
- Opcode `0xa5` command traffic still requires a separate 30 MHz hardware stress
  run before 30 MHz is claimed for command streaming.

## Hardware Qualification

Before increasing SCLK:

1. retain the scoped synchronizer attributes/exceptions, constrained SCLK, and
   falling-edge MISO OLOGIC placement described in the board I/O backlog;
2. validate command writes separately from the qualified register/DDR path;
3. exercise every command size, FIFO wrap, and near-full behavior;
4. inject partial words and CS termination and observe `spi_error` plus parser
   recovery;
5. run the maximum intended command workload during 512-voice rendering;
6. check command errors, render deadlines, output lead, underruns, and drops;
7. record requested and actual CH347 rates, duty cycle, wiring, voltage, and
   temperature assumptions.
