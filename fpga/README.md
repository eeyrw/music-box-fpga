# FPGA Integration Workspace

This directory is reserved for board-specific FPGA integration work. The RTL
under `rtl/` is the generic synthesizable wavetable core; files here should bind
that core to a real board, a real clock tree, real pins, and real memory/audio
devices.

The current concrete target is `smart_artix/`, a Smart Artix XC7A50T board path
for SPI control, native-SD asset loading into DDR3, DDR3-backed wavetable memory,
and simple I2S audio. Use `board_template/` as the starting point for future board
directories, for example:

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

5. Replace abstract memory with a physical memory controller.
   `wavetable_cached_render_core` exposes a line-read interface, not real DDR3 pins or
   a MIG app interface. The Smart Artix path should translate line requests into
   reads from a MIG controller configured for the Micron `MT41K256M16TW`.

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
   MCU, or soft core can use to program voice registers.

9. Provide control firmware or host software.
   The RTL does not allocate voices or parse MIDI. A control-side implementation
   must write the documented register map, commit voices, update envelopes, and
   stop voices on note release.

10. Verify real-time timing.
    Measure render latency, memory miss latency, I2S underruns, and sample drops.
    Add an output FIFO or deeper prefetching if the core cannot produce each
    48 kHz frame before the audio transmitter consumes it.

## Source Files For Synthesis

The generic synthesizer core source list should match `RTL_SOURCES` in the root
`Makefile`:

```text
rtl/pkg/synth_pkg.sv
rtl/pkg/synth_register_pkg.sv
rtl/control/voice_active_store.sv
rtl/control/voice_bram_1r1w.sv
rtl/control/voice_bram_1w2r.sv
rtl/control/voice_commit_engine.sv
rtl/control/voice_descriptor_store.sv
rtl/control/voice_runtime_store.sv
rtl/control/voice_register_bank.sv
rtl/memory/wave_memory_subsystem.sv
rtl/dsp/linear_interpolator.sv
rtl/dsp/gain_saturate.sv
rtl/dsp/voice_dsp_pipeline.sv
rtl/audio/output_sample_fifo.sv
rtl/voice/voice_phase_frame.sv
rtl/voice/voice_endpoint_fetch.sv
rtl/voice/multi_voice_pipeline.sv
rtl/top/wavetable_render_core.sv
rtl/top/wavetable_cached_render_core.sv
```

Common board/peripheral adapters live under `fpga/common/rtl`:

```text
fpga/common/rtl/fractional_tick_gen.sv
fpga/common/rtl/spi_register_bridge.sv
fpga/common/rtl/wavetable_system_debug_regs.sv
fpga/common/rtl/i2s_tx.sv
fpga/common/rtl/wavetable_system_core.sv
fpga/common/rtl/wavetable_i2s_output.sv
fpga/common/rtl/wavetable_demo_system.sv
```

Use `wavetable_render_core` for the smallest datapath integration,
`wavetable_cached_render_core` when a standalone Verilated top should include the
line-memory adapter, `wavetable_system_core` when a board/common wrapper should
compose the render core and line-memory adapter behind an abstract register bus,
`wavetable_i2s_output` when adapting PCM frames to I2S, or
`wavetable_demo_system` when keeping the current SPI plus I2S board demo shape.
