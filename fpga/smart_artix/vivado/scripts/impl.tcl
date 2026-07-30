# Smart Artix Vivado implementation flow.
# Usage from the repository root:
#   make vivado-impl

source [file join [file dirname [file normalize [info script]]] project.tcl]
source [file join [file dirname [file normalize [info script]]] report_summary.tcl]

set synth_status [get_property STATUS [get_runs $synth_run_name]]
if {[string match "*Complete*" $synth_status] && ![get_property NEEDS_REFRESH [get_runs $synth_run_name]]} {
  puts "INFO: $synth_run_name is complete and up-to-date; reusing existing run."
} else {
  if {![string match "*Not started*" $synth_status]} {
    reset_run $synth_run_name
  }
  launch_runs $synth_run_name -jobs $vivado_jobs
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
  launch_runs $impl_run_name -to_step $impl_to_step -jobs $vivado_jobs
  wait_on_run $impl_run_name
}
set impl_status [get_property STATUS [get_runs $impl_run_name]]
if {![string match "*Complete*" $impl_status]} {
  error "$impl_run_name failed with status: $impl_status"
}

open_run $impl_run_name
write_checkpoint -force $checkpoint_dir/post_route.dcp
report_utilization -file $report_dir/post_route_utilization.rpt
report_utilization -hierarchical -hierarchical_depth 4 \
  -file $report_dir/post_route_utilization_hier_depth4.rpt
report_timing_summary -report_unconstrained -file $report_dir/post_route_timing.rpt
report_timing -delay_type max -max_paths 100 -nworst 10 \
  -file $report_dir/post_route_setup_paths.rpt
report_timing -delay_type min -max_paths 100 -nworst 10 \
  -file $report_dir/post_route_hold_paths.rpt
report_route_status -file $report_dir/post_route_route_status.rpt
report_drc -file $report_dir/post_route_drc.rpt
write_optional_report methodology [list report_methodology] \
  [file join $report_dir post_route_methodology.rpt]
write_optional_report qor_assessment [list report_qor_assessment] \
  [file join $report_dir post_route_qor_assessment.rpt]
write_optional_report qor_suggestions [list report_qor_suggestions] \
  [file join $report_dir post_route_qor_suggestions.rpt]
write_optional_report congestion [list report_design_analysis -congestion] \
  [file join $report_dir post_route_congestion.rpt]
write_optional_report high_fanout [list report_high_fanout_nets -timing -load_types -max_nets 100] \
  [file join $report_dir post_route_high_fanout.rpt]
write_optional_report clock_interaction [list report_clock_interaction -delay_type min_max] \
  [file join $report_dir post_route_clock_interaction.rpt]
write_optional_report check_timing [list check_timing -verbose] \
  [file join $report_dir post_route_check_timing.rpt]
write_vivado_summary post_route [file join $report_dir post_route_summary.json]
