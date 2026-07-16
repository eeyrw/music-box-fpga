# Smart Artix Vivado implementation flow.
# Usage:
#   cd build/fpga/smart_artix/vivado
#   vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/impl.tcl

source [file join [file dirname [file normalize [info script]]] project.tcl]
source [file join [file dirname [file normalize [info script]]] report_summary.tcl]

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

set impl_run [get_runs $impl_run_name]
set impl_status [get_property STATUS $impl_run]
if {[string match "*Complete*" $impl_status] && ![get_property NEEDS_REFRESH $impl_run]} {
  puts "INFO: $impl_run_name is complete and up-to-date; reusing existing run."
} else {
  if {![string match "*Not started*" $impl_status]} {
    reset_run $impl_run_name
  }
  launch_runs $impl_run_name -to_step route_design -jobs 4
  wait_on_run $impl_run_name
}
set impl_status [get_property STATUS [get_runs $impl_run_name]]
if {![string match "*Complete*" $impl_status]} {
  error "$impl_run_name failed with status: $impl_status"
}

open_run $impl_run_name
write_checkpoint -force $checkpoint_dir/post_route.dcp
report_utilization -file $report_dir/post_route_utilization.rpt
report_timing_summary -file $report_dir/post_route_timing.rpt
write_vivado_summary post_route [file join $report_dir post_route_summary.json]
