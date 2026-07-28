# Superseded renderer source list. This is intentionally separate from the
# production rtl/filelist.f.
../../../rtl/pkg/synth_pkg.sv
../../../rtl/pkg/synth_register_pkg.sv
../../../rtl/generated/synth_dsp_lut_pkg.sv
../../../rtl/legacy/control/voice_bram_1r1w.sv
../../../rtl/control/control_word_fifo.sv
../../../rtl/legacy/control/control_action_fifo.sv
../../../rtl/legacy/control/control_action_parser.sv
../../../rtl/legacy/control/control_action_executor.sv
../../../rtl/legacy/control/transactional_control_plane.sv
../../../rtl/legacy/control/synth_control_plane.sv
../../../rtl/legacy/memory/wave_memory_subsystem.sv
../../../rtl/legacy/memory/voice_line_cache.sv
../../../rtl/legacy/dsp/linear_interpolator.sv
../../../rtl/legacy/dsp/gain_saturate.sv
../../../rtl/legacy/dsp/voice_dsp_pipeline.sv
../../../rtl/audio/lookahead_compressor.sv
../../../rtl/audio/output_sample_fifo.sv
../../../rtl/audio/render_credit_scheduler.sv
../../../rtl/legacy/voice/voice_phase_frame.sv
../../../rtl/legacy/voice/voice_endpoint_fetch.sv
../../../rtl/legacy/voice/multi_voice_pipeline.sv
../../../rtl/legacy/top/wavetable_render_core.sv
../../../rtl/legacy/top/wavetable_cached_render_core.sv

# Common board/peripheral RTL.
../../common/rtl/fractional_tick_gen.sv
../../common/rtl/spi_register_bridge.sv
../../common/rtl/wavetable_common_status_regs.sv
../../common/rtl/i2s_tx.sv
../../common/legacy/wavetable_system_core.sv
../../common/rtl/wavetable_i2s_output.sv
../../common/legacy/wavetable_demo_system.sv

# Board-specific RTL. Replace this with the concrete board top after copying.
rtl/board_top.sv.template
