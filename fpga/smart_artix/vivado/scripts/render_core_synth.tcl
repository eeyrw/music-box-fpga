# Synthesis-only Smart Artix integration of the voice-major renderer and MIG.
# Run from the repository root:
#   /opt/Xilinx2051.1/2025.2/Vivado/bin/vivado -mode batch \
#     -source fpga/smart_artix/vivado/scripts/render_core_synth.tcl

set script_dir [file dirname [file normalize [info script]]]
set board_dir [file normalize [file join $script_dir ../..]]
set repo_root [file normalize [file join $board_dir ../..]]
set build_dir [file join $repo_root build/fpga/smart_artix/render_core_mig_synth]
set report_dir [file join $build_dir reports]
set checkpoint_dir [file join $build_dir checkpoints]
set project_dir [file join $build_dir project]
set copied_ip_dir [file join $build_dir ip]
set part_name xc7a50tfgg484-2
set top_name smart_artix_voice_major_synth_top

file mkdir $build_dir
file mkdir $report_dir
file mkdir $checkpoint_dir
file mkdir $copied_ip_dir
create_project -force render_core_mig $project_dir -part $part_name
set_property target_language Verilog [current_project]
set_property verilog_define {SYNTH_NUM_VOICES=256} [get_filesets sources_1]

proc add_filelist_sources {filelist_path base_dir} {
  set fd [open $filelist_path r]
  set text [read $fd]
  close $fd
  foreach source_line [split $text "\n"] {
    set source_line [string trim $source_line]
    if {$source_line eq "" || [string match "#*" $source_line]} {
      continue
    }
    add_files [file normalize [file join $base_dir $source_line]]
  }
}

add_filelist_sources [file join $repo_root rtl/filelist.f] [file join $repo_root rtl]
add_filelist_sources [file join $board_dir filelist.f] $board_dir

foreach ip_name [list smart_artix_clk_50m_to_200m smart_artix_ddr3_mig] {
  set source_ip_dir [file join $board_dir vivado ip $ip_name]
  set build_ip_dir [file join $copied_ip_dir $ip_name]
  if {![file exists $build_ip_dir]} {
    file copy -force $source_ip_dir $copied_ip_dir
  }
  set ip_file [file join $build_ip_dir ${ip_name}.xci]
  read_ip $ip_file
  generate_target all [get_files $ip_file]
}

set_property top $top_name [current_fileset]
update_compile_order -fileset sources_1
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
  error "synth_1 failed with status: $synth_status"
}
open_run synth_1

write_checkpoint -force [file join $checkpoint_dir post_synth.dcp]
report_utilization -file [file join $report_dir post_synth_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 \
  -file [file join $report_dir post_synth_utilization_hier_depth6.rpt]
report_timing_summary -delay_type min_max -check_timing_verbose \
  -file [file join $report_dir post_synth_timing.rpt]
report_timing -delay_type max -max_paths 100 -nworst 10 \
  -file [file join $report_dir post_synth_setup_paths.rpt]
report_methodology -file [file join $report_dir post_synth_methodology.rpt]
report_ram_utilization -file [file join $report_dir post_synth_ram_utilization.rpt]

puts "RENDER_CORE_MIG_SYNTH_COMPLETE build_dir=$build_dir"
