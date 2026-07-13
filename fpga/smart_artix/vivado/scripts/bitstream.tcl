# Smart Artix Vivado bitstream flow.
# Usage:
#   cd build/fpga/smart_artix/vivado
#   vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/bitstream.tcl

source [file join [file dirname [file normalize [info script]]] project.tcl]

launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
  error "synth_1 failed with status: $synth_status"
}

launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match "*Complete*" $impl_status]} {
  error "impl_1 failed with status: $impl_status"
}

set run_bit $build_dir/$board_name.runs/impl_1/${top_name}.bit
if {[file exists $run_bit]} {
  file copy -force $run_bit $bitstream_dir/${top_name}.bit
}
