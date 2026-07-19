# Smart Artix XC7A50T Target

This directory is the board-specific integration workspace for the Smart Artix
minimum system board. The RTL connects SPI control, native-SD asset loading,
DDR3-backed wavetable reads, and I2S output. Pin locations, exact clocking, and
DDR3 MIG files must still be verified against the board schematic and
Vivado-generated IP before hardware implementation.

Use [`../../docs/board/smart_artix_bringup.md`](../../docs/board/smart_artix_bringup.md) as
the practical hardware bring-up checklist.

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
- Generated clock wizard: `smart_artix_clk_50m_to_200m`, currently `50 MHz` input to `200 MHz`
  output.
- Generated MIG IP source configuration: `vivado/ip/smart_artix_ddr3_mig`.

Still required from the board documentation:

- Reset source and polarity.
- SPI, I2S, LED, and DDR3 pin locations.
- I/O standards and bank voltages.
- Target DDR3 clock rate and MIG configuration.
- Audio codec timing limits and whether MCLK, reset, mute, or codec register
  configuration pins are actually needed.

## Current Top

`rtl/smart_artix_top.sv` instantiates `wavetable_demo_system` with SPI control,
line-memory caching, output FIFO, and I2S output. Board-specific SD loading, DDR3
read/write arbitration, line reads, and DDR debug traffic are grouped behind
`smart_artix_ddr3_subsystem`; Smart Artix platform registers are implemented by
`smart_artix_platform_debug_regs` through the common wrapper's debug extension
bus. After MIG calibration completes, the top starts the SD loader, copies the
raw SF2 byte image into DDR3, and holds the audio core in reset until
`asset_loaded` is asserted.

The intended memory replacement is:

```text
SD native pins: CLK, CMD, DAT[3:0]
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
repacking so software can keep using absolute SF2 `smpl` offsets when programming
voice registers.

The native 4-bit path is connected to `smart_artix_top`:

```text
native SD pins: CLK, CMD, DAT[3:0]
  -> sd_native_pin_phy
  -> smart_artix_sd_native_asset_loader
  -> sd_native_block_reader
  -> smart_artix_asset_loader
  -> smart_artix_ddr3_asset_writer
  -> smart_artix_ddr3_rw_arbiter
  -> MIG app write interface
```

The native reader initializes SDHC/SDXC cards, selects the assigned RCA, switches
to 4-bit bus mode with `ACMD6`, switches to high-speed timing with `CMD6`, and
issues `CMD17` single-block reads or `CMD23`/`CMD18` predeclared multi-block
reads. The native
pin PHY drives `SD_CLK`, transmits commands with CRC7, releases/captures the `CMD`
line for responses, receives `DAT[3:0]` as a byte stream, and checks each data
line's CRC16 before releasing the final byte of a block.

The initialization policy follows the same practical sequence used by small FPGA
SD readers, but narrowed to SDHC/SDXC: `CMD0`, `CMD8`, retrying `CMD55/ACMD41`
with HCS, then `CMD2/CMD3/CMD7` plus `CMD55/ACMD6` for native 4-bit mode and
`CMD6` for high-speed timing.
SDv1/SDSC, SPI-mode SD, FAT filesystems, and `CMD16` fallback remain out of
scope for this loader path. The DDR3 subsystem has separate `sd_init_clk_div` and
`sd_transfer_clk_div` inputs and switches the native pin PHY to the transfer
divider after the SD reader reports `sd_transfer_clock_ready`. With the current
100 MHz MIG UI clock, the divider formula is `sd_clk = clk / (2 * (clk_div + 1))`:
`SD_INIT_CLK_DIV = 124` gives 400 kHz and `SD_TRANSFER_CLK_DIV = 0` gives 50 MHz.

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
MIG app command, write-data, response, line-read, platform-status, and DDR debug
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
reads `filelist.f`, applies `constraints/smart_artix.xdc`, synthesizes
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

The non-DDR XDC currently contains temporary package pins selected only to let
Vivado run early synthesis and timing checks. These pins are legal user I/O for
the package, but they are not verified against the Smart Artix schematic and must
not be used to connect real hardware. The temporary non-DDR I/O standard is
`LVCMOS33`, and the primary board clock is constrained to `20.000 ns` for the
confirmed `50 MHz` oscillator. DDR3 pins come from the generated MIG XDC.

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

Latest post-synthesis result with `smart_artix_clk_50m_to_200m`,
`smart_artix_ddr3_mig`, the generated MIG XDC, the read-only line-reader path,
and the voice snapshot timing stage connected:

```text
Design: smart_artix_top
Device: 7a50tfgg484-2
Vivado result: synth_design completed successfully
Errors: 0
Critical warnings: 0
Warnings: 310 during synth_design; 165 in final Vivado session summary
```

The warning count is left visible instead of suppressed. It currently includes
generated IP messages plus expected early board-level timing gaps while the MIG
input clock and external SPI/I2S timing contracts are still unresolved.

Post-synthesis utilization:

```text
Slice LUTs        9905 / 32600  30.38%
Slice Registers  13611 / 65200  20.88%
DSP48E1             26 / 120    21.67%
Block RAM tiles      9 / 75     12.00%
Bonded IOB          61 / 250    24.40%
```

Post-synthesis timing still reports hold violations in generated clocking paths:

```text
WNS  +0.678 ns
TNS  0.000 ns
Failing setup endpoints: 0
WHS  -1.345 ns
THS  -23.952 ns
Failing hold endpoints: 55
No unclocked registers
No unconstrained internal endpoints
```

Treat this post-synthesis timing result as an implementation-stage DDR PHY timing
warning. The remaining hold violations are in MIG-generated clock domains such as
`oserdes_clk` to `oserdes_clkdiv` and the Clocking Wizard output to MIG
`clk_pll_i`, not in the generic wavetable core.

Post-route timing closes after snapshotting the selected voice before phase
advance:

```text
WNS  +0.428 ns
TNS  0.000 ns
Failing setup endpoints: 0
WHS  +0.036 ns
THS  0.000 ns
Failing hold endpoints: 0
```

The previous worst routed setup path was in the core voice pipeline, from
replicated `voice_index_reg` through configuration/runtime selection and phase
carry-chain logic to `phase_reg`. The current `multi_voice_pipeline` keeps the
external interface unchanged and adds a `PROCESS_VOICE` stage: `START_VOICE`
captures the selected voice's config, runtime controls, commit bit, and phase;
the next cycle computes frame indexes, loop wrap, and phase writeback from those
registers. This costs one clock per visited voice and keeps the core at the MIG
`100 MHz` `ui_clk`.

The first remaining timing pressure to watch is around the voice pipeline
multiply and wide accumulation paths. Vivado also reports that several wide
multipliers do not have the two pipeline stages it recommends. If later feature
work reintroduces timing pressure, prefer adding focused pipeline stages in
`rtl/voice/multi_voice_pipeline.sv` over changing board constraints to hide the
path.

The timing report also shows expected board-level gaps: SPI input ports and I2S
or debug output ports do not yet have external input/output delays. Add those
only after the real board timing contract is known.

## Resource Follow-Up

The first resource cleanup removed the renderer's full per-frame copies of
`voice_config` and `voice_runtime`. That brought post-synthesis LUT use down from
about `81.89%` to `57.43%`, while register use remains high at `69.45%`.

Board-level optimization should now focus on these items, in order:

1. Add a board build option to compile out the optional biquad filter when a
   bring-up image does not need it.
2. If filter support is required, replace the current combinational biquad path
   with a registered multi-cycle/shared-DSP filter block.
3. Move wide, low-rate voice control fields toward LUTRAM or RAM-backed storage
   while preserving output-frame atomic updates.
4. Consider narrowing filter state only with matching fixed-point documentation
   and exact regression tests.
5. Re-run full implementation with real pins and clocking before adding final
   pipeline stages for timing closure.

## Bring-Up Order

1. Replace the temporary non-DDR XDC package pins with schematic-verified Smart Artix
   pins before connecting hardware.
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
`voice_register_bank`, memory, and the MIG wrapper without the full IP hierarchy
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
