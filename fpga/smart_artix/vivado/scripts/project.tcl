# Smart Artix Vivado project generation.
# Usage:
#   cd build/fpga/smart_artix/vivado
#   vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/project.tcl

set board_name smart_artix
set part_name xc7a50tfgg484-2
set top_name smart_artix_top
set synth_run_name synth_smart_artix_top
set impl_run_name impl_smart_artix_top

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
set project_file [file join $build_dir ${board_name}.xpr]

set force_rebuild 0
if {[info exists ::env(VIVADO_FORCE_REBUILD)] && $::env(VIVADO_FORCE_REBUILD) ne "0"} {
  set force_rebuild 1
}
set regenerate_ip 0
if {[info exists ::env(VIVADO_REGENERATE_IP)] && $::env(VIVADO_REGENERATE_IP) ne "0"} {
  set regenerate_ip 1
}

file mkdir $build_dir
file mkdir $checkpoint_dir
file mkdir $report_dir
file mkdir $bitstream_dir
file mkdir $log_dir

if {$force_rebuild && [file exists $project_file]} {
  close_project -quiet
  file delete -force $project_file [file join $build_dir ${board_name}.cache] \
    [file join $build_dir ${board_name}.hw] [file join $build_dir ${board_name}.ip_user_files] \
    [file join $build_dir ${board_name}.runs] [file join $build_dir ${board_name}.sim] \
    [file join $build_dir ${board_name}.srcs]
}

if {[file exists $project_file]} {
  open_project $project_file
} else {
  create_project $board_name $build_dir -part $part_name
}
set_property target_language Verilog [current_project]

if {[llength [get_runs -quiet $synth_run_name]] == 0 && [llength [get_runs -quiet synth_1]] != 0} {
  set_property NAME $synth_run_name [get_runs synth_1]
}
if {[llength [get_runs -quiet $impl_run_name]] == 0 && [llength [get_runs -quiet impl_1]] != 0} {
  set_property NAME $impl_run_name [get_runs impl_1]
}

file mkdir $build_ip_root
foreach ip_name [list smart_artix_clk_50m_to_200m smart_artix_ddr3_mig] {
  set source_ip_dir [file join $source_ip_root $ip_name]
  set build_ip_dir [file join $build_ip_root $ip_name]
  if {$regenerate_ip || ![file exists $build_ip_dir]} {
    file delete -force $build_ip_dir
    file copy -force $source_ip_dir $build_ip_root
  }
}

foreach ip [list \
  $build_ip_root/smart_artix_clk_50m_to_200m/smart_artix_clk_50m_to_200m.xci \
  $build_ip_root/smart_artix_ddr3_mig/smart_artix_ddr3_mig.xci \
] {
  if {[file exists $ip]} {
    if {[llength [get_files -quiet $ip]] == 0} {
      read_ip $ip
    }
    set ip_files [get_files $ip]
    set ip_dir [file dirname $ip]
    set ip_name [file rootname [file tail $ip]]
    set ip_dcp [file join $ip_dir ${ip_name}.dcp]
    if {$regenerate_ip || ![file exists $ip_dcp]} {
      generate_target all $ip_files
    }
  }
}

set filelist_fd [open [file join $board_dir filelist.f] r]
set filelist_text [read $filelist_fd]
close $filelist_fd

set expected_sources [list]
foreach src [split $filelist_text "\n"] {
  set src [string trim $src]
  if {$src eq "" || [string match "#*" $src]} { continue }
  lappend expected_sources [file normalize [file join $board_dir $src]]
}

foreach src $expected_sources {
  if {[llength [get_files -quiet $src]] == 0} {
    add_files $src
  }
}

set board_xdc [file normalize [file join $board_dir constraints/smart_artix.xdc]]
if {[llength [get_files -quiet $board_xdc]] == 0} {
  add_files -fileset constrs_1 $board_xdc
}
set_property top $top_name [current_fileset]
update_compile_order -fileset sources_1
