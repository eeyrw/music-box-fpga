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
  -> Xilinx MIG app interface
  -> MT41K256M16TW
```

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
7. Add a DDR3 asset-loading path after read-only playback is proven.

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
