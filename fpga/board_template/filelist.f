# Generic synthesizable RTL. Keep this list aligned with RTL_SOURCES in ../../Makefile.
../../rtl/pkg/synth_pkg.sv
../../rtl/pkg/synth_register_pkg.sv
../../rtl/control/voice_bram_1r1w.sv
../../rtl/control/control_word_fifo.sv
../../rtl/control/control_action_fifo.sv
../../rtl/control/control_action_parser.sv
../../rtl/control/control_action_executor.sv
../../rtl/control/transactional_control_plane.sv
../../rtl/control/synth_control_plane.sv
../../rtl/memory/wave_memory_subsystem.sv
../../rtl/dsp/linear_interpolator.sv
../../rtl/dsp/gain_saturate.sv
../../rtl/dsp/voice_dsp_pipeline.sv
../../rtl/audio/output_sample_fifo.sv
../../rtl/audio/render_credit_scheduler.sv
../../rtl/voice/voice_phase_frame.sv
../../rtl/voice/voice_endpoint_fetch.sv
../../rtl/voice/multi_voice_pipeline.sv
../../rtl/top/wavetable_render_core.sv
../../rtl/top/wavetable_cached_render_core.sv

# Common board/peripheral RTL.
../common/rtl/fractional_tick_gen.sv
../common/rtl/spi_register_bridge.sv
../common/rtl/wavetable_common_status_regs.sv
../common/rtl/i2s_tx.sv
../common/rtl/wavetable_system_core.sv
../common/rtl/wavetable_i2s_output.sv
../common/rtl/wavetable_demo_system.sv

# Board-specific RTL. Replace this with the concrete board top after copying.
rtl/board_top.sv.template
