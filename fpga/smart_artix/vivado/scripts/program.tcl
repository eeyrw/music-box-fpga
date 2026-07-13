# Smart Artix Vivado hardware programming flow.
# Usage:
#   cd build/fpga/smart_artix/vivado
#   vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/program.tcl

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

set hw_device [lindex [get_hw_devices] 0]
if {$hw_device eq ""} {
  error "No hardware device found"
}

current_hw_device $hw_device
refresh_hw_device $hw_device
set_property PROGRAM.FILE $bit_file $hw_device
if {[file exists $ltx_file]} {
  set_property PROBES.FILE $ltx_file $hw_device
}
program_hw_devices $hw_device
