# SPI Transport Backlog

This document tracks correctness and timing work for the current Smart Artix
SPI bridge and separates near-term hardening from an optional packetized DMA
protocol. Throughput and register timing remain in
[`spi_command_stream_throughput.md`](spi_command_stream_throughput.md) and
[`spi_register_timing.md`](spi_register_timing.md).

The status was refreshed against `spi_register_bridge`, the version-10 command
plane, and `Ch347RegisterTransport` on 2026-07-30.

## Implemented Baseline

- `spi_register_bridge` runs entirely in the 100 MHz MIG UI clock domain.
- SCLK, CS, and MOSI pass through two-register vectors and are edge-detected in
  that domain; SCLK is not an FPGA clock.
- Mode-0-style register opcodes are `0x00`, `0x40`, `0x80`, and `0xc0`.
- Opcode `0xa5` publishes consecutive big-endian command words directly into
  the shared 1024-word FIFO.
- The parser waits for a complete version-10 command before executing it, but
  words already accepted by the FIFO are not grouped by SPI transaction.
- `spi_error` is an output indication. It is cleared at the start of the next
  CS-low transaction and is not a packet ACK or a software-readable history.
- The CH347 host requests 1 MHz by default, sends one complete command per CS,
  and does not currently preflight `CMD_FIFO_STATUS`. Its transport API can
  carry multiple complete commands but rejects malformed framing and more than
  63 total words.
- Current register targets acknowledge immediately. DDR debug uses START plus
  later status polling; MIG latency is never held inside one SPI transaction.

## Open Correctness Defects

### SPI-001: A Command Transaction Can Be Partially Published

Status: open bug.

`STATE_STREAM_DATA` checks `cmd_ready` only at each 32-bit boundary. If the FIFO
becomes unavailable during one CS-low transaction, earlier words remain in the
FIFO while the rejected word is dropped. A parser waiting on an incomplete
command may then consume words from a later transaction as its payload.

The current one-command-per-CS host reduces the affected scope but does not
remove the bug. A near-full FIFO can still accept the header and reject a later
payload word.

Required invariant:

- one CS-delimited `0xa5` transaction becomes wholly visible to the command
  FIFO, or none of it does;
- a rejected transaction cannot change parser state;
- software can observe a sticky accepted/rejected/framing count or status.

### SPI-002: Partial Final Word Is Silently Discarded

Status: open bug.

If CS is deasserted partway through a command word, the bridge resets its bit
counter without recording a framing error. Earlier complete words from the same
transaction remain committed.

Required invariant:

- CS may end an `0xa5` transaction only on a legal word boundary;
- a partial word rejects the complete staged transaction;
- no transaction prefix reaches the parser;
- a sticky framing indication records the failure.

### SPI-003: Register Targets Must Remain Immediate

Status: current design constraint, not a defect in the implemented register
map.

The SPI wire protocol has no ready/wait indication. `STATE_WRITE_WAIT` and
`STATE_READ_WAIT` are safe only because the generic, common-status, and Smart
Artix platform register windows acknowledge immediately. A future target that
holds `bus_ready` low can cause the bridge to ignore gapless SCLK edges.

The DDR debug aperture already follows the correct model: a register write
starts a MIG operation and software polls status in later SPI transactions.
Keep every variable-latency operation split-phase instead of placing a blocking
target behind the direct bridge.

## Near-Term Compatible Hardening

The first correction does not need a new CRC/sequence packet protocol. It can
preserve the existing wire format:

```text
CS low -> 0xa5 -> word0 -> ... -> wordN -> CS high
```

Recommended implementation:

1. receive a bounded complete CS-delimited command transaction into staging
   storage instead of publishing each word immediately;
2. detect partial words and overlength transactions while receiving;
3. after CS rises, validate legal word framing and reserve enough command-FIFO
   capacity for the entire staged transaction;
4. commit every staged word in order, or discard all of them;
5. expose sticky accepted, rejected, framing, and capacity counters through the
   register map;
6. block a new staged transaction only through a documented inter-transaction
   readiness rule, never by dropping words after CS falls.

Open design choices:

- [ ] Select a maximum staged transaction size. The current CH347 limit permits
  63 words, while the largest production command is 17 words.
- [ ] Decide whether the compatible bridge accepts exactly one command per CS
  or permits multiple complete commands in one staged transaction.
- [ ] Define how the receiver proves/reserves FIFO capacity before commit.
- [ ] Decide whether a READY GPIO is needed or whether sparse host traffic plus
  software-readable counters is sufficient.
- [ ] Define parser recovery for legacy partial FIFO contents across reset and
  `STREAM_FLUSH`.

This path fixes SPI-001 and SPI-002 for the current CH347 workflow. It does not
provide CRC, lost-ACK recovery, or exactly-once retry.

## Optional Packetized DMA Transport

A new packet protocol is justified only if the selected MCU must queue multiple
DMA descriptors without per-transaction software supervision, requires CRC on
the physical link, or must retry after a lost response.

Candidate data path:

```text
SPI SCLK domain
  -> fixed-length packet receiver and ping-pong buffers
  -> length, sequence, and CRC validation
  -> asynchronous request FIFO
  -> 100 MHz command/register executor
  -> asynchronous response FIFO
  -> later SPI response transaction
```

Candidate packet contract:

```text
request:  sync | opcode | sequence | address | word_count | payload | CRC
response: sync | sequence | status | word_count | payload | CRC
```

This would require packet credits, ACK/NACK, duplicate suppression, response
storage, bounded retries, and statuses such as `ACCEPTED`, `DONE`,
`BAD_LENGTH`, `FIFO_FULL`, `CRC_ERROR`, and `EXEC_ERROR`. It is an external
protocol change and must not be implemented merely to solve a local FIFO
reservation problem.

## Clock-Domain And Physical Timing

The present oversampling bridge still needs:

- [ ] `ASYNC_REG` attributes and scoped asynchronous input exceptions for the
  SCLK, CS, and MOSI synchronizers;
- [ ] protection against unintended shift-register extraction;
- [ ] an output-IOB or otherwise bounded system-clock-to-MISO path;
- [ ] measurements of SCLK duty cycle, CS setup/hold, MOSI timing, and MISO
  timing for the selected adapter and cable;
- [ ] qualification beginning at the 1 MHz host default, then the actual CH347
  1.875 MHz, 3.75 MHz, and 7.5 MHz steps.

If higher rates or formal SCLK-relative I/O timing are required, move shifting
into the SCLK domain and cross complete staged transactions through explicit
asynchronous FIFOs. That larger CDC change should be combined with, not used as
a substitute for, transaction atomicity.

## Host Work

For the compatible transport:

- [x] preserve complete command boundaries within each CS assertion;
- [x] enforce the 63-word CH347 transfer maximum, 16-word per-command payload
  maximum, and declared payload lengths;
- [ ] optionally read capacity/status before bursts, while recognizing that
  preflight is not the atomicity mechanism;
- [ ] read sticky rejection/framing status after a failed operation or during
  health polling;
- [ ] bound retries and issue `STREAM_FLUSH` or reset only according to the
  documented recovery contract.

For a future packetized transport, additionally implement sequence-based retry,
duplicate suppression, response polling or READY/IRQ, and CRC errors.

## Verification Acceptance

Compatible hardening is complete only when focused tests prove:

- [ ] every possible CS termination within a word rejects the entire staged
  transaction;
- [ ] FIFO capacity loss at every commit boundary produces all-or-nothing
  visibility;
- [ ] sizes zero through the selected maximum are accepted or rejected exactly
  as specified;
- [ ] consecutive accepted/rejected transactions cannot desynchronize the
  command parser;
- [ ] FIFO wrap and simultaneous `CMD_FIFO_DATA` traffic preserve ordering and
  the direct-stream priority rule;
- [ ] reset in receive, validate, and commit states leaves no visible prefix;
- [ ] all sticky counters saturate and clear according to the register contract;
- [ ] sparse register traffic and the maximum intended command workload do not
  cause audio underrun, drop, or hidden transport loss.

A packetized protocol additionally requires CRC corruption, lost response,
duplicate retry, request/response FIFO exhaustion, and exactly-once execution
tests.

## Completion Rule

SPI-001 and SPI-002 are not fixed by lowering SCLK, increasing FIFO depth,
checking `spi_error` after DMA, or reading FIFO capacity before CS falls. The
parser must observe the entire accepted transaction or no part of it.
