# Smart Artix XC7A50T Target

This directory is the board-specific integration workspace for the Smart Artix
minimum system board. The RTL connects SPI control, native-SD asset loading,
DDR3-backed wavetable reads, and I2S output. The native-SD pins and the
project-selected SPI/I2S expansion-header pins have been checked against the
board pin table and schematic. External timing, BANK15 voltage, wiring, and
signal integrity still require qualification before hardware signoff. The
source-controlled Vivado flow already generates and implements the Clocking
Wizard and DDR3 MIG configuration.

Use [`../../docs/board/smart_artix_bringup.md`](../../docs/board/smart_artix_bringup.md) as
the practical hardware bring-up checklist.
Use [`../../docs/board/smart_artix_io_constraints_backlog.md`](../../docs/board/smart_artix_io_constraints_backlog.md)
for SPI, native-SD, and I2S constraint analysis and completion gates.

## Known Board Facts

- FPGA family target: Xilinx Artix-7 `XC7A50T`.
- FPGA device reported by the board owner: `XC7A50T-2FGG484I`.
- Vivado 2018.3 part name: `xc7a50tfgg484-2`. Vivado does not encode the
  industrial temperature suffix in the part name used by `create_project`.
- External wave memory: Micron `MT41K256M16TW` DDR3.
- DDR3 capacity and width: `256M x 16-bit`, total `512 MB`.
- DDR3 FPGA bank: `BANK34`.
- Control interface: external MCU or PC USB-to-SPI adapter.
- Audio codec: I2S only, no register initialization, no MCLK requirement.
- Board oscillator: `50 MHz`.
- Generated clock wizard: `smart_artix_clk_50m_to_200m`, currently `50 MHz` input to `200 MHz`
  output.
- Generated MIG IP source configuration: `vivado/ip/smart_artix_ddr3_mig`.

Still required from peripheral documentation or hardware measurements:

- Reset source and polarity.
- Confirmation that BANK15 `VCCIO_ADJ` is 3.3 V before using the selected SPI
  and I2S expansion pins as `LVCMOS33`.
- External SPI and I2S timing limits.
- Audio codec timing limits and whether MCLK, reset, mute, or codec register
  configuration pins are actually needed.

## Current Top

`rtl/smart_artix_top.sv` instantiates `wavetable_demo_system` with SPI control,
line-memory caching, output FIFO, and I2S output. Board-specific SD loading, DDR3
read/write arbitration, line reads, and DDR register access traffic are grouped behind
`smart_artix_ddr3_subsystem`; Smart Artix platform registers are implemented by
`smart_artix_platform_regs` through the common wrapper's platform register window
bus. After MIG calibration completes, the top starts the SD loader, copies the
raw SF2 byte image into DDR3, and holds the audio core in reset until
`asset_loaded` is asserted.

The intended memory replacement is:

```text
SD native pins: CLK, CMD, DAT[3:0], active-low CD
  -> smart_artix_ddr3_subsystem
  -> sd_native_pin_phy
  -> smart_artix_sd_native_asset_loader
  -> sd_native_block_reader
  -> smart_artix_asset_loader
  -> smart_artix_ddr3_asset_writer
  -> smart_artix_ddr3_rw_arbiter
  -> Xilinx MIG app write interface
  -> MT41K256M16TW

wavetable_demo_system external line-read pins
  -> smart_artix_ddr3_subsystem
  -> smart_artix_ddr3_line_reader
  -> smart_artix_ddr3_rw_arbiter
  -> Xilinx MIG app read interface
  -> MT41K256M16TW
```

The raw-image asset format is documented in `../../docs/board/asset_loading.md`. Sector 0
contains the `WTSF` header; the SF2 byte image is copied into DDR3 without byte
repacking so software can keep using absolute SF2 `smpl` offsets in voice
definition commands.

The native 4-bit path is connected to `smart_artix_top`:

```text
native SD pins: CLK, CMD, DAT[3:0], active-low CD
  -> sd_native_pin_phy
  -> smart_artix_sd_native_asset_loader
  -> sd_native_block_reader
  -> smart_artix_asset_loader
  -> smart_artix_ddr3_asset_writer
  -> smart_artix_ddr3_rw_arbiter
  -> MIG app write interface
```

The native reader initializes SDHC/SDXC cards, selects the assigned RCA with
R1b busy handling, disconnects the DAT3 detect pull-up with `ACMD42`, switches
to 4-bit bus mode with `ACMD6`, queries and validates High Speed with `CMD6`, and
reads SCR with `ACMD51`. Loader requests larger than one block use `CMD18`;
`CMD23` is issued only when SCR advertises it, while unsupported or rejected
CMD23 falls back to CMD18 followed by R1b-aware `CMD12`. Failed CMD18 blocks are
stopped and retried from the failed LBA with bounded `CMD17`. The native
pin PHY drives `SD_CLK`, transmits commands with CRC7, releases/captures the `CMD`
line for responses, receives `DAT[3:0]` as a byte stream, and checks each data
line's CRC16 before releasing the final byte of a block.

The initialization policy follows the same practical sequence used by small FPGA
SD readers, but narrowed to SDHC/SDXC: `CMD0`, `CMD8`, retrying `CMD55/ACMD41`
with HCS, then `CMD2/CMD3/CMD7` plus `CMD55/ACMD6` for native 4-bit mode and
CMD6 mode-0/mode-1 negotiation for optional High Speed timing.
SDv1/SDSC, SPI-mode SD, FAT filesystems, and `CMD16` fallback remain out of
scope for this loader path. The DDR3 subsystem selects separate initialization,
Default Speed, and High Speed dividers. With the current
100 MHz MIG UI clock, the divider formula is `sd_clk = clk / (2 * (clk_div + 1))`:
`124` gives 400 kHz, `1` gives 25 MHz, and `0` gives 50 MHz. The 50 MHz divider
is selected only after CMD6 status confirms Function Group 1 selection and the
eight old-rate guard clocks finish.

The board pin table and schematic identify `SD_CD` on U17. The socket switch is
active low with a board 10 kOhm pull-up. The top synchronizes and debounces it,
waits at least 1 ms after stable insertion, and resets the complete SD/asset
session on removal so a replacement card cannot inherit initialization or High
Speed state.

Ethernet is not part of the initial real-time audio path. If the board's
RTL8211E interface is used later, it should first serve board control and asset
upload needs such as UDP status, preset upload, wave-image transfer, or network
MIDI. A full TCP/IP stack is better owned by an MCU or soft core than by the
wavetable datapath RTL.

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

Smart Artix RTL uses `smart_artix_pkg.sv` as the local board-facing contract for
MIG app command, write-data, response, line-read, platform-status, and DDR register access
structs. Generated MIG IP ports remain explicit at `smart_artix_top`; the struct
types are used on the board-owned side of that boundary and in the DDR3
subsystem internals.

`smart_artix_mig_stub` is not a DDR3 timing model. It only provides a calibration
delay, accepts one read command at a time, and returns a deterministic 128-bit
pattern after a fixed latency. Replace it with the generated MIG instance for any
hardware build that needs real DDR3 pins.

Board reference files such as schematics belong under `docs/`. They are kept as
source material for later pin and constraint work, not as synthesis inputs.

## Current Vivado 2025.2 Status

Vivado is installed locally under `/opt/Xilinx2051.1/2025.2/Vivado`. The batch flow in
`vivado/scripts/synth.tcl` now creates a local project for `xc7a50tfgg484-2`,
merges the generic `../../rtl/filelist.f` with the board integration
`filelist.f`, applies `constraints/smart_artix.xdc`, synthesizes
`smart_artix_top`, reads source-controlled IP configuration from `vivado/ip`,
writes reports and checkpoints under `../../build/fpga/smart_artix/vivado`, and
keeps the board source directory free of generated Vivado output.

Run the current synthesis check from this directory with:

```bash
mkdir -p ../../build/fpga/smart_artix/vivado/logs
cd ../../build/fpga/smart_artix/vivado
/opt/Xilinx2051.1/2025.2/Vivado/bin/vivado -mode batch \
  -source ../../../../fpga/smart_artix/vivado/scripts/synth.tcl \
  -journal logs/synth.jou -log logs/synth.log
```

The non-DDR XDC uses board-documented native-SD pins and project-selected
BANK15 expansion-header pins for SPI and I2S. The package locations match the
board pin table, but external wiring and BANK15 voltage still require
verification. The current non-DDR I/O standard is `LVCMOS33`, and the primary
board clock is constrained to `20.000 ns` for the confirmed `50 MHz`
oscillator. DDR3 pins come from the generated MIG XDC. External timing remains
open as detailed in the board I/O constraints backlog.

`DDRPIN.ucf` is the board-provided DDR3 pin assignment source. Keep it with the
board target: the Vivado project script checks the MIG `mig_b.prj` pin selection
against this file before generating or reusing the MIG IP, and the generated MIG
XDC then carries those pins into synthesis and implementation.

The current board top instantiates `smart_artix_clk_50m_to_200m` and `smart_artix_ddr3_mig` when the
generated IP configuration is present. The source-controlled IP inputs are the
Clocking Wizard `.xci`, the MIG `.xci`, and the MIG `.prj` file under
`vivado/ip`; generated Verilog, checkpoints, project files, and reports remain
local Vivado output under `../../build/fpga/smart_artix/vivado`.
`smart_artix_mig_stub` remains in the repository for unit tests and non-Vivado
simulation, but it is no longer used by `smart_artix_top`.

Clocking status: the generated `smart_artix_clk_50m_to_200m` produces `200 MHz`
from the board's `50 MHz` oscillator, and the generated MIG project records
`InputClkFreq = 200 MHz`, `TimePeriod = 2500 ps`, and `PHYRatio = 4:1`. The
latest MIG wrapper has no separate `clk_ref_i` port, so `smart_artix_top` feeds
the available `200 MHz` clock directly to MIG `sys_clk_i`.

The core does not run at the Clocking Wizard's `200 MHz` output. The MIG derives
its DDR PHY clocks internally and exposes a `100 MHz` user interface clock
(`ui_clk`, reported as `clk_pll_i`). `smart_artix_top` intentionally uses that
clock as `clk_sys` and sets `SYS_CLK_HZ = 100_000_000`, keeping the wavetable core
and MIG app interface in one clock domain.

The latest generated MIG native app interface is `128` bits wide with a `29` bit
app address. The board top therefore uses `LINE_WORDS = 8` so one MIG read beat
contains one complete wavetable cache line.

Latest forced full implementation result with `smart_artix_clk_50m_to_200m`,
`smart_artix_ddr3_mig`, the generated MIG XDC, the complete generic RTL
filelist, and the board RTL filelist merged by `project.tcl`:

```text
Design: smart_artix_top
Device: 7a50tfgg484-2
Vivado result: route_design completed successfully
Errors: 0
Critical warnings: 0
Synthesis checksum: d17fba4
```

Warnings remain visible and include generated-IP and board I/O timing messages.
They do not include route or DRC errors. External SPI and I2S input/output delay
constraints still require measured board timing contracts.

Post-route utilization:

```text
Slice LUTs       19306 / 32600  59.22%
Slice Registers 20750 / 65200  31.83%
DSP48E1            47 / 120    39.17%
Block RAM tiles  39.5 / 75     52.67%
```

Post-route timing at the MIG 100 MHz `ui_clk`:

```text
WNS  +0.226 ns
TNS  0.000 ns
Failing setup endpoints: 0
WHS  +0.036 ns
THS  0.000 ns
Failing hold endpoints: 0
Fully routed nets: 39892 / 39892
Route errors: 0
DRC errors: 0
```

Timing closure required BRAM-safe chorus/reverb memories and explicit numeric
stages in the chorus, reverb, return mixer, compressor, and control executor.
The reusable coding patterns, path-cluster history, and failure signatures are
recorded in `../../docs/verification/vivado_synthesis_timing.md`.

The timing report also shows expected board-level gaps: SPI input ports and I2S
or status output ports do not yet have external input/output delays. Add those
only after the real board timing contract is known.

## Resource Follow-Up

The design now fits with useful headroom in every reported programmable
resource. Preserve synchronous BRAM templates and re-run full implementation
after effects, voice-count, or control-record changes; post-synthesis timing is
not sufficient for signoff.

## Bring-Up Order

1. Confirm BANK15 is at 3.3 V and wire the selected SPI/I2S expansion pins in
   the same order recorded by the XDC and board I/O constraints backlog.
2. Run full implementation with the `200 MHz` MIG input clock and review
   post-route MIG DDR PHY hold timing before treating post-synthesis hold as a
   board-blocking failure.
3. Keep the first audio/system clock strategy on MIG `ui_clk` unless hardware
   measurements show a need to split domains. The board top now records
   `SYS_CLK_HZ = 100_000_000`; `sample_tick` and I2S BCLK use fractional
   phase-accumulator dividers from that clock. Recheck I2S output timing on
   hardware before adding a separate audio clock or CDC bridge.
4. Add real reset conditioning and document reset polarity.
5. Add SPI mode, maximum SCLK, CDC, and input-delay constraints for the selected
   control source.
6. Add I2S output delay constraints from the codec timing limits, then verify
   `BCLK`, `LRCLK`, and `SDATA` with a scope or logic analyzer.
7. Add a tiny BRAM-backed line-memory test source for one known waveform.
8. Re-run Vivado synthesis and implementation with real MIG and real pin
   constraints; record resource and timing changes here.
9. Verify the SD raw-image loader path on hardware: native SD pins, asset header
   parser, DDR3 write DMA, loader status, and loaded-byte readback or audio smoke
   output.

## Vivado Batch Flow

Source-controlled Vivado inputs live under `fpga/smart_artix/vivado/`.
Generated Vivado projects, reports, checkpoints, bitstreams, logs, and IP output
products live under `build/fpga/smart_artix/vivado/` at the repository root and
should not be committed.

Generate or refresh the local Vivado project:

```bash
mkdir -p ../../build/fpga/smart_artix/vivado/logs
cd ../../build/fpga/smart_artix/vivado
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/project.tcl \
  -journal logs/project.jou -log logs/project.log
```

Run synthesis:

```bash
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/synth.tcl \
  -journal logs/synth.jou -log logs/synth.log
```

The synthesis script writes the flat utilization, hierarchical utilization, and
timing reports under `../../build/fpga/smart_artix/vivado/reports/`. Use
`post_synth_utilization_hier_depth4.rpt` first when checking resource ownership;
it shows the major split between `core_system`, `multi_voice_pipeline`,
`synth_control_plane`, memory, and the MIG wrapper without the full IP hierarchy
noise. Use `post_synth_utilization_hier.rpt` when a deeper instance-level trace is
needed.

Run implementation or bitstream generation:

```bash
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/impl.tcl \
  -journal logs/impl.jou -log logs/impl.log
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/bitstream.tcl \
  -journal logs/bitstream.jou -log logs/bitstream.log
```

Program hardware with the generated bitstream:

```bash
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/program.tcl \
  -journal logs/program.jou -log logs/program.log
```

For GUI work, open `../../build/fpga/smart_artix/vivado/smart_artix.xpr` from
this directory. If IP settings are changed in the GUI, copy only the updated
`.xci` or MIG `.prj` files back into `vivado/ip/`; do not commit the generated
project, runs, checkpoints, or reports.

Implementation and bitstream scripts are available for tool-flow experiments.
Treat bitstreams built with the temporary XDC as non-hardware images until the
temporary pins are replaced with schematic-verified Smart Artix pins.

## Local Checks

Run the Smart Artix board-level regression from the repository root:

```bash
make smart-artix-test
```

This builds and runs the current focused Smart Artix SystemVerilog tests for the
raw-image asset loader, DDR3 asset writer, DDR3 line reader, DDR3 read/write
arbiter, MIG stub, native SD command reader, native fake-card model, native pin
PHY, and native asset-loader path.

Run the board-loader render harness from the repository root:

```bash
make render-board-loader SECONDS=0.1
```

This C++ harness constructs a raw SD image from the selected SF2, drives the
native-SD command/data loader RTL into a DDR byte model, checks the loaded DDR
bytes against the source SF2, then renders through `wavetable_cached_render_core` and
compares every output sample against the C++ fixed-point reference. It uses a
command-level SD model for speed; pin-level SD behavior is covered by the focused
native pin PHY tests inside `make smart-artix-test`.

For board-top checking, `smart_artix_top` instantiates Vivado-generated clock and
MIG IP directly. Use the Vivado batch synthesis command above for that path; pure
Verilator lint needs temporary stubs for those vendor modules.
