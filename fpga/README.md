# FPGA Integration Workspace

This directory is reserved for board-specific FPGA integration work. The RTL
under `rtl/` is the generic synthesizable wavetable core; files here should bind
that core to a real board, a real clock tree, real pins, and real memory/audio
devices.

The current concrete target is `smart_artix/`, a Smart Artix XC7A50T board path
for SPI control, native-SD asset loading into DDR3, DDR3-backed wavetable memory,
and simple I2S audio. Use its common-wrapper and DDR arbiter boundaries as the
starting point for future board directories, for example:

```text
fpga/<board-name>/
```

Do not place simulation-only models from `sim/` in synthesis projects.
The old generic board template is preserved under `legacy/board_template` and
still targets the superseded renderer.

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
├── vivado/                     # Optional Xilinx project inputs
│   ├── ip/                     # Versioned .xci/.prj IP configuration
│   └── scripts/                # Project generation, synthesis, implementation
├── scripts/                    # Optional non-Vivado board scripts
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
   The current wrappers default to a `100 MHz` system clock and derive audio
   timing with fractional phase-accumulator dividers. The board project must set
   `SYS_CLK_HZ` to the actual core clock and verify the resulting audio clocks.

4. Add constraints.
   Define pin locations, I/O standards, drive strength where needed, primary
   clocks, generated clocks, false paths, multicycle paths, and external device
   timing for SPI, I2S, and memory interfaces.

5. Connect the ordered refill interface to physical memory.
   `voice_major_render_core` exposes ordered eight-word refills. The Smart Artix
   path translates them through its line reader and existing arbiter to MIG.

6. Complete the audio interface.
   `i2s_tx` emits BCLK, LRCLK, and serial data. Many boards also need codec MCLK,
   codec reset, mute control, and I2C/SPI codec register configuration.

7. Harden the control interface.
   Define the supported SPI mode, maximum SCLK, clock-domain assumptions,
   chip-select timing, and read turnaround behavior. Add synchronizers or CDC
   logic in the board wrapper when the SPI pins are not synchronous to `clk`.

8. Define and load the asset image.
   Runtime SF2/MIDI parsing is simulation-only. The Smart Artix path currently
   expects a raw SD image with a `WTSF` header and copies the SF2 byte image into
   DDR before playback. A board flow still needs metadata tables that the host,
   MCU, or soft core can use to build voice commands.

9. Provide control firmware or host software.
   The RTL does not allocate voices or parse MIDI. A control-side implementation
   must send the documented command stream for voice start, runtime updates,
   release, and stop.

10. Verify real-time timing.
    Measure render latency, memory miss latency, I2S underruns, and sample drops.
    Add an output FIFO or deeper prefetching if the core cannot produce each
    48 kHz frame before the audio transmitter consumes it.

## Source Files For Synthesis

`rtl/filelist.f` is the single source of truth for generic synthesizable RTL.
The root `Makefile` derives `RTL_SOURCES` from that file. Board projects must
read it directly and keep only common/board integration sources in their local
`filelist.f`; do not copy the generic list into each board directory.

The Smart Artix `project.tcl` demonstrates the required ordering: generic RTL
first, then `fpga/common/rtl` and Smart Artix integration RTL. Simulation models
under `sim/` and `fpga/<board>/sim/` must never be added to either synthesis
list.

Common board/peripheral adapters live under `fpga/common/rtl`:

```text
fpga/common/rtl/fractional_tick_gen.sv
fpga/common/rtl/spi_register_bridge.sv
fpga/common/rtl/wavetable_register_fabric.sv
fpga/common/rtl/wavetable_common_status_regs.sv
fpga/common/rtl/i2s_tx.sv
fpga/common/rtl/sd_native_block_reader.sv
fpga/common/rtl/sd_native_pin_phy.sv
fpga/common/rtl/wavetable_i2s_output.sv
fpga/common/rtl/voice_major_system.sv
```

Use `voice_major_render_core` for the generic block renderer,
`voice_major_system` for SPI/register/effects/I2S composition,
`wavetable_i2s_output` when adapting PCM frames to I2S,
`sd_native_block_reader` and `sd_native_pin_phy` when a board loader needs the
native SD command/pin layer without tying it to a specific memory controller.
