# Smart Artix XC7A50T Target

This directory is the first board-specific integration workspace for the Smart
Artix minimum system board. It is intentionally a synthesis/bring-up skeleton:
pin locations, exact clocking, and DDR3 MIG files must be filled in from the
board schematic and Vivado-generated IP before implementation.

## Known Board Facts

- FPGA family target: Xilinx Artix-7, planned as `XC7A50T`.
- FPGA device reported by the board owner: `XC7A50T-2FGG484I`.
- Vivado 2018.3 part name: `xc7a50tfgg484-2`. Vivado does not encode the
  industrial temperature suffix in the part name used by `create_project`.
- External wave memory: Micron `MT41K256M16TW` DDR3.
- DDR3 capacity and width: `256M x 16-bit`, total `512 MB`.
- DDR3 FPGA bank: `BANK34`.
- Control interface: external MCU or PC USB-to-SPI adapter.
- Audio codec: I2S only, no register initialization, no MCLK requirement.
- Board oscillator: `50 MHz`.
- Generated clock wizard: `clk_wiz_0`, currently `50 MHz` input to `200 MHz`
  output.
- Generated MIG IP: `mig_7series_0` under
  `music-box-fpga.srcs/sources_1/ip/mig_7series_0`.

Still required from the board documentation:

- Reset source and polarity.
- SPI, I2S, LED, and DDR3 pin locations.
- I/O standards and bank voltages.
- Target DDR3 clock rate and MIG configuration.
- Audio codec timing limits and whether MCLK, reset, mute, or codec register
  configuration pins are actually needed.

## Current Top

`rtl/smart_artix_top.sv` instantiates `wavetable_core_system` with the current
SPI-control, line-memory, output FIFO, and I2S path. It also instantiates
`smart_artix_ddr3_line_reader` and a small `smart_artix_mig_stub` so the read
path can lint and simulate before Vivado MIG is generated.

The intended memory replacement is:

```text
wavetable_core_system external line-read pins
  -> smart_artix_ddr3_line_reader
  -> smart_artix_ddr3_rw_arbiter
  -> Xilinx MIG app interface
  -> MT41K256M16TW
```

The SD raw-image loading path is implemented as reusable board RTL but is not yet
connected to `smart_artix_top` because the SD bit-level SPI master, real MIG
instance, and read/write arbitration policy still need board-specific decisions:

```text
SD SPI pins: CLK, CMD/MOSI, DAT0/MISO, DAT3/CS
  -> smart_artix_sd_spi_byte_master
  -> smart_artix_sd_spi_block_reader
  -> smart_artix_sd_ddr3_asset_loader
  -> MIG app write interface
```

The SD SPI path intentionally implements only the raw-sector subset needed for
asset loading. It borrows LiteSDCard's command/data separation but omits filesystem
logic, write commands, DMA frontends, and native 4-bit timing. The SPI electrical
connection is direct FPGA I/O; `PHY` here means the small RTL layer that shifts and
samples the pins, not an external chip.

A matching native 4-bit command-level reader is also present:

```text
native SD pins: CLK, CMD, DAT[3:0]
  -> smart_artix_sd_native_pin_phy
  -> smart_artix_sd_native_block_reader
  -> smart_artix_sd_ddr3_asset_loader
  -> smart_artix_ddr3_rw_arbiter
  -> MIG app write interface
```

The native reader initializes SDHC/SDXC cards, selects the assigned RCA, switches
to 4-bit bus mode with `ACMD6`, and issues single-block `CMD17` reads. The native
pin PHY drives `SD_CLK`, transmits commands with CRC7, releases/captures the `CMD`
line for responses, receives `DAT[3:0]` as a byte stream, and checks each data
line's CRC16 before releasing the final byte of a block.

The initialization policy follows the same practical sequence used by small FPGA
SD readers, but narrowed to SDHC/SDXC: `CMD0`, `CMD8`, retrying `CMD55/ACMD41`
with HCS, then either `CMD58` for SPI mode or `CMD2/CMD3/CMD7` plus
`CMD55/ACMD6` for native 4-bit mode. SDv1/SDSC and `CMD16` fallback remain out of
scope for this loader path. The native pin asset-loader wrapper has separate
`sd_init_clk_div` and `sd_transfer_clk_div` inputs and switches to the transfer
divider after the SD reader reports initialization complete.

An optional `smart_artix_fat_file_reader` can sit above either SD block reader when
bring-up needs to load an 8.3-named file from a FAT16/FAT32 root directory. It
keeps the same sector-stream boundary as the raw-image loader and deliberately
does not implement long filenames or subdirectories yet.

## DDR3 Line-Reader Assumptions

The first `smart_artix_ddr3_line_reader` skeleton targets the 7-series MIG native
application read interface:

- `app_cmd = 3'b001` is treated as a read command.
- `app_en && app_rdy` accepts one aligned read command.
- `app_rd_data_valid && app_rd_data_end` returns one complete memory line.
- Default `MIG_DATA_WIDTH` is `128` bits, matching `LINE_WORDS = 8` 16-bit PCM
  words.
- The core-side address is a 16-bit word address. `WORD_ADDR_SHIFT = 1` converts
  it to a byte-addressed MIG app address.

If the generated MIG uses a different app data width, address unit, burst mode,
or clocking scheme, update the adapter before connecting hardware. The current
adapter assumes one MIG read response contains the whole line.

`smart_artix_mig_stub` is not a DDR3 timing model. It only provides a calibration
delay, accepts one read command at a time, and returns a deterministic 128-bit
pattern after a fixed latency. Replace it with the generated MIG instance for any
hardware build that needs real DDR3 pins.

Board reference files such as schematics belong under `docs/`. They are kept as
source material for later pin and constraint work, not as synthesis inputs.

## Current Vivado 2018.3 Status

Vivado is installed locally under `/opt/Xilinx/Vivado/2018.3`. The batch flow in
`scripts/vivado_synth.tcl` now creates a project for `xc7a50tfgg484-2`, reads
`filelist.f`, applies `constraints/smart_artix.xdc`, synthesizes
`smart_artix_top`, reads generated IP when present, writes
`build/vivado/post_synth.dcp`, and emits utilization and timing reports.

Run the current synthesis check from this directory with:

```bash
/opt/Xilinx/Vivado/2018.3/bin/vivado -mode batch -source scripts/vivado_synth.tcl
```

The non-DDR XDC currently contains temporary package pins selected only to let
Vivado run early synthesis and timing checks. These pins are legal user I/O for
the package, but they are not verified against the Smart Artix schematic and must
not be used to connect real hardware. The temporary non-DDR I/O standard is
`LVCMOS33`, and the primary board clock is constrained to `20.000 ns` for the
confirmed `50 MHz` oscillator. DDR3 pins come from the generated MIG XDC.

`DDRPIN.ucf` is kept as the board-provided DDR pin reference. It is not consumed
directly by the Vivado batch flow; use it when checking or regenerating the MIG
pin configuration, then let MIG emit the final DDR3 XDC.

The current board top instantiates `clk_wiz_0` and `mig_7series_0` when the
generated IP configuration is present. The source-controlled IP inputs are the
Clocking Wizard `.xci`, the MIG `.xci`, and the MIG `.prj` file referenced by
that `.xci`; generated Verilog, checkpoints, project files, and reports remain
local Vivado output. `smart_artix_mig_stub` remains in the repository for unit
tests and non-Vivado simulation, but it is no longer used by `smart_artix_top`.

Important clocking issue: the generated `clk_wiz_0` produces `200 MHz` from the
board's `50 MHz` oscillator, but the generated MIG project currently records
`InputClkFreq = 333.333 MHz`, `TimePeriod = 3000 ps`, and `PHYRatio = 2:1`.
The latest MIG wrapper has no separate `clk_ref_i` port, so `smart_artix_top`
feeds the available `200 MHz` clock directly to MIG `sys_clk_i`. Before any real
DDR3 bring-up, confirm whether this regenerated MIG is intended to use a
`200 MHz` input despite the project file still recording `333.333 MHz`. If not,
fix this one of two ways:

1. Regenerate `clk_wiz_0` with two outputs: `333.333 MHz` for MIG `sys_clk_i`
   if the MIG remains configured for that input frequency.
2. Regenerate `mig_7series_0` so its input clock frequency matches the available
   `200 MHz` system clock, if that is a valid MIG setting for the selected DDR3
   rate.

Do not expect DDR3 calibration to pass on hardware until the MIG `sys_clk_i`
frequency matches the MIG project setting.

The latest generated MIG native app interface is `128` bits wide with a `29` bit
app address. The board top therefore uses `LINE_WORDS = 8` so one MIG read beat
contains one complete wavetable cache line.

Latest post-synthesis result with `clk_wiz_0`, `mig_7series_0`, the generated MIG
XDC, and the read-only line-reader path connected:

```text
Design: smart_artix_top
Device: 7a50tfgg484-2
Vivado result: synth_design completed successfully
Errors: 0
Critical warnings: 0
Warnings: 205
```

The warning count is left visible instead of suppressed. It currently includes
generated IP messages plus expected early board-level timing gaps while the MIG
input clock and external SPI/I2S timing contracts are still unresolved.

Post-synthesis utilization:

```text
Slice LUTs       26695 / 32600  81.89%
Slice Registers 49965 / 65200  76.63%
DSP48E1             26 / 120    21.67%
Block RAM tiles      0 / 75      0.00%
Bonded IOB          61 / 250    24.40%
```

Post-synthesis timing does not meet constraints yet:

```text
WNS  -11.098 ns
TNS  -2195.276 ns
Failing setup endpoints: 574
WHS  -1.329 ns
THS  -23.799 ns
Failing hold endpoints: 90
No unclocked registers
No unconstrained internal endpoints
```

Treat this timing result as a clocking/configuration warning until the MIG input
frequency and final audio/system clock plan are settled.

The first timing pressure is expected around the voice pipeline multiply and wide
accumulation paths. Vivado also reports that several wide multipliers do not have
the two pipeline stages it recommends. Before treating this as a board-blocking
failure, run full implementation after real pins and clocking are known; then, if
timing still fails, prefer adding focused pipeline stages in
`rtl/voice/multi_voice_pipeline.sv` over changing board constraints to hide the
path.

The timing report also shows expected board-level gaps: SPI input ports and I2S
or debug output ports do not yet have external input/output delays. Add those
only after the real board timing contract is known.

## Bring-Up Order

1. Replace the temporary non-DDR XDC package pins with schematic-verified Smart Artix
   pins before connecting hardware.
2. Fix or confirm the MIG clocking mismatch: provide `333.333 MHz` to MIG
   `sys_clk_i` if the MIG expects it, or regenerate/verify MIG for the available
   `200 MHz` input clock.
3. Decide the final audio/system clock strategy. Running the synth core on MIG
   `ui_clk` keeps the first integration single-clock but does not naturally
   produce exact 48 kHz I2S unless `SYS_CLK_HZ` and dividers are adjusted.
4. Add real reset conditioning and document reset polarity.
5. Add SPI mode, maximum SCLK, CDC, and input-delay constraints for the selected
   control source.
6. Add I2S output delay constraints from the codec timing limits, then verify
   `BCLK`, `LRCLK`, and `SDATA` with a scope or logic analyzer.
7. Add a tiny BRAM-backed line-memory test source for one known waveform.
8. Re-run Vivado synthesis and implementation with real MIG and real pin
   constraints; record resource and timing changes here.
9. Add the SD raw-image loader path: SD sector stream, asset header parser, and
   DDR3 write DMA.

## Vivado Batch Flow

Run:

```bash
vivado -mode batch -source scripts/vivado_synth.tcl
```

Generated Vivado output should stay under `fpga/smart_artix/build/` and should
not be committed.

The current flow stops after synthesis. Add `opt_design`, `place_design`,
`route_design`, implementation reports, and bitstream generation only after the
temporary pins are replaced with real schematic pins. Generating a bitstream with
the temporary XDC is useful only as a tool-flow experiment, not for board use.

## Local Checks

Run the board top lint from this directory:

```bash
verilator --lint-only --Wall -Wno-fatal --top-module smart_artix_top -f filelist.f
```

This pure Verilator lint is only valid for the older stubbed board top. The
current `smart_artix_top` instantiates Vivado IP directly, so use the Vivado
batch synthesis command above for board-top checking and keep the unit tests
below for non-vendor board RTL.

Run the DDR3 line-reader unit test from this directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/line_reader_obj_dir \
  --top-module tb_smart_artix_ddr3_line_reader \
  rtl/smart_artix_ddr3_line_reader.sv sim/tb_smart_artix_ddr3_line_reader.sv
build/line_reader_obj_dir/Vtb_smart_artix_ddr3_line_reader
```

Run the temporary MIG stub unit test from this directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/mig_stub_obj_dir \
  --top-module tb_smart_artix_mig_stub \
  rtl/smart_artix_mig_stub.sv sim/tb_smart_artix_mig_stub.sv
build/mig_stub_obj_dir/Vtb_smart_artix_mig_stub
```

Run the DDR3 asset-writer unit test from this directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/asset_writer_obj_dir \
  --top-module tb_smart_artix_ddr3_asset_writer \
  rtl/smart_artix_ddr3_asset_writer.sv sim/tb_smart_artix_ddr3_asset_writer.sv
build/asset_writer_obj_dir/Vtb_smart_artix_ddr3_asset_writer
```

Run the DDR3 read/write arbiter unit test from this directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/ddr3_rw_arbiter_obj_dir \
  --top-module tb_smart_artix_ddr3_rw_arbiter \
  rtl/smart_artix_ddr3_rw_arbiter.sv sim/tb_smart_artix_ddr3_rw_arbiter.sv
build/ddr3_rw_arbiter_obj_dir/Vtb_smart_artix_ddr3_rw_arbiter
```

Run the raw-image asset-loader unit test from this directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/asset_loader_obj_dir \
  --top-module tb_smart_artix_asset_loader \
  rtl/smart_artix_asset_loader.sv sim/tb_smart_artix_asset_loader.sv
build/asset_loader_obj_dir/Vtb_smart_artix_asset_loader
```

Run the SD SPI block-reader protocol unit test from this directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/sd_spi_reader_obj_dir \
  --top-module tb_smart_artix_sd_spi_block_reader \
  rtl/smart_artix_sd_spi_block_reader.sv sim/tb_smart_artix_sd_spi_block_reader.sv
build/sd_spi_reader_obj_dir/Vtb_smart_artix_sd_spi_block_reader
```

Run the FAT file-reader unit test from this directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/fat_file_reader_obj_dir \
  --top-module tb_smart_artix_fat_file_reader \
  rtl/smart_artix_fat_file_reader.sv sim/tb_smart_artix_fat_file_reader.sv
build/fat_file_reader_obj_dir/Vtb_smart_artix_fat_file_reader
```

Run the native SD command-level reader unit test from this directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/sd_native_reader_obj_dir \
  --top-module tb_smart_artix_sd_native_block_reader \
  rtl/smart_artix_sd_native_block_reader.sv sim/tb_smart_artix_sd_native_block_reader.sv
build/sd_native_reader_obj_dir/Vtb_smart_artix_sd_native_block_reader
```

Run the native SD reader against the fake-card command/data model from this
directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/sd_native_fake_obj_dir \
  --top-module tb_smart_artix_sd_native_block_reader_fake \
  rtl/smart_artix_sd_native_block_reader.sv \
  sim/fake_sd_native_phy_model.sv \
  sim/tb_smart_artix_sd_native_block_reader_fake.sv
build/sd_native_fake_obj_dir/Vtb_smart_artix_sd_native_block_reader_fake
```

Run the native SD pin-level PHY unit test from this directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/sd_native_pin_phy_obj_dir \
  --top-module tb_smart_artix_sd_native_pin_phy \
  rtl/smart_artix_sd_native_pin_phy.sv sim/tb_smart_artix_sd_native_pin_phy.sv
build/sd_native_pin_phy_obj_dir/Vtb_smart_artix_sd_native_pin_phy
```

Run the native SD pin-level fake-card transport test from this directory:

```bash
verilator --binary --timing --Wall -Wno-fatal \
  --Mdir build/sd_native_pin_fake_obj_dir \
  --top-module tb_smart_artix_sd_native_pin_phy_fake \
  rtl/smart_artix_sd_native_pin_phy.sv \
  sim/fake_sd_native_pin_model.sv \
  sim/tb_smart_artix_sd_native_pin_phy_fake.sv
build/sd_native_pin_fake_obj_dir/Vtb_smart_artix_sd_native_pin_phy_fake
```
