# Smart Artix UDP DDR3 Backlog

This document plans a compact UDP service for high-speed DDR3 inspection and
loading through the Smart Artix board's gigabit Ethernet port. It is a backlog,
not a current wire or RTL contract. Freeze the protocol in a stable transport
document before implementing host-visible behavior.

The plan was written against the 2026-08-03 routed `XC7A50T-2FGG484I`
baseline and the existing SD, renderer, register-access, and MIG ownership.

## Scope And Decisions

The first release has these fixed requirements:

- retain the native four-bit SDHC/SDXC loader and its automatic WTSF load;
- use the on-board `RTL8211E-VB-CG` PHY through RGMII;
- use one compile-time static MAC address, static IPv4 address, and UDP port;
- do not implement DHCP, IPv6, TCP, VLAN, IP options, IP fragmentation, jumbo
  frames, or a soft CPU;
- support ARP, Ethernet/IPv4/UDP validation, DDR reads, DDR writes, status, and
  a one-way playback release;
- use standard 1500-byte Ethernet MTU and never emit fragmented IPv4 packets;
- keep the existing generic ordered renderer-memory interface unchanged;
- keep generated/vendor Ethernet logic out of the generic `rtl/` tree;
- do not support live wavetable replacement while audio is running.

ICMP echo is optional bring-up work and is not required for DDR transport.
MDIO is a PHY-management interface, not DHCP; it remains in scope for PHY ID,
link-state, speed, duplex, and RGMII-delay qualification.

## Current Baseline And Budget

The current board has a 50 MHz oscillator, a 100 MHz/128-bit MIG application
interface, 512 MiB x16 DDR3, and an RGMII PHY with a 125 MHz gigabit data clock.
The latest recorded post-route report used:

| Resource | Used | Available | Utilization |
| --- | ---: | ---: | ---: |
| Slice LUTs | 25,905 | 32,600 | 79.46% |
| Slice registers | 26,517 | 65,200 | 40.67% |
| BRAM tiles | 46.5 | 75 | 62.00% |
| DSP48E1 | 39 | 120 | 32.50% |

The same run had setup WNS `+0.148 ns` and hold WHS `+0.040 ns`. Positive but
small existing margin makes post-route closure part of feature design, not a
final cleanup step.

Initial incremental budgets are:

| Resource | Target | Stop-and-review limit |
| --- | ---: | ---: |
| Slice LUTs | at most 3,500 | total design above 92% |
| Slice registers | at most 4,500 | total design above 55% |
| BRAM tiles | at most 8 | total design above 78% |
| DSP48E1 | 0 | any new DSP without measured justification |

The target permits about 90.2% total LUT use. Crossing the review limit is not
accepted merely because synthesis fits; reduce the design or explicitly change
the device/feature scope before continuing.

## Boot And Ownership Model

Version 1 uses a one-way boot lifecycle instead of runtime cache coherence:

```text
RESET
  -> MIG calibration
  -> SD_LOAD (SD loader owns DDR writes; UDP DMA returns NOT_READY)
  -> UDP_MAINTENANCE (audio core held in reset; UDP DDR read/write enabled)
  -> PLAYBACK (UDP DDR read/write permanently disabled until board reset)
```

ARP and status remain available in every state. The existing SD loader remains
the authoritative initial image source. Ethernet does not replace it and does
not run in parallel with SD writes.

`START_PLAYBACK` is a one-way transition for the current reset cycle:

1. stop accepting new DDR commands;
2. finish every accepted write and read response;
3. transmit the successful `START_PLAYBACK` response;
4. reset transport DMA queues and invalidate their ownership state;
5. release `core_rst` so all renderer sample-window state starts invalid;
6. reject later DDR commands with `PLAYBACK_ACTIVE` until board reset.

Repeated `START_PLAYBACK` requests are idempotent and report the current
playback state. A missing acknowledgement can therefore be resolved with
`STATUS`; it must never reopen DDR access.

The existing automatic core release on `asset_loaded` must be replaced by the
explicit boot coordinator when this feature is enabled. Decide before RTL work
whether all Ethernet builds require the release command or whether a synthesis
parameter preserves an auto-play image for unattended use. Do not implement a
timed software race in which the host must set a hold bit before SD loading
finishes.

No phase-1 cache invalidation command is needed. Returning from `PLAYBACK` to
`UDP_MAINTENANCE`, changing active wave memory, or preserving voices across a
DDR rewrite is out of scope.

## Proposed Data Path

```text
RTL8211E RGMII pins
  <-> RGMII IDDR/ODDR and clocking
  <-> Ethernet RX/TX MAC, FCS, padding, and IFG
  <-> ARP / IPv4 / UDP parser and packet builder
  <-> validated RX and response packet buffers
  <-> asynchronous descriptor/data FIFOs
  <-> UDP DDR DMA in the 100 MHz MIG UI domain
  <-> extended Smart Artix MIG arbiter
  <-> existing MIG application interface
```

The RX side must buffer a complete write request before changing DDR. Ethernet
FCS, IPv4 header checksum, UDP length/checksum, application header, bounds, and
application CRC all pass before the first MIG write is issued. A truncated,
overlong, malformed, or bad-CRC datagram changes no DDR byte.

Use BRAM-backed ping-pong buffers. Do not infer 1 KiB packet arrays as registers
and do not build a whole-packet combinational CRC. CRC and Internet checksum
logic advance per byte or per datapath word.

### Clock Domains

- RGMII RX logic is clocked from the PHY-provided receive clock.
- RGMII TX logic uses a qualified 125 MHz transmit clock and phase relationship.
- DMA, boot coordination, SD loading, renderer access, and MIG arbitration stay
  in the 100 MHz MIG UI clock domain.
- Only complete descriptors and buffered data cross clock domains through
  explicit asynchronous FIFOs.
- Reset assertion/deassertion and link-down recovery are specified separately
  in every domain; no multi-bit status bus is sampled without a CDC mechanism.

Do not assume that the PHY strap configuration supplies the required RGMII
internal delay. Confirm the board schematic and RTL8211E mode, then choose one
consistent PHY-delay/FPGA-delay scheme. Constrain and measure both directions.

## Candidate UDP Application Protocol

Freeze this proposal in a stable transport contract before RTL implementation.
All multi-byte header integers use network byte order. DDR data bytes are opaque
and retain their addressed byte order.

Every UDP payload begins with this 32-byte header:

| Offset | Bytes | Field | Proposed meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `magic` | `0x4d424431` (`MBD1`) |
| 4 | 1 | `version` | `1` |
| 5 | 1 | `opcode` | request or response operation |
| 6 | 1 | `status` | zero in requests; response status |
| 7 | 1 | `flags` | zero in version 1 |
| 8 | 4 | `transaction_id` | host-selected request identity |
| 12 | 4 | `byte_address` | absolute DDR byte address |
| 16 | 2 | `data_length` | bytes following the header |
| 18 | 2 | `header_length` | exactly 32 |
| 20 | 4 | `session_id` | nonzero host nonce accepted by `OPEN_SESSION` |
| 24 | 4 | `detail` | opcode/status-specific value |
| 28 | 4 | `crc32` | CRC32 over bytes 0..27 and data |

Candidate opcodes are:

| Opcode | Name | Request data | Successful response data |
| ---: | --- | --- | --- |
| `0x01` | `STATUS` | none | fixed versioned status record |
| `0x02` | `OPEN_SESSION` | none | negotiated session information |
| `0x03` | `DDR_READ` | none | requested DDR bytes |
| `0x04` | `DDR_WRITE` | bytes to write | none |
| `0x05` | `START_PLAYBACK` | none | none |

Responses set opcode bit 7. Define at least `OK`, `BAD_MAGIC`, `BAD_VERSION`,
`BAD_OPCODE`, `BAD_LENGTH`, `BAD_ALIGNMENT`, `BAD_ADDRESS`, `BAD_CRC`,
`NOT_READY`, `SD_LOADING`, `QUEUE_FULL`, `PLAYBACK_ACTIVE`, `LINK_CHANGED`,
`NO_SESSION`, `SESSION_BUSY`, `STALE_SESSION`, and `INTERNAL_ERROR`. Malformed
traffic that cannot provide a trustworthy return tuple may be counted and
dropped instead of answered.

Version 1 transfer rules are deliberately narrow:

- DDR address and length are multiples of the 16-byte MIG beat;
- data length is 16 through 1024 bytes for read/write operations;
- address plus length must not wrap and must fit the implemented 512 MiB DDR;
- one application operation fits in one UDP datagram and one IPv4 packet;
- IPv4 packets with options, fragmentation bits, or a nonzero fragment offset
  are rejected;
- incoming zero UDP checksums are accepted as IPv4 permits; nonzero checksums
  are verified; transmitted packets use a computed UDP checksum unless a
  measured resource result justifies documented zero-checksum transmission;
- application CRC32 remains mandatory regardless of UDP checksum;
- Ethernet padding is excluded from IPv4, UDP, and application lengths.

After reset there is no active session. The host chooses a random nonzero
`session_id` and sends `OPEN_SESSION`; the FPGA binds it to the request source
MAC/IP/UDP port until playback or reset. Repeating the same open is idempotent,
while another nonce or peer receives `SESSION_BUSY`. `STATUS` is allowed with
session zero, but every DDR and playback request must match the active session.
This nonce is stale-packet protection, not authentication. It avoids claiming
that the FPGA can manufacture a persistent or random boot counter by itself.

The aligned restriction avoids read-modify-write state and partial-beat masks
in the first implementation. Add arbitrary byte writes only after aligned
throughput and atomic packet validation pass.

### Retry And Duplicate Rules

UDP does not provide delivery, ordering, congestion control, or duplicate
suppression. The host must use bounded timeout/retry and a configurable window
of outstanding transaction IDs.

The FPGA retains a small recent-write table keyed by session ID, source
MAC/IP/UDP port, transaction ID, address, length, and request CRC. An exact
duplicate returns the recorded completion without writing DDR again. Reuse of a
live transaction ID with different request fields returns an error. Duplicate
reads may be re-executed. `START_PLAYBACK` is intrinsically idempotent.

Start with 16 recent write entries and up to 16 queued requests. Measure whether
32 outstanding host requests are needed to reach the hardware throughput gate.
Do not increase packet RAM or queue depth without utilization evidence.

This interface has no authentication or confidentiality. Treat the Ethernet
segment as trusted. An optional compile-time peer MAC/IP filter may reduce
accidental access but is not a security boundary.

## SD And MIG Arbitration

The present arbiter has renderer reads, register reads/writes, and SD-loader
writes. It holds one read owner while reads are outstanding, so it cannot simply
accept interleaved UDP and renderer reads.

For version 1, lifecycle separation simplifies ownership:

- `SD_LOAD`: grant SD writes; reject UDP DMA; renderer remains reset;
- `UDP_MAINTENANCE`: SD loader is idle; grant UDP reads/writes and retain the
  low-rate register debug aperture;
- `PLAYBACK`: grant renderer and register debug traffic; reject UDP DMA.

Even with separated high-volume clients, extend the arbiter explicitly rather
than muxing UDP into an existing source. Preserve these invariants:

- every accepted MIG read command has exactly one owner entry;
- every MIG read response is routed to that owner in acceptance order;
- MIG command and write-data handshakes may occur independently, but a write
  pair never mixes owners;
- reset/link loss cannot leave an accepted MIG response without a drain owner;
- SD completion and `asset_loaded` behavior are unchanged;
- register debug access cannot corrupt or consume a UDP response;
- transition to playback waits until UDP outstanding counts are zero.

If future work permits concurrent playback reads, add a per-command read-owner
FIFO and measured fairness policy then. It is not part of this release.

## Work Breakdown

### ETH-000: Freeze Board And Wire Contracts

- [ ] Obtain the authoritative board schematic and RTL8211E datasheet/revision.
- [ ] Confirm PHY address, reset timing, strap mode, RGMII voltage, clock delay,
  LED/interrupt wiring, and whether MDIO writes are required.
- [ ] Choose static MAC, static IPv4 address, netmask assumptions, and UDP port.
- [ ] Move the candidate application format into a stable transport contract.
- [ ] Define the status record, counters, session lifetime, timeout behavior, and
  exact CRC/checksum vectors.
- [ ] Decide the unattended auto-play versus explicit-release build policy.

Exit gate: reviewed wire vectors exist for valid requests/responses and every
reject status; no RTL is written against an unresolved RGMII-delay assumption.

### ETH-010: RGMII And PHY Bring-Up

- [ ] Add all Ethernet pins to `smart_artix_top` and the board XDC.
- [ ] Add PHY reset sequencing and a minimal MDIO controller/readout.
- [ ] Implement RGMII RX/TX with 7-series I/O primitives and explicit clocks.
- [ ] Implement link-down reset/recovery without resetting MIG or the SD loader.
- [ ] Prove PHY ID, autonegotiation, 1000BASE-T/full-duplex link, and stable RXC.
- [ ] Add generated clocks, input/output delays, CDC exceptions, and I/O
  placement checks; do not use broad false paths.

Exit gate: repeated cold boots establish a gigabit link; post-route I/O timing
is nonnegative; an ILA or loopback test proves exact RGMII nibbles and clocks.

### ETH-020: Streaming Ethernet MAC

- [ ] Receive preamble/SFD, enforce frame length, check FCS, and discard bad
  frames without exposing partial payload.
- [ ] Transmit preamble/SFD, padding, FCS, and the 96-bit-time inter-frame gap.
- [ ] Filter destination MAC and broadcast traffic before packet buffering.
- [ ] Add exact counters for good, short, long, FCS-failed, overflowed, and
  unsupported frames.
- [ ] Add back-to-back minimum-frame and maximum-frame self-checking tests.

Exit gate: simulation compares complete emitted frames byte-for-byte, including
FCS and padding, and RX never commits a failed frame.

### ETH-030: ARP, IPv4, And UDP

- [ ] Answer ARP requests for the configured static address.
- [ ] Accept only IPv4/IHL-5, validate total length and header checksum, and
  reject fragments/options.
- [ ] Validate UDP destination port, length, and nonzero checksum.
- [ ] Generate correct Ethernet, IPv4, and UDP response headers/checksums.
- [ ] Retain the request source MAC/IP/port with its transaction descriptor.
- [ ] Add malformed-length, checksum, fragmentation, wrong-address, and
  unsupported-protocol tests.

Exit gate: packet vectors captured by an independent host parser match the RTL,
and malformed packets cannot enqueue an application request.

### ETH-040: Application Packet Engine And CDC

- [ ] Infer BRAM-backed RX/TX ping-pong buffers and inspect primitive mapping.
- [ ] Parse the 32-byte header and compute application CRC incrementally.
- [ ] Commit a write descriptor only after the complete datagram is valid.
- [ ] Add asynchronous descriptor/data FIFOs with full/empty backpressure.
- [ ] Implement bounded request queues, recent-write duplicate handling, and
  exact response status.
- [ ] Define link-down behavior for buffered, accepted, and completed requests.

Exit gate: randomized clock ratios, FIFO-full injection, packet truncation at
every byte, reset in every state, and duplicate requests are self-checking.

### ETH-050: DDR DMA And Boot Coordinator

- [ ] Add aligned 128-bit multi-beat UDP reads and writes in the MIG UI domain.
- [ ] Bounds-check the complete operation before its first MIG command.
- [ ] Extend the Smart Artix DDR arbiter with an explicit UDP owner and response
  accounting while preserving SD and register behavior.
- [ ] Implement `RESET -> SD_LOAD -> UDP_MAINTENANCE -> PLAYBACK`.
- [ ] Hold the core in reset through SD load and UDP maintenance.
- [ ] Drain accepted UDP operations and the playback response before releasing
  the core; never permit a reverse transition before board reset.
- [ ] Add platform status/counters through `spec/register_map.json` only after
  defining their exact access, reset, saturation, and clear semantics.

Exit gate: SD still loads the exact image; UDP can read it back and modify it;
the first renderer access after release observes modified DDR and an invalid
sample window; later UDP DDR requests are rejected.

### ETH-060: Host Tool

- [ ] Add a host CLI with `status`, `read`, `write`, `verify`, and
  `start-playback` commands.
- [ ] Open a random nonzero session automatically before the first DDR command
  and expose an explicit session option for protocol diagnostics.
- [ ] Use bounded timeouts, bounded retries, a selectable outstanding window,
  and transaction IDs that are not reused within one session.
- [ ] Split files into aligned operations, preserve byte offsets locally, and
  verify readback by size and CRC.
- [ ] Report FPGA reject status and transport loss separately.
- [ ] Refuse writes outside an explicit user-provided address range.
- [ ] Record throughput, retry count, duplicate count, and session ID.

Exit gate: interrupted transfers resume or fail clearly without silently
accepting a partial file, and exact read-after-write comparison passes.

### ETH-070: Integration, Resources, And Hardware Qualification

- [ ] Run all focused Ethernet, SD, DDR arbiter, and register tests.
- [ ] Run `make check-generated`, `make check-docs`, `make lint`, and
  `make test`.
- [ ] Run a fresh forced post-route implementation after each material clock,
  buffer, queue-depth, or arbiter change.
- [ ] Inspect MAC/DMA hierarchy utilization, BRAM inference, clocking, CDC,
  unconstrained paths, route status, DRC, and methodology warnings.
- [ ] Repeat SD cold-boot and exact DDR-image verification with Ethernet logic
  present but idle.
- [ ] Measure Ethernet write, read, retry, and packet-loss behavior over a
  direct gigabit link and a normal switched LAN.
- [ ] Measure RGMII timing/electrical margin on hardware; routed internal timing
  alone is not external-interface signoff.

Exit gate: all acceptance criteria below pass on a fresh bitstream.

## Verification Matrix

| Boundary | Required cases |
| --- | --- |
| Reset/boot | cold reset, MIG calibration delay, missing SD, SD error, successful SD load, Ethernet link absent/present |
| RGMII RX | min/max frames, back-to-back frames, bad preamble, runt, oversize, bad FCS, RX FIFO full |
| RGMII TX | padding, FCS, IFG, backpressure, reset/link loss between packets |
| ARP/IP/UDP | wrong MAC/IP/port, ARP broadcast, bad lengths/checksums, IPv4 options/fragments, zero/nonzero UDP checksum |
| Application | session open/collision/reset, every opcode/status, 16/1024-byte limits, alignment, address end/wrap, CRC failure, stale session |
| Reliability | dropped request, dropped response, duplicate write, duplicate read, transaction-ID collision, queue full |
| DDR | MIG command/data independent stalls, read latency, response stall, write atomic validation, exact byte order |
| SD coexistence | UDP rejection while loading, unchanged SD retry/error behavior, exact loaded byte count and image |
| Playback release | DMA drain, response-before-release, initial cache invalidity, idempotent retry, permanent post-release rejection |

Use a simulation-only Ethernet peer/PHY model under `sim/models` or the board
simulation tree. It must never enter synthesis filelists. Expected packets and
memory contents are calculated independently rather than copied from RTL state.

## Performance Acceptance

The first implementation is accepted only if all of these are measured:

- no DDR mismatch during at least 1 GiB of aggregate write/read/verify traffic
  within an explicitly bounded DDR test region;
- at least 80 MB/s application payload for aligned 1024-byte writes over a
  direct gigabit link, excluding host file I/O;
- at least 80 MB/s application payload for aligned 1024-byte reads with a tuned
  but bounded outstanding window;
- zero unreported FPGA RX overflow, CRC failure, queue drop, or DMA error;
- every missing UDP response is visible as a bounded host retry or terminal
  failure, never silent success;
- SD loading produces the same byte count, image hash, and error behavior as
  the pre-Ethernet baseline;
- playback release introduces no renderer memory-response mismatch, deadline
  error, or stale sample-window data;
- final setup and hold WNS are nonnegative, TNS/THS are zero, every routable net
  is routed, and DRC has no errors or critical warnings;
- resource use stays within the agreed target or has a recorded design review
  before proceeding.

The 80 MB/s target is a system acceptance point, not an Ethernet line-rate
claim. Record packet size, host OS/NIC, socket buffer sizes, outstanding window,
switch/direct topology, retries, and FPGA counters with every result.

## Explicitly Deferred Work

- DHCP, IPv6, TCP, VLAN, jumbo frames, multicast, and IP reassembly;
- a general-purpose network stack or embedded CPU;
- concurrent high-rate UDP DMA and audio rendering;
- live wave-memory writes, renderer cache invalidation, or voice preservation;
- arbitrary unaligned/partial-beat DDR writes;
- remotely entering maintenance mode after playback starts;
- authentication, encryption, secure boot, and hostile-network exposure;
- multiple simultaneous host sessions or routed-network congestion control.
