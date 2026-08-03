# Smart Artix Native SD 50 MHz Debug Record

This document records the complete 2026-08-02 investigation that moved the
Smart Artix board-level native-SD path from a repeatable 50 MHz CMD17 failure to
a post-route-closed and hardware-demonstrated 50 MHz sector-0 read. It preserves
the failed hypotheses and report-reading method because the useful result is the
debug process, not only the final RTL.

## Scope And Bench

- FPGA: `xc7a50tfgg484-2` on the Smart Artix board.
- FPGA board clock: 50 MHz oscillator; MIG `ui_clk`: 100 MHz.
- SD interface: board-level socket and PCB traces, not flywires.
- Final test card: genuine 32 GB SDHC card, High Speed capable.
- Card content: no WTSF image. A successful sector-0 transfer must therefore end
  with loader error `invalid magic`, not `asset_loaded`.
- Host/control path: CH347 SPI Bridge on J20 SCLK, with 937.5 kHz smoke reads and
  30 MHz final reads.
- Fixed SD pins: V20 CLK, Y22 CMD, U20/V18/V22/Y21 DAT[0:3], and U17 active-low
  card detect. The SD pins cannot be moved on this board.

The final acceptance signature for this card is:

```text
VERSION          = 0x000d0000
PLATFORM_STATUS  = 0x00018057
PLATFORM_ERRORS  = 0x000f0100
```

`PLATFORM_STATUS` proves DDR calibration, card presence, SD initialization, and
High Speed selection. In `PLATFORM_ERRORS`, SD error zero proves the sector read
completed; loader error one is the expected invalid WTSF magic.

## Evidence Timeline

### 1. Card Compatibility Was Separated From Pin Timing

The first card was an old 2 GB card without an SDHC marking. The current reader
intentionally supports block-addressed SDHC/SDXC cards and does not implement
SDSC byte-address fallback, so that card could not be used as a clean 50 MHz
timing probe.

The replacement genuine 32 GB SDHC card removed that ambiguity. It initially
failed CMD3 with SD error 14. The R6 validator expected Standby state (`3`), but
R6 reports the state at command receipt, which is Identification (`2`). Fixing
that protocol check allowed initialization and CMD6 High Speed selection to
complete. This was a protocol defect independent of the later CMD17 timing
failure.

### 2. A 25/50 MHz A/B Test Localized The Failure

Two fresh images differed only in the post-CMD6 transfer divider:

| Bitstream SHA-256 | SD clock | Result |
| --- | ---: | --- |
| `5b19ae16680112528a789d351237009a3edf3edd5e564619523de4302893d5ec` | 50 MHz | `PLATFORM_ERRORS=0x00220008`; CMD17 failed after two retries |
| `e425a2882fbe821bf1ffbdda337e81c772291d92e0ba226994537052a61f3ef5` | 25 MHz | `PLATFORM_ERRORS=0x000f0100`; sector 0 reached the expected invalid-magic check |

The 25 MHz run also reported `PLATFORM_STATUS=0x00018057` and passed direct DDR
write/read at byte address `0x100`. Holding the card, protocol, socket, image
content, and loader constant made clock rate the useful independent variable.
This ruled out initialization and WTSF parsing as explanations for the 50 MHz
CMD17 failure and justified investigating the physical pin path before another
long protocol rewrite.

### 3. Package And Pin Capabilities Were Audited

The board pin assignment was checked against the Xilinx 7-series package file.
V20 is `IO_L11N_T1_SRCC_14`, so the fixed SD clock pin is clock-capable. CMD and
DAT remain fixed board-level pins. The downloaded reference is preserved under
`docs/reference/`:

| Artifact | SHA-256 |
| --- | --- |
| `xilinx-7-series-package-files-v1.10.zip` | `576e04c5eea02d4d139a475338cfa4be600e7c4e5a983ba792d799849880d53b` |
| `xc7a50tfgg484pkg.csv` | `cecbf7cf3c1b8c8b14373213a3680231fc267104c73d4cecaa881b4fd1dc6cd9` |

This step prevented an unnecessary pin-change proposal and confirmed that the
remaining work belonged in the board I/O architecture and XDC.

## Timing Investigation

### Initial Assumptions

The bundled public SD simplified specification leaves the numeric Default/High
Speed timing tables blank. Until a production card data sheet and socket
measurement are available, the XDC uses explicit generic 3.3 V High Speed
assumptions:

| Quantity | Constraint assumption |
| --- | ---: |
| card CMD/DAT output maximum delay | 14.0 ns |
| card CMD/DAT output minimum hold | 2.5 ns |
| card CMD input setup requirement | 6.0 ns |
| card CMD input hold requirement | 2.0 ns |

These values are engineering assumptions, not claims extracted from the bundled
Version 9.10 PDF.

### Reports Were Split By Direction

Global WNS is insufficient for a source-synchronous interface. Each routed
checkpoint was queried separately for:

1. SD CLK forwarding delay from the 100 MHz register to V20;
2. card CMD/DAT to the input boundary, maximum/setup;
3. card CMD/DAT to the input boundary, minimum/hold;
4. CMD data/output-enable to Y22, maximum/setup;
5. CMD data/output-enable to Y22, minimum/hold;
6. the physical ILOGIC/OLOGIC placement of each boundary register.

The critical report option was `-path_type full_clock_expanded`. It exposed the
clock source delay and the actual capture edge rather than only reporting a
single slack number.

### Failed Attempt A: Falling-Edge IDDR Capture

The first board wrapper used IDDR and selected the falling-edge sample. The
intent was to capture near the middle of the 20 ns SD period. Routed analysis
showed why that was impossible under the 14 ns card delay assumption:

- the fabric-generated SD clock took `6.819 ns` to reach the socket pin;
- the return path included the 14 ns external delay and input buffer delay;
- the falling system edge was only 5 ns after the launch edge in the internal
  100 MHz clock domain;
- the resulting SD input WNS was approximately `-15.995 ns`.

The lesson was that selecting a later-looking internal edge does not create
margin when the forwarded-clock source delay is included. The full external
clock path must be part of the calculation.

### Failed Attempt B: Q1 IDDR With Delayed PHY Consumption

The next attempt packed SD_CLK and CMD launch registers into output IOBs and
used IDDR Q1. The PHY was changed to consume the registered response/data in the
following high state, so the intended logical sample was one full SD period
after card launch.

The implementation still failed with WNS `-4.035 ns`. Detailed timing showed a
15 ns requirement ending on the IDDR falling capture. IDDR physically captures
both edges at its D pin even when Q2 is unused, so choosing Q1 in RTL does not
remove the falling-edge timing check. A separate warning also showed that CMD
data and active-low-transformed output-enable registers could not share one
OLOGIC because their control sets differ.

This failure is important: unused output connectivity does not erase physical
primitive behavior. Timing must match the primitive, not the intended use of one
of its outputs.

### Constraint Selection Failure

An early multicycle constraint used a hierarchical `get_pins` name filter. It
selected no endpoints after synthesis because register replication and pin-name
formatting differed from the RTL name. Vivado did not provide a useful failure
at the point the query was written.

The stable method was:

```tcl
set sd_input_iob_regs [get_cells -hier -filter \
  {NAME =~ "sd_io/sd_*_i_q_reg*"}]
set sd_input_iob_d_pins [get_pins -of_objects $sd_input_iob_regs -filter \
  {REF_PIN_NAME == D}]
```

Every list was printed and checked against the synthesized checkpoint before
implementation. The CMD hold exception similarly filters `IS_SEQUENTIAL` so
same-prefix LUTs cannot become invalid startpoints.

## Final Architecture

The final board-specific solution is deliberately simpler than IDDR:

- `smart_artix_sd_io` owns the Smart Artix IBUF/IOBUF/OBUF boundary;
- five single-edge 100 MHz input registers carry `IOB=TRUE` and capture CMD plus
  DAT[3:0];
- `sd_native_pin_phy` consumes response bits, data nibbles, CRC, and end tokens
  in the high state after the boundary register has captured the previous bit;
- at 50 MHz, the effective card-launch-to-input-FF capture interval is 20 ns;
- SD_CLK and CMD data launch registers are packed into output IOBs;
- a generated 50 MHz clock is defined on `sd_clk`;
- setup-two/hold-one multicycle constraints end only at the five input-IOB D
  pins;
- CMD data and OE are state-qualified to the falling/low phase. Only their
  impossible same-rising-edge hold path is false-pathed; maximum delay to the
  following rising edge remains timed.

The PHY still supports slower initialization and Default Speed dividers. The
divider is transaction-latched, and CMD6 guard clocks complete at the old rate
before the subsystem enables 50 MHz.

## Final Timing Results

Forced implementation used Vivado 2025.2 and the production configuration of
512 voices. The final result was:

| Check | Result |
| --- | ---: |
| global WNS / TNS | `+0.175 ns` / `0.000 ns` |
| global WHS / THS | `+0.045 ns` / `0.000 ns` |
| routed nets | `46621 / 46621` |
| route errors | `0` |
| DRC errors / critical warnings | `0 / 0` |
| card input setup slack | `+0.965 ns` |
| card input hold slack | `+13.902 ns` |
| FPGA CMD setup slack | `+1.545 ns` |

The card-input detailed report explicitly uses a 20 ns requirement from SD clock
rise at 0 ns to system-clock rise at 20 ns. Input data path delay is `1.445 ns`
inside the FPGA after the external delay. All five input FFs, SD_CLK output FF,
and CMD output FF retain `IOB=TRUE` in the post-route checkpoint.

The final bitstream is:

```text
bdcfda91c30921cf336c7cf104d36e58ce22399f192a405ea018bce1a2098c13
```

## Hardware Acceptance

The bitstream was programmed into volatile SRAM twice. Both independent FPGA
starts produced:

```text
PLATFORM_STATUS = 0x00018057
PLATFORM_ERRORS = 0x000f0100
```

The first run was read at 937.5 kHz and again at 30 MHz SPI. The second run was
read at 30 MHz SPI. All reads were exact. This demonstrates that the 50 MHz SD
change did not regress the previously qualified 30 MHz SPI Bridge path.

The board smoke flow was also run against the physical board. The original C++
runner is now retired; its current Python equivalent is:

```bash
python3 tools/ch347_tool.py --clock-hz 30000000 wait ddr
python3 tools/ch347_tool.py --clock-hz 30000000 ddr-smoke 0x100
```

It passed interface-version validation, printed the expected SD/loader status,
accepted DDR readiness despite the expected invalid-WTSF loader error, and
completed an exact 16-byte DDR write/read. Core registers are intentionally not
read while `asset_loaded=0`, because the asset reset keeps that register window
unavailable.

The completed verification gates for this change were:

- `make lint`;
- `make test`, including the host/CH347 tests and generic RTL regression;
- `make smart-artix-test`, including the focused SD PHY and Smart Artix I/O
  boundary tests;
- `make check-docs check-generated`;
- a forced fresh Vivado post-route implementation and detailed SD path review;
- two volatile FPGA programs followed by independent 50 MHz SD initialization
  and sector-0 reads on the physical board.

## Reproduction Sequence

```bash
make tb_sd_native_pin_phy tb_sd_native_pin_phy_fake tb_smart_artix_sd_io
make smart-artix-test
make vivado-impl
make vivado-summary
make vivado-analyze
make vivado-bitstream
sha256sum build/fpga/smart_artix/vivado/bitstream/smart_artix_top.bit
make vivado-program
python3 tools/ch347_tool.py --clock-hz 30000000 \
  read VERSION PLATFORM_STATUS PLATFORM_ERRORS
python3 tools/ch347_tool.py --clock-hz 30000000 wait ddr
python3 tools/ch347_tool.py --clock-hz 30000000 ddr-smoke 0x100
```

Verilator targets use the Makefile default `-j 0`. A sporadic parallel build
failure may be retried, but routine runs must not be forced to `-j 1`. Vivado
uses its separate configured job count.

## Remaining Qualification

This experiment closes the implemented timing model and demonstrates operation
on one board/card/adapter combination. It does not replace:

- oscilloscope measurements at the socket for duty cycle, rise/fall time,
  overshoot, ringing, and CMD/DAT eye margin;
- PCB trace-skew extraction;
- voltage and temperature corner testing;
- confirmation against the selected production card data sheet;
- repeated testing across more than one SDHC/SDXC vendor and capacity.

Those items should refine the external delay numbers. They should not remove the
explicit I/O boundary or broaden the scoped exceptions without a new detailed
timing proof.
