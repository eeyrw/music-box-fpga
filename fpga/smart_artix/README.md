# Smart Artix XC7A50T Target

This directory is the first board-specific integration workspace for the Smart
Artix minimum system board. It is intentionally a synthesis/bring-up skeleton:
pin locations, exact clocking, and DDR3 MIG files must be filled in from the
board schematic and Vivado-generated IP before implementation.

## Known Board Facts

- FPGA family target: Xilinx Artix-7, planned as `XC7A50T`.
- External wave memory: Micron `MT41K256M16TW` DDR3.
- DDR3 capacity and width: `256M x 16-bit`, total `512 MB`.
- DDR3 FPGA bank: `BANK34`.
- Control interface: external MCU or PC USB-to-SPI adapter.
- Audio codec: I2S only, no register initialization, no MCLK requirement.

Still required from the board documentation:

- Exact FPGA package and speed grade.
- Input oscillator frequency.
- Reset source and polarity.
- SPI, I2S, LED, and DDR3 pin locations.
- I/O standards and bank voltages.
- Target DDR3 clock rate and MIG configuration.

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

## Bring-Up Order

1. Fill in FPGA part, clock, reset, and non-DDR pins in `constraints/smart_artix.xdc`.
2. Run Vivado synthesis to measure generic core resource use on `XC7A50T`.
3. Add clock generation for the selected system/audio clock.
4. Verify I2S `BCLK`, `LRCLK`, and `SDATA` pins with a scope or logic analyzer.
5. Add a tiny BRAM-backed line-memory test source for one known waveform.
6. Generate MIG for `MT41K256M16TW` and add a read-only DDR3 line-reader adapter.
7. Add the SD raw-image loader path: SD sector stream, asset header parser, and
   DDR3 write DMA.

## Vivado Batch Skeleton

After replacing placeholders in the Tcl script and XDC file, run:

```bash
vivado -mode batch -source scripts/vivado_synth.tcl
```

Generated Vivado output should stay under `fpga/smart_artix/build/` and should
not be committed.

## Local Checks

Run the board top lint from this directory:

```bash
verilator --lint-only --Wall -Wno-fatal --top-module smart_artix_top -f filelist.f
```

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
