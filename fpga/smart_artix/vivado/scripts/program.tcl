# Smart Artix Vivado hardware programming flow.
# Usage from the repository root, with one Smart Artix FPGA attached:
#   make vivado-program

set script_dir [file dirname [file normalize [info script]]]
source [file join $script_dir hardware_common.tcl]

set bit_file $smart_artix_build_dir/bitstream/${smart_artix_top_name}.bit
set ltx_file $smart_artix_build_dir/bitstream/${smart_artix_top_name}.ltx

if {![file exists $bit_file]} {
  error "Bitstream not found: $bit_file"
}

set hw_device [smart_artix_open_device]
set_property PROGRAM.FILE $bit_file $hw_device
if {[file exists $ltx_file]} {
  set_property PROBES.FILE $ltx_file $hw_device
}
program_hw_devices $hw_device
after 500
smart_artix_check_config_status $hw_device "volatile SRAM programming"
puts "INFO: Programmed volatile FPGA configuration on $hw_device from $bit_file"
smart_artix_close_hardware
