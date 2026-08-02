# Smart Artix Vivado bitstream flow.
# Usage from the repository root:
#   make vivado-bitstream

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
set run_bit $build_dir/$board_name.runs/$impl_run_name/${top_name}.bit
set impl_is_current [expr {![get_property NEEDS_REFRESH $impl_run]}]
set implementation_was_launched 0
if {[string match "*Complete*" $impl_status] && $impl_is_current && [file exists $run_bit]} {
  puts "INFO: $impl_run_name and its bitstream are complete and up-to-date; reusing existing run."
} else {
  if {!$impl_is_current || ![string match "*Complete*" $impl_status]} {
    if {![string match "*Not started*" $impl_status]} {
      reset_run $impl_run_name
    }
  } else {
    puts "INFO: $impl_run_name is routed but has no bitstream; continuing to write_bitstream."
  }
  launch_runs $impl_run_name -to_step write_bitstream -jobs $vivado_jobs
  wait_on_run $impl_run_name
  set implementation_was_launched 1
}

set impl_status [get_property STATUS [get_runs $impl_run_name]]
if {![string match "*Complete*" $impl_status]} {
  error "$impl_run_name failed with status: $impl_status"
}

if {![file exists $run_bit]} {
  error "Bitstream run completed without producing $run_bit"
}

# Keep the bitstream entry point self-contained when it had to run
# implementation itself, but do not repeat the expensive report suite after a
# separate successful vivado-impl invocation.
set signoff_summary [file join $report_dir post_route_summary.json]
set signoff_checkpoint [file join $checkpoint_dir post_route.dcp]
set need_signoff_reports [expr {$implementation_was_launched ||
  ![file exists $signoff_summary] || ![file exists $signoff_checkpoint]}]
if {$need_signoff_reports} {
  open_run $impl_run_name
  write_checkpoint -force $signoff_checkpoint
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
  write_vivado_summary post_route $signoff_summary
} else {
  puts "INFO: Reusing existing post-route signoff reports."
}

set output_bit $bitstream_dir/${top_name}.bit
file copy -force $run_bit $output_bit
# file copy preserves the run artifact's old timestamp. Mark the public output
# with this successful validation time so Make can cache the checked input set.
file mtime $output_bit [clock seconds]
set run_ltx $build_dir/$board_name.runs/$impl_run_name/${top_name}.ltx
if {[file exists $run_ltx]} {
  file copy -force $run_ltx $bitstream_dir/${top_name}.ltx
}
puts "INFO: Wrote Smart Artix bitstream: $output_bit"
