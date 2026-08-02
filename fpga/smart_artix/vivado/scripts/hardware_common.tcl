# Shared Smart Artix Vivado hardware helpers.

set smart_artix_top_name smart_artix_top
set smart_artix_device_pattern xc7a50t*
set smart_artix_cfgmem_part_name w25q128jvq-spi-x1_x2_x4
set smart_artix_hw_frequency 15000000
if {[info exists ::env(SMART_ARTIX_HW_FREQUENCY)] &&
    $::env(SMART_ARTIX_HW_FREQUENCY) ne ""} {
  if {![string is integer -strict $::env(SMART_ARTIX_HW_FREQUENCY)] ||
      $::env(SMART_ARTIX_HW_FREQUENCY) <= 0} {
    error "SMART_ARTIX_HW_FREQUENCY must be a positive integer"
  }
  set smart_artix_hw_frequency $::env(SMART_ARTIX_HW_FREQUENCY)
}

set smart_artix_script_dir [file dirname [file normalize [info script]]]
set smart_artix_board_dir [file normalize [file join $smart_artix_script_dir ../..]]
set smart_artix_repo_root [file normalize [file join $smart_artix_board_dir ../..]]
set smart_artix_build_dir [file normalize \
  [file join $smart_artix_repo_root build/fpga/smart_artix/vivado]]

proc smart_artix_open_device {} {
  global smart_artix_device_pattern smart_artix_hw_frequency

  open_hw_manager
  connect_hw_server
  open_hw_target

  set target [current_hw_target]
  set supported_frequencies [list_property_value PARAM.FREQUENCY $target]
  if {[lsearch -exact $supported_frequencies $smart_artix_hw_frequency] < 0} {
    error "JTAG frequency $smart_artix_hw_frequency is unsupported; available: $supported_frequencies"
  }
  set_property PARAM.FREQUENCY $smart_artix_hw_frequency $target
  puts "INFO: Smart Artix JTAG frequency: [get_property PARAM.FREQUENCY $target] Hz"

  set all_devices [get_hw_devices -quiet]
  set devices [get_hw_devices -quiet $smart_artix_device_pattern]
  if {[llength $devices] != 1} {
    error "Expected exactly one $smart_artix_device_pattern device; detected devices: $all_devices"
  }

  set device [lindex $devices 0]
  current_hw_device $device
  refresh_hw_device -update_hw_probes false $device
  return $device
}

proc smart_artix_close_hardware {} {
  catch {close_hw_target}
  catch {close_hw_manager}
}

proc smart_artix_create_cfgmem {device} {
  global smart_artix_cfgmem_part_name

  # Vivado can return the same named cfgmem part once per compatible FPGA
  # family. Collapse those catalog aliases before validating the selection.
  set parts [lsort -unique [get_cfgmem_parts -quiet $smart_artix_cfgmem_part_name]]
  if {[llength $parts] != 1} {
    error "Expected exactly one cfgmem part named $smart_artix_cfgmem_part_name; found: $parts"
  }
  return [create_hw_cfgmem -hw_device $device [lindex $parts 0]]
}

proc smart_artix_load_cfgmem_access_core {device} {
  set helper_bit [get_property PROGRAM.HW_CFGMEM_BITFILE $device]
  if {$helper_bit eq ""} {
    error "Vivado did not select a cfgmem access bitstream"
  }
  # create_hw_bitstream materializes this Vivado-owned image on demand; the
  # PROGRAM.HW_CFGMEM_BITFILE path need not exist before this call.
  create_hw_bitstream -hw_device $device $helper_bit
  program_hw_devices $device
  refresh_hw_device -update_hw_probes false $device
  puts "INFO: Loaded temporary cfgmem access core from $helper_bit"
}

proc smart_artix_check_config_status {device context} {
  refresh_hw_device -update_hw_probes false $device

  set done [get_property REGISTER.CONFIG_STATUS.BIT13_DONE_INTERNAL_SIGNAL_STATUS $device]
  set done_pin [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $device]
  set eos [get_property REGISTER.CONFIG_STATUS.BIT04_END_OF_STARTUP_(EOS)_STATUS $device]
  set crc_error [get_property REGISTER.CONFIG_STATUS.BIT00_CRC_ERROR $device]
  set idcode_error [get_property REGISTER.CONFIG_STATUS.BIT15_IDCODE_ERROR $device]
  puts "INFO: $context status: DONE=$done DONE_PIN=$done_pin EOS=$eos CRC_ERROR=$crc_error IDCODE_ERROR=$idcode_error"

  if {!$done || !$done_pin || !$eos || $crc_error || $idcode_error} {
    error "FPGA did not enter a valid configuration after $context"
  }
}

proc smart_artix_boot_from_flash {device} {
  boot_hw_device $device
  after 1000
  smart_artix_check_config_status $device "flash boot"
}
