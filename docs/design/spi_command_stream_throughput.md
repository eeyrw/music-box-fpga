# SPI Command-Stream Throughput

This document estimates the useful throughput required by the dedicated SPI
command stream and derives a practical SCLK target for the current Smart Artix
system. It applies only to opcode `0xa5` command writes. Register reads and
register burst transactions have different turnaround and wait-state behavior
and must not use the command-stream result as their timing limit.

The result is a workload target, not a board-level timing guarantee. The current
Smart Artix constraints do not specify SPI input/output delays, and the SPI pins
are sampled asynchronously by the `100 MHz` MIG UI clock. Physical validation
is still required for the selected host, cable, header, and FPGA image.

## Current Configuration

The calculation uses the current board and control-plane constants:

| Item | Value |
| --- | ---: |
| System clock | `100 MHz` |
| Audio sample rate | `48 kHz` |
| Command word width | 32 bits |
| Command word FIFO | 1024 words |
| Decoded action FIFO | 32 actions |
| Maximum action batch | 16 actions per rendered frame |
| Configured voice slots | 256 |
| PCM FIFO target | 48 frames |

One audio frame therefore has this system-clock budget:

```text
100,000,000 / 48,000 = 2083.33 system clocks per audio frame
```

The PCM FIFO normally keeps about 48 frames of audio lead, or about `1 ms` at
`48 kHz`. A complete command has no timestamp; after it is parsed, it becomes
eligible at the next render-frame boundary that has not started.

## Command-Stream Data Path

The dedicated transport is:

```text
SPI mode 0
  -> opcode 0xa5
  -> consecutive big-endian 32-bit words
  -> one-cycle cmd_valid pulse per complete word
  -> 1024-word command FIFO
  -> parser
  -> 32-action FIFO
  -> at most 16 actions before a render frame is released
```

Unlike register burst writes, `STATE_STREAM_DATA` has no per-word
`WRITE_WAIT` state. Consecutive words can therefore be sent without an idle
SCLK between them. On the last rising edge of every 32-bit word, the bridge
checks `cmd_ready`. It emits `cmd_valid` when ready; otherwise it discards that
word and sets `spi_error` because SPI cannot backpressure the master.

The host must read `CMD_FIFO_STATUS` before a stream transaction and calculate:

```text
free_words = 1024 - CMD_FIFO_STATUS[15:2]
```

It must send no more than `free_words`. Space must be reserved for the complete
transaction before CS is asserted; observing only the full bit is insufficient
for a multi-word write.

This preflight rule reduces overflow risk for a single producer but does not
make the current transaction atomic. Per-word rejection after a DMA has started
and silent discard of a partial final word are tracked as P0 correctness bugs in
[`spi_transport_backlog.md`](spi_transport_backlog.md).

The current CH347 transport has a 256-byte local transfer buffer. One byte is
the `0xa5` opcode, so a transaction can contain at most 63 command words:

```text
1 + 63 * 4 = 253 bytes
```

At that size, opcode overhead is only `1 / 253`, approximately `0.4%`.

## Renderer Throughput Context

Wave samples do not cross SPI. DDR3 supplies the PCM endpoints, while SPI sends
only lifecycle and runtime state changes. The SPI rate therefore does not need
to equal the wave-memory bandwidth.

The renderer scans all configured voice slots for every output frame. Existing
256-slot render artifacts with one or two active voices report approximately
`268` to `283` system clocks per frame. This measurement establishes the fixed
scan and pipeline cost for that workload; it is not a full-polyphony board
measurement.

Each contributing mono voice needs at least two accepted PCM word requests and
each stereo voice needs four. Ignoring memory stalls, a conservative first-order
estimate for 256 active stereo voices is:

```text
fixed scan/pipeline cost + endpoint issue cost
about 269 + 256 * 4 = 1293 clocks per frame
```

That fits inside the `2083`-clock audio-frame budget with about 790 clocks left
for response latency and drain. DDR cache misses, MIG arbitration, and response
queue stalls remain the real full-polyphony risk and must be measured rather
than inferred from this estimate.

At 256 active voices, the renderer represents:

```text
256 * 48,000 = 12.288 million voice samples per second
```

The logical endpoint rate is `24.576 million PCM words/s` for all mono voices
or `49.152 million PCM words/s` for all stereo voices. That traffic belongs to
the DDR path, not the SPI command path.

## Command Sizes

Command sizes include the 32-bit command header:

| Operation | Words | Bits |
| --- | ---: | ---: |
| Mono DEFINE | 12 | 384 |
| Stereo DEFINE | 16 | 512 |
| START | 9 | 288 |
| Mono DEFINE + START | 21 | 672 |
| Stereo DEFINE + START | 25 | 800 |
| GAIN_PHASE | 3 | 96 |
| FILTER | 4 | 128 |
| GAIN_PHASE + FILTER | 7 | 224 |
| RELEASE | 2 | 64 |
| STOP | 1 | 32 |

The FPGA volume envelope advances internally for every rendered sample. It does
not require per-sample SPI writes. The recurring host load comes from MIDI
events, voice allocation, LFO/modulator policy, pitch/gain changes, and filter
coefficient changes.

## Runtime-Update Workloads

For `N` active voices, update frequency `Fupdate`, and `W` command words per
voice update, the payload requirement is:

```text
payload_bits_per_second = N * Fupdate * W * 32
```

For all 256 voices, the relevant cases are:

| Per-voice update rate | GAIN_PHASE, 3 words | FILTER, 4 words | Both, 7 words |
| ---: | ---: | ---: | ---: |
| 50 Hz | 1.229 Mbps | 1.638 Mbps | 2.867 Mbps |
| 100 Hz | 2.458 Mbps | 3.277 Mbps | 5.734 Mbps |
| 200 Hz | 4.915 Mbps | 6.554 Mbps | 11.469 Mbps |

Updating both runtime groups for every voice at `100 Hz` is a deliberately
demanding but useful design point. It requires `5.734 Mbps` of command words.
Allowing approximately 2x margin for USB transaction gaps, host scheduling,
status reads, uneven bursts, and future command growth gives a raw SPI target
near `12 Mbps`.

The useful update rate at a given SCLK can be estimated by reserving only part
of the raw link for sustained payload. With a 70% utilization target:

| SCLK | GAIN_PHASE | FILTER | Both |
| ---: | ---: | ---: | ---: |
| 7.5 MHz | 214 Hz | 160 Hz | 94 Hz |
| 15 MHz | 427 Hz | 320 Hz | 188 Hz |

These rates update all 256 voices. A normal musical workload with fewer active
voices scales inversely with the active-voice count. For example, 64 voices can
be updated four times as often at the same link utilization.

## Voice-Start Latency

The pure wire time for complete DEFINE+START pairs is:

| SCLK | Mono, 672 bits | Stereo, 800 bits |
| ---: | ---: | ---: |
| 7.5 MHz | 89.6 us | 106.7 us |
| 15 MHz | 44.8 us | 53.3 us |

These times exclude USB and host scheduling latency. Both are small relative to
the normal `1 ms` PCM lead, but `15 MHz` leaves more room for chord bursts and
controller updates before a future render boundary.

A maximum-size 63-word CH347 command transaction takes about `134.9 us` at
`15 MHz`. It can carry exactly three mono DEFINE+START pairs, or two stereo
DEFINE+START pairs with room for additional runtime commands.

## FPGA-Side Consumption Limit

The parser can consume command words at up to one word per `100 MHz` system
clock when its output is not blocked. This is far above any safe SCLK rate. At
`15 MHz`, a new SPI word arrives only once every:

```text
32 / 15,000,000 = 2.133 us
2.133 us * 100 MHz = 213 system clocks
```

The decoded-action executor is intentionally bounded to 16 actions before it
releases a waiting render frame. At `48 kHz`, the long-term architectural bound
is up to `768,000 actions/s`, subject to executor cycles and renderer credit.
This bound prevents control traffic from starving audio; it is not a required
SPI throughput. Even a `15 MHz` stream supplies only `468,750 command words/s`,
and multi-word commands reduce the action rate further.

Consequently, the SPI link is the rate limiter for extreme control traffic,
while the parser and word FIFO provide ample clock-rate margin. This is the
intended balance: audio rendering must remain bounded even if the host sends a
continuous command stream.

## SCLK Sampling Margin

`spi_sclk`, `spi_cs_n`, and `spi_mosi` are sampled into the `100 MHz` system
clock domain. The bridge detects edges from synchronized SCLK samples. For a
50% duty-cycle clock, the approximate number of system clocks per SCLK half
period is:

| SCLK | System clocks per half period | Assessment |
| ---: | ---: | --- |
| 7.5 MHz | 6.67 | Large sampling margin |
| 15 MHz | 3.33 | Practical stream-write target |
| 30 MHz | 1.67 | Insufficient margin for a safe asynchronous contract |
| 60 MHz | 0.83 | An SCLK level can be missed |

The command stream uses only synchronized rising edges for input data and does
not depend on MISO timing. This makes it less restrictive than register reads.
Nevertheless, `30 MHz` provides too little phase and metastability margin to be
called safe with the current oversampling implementation. `60 MHz` is outside
the structural capture limit because a high or low interval can be shorter than
one system-clock period.

The existing self-checking SPI test exercises a five-word command stream with a
nominal 60 ns bit period, approximately `16.67 MHz`, but uses fixed simulation
phase and asymmetric 20 ns high/40 ns low timing. It validates logical framing;
it does not model metastability, pad delay, cable integrity, or post-route input
timing.

## Recommended Operating Point

The command-stream workload target is:

```text
SPI mode                         0
validated SCLK target            15 MHz
fallback SCLK                    7.5 MHz
minimum sustained useful rate    6 Mbps
preferred sustained useful rate  8 to 10 Mbps
reference workload               256 voices, both runtime groups at 100 Hz
maximum CH347 transaction         63 command words
```

`15 MHz` is a rational match for the synthesizer because it supports the
reference workload with substantial payload margin while retaining more than
three `100 MHz` samples per SCLK half period. Raising SCLK to `30 MHz` adds link
capacity that ordinary voice control does not need and gives up most of the
current sampling margin.

This recommendation does not raise the guaranteed register-access frequency.
Register reads must retain their separate conservative bring-up rate because
their MISO turnaround path is more restrictive. See
[`spi_register_timing.md`](spi_register_timing.md) for the single/burst
read/write timing and throughput analysis.

## Hardware Qualification

Qualify command-stream SCLK independently from register reads:

1. Establish register access at the conservative bring-up rate.
2. Send command streams at `7.5 MHz`, then `15 MHz`, without using MISO inside
   the stream transaction.
3. Sweep transaction sizes from 1 through 63 words, including partial FIFO
   availability and back-to-back USB transfers.
4. Vary command alignment so every opcode and payload pattern exercises long
   runs of zeroes, ones, and alternating bits.
5. Run sustained traffic while rendering maximum intended mono and stereo
   polyphony and while DDR cache misses are present.
6. Check `spi_error`, `CMD_FIFO_STATUS`, `CMD_ERROR_STATUS`, stale-sequence
   status, audio underrun/drop/deadline flags, and the received command count.
7. Measure SCLK duty cycle, CS-to-first-clock setup, MOSI setup/hold, and actual
   CH347 frequency with a logic analyzer or oscilloscope.

A board release may call `15 MHz` supported only after this test passes on the
selected physical connection and the SPI paths receive explicit timing/CDC
constraints or a documented asynchronous-interface exception.
