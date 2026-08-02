# Read the complete Smart Artix W25Q128JV configuration flash.
# This temporarily replaces the running FPGA design with Vivado's indirect SPI
# access core, then boots the FPGA from flash before exiting.
# Usage from the repository root:
#   make vivado-flash-readback

source [file join [file dirname [file normalize [info script]]] hardware_common.tcl]

set output_dir [file join $smart_artix_build_dir flash]
set output_file [file join $output_dir w25q128jv_full_readback.bin]
file mkdir $output_dir

set device ""
set access_core_may_be_loaded 0
set operation_status [catch {
  set device [smart_artix_open_device]
  set cfgmem [smart_artix_create_cfgmem $device]
  set access_core_may_be_loaded 1
  smart_artix_load_cfgmem_access_core $device
  readback_hw_cfgmem -all -force -format bin -file $output_file $cfgmem
  if {[file size $output_file] != 16777216} {
    error "Expected a 16 MiB W25Q128JV readback; got [file size $output_file] bytes"
  }
  puts "INFO: Read complete W25Q128JV contents to $output_file"
} operation_result operation_options]

set boot_status 0
if {$access_core_may_be_loaded && $device ne ""} {
  set boot_status [catch {
    smart_artix_boot_from_flash $device
  } boot_result boot_options]
}
smart_artix_close_hardware

if {$operation_status} {
  if {$boot_status} {
    puts stderr "ERROR: Flash readback failed and flash reboot also failed: $boot_result"
  }
  return -options $operation_options $operation_result
}
if {$boot_status} {
  return -options $boot_options $boot_result
}
