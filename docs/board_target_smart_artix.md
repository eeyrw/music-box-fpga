# Smart Artix Board Target

This document records the current board target assumptions for the first
XC7A50T integration path. The generic synthesizable wavetable core remains under
`rtl/`; board-specific clocks, constraints, DDR3 IP, pin binding, and bring-up
files belong under `fpga/`.

## Fixed Board Assumptions

- FPGA target: Xilinx Artix-7 `XC7A50T-2FGG484I`.
- Vivado 2018.3 part name: `xc7a50tfgg484-2`.
- Development board: Smart Artix minimum system board.
- Board oscillator: `50 MHz`.
- External wave memory: one Micron `MT41K256M16TW` DDR3 device.
- DDR3 organization: `256M x 16-bit`, total capacity `512 MB`.
- DDR3 connection: 16-bit data bus connected to FPGA `BANK34`.
- DDR3 PCB design: routed according to DDR3 length-matching requirements.
- Control source: external MCU or PC USB-to-SPI adapter.
- Audio codec: simple I2S codec with no register initialization and no MCLK
  requirement.

The board revision, I/O standards, DDR3 clock rate, SPI voltage, non-DDR pin
locations, and I2S codec timing limits still need to be recorded from the board
documentation or schematic before constraints are finalized.

## System Boundary

The FPGA synth path is:

```text
external MCU or PC USB-to-SPI
  -> spi_register_bridge
  -> wavetable_core
  -> wave_memory_subsystem
  -> DDR3 line-read adapter
  -> Xilinx MIG DDR3 controller
  -> MT41K256M16TW

wavetable_core
  -> output FIFO
  -> i2s_tx
  -> simple I2S codec
```

The FPGA does not parse MIDI files, SoundFont files, preset regions, envelopes,
voice allocation policy, or controller policy. Those remain owned by the
external MCU, PC tool, or simulation harness. The FPGA receives register writes
through the documented register map and renders the committed voice state.

## DDR3 Integration Policy

The DDR3 controller must stay behind a board-level adapter. The generic core
must not depend on MIG signals or DDR timing. The intended layering is:

```text
wavetable_core word reads
  -> wave_memory_subsystem line reads
  -> board DDR3 line-reader adapter
  -> MIG application interface
```

The first hardware milestone should support read-only wavetable playback from
DDR3. DDR3 asset loading, write arbitration, SD-card loading, and Ethernet upload
are separate board-system tasks and should not be mixed into the first playback
bring-up unless the selected load path requires them.

## Asset Loading Direction

SD card storage is treated as an asset source, not as the real-time audio read
path. The planned first contract is documented in `docs/asset_loading.md`: the SD
card stores a raw image with a small header, the FPGA copies the SF2 byte image
into DDR3 before playback, and the MCU or host owns SF2 metadata and voice policy.
A practical flow is:

```text
PC preprocessing tool
  -> raw SD image: header, SF2 bytes, optional metadata
  -> FPGA SD block reader
  -> DDR3 load before playback starts
  -> SPI voice-register control during playback
```

SPI is acceptable for register control and small diagnostics. Loading large
wave-memory images through the low-speed SPI control link will be slow, so the
board design should use a dedicated SD load path or another faster asset upload
path. SD SPI mode is acceptable for initial bring-up, but native 4-bit SD is the
more practical path for a roughly 500 MB image.

## Ethernet Direction

The RTL8211E Ethernet interface is not part of the initial real-time audio path.
When used, it should first serve board control and asset upload needs such as UDP
status, preset upload, wave-image transfer, or network MIDI. A full TCP/IP stack
is better owned by an MCU or soft core than by the wavetable datapath RTL.

## First Bring-Up Milestones

1. Add board documentation and a `fpga/smart_artix/` project skeleton.
2. Verify the generic core with output FIFO, deadline counters, and underrun
   checks in simulation.
3. Synthesize the core for `XC7A50T-2FGG484I` without DDR3 attached to measure
   LUT, FF, BRAM, DSP, and timing margins.
4. Generate a MIG configuration for `MT41K256M16TW` and connect a read-only DDR3
   line-reader adapter to `wave_memory_subsystem`.
5. Play a small known wave image from DDR3 through I2S.
6. Add the SD raw-image to DDR3 asset-loading path from `docs/asset_loading.md`.

The initial skeleton lives in `fpga/smart_artix/`. It intentionally keeps DDR3
stubbed so the first synthesis pass can measure core resource use before MIG and
board constraints are added. The skeleton includes a first `smart_artix_ddr3_line_reader`
adapter for the 7-series MIG native read interface; it assumes a 128-bit MIG app
read data beat returns one `LINE_WORDS = 8` PCM-word line.

## Vivado 2018.3 Snapshot

Vivado 2018.3 is installed under `/opt/Xilinx/Vivado/2018.3` on the local
development machine. The Smart Artix batch flow is in
`fpga/smart_artix/scripts/vivado_synth.tcl` and currently runs synthesis for
`smart_artix_top` with `xc7a50tfgg484-2`.

The current XDC uses temporary legal package pins and `LVCMOS33` so Vivado can
exercise the flow. These pins are not schematic-verified and must be replaced
before any hardware connection. DDR3 pins remain owned by the future MIG-generated
XDC.

Latest post-synthesis result with the temporary `49.152 MHz` constraint:

```text
Vivado result: 0 errors, 0 critical warnings
Slice LUTs: 21538 / 32600, 66.07%
Slice registers: 45477 / 65200, 69.75%
DSP48E1: 26 / 120, 21.67%
Block RAM tiles: 0 / 75, 0.00%
Timing WNS: -0.725 ns at 49.152 MHz
```

This timing result is a useful early warning, not a final board result. The next
timing work is to run implementation after real pins and clocking are known, then
pipeline the voice pipeline multiply/accumulation path if the violation remains.

## MIG Clocking Note

Generated IP currently exists under
`fpga/smart_artix/music-box-fpga.srcs/sources_1/ip/`. Only the source-level IP
configuration files are intended for version control: the Clocking Wizard `.xci`,
the MIG `.xci`, and the MIG `.prj` referenced by that `.xci`. `clk_wiz_0`
converts the board `50 MHz` oscillator to `200 MHz`. The latest generated
`mig_7series_0` native app interface is `128` bits wide with a `29` bit app
address, so the Smart Artix top uses `LINE_WORDS = 8` for one complete cache line
per MIG read beat.

The generated MIG project currently records `InputClkFreq = 333.333 MHz`,
`TimePeriod = 3000 ps`, and `PHYRatio = 2:1`. The latest MIG wrapper exposes only
`sys_clk_i`, with no separate `clk_ref_i`; the current top feeds the available
`200 MHz` clock to `sys_clk_i`. Before hardware DDR3 bring-up, confirm that this
is the intended MIG input clock, regenerate the clock wizard for `333.333 MHz`,
or regenerate MIG for a `200 MHz` input clock if that mode is valid for the
selected DDR3 rate.

The current Vivado batch synthesis passes with the generated MIG and clock wizard
connected: `0 errors`, `0 critical warnings`, and `205 warnings`. Most warnings
come from generated Vivado IP and early board-level timing gaps; they are not yet
filtered because the clocking and real external timing constraints are unsettled.
Post-synthesis utilization is about `26695 / 32600` LUTs, `49965 / 65200`
registers, and `26 / 120` DSPs. Timing is not yet clean, with
`WNS = -11.098 ns` and `WHS = -1.329 ns`; treat that as a clocking/configuration
issue until the MIG input frequency and final clock plan are confirmed.
