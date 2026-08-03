# SPI Transport Backlog

This document tracks correctness and timing work for the current Smart Artix
SPI bridge and separates near-term hardening from an optional packetized DMA
protocol. Throughput and register timing remain in
[`../design/transport/spi_command_stream.md`](../design/transport/spi_command_stream.md)
and
[`../design/transport/spi_register_mailbox.md`](../design/transport/spi_register_mailbox.md).

The status was refreshed against `spi_register_bridge`, the command plane, and
`Ch347RegisterTransport` on 2026-08-03.

## Implemented Baseline

- SPI request decoding and command reception run in the 100 MHz MIG UI clock
  domain. Fetch response shifting runs in the external SCLK domain.
- SCLK, CS, and MOSI pass through attributed two-register vectors and are
  edge-detected for receive traffic. SCLK also clocks the dedicated fetch TX
  registers: the response is synchronized and frozen during the header, then
  MISO changes directly on falling edges.
- Register access uses the single-outstanding `0x5a` request and `0x5b` fetch
  mailbox. The former direct and burst opcodes are rejected.
- Opcode `0xa5` begins an aligned four-byte header containing an 8-bit word
  count and CRC16, followed by 1 through 63 big-endian command words.
- Opcode `0xa6` is the fixed four-byte out-of-band FLUSH transaction. It
  cancels unpublished staging, clears the command FIFO, and resets parser state.
- The bridge stages and validates the complete CS-delimited transaction before
  beginning a held ready/valid commit into the shared 1024-word FIFO.
- `spi_error` is an output indication. It is cleared at the start of the next
  CS-low transaction and is not a packet ACK or a software-readable history.
- The CH347 host requests 1 MHz by default, sends one complete command per CS,
  and does not currently preflight `CMD_FIFO_STATUS`. Its transport API can
  carry multiple complete commands but rejects malformed framing and more than
  63 total words.
- There is no register-based command injection path.
- Register requests hold the internal ready/valid bus until completion. Their
  CRC32-protected response is retained for later fetch, so register latency is
  not coupled to the active SPI request transaction.

## Open Correctness Defects

### SPI-001: A Command Transaction Can Be Partially Published

Status: fixed; sticky transport counters remain open.

The bridge now receives the declared transaction into a 63-word staging RAM.
After validation, `cmd_valid` remains asserted with the current staged word
until `cmd_ready` accepts it. FIFO backpressure therefore delays the commit
instead of dropping an interior word, and another command transaction arriving
while the staged commit is pending is rejected in full.

The receiver also checks that the staged words form one or more complete
self-delimiting commands before any word is published. A malformed final
command can no longer consume words from a later CS transaction.

Required invariant:

- one CS-delimited `0xa5` transaction becomes wholly visible to the command
  FIFO, or none of it does;
- a rejected transaction cannot change parser state;
- software can observe a sticky accepted/rejected/framing count or status.

### SPI-002: Partial Final Word Is Silently Discarded

Status: fixed; sticky transport counters remain open.

CS deassertion in the three-byte header tail or partway through a payload word
now rejects the complete staged transaction and asserts `spi_error`. Declared
and received word counts must match exactly.

Required invariant:

- CS may end an `0xa5` transaction only on a legal word boundary;
- a partial word rejects the complete staged transaction;
- no transaction prefix reaches the parser;
- a sticky framing indication records the failure.

### SPI-003: Register Targets Must Remain Immediate

Status: fixed by the register mailbox.

The complete 12-byte register request is validated before `bus_valid` is
asserted. The bridge then holds the single bus request until `bus_ready` and
stores either `OK` or `BUS_ERROR`. A separate 16-byte fetch returns that result,
or a CRC-protected `BUSY` response while execution is still pending. There is no
gapless register burst and no SPI edge can overrun a stalled register target.

The completed response remains available for repeated fetches and is replaced
only by a later request. The host checks CRC32, echoed operation/address, and
status before treating either a read or write as complete.

## Near-Term Compatible Hardening

The implemented compatible-sized transport uses an aligned header:

```text
CS low -> 0xa5 -> word_count -> CRC16 -> word0 -> ... -> wordN-1 -> CS high
```

Implemented behavior:

1. receive 1 through 63 words into staging storage;
2. detect partial header/payload words, count mismatch, overlength, malformed
   command boundaries, and CRC mismatch;
3. make CRC comparison configurable with `CHECK_COMMAND_CRC` while retaining
   the CRC16 field in every wire header;
4. commit every accepted staged word through held ready/valid, or discard the
   staged transaction;
5. reject a new command transaction in full while a prior commit is pending.

Open design choices:

- [x] Stage at most 63 words, matching the 256-byte CH347 transfer after the
  four-byte header.
- [x] Permit multiple complete commands in one staged transaction.
- [x] Hold each staged commit word until downstream acceptance; temporary FIFO
  capacity loss stalls rather than rejects an already validated transaction.
- [ ] Expose sticky accepted, rejected, framing, CRC, and busy counters through
  the register map. `spi_error` remains only a per-transaction indication.
- [ ] Decide whether a READY GPIO is needed or whether sparse host traffic plus
  software-readable counters is sufficient.
- [x] Define and implement the `0xa6` out-of-band recovery operation that
  cancels bridge publication, clears the FIFO, and resets parser state.

This path fixes SPI-001 and SPI-002 for the current CH347 workflow. CRC detects
corruption when enabled, but the protocol still does not provide an ACK,
lost-ACK recovery, or exactly-once retry.

### Implementation Cost

The first atomic-transaction implementation inferred the 63 x 32 staging store
as registers and expanded CRC over complete words or frames in one cycle. A
fresh Vivado synthesis attributed 2,261 LUTs and 2,573 registers to
`spi_register_bridge`, which was too expensive for this device.

The current implementation uses a conventional synchronous one-write/one-read
RAM template with read-ahead. Vivado maps the staging store to one RAMB18. The
first committed word has one system-clock cycle of internal startup latency;
after that, an asserted `cmd_ready` accepts one word per 100 MHz system clock.
If `cmd_ready` falls, `cmd_valid` and `cmd_data` remain stable.

CRC16 and CRC32 now advance once per received or transmitted byte instead of
forming a full-frame combinational CRC cone. This changes neither polynomial,
initial/final value, covered bytes, wire field, nor the configurable CRC-check
behavior. Fresh synthesis reduced the bridge to 890 LUTs, 585 registers, and
one RAMB18. Post-route attribution was 816 LUTs, 585 registers, and one RAMB18.

The corresponding forced Smart Artix implementation met the 100 MHz system
clock with setup WNS +0.165 ns, setup TNS 0 ns, hold WHS +0.025 ns, and hold THS
0 ns. The worst setup and hold paths were outside the SPI bridge. The complete
design used 24,933 LUTs, 25,911 registers, 46.5 BRAM tiles, and 39 DSPs, with
all 46,033 routable nets fully routed and no route or DRC errors.

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

The present hybrid bridge has completed:

- [x] `ASYNC_REG` attributes and scoped asynchronous input exceptions for the
  SCLK, CS, and MOSI synchronizers;
- [x] protection against unintended shift-register extraction;
- [x] a falling-SCLK MISO output register with an IOB placement request and
  explicit 30 MHz output timing assumptions.

It still needs:

- [x] post-route confirmation that the synchronizer exceptions resolve and the
  MISO register is packed into `OLOGIC_X0Y92`;
- [ ] measurements of SCLK duty cycle, CS setup/hold, MOSI timing, and MISO
  timing for the selected adapter and cable;
- [x] repeated register and DDR qualification at the 30 MHz CH347 step: 300/300
  exact rounds passed with SCLK on `J20`.

If higher rates or formal SCLK-relative I/O timing are required, move shifting
into the SCLK domain and cross complete staged transactions through explicit
asynchronous FIFOs. That larger CDC change should be combined with, not used as
a substitute for, transaction atomicity.

## Host Work

For the compatible transport:

- [x] preserve complete command boundaries within each CS assertion;
- [x] enforce the 63-word CH347 transfer maximum, 16-word per-command payload
  maximum, and declared payload lengths;
- [ ] preflight complete-transaction capacity as an interim mitigation under
  the documented single-producer contract; this prevents FIFO overflow but is
  not the truncation/framing atomicity mechanism;
- [ ] read sticky rejection/framing status after a failed operation or during
  health polling;
- [x] expose the dedicated FLUSH frame in the C++ and Python CH347 transports;
- [ ] bound retries and issue FLUSH or reset only according to the documented
  recovery contract.

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
- [ ] FIFO wrap and multiple commands in one `0xa5` transaction preserve
  ordering;
- [ ] reset in receive, validate, and commit states leaves no visible prefix;
- [x] a valid FLUSH under downstream backpressure cancels the staged commit,
  clears downstream parsing state, and allows the next complete command;
- [ ] all sticky counters saturate and clear according to the register contract;
- [ ] sparse diagnostic register traffic and the maximum intended `0xa5`
  command workload do not cause audio underrun, drop, or hidden transport loss.

A packetized protocol additionally requires CRC corruption, lost response,
duplicate retry, request/response FIFO exhaustion, and exactly-once execution
tests.

## Completion Rule

SPI-001 and SPI-002 are not fixed by lowering SCLK, increasing FIFO depth,
checking `spi_error` after DMA, or reading FIFO capacity before CS falls. The
parser must observe the entire accepted transaction or no part of it.
