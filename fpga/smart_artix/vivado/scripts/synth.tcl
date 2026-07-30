# Smart Artix Vivado synthesis flow.
# Usage from the repository root:
#   make vivado-synth

source [file join [file dirname [file normalize [info script]]] project.tcl]
source [file join [file dirname [file normalize [info script]]] report_summary.tcl]

set synth_run [get_runs $synth_run_name]
set synth_status [get_property STATUS $synth_run]

if {![string match "*Not started*" $synth_status]} {
  reset_run $synth_run_name
}
puts "INFO: forcing a fresh synthesis run for the requested build configuration."
launch_runs $synth_run_name -jobs $vivado_jobs
wait_on_run $synth_run_name

set synth_status [get_property STATUS [get_runs $synth_run_name]]
if {![string match "*Complete*" $synth_status]} {
  error "$synth_run_name failed with status: $synth_status"
}

open_run $synth_run_name
write_checkpoint -force $checkpoint_dir/post_synth.dcp
report_utilization -file $report_dir/post_synth_utilization.rpt
report_utilization -hierarchical -file $report_dir/post_synth_utilization_hier.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $report_dir/post_synth_utilization_hier_depth4.rpt
report_timing_summary -report_unconstrained -file $report_dir/post_synth_timing.rpt
write_optional_report methodology [list report_methodology] \
  [file join $report_dir post_synth_methodology.rpt]
write_optional_report qor_assessment [list report_qor_assessment] \
  [file join $report_dir post_synth_qor_assessment.rpt]
write_optional_report high_fanout [list report_high_fanout_nets -timing -load_types -max_nets 100] \
  [file join $report_dir post_synth_high_fanout.rpt]
write_optional_report clock_interaction [list report_clock_interaction -delay_type min_max] \
  [file join $report_dir post_synth_clock_interaction.rpt]
write_optional_report check_timing [list check_timing -verbose] \
  [file join $report_dir post_synth_check_timing.rpt]
write_vivado_summary post_synth [file join $report_dir post_synth_summary.json]
