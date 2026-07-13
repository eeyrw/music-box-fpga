# Smart Artix Vivado synthesis flow.
# Usage:
#   cd build/fpga/smart_artix/vivado
#   vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/synth.tcl

source [file join [file dirname [file normalize [info script]]] project.tcl]

set synth_run [get_runs synth_1]
set synth_status [get_property STATUS $synth_run]

if {[string match "*Complete*" $synth_status] && ![get_property NEEDS_REFRESH $synth_run]} {
  puts "INFO: synth_1 is complete and up-to-date; reusing existing run."
} else {
  if {[string match "*Complete*" $synth_status] || [get_property NEEDS_REFRESH $synth_run]} {
    reset_run synth_1
  }
  launch_runs synth_1 -jobs 4
  wait_on_run synth_1
}

set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
  error "synth_1 failed with status: $synth_status"
}

open_run synth_1
write_checkpoint -force $checkpoint_dir/post_synth.dcp
report_utilization -file $report_dir/post_synth_utilization.rpt
report_timing_summary -file $report_dir/post_synth_timing.rpt
