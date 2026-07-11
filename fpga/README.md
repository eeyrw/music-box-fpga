# FPGA Integration Workspace

This directory is reserved for board-specific FPGA integration work. The RTL
under `rtl/` is the generic synthesizable wavetable core; files here should bind
that core to a real board, a real clock tree, real pins, and real memory/audio
devices.

The current repository does not yet target a specific FPGA board. Use
`board_template/` as the starting point for a concrete board directory, for
example:

```text
fpga/<board-name>/
```

Do not place simulation-only models from `sim/` in synthesis projects.

## Expected Board Directory

```text
fpga/<board-name>/
├── README.md
├── filelist.f
├── rtl/
│   └── <board-name>_top.sv
├── constraints/
│   ├── <board-name>.xdc        # Vivado, if using Xilinx
│   └── <board-name>.sdc        # Quartus/Yosys timing constraints, if needed
├── scripts/
│   ├── vivado_synth.tcl        # Optional Vivado batch flow
│   ├── quartus_project.tcl     # Optional Quartus project generation
│   └── yosys_synth.ys          # Optional open-source synthesis flow
└── assets/
    └── README.md
```

## Work Required Before Synthesis

1. Select a board and FPGA part.
   Record the exact FPGA part number, package, speed grade, board revision,
   oscillator frequency, I/O bank voltages, audio device, and memory device.

2. Add a board top level.
   Instantiate the generic core, connect physical pins, define reset behavior,
   and adapt external memory/audio/control ports to the board devices.

3. Generate board clocks.
   The simulation wrapper defaults to a 49.152 MHz system clock for 48 kHz audio.
   The board project must either generate that clock with a PLL/MMCM or adjust
   `SYS_CLK_HZ` and verify the resulting audio clocks.

4. Add constraints.
   Define pin locations, I/O standards, drive strength where needed, primary
   clocks, generated clocks, false paths, multicycle paths, and external device
   timing for SPI, I2S, and memory interfaces.

5. Replace abstract memory with a physical memory controller.
   `wavetable_core_memory` exposes a line-read interface, not real DDR, SDRAM,
   PSRAM, SPI Flash, QSPI Flash, or parallel NOR pins. A board wrapper must
   translate line requests into the selected memory protocol.

6. Complete the audio interface.
   `i2s_tx` emits BCLK, LRCLK, and serial data. Many boards also need codec MCLK,
   codec reset, mute control, and I2C/SPI codec register configuration.

7. Harden the control interface.
   Define the supported SPI mode, maximum SCLK, clock-domain assumptions,
   chip-select timing, and read turnaround behavior. Add synchronizers or CDC
   logic in the board wrapper when the SPI pins are not synchronous to `clk`.

8. Define the asset image.
   Runtime SF2/MIDI parsing is simulation-only. A board flow needs a preprocessed
   wave-memory image and metadata tables that the host, MCU, or soft core can use
   to program voice registers.

9. Provide control firmware or host software.
   The RTL does not allocate voices or parse MIDI. A control-side implementation
   must write the documented register map, commit voices, update envelopes, and
   stop voices on note release.

10. Verify real-time timing.
    Measure render latency, memory miss latency, I2S underruns, and sample drops.
    Add an output FIFO or deeper prefetching if the core cannot produce each
    48 kHz frame before the audio transmitter consumes it.

## Source Files For Synthesis

The generic RTL source list should match the synthesizable `RTL_SOURCES` in the
root `Makefile`:

```text
rtl/pkg/synth_pkg.sv
rtl/bus/register_bus_if.sv
rtl/bus/spi_register_bridge.sv
rtl/control/voice_register_bank.sv
rtl/memory/wave_memory_subsystem.sv
rtl/dsp/linear_interpolator.sv
rtl/dsp/gain_saturate.sv
rtl/audio/i2s_tx.sv
rtl/voice/multi_voice_pipeline.sv
rtl/top/wavetable_core.sv
rtl/top/wavetable_core_memory.sv
rtl/top/wavetable_core_spi.sv
rtl/top/wavetable_core_system.sv
```

Use `wavetable_core` for the smallest datapath integration, `wavetable_core_memory`
when attaching a line-memory controller, or `wavetable_core_system` when keeping
the current SPI plus I2S integration shape.
