# Current generic synthesizable RTL. Keep aligned with ../../rtl/filelist.f.
../../rtl/pkg/synth_pkg.sv
../../rtl/pkg/synth_register_pkg.sv
../../rtl/generated/synth_dsp_lut_pkg.sv
../../rtl/control/block_voice_event_executor.sv
../../rtl/control/block_voice_state_store.sv
../../rtl/dsp/block_interleaved_voice_dsp.sv
../../rtl/audio/stereo_chorus.sv
../../rtl/audio/fdn_reverb.sv
../../rtl/audio/effect_return_mixer.sv
../../rtl/audio/global_effects_chain.sv
../../rtl/audio/global_audio_effects_chain.sv
../../rtl/audio/lookahead_compressor.sv
../../rtl/audio/output_sample_fifo.sv
../../rtl/audio/render_credit_scheduler.sv
../../rtl/voice/mono_phase_frame.sv
../../rtl/voice/block_interleaved_envelope_frontend.sv
../../rtl/voice/block_mix_buffer.sv
../../rtl/voice/block_interleaved_voice_renderer.sv
../../rtl/voice/block_mono_voice_engine.sv
../../rtl/voice/voice_major_block_controller.sv
../../rtl/top/voice_major_render_core.sv

# Reusable board/peripheral RTL.
../common/rtl/fractional_tick_gen.sv
../common/rtl/spi_register_bridge.sv
../common/rtl/wavetable_register_fabric.sv
../common/rtl/wavetable_common_status_regs.sv
../common/rtl/i2s_tx.sv
../common/rtl/sd_native_pkg.sv
../common/rtl/sd_native_block_reader.sv
../common/rtl/sd_native_pin_phy.sv
../common/rtl/wavetable_i2s_output.sv

# Rename after copying to a concrete board directory.
rtl/board_top.sv.template
