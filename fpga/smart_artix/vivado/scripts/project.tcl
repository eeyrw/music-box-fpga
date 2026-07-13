# Smart Artix Vivado project generation.
# Usage:
#   cd build/fpga/smart_artix/vivado
#   vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/project.tcl

set board_name smart_artix
set part_name xc7a50tfgg484-2
set top_name smart_artix_top

set script_dir [file dirname [file normalize [info script]]]
set board_dir [file normalize [file join $script_dir ../..]]
set repo_root [file normalize [file join $board_dir ../..]]
set build_dir [file normalize [file join $repo_root build/fpga/smart_artix/vivado]]
set source_ip_root [file join $board_dir vivado/ip]
set build_ip_root $build_dir/ip
set checkpoint_dir $build_dir/checkpoints
set report_dir $build_dir/reports
set bitstream_dir $build_dir/bitstream
set log_dir $build_dir/logs

file mkdir $build_dir
file mkdir $checkpoint_dir
file mkdir $report_dir
file mkdir $bitstream_dir
file mkdir $log_dir

create_project $board_name $build_dir -part $part_name -force
set_property target_language Verilog [current_project]

file delete -force $build_ip_root
file mkdir $build_ip_root
foreach ip_name [list clk_wiz_0 mig_7series_0] {
  file copy -force $source_ip_root/$ip_name $build_ip_root
}

foreach ip [list \
  $build_ip_root/clk_wiz_0/clk_wiz_0.xci \
  $build_ip_root/mig_7series_0/mig_7series_0.xci \
] {
  if {[file exists $ip]} {
    read_ip $ip
    generate_target all [get_files $ip]
  }
}

set filelist_fd [open [file join $board_dir filelist.f] r]
set filelist_text [read $filelist_fd]
close $filelist_fd

foreach src [split $filelist_text "\n"] {
  set src [string trim $src]
  if {$src eq "" || [string match "#*" $src]} { continue }
  add_files [file normalize [file join $board_dir $src]]
}

add_files -fileset constrs_1 [file join $board_dir constraints/smart_artix.xdc]
set_property top $top_name [current_fileset]
update_compile_order -fileset sources_1
