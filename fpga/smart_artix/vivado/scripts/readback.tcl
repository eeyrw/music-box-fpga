# Read the current Smart Artix FPGA configuration SRAM without reprogramming it.
# Usage from the repository root:
#   make vivado-readback

source [file join [file dirname [file normalize [info script]]] hardware_common.tcl]

set output_dir [file join $smart_artix_build_dir readback]
set output_file [file join $output_dir ${smart_artix_top_name}_readback.bin]
file mkdir $output_dir

set status [catch {
  set device [smart_artix_open_device]
  smart_artix_check_config_status $device "configuration readback precheck"
  readback_hw_device -force -bin_file $output_file $device
  smart_artix_check_config_status $device "configuration readback"
  puts "INFO: Read [file size $output_file] FPGA configuration bytes to $output_file"
} result options]
smart_artix_close_hardware
if {$status} {
  return -options $options $result
}
