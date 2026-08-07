# Smart Artix Bring-Up Plan

This document turns the current Smart Artix board integration state into a
hardware bring-up procedure. It assumes the `fpga/smart_artix/` top level is the
target image and that the first board goal is to prove the platform path before
bringing up musical behavior.

The intended order is:

```text
Vivado bitstream
  -> clock/reset and DDR3 calibration
  -> SPI status-register reads
  -> SD raw-image load into DDR3
  -> one programmed voice
  -> I2S electrical/audio smoke test
```

Do not start with MIDI playback or full SoundFont preset policy. The FPGA does
not parse MIDI, allocate voices, or evaluate SoundFont regions; those remain
host, MCU, or later soft-processor responsibilities.

## Current Board Image

`fpga/smart_artix/rtl/smart_artix_top.sv` currently connects:

- `clk_in` from the board `50 MHz` oscillator.
- `smart_artix_clk_50m_to_200m`, feeding MIG `sys_clk_i`.
- `smart_artix_ddr3_mig`, exposing a `100 MHz` MIG `ui_clk`.
- `voice_major_system`, clocked by MIG `ui_clk`.
- native 4-bit SD asset loading into DDR3.
- DDR3 read/write arbitration between asset-loader writes and wavetable reads.
- SPI global-register access, transactional voice commands, and common status.
- fixed-rate 48 kHz I2S transmit output.
- two onboard milestone LEDs: DDR3 calibration complete on `R17`, and SD loader
  status on `P16`; four detailed diagnostic LED outputs remain on the expansion
  header.

The generic core and the MIG application interface intentionally stay in the
same `100 MHz` `ui_clk` domain. This avoids a CDC bridge in the memory request
path during first bring-up.

## Bring-Up Boundaries

The first hardware image should prove these contracts:

- Vivado can generate a bitstream for `xc7a50tfgg484-2` with the generated Clocking
  Wizard and MIG IP.
- The board oscillator, reset input, and MIG DDR3 connection allow
  `init_calib_complete` to assert.
- The SPI transport can read the common status window after the MIG UI clock is
  available.
- The SD raw-image loader can initialize an SDHC or SDXC card, parse the `WTSF`
  sector-0 header, and copy the SF2 byte image into DDR3.
- The host can write one voice slot through SPI and produce non-silent I2S data.

The first hardware image does not need to prove:

- MIDI file playback.
- full SF2 preset, generator, modulator, or velocity behavior.
- real-time voice allocation policy.
- Ethernet or high-speed asset upload.
- codec configuration over I2C or SPI.

## Before Connecting Hardware

Replace every temporary or unverified board pin assignment before wiring external
hardware. The checked-in XDC records useful intent, but it should be treated as a
bring-up skeleton until it has been checked against the Smart Artix schematic.

Required checks:

- Confirm the exact FPGA part, package, and speed grade: `XC7A50T-2FGG484I`, Vivado
  part `xc7a50tfgg484-2`.
- Confirm `clk_in` is the board `50 MHz` oscillator pin and that the Clocking
  Wizard XDC owns the primary clock constraint.
- Confirm `rst_n` source and polarity. The board top expects active-low reset.
- Confirm SPI, I2S, SD, and status LED pins against the schematic and connector
  pinout.
- Wire the BANK15 SPI header as SCLK pin 14 (`J20`), CS pin 2 (`H13`), MOSI pin
  3 (`G18`), and MISO pin 4 (`G17`). `J20` is an SRCC input; do not return SCLK
  to ordinary-I/O header pin 1 (`G13`) when testing the source-synchronous image.
- Confirm I/O standards and bank voltages. The skeleton uses `LVCMOS33` for
  non-DDR I/O.
- Keep DDR3 pins and DDR3 timing constraints owned by the MIG-generated XDC.
- Add real constraints for all top-level ports before generating a hardware
  bitstream.

Pay special attention to XDC coverage that must still be checked against the
actual board wiring:

- The SD connector may be marked by SPI-mode names. For native SD mode, map
  `SCK` to `sd_clk`, `MOSI` to `sd_cmd`, `MISO` to `sd_dat[0]`, and `CS` to
  `sd_dat[3]`. Native 4-bit mode also requires `sd_dat[1]` and `sd_dat[2]`.
- The current native SD path is read-only: the card drives `DAT[3:0]` during data
  blocks and the FPGA samples those pins as inputs. Do not make the FPGA actively
  drive `DAT[3:0]` unless a later write-capable SD PHY adds explicit output-enable
  control.
- `sd_cmd` and every `sd_dat` line need pull-ups unless the board already provides
  suitable external pull-ups.
- The two on-board green LEDs are `LED1` on `R17` and `LED2` on `P16`. The
  current XDC maps `led_ddr_ready` to LED1 and `led_asset_loaded` to LED2;
  LED2 is a status pattern despite retaining the stable top-level port name.
  The four detailed SPI/audio diagnostic LEDs remain on BANK15 expansion pins.
- SPI and I2S external input/output delays are not final until the selected host
  adapter and codec timing are known.

## Pre-Hardware Regression

Run the normal core and board-level tests before building a bitstream:

```bash
make lint
make test
make smart-artix-test
make render-rtl-ddr3 SECONDS=0.1
```

Expected intent:

- `make lint` catches synthesizable RTL issues.
- `make test` checks C++ parser/control helpers plus exact core register,
  memory, interpolation, loop, gain, mix, SPI, and I2S behavior.
- `make smart-artix-test` checks the Smart Artix SD, DDR writer, DDR reader,
  read/write arbiter, native SD path, and loader blocks with focused simulations.
- `make render-rtl-ddr3` verifies real SF2 command generation, the voice window,
  ordered DDR refill traffic, and timed DDR3-backed rendering.

These tests do not prove board pin timing or DDR3 electrical behavior. They are
the regression floor before hardware bring-up starts.

## Vivado Flow

Use the repository-root targets. They create and enter the generated build
directory so project output stays under `build/`:

```bash
make vivado-project
make vivado-impl
make vivado-analyze
make vivado-bitstream
```

Review at least:

- `reports/post_route_timing.rpt`
- `reports/post_route_utilization.rpt`
- bitstream log messages about unconstrained or unrouted I/O
- MIG IP warnings that mention clocking, reset, or pin incompatibility

The latest 2026-08-03 forced-fresh route, including the MAX98357A I2S output
constraints, met setup and hold timing with WNS `+0.148 ns`, WHS `+0.040 ns`,
and zero TNS/THS. All 47,904 routable nets were routed and DRC reported zero
errors or critical warnings. Routed utilization was 25,905 LUTs (79.46%),
26,517 registers, 46.5 BRAM tiles, and 39 DSPs. The margin and LUT headroom
remain small, so every functional RTL change still requires a fresh post-route
result. Detailed I2S path results are recorded in
[`smart_artix_io_constraints_backlog.md`](smart_artix_io_constraints_backlog.md#p1-i2s-output-timing).

### Current Bitstream and Programming Status

`VIVADO_FORCE_REBUILD=1 make vivado-impl` followed by `make vivado-bitstream`
completed successfully on 2026-08-03 with Vivado 2025.2.
The write-bitstream precondition DRC reported zero errors, and the generated file
was identified as an image for `7a50tfgg484`:

```text
build/fpga/smart_artix/vivado/bitstream/smart_artix_top.bit
size:   2,192,139 bytes
sha256: f3fdfaf76bab00bc319891210ceadc89d5a0c50d56201fc8015444d27bb209fe
```

Generated files under `build/` are intentionally not committed. Regenerate the
image from the checked-in sources and record a new checksum whenever RTL, XDC,
IP configuration, Vivado version, or run strategy changes.

On 2026-08-02, Vivado 2025.2 opened Xilinx Adapt cable `26SH012`, detected one
`xc7a50t` with IDCODE `0x0362c093`, and read the already-running FPGA
configuration SRAM. The 2,190,084-byte raw readback had SHA-256
`2b7d7350e3e041adae00c47d27e8ffddb0ef0d15c556be0843d0c4d24badcd3e`.
`DONE`, `EOS`, PLL lock, and DCI match were set; CRC and IDCODE errors were
clear. This proves JTAG enumeration and readback for that board and cable. It
does not prove that the locally generated `.bit` is the image that was running.

Load the local image into volatile configuration SRAM with:

```bash
make vivado-program
```

The programming script requires exactly one detected `xc7a50t` device instead
of selecting the first device in an arbitrary JTAG chain. This command loads the
`.bit` file into the FPGA's volatile configuration SRAM; it must be repeated
after power is removed. The latest 2026-08-03 run programmed the current hash
above to `xc7a50t_0` and then required `DONE=1`, `DONE_PIN=1`, `EOS=1`,
`CRC_ERROR=0`, and `IDCODE_ERROR=0` before succeeding.

Read the currently running FPGA configuration without programming it:

```bash
make vivado-readback
```

The output is raw programming data under
`build/fpga/smart_artix/vivado/readback/`, not the original `.bit` container.
The diagnostic-image post-program read on 2026-08-02 returned 2,190,084 bytes
with SHA-256
`e436ba68fb988d479bee11f4cd41cc268a09dffd17dc691bfc4c1b4c75c10a8f`.
The raw readback can include changing state such as BRAM contents, so its hash
is a per-run audit value, not a deterministic identity for the source `.bit`.

### Configuration Flash

Schematic revision 1.3 identifies the configuration device as Winbond
`W25Q128JVSIQTR`, 128 Mbit (16 MiB), connected to the FPGA's dedicated QSPI
pins. The mode resistors select Master SPI. Vivado 2025.2 matches this device
with cfgmem part `w25q128jvq-spi-x1_x2_x4`. The project XDC sets
`BITSTREAM.CONFIG.SPI_BUSWIDTH` to `4`, matching the four connected data pins
and the `SPIx4` persistent-image format.

Read the complete Flash with:

```bash
make vivado-flash-readback
```

Vivado must first load its indirect SPI access core into FPGA configuration
SRAM, so this interrupts the running design. The target reads all 16 MiB to
`build/fpga/smart_artix/vivado/flash/w25q128jv_full_readback.bin`, then issues
`boot_hw_device` and requires a clean `DONE/EOS/CRC/IDCODE` status before it
succeeds. It does not erase or write the Flash.

The 2026-08-02 hardware run read JEDEC ID `ef 40 18`, completed in 44 seconds,
and produced SHA-256
`c71e9d450d816b5986dca43c93a31d5b876820ce24a386acf1d9385e2ac30f10`.
The image contains the Xilinx synchronization word `aa995566` at offset
`0x30`. JTAG-triggered Flash boot then completed with `DONE=1`, `EOS=1`, and no
CRC or IDCODE error. A cold power-cycle boot is still unqualified.

Build the persistent SPIx4 configuration image without accessing hardware:

```bash
make vivado-cfgmem-image
```

This reuses or regenerates the current routed `.bit` and writes
`build/fpga/smart_artix/vivado/flash/smart_artix_top_spi_x4.mcs`. The
2026-08-03 image was generated successfully with SPIx4 interface and SHA-256
`71c1c70f47aa70fc94ae0e176589e649c4bdd87e4f13085e143b894bf4139d2d`.
Persistent
programming is deliberately a separate, destructive target:

```bash
make vivado-flash-program CONFIRM_FLASH_PROGRAM=YES
```

It requires exactly one `xc7a50t`, loads the indirect SPI core, erases the
addressed configuration sectors, programs the MCS image, enables Vivado verify,
then boots from Flash and checks configuration status. Back up the full Flash
first when its existing contents must be retained. On 2026-08-03 the target
erased, programmed, and verified the image in 85 seconds, then booted it with
`DONE=1`, `DONE_PIN=1`, `EOS=1`, `CRC_ERROR=0`, and `IDCODE_ERROR=0`. The
post-boot register snapshot also showed DDR calibrated, SD High Speed active,
and the complete SF2 loaded without SD, loader, retry, or recovery errors.

On 2026-08-07 the same flow programmed and verified the interface-version-16
render-session-reset image. The routed bitstream SHA-256 was
`914c65fe436bf84d60c699bea4299f15c7d22ec290de657fec35146fa5fb625c` and the
SPIx4 MCS SHA-256 was
`ed12c59c5f9ecd014be733fdb8d3988d0510e85b19d08b22c50798bf4df063bc`.
Flash boot again reported `DONE=1`, `DONE_PIN=1`, `EOS=1`, `CRC_ERROR=0`, and
`IDCODE_ERROR=0`; the RP2040 subsequently read `VERSION=0x00100000` and the
expected 324,800,670-byte asset identity.

The same run exposed avoidable host-build overhead before hardware access.
After converting the `.bit` and `.mcs` outputs to real dependency-tracked Make
targets, a repeated unchanged `make vivado-cfgmem-image` fell from the earlier
Vivado/report path to 0.03 seconds and did not start Vivado. A changed input still
runs the bitstream freshness check and rebuilds the MCS; the measured combined
refresh was 12.79 seconds. These changes remove pre-program duplication from
`vivado-flash-program`, but not the required 85-second physical Flash erase,
program, and verify operation.

The Xilinx Adapt target advertised 30 MHz as its highest supported JTAG setting.
A same-image A/B reduced `program_hw_cfgmem` from 85 seconds at 15 MHz to 81
seconds at 30 MHz. The 30 MHz run completed erase, program, verify, Flash boot,
and the following full SD load without configuration or asset errors. The small
4.7% gain confirms that Flash erase and Vivado's indirect SPI operations
dominate; doubling JTAG frequency cannot make this path twice as fast. The
default therefore remains the conservative 15 MHz; use
`VIVADO_HW_FREQUENCY=30000000` explicitly when the minor gain is useful.

Volatile SRAM programming showed a somewhat larger but still modest end-to-end
benefit. Programming the same bitstream with `make vivado-program` took 11.61
seconds at 15 MHz and 10.34 seconds at 30 MHz, a 1.27-second (10.9%) reduction.
The direct bitstream transfer benefits from the faster JTAG clock, but Vivado
startup, hardware-server connection, device refresh, and status checks remain
fixed costs. This result also does not justify changing the 15 MHz default.

## First Power-On Checks

Keep the first power-on observation simple:

- Confirm JTAG sees the FPGA and programming completes.
- Confirm reset release polarity with a scope or logic analyzer if the board does
  not behave as expected.
- Confirm the Clocking Wizard and MIG are not held in reset.
- Confirm DDR3 calibration eventually completes.
- Watch on-board LED1 (`led_ddr_ready`, R17) and LED2
  (`led_asset_loaded`, P16). LED1 stays on after MIG calibration. LED2 is off
  when the loader is idle, blinks slowly while SD initialization/loading is
  active, blinks quickly when any SD, recovery, or asset-loader error code is
  nonzero, and stays on after the asset is in DDR. At the 100 MHz system clock,
  slow means 0.5 s on plus 0.5 s off (1 Hz), while fast means 0.1 s on plus
  0.1 s off (5 Hz). Success overrides error and error overrides busy.
- The first 2026-08-02 image used steady LED2-only completion indication. The
  observed LED1-on/LED2-off state qualified DDR3 calibration but showed that the
  SD-to-DDR load had not completed; it motivated the diagnostic blink pattern.
- With the diagnostic image programmed later that day, LED1 stayed on and LED2
  blinked at the fast 5 Hz rate. This qualifies MIG calibration and proves that
  at least one of the SD, SD-recovery, or asset-loader error fields became
  nonzero. It does not distinguish those fields. After the SPI bridge is
  connected, read `PLATFORM_STATUS` (`0x9040`) and `PLATFORM_ERRORS` (`0x9044`)
  before resetting the SD session, then decode the fields using
  `docs/register_map.md`.

The current SPI platform register window is clocked from MIG `ui_clk`. It is
available only after the MIG UI clock exists and the system reset is released.
If DDR3 calibration never completes, expect SPI reg reads to fail or stay
unavailable. A future always-on status island would need a separate clock domain
and CDC status snapshots.

## SPI Status Smoke Test

Run the Python protocol tests without hardware access, then inspect the board:

```bash
make test-ch347-python
python3 tools/ch347_tool.py --device 0 --clock-hz 1000000 info
python3 tools/ch347_tool.py --device 0 --clock-hz 1000000 \
  read VERSION PLATFORM_STATUS PLATFORM_ERRORS
```

Then use the selected CH347 library and conservative SPI speed. Start around
`1 MHz` when checking new wiring. The common SPI register bridge receives
requests by sampling SCLK into the 100 MHz FPGA system clock, while fetch MISO
is launched directly from SCLK falling edges. Register execution is split from
the SPI request and reported by a later fetch, so a stalled internal register
target no longer requires the SPI master to pause in one transaction. The
current `J20` SCLK image has passed exact mailbox and DDR testing at the CH347
30 MHz step; do not extrapolate that result to another adapter or wiring. See
[`../design/transport/spi_register_mailbox.md`](../design/transport/spi_register_mailbox.md).

That sequence applies to bidirectional register transactions. Dedicated
opcode-`0xa5` command writes do not use MISO and have no per-word register-bus
wait state. After register access is stable, qualify command-only streams
separately at each actual CH347 step through the measured 7.5 MHz stress point.
The command workload may require more throughput than the current bridge can
safely provide; that is not permission to skip physical qualification. The
workload derivation and stress criteria are documented in
[`../design/transport/spi_command_stream.md`](../design/transport/spi_command_stream.md).

```bash
python3 tools/ch347_tool.py --device 0 \
  --clock-hz 1000000 --cs-mask 0x80 snapshot --group platform
python3 tools/ch347_tool.py --device 0 \
  --clock-hz 1000000 --cs-mask 0x80 wait ddr
```

The CH347 Linux SDK opens device paths such as `/dev/ch34x_pis0`; the host tool
maps `--device 0` to that path for convenience. The copied x64 vendor library is
used by default from `third_party/ch347_linux/lib/x64/libch347.so`.

`ch347_tool.py` reads the mailbox-backed status and exits nonzero when an
operation fails. Confirm `VERSION == 0x00100000` before interpreting current
fields. If CH347 is connected to the host but not to a valid FPGA SPI target,
MISO may read back as all ones and the version check will fail. The Python
transport is unconditionally configured for the board's SPI mode 0.

The useful first reads are:

| Address | Register | Expected use |
| --- | --- | --- |
| `0x9000` | `VERSION` | Proves SPI can reach the register map. |
| `0x9010` | `SYSTEM_STATUS` | Shows core, FIFO, I2S, and external-memory handshake state. |
| `0x9014` | `COMMON_EVENT_FLAGS` | Shows sticky underrun/drop/deadline/memory events. |
| `0x901c` | `PIPELINE_LATENCY_STATUS` | Shows last render and memory-response latency. |
| `0x9040` | `PLATFORM_STATUS` | Main DDR/SD/asset-loader status word. |
| `0x9044` | `PLATFORM_ERRORS` | SD error, loader error, and loader state. |
| `0x9048` | `PLATFORM_BYTES_LOADED` | Loaded byte count. |
| `0x9050` | `PLATFORM_SF2_SIZE` | SF2 byte count from the raw header. |
| `0x9058` | `PLATFORM_CURRENT_LBA` | Current sector being loaded. |
| `0x905c` | `PLATFORM_DDR_STATUS` | MIG calibration, ready flags, and device temperature. |
| `0x9060`..`0x907c` | `DDR_ACCESS_*` | Single-beat DDR read/write platform register window. |

### 2026-08-02 CH347 SPI Clock Sweep

The rewired board was measured with SPI mode 0, CH347 device
`/dev/ch34x_pis2`, chip-select mask `0x80`, the 100 MHz FPGA system clock, and
bitstream SHA-256
`7a569902223b3b55471061165ef5bec04cf198da8a9f166d38c17882adbdcf58`.
DDR calibration was complete. A 16-byte pattern was first written at DDR byte
address `0x100`, then every clock step repeatedly read `PLATFORM_STATUS`,
`PLATFORM_ERRORS`, and that DDR beat. Each passing step completed 100 exact
reads of each target, or 300 mailbox transactions:

| Requested SCLK | Selected SCLK | Exact transactions | Result |
| ---: | ---: | ---: | --- |
| 468.75 kHz | 468.75 kHz | 300/300 | pass |
| 1 MHz | 937.5 kHz | 300/300 | pass |
| 2 MHz | 1.875 MHz | 300/300 | pass |
| 5 MHz | 3.75 MHz | 300/300 | pass |
| 10 MHz | 7.5 MHz | 300/300 | pass |
| 15 MHz | 15 MHz | 300/300 | pass |
| 30 MHz | 30 MHz | 0/300 | first mailbox request timed out |
| 60 MHz | 60 MHz | 0/300 | first mailbox request timed out |

The highest demonstrated stable CH347 step is therefore 15 MHz, and the first
failing step is 30 MHz. Because this adapter offers no intermediate step, this
experiment bounds the failure threshold to the interval above 15 MHz and at or
below 30 MHz; it does not identify a more precise maximum. Cable geometry,
signal voltage at the FPGA pins, waveform margins, load, and temperature were
not instrumented, and external SPI timing constraints remain incomplete. Treat
15 MHz as a result for this exact bench wiring, not as a portable board rating.

After the SD fixes and 25 MHz SD transfer-clock change, bitstream
`e425a2882fbe821bf1ffbdda337e81c772291d92e0ba226994537052a61f3ef5`
was rechecked at the demonstrated 15 MHz SPI step. It completed another 100
exact reads each of `PLATFORM_STATUS`, `PLATFORM_ERRORS`, and the DDR beat at
`0x100` (300/300 transactions). This confirms that the final image retained the
15 MHz SPI result. The CH347 connection used for this test is external test
wiring; the SD socket and SD signals are board-level routing.

### 2026-08-02 Clock-Capable SCLK And 30 MHz Retest

The SPI Bridge fetch transmitter was changed to launch MISO directly from the
external SCLK falling edge. SCLK moved from ordinary-I/O BANK15 header pin 1 /
`G13` to clock-capable header pin 14 / `J20` (`IO_L11P_T1_SRCC_15`). CS, MOSI,
and MISO remained on header pins 2 / `H13`, 3 / `G18`, and 4 / `G17`.

Forced implementation of bitstream
`804e0fa9ac38df3ad9238416fa656a7ea76395954e50227311378451816f8e1c`
met timing with WNS `+0.213 ns`, WHS `+0.021 ns`, zero failing endpoints, zero
route errors, and zero DRC errors. The SCLK clock is asynchronous to the board
clock group. The falling-edge MISO register is packed in `OLOGIC_X0Y92`; its
30 MHz SCLK-to-MISO setup path has `+2.845 ns` slack under the documented 5 ns
external setup budget.

After volatile programming, a 937.5 kHz smoke test read `VERSION =
0x000d0000`, `PLATFORM_STATUS = 0x00018057`, and `PLATFORM_ERRORS =
0x000f0100`, then wrote and read back DDR byte address `0x100` as
`fedcba98_76543210_89abcdef_01234567`. At an actual 30 MHz SCLK, one initial
read passed and 300/300 subsequent rounds returned those same three registers
and DDR data exactly.

The CH347 60 MHz step timed out on its first mailbox request, as expected for
the remaining 100 MHz dual-edge oversampling receiver: a 60 MHz half-period is
only 8.33 ns, shorter than one 10 ns system-clock sample interval. This is an
architecture limit, not evidence of a new wiring or MISO failure. The available
CH347 steps therefore establish 30 MHz as the highest demonstrated mailbox/DDR
rate and 60 MHz as unsupported; they do not locate a finer threshold below
50 MHz. No oscilloscope measurements of voltage, duty cycle, or temperature
margin were made, so 30 MHz remains a qualification result for this exact
adapter, wiring, board, and image rather than a general electrical rating.

`PLATFORM_STATUS` bit meanings:

```text
bit 0      platform register window present
bit 1      SD or loader error present
bit 2      DDR calibration complete
bit 4      SD initialized
bit 5      asset loaded
bit 6      asset loader busy
bits 14:7  reserved, zero
bit 15     SD card present
bit 16     SD High Speed active
```

Detailed DDR UI reset/MIG handshake fields are in `PLATFORM_DDR_STATUS`, and
the asset-loader state is in `PLATFORM_ERRORS[19:16]`.

`PLATFORM_ERRORS` packs:

```text
bits 7:0    SD error code
bits 15:8   loader error code
bits 19:16  asset-loader state
bits 27:20  saturating SD retry count
bits 31:28  SD recovery error code
```

For the current native-SD Smart Artix top, decode `SD error code` and `loader
error code` with the `PLATFORM_ERRORS` tables in `docs/register_map.md`. The SD
code identifies the failed native card command or data transfer stage; the loader
code identifies raw `WTSF` header validation, size/range checks, or DDR writer
failure.

After `PLATFORM_DDR_STATUS[0]` reports calibration complete and
`DDR_ACCESS_STATUS.ready` is set, use the DDR register-access wrapper in the
CH347 tool to prove direct DDR access before depending on SD-loaded data:

```bash
# Wait for DDR, then destructively write and verify one 16-byte beat.
python3 tools/ch347_tool.py --device 0 --clock-hz 1000000 wait ddr
python3 tools/ch347_tool.py --device 0 --clock-hz 1000000 \
  ddr-smoke 0x00000100

# Write 16 bytes at DDR byte address 0x100.
python3 tools/ch347_tool.py --device 0 --clock-hz 1000000 \
  ddr-write 0x00000100 0x01234567 0x89abcdef 0x76543210 0xfedcba98 \
  --byte-enable 0xffff

# Read back the same 16-byte beat.
python3 tools/ch347_tool.py --device 0 --clock-hz 1000000 \
  ddr-read 0x00000100
```

Each DDR register-access command accesses one 128-bit MIG beat, which is 16
bytes in the current Smart Artix build. To inspect or patch 128 bytes, run eight
commands and increment the address by `0x10` each time. The address must be
16-byte aligned; an unaligned command or a write with `--ddr-byte-enable 0`
reports an error and does not access DDR.

For a sequential read-throughput measurement or an exact comparison with a
source byte image, use the Python benchmark command:

```bash
python3 tools/ch347_tool.py --device /dev/ch34x_pis0 --clock-hz 30000000 \
  ddr-benchmark \
  --address 0 --bytes 65536 --verify path/to/source.sf2
```

The benchmark reports end-to-end payload throughput through the single-beat
DDR register window. `--verify` compares DDR bytes with the same byte offset in
the source file; `--output` writes the captured range to a file. Both the start
address and byte count must be multiples of 16.

On the 2026-08-02 bench, sequential reads at both the 15 MHz and 30 MHz CH347
steps delivered approximately 12.2 KiB/s of SF2 payload. The similar result at
both clock steps shows that this utility is dominated by the mailbox request,
DDR command, and polling round trips for each 16-byte beat, rather than raw SPI
shift time. An exact sampled-range comparison against
`SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2` passed. This path is intended for
inspection and integrity checks, not bulk sample transport.

### Diagnostic Interval And Pressure Test

Interface version 14 replaces the old command-FIFO debug write register with
interval-oriented diagnostics. Define a measurement interval by clearing the
counters immediately before the workload, then read the diagnostic registers
after it stops:

```bash
python3 tools/ch347_tool.py --device 0 --clock-hz 30000000 \
  clear-diagnostics --verify
python3 tools/ch347_tool.py --device 0 --clock-hz 30000000 \
  read PIPELINE_LATENCY_MAX AUDIO_FIFO_DIAGNOSTICS AUDIO_LEAD \
  COMMAND_ERROR_COUNT STALE_GENERATION_COUNT
```

`DIAGNOSTIC_CONTROL.CLEAR` clears sticky event flags, event counters, latency
maxima, command/stale-generation counters, sample-window statistics, and the
audio FIFO minimum. It deliberately preserves voices, parser state, FIFO
contents, cache contents, and playback. Each CH347 read is a separate mailbox
transaction, so a group of live values is not an atomic snapshot. Stop or
quiesce the workload when exact cross-register identities matter. See
[`../register_map.md`](../register_map.md) for field definitions.

The v14 image with SHA-256
`fed441cc14e63d01d7e522ef2b99d1f37a41731ed0e46e7b7af031a9b43e5b5f`
was loaded into volatile FPGA configuration SRAM and checked through CH347 at
30 MHz. `VERSION` returned `0x000e0000`; access to removed address `0x903c`
returned a bus error. One deliberately invalid zero-length START command
produced exactly one command error, and the diagnostic clear returned the count
and flag to zero without resetting runtime state.

A static 320-note pressure workload reached 465 active hardware voices and ran
for three seconds before a deliberate hard stop. It reported no transport
errors, underruns, drops, or render deadlines. Maximum render latency was
31,516 system clocks (315.16 us at 100 MHz), maximum traced DDR response latency
was 59 clocks, and the minimum audio FIFO occupancy after playback start was 19
frames. The sample-window counters closed exactly:

```text
15,212,453 requests = 10,760,291 hits
                    + 1,505,533 refills
                    + 2,946,629 fallbacks
8,968,761 external-memory reads
1,505,068 cache evictions
157,611,913 cache-stall clocks
```

The hard stop left 34 stale-generation commands while queued work from stopped
voices drained; this is expected cleanup behavior for that stop method, not an
SPI transport error. A final diagnostic clear returned all interval statistics
to their idle values. This v14 image was programmed only into volatile FPGA
SRAM; at the time of this historical measurement, configuration Flash still
contained the preceding persistent image.

The repository's default 10-second `build/polyphony_stress_512.mid` was then
played in full with a one-second tail against the same SF2 and 30 MHz CH347
link. Unlike the static workload above, this MIDI continuously changes programs,
controllers, pitch bend, and notes. The host scheduled all 13,279 MIDI events,
dropped no note-on or replaceable MIDI events, drained normally, and reported
zero transport errors. It reached all 512 hardware voices, performed 4,716
voice steals, and accumulated 19,040 stale-generation rejections as superseded
voice work drained.

This dynamic workload exceeded the current render budget: it recorded 6,427
I2S underruns and 6,874 render deadline misses, with no sample drops. FIFO
occupancy reached zero. Maximum render latency was 43,040 clocks (430.4 us at
100 MHz), while maximum traced DDR response latency remained 59 clocks. The
sample-window accounting still closed exactly, and its external-memory read
count matched `MEM_RESPONSE_COUNT`:

```text
59,463,068 requests = 41,413,399 hits
                    + 5,311,818 refills
                    + 12,737,851 fallbacks
33,985,123 external-memory reads = 33,985,123 memory responses
5,311,771 cache evictions
625,946,375 cache-stall clocks
```

The contrast with the passing 320-note static interval isolates the severe
underrun to sustained full-allocation churn and renderer/cache scheduling, not
to CH347 command corruption or an unusually long individual DDR response. This
test currently documents an overload boundary; it is not a passing polyphony
qualification.

As a bounded PC comparison, the original device-only timed DDR3 model rendered
the first 200 ms of the same MIDI/SF2 workload. It reached 512 voices and
completed 9,600 frames in 600 blocks with zero deadline misses. Maximum render
time was only 29,966 clocks, exposing that the model did not include MIG
controller/UI/PHY completion latency. The static 465-voice interval had almost
the same cache traffic on the board and PC, but sample-window stalls were about
17,512 clocks per block on hardware versus 2,877 in the device-only model.

Adding 80 cycles at the model's 400 MHz DDR clock, equivalent to 20 cycles of
the 100 MHz MIG UI clock, matched the static hardware maximum within 69 clocks:
31,585 modeled versus 31,516 measured. With that calibration, the 200 ms PC run
reached 512 voices, reported a 43,633-clock maximum and 525 deadline misses in
600 blocks. This reproduces the board's 43,040-clock maximum and overload
direction without simulating the complete 10-second MIDI. The calibrated delay
is now the default `render-rtl-ddr3` Smart Artix profile; it can be overridden
with `DDR3_EXTRA_READ_CYCLES` for sensitivity experiments. The complete
methodology, sweep, MIG contract, and optimization implications are in
[`../verification/smart_artix_mig_latency_calibration.md`](../verification/smart_artix_mig_latency_calibration.md).

### 2026-08-02 Hedwig's Theme Long-Form MIDI Run

The format-1, 37-track `Hedwigs_Themefinished.mid` file was played from its
mounted source through `realtime_midi_host`, using the same SGM v2.01 SF2,
30 MHz CH347 link, v14 volatile bitstream, and a one-second tail. The diagnostic
interval was cleared and verified before playback. The host reached the MIDI's
natural end after approximately 222 seconds, shorter than the initial 272-second
estimate, then sent all-sound-off and drained normally.

The host scheduled all 27,850 MIDI events with no MIDI queue drops, transport
errors, abandoned commands, or read errors. It processed 13,855 note-on events,
of which 183 did not map to an SF2 region. The host allocator reached 512 active
mono voices, performed 592 voice steals, and returned to zero active voices.
Command-queue high water was 412 words; maximum command age was 12.384 ms and
maximum CH347 driver time was 0.713 ms.

Unlike the synthetic churn workload, this real composition remained inside the
hardware render budget despite its instantaneous 512-voice allocator peak:

| Metric | Result |
| --- | ---: |
| I2S underruns | 0 |
| Sample drops | 0 |
| Render deadline misses | 0 |
| Maximum render latency | 21,368 clocks, 64.1% of the 16-frame budget |
| Maximum traced DDR response latency | 59 clocks |
| Minimum audio FIFO occupancy after playback start | 23 frames |
| Command errors | 0 |
| Stale-generation rejections | 3,984 |

The stale-generation count is consistent with queued parameter work superseded
by voice steals and generation changes; it did not accompany a command or SPI
transport error. A 512-voice allocator peak is therefore not by itself an
overload qualification. Duration at high concurrency, region expansion,
phase increments, and cache locality determine the sustained render cost.

The long interval also closed both sample-window identities exactly:

```text
313,960,644 requests = 208,533,542 hits
                     + 37,606,708 refills
                     + 67,820,394 fallbacks
218,247,226 memory reads = 4 * 37,606,708 refills
                         + 67,820,394 fallbacks
37,606,708 cache evictions
3,581,076,657 cache-stall clocks
```

The hit, refill, and fallback shares were 66.42%, 11.98%, and 21.60%.
Sample-window stall averaged 11.41 clocks per accepted client request. The
effect and compressor frame/saturation counters were excluded from this song's
interval because `DIAGNOSTIC_CONTROL.CLEAR` intentionally does not clear them;
they remain cumulative from core reset.

After recording the snapshot, the diagnostic interval was cleared again.
Event, command/stale, and sample-window counters returned to zero. The render
latency maximum immediately began accumulating silent playback blocks, so a
small nonzero post-clear latency value is expected while the renderer remains
running.

After loading a valid sample range, exercise the atomic command path separately:

```bash
python3 tools/ch347_tool.py --device 0 --clock-hz 1000000 wait asset
python3 tools/ch347_tool.py --device 0 --clock-hz 1000000 voice-smoke \
  --voice 0 --base 0x00000000 --length 48000 --phase-inc 0x100
```

The command supports only the current mono hardware voice contract. It verifies
that the command FIFO and parser drain without command/stale-generation errors,
waits for memory-response activity, rejects new underrun/drop/deadline flags,
and sends a matching STOP command before returning. Linked stereo must use two
mono voices through the application control layer; it is not a bring-up runner
option.

## SD Raw Image Bring-Up

The first product path uses a raw SD image, not a live filesystem. Sector 0 holds
a `WTSF` header; the SF2 byte image starts at the header-provided LBA and is copied
into DDR3 without byte repacking.

The loader currently targets SDHC and SDXC cards:

- SD v2 voltage/check pattern through `CMD8`.
- high-capacity request through `CMD55/ACMD41` with HCS.
- native-mode card identification and selection through `CMD2`, `CMD3`, and
  R1b-aware `CMD7`.
- card-side DAT3 detect-pull-up removal through `CMD55/ACMD42`, followed by
  4-bit data mode through `CMD55/ACMD6`.
- CMD6 mode-0 capability discovery and validated mode-1 High Speed selection,
  clocked at 50 MHz after selection, with 25 MHz Default Speed fallback. The
  implemented 50 MHz path is post-route closed and demonstrated on the recorded
  board/card bench; production electrical margins remain to be measured.
- SCR capability discovery through `CMD55/ACMD51`; multi-block `CMD18` reads use
  optional `CMD23` only when advertised, otherwise terminate with `CMD12`.
- bounded `CMD17` recovery from a failed CMD18 block without repeating previously
  committed blocks.

### 2026-08-02 SD Hardware Diagnosis

The complete chronological investigation, including failed IDDR approaches,
constraint-query pitfalls, detailed post-route paths, and reproduction commands,
is preserved in
[`smart_artix_sd_50mhz_debug.md`](smart_artix_sd_50mhz_debug.md). This section is
the concise bring-up result.

The SD socket and all SD signal traces in this experiment are board-level
routing, not flywires. The card was a genuine 32 GB SDHC card without a WTSF
image, which makes an invalid-magic loader result the expected end condition
after a successful sector-0 read.

The native reader initially rejected the real card's CMD3 R6 response with SD
error `14`. R6 reports the card state when CMD3 is received, so the expected
state is Identification (`2`), not the post-command Standby state (`3`). After
correcting that check, the following two otherwise equivalent fresh images were
measured:

| Image SHA-256 | Selected SD mode | SD line clock | Hardware result |
| --- | --- | ---: | --- |
| `5b19ae16680112528a789d351237009a3edf3edd5e564619523de4302893d5ec` | High Speed | 50 MHz | `PLATFORM_ERRORS=0x00220008`: CMD17 failed after two retries |
| `e425a2882fbe821bf1ffbdda337e81c772291d92e0ba226994537052a61f3ef5` | High Speed | 25 MHz | `PLATFORM_ERRORS=0x000f0100`: SD error 0, loader error 1 (invalid WTSF magic) |
| `bdcfda91c30921cf336c7cf104d36e58ce22399f192a405ea018bce1a2098c13` | High Speed | 50 MHz | post-route IOB capture fix; two FPGA starts both returned `PLATFORM_STATUS=0x00018057`, `PLATFORM_ERRORS=0x000f0100` |

The 25 MHz image reported `PLATFORM_STATUS=0x00018057`: DDR calibrated, card
present, SD initialized, and High Speed mode selected. The asset loader stopped
in its error state because sector 0 did not contain WTSF magic, as expected.
Direct DDR access in the same run wrote and exactly read back
`fedcba98_76543210_89abcdef_01234567` at byte address `0x100`.

The original A/B result localized the problem to the 50 MHz pin path. The final
image adds single-edge input IOB capture over a complete 20 ns SD period, output
IOB registers, a generated SD clock, and scoped external timing constraints.
Post-route input setup/hold were `+0.965 ns`/`+13.902 ns`; CMD setup was
`+1.545 ns`. Two programming cycles then qualified native SD initialization and
a single-block sector-0 read at 50 MHz on this board/card combination. Electrical
waveform and multi-card production margin remain unmeasured.

The socket's `SD_CD` switch is active low on U17. Insertion is synchronized and
debounced, followed by a 1 ms stable-power wait and at least 80 startup clocks.
Removal resets the SD and asset-loader session. A replacement card therefore
starts from 400 kHz initialization even if the previous card reached 50 MHz.

Do not use SDSC cards for the first bring-up path. The RTL intentionally does not
implement the byte-addressed SDSC fallback.

### 2026-08-03 Full SF2 Load Throughput

The physical 32 GB SDHC card carried the 324,800,670-byte
`SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2` WTSF payload. CH347 polling at 30 MHz
measured `PLATFORM_BYTES_LOADED` from the first in-progress sample until it
equaled `PLATFORM_SF2_SIZE`; this avoids assigning FPGA configuration, DDR
calibration, or SD initialization time to the payload transfer.

| Reader configuration | Maximum CMD18 extent | Measured load time | Effective payload rate |
| --- | ---: | ---: | ---: |
| Original one-bank path | 16 blocks / 8 KiB | approximately 35 s by LED timing | approximately 8.9 MiB/s |
| Two-bank 1 KiB RAM, short extent | 16 blocks / 8 KiB | 33.559550 s | 9.230 MiB/s |
| Two-bank 1 KiB RAM, production extent | 256 blocks / 128 KiB | 14.720993 s | 21.035 MiB/s |

The small change from the first to second row shows that DDR draining was not the
dominant 35-second cost. Increasing the CMD23/CMD18 extent reduced the number of
command and first-data-token starts by approximately 16 times and produced the
material gain. CMD23 helps the card plan and terminate the counted multi-block
read, but does not change the 4-bit 50 MHz wire limit of 25 MB/s (23.84 MiB/s).
The final measured payload rate is about 88% of that wire limit. Synthesis mapped
the two 512-byte banks to one `1 K x 8` RAMB18, not a 128 KiB on-chip buffer.

At completion, `PLATFORM_STATUS=0x00018035` and
`PLATFORM_ERRORS=0x00050000`: loader state 5 (loaded), SD error 0, loader error
0, retry count 0, and recovery error 0. Therefore CRC retries did not explain
the original load time. A seeded CH347 comparison of 128 distributed 16-byte DDR
beats against the source SF2 covered a 324,800,656-byte aligned span and reported
zero mismatches. A second snapshot after booting the same image from configuration
Flash again showed the complete size, High Speed active, and all error/retry
fields clear.

Generate and check the raw image on the host before inserting the card:

```bash
make wtsf-image SF2=assets/soundfonts/MT6276.sf2
make verify-wtsf-image
```

The default output is `build/assets/wavetable.wtsf.img`. To write an SDHC/SDXC
card, pass the whole-card block device, not a partition:

```bash
make flash-wtsf-sd SD_DEVICE=/dev/sdX
```

The burn script refuses mounted devices and requires `SD_DEVICE` because the write
destroys the target card contents. Use `lsblk` before running it if more than one
removable drive is connected.

Expected successful load signs:

- `PLATFORM_STATUS[2] = 1`: DDR calibration complete.
- `PLATFORM_STATUS[4] = 1`: SD initialized.
- `PLATFORM_STATUS[5] = 1`: asset loaded.
- `PLATFORM_STATUS[1] = 0`: no SD or loader error.
- `PLATFORM_BYTES_LOADED == PLATFORM_SF2_SIZE`.

If loading fails:

- Check SD card voltage, pull-ups, and pin mapping first.
- Check whether the card is SDHC or SDXC.
- Read `PLATFORM_ERRORS` to separate SD protocol failure from raw-header or DDR
  writer failure.
- Watch `PLATFORM_CURRENT_LBA` to see whether the loader reached data sectors or
  failed near initialization/header parsing.

## First I2S Test

Do not connect a power amplifier for the first I2S test. Use a scope, logic
analyzer, or codec input with safe gain first.

For the Raspberry Pi Pico capture path, use the complete SPI/I2S wiring table,
USB checks, and Clock Validity troubleshooting in
[`../mcu/rp2040_firmware.md`](../mcu/rp2040_firmware.md). The table below remains
the FPGA-side I2S pin contract.

The current bitstream routes the three 3.3 V `LVCMOS33` outputs to adjacent
BANK15 expansion-header pins:

| Signal | FPGA pin | BANK15 header pin |
| --- | --- | ---: |
| `i2s_bclk` | `G16` | 5 |
| `i2s_lrclk` | `G15` | 6 |
| `i2s_sdata` | `H15` | 7 |

The header pin table does not identify a ground pin on this connector. Provide
a verified common board ground from a power connector or test point; do not use
header pins 37/38 (`VCC3V3`) or 39/40 (`5V_DC`) as ground.

The stream is Philips I2S, 48 kHz stereo with two 16-bit slots and a 1.536 MHz
BCLK. LRCLK changes one BCLK before the next word MSB. SDATA and LRCLK change on
BCLK falling edges and are intended to be sampled on rising edges. The current
top exports no MCLK, codec configuration, reset, or mute signal.

Check these signals:

- `i2s_bclk` toggles continuously after playback reset is released.
- `i2s_lrclk` runs at the configured sample rate, currently `48 kHz`.
- `i2s_sdata` is initially quiet or low before a voice is programmed.
- After one voice is committed, `i2s_sdata` becomes non-static.

The board assumption is a simple I2S codec with no register initialization and no
MCLK requirement. If the actual codec needs MCLK, reset, mute, or register setup,
add those to the board wrapper before treating silence as a core bug.

## First Voice Programming

After `asset_loaded` is set, program a single conservative voice through SPI.
Start with:

- one voice slot, usually slot 0.
- mono playback.
- no loop.
- filter bypassed.
- envelope stage/flags `0x004c_0000` and attenuation `0x0000_0000`.
- left and right gain around `0x2000` or lower for external audio safety.
- a known valid `BASE_ADDR` and `LENGTH` from the loaded SF2 sample metadata.

The command payload and ordering are documented in
`../command_stream.md`. Inspect command/parser state through
`CMD_FIFO_STATUS`.

If audio is silent after `VOICE_START_MONO`:

- Read `SYSTEM_STATUS`, `COMMON_EVENT_FLAGS`, and `PIPELINE_LATENCY_STATUS`.
- Check the sample-window counters at `0x9160` through `0x9178` for hits,
  refills, fallback reads, external reads, evictions, and stalls.
- Check `COMMON_EVENT_FLAGS` for underrun, sample drop, or render deadline miss.
- Confirm the programmed `BASE_ADDR` includes the SF2 `smpl` payload offset and is
  expressed as a 16-bit word address.
- Confirm `LENGTH` is nonzero and loop fields are valid for the selected loop
  mode.

## Fault Isolation

Use this order when a stage fails:

| Symptom | Likely area | First checks |
| --- | --- | --- |
| FPGA does not program | JTAG, power, part selection | Cable, target voltage, Vivado device list, part name. |
| No SPI response | DDR/MIG clock, SPI pins, reset | MIG calibration, `ui_clk`, `rst_n`, SPI mode, CS polarity, SCLK rate. |
| `PLATFORM_STATUS[2] = 0` | DDR3/MIG | DDR pins, MIG `.prj`, clock wizard, reset, board DDR power. |
| `PLATFORM_STATUS[4] = 0` | SD init | SD pins, pull-ups, card type, clock divider, voltage. |
| `PLATFORM_STATUS[1] = 1` | SD or loader | Decode `PLATFORM_ERRORS`, check raw image header and current LBA. |
| `asset_loaded = 1` but no memory responses | DDR read path | DDR arbiter, line reader, voice base address, memory status counters. |
| Memory responses but silent I2S | voice configuration or I2S | gains, envelope, length, loop mode, codec wiring, LRCLK/BCLK. |
| I2S underruns or deadline misses | throughput | active voice count, DDR latency, output FIFO level, external line request rate. |

## Suggested Milestones

Record each board result in `../../fpga/smart_artix/README.md` or a dated lab log.
Use these milestones as the first checklist:

1. Bitstream generated with all top-level I/O constrained.
2. Board programs over JTAG.
3. MIG DDR3 calibration completes.
4. SPI can read `VERSION` and `PLATFORM_STATUS`.
5. SD card initializes.
6. Raw `WTSF` header parses without loader error.
7. `bytes_loaded == sf2_size_bytes` and `asset_loaded = 1`.
8. A single no-loop mono voice causes memory reads and non-static I2S data.
9. I2S BCLK/LRCLK timing is measured against the codec requirements.
10. Audio output is audible at safe gain with no sustained underrun, sample-drop,
    or render-deadline flags.
