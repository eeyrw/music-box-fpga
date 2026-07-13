# Smart Artix Vivado implementation flow.
# Usage:
#   cd build/fpga/smart_artix/vivado
#   vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/impl.tcl

source [file join [file dirname [file normalize [info script]]] project.tcl]

launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
  error "synth_1 failed with status: $synth_status"
}

launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match "*Complete*" $impl_status]} {
  error "impl_1 failed with status: $impl_status"
}

open_run impl_1
write_checkpoint -force $checkpoint_dir/post_route.dcp
report_utilization -file $report_dir/post_route_utilization.rpt
report_timing_summary -file $report_dir/post_route_timing.rpt
