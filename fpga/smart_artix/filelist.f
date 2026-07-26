# Smart Artix integration RTL, relative to this directory. Vivado prepends the
# generic synthesizable sources from ../../rtl/filelist.f at project load time.
../common/rtl/fractional_tick_gen.sv
../common/rtl/spi_register_bridge.sv
../common/rtl/wavetable_register_fabric.sv
../common/rtl/wavetable_common_status_regs.sv
../common/rtl/i2s_tx.sv
../common/rtl/sd_native_block_reader.sv
../common/rtl/sd_native_pin_phy.sv
../common/rtl/wavetable_system_core.sv
../common/rtl/wavetable_i2s_output.sv
../common/rtl/wavetable_demo_system.sv

# Board-specific RTL.
rtl/smart_artix_pkg.sv
rtl/smart_artix_mig_stub.sv
rtl/smart_artix_ddr3_reg_access_master.sv
rtl/smart_artix_ddr3_line_reader.sv
rtl/smart_artix_ddr3_rw_arbiter.sv
rtl/smart_artix_ddr3_subsystem.sv
rtl/smart_artix_platform_regs.sv
rtl/smart_artix_ddr3_asset_writer.sv
rtl/smart_artix_asset_loader.sv
rtl/smart_artix_sd_native_asset_loader.sv
rtl/smart_artix_top.sv
