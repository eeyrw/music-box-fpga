# Generic synthesizable RTL. Keep this list aligned with RTL_SOURCES in ../../Makefile.
../../rtl/pkg/synth_pkg.sv
../../rtl/bus/register_bus_if.sv
../../rtl/bus/spi_register_bridge.sv
../../rtl/control/voice_bram_1r1w.sv
../../rtl/control/voice_bram_1w2r.sv
../../rtl/control/voice_register_bank.sv
../../rtl/memory/wave_memory_subsystem.sv
../../rtl/dsp/linear_interpolator.sv
../../rtl/dsp/gain_saturate.sv
../../rtl/audio/output_sample_fifo.sv
../../rtl/audio/i2s_tx.sv
../../rtl/voice/multi_voice_pipeline.sv
../../rtl/top/wavetable_core.sv
../../rtl/top/wavetable_core_memory.sv
../../rtl/top/wavetable_core_spi.sv
../../rtl/top/wavetable_core_system.sv

# Board-specific RTL. Replace this with the concrete board top after copying.
rtl/board_top.sv.template
