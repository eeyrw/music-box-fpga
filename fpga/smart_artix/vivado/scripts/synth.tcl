# Smart Artix Vivado synthesis flow.
# Usage:
#   cd build/fpga/smart_artix/vivado
#   vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/synth.tcl

source [file join [file dirname [file normalize [info script]]] project.tcl]

launch_runs synth_1 -jobs 4
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
  error "synth_1 failed with status: $synth_status"
}

open_run synth_1
write_checkpoint -force $checkpoint_dir/post_synth.dcp
report_utilization -file $report_dir/post_synth_utilization.rpt
report_timing_summary -file $report_dir/post_synth_timing.rpt
