# Smart Artix Vivado batch synthesis skeleton.
# Usage:
#   cd fpga/smart_artix
#   vivado -mode batch -source scripts/vivado_synth.tcl

set board_name smart_artix
set part_name xc7a50tfgg484-2
set top_name smart_artix_top
set ip_root music-box-fpga.srcs/sources_1/ip
set clk_wiz_xci $ip_root/clk_wiz_0/clk_wiz_0.xci
set mig_xci $ip_root/mig_7series_0/mig_7series_0.xci

create_project $board_name build/vivado -part $part_name -force
set_property target_language Verilog [current_project]

foreach ip [list $clk_wiz_xci $mig_xci] {
  if {[file exists $ip]} {
    read_ip $ip
    generate_target all [get_files $ip]
  }
}

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
