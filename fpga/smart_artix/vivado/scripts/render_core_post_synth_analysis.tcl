# Hierarchical timing analysis for an existing renderer/MIG synthesis run.
# Run from the repository root after render_core_synth.tcl.

set script_dir [file dirname [file normalize [info script]]]
set board_dir [file normalize [file join $script_dir ../..]]
set repo_root [file normalize [file join $board_dir ../..]]
set build_dir [file join $repo_root build/fpga/smart_artix/render_core_mig_synth]
set report_dir [file join $build_dir reports]
set project_file [file join $build_dir project render_core_mig.xpr]

open_project $project_file
open_run synth_1

set timing_groups [list \
    state_store {core/state_store/*} \
    controller {core/controller/*} \
    envelope {core/controller/engine/envelope/*} \
    renderer {core/controller/engine/renderer/*} \
    renderer_dsp {core/controller/engine/renderer/dsp/*} \
    line_cache {core/controller/engine/renderer/line_cache/*} \
    mix_buffer {core/controller/mix_buffer/*} \
    memory_subsystem {memory_subsystem/*} \
    mig {ddr3_memory_controller/*}]

foreach {group_name hierarchy_pattern} $timing_groups {
  set endpoints [get_cells -quiet -hierarchical -filter \
      "IS_SEQUENTIAL == 1 && NAME =~ $hierarchy_pattern"]
  if {[llength $endpoints] == 0} {
    puts "WARNING: no sequential endpoints found for $group_name"
    continue
  }
  report_timing -delay_type max -max_paths 50 -nworst 1 \
      -to $endpoints \
      -file [file join $report_dir post_synth_timing_${group_name}.rpt]
}

report_high_fanout_nets -timing -load_types -max_nets 100 \
    -file [file join $report_dir post_synth_high_fanout.rpt]

puts "RENDER_CORE_POST_SYNTH_ANALYSIS_COMPLETE report_dir=$report_dir"
