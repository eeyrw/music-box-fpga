# Erase, program, and verify the Smart Artix W25Q128JV configuration flash.
# Usage from the repository root:
#   make vivado-flash-program CONFIRM_FLASH_PROGRAM=YES

source [file join [file dirname [file normalize [info script]]] hardware_common.tcl]

if {![info exists ::env(SMART_ARTIX_FLASH_PROGRAM_CONFIRM)] ||
    $::env(SMART_ARTIX_FLASH_PROGRAM_CONFIRM) ne "YES"} {
  error "Flash programming requires CONFIRM_FLASH_PROGRAM=YES on the make command line"
}

set image_file [file join $smart_artix_build_dir flash ${smart_artix_top_name}_spi_x4.mcs]
if {![file exists $image_file]} {
  error "Configuration-memory image not found: $image_file"
}

set device ""
set access_core_may_be_loaded 0
set operation_status [catch {
  set device [smart_artix_open_device]
  set cfgmem [smart_artix_create_cfgmem $device]
  set_property PROGRAM.FILES [list $image_file] $cfgmem
  set_property PROGRAM.BLANK_CHECK 0 $cfgmem
  set_property PROGRAM.ERASE 1 $cfgmem
  set_property PROGRAM.CFG_PROGRAM 1 $cfgmem
  set_property PROGRAM.VERIFY 1 $cfgmem
  set access_core_may_be_loaded 1
  smart_artix_load_cfgmem_access_core $device
  program_hw_cfgmem -hw_cfgmem $cfgmem
  puts "INFO: Programmed and verified W25Q128JV from $image_file"
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
    puts stderr "ERROR: Flash programming failed and flash reboot also failed: $boot_result"
  }
  return -options $operation_options $operation_result
}
if {$boot_status} {
  return -options $boot_options $boot_result
}
