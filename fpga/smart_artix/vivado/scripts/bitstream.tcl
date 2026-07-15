# Smart Artix Vivado bitstream flow.
# Usage:
#   cd build/fpga/smart_artix/vivado
#   vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/bitstream.tcl

source [file join [file dirname [file normalize [info script]]] project.tcl]

set synth_status [get_property STATUS [get_runs $synth_run_name]]
if {[string match "*Complete*" $synth_status] && ![get_property NEEDS_REFRESH [get_runs $synth_run_name]]} {
  puts "INFO: $synth_run_name is complete and up-to-date; reusing existing run."
} else {
  if {![string match "*Not started*" $synth_status]} {
    reset_run $synth_run_name
  }
  launch_runs $synth_run_name -jobs 4
  wait_on_run $synth_run_name
}
set synth_status [get_property STATUS [get_runs $synth_run_name]]
if {![string match "*Complete*" $synth_status]} {
  error "$synth_run_name failed with status: $synth_status"
}

launch_runs $impl_run_name -to_step write_bitstream -jobs 4
wait_on_run $impl_run_name

set impl_status [get_property STATUS [get_runs $impl_run_name]]
if {![string match "*Complete*" $impl_status]} {
  error "$impl_run_name failed with status: $impl_status"
}

set run_bit $build_dir/$board_name.runs/$impl_run_name/${top_name}.bit
if {[file exists $run_bit]} {
  file copy -force $run_bit $bitstream_dir/${top_name}.bit
}
