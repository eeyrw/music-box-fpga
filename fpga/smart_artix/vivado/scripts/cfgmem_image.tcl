# Build the persistent SPIx4 configuration image for the Smart Artix W25Q128JV.
# Usage from the repository root:
#   make vivado-cfgmem-image

source [file join [file dirname [file normalize [info script]]] hardware_common.tcl]

set bit_file [file join $smart_artix_build_dir bitstream ${smart_artix_top_name}.bit]
set output_dir [file join $smart_artix_build_dir flash]
set output_base [file join $output_dir ${smart_artix_top_name}_spi_x4]
set output_file ${output_base}.mcs

if {![file exists $bit_file]} {
  error "Bitstream not found: $bit_file"
}
file mkdir $output_dir
write_cfgmem -force -format MCS -size 16 -interface SPIx4 \
  -loadbit "up 0x0 $bit_file" $output_base
if {![file exists $output_file]} {
  error "write_cfgmem did not create $output_file"
}
puts "INFO: Wrote Smart Artix W25Q128JV image: $output_file"
