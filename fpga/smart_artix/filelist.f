# Generic synthesizable RTL. Keep this list aligned with RTL_SOURCES in ../../Makefile.
../../rtl/pkg/synth_pkg.sv
../../rtl/control/voice_active_store.sv
../../rtl/control/voice_bram_1r1w.sv
../../rtl/control/voice_bram_1w2r.sv
../../rtl/control/voice_commit_engine.sv
../../rtl/control/voice_descriptor_store.sv
../../rtl/control/voice_runtime_store.sv
../../rtl/control/voice_register_bank.sv
../../rtl/memory/wave_memory_subsystem.sv
../../rtl/dsp/linear_interpolator.sv
../../rtl/dsp/gain_saturate.sv
../../rtl/dsp/voice_dsp_pipeline.sv
../../rtl/audio/output_sample_fifo.sv
../../rtl/voice/voice_phase_frame.sv
../../rtl/voice/voice_endpoint_fetch.sv
../../rtl/voice/multi_voice_pipeline.sv
../../rtl/top/wavetable_render_core.sv
../../rtl/top/wavetable_line_memory_core.sv

# Common board/peripheral RTL.
../common/rtl/fractional_tick_gen.sv
../common/rtl/spi_register_bridge.sv
../common/rtl/wavetable_system_debug_regs.sv
../common/rtl/i2s_tx.sv
../common/rtl/wavetable_spi_audio_system.sv

# Board-specific RTL.
rtl/smart_artix_mig_stub.sv
rtl/smart_artix_ddr3_debug_master.sv
rtl/smart_artix_ddr3_line_reader.sv
rtl/smart_artix_ddr3_rw_arbiter.sv
rtl/smart_artix_ddr3_asset_writer.sv
rtl/smart_artix_asset_loader.sv
rtl/smart_artix_fat_file_reader.sv
rtl/smart_artix_sd_ddr3_asset_loader.sv
rtl/smart_artix_sd_spi_block_reader.sv
rtl/smart_artix_sd_spi_asset_loader.sv
rtl/smart_artix_sd_spi_byte_master.sv
rtl/smart_artix_sd_spi_pin_asset_loader.sv
rtl/smart_artix_sd_native_block_reader.sv
rtl/smart_artix_sd_native_asset_loader.sv
rtl/smart_artix_sd_native_pin_phy.sv
rtl/smart_artix_sd_native_pin_asset_loader.sv
rtl/smart_artix_top.sv
