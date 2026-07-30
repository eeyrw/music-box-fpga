# Smart Artix Vivado hardware programming flow.
# Usage from the repository root, with one Smart Artix FPGA attached:
#   make vivado-program

set top_name smart_artix_top
set script_dir [file dirname [file normalize [info script]]]
set board_dir [file normalize [file join $script_dir ../..]]
set repo_root [file normalize [file join $board_dir ../..]]
set build_dir [file normalize [file join $repo_root build/fpga/smart_artix/vivado]]
set bit_file $build_dir/bitstream/${top_name}.bit
set ltx_file $build_dir/bitstream/${top_name}.ltx

if {![file exists $bit_file]} {
  error "Bitstream not found: $bit_file"
}

open_hw_manager
connect_hw_server
open_hw_target

set all_hw_devices [get_hw_devices -quiet]
set matching_hw_devices [get_hw_devices -quiet xc7a50t*]
if {[llength $matching_hw_devices] == 0} {
  error "No xc7a50t hardware device found; detected devices: $all_hw_devices"
}
if {[llength $matching_hw_devices] != 1} {
  error "Expected exactly one xc7a50t hardware device, found: $matching_hw_devices"
}
set hw_device [lindex $matching_hw_devices 0]

current_hw_device $hw_device
refresh_hw_device $hw_device
set_property PROGRAM.FILE $bit_file $hw_device
if {[file exists $ltx_file]} {
  set_property PROBES.FILE $ltx_file $hw_device
}
program_hw_devices $hw_device
puts "INFO: Programmed volatile FPGA configuration on $hw_device from $bit_file"
