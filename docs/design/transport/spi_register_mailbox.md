# SPI Register Mailbox Timing And Throughput

This document covers the split-phase single-register protocol implemented by
`spi_register_bridge`. Opcode `0xa5` command traffic and opcode `0xa6` FLUSH are documented separately
in [`spi_command_stream.md`](spi_command_stream.md).

The request receiver oversamples synchronized SPI mode-0 pins in the 100 MHz
system-clock domain. Fetch responses are frozen during their 32-bit header and
shifted directly from the external SCLK falling edge, removing system-clock
edge-detection latency from the MISO setup path. With SCLK on the clock-capable
BANK15 header pin 14 / `J20`, hardware has completed 300/300 exact register and
DDR rounds at an actual 30 MHz CH347 clock.

## Wire Protocol

The removed direct register opcodes `0x00`, `0x40`, `0x80`, and `0xc0` are
invalid. Register access uses one request CS followed by one or more fetch CS
transactions. All multi-byte fields are most-significant byte first.

Every request is 12 bytes:

```text
byte 0       0x5a
byte 1       operation: 0x00 read, 0x01 write
bytes 2..3   16-bit byte address
bytes 4..7   32-bit write data; ignored for reads
bytes 8..11  CRC32 of bytes 0..7
```

The complete request is checked only when CS rises. A truncated request, extra
clocks, unsupported operation, CRC mismatch, or request while the register bus
is busy cannot start a new bus access. `CHECK_REGISTER_CRC` may disable request
CRC comparison without changing the wire layout.

Every fetch is 16 bytes. MOSI sends four header bytes followed by twelve zero
bytes:

```text
MOSI bytes 0..3   0x5b, 0x00, 0x00, 0x00
MOSI bytes 4..15  zero padding used to clock the response
```

MISO is undefined during the fetch header. Its following twelve bytes are:

```text
byte 0       status
byte 1       echoed operation
bytes 2..3   echoed address
bytes 4..7   read data, or zero for write/error responses
bytes 8..11  CRC32 of response bytes 0..7
```

Status values are `0x00 OK`, `0x01 BUS_ERROR`, `0x02 BUSY`, and `0x03 EMPTY`.
CRC32 is CRC-32/ISO-HDLC: reflected polynomial `0xedb88320`, initial value
`0xffffffff`, and final XOR `0xffffffff`.

## Execution And Retry

An accepted request asserts the internal register bus `valid` and holds its
operation, address, and write data until `ready`. SPI traffic therefore cannot
overrun a variable-latency register target. A fetch made before completion
returns a valid CRC-protected `BUSY` response.

The completed `OK` or `BUS_ERROR` response remains stored and may be fetched
again. This lets software retry a fetch whose returned CRC was corrupt without
executing a write twice. A new structurally complete request made while idle
clears the prior response; a rejected CRC then yields `EMPTY` rather than a
stale matching response.

The Python `Ch347Transport` permits at most 1000 fetch attempts for one API call,
including `BUSY` responses and response-CRC retries. It verifies response CRC,
operation, address, and status before returning. Register writes are
acknowledged operations rather than posted SPI writes.

There is one outstanding register request and no register burst. Python issues
one complete mailbox operation for each address; multiple reads are likewise
issued individually. DDR debug
remains unchanged at the register-map level: software fills its buffer
registers, writes `DDR_ACCESS_CONTROL`, polls status, and later reads the
buffered data registers.

## Wire Cost

A completed register operation normally uses a 12-byte request and a 16-byte
fetch, or 224 SPI bits across two CS assertions. At selected SCLK `F` the ideal
wire-only upper bound is `F / 224` operations per second, excluding USB call
latency and CS gaps.

| Actual SCLK | Wire-only operations/s |
| ---: | ---: |
| 937.5 kHz | 4,185 |
| 1.875 MHz | 8,371 |
| 3.75 MHz | 16,741 |
| 7.5 MHz | 33,482 |
| 15 MHz | 66,964 |
| 30 MHz | 133,929 |

This overhead is intentional: register traffic is sparse, while integrity,
explicit completion, retained responses, and arbitrary `bus_ready` latency are
part of the contract.

## Physical Timing

Mailbox execution removes register response latency from the active request
transaction. MISO timing is required only during fetch, when the complete
response is already available or the bridge returns `BUSY`. The response
crosses through a two-stage SCLK-domain snapshot, its CRC is calculated
byte-serially during the header, and each output bit is launched on SCLK's
falling edge for the next rising-edge sample. Remaining board-I/O work is:

- retain the scoped synchronizer exceptions and verified MISO OLOGIC placement;
- measure SCLK duty cycle, CS setup/hold, MOSI timing, and MISO timing;
- repeat 30 MHz qualification if adapter, cable, pin assignment, voltage, or
  image changes.

The 60 MHz CH347 step is outside the remaining 100 MHz dual-edge oversampling
receiver's supported range: its 8.33 ns half-period is shorter than one system
clock. No analytical number in this document is a released board rating.
