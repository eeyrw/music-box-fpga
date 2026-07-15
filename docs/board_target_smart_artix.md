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

The current pin source is
`fpga/smart_artix/docs/Smart_Artix_Pin_Assignment.txt`. The XDC binds the board
`CLK_50M` and `RESET_N` pins directly. The current top-level SPI, I2S, and debug
status signals do not have dedicated pins in that table, so they are temporarily
exported on BANK15 expansion-header pins documented by that same table. I2S codec
timing limits still need to be recorded before hardware connection.

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

## Vivado 2025.2 Snapshot

Vivado 2025.2 is installed under `/opt/Xilinx2051.1/2025.2/Vivado` on the local
development machine. The Smart Artix batch flow is in
`fpga/smart_artix/vivado/scripts/synth.tcl` and currently runs synthesis for
`smart_artix_top` with `xc7a50tfgg484-2`.

The current XDC uses temporary legal package pins and `LVCMOS33` so Vivado can
exercise the flow. These pins are not schematic-verified and must be replaced
before any hardware connection. DDR3 pins remain owned by the future MIG-generated
XDC.

Earlier post-synthesis result with the temporary `49.152 MHz` constraint:

```text
Vivado result: 0 errors, 0 critical warnings
Slice LUTs: 21538 / 32600, 66.07%
Slice registers: 45477 / 65200, 69.75%
DSP48E1: 26 / 120, 21.67%
Block RAM tiles: 0 / 75, 0.00%
Timing WNS: -0.725 ns at 49.152 MHz
```

Current post-synthesis result after upgrading the checked-in Clocking Wizard and
MIG `.xci` files for Vivado 2025.2, using the generated MIG and clock wizard,
and adding a one-cycle voice snapshot stage in `multi_voice_pipeline`:

```text
Vivado result: 0 errors, 0 critical warnings
Slice LUTs: 9905 / 32600, 30.38%
Slice registers: 13611 / 65200, 20.88%
DSP48E1: 26 / 120, 21.67%
Block RAM tiles: 9 / 75, 12.00%
Setup WNS: +0.678 ns, WHS: -1.345 ns
```

Latest area-oriented post-synthesis result after changing `multi_voice_pipeline`
to sequential slot scanning and RAM-backed per-voice phase/filter history:

```text
Vivado result: 0 errors, 0 critical warnings
Slice LUTs: 8272 / 32600, 25.37%
Slice registers: 7882 / 65200, 12.09%
DSP48E1: 26 / 120, 21.67%
Block RAM tiles: 9 / 75, 12.00%
Setup WNS: -0.371 ns, WHS: -1.345 ns
Core ui-clock group: setup slack +2.669 ns, hold slack +0.037 ns
```

Current post-route result with the same inputs:

```text
Vivado result: route_design completed successfully
Slice LUTs: 9174 / 32600, 28.14%
Slice registers: 13491 / 65200, 20.69%
DSP48E1: 26 / 120, 21.67%
Block RAM tiles: 9 / 75, 12.00%
Setup WNS: +0.428 ns, TNS: 0.000 ns, failing endpoints: 0
Hold WHS: +0.036 ns, THS: 0.000 ns, failing endpoints: 0
```

Implementation fixes the post-synthesis hold violations. The previous routed
setup failure in the `clk_pll_i` domain was inside the core voice pipeline from
`voice_index_reg` through configuration/runtime selection and phase carry-chain
logic to `phase_reg`. The fix keeps the core on MIG `ui_clk` (`clk_pll_i`,
`100 MHz`) and adds a `PROCESS_VOICE` stage: `START_VOICE` snapshots the selected
voice's configuration, runtime controls, commit bit, and current phase into local
registers; the next cycle performs phase advance, loop wrap, frame selection, and
phase writeback from those registers. This costs one clock per visited voice and
keeps the external core and memory interfaces unchanged.

The latest pass confirms that the largest voice-register-bank muxes have been
removed: active configuration is stored as a `32 x 172` BRAM-backed word and
runtime filter coefficients as a `32 x 160` BRAM-backed word. Runtime phase
increment, gain, and envelope state are stored in narrow true-dual-port RAM banks
so readback does not steal the renderer read port. Direct per-voice
configuration/runtime readback was intentionally removed from the main register
path; low-rate inspection now uses the staged readback window, and software
should still mirror write state on the host side for normal operation.

The area-oriented pass also removes the renderer's combinational next-valid-voice
search. Invalid voice slots are scanned sequentially, trading frame-render cycles
for a much smaller `multi_voice_pipeline`. Per-voice phase is held in a `32 x 32`
distributed RAM plus a valid bit, and per-voice biquad history is held in four
`32 x 48` distributed RAMs plus a valid bit, rather than resettable flip-flop
arrays.

The filter pipeline removed an earlier `clk_pll_i` post-synthesis setup
violation. The later voice snapshot stage removed the routed phase-update setup
failure while implementation continues to close the generated MIG/clocking hold
paths. Remaining board-level timing gaps are the unconstrained external SPI, I2S,
and debug I/O delays, which need real external timing contracts before hardware
signoff.

## Vivado Project Reuse

The Smart Artix Tcl flow intentionally keeps the generated Vivado project under
`build/fpga/smart_artix/vivado/` between runs. `project.tcl` opens an existing
`smart_artix.xpr` when present instead of recreating it, avoids recopying or
regenerating IP output products unless they are missing, and adds source and XDC
files only if they are not already in the project.

`synth.tcl` checks the `synth_smart_artix_top` run before launching synthesis:

- If the run is complete and not marked `NEEDS_REFRESH`, the script reuses it,
  opens the existing run, and rewrites the post-synthesis checkpoint and reports.
- If RTL, XDC, IP, or project inputs make the run stale, the script resets and
  relaunches `synth_smart_artix_top` instead of failing with Vivado's `needs to be reset`
  message.
- If a previous failed synthesis leaves `synth_smart_artix_top` in a non-startable state, the
  script resets and relaunches the run.
- If a clean rebuild is required, set `VIVADO_FORCE_REBUILD=1`. If IP output
  products need to be regenerated from the source `.xci` files, set
  `VIVADO_REGENERATE_IP=1`.

This is project/run reuse, not Vivado implementation incremental checkpointing.
Source changes still require a synthesis rerun; unchanged inputs avoid a needless
project/IP rebuild and avoid a needless synthesis rerun.

After opening the synthesized run, `synth.tcl` also writes a fixed set of
post-synthesis reports under `build/fpga/smart_artix/vivado/reports/`:

- `post_synth_utilization.rpt` for the flat utilization summary.
- `post_synth_utilization_hier.rpt` for full hierarchy ownership.
- `post_synth_utilization_hier_depth4.rpt` for the quick resource-hotspot view
  used to compare `multi_voice_pipeline`, `voice_register_bank`, memory, and MIG
  usage.
- `post_synth_timing.rpt` for timing summary and path details.

The behavior was verified with three batch runs: an up-to-date run logged
`synth_smart_artix_top is complete and up-to-date; reusing existing run`, touching an RTL file
caused an automatic reset/relaunch and completed synthesis, and
`VIVADO_FORCE_REBUILD=1` rebuilt the project and completed synthesis.

## MIG Clocking Note

Generated IP source configuration lives under `fpga/smart_artix/vivado/ip/`.
Only the source-level IP configuration files are intended for version control:
the Clocking Wizard `.xci`, the MIG `.xci`, and the MIG `.prj` referenced by
that `.xci`. The checked-in `.xci` files were upgraded with Vivado 2025.2 so a
clean build can generate output products without first unlocking old 2018.3 IP
instances. Vivado-generated project files, checkpoints, netlists, and reports
remain local build output under `build/fpga/smart_artix/vivado/`. `smart_artix_clk_50m_to_200m`
converts the board `50 MHz` oscillator to `200 MHz`. The latest generated
`smart_artix_ddr3_mig` native app interface is `128` bits wide with a `29` bit app
address, so the Smart Artix top uses `LINE_WORDS = 8` for one complete cache line
per MIG read beat.

The generated MIG project records `InputClkFreq = 200 MHz`,
`TimePeriod = 2500 ps`, and `PHYRatio = 4:1`. The latest MIG wrapper exposes only
`sys_clk_i`, with no separate `clk_ref_i`; the current top feeds the
Clocking Wizard's `200 MHz` output to MIG `sys_clk_i`.

The Clocking Wizard output is not the core clock. MIG derives the DDR PHY clocks
and exposes `ui_clk` as `clk_pll_i`, currently `100 MHz`; `smart_artix_top` uses
that clock as `clk_sys` and sets `SYS_CLK_HZ = 100_000_000`. This keeps the core
and MIG app interface in one clock domain and avoids a CDC bridge on the memory
request path.

The current Vivado batch synthesis and implementation flows pass with the
generated MIG and clock wizard connected. Most warnings come from generated
Vivado IP and early board-level timing gaps; they are not yet filtered because
the real external timing constraints are unsettled. Full implementation removes
the post-synthesis hold violations and the core `clk_pll_i` phase-update setup
path now meets timing.
