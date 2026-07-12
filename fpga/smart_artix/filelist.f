# Generic synthesizable RTL. Keep this list aligned with RTL_SOURCES in ../../Makefile.
../../rtl/pkg/synth_pkg.sv
../../rtl/bus/register_bus_if.sv
../../rtl/bus/spi_register_bridge.sv
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

# Board-specific RTL.
rtl/smart_artix_mig_stub.sv
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
