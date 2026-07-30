# Smart Artix Vivado bitstream flow.
# Usage from the repository root:
#   make vivado-bitstream

source [file join [file dirname [file normalize [info script]]] project.tcl]

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
}

set impl_status [get_property STATUS [get_runs $impl_run_name]]
if {![string match "*Complete*" $impl_status]} {
  error "$impl_run_name failed with status: $impl_status"
}

if {![file exists $run_bit]} {
  error "Bitstream run completed without producing $run_bit"
}
set output_bit $bitstream_dir/${top_name}.bit
file copy -force $run_bit $output_bit
set run_ltx $build_dir/$board_name.runs/$impl_run_name/${top_name}.ltx
if {[file exists $run_ltx]} {
  file copy -force $run_ltx $bitstream_dir/${top_name}.ltx
}
puts "INFO: Wrote Smart Artix bitstream: $output_bit"
