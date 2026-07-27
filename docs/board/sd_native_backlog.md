# Native SD Protocol Backlog

This document tracks protocol-correctness and compatibility work for the custom
3.3 V, 4-bit native SDHC/SDXC asset-loading path. Electrical timing and XDC
closure remain tracked separately in
[`smart_artix_io_constraints_backlog.md`](smart_artix_io_constraints_backlog.md).

The review basis is `docs/sdcard_spec_v9.10.pdf`, SD Specifications Part 1
Physical Layer Simplified Specification Version 9.10, dated 2023-12-01. The
current focused SD regressions cover the principal success, fallback, timeout,
framing, CRC, busy, and multi-block recovery paths listed below. They are not
exhaustive protocol or physical-card qualification for arbitrary conforming
SDHC/SDXC cards.

[`asset_loading.md`](asset_loading.md) is the current implementation contract.
This file retains the original audit evidence, records how each issue was
resolved, and tracks the qualification work that remains.

## Current Scope

The intended path supports:

- 3.3 V native SD memory-card mode over `CMD` and `DAT[3:0]`;
- SDHC and SDXC block addressing with 512-byte logical blocks;
- Default Speed initialization followed by an optional High Speed switch;
- raw `WTSF` image reads through `CMD17` or bounded multi-block reads.

SDSC byte addressing, SDUC address extension, SPI mode, SDIO, 1.8 V signaling,
UHS-I modes, UHS-II, SD Express, filesystems, writes, erase, security, and boot
functions remain out of scope. A fix must not silently broaden those claims.

## Priority Index

Issue IDs follow audit discovery order and remain stable even when later review
moves them into a different priority group.

| Priority | Issues | Focus |
| --- | --- | --- |
| P0 protocol | SD-001 through SD-005 | Initialization, command policy, multi-block reads, and recovery |
| P0 pin PHY | SD-007 through SD-010, SD-012, SD-013, SD-015, SD-016 | Wire framing, state coordination, clocking, and wait loops |
| P1 integration | SD-006, SD-011, SD-014 | Time budgets, insertion/power assumptions, and DAT3 pull-up control |
| P2 resilience | SD-017 | Bounded retry after correctness defects are closed |

## Implementation Update

The current RTL resolves the coupled defects with a revised reader/PHY contract:

- `sd_native_pkg` defines semantic R1, R1b, R2, R3, R6, and R7 response types
  plus distinct timeout, CRC, framing, wrong-index, busy-timeout, cancel, and
  abort transport status values.
- The PHY atomically latches the complete command descriptor and divider. It
  searches for response and data start tokens through complete clock cycles,
  validates response-class framing and CRC, requires all four DAT start bits,
  waits for R1b DAT0 release, and requires the reader to approve or cancel a
  data phase after seeing the response.
- The default data-start timeout is 10,000,000 clocks of the 100 MHz system
  domain, or 100 ms independent of whether SD_CLK is 400 kHz, 25 MHz, or 50 MHz.
  Focused simulations override the system-clock count without changing the
  hardware default.
- The next command bit is installed when SD_CLK falls. Divider zero therefore
  retains one 100 MHz system-clock period of logical setup before the following
  SD_CLK rising edge. The divider is transaction-latched, and a new divider is
  used only by a later command after the old-rate post-transaction clocks.
- The reader validates R1/R6 errors, APP_CMD, and expected card state. CMD7 uses
  R1b; ACMD42 precedes ACMD6; CMD6 mode 0 discovers High Speed support/busy and
  mode 1 must report Function Group 1 selection `1` before 50 MHz is enabled.
  Unsupported, busy, or unchanged Default Speed results initialize successfully
  at 25 MHz. A CMD6 status-data CRC error reports power-cycle-required.
- Initialization reads SCR with CMD55/ACMD51 and enables optional CMD23 only when
  SCR CMD_SUPPORT advertises it. Multi-block requests use CMD18; cards without
  CMD23 support use CMD18 followed by CMD12, while a rejected advertised CMD23
  also falls back to that path. Single-block requests and recovery use CMD17.
- Each physical block is buffered until all 512 bytes and the CRC/end status are
  clean. A middle-CMD18 failure aborts the PHY transaction, issues CMD12 with
  R1b handling, and retries the failed LBA through bounded CMD17 reads without
  duplicating already committed bytes. The cumulative retry count is saturating
  and visible in `PLATFORM_ERRORS[27:20]`. If CMD12 itself fails, the primary SD
  error preserves the original data failure and `PLATFORM_ERRORS[31:28]`
  separately reports the recovery failure.
- Smart Artix `SD_CD` is U17, active low, with the schematic's 10 kOhm pull-up.
  The board layer applies two-stage synchronization, 5 ms debounce, and a 1 ms
  stable-power wait. Removal resets the SD/asset session; reinsertion repeats the
  startup clocks and cannot inherit the previous card's speed or asset-valid
  state.

The issue descriptions below retain the original audit evidence and required
tests. A status of implemented means the RTL path exists and focused regressions
cover its principal behavior; it does not imply external I/O timing or physical
card qualification.

## P0 Protocol Defects

### SD-001: Read Timeout Is Too Short At The Transfer Clock

Status: implemented; hardware qualification remains open.

`sd_native_pin_phy` defaults `DATA_TIMEOUT_CYCLES` to 65,535 and counts SD clock
sampling edges. At the Smart Artix 50 MHz transfer clock this is approximately
1.31 ms. Version 9.10 Section 4.6.2.1 says an SDHC or SDXC host should use a
minimum 100 ms timeout for both single and multiple read operations. A
conforming card can therefore be rejected long before its allowed data-start
latency expires. The current 16-bit `timeout_count` cannot represent the
required 5,000,000-cycle 50 MHz budget, and the wait-loop defect in SD-016 must
be fixed before a larger timeout can work at all.

Required behavior:

- express the read timeout as an elapsed-time budget independent of the selected
  SD divider, or derive the required cycle count from the actual SD clock;
- provide at least 100 ms from command completion to the first data start bit and
  between blocks of a multiple read;
- size counters explicitly for the 50 MHz worst case, which needs at least
  5,000,000 SD clock cycles;
- retain a much smaller parameter override for focused simulations without
  weakening the hardware default.

Required tests:

- accept a data start just before the 100 ms deadline at both 400 kHz and 50 MHz;
- reject a data start after the configured deadline;
- repeat the boundary check between two blocks of a multiple read.

### SD-002: High Speed Is Declared Without Validating CMD6 Status

Status: implemented.

`sd_native_block_reader` consumes the 64-byte CMD6 Switch Function Status block
but checks only its length and transport status. It then asserts
`transfer_clock_ready`, causing `smart_artix_ddr3_subsystem` to select 50 MHz.
Version 9.10 Sections 4.3.10.4 and 4.3.11 require the host to use the returned
support and selection fields. Default Speed is limited to 25 MHz; 50 MHz is valid
only after High Speed function 1 is actually selected in Function Group 1.

Required behavior:

- capture and decode the Function Group 1 support bits `[415:400]` and selection
  field `[379:376]` from the 512-bit status block;
- do not select 50 MHz unless High Speed is supported and the mode-1 result is
  function `1`;
- reject a function-selection error (`0xf`) and define whether unsupported or
  busy High Speed falls back to 25 MHz or fails initialization;
- treat a CRC error in the CMD6 status block as requiring a card power cycle,
  rather than attempting recovery with CMD0 alone, as required by Section
  4.3.10;
- either perform the recommended mode-0 capability/current query before mode 1,
  or document and enforce a conservative power assumption;
- separate "card initialized" from "50 MHz High Speed active" so a Default
  Speed fallback cannot accidentally select the 50 MHz divider.

Required tests:

- successful High Speed selection;
- unsupported High Speed with a 25 MHz fallback;
- mode-1 selection result remaining at Default Speed;
- function-selection error and malformed/short status data.

### SD-003: Card Status And R1b Busy Are Not Enforced

Status: implemented.

The pin PHY reports framing, timeout, and CRC transport status, while the block
reader generally treats any transport-valid R1 or R6 as command success. It does
not reject card-status errors such as `ILLEGAL_COMMAND`, `COM_CRC_ERROR`,
`ADDRESS_ERROR`, or `BLOCK_LEN_ERROR`; it also does not validate expected card
state or the `APP_CMD` indication around application commands. Version 9.10
Sections 4.9, 4.9.5, 4.10, and 4.3.9.1 define these response-level obligations.

CMD7 returns R1b, but the current response type has no R1b representation and
the PHY never waits for the optional DAT0 busy interval. Version 9.10 Section
4.9.2 requires the host to check busy before continuing.

Required behavior:

- define command-specific R1/R6 error masks and expected `CURRENT_STATE` values;
- check CMD55 `APP_CMD` before issuing ACMD6 and account for the special ACMD41
  idle-state response rules;
- expose an R1b response type and wait until DAT0 is released or a justified busy
  timeout expires;
- use R1b handling for CMD7 before issuing the following CMD55;
- return distinct diagnostics for transport failure, card-status rejection, bad
  state, and busy timeout.

Required tests:

- inject each relevant R1/R6 error bit and prove initialization/read does not
  continue;
- clear `APP_CMD` after CMD55 and prove the ACMD is not issued;
- hold DAT0 busy after CMD7 for a legal interval and then release it;
- verify CMD7 busy timeout and recovery.

### SD-004: Multi-Block Loading Assumes Optional CMD23 Support

Status: implemented with SCR discovery, CMD18, and bounded error recovery.

The original implementation sent `CMD23` followed by `CMD18` for every request
larger than one block. That made an optional SDHC/SDXC command a compatibility
requirement.

The current reader decodes SCR CMD_SUPPORT during initialization. Multi-block
requests use `CMD18`; `CMD23` is prefixed only when SCR advertises support. Cards
without CMD23 support use an open-ended `CMD18` followed by `CMD12`. If a card
advertises CMD23 but rejects it in R1, the reader clears the discovered capability
and continues through the no-CMD23 CMD18 path. Recovery after a failed CMD18
block stops the multiple read and uses bounded `CMD17` reads from the failed LBA.
`CMD17` is not the normal fallback for a card without CMD23 support.

Implemented behavior:

- read and decode SCR before enabling the CMD23 path;
- use `CMD18` without CMD23 for cards that do not advertise CMD23;
- fall back when an advertised CMD23 is rejected;
- keep the output byte stream and final `last` semantics identical across the
  optimized and recovery paths.

Focused tests:

- a card that accepts CMD23 completes multi-block asset-loader bursts;
- a card whose SCR lacks CMD23 support completes a request through CMD18/CMD12;
- CMD23 rejection in R1 falls back without waiting for nonexistent data.

### SD-005: A Mid-Burst Data Error Can Deadlock Recovery

Status: implemented with coordinated abort, CMD12, and failed-LBA recovery.

The original `CMD18` path could leave the pin PHY owning remaining blocks after
the reader stopped accepting data, preventing reset recovery from reaching a
command-ready PHY.

The current reader accepts a CRC-checked physical block boundary from the PHY and
can backpressure between CMD18 blocks while emitting the previous block. On a
middle-block failure it requests a PHY abort, waits for transport completion,
issues CMD12 with R1b handling, and restarts at the failed LBA with CMD17. Clean
blocks already emitted are not repeated. The final block of an open-ended CMD18
is not committed until normal CMD12 completion succeeds.

Version 9.10 Section 4.15 requires CMD12 recovery when an error is detected in a
CMD18 operation. The general read rules in Section 4.3.3 also permit CMD12 to
abort a data read.

Implemented behavior:

- add a coordinated abort path between the reader and pin PHY;
- issue CMD12 with R1b handling when a CMD18 transfer fails before its declared
  final block, or safely drain the complete predeclared transfer before exposing
  the error;
- guarantee that every error path eventually returns the PHY to command-ready or
  reaches an explicit terminal state recoverable by reset;
- preserve the first failure cause while separately reporting abort failure.

Focused and remaining tests:

- middle-block CRC failure and successful CMD12 recovery are covered;
- first-block CRC failure, inter-block timeout, CMD12 busy timeout, and repeated
  reinitialization remain part of the exhaustive fault matrix.

## P0 Pin PHY Defects

### SD-007: Response Framing Validation Is Incomplete

Status: implemented; exhaustive response-class fault vectors remain open.

For 48-bit responses, `response_crc_ok` verifies start/transmission bits, the end
bit, and CRC7, but does not verify that R1/R6/R7 command index `[45:40]` matches
the issued command. A validly encoded delayed or unrelated response can therefore
be accepted. The ACMD41 special case skips CRC as required for R3, but also fails
to require the R3 reserved index and CRC fields to be all ones.

For a 136-bit R2 response, the PHY currently assigns `STATUS_OK`
unconditionally. It does not check the start bit, card transmission bit, six
reserved one bits, end bit, or the CID/CSD internal CRC7. Version 9.10 Sections
4.5 and 4.9 require CRC7 on every response except R3 and define the complete R1,
R2, R3, R6, and R7 framing fields.

Required behavior:

- represent enough semantic response type information to distinguish R1/R1b,
  R2, R3, R6, and R7 validation rules;
- require the echoed command index for R1, R1b, R6, and R7;
- require the R3 reserved command-index and CRC fields to be all ones while
  continuing to exclude them from CRC checking;
- validate all fixed R2 framing fields and its CID/CSD internal CRC7 before
  reporting the response;
- report framing, wrong-index, and CRC errors distinctly enough for focused
  diagnosis.

Required tests:

- wrong command index with an otherwise valid short-response CRC;
- malformed start, transmission, and end bits for every used response class;
- malformed R3 reserved fields;
- valid and corrupted R2 CID responses, including a corrupted internal CRC7.

### SD-008: Four-Bit Data Start Token Checks Only DAT0

Status: implemented.

In `STATE_DATA_WAIT`, the PHY starts a block whenever `sd_dat_i[0]` is low. In
4-bit mode, Version 9.10 Sections 3.6.1 and 4.3.3 define one low start bit on
each active DAT line. A token such as `4'b1110` is malformed, but the current PHY
accepts it and begins accumulating payload/CRC on the next cycle.

Required behavior:

- require `DAT[3:0] == 4'b0000` for the data start token in the current fixed
  4-bit receive mode;
- distinguish malformed start/end framing from CRC mismatch and timeout;
- keep the start token excluded from each DAT-line CRC16 calculation.

Required tests:

- all four legal low start bits;
- each single-line and representative multi-line malformed start token;
- malformed end tokens independently from valid and invalid CRC16 values.

### SD-009: CMD6 Guard Clocks Switch Frequency Too Early

Status: implemented.

Version 9.10 Section 4.3.10 requires the host to wait at least eight clocks after
the CMD6 status-data end bit before using a newly selected bus behavior or
frequency. The PHY does generate eight post-transaction clocks, but the reader
asserts `transfer_clock_ready` when the final status byte is accepted. The Smart
Artix subsystem then changes `clk_div` combinationally before the PHY emits those
eight clocks. The guard interval is consequently generated at 50 MHz instead of
the pre-switch initialization frequency.

Required behavior:

- keep the old clock divider through the complete eight-clock CMD6 guard
  interval;
- report a distinct transaction-complete or frequency-switch-safe event only
  after those clocks finish;
- change the board-selected divider only while the PHY is idle and at a defined
  low SD_CLK phase;
- preserve the generic Section 4.4 rule of eight clocks after command response
  or final read-data end bit.

Required tests:

- check the period of every CMD6 status and post-transaction clock;
- prove the first faster clock edge occurs only after eight complete old-rate
  clocks;
- change the requested divider near transaction completion and prove no runt or
  stretched edge is emitted.

### SD-010: Divider-Zero Command Launch Has No Logical Setup Margin

Status: RTL phase defect fixed; XDC and physical closure remain owned by
[`smart_artix_io_constraints_backlog.md`](smart_artix_io_constraints_backlog.md).

At `clk_div == 0`, `STATE_CMD_LOW` changes `sd_cmd_o` and raises `sd_clk` on the
same 100 MHz system edge. Except for the preloaded first start bit, command bits
therefore have approximately zero logical setup at the card. The public Version
9.10 simplified specification omits the numeric Default/High Speed timing
tables, so final numbers also require the selected card data sheet, but a
same-edge launch cannot meet a positive setup requirement.

Required behavior and tests are the P0 Native SD Timing items in the I/O backlog.
Until those gates close, use a divider that provides a full system-clock setup
phase and do not claim a timing-qualified 50 MHz pin interface.

### SD-012: Accepted Command Control Fields Are Not Latched

Status: implemented.

The PHY latches the generated 48-bit command frame, block length, and block
count when `cmd_valid && cmd_ready` is accepted. It does not latch `cmd_index`,
`cmd_resp_type`, or `cmd_data_read`. Response length selection, R3 CRC bypass,
response payload extraction, and the transition into the data phase continue to
read those live input ports for the rest of the transaction.

The current `sd_native_block_reader` happens to retain its pending command
registers until completion, but this is an undocumented dependency and violates
the normal ready/valid rule that a producer may change its payload after an
accepted transfer. It also makes a later producer or refactor capable of
changing a 48-bit response into a 136-bit response, applying the wrong CRC rule,
or skipping/adding a data phase in the middle of a wire transaction.

Required behavior:

- latch every command descriptor field atomically on command acceptance;
- use only the latched descriptor until all response, data, and post-clock work
  completes;
- define whether `clk_div` is also transaction-latched or controlled through a
  separate idle-only update handshake, consistent with SD-009;
- document the command descriptor stability contract at the reader/PHY boundary.

Required tests:

- change every command input immediately after handshake and prove the accepted
  transaction is unchanged;
- cover short, long, no-response, single-data-block, and multi-block commands;
- assert that no live command input except a defined asynchronous abort can
  affect a busy PHY.

### SD-013: Failed Data-Command Responses Do Not Cancel The Data Phase

Status: implemented with an explicit response proceed/cancel handshake.

After receiving any complete response to a command with `cmd_data_read` set,
the PHY enters `STATE_DATA_WAIT` even when its own response CRC check failed.
Separately, the reader can reject an R1 card-status response while the PHY has
already committed to waiting for data. A card that reports an address, length,
state, or illegal-command error sends no data block, and a response CRC failure
also requires an explicit receive/discard or abort policy.

If the reader leaves its read state while the PHY waits for or begins receiving
that data, `phy_data_ready` is removed and the two state machines can no longer
reach a new command handshake. This is the response-side counterpart of the
mid-burst failure in SD-005.

Required behavior:

- do not let the PHY autonomously commit to a data phase before response
  disposition is known;
- add a response accept/cancel decision from the command layer, or move the
  required R1 success classification into a shared transaction controller;
- for a response CRC/framing failure where the card may still transmit, define a
  bounded drain or CMD12/reset recovery path instead of simply withdrawing
  `data_ready`;
- guarantee that response timeout, response CRC failure, R1 rejection, and data
  timeout each converge on an idle or explicitly recoverable PHY state.

Required tests:

- CMD17/CMD18 R1 with `ADDRESS_ERROR`, `BLOCK_LEN_ERROR`, and
  `ILLEGAL_COMMAND`, with no following data token;
- corrupted CMD17/CMD18 response CRC followed by both present and absent data;
- rejected CMD6 R1 and corrupted CMD6 response CRC;
- successful new command acceptance after every failure without top-level
  simulation reset.

### SD-015: Response Start Wait Falls Into Payload Capture After One Clock

Status: implemented.

`STATE_RESP_WAIT` samples CMD on a rising edge. If the line is still high and
the timeout has not expired, it increments `timeout_count` but transitions to
`STATE_RESP_HIGH`. On the following falling phase, `STATE_RESP_HIGH` sees a zero
response-bit count and transitions to `STATE_RESP_LOW`, which unconditionally
shifts CMD as response payload. It never returns to `STATE_RESP_WAIT`.

Consequently, the PHY recognizes a response only if its start bit is present on
the first sampled clock after the command. A legal later response is captured
with the wrong alignment, and `RESPONSE_TIMEOUT_CYCLES` is effectively
unreachable for values greater than one. The current fake pin card starts its
response immediately and therefore masks this state transition.

Required behavior:

- keep toggling complete low/high SD clock phases in a response-start search
  loop until CMD is sampled low or the timeout expires;
- enter payload capture only after recording the response start bit;
- count timeout in documented SD clock cycles and preserve the complete allowed
  card-response latency;
- distinguish "searching for start" from "capturing response" in explicit state
  or flag ownership so a zero bit count cannot enter payload capture.

Required tests:

- valid responses beginning on the first, second, representative middle, and
  final allowed response clock;
- no response through the complete timeout;
- a low glitch that does not form a valid response frame;
- assertions that `rsp_bit_count` remains zero and no response payload is shifted
  while CMD stays high.

### SD-016: Data Start Wait Falls Into Payload Capture After One Clock

Status: implemented.

`STATE_DATA_WAIT` has the analogous transition error. If DAT0 is high on the
first sampled clock, it increments `timeout_count` and transitions to
`STATE_DATA_HIGH`. On the next falling phase, `STATE_DATA_HIGH` proceeds to
`STATE_DATA_LOW`, which starts shifting DAT nibbles even though no start token
was observed. `DATA_TIMEOUT_CYCLES` is therefore also effectively unreachable
for values greater than one, and idle `4'hf` cycles are consumed as payload.

The existing `fake_sd_native_pin_model` deliberately inserts 24 idle clocks
between its response and data block. The current `tb_sd_native_pin_phy_fake`
expects four `8'hff` bytes and does not assert `data_status == STATUS_OK`, so it
can pass by consuming those idle clocks and ignoring the resulting CRC failure
before the fake card's actual start token arrives.

Required behavior:

- remain in a complete low/high data-start search loop until the valid 4-bit
  start token from SD-008 is observed or the timeout expires;
- reset payload byte, half-nibble, and CRC state only on a valid start token;
- never assert `data_valid` before a valid start token;
- make a timeout terminal handshake honor `data_ready` and leave the PHY in a
  defined recoverable state.

Required tests:

- valid data starts after zero, one, several, and nearly the maximum allowed
  idle clocks;
- no start token through the complete timeout;
- assertions that byte count, CRC state, and `data_valid` remain unchanged while
  DAT stays idle;
- update the fake pin test to check the actual driven payload, final
  `data_status == STATUS_OK`, CRC16, and that the delayed real start token was
  observed before any byte was emitted.

## P1 Initialization Robustness

### SD-006: ACMD41 Retry Limit Is Not A One-Second Time Budget

Status: implemented with a 1.1 second elapsed system-clock budget.

The reader defaults to 1,024 ACMD41 attempts. At the 400 kHz initialization
clock, fast CMD55/ACMD41 responses can exhaust that count in approximately
0.53 seconds. Version 9.10 Sections 4.2.3 and 4.2.3.1 require the host to repeat
ACMD41 for at least one second or until ready, with a timeout greater than one
second from the first nonzero-voltage-window ACMD41.

Required behavior:

- replace or supplement the retry count with an elapsed-time budget derived from
  a known clock;
- keep every repeated ACMD41 argument identical to the first initialization
  request;
- make the timeout greater than one second and expose a distinct initialization
  timeout diagnostic;
- keep a bounded simulation override that still verifies the time-based policy.

Required tests:

- card ready immediately;
- card busy until just before one second;
- card busy beyond the configured deadline;
- assertion that every repeated ACMD41 argument is identical.

### SD-011: Startup Clocks Depend On A Preinserted, Already-Powered Card

Status: implemented for the Smart Artix active-low `SD_CD` input on U17.

The pin PHY emits its default 80 startup clocks once after `rst` and has no card
detect or card-power-stable input. Version 9.10 Section 6.4.1.1 requires the
initialization delay to account for supply ramp, up to 1 ms, and at least 74 SD
clocks; the same initialization requirement applies after hot insertion. The
current Smart Artix flow is safe only under the board assumption that the card
is inserted and powered long enough before the PHY reset is released. A card
inserted after the one-shot startup clocks will receive CMD0/CMD8 without a new
power-up clock sequence.

Required behavior:

- either document and enforce a boot-only, preinserted-card product contract; or
- synchronize card detect, debounce insertion/removal, restart the power-up
  clock sequence after insertion, and wait for the power-stable time budget
  before the first command;
- prevent a removal or reinsertion from inheriting `initialized` or High Speed
  state from the previous card;
- make the relationship between card power, board reset, PHY reset, and
  `init_start` explicit in the board integration document.

Required tests for any hot-insertion implementation:

- insertion before reset release and insertion after the PHY has become idle;
- removal during initialization and during a block read;
- reinsertion of a different card, including a Default Speed-only card after a
  High Speed card;
- prove at least 74 clocks and the configured power-stable delay precede CMD0 or
  CMD8 after every insertion.

### SD-014: Card-Side DAT3 Detect Pull-Up Is Never Disconnected

Status: implemented.

Version 9.10 Section 3.6 documents the card's power-up 50 kOhm pull-up on
CD/DAT3 and says it should be disconnected during regular data transfer with
`SET_CLR_CARD_DETECT` (ACMD42). ACMD42 is mandatory for SD memory cards. The
current initialization sequence goes directly from CMD7 to CMD55/ACMD6 and
never sends CMD55/ACMD42 with `set_cd=0`.

The pull-up does not change the logical value while the card actively drives
DAT3, so this is not expected to explain command-level simulation failures. It
is nevertheless a missing native-pin initialization step and changes the DAT3
electrical load from the regular-transfer condition described by the
specification.

Required behavior:

- after selecting and validating an unlocked card, issue CMD55 followed by
  ACMD42 with argument bit 0 cleared before regular 4-bit transfers;
- validate CMD55 APP_CMD and ACMD42 R1 status before continuing;
- include the card-internal and board pull-ups in the DAT3 board timing/load
  assumptions until ACMD42 completes;
- decide whether reset, removal, or failed initialization requires any explicit
  restoration policy, noting that card power-up and CMD0 restore default card
  behavior.

Required tests:

- verify ACMD42 ordering and argument before ACMD6;
- inject ACMD42 illegal-command and transport failures;
- make the fake card retain its DAT3 pull-up state and reject a test sequence
  that claims normal transfer without disconnecting it.

## P2 Transfer Resilience

### SD-017: Transient Read Errors Abort The Complete Asset Load

Status: partially implemented; block-data retries are bounded and buffered,
while separate initialization-command retry classes remain open.

The current reader buffers each block until CRC/end validation and implements a
bounded block-data retry. A failed CMD17 is retried directly. A failed CMD18 is
aborted, stopped with CMD12, and resumed from the failed LBA with CMD17, without
duplicating clean blocks already committed to the loader. Retry count and a
secondary CMD12 recovery failure are software-visible.

General command-response CRC/timeout retry classes are not implemented. Such a
failure remains terminal and clears `initialized`. CMD6 status-data CRC is also
terminal and explicitly reports that a card power cycle is required, as required
by Version 9.10.

This work must follow SD-003, SD-005, SD-013, SD-015, and SD-016. Retrying an
operation while reader and PHY state disagree would conceal or worsen the
existing deadlocks.

Required behavior:

- define bounded retry counts separately for command transport, single-block
  read, and recoverable multi-block read failures;
- retry only after proving the card and PHY returned to Transfer/idle state,
  using CMD12 or reinitialization where required;
- never retry CMD6 status CRC with CMD0 alone; expose a power-cycle-required
  terminal status if the board cannot switch card power;
- keep the asset unavailable until every byte has been received through a
  CRC-clean transaction, and overwrite any partially committed retry region;
- expose retry counters and the final failure cause for hardware diagnosis.

Required tests:

- one recoverable command CRC/timeout followed by success;
- one recoverable data CRC failure for CMD17 and for a middle CMD18 block;
- retry exhaustion with deterministic final status;
- CMD6 status CRC entering the power-cycle-required state without retry;
- exact DDR image comparison after a retry overwrites partial data.

## Confirmed Behavior

The Version 9.10 review found these implemented behaviors consistent with the
current SDHC/SDXC scope:

- CMD0, CMD8, CMD55/ACMD41, CMD2, CMD3, R1b-aware CMD7,
  CMD55/ACMD42, CMD55/ACMD6, and CMD55/ACMD51 sequencing;
- CMD8 voltage/check-pattern echo validation and ACMD41 HCS/CCS handling;
- CMD6 capability query, validated High Speed selection, and Default Speed
  fallback;
- optional CMD23 discovery through SCR and CMD18/CMD12 operation without CMD23;
- block-addressed CMD17/CMD18 arguments and fixed 512-byte SDHC/SDXC blocks;
- at least 74 startup clocks through the default 80-clock setting;
- command CRC7 generation and semantic short/long-response framing and CRC7
  checking, except R3 CRC as required;
- four-line data CRC16 and data end-bit checking;
- 4-bit nibble-to-byte assembly and per-block final-byte status reporting;
- pausing SD_CLK low for downstream backpressure, which is permitted by Section
  4.4 clock control.

These confirmations do not close the separate 50 MHz pin phase and XDC work in
`smart_artix_io_constraints_backlog.md`.

## Verification Baseline And Completion Gates

The following focused tests passed at the time of the Version 9.10 review:

```text
tb_sd_native_block_reader
tb_sd_native_block_reader_fake
tb_sd_native_pin_phy
tb_sd_native_pin_phy_fake
```

The updated focused tests cover delayed response/data starts, genuine timeouts,
wrong response indices, valid R2 CRC, R1b busy release, malformed four-bit start
tokens, command-descriptor mutation after acceptance, divider-zero command setup,
ACMD42 ordering, ACMD51 SCR discovery, CMD6 query/selection, Default Speed
fallback, accepted and rejected CMD23 paths, CMD18 without CMD23, per-block PHY
boundaries, and middle-CMD18 CRC recovery through CMD12 plus failed-LBA CMD17.
Remaining test expansion includes exhaustive R1/R6 error-bit injection, every
malformed framing bit for every response class, exact 100 ms boundary tests at
all three board dividers, CMD6 guard-clock period measurement, first-block and
inter-block failures, CMD12 busy timeout, initialization deadline boundaries,
removal during active I/O, and retry exhaustion.

Protocol backlog completion requires:

- [ ] SD-001 through SD-005, SD-007 through SD-010, SD-012, SD-013, SD-015,
  and SD-016 have focused self-checking regressions and are closed.
- [ ] SD-006 uses a measured time budget and has boundary tests.
- [x] SD-011 is closed by either an explicit preinserted-card contract or tested
  card-detect/power sequencing.
- [x] SD-014 disconnects the card-side DAT3 detect pull-up before regular
  transfer, or a documented board decision justifies retaining it.
- [ ] SD-017 has a bounded retry policy after all prerequisite recovery-state
  defects are closed.
- [ ] Fake command-level and pin-level cards can inject response status, busy,
  long data latency, capability differences, response framing faults, malformed
  data tokens, and per-block CRC errors.
- [x] `make smart-artix-test`, `make lint`, and `make test` pass.
- [x] The supported-card statement explicitly matches implemented discovery,
  fallback, addressing, voltage, and speed behavior.
- [ ] Hardware qualification uses at least one Default Speed-only path and more
  than one SDHC/SDXC card family after the timing backlog is closed.
