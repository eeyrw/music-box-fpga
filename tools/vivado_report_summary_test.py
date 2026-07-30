#!/usr/bin/env python3

import tempfile
import unittest
from pathlib import Path

from vivado_report_summary import (
    build_analysis,
    cluster_timing_paths,
    normalized_cell,
    parse_check_timing,
    parse_design_timing_summary,
    parse_io_delay_coverage,
    parse_rule_summary,
    parse_timing_paths,
)


TIMING_REPORT = """
Slack (VIOLATED) :         -0.125ns  (required time - arrival time)
  Source:                 top/core/source_reg[3]/C
                            (rising edge-triggered cell FDRE clocked by clk_main)
  Destination:            top/core/data_ram_reg/DIADI[7]
                            (rising edge-triggered cell RAMB36E1 clocked by clk_main)
  Path Group:             clk_main
  Path Type:              Setup (Max at Slow Process Corner)
  Requirement:            10.000ns
  Data Path Delay:        9.750ns  (logic 3.000ns (30.769%)  route 6.750ns (69.231%))
  Logic Levels:           13  (CARRY4=4 LUT6=9)
  Clock Path Skew:        -0.100ns
  Clock Uncertainty:      0.075ns

Slack (MET) :             0.050ns  (required time - arrival time)
  Source:                 top/core/source_reg[4]_replica_2/C
                            (rising edge-triggered cell FDRE clocked by clk_main)
  Destination:            top/core/data_ram_reg/DIADI[8]
                            (rising edge-triggered cell RAMB36E1 clocked by clk_main)
  Path Group:             clk_main
  Path Type:              Setup (Max at Slow Process Corner)
  Requirement:            10.000ns
  Data Path Delay:        9.500ns  (logic 3.500ns (36.842%)  route 6.000ns (63.158%))
  Logic Levels:           12  (CARRY4=3 LUT6=9)
"""

CHECK_TIMING_REPORT = """
Table of Contents
1. checking no_clock (0)
2. checking unconstrained_internal_endpoints (1)
3. checking no_input_delay (9)

1. checking no_clock (0)

 There are 2 input ports with no input delay specified. (HIGH)

spi_cs_n
spi_mosi

 There is 1 input port with no input delay but user has a false path constraint. (MEDIUM)

sd_cd_n

 There are 2 ports with no output delay specified. (HIGH)

i2s_bclk
i2s_sdata

 There are 0 ports with no output delay but user has a false path constraint
"""

METHODOLOGY_REPORT = """
| Rule     | Severity | Description                                 | Checks |
| SYNTH-6  | Warning  | Timing of a RAM block might be sub-optimal | 12     |
| REQP-100 | Advisory | Example advisory                            | 2      |
"""

DESIGN_TIMING_REPORT = """
| Design Timing Summary
    WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints WHS(ns) THS(ns) THS Failing Endpoints THS Total Endpoints WPWS(ns) TPWS(ns) TPWS Failing Endpoints TPWS Total Endpoints
    ------- ------- --------------------- ------------------- ------- ------- --------------------- ------------------- -------- -------- ---------------------- --------------------
      -0.125  -0.250  1  100  0.050  0.000  0  99  0.100  0.000  0  20
"""


class VivadoReportSummaryTest(unittest.TestCase):
    def test_parses_and_clusters_timing_paths(self) -> None:
        paths = parse_timing_paths(TIMING_REPORT)
        self.assertEqual(len(paths), 2)
        self.assertEqual(paths[0].slack_ns, -0.125)
        self.assertEqual(paths[0].destination_type, "RAMB36E1")
        self.assertEqual(paths[0].logic_levels, 13)
        self.assertAlmostEqual(paths[0].route_pct, 69.231)

        clusters = cluster_timing_paths(paths)
        self.assertEqual(len(clusters), 2)
        self.assertEqual(clusters[0]["worst_slack_ns"], -0.125)

    def test_normalizes_only_pin_suffixes(self) -> None:
        self.assertEqual(normalized_cell("top/core/source_reg[3]/C"), "top/core/source_reg[]")
        self.assertEqual(normalized_cell("top/core/source_reg[4]_replica_2"), "top/core/source_reg[]_replica")

    def test_parses_constraint_and_methodology_summaries(self) -> None:
        self.assertEqual(
            parse_check_timing(CHECK_TIMING_REPORT),
            {"no_clock": 0, "unconstrained_internal_endpoints": 1, "no_input_delay": 9},
        )
        rules = parse_rule_summary(METHODOLOGY_REPORT)
        self.assertEqual([(rule["rule"], rule["count"]) for rule in rules], [("SYNTH-6", 12), ("REQP-100", 2)])
        timing = parse_design_timing_summary(DESIGN_TIMING_REPORT)
        self.assertEqual(timing["setup_failing_endpoints"], 1)
        self.assertEqual(timing["pulse_width_failing_endpoints"], 0)
        io_delays = parse_io_delay_coverage(CHECK_TIMING_REPORT)
        self.assertEqual(io_delays["inputs_without_delay"], ["spi_cs_n", "spi_mosi"])
        self.assertEqual(io_delays["inputs_without_delay_false_pathed"], ["sd_cd_n"])
        self.assertEqual(io_delays["outputs_without_delay"], ["i2s_bclk", "i2s_sdata"])

    def test_analysis_fails_on_timing_and_constraint_errors(self) -> None:
        summary = {
            "timing": {
                "wns_ns": -0.125,
                "whs_ns": 0.050,
                "tns_failing_endpoints": 1,
                "ths_failing_endpoints": 0,
            },
            "utilization": {"slice_luts": {"util_pct": 75.0}},
            "route_status": {"routing_errors": 0},
            "drc": {"error_count": 0, "critical_warning_count": 0, "warning_count": 2},
        }
        with tempfile.TemporaryDirectory() as directory:
            report_dir = Path(directory)
            (report_dir / "post_route_setup_paths.rpt").write_text(TIMING_REPORT)
            (report_dir / "post_route_hold_paths.rpt").write_text(TIMING_REPORT)
            (report_dir / "post_route_check_timing.rpt").write_text(CHECK_TIMING_REPORT)
            (report_dir / "post_route_methodology.rpt").write_text(METHODOLOGY_REPORT)
            (report_dir / "post_route_timing.rpt").write_text(DESIGN_TIMING_REPORT)
            analysis = build_analysis(report_dir, summary, 0.200)

        self.assertEqual(analysis["status"], "FAIL")
        self.assertIn("setup timing fails: WNS -0.125 ns", analysis["failures"])
        self.assertIn(
            "check_timing unconstrained_internal_endpoints: 1", analysis["failures"]
        )
        self.assertTrue(any("RAM/DSP" in item for item in analysis["recommendations"]))


if __name__ == "__main__":
    unittest.main()
