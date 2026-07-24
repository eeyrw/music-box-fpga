# SPI Register Timing And Throughput

This document analyzes normal and burst register transactions through
`spi_register_bridge`. It is a companion to
[`spi_command_stream_throughput.md`](spi_command_stream_throughput.md), which
covers only opcode-`0xa5` command writes.

Register writes and reads do not have the same limit. Writes are primarily
limited by asynchronous SCLK/MOSI capture. Reads also depend on synchronized
SCLK falling-edge detection, MISO update latency, register-bus response time,
and the master's next sampling edge. Gapless burst reads are the most
restrictive current transaction type.

The frequencies below are RTL timing estimates and hardware-validation targets,
not a board-level guarantee. The Smart Artix XDC does not yet constrain SPI
input/output delays, and no physical SPI timing report or cable measurement is
available.

## Current Clock And Protocol

The Smart Artix system runs `spi_register_bridge` in the `100 MHz` MIG UI clock
domain:

```text
Tsys = 10 ns
SPI mode = 0
MOSI sampled from synchronized SCLK rising edges
MISO advanced after synchronized SCLK falling edges
```

The external `spi_sclk`, `spi_cs_n`, and `spi_mosi` inputs pass through two-bit
synchronizing shift registers. Edge detection and the protocol state machine
run on `clk`, not on `spi_sclk`.

The register frames are:

```text
single read:   0x00, address[15:8], address[7:0], 4 data bytes
burst read:    0x40, address[15:8], address[7:0], N * 4 data bytes
single write:  0x80, address[15:8], address[7:0], 4 data bytes
burst write:   0xc0, address[15:8], address[7:0], N * 4 data bytes
```

All fields are transmitted most-significant byte first. Burst transactions
increment the register address by four after each 32-bit word.

## Current Register-Bus Response

The current generic, common-status, and Smart Artix platform register windows
all return `ready` combinationally from `valid`. A register access therefore
completes without an arbitrary downstream stall once the SPI bridge asserts
`bus_valid`.

This is an important assumption. The SPI protocol has no ready or wait signal
to the master. If a future register target can hold `bus_ready` low, gapless
burst traffic can overrun the bridge unless the target is snapshotted, buffered,
or the SPI transaction defines explicit dummy clocks.

An MCU DMA cannot react to an in-transaction BUSY indication. The packetized
request/response transport, posted-write behavior, and split-phase read tasks
needed to remove this assumption are tracked in
[`spi_transport_backlog.md`](spi_transport_backlog.md).

The DDR debug aperture remains a register protocol, not a blocking DDR read.
Writing its control register starts one 128-bit MIG operation; software polls a
status register later. MIG latency therefore does not directly extend the SPI
register response.

## Write Timing

### Single Write

The bridge captures 32 data bits on synchronized rising edges. On the final bit
it asserts `bus_valid`, `bus_write`, and the complete `bus_wdata`, then enters
`STATE_WRITE_WAIT`. With the current immediate-ready targets, the write is
acknowledged on the following system clock.

CS must remain low long enough after the final data edge for that handshake to
complete. Normal mode-0 masters deassert CS after the final falling edge. At the
recommended frequencies, the independently synchronized CS path leaves ample
system-clock margin, but this must still be checked on the physical master.

### Burst Write

At every 32-bit boundary, burst write briefly enters `STATE_WRITE_WAIT`. With an
immediate-ready register target, it returns to `STATE_WRITE_DATA` one system
clock later and increments the address by four.

The next word's first rising edge occurs one complete SCLK period after the
previous word's last rising edge. At `15 MHz`, that interval is `66.7 ns`, or
about 6.67 system clocks, so the one-clock bus handshake does not require an
SCLK gap. The limiting factor remains reliable asynchronous sampling of each
SCLK high and low interval, not the word-boundary register write.

For a 50% duty-cycle SCLK:

| SCLK | System clocks per half period | Write assessment |
| ---: | ---: | --- |
| 7.5 MHz | 6.67 | Large margin |
| 10 MHz | 5.00 | Large margin |
| 15 MHz | 3.33 | Practical validation target |
| 30 MHz | 1.67 | Too little asynchronous sampling margin for a safe contract |
| 60 MHz | 0.83 | SCLK levels can be missed |

The recommended current write target is therefore `15 MHz`, with `7.5 MHz` as
the initial hardware qualification rate. `30 MHz` may work in a favorable lab
setup but is not a safe operating point for the current oversampling design.

## Single-Read Timing

A read request is launched after the final address rising edge. With an
immediate-ready target, the bridge needs approximately:

```text
external address edge synchronization  up to about 2 Tsys
register response and MISO load         about 1 Tsys
```

The master does not sample the first data bit until one full SCLK period after
the final address bit, so this initial turnaround is not normally the limiting
part of a single read at 10 or 15 MHz.

During the data field, the master samples MISO on rising edges. The bridge sees
the preceding falling edge through its synchronizer and then changes MISO. The
low half period must cover up to approximately two `100 MHz` clocks plus FPGA
clock-to-output, board delay, and master setup time:

```text
low half period > about 20 ns + physical timing margin
```

The pure RTL boundary is therefore near `25 MHz`, but that leaves no phase or
I/O margin. `10 MHz` is a reasonable single-read validation target; `5` to
`7.5 MHz` is the conservative operating range until board timing is measured.

## Burst-Read Word Boundary

Gapless burst read has an additional delay after every 32-bit word:

1. The master samples bit 0 on a rising edge.
2. The following falling edge is synchronized into the system domain.
3. `STATE_READ_DATA` recognizes the completed word and enters
   `STATE_READ_WAIT`.
4. `STATE_READ_WAIT` asserts `bus_valid`.
5. On the next system clock, immediate `bus_ready` is observed and the new
   word's most-significant bit is loaded onto MISO.

From the external falling edge to valid next-word MISO, the worst asynchronous
phase estimate is approximately four system clocks, or `40 ns`, before adding
pad, PCB, cable, and master setup time. The next word's first bit is sampled
only one low half period after that falling edge:

```text
SCLK = 10 MHz: low half period = 50.0 ns, about 10 ns RTL margin
SCLK = 15 MHz: low half period = 33.3 ns, below the worst-case estimate
```

Consequently:

- `15 MHz` must not be considered safe for current gapless burst reads.
- `10 MHz` is an RTL validation target with limited physical margin.
- `5` to `7.5 MHz` is the recommended range before board-level timing is
  characterized.

An inter-word pause of at least one or two SCLK half periods could raise the
safe burst-read SCLK, but the current CH347 `read_registers` transaction emits a
gapless byte stream and the SPI protocol does not specify such a pause.

## Wire Throughput

A single register transaction carries 32 payload bits in a 56-bit frame:

```text
payload efficiency = 32 / 56 = 57.14%
transactions_per_second = SCLK / 56
```

| SCLK | Single transactions/s | 32-bit payload rate |
| ---: | ---: | ---: |
| 1 MHz | 17,857 | 71.4 kB/s |
| 5 MHz | 89,286 | 357.1 kB/s |
| 7.5 MHz | 133,929 | 535.7 kB/s |
| 10 MHz | 178,571 | 714.3 kB/s |
| 15 MHz | 267,857 | 1.071 MB/s |

These are wire limits and exclude USB call latency and CS gaps. Repeated single
transactions can be much slower in practice because every operation is a
separate CH347/USB request.

The current host buffer allows at most 63 register words per burst:

```text
3 header bytes + 63 * 4 payload bytes = 255 bytes
payload efficiency = 252 / 255 = 98.82%
```

| SCLK | Maximum-burst payload rate |
| ---: | ---: |
| 1 MHz | 0.124 MB/s |
| 5 MHz | 0.618 MB/s |
| 7.5 MHz | 0.926 MB/s |
| 10 MHz | 1.235 MB/s |
| 15 MHz | 1.853 MB/s |

The write table can use the `15 MHz` validation target. The read table is only
a throughput calculation; current gapless burst reads should use the lower
frequency recommendation above.

## Recommended Operating Points

| Transaction | Initial rate | Validation target | Current position |
| --- | ---: | ---: | --- |
| Single register write | 7.5 MHz | 15 MHz | Same input-only limit as command stream |
| Burst register write | 7.5 MHz | 15 MHz | No SCLK gap required with current immediate-ready targets |
| Single register read | 5-7.5 MHz | 10 MHz | MISO bit-update timing limits margin |
| Gapless burst register read | 5 MHz | 7.5 MHz; test 10 MHz | Most restrictive word-boundary refill path |
| Opcode-`0xa5` command stream | 7.5 MHz | 15 MHz | See the command-stream analysis |

These values deliberately keep separate host profiles for reads and writes. If
one application must use a single fixed SCLK for every transaction, use
`5 MHz` conservatively or `7.5 MHz` after successful burst-read qualification.
Do not select `15 MHz` globally merely because command writes pass at that rate.

## Hardware Qualification

Register timing must be tested independently for each transaction class:

1. Verify single writes and readback at `1 MHz` before increasing frequency.
2. Sweep single and 63-word burst writes at `7.5 MHz` and `15 MHz`.
3. Sweep single reads at `5`, `7.5`, and `10 MHz` with patterns including
   `0x00000000`, `0xffffffff`, `0xaaaaaaaa`, `0x55555555`, and walking bits.
4. Sweep burst-read lengths from 1 through 63 words at `5` and `7.5 MHz`, then
   treat `10 MHz` as a measured stress point.
5. Repeat tests with different CS-to-first-clock delays, transaction gaps, and
   cable/header configurations.
6. Measure actual SCLK duty cycle and MISO validity relative to the master's
   rising sampling edge.
7. Check `spi_error`, returned addresses/data, common event flags, and audio
   underrun/drop/deadline status during simultaneous rendering and DDR traffic.

Before declaring a release frequency, add or document the corresponding SPI
input/output timing constraints and CDC treatment in the board integration.
