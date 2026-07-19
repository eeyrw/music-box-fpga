# Smart Artix XDC for XC7A50T-2FGG484I.
# Pin locations are taken from fpga/smart_artix/docs/Smart_Artix_Pin_Assignment.txt.
# Current SPI, I2S, and status outputs are exported through BANK15 expansion
# header pins because the pin table does not list dedicated board connectors for
# those signals.

# Primary input clock. The generated clock wizard XDC already creates the
# 50 MHz input clock on clk_in, so do not duplicate create_clock here.
set_property PACKAGE_PIN Y18 [get_ports clk_in]
set_property IOSTANDARD LVCMOS33 [get_ports clk_in]

# RESET_N pushbutton. smart_artix_top expects active-low rst_n.
set_property PACKAGE_PIN T20 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

# SPI control from external MCU or PC USB-to-SPI adapter on BANK15 header pins.
set_property PACKAGE_PIN G13 [get_ports spi_sclk]
set_property PACKAGE_PIN H13 [get_ports spi_cs_n]
set_property PACKAGE_PIN G18 [get_ports spi_mosi]
set_property PACKAGE_PIN G17 [get_ports spi_miso]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_sclk spi_cs_n spi_mosi spi_miso}]

# I2S output to an external simple codec on BANK15 header pins. No MCLK or codec
# configuration pins are assumed.
set_property PACKAGE_PIN G16 [get_ports i2s_bclk]
set_property PACKAGE_PIN G15 [get_ports i2s_lrclk]
set_property PACKAGE_PIN H15 [get_ports i2s_sdata]
set_property IOSTANDARD LVCMOS33 [get_ports {i2s_bclk i2s_lrclk i2s_sdata}]

# Native SD card pins. Some boards label these nets by their SPI-mode role:
# SCK -> SD_CLK, MOSI -> SD_CMD, MISO -> SD_D0, and CS -> SD_D3. Native 4-bit
# mode also uses SD_D1 and SD_D2. The current board top is a read-only SD host:
# the SD card drives DAT[3:0] during CMD6 status and read data blocks, and the
# FPGA samples those pins as inputs. The FPGA must not actively drive DAT[3:0]
# in this path.
# Keep pull-ups enabled on CMD and DAT[3:0]. DAT1-DAT3 must not float during
# power-up; otherwise a card can enter the wrong mode or fail native-SD bring-up.
set_property PACKAGE_PIN V20 [get_ports sd_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sd_clk]
set_property PACKAGE_PIN Y22 [get_ports sd_cmd]
set_property IOSTANDARD LVCMOS33 [get_ports sd_cmd]
set_property PULLUP true [get_ports sd_cmd]
set_property PACKAGE_PIN U20 [get_ports {sd_dat[0]}]
set_property PACKAGE_PIN V18 [get_ports {sd_dat[1]}]
set_property PACKAGE_PIN V22 [get_ports {sd_dat[2]}]
set_property PACKAGE_PIN Y21 [get_ports {sd_dat[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sd_dat[*]}]
set_property PULLUP true [get_ports {sd_dat[*]}]

# Status outputs on BANK15 header pins.
set_property PACKAGE_PIN J15 [get_ports led_spi_error]
set_property PACKAGE_PIN G20 [get_ports led_underrun]
set_property PACKAGE_PIN H20 [get_ports led_sample_drop]
set_property PACKAGE_PIN H18 [get_ports led_deadline_miss]
set_property PACKAGE_PIN H17 [get_ports led_asset_loaded]
set_property PACKAGE_PIN J21 [get_ports led_loader_error]
set_property IOSTANDARD LVCMOS33 [get_ports {led_spi_error led_underrun led_sample_drop led_deadline_miss led_asset_loaded led_loader_error}]

# DDR3 pins belong to the Vivado MIG-generated XDC once the MT41K256M16TW
# controller is generated for BANK34. Do not hand-write incomplete DDR timing here.

# MIG temperature monitor crosses from the 200 MHz clock-wizard domain into the
# 100 MHz MIG UI domain through device_temp_sync_r1_reg[*]. MIG's generated XDC
# relaxes setup with a max-delay constraint; this hold-only exception prevents
# Vivado from treating the first synchronizer stage as a same-edge related-clock
# hold path.
set_false_path -hold \
  -from [get_pins -hier -quiet -regexp {.*temp_mon_enabled\.u_tempmon/xadc_supplied_temperature\.temperature_reg\[[0-9]+\]/C}] \
  -to [get_pins -hier -quiet -regexp {.*temp_mon_enabled\.u_tempmon/device_temp_sync_r1_reg\[[0-9]+\]/D}]

# The MIG 7-series PHY contains generated PHASER-to-OSERDES reset paths that
# share related clocks but are reset-control paths inside the vendor PHY. Keep
# this hold exception scoped to OSERDES reset pins only.
set_false_path -hold \
  -from [get_pins -hier -quiet -regexp {.*u_ddr_mc_phy/ddr_phy_4lanes_0\.u_ddr_phy_4lanes/ddr_byte_lane_[A-D]\.ddr_byte_lane_[A-D]/phaser_out/OCLK}] \
  -to [get_pins -hier -quiet -regexp {.*u_ddr_mc_phy/ddr_phy_4lanes_0\.u_ddr_phy_4lanes/ddr_byte_lane_[A-D]\.ddr_byte_lane_[A-D]/ddr_byte_group_io/output_\[[0-9]+\]\.oserdes_dq_\.(sdr|ddr)\.oserdes_dq_i/RST}]
set_false_path -hold \
  -from [get_pins -hier -quiet -regexp {.*u_ddr_mc_phy/ddr_phy_4lanes_0\.u_ddr_phy_4lanes/ddr_byte_lane_[A-D]\.ddr_byte_lane_[A-D]/phaser_out/OCLK}] \
  -to [get_pins -hier -quiet -regexp {.*u_ddr_mc_phy/ddr_phy_4lanes_0\.u_ddr_phy_4lanes/ddr_byte_lane_[A-D]\.ddr_byte_lane_[A-D]/ddr_byte_group_io/slave_ts\.oserdes_slave_ts/RST}]

# TODO: Add generated clock constraints after selecting the MMCM/PLL clocking.
# TODO: Add SPI external timing or CDC constraints after the SPI timing contract is fixed.
# TODO: Add I2S output timing constraints if required by the codec datasheet.
