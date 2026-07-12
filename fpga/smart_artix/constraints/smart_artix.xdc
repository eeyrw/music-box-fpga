# Smart Artix XDC skeleton for XC7A50T-2FGG484I.
#
# The package pins below are temporary legal user-I/O assignments chosen only so
# Vivado can run early synthesis/implementation checks. Replace them with the
# Smart Artix schematic pins before connecting hardware.

# Primary input clock. The generated clock wizard XDC already creates the
# 50 MHz input clock on clk_in, so do not duplicate create_clock here.
set_property PACKAGE_PIN G4 [get_ports clk_in]
set_property IOSTANDARD LVCMOS33 [get_ports clk_in]

# Reset. Confirm polarity; smart_artix_top currently expects active-low rst_n.
set_property PACKAGE_PIN G3 [get_ports rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

# SPI control from external MCU or PC USB-to-SPI adapter.
set_property PACKAGE_PIN F4 [get_ports spi_sclk]
set_property PACKAGE_PIN F3 [get_ports spi_cs_n]
set_property PACKAGE_PIN G2 [get_ports spi_mosi]
set_property PACKAGE_PIN G1 [get_ports spi_miso]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_sclk spi_cs_n spi_mosi spi_miso}]

# I2S output to the simple codec. No MCLK or codec configuration pins are assumed.
set_property PACKAGE_PIN E3 [get_ports i2s_bclk]
set_property PACKAGE_PIN E2 [get_ports i2s_lrclk]
set_property PACKAGE_PIN E1 [get_ports i2s_sdata]
set_property IOSTANDARD LVCMOS33 [get_ports {i2s_bclk i2s_lrclk i2s_sdata}]

# Native SD card pins. These constraints are conditional because the current
# smart_artix_top does not expose the SD loader pins yet. When the SD pins are
# added to the board top, replace the PACKAGE_PIN and IOSTANDARD placeholders and
# keep pull-ups enabled on CMD and every DAT line. DAT1-DAT3 must not float during
# power-up; otherwise a card can enter the wrong mode or fail native-SD bring-up.
# set_property PACKAGE_PIN <SD_CLK_PIN> [get_ports sd_clk]
# set_property IOSTANDARD <IOSTANDARD> [get_ports sd_clk]
# set_property PACKAGE_PIN <SD_CMD_PIN> [get_ports sd_cmd]
# set_property IOSTANDARD <IOSTANDARD> [get_ports sd_cmd]
# set_property PULLUP true [get_ports sd_cmd]
# set_property PACKAGE_PIN <SD_DAT0_PIN> [get_ports {sd_dat[0]}]
# set_property PACKAGE_PIN <SD_DAT1_PIN> [get_ports {sd_dat[1]}]
# set_property PACKAGE_PIN <SD_DAT2_PIN> [get_ports {sd_dat[2]}]
# set_property PACKAGE_PIN <SD_DAT3_PIN> [get_ports {sd_dat[3]}]
# set_property IOSTANDARD <IOSTANDARD> [get_ports {sd_dat[*]}]
# set_property PULLUP true [get_ports {sd_dat[*]}]

# Debug LEDs.
set_property PACKAGE_PIN D2 [get_ports led_spi_error]
set_property PACKAGE_PIN C2 [get_ports led_underrun]
set_property PACKAGE_PIN B2 [get_ports led_sample_drop]
set_property PACKAGE_PIN B1 [get_ports led_deadline_miss]
set_property IOSTANDARD LVCMOS33 [get_ports {led_spi_error led_underrun led_sample_drop led_deadline_miss}]

# DDR3 pins belong to the Vivado MIG-generated XDC once the MT41K256M16TW
# controller is generated for BANK34. Do not hand-write incomplete DDR timing here.

# TODO: Add generated clock constraints after selecting the MMCM/PLL clocking.
# TODO: Add SPI external timing or CDC constraints after the SPI timing contract is fixed.
# TODO: Add I2S output timing constraints if required by the codec datasheet.
