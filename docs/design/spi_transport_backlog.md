# SPI Transport Backlog

This document tracks correctness defects and follow-up work for SPI masters
driven by fixed-length MCU DMA. It covers both opcode-`0xa5` command traffic and
register transactions. Throughput estimates remain in
[`spi_command_stream_throughput.md`](spi_command_stream_throughput.md) and
[`spi_register_timing.md`](spi_register_timing.md).

The tasks in this document are not implemented by the current RTL. Frequency
qualification must not be treated as a substitute for completing the
correctness work below.

## P0 Correctness Defects

### SPI-001: Command Transaction Can Be Partially Accepted

Status: open bug.

`STATE_STREAM_DATA` checks `cmd_ready` only when each complete 32-bit word
arrives. If the command FIFO becomes unavailable during one CS-low transaction,
earlier words have already been committed while the current and later words are
discarded. `spi_error` is set, but the parser can be left holding an incomplete
command or a transaction prefix.

This violates transaction atomicity. A DMA master cannot react to `cmd_ready`
or `spi_error` until its fixed-length transfer has completed, so per-word
accept/reject is not valid transport-level flow control.

Required behavior:

- accept every word in the declared SPI packet, or accept none of them;
- never expose a packet prefix to the command parser;
- report one packet-level ACK or NACK after the complete DMA transfer;
- allow a NACKed packet to be retried safely by sequence number;
- count and expose rejected packets without relying only on an LED-level
  `spi_error` signal.

### SPI-002: Partial Final Word Is Silently Discarded

Status: open bug.

If CS is deasserted after only part of a 32-bit command word, the bridge resets
its bit counter and silently discards those bits. No half word is pushed into
the FIFO, but the malformed transaction is not reported, and any earlier words
from the same transaction remain committed.

Required behavior:

- detect CS deassertion when the packet is not on a legal word boundary;
- reject the complete packet rather than retaining its prefix;
- set a sticky framing-error counter/status field;
- verify that the parser state is unchanged after the rejected packet.

### SPI-003: Register Ready/Busy Is Not Representable To DMA

Status: open architectural bug for any non-immediate register target.

The internal register bus exposes `ready`, but SPI has no current wire-level
mechanism to pause or reject an in-progress DMA transaction. `STATE_WRITE_WAIT`
and `STATE_READ_WAIT` work only because all current register targets respond
immediately. A future target that holds `bus_ready` low can cause incoming SCLK
edges to be ignored and corrupt a gapless transaction.

Required behavior:

- prohibit non-immediate targets behind the current direct bridge until a
  queued transport exists;
- use posted writes and split-phase reads for variable-latency targets;
- distinguish request `ACCEPTED` from operation `COMPLETED`;
- represent long operations as `START`, followed by `BUSY`, `DONE`, or `ERROR`
  status rather than holding an SPI transaction open.

## Target DMA Transport

An MCU DMA descriptor cannot branch on an in-transaction BUSY indication. The
FPGA must therefore be able to sink one complete packet at line rate, and flow
control may affect only a later DMA descriptor.

The target data path is:

```text
SPI SCLK domain
  -> fixed-length packet receiver
  -> ping-pong staging buffers
  -> length, sequence, and CRC validation
  -> atomic packet accept or reject
  -> asynchronous request FIFO
  -> 100 MHz command/register executor
  -> asynchronous response FIFO
  -> later SPI response DMA
```

The target packet contract is:

```text
request:  sync | opcode | sequence | address | word_count | payload | CRC
response: sync | sequence | status | word_count | payload | CRC
```

Required response states include `ACCEPTED`, `BUSY`, `DONE`, `BAD_ADDRESS`,
`BAD_LENGTH`, `FIFO_FULL`, `CRC_ERROR`, and `EXEC_ERROR`.

## Implementation Tasks

### Packet Ingress

- [ ] Select a fixed maximum DMA packet size, initially 32 or 64 words.
- [ ] Add two packet staging buffers so one packet can be validated/committed
  while the other receives the next DMA transfer.
- [ ] Receive and count the complete packet in the SPI SCLK domain.
- [ ] Add declared word count, transaction sequence, and CRC32.
- [ ] Commit a validated packet atomically into the request/command FIFO.
- [ ] Reject the complete packet on bad length, partial word, CRC failure, or
  insufficient reserved capacity.
- [ ] Add sticky accepted/rejected/framing/CRC/overflow counters.

### Flow Control Between DMA Descriptors

- [ ] Define packet credits, where one credit reserves space for one maximum
  packet rather than advertising only instantaneous word FIFO level.
- [ ] Decide whether the board exposes a `READY`/`IRQ` GPIO. If present, READY
  may authorize the next DMA only and must not be withdrawn after DMA starts.
- [ ] Without a GPIO, provide a status transaction that returns packet credits
  and response-FIFO availability.
- [ ] Make the host cap every DMA transfer to the granted packet credit.
- [ ] Add sequence-based retry and duplicate suppression so a lost ACK does not
  apply one command packet twice.

### Register Requests And Responses

- [ ] Keep bounded-latency cached status registers available for immediate
  bring-up reads.
- [ ] Convert variable-latency register writes to posted requests.
- [ ] Add a response FIFO for split-phase register reads.
- [ ] Return read data in a later DMA transaction with matching sequence.
- [ ] Add coherent snapshot commands for multiword status blocks.
- [ ] Preserve the existing DDR debug model of START plus status polling; do not
  turn MIG latency into an SPI wait state.

### Clock-Domain And Board Timing

- [ ] Move high-speed SPI shifting into the SCLK domain instead of relying only
  on `100 MHz` oversampling.
- [ ] Cross complete requests/responses through explicit asynchronous FIFOs.
- [ ] Mark and constrain synchronizers and asynchronous FIFO paths.
- [ ] Add board SPI input/output delays after MCU timing and physical routing
  are known.
- [ ] Measure CS setup/hold, SCLK duty cycle, MOSI timing, and MISO timing on the
  selected MCU and connection.

### Host And MCU Software

- [ ] Build one DMA descriptor per complete packet; never split a packet across
  independent CS assertions.
- [ ] Process ACK/NACK only after DMA completion.
- [ ] Retry NACKed packets with the same sequence and payload.
- [ ] Keep writes queued until `ACCEPTED`; wait for `DONE` only when operation
  completion is semantically required.
- [ ] Issue reads as request DMA followed by READY/IRQ or status polling and a
  separate response DMA.
- [ ] Bound retry count and surface permanent protocol/CRC/overflow errors.

## Verification Acceptance Criteria

- [ ] Exhaust every possible CS position within a 32-bit word and prove that no
  packet prefix reaches the parser.
- [ ] Force command FIFO capacity to disappear at every word boundary and prove
  all-or-nothing packet visibility.
- [ ] Test packet sizes from zero through the selected maximum and reject
  declared/actual length mismatches.
- [ ] Corrupt every header field, payload bit class, and CRC byte.
- [ ] Lose an ACK, retry the same sequence, and prove exactly-once command
  application.
- [ ] Fill request and response FIFOs while DMA continues at the qualified SCLK;
  prove bounded NACK behavior without word loss or parser desynchronization.
- [ ] Stall a register target for arbitrary cycles and prove that later SPI
  packets remain framed correctly.
- [ ] Run sustained command and register traffic during maximum intended
  polyphony, DDR misses, and audio FIFO pressure without underrun or hidden
  transport loss.
- [ ] Add focused self-checking RTL tests before changing the documented SPI
  transport contract.

## Completion Rule

SPI-001 and SPI-002 are complete only when the parser can observe either the
entire validated DMA packet or no part of it. Merely setting `spi_error`, asking
firmware to inspect BUSY during DMA, increasing FIFO depth, or lowering SCLK
does not fix either bug.
