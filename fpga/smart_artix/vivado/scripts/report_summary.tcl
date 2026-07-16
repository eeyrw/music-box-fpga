# Helpers for writing compact machine-readable Vivado summaries.

proc json_escape {value} {
  set out ""
  foreach char [split $value ""] {
    scan $char %c code
    switch -- $char {
      "\\" { append out "\\\\" }
      "\"" { append out "\\\"" }
      "\b" { append out "\\b" }
      "\f" { append out "\\f" }
      "\n" { append out "\\n" }
      "\r" { append out "\\r" }
      "\t" { append out "\\t" }
      default {
        if {$code < 32} {
          append out [format "\\u%04x" $code]
        } else {
          append out $char
        }
      }
    }
  }
  return $out
}

proc json_value {value} {
  if {$value eq "null"} {
    return "null"
  }
  if {[string is double -strict $value] || [string is integer -strict $value]} {
    return $value
  }
  if {$value ne "" && ![catch {dict size $value}]} {
    return [json_object $value]
  }
  return "\"[json_escape $value]\""
}

proc json_object {dict_value {indent ""}} {
  set pieces [list]
  dict for {key value} $dict_value {
    lappend pieces "${indent}  \"[json_escape $key]\": [json_value $value]"
  }
  return "{\n[join $pieces ,\n]\n${indent}}"
}

proc read_file_text {path} {
  set fd [open $path r]
  set text [read $fd]
  close $fd
  return $text
}

proc report_to_string {command temp_path} {
  if {![catch {uplevel 1 [concat $command [list -return_string]]} text]} {
    return $text
  }
  file delete -force $temp_path
  uplevel 1 [concat $command [list -file $temp_path]]
  set text [read_file_text $temp_path]
  file delete -force $temp_path
  return $text
}

proc parse_table_row_metrics {text labels} {
  set result [dict create]
  foreach line [split $text "\n"] {
    if {![regexp {^\|(.+)\|$} $line -> body]} {
      continue
    }
    set cells [list]
    foreach cell [split $body "|"] {
      lappend cells [string trim $cell]
    }
    set label [regsub {\*+$} [lindex $cells 0] ""]
    if {[dict exists $labels $label]} {
      set key [dict get $labels $label]
      dict set result $key used [lindex $cells 1]
      dict set result $key available [lindex $cells 4]
      dict set result $key util_pct [lindex $cells 5]
    }
  }
  return $result
}

proc parse_timing_summary {text} {
  set result [dict create source report_timing_summary]
  set lines [split $text "\n"]
  for {set i 0} {$i < [llength $lines]} {incr i} {
    set line [string trim [lindex $lines $i]]
    if {[regexp {^[-+0-9.]+\s+[-+0-9.]+\s+[0-9]+\s+[0-9]+\s+[-+0-9.]+\s+[-+0-9.]+\s+[0-9]+\s+[0-9]+} $line]} {
      set fields [regexp -all -inline {[-+]?[0-9]+(?:\.[0-9]+)?} $line]
      if {[llength $fields] >= 8} {
        dict set result wns_ns [lindex $fields 0]
        dict set result tns_ns [lindex $fields 1]
        dict set result tns_failing_endpoints [lindex $fields 2]
        dict set result tns_total_endpoints [lindex $fields 3]
        dict set result whs_ns [lindex $fields 4]
        dict set result ths_ns [lindex $fields 5]
        dict set result ths_failing_endpoints [lindex $fields 6]
        dict set result ths_total_endpoints [lindex $fields 7]
        return $result
      }
    }
  }
  dict set result parse_error "design timing summary row not found"
  return $result
}

proc path_dict {path} {
  if {$path eq ""} {
    return [dict create found 0]
  }
  set result [dict create found 1]
  foreach prop {SLACK STARTPOINT_PIN ENDPOINT_PIN STARTPOINT_CLOCK ENDPOINT_CLOCK PATH_GROUP DATAPATH_DELAY LOGIC_LEVELS} {
    if {![catch {get_property $prop $path} value]} {
      dict set result [string tolower $prop] $value
    }
  }
  return $result
}

proc collect_timing {stage report_dir} {
  set text [report_to_string [list report_timing_summary] [file join $report_dir ${stage}_timing_for_summary.rpt]]
  set result [parse_timing_summary $text]
  if {![catch {lindex [get_timing_paths -setup -max_paths 1 -quiet] 0} setup_path]} {
    dict set result worst_setup_path [path_dict $setup_path]
  }
  if {![catch {lindex [get_timing_paths -hold -max_paths 1 -quiet] 0} hold_path]} {
    dict set result worst_hold_path [path_dict $hold_path]
  }
  return $result
}

proc collect_utilization {stage report_dir} {
  set text [report_to_string [list report_utilization] [file join $report_dir ${stage}_utilization_for_summary.rpt]]
  set labels [dict create \
    "Slice LUTs" slice_luts \
    "Slice Registers" slice_registers \
    "Block RAM Tile" block_ram_tiles \
    "DSPs" dsps \
    "DSP48E1" dsp48e1]
  set result [parse_table_row_metrics $text $labels]
  dict set result source report_utilization
  return $result
}

proc collect_route_status {stage report_dir} {
  set result [dict create source report_route_status]
  if {![string match "*route*" $stage]} {
    dict set result available 0
    dict set result skipped "route status is only meaningful after implementation"
    return $result
  }
  if {[catch {report_to_string [list report_route_status] [file join $report_dir ${stage}_route_status_for_summary.rpt]} text]} {
    dict set result available 0
    return $result
  }
  dict set result available 1
  foreach line [split $text "\n"] {
    if {[regexp {# of routable nets\.*\s*:\s*([0-9]+)} $line -> value]} {
      dict set result routable_nets $value
    } elseif {[regexp {# of fully routed nets\.*\s*:\s*([0-9]+)} $line -> value]} {
      dict set result fully_routed_nets $value
    } elseif {[regexp {# of nets with routing errors\.*\s*:\s*([0-9]+)} $line -> value]} {
      dict set result routing_errors $value
    }
  }
  return $result
}

proc collect_drc {stage report_dir} {
  set result [dict create source report_drc]
  if {[catch {report_to_string [list report_drc] [file join $report_dir ${stage}_drc_for_summary.rpt]} text]} {
    dict set result available 0
    return $result
  }
  dict set result available 1
  dict set result checks_found 0
  dict set result error_count 0
  dict set result critical_warning_count 0
  dict set result warning_count 0
  dict set result advisory_count 0
  if {[regexp {Checks found:\s*([0-9]+)} $text -> checks]} {
    dict set result checks_found $checks
  }
  foreach line [split $text "\n"] {
    if {[regexp {^\|\s*[^|]+\|\s*(Error|Critical Warning|Warning|Advisory)\s*\|.*\|\s*([0-9]+)\s*\|} $line -> severity count]} {
      switch -- $severity {
        "Error" { dict incr result error_count $count }
        "Critical Warning" { dict incr result critical_warning_count $count }
        "Warning" { dict incr result warning_count $count }
        "Advisory" { dict incr result advisory_count $count }
      }
    }
  }
  return $result
}

proc write_vivado_summary {stage output_path} {
  global report_dir board_name part_name top_name synth_run_name impl_run_name

  set summary [dict create]
  dict set summary schema_version 1
  dict set summary generated_by vivado_report_summary_tcl
  dict set summary stage $stage
  dict set summary board $board_name
  dict set summary part $part_name
  dict set summary top $top_name
  dict set summary generated_at [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]
  dict set summary synth_run $synth_run_name
  dict set summary impl_run $impl_run_name
  if {![catch {version -short} vivado_version]} {
    dict set summary vivado_version $vivado_version
  }

  dict set summary timing [collect_timing $stage $report_dir]
  dict set summary utilization [collect_utilization $stage $report_dir]
  dict set summary route_status [collect_route_status $stage $report_dir]
  dict set summary drc [collect_drc $stage $report_dir]

  file mkdir [file dirname $output_path]
  set fd [open $output_path w]
  puts $fd [json_object $summary]
  close $fd
  puts "INFO: Wrote Vivado summary JSON: $output_path"
}
