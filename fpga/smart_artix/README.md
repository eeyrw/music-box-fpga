# Smart Artix XC7A50T Target

This is the current production board integration for the Smart Artix minimum
system board. It connects SPI control, native-SD asset loading, MIG-backed DDR3
wavetable reads, and I2S output around `voice_major_system`.

## Board Facts

| Item | Current value |
| --- | --- |
| FPGA | `xc7a50tfgg484-2` (`XC7A50T-2FGG484I` board device) |
| Configuration flash | Winbond `W25Q128JVSIQTR`, 128 Mbit (16 MiB), SPIx1/x2/x4 |
| Oscillator | 50 MHz |
| DDR3 | Micron `MT41K256M16TW`, 512 MB, x16 |
| Core/application clock | MIG `ui_clk`, 100 MHz |
| MIG application width | 128 bits, one 8-word wavetable line |
| Control | SPI mode 0, register mailbox, opcode `0xa5` commands, `0xa6` FLUSH, and `0xa7` render-session reset |
| Asset source | native 4-bit SDHC/SDXC WTSF image |
| Audio | I2S data/BCLK/LRCLK; no codec initialization in this target |
| On-board LEDs | LED1 `R17` = DDR ready; LED2 `P16` = SD busy/error/loaded status |

BANK15 voltage, external SPI/I2S timing, physical wiring, signal integrity, and
codec requirements still need hardware confirmation. These are not waived by
internal routed timing closure.

## Composition

```text
50 MHz clock -> Clocking Wizard -> MIG DDR3 -> 100 MHz ui_clk
                                      |
SPI pins -> spi_register_bridge -> voice_major_system
                                      |
SD pins -> native SD reader -> asset writer -> DDR3 arbiter
                                      |
renderer ordered reads -> line reader -> DDR3 arbiter
                                      |
                              effects/FIFO -> I2S pins
```

`rtl/smart_artix_top.sv` owns physical pins and generated IP ports.
`rtl/smart_artix_ddr3_subsystem.sv` groups SD loading, line reads, register
access, and MIG arbitration. `smart_artix_pkg.sv` defines board-internal payload
types. The generated MIG, not `smart_artix_mig_stub`, is used by the Vivado top;
the stub remains simulation support.

## Source Layout

```text
filelist.f       common and board integration sources
rtl/             board-specific synthesizable RTL
sim/             focused board models and tests
constraints/     board XDC; MIG owns DDR pin timing
vivado/ip/       source-controlled Clocking Wizard and MIG configuration
vivado/scripts/  project, synthesis, implementation, bitstream, programming
docs/            local schematic and pin-assignment source material
assets/          notes only; generated WTSF images belong under build/
```

Generic RTL remains owned by `rtl/filelist.f` at the repository root.

## Current Implementation Baseline

The latest recorded forced implementation uses Vivado 2025.2,
`Flow_PerfOptimized_high`, and `Performance_ExplorePostRoutePhysOpt`:

```text
LUTs       24,965 / 32,600 (76.58%)
Registers  25,959 / 65,200 (39.81%)
DSPs       39 / 120
BRAM       46.5 / 75 tiles
WNS/WHS    +0.162 ns / +0.045 ns
Routing    46,117 / 46,117 nets, 0 route errors
DRC        0 errors, 0 critical warnings; 124 warnings remain for review
```

This is a recorded baseline, not evidence for a later RTL revision. Re-run the
required gate and confirm report freshness after production changes.

## Entry Points

- [`../../docs/board/smart_artix_bringup.md`](../../docs/board/smart_artix_bringup.md):
  hardware sequence, status interpretation, and smoke tests.
- [`../../docs/board/asset_loading.md`](../../docs/board/asset_loading.md): WTSF
  format and SD-to-DDR3 contract.
- [`../../docs/board/smart_artix_io_constraints_backlog.md`](../../docs/board/smart_artix_io_constraints_backlog.md):
  unresolved external timing and electrical work.
- [`vivado/README.md`](vivado/README.md): exact batch commands, generated report
  files, run reuse, and strategy overrides.
- [`../../docs/verification/vivado_synthesis_timing.md`](../../docs/verification/vivado_synthesis_timing.md):
  inference and timing-closure rules.
- [`../../docs/development/rtl_change_workflow.md`](../../docs/development/rtl_change_workflow.md):
  mandatory change and signoff gates.

Focused board regressions run with `make smart-artix-test`. The normal synthesis
and implementation commands run from the repository root and write only below
`build/fpga/smart_artix/vivado/`.
