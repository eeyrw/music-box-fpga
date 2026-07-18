# Generic synthesizable RTL. Keep this list aligned with RTL_SOURCES in ../../Makefile.
../../rtl/pkg/synth_pkg.sv
../../rtl/bus/spi_register_bridge.sv
../../rtl/control/voice_active_store.sv
../../rtl/control/voice_bram_1r1w.sv
../../rtl/control/voice_bram_1w2r.sv
../../rtl/control/voice_commit_engine.sv
../../rtl/control/voice_descriptor_store.sv
../../rtl/control/voice_runtime_store.sv
../../rtl/control/voice_register_bank.sv
../../rtl/control/wavetable_system_debug_regs.sv
../../rtl/memory/wave_memory_subsystem.sv
../../rtl/dsp/linear_interpolator.sv
../../rtl/dsp/gain_saturate.sv
../../rtl/dsp/voice_dsp_pipeline.sv
../../rtl/audio/fractional_tick_gen.sv
../../rtl/audio/output_sample_fifo.sv
../../rtl/audio/i2s_tx.sv
../../rtl/voice/voice_phase_frame.sv
../../rtl/voice/voice_endpoint_fetch.sv
../../rtl/voice/multi_voice_pipeline.sv
../../rtl/top/wavetable_render_core.sv
../../rtl/top/wavetable_line_memory_core.sv
../../rtl/top/wavetable_spi_audio_system.sv

# Board-specific RTL. Replace this with the concrete board top after copying.
rtl/board_top.sv.template
