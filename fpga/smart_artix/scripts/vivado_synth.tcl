# Smart Artix Vivado batch synthesis skeleton.
# Usage:
#   cd fpga/smart_artix
#   vivado -mode batch -source scripts/vivado_synth.tcl

set board_name smart_artix
set part_name <xc7a50t-package-speed>
set top_name smart_artix_top

create_project $board_name build/vivado -part $part_name -force
set_property target_language SystemVerilog [current_project]

foreach src [split [read [open filelist.f r]] "\n"] {
  set src [string trim $src]
  if {$src eq "" || [string match "#*" $src]} { continue }
  add_files $src
}

add_files -fileset constrs_1 constraints/smart_artix.xdc
set_property top $top_name [current_fileset]

update_compile_order -fileset sources_1
synth_design -top $top_name -part $part_name
write_checkpoint -force build/vivado/post_synth.dcp
report_utilization -file build/vivado/post_synth_utilization.rpt
report_timing_summary -file build/vivado/post_synth_timing.rpt
