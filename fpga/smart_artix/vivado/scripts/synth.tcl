# Smart Artix Vivado synthesis flow.
# Usage:
#   cd build/fpga/smart_artix/vivado
#   vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/synth.tcl

source [file join [file dirname [file normalize [info script]]] project.tcl]

set synth_run [get_runs $synth_run_name]
set synth_status [get_property STATUS $synth_run]

if {[string match "*Complete*" $synth_status] && ![get_property NEEDS_REFRESH $synth_run]} {
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

open_run $synth_run_name
write_checkpoint -force $checkpoint_dir/post_synth.dcp
report_utilization -file $report_dir/post_synth_utilization.rpt
report_utilization -hierarchical -file $report_dir/post_synth_utilization_hier.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $report_dir/post_synth_utilization_hier_depth4.rpt
report_timing_summary -file $report_dir/post_synth_timing.rpt
