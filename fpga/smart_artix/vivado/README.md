# Smart Artix Vivado Inputs

This directory contains source-controlled Vivado inputs only.

- `ip/`: IP configuration sources such as `.xci` files and MIG `.prj` files.
- `scripts/`: Tcl entry points that create local Vivado projects and run flows.

Generated Vivado projects, runs, checkpoints, bitstreams, reports, logs, and IP
output products belong under `../../../build/fpga/smart_artix/vivado/`. Do not
commit a generated `.xpr`; the source of truth is still the Tcl scripts plus the
source-controlled IP configuration. The scripts keep the generated project in
the build tree, while `vivado-synth` deliberately resets the synthesis run so
configuration comparisons cannot reuse stale incremental partitions.

Common entry points run from the repository root. The Makefile runs Vivado from
the build directory so `.Xil/`, logs, and project output stay out of the source
tree, and it supplies the shared `NUM_VOICES` and `BLOCK_WORK_ENTRIES`
configuration:

```bash
make vivado-project
make vivado-synth
make vivado-impl
make vivado-bitstream
```

The default Vivado 2025.2 run configuration is timing-oriented:

- Synthesis uses `Flow_PerfOptimized_high`. UG901 describes its
  `PerformanceOptimized` directive as reducing logic levels at the possible cost
  of area, which is appropriate for the current routed design's limited timing
  margin, while the resulting 78.63% LUT use must be treated as constrained
  growth capacity.
- Implementation uses `Performance_ExplorePostRoutePhysOpt`. UG904 defines this
  as `Explore` optimization, placement, physical optimization, and routing plus
  an additional post-route `phys_opt_design` pass.
- Global synthesis retiming is not forced. UG901 states that `auto` does not
  perform retiming on non-Versal devices; enabling it globally should be a
  measured experiment because this top includes vendor IP and clock-domain
  boundaries.
- Automatic incremental synthesis is disabled after applying the strategy.
  `vivado-synth` already forces a clean run for trustworthy resource
  comparisons, while `vivado-impl` reuses an up-to-date synthesis checkpoint.

Strategies are coherent collections of step options, so prefer comparing named
strategies before overriding individual step properties. Alternatives useful for
this Artix-7 target include `Flow_AlternateRoutability` when synthesis creates
difficult MUX/carry structures, `Performance_ExploreWithRemap` for excess logic
depth, and `Congestion_SpreadLogic_medium` when the routed congestion report
shows a localized problem. `Flow_Quick` is only suitable for fast utilization
estimates, not timing signoff.

For GUI work, open the generated project at
`../../build/fpga/smart_artix/vivado/smart_artix.xpr`. If IP settings change in
the GUI, copy only the updated source configuration files back into `ip/`.

## Reuse Behavior

`project.tcl` opens the existing generated project when it exists. It copies IP
source directories and runs `generate_target` only when build-tree IP products are
missing, or when forced. It also avoids repeatedly adding the same RTL and XDC
files to the project. Defines, top selection, compile order, and run strategies
are updated only when their values actually change; this preserves Vivado's run
freshness state. A repeated `make vivado-impl` was verified to report both runs
as complete and up to date, then reuse them while regenerating the reports.

`synth.tcl` always resets and relaunches `synth_smart_artix_top`. This costs more
runtime than incremental reuse, but an earlier slot-count change produced a
plausible stale utilization report. Resource comparisons require a fresh run.
The generated project and IP output products are still reused.

Each synthesis run writes these stable report files under
`../../build/fpga/smart_artix/vivado/reports/`:

- `post_synth_utilization.rpt`: flat device utilization summary.
- `post_synth_utilization_hier.rpt`: full hierarchical utilization report.
- `post_synth_utilization_hier_depth4.rpt`: compact hierarchy report deep enough
  to compare `core_system`, `synth_control_plane`, `multi_voice_pipeline`, memory,
  and MIG resource ownership.
- `post_synth_timing.rpt`: post-synthesis timing summary.
- `post_synth_summary.json`: compact machine-readable summary generated inside
  Vivado from timing, utilization, route-status, and DRC queries.

Implementation writes matching post-route files:

- `post_route_utilization.rpt`: flat routed utilization summary.
- `post_route_timing.rpt`: routed timing summary.
- `post_route_setup_paths.rpt`: top 100 maximum-delay paths, with up to 10
  paths per endpoint for cluster analysis.
- `post_route_hold_paths.rpt`: matching minimum-delay paths for hold analysis.
- `post_route_route_status.rpt` and `post_route_drc.rpt`: explicit routing and
  design-rule completion evidence.
- `post_route_qor_assessment.rpt`, `post_route_qor_suggestions.rpt`, and
  `post_route_congestion.rpt`: Vivado timing-closure and congestion diagnostics.
- `post_route_methodology.rpt`, `post_route_high_fanout.rpt`,
  `post_route_clock_interaction.rpt`, and `post_route_check_timing.rpt`: design
  methodology, fanout, clock-domain, and constraint coverage checks.
- `post_route_summary.json`: compact machine-readable routed summary.

Read the JSON summaries from the repository root with:

```bash
make vivado-summary
python3 tools/vivado_report_summary.py show
python3 tools/vivado_report_summary.py compare \
  build/fpga/smart_artix/vivado/reports/post_synth_summary.json \
  build/fpga/smart_artix/vivado/reports/post_route_summary.json
```

The JSON format is intentionally small and project-owned. The Tcl exporter uses
Vivado object/report queries and avoids depending on Vivado's internal `.rpx` or
`.pb` files as a long-term parsing interface.

`impl.tcl` and `bitstream.tcl` also reuse an up-to-date completed
`impl_smart_artix_top` run. If implementation inputs become stale, the scripts
reset and relaunch that run before writing post-route reports or copying the
bitstream.

Useful environment overrides:

```bash
VIVADO_FORCE_REBUILD=1 make vivado-synth
VIVADO_FORCE_REBUILD=1 make vivado-impl
VIVADO_REGENERATE_IP=1 make vivado-synth
make vivado-impl VIVADO_JOBS=8
make vivado-impl VIVADO_SYNTH_STRATEGY=Flow_AlternateRoutability \
  VIVADO_IMPL_STRATEGY=Performance_ExploreWithRemap
```

`VIVADO_FORCE_REBUILD=1` deletes the generated project/runs before recreating
them. Use the `impl.tcl` form for timing signoff; the `synth.tcl` form is only a
resource and post-synthesis timing checkpoint. The current BRAM-inference and
timing-closure procedure is documented in
`../../../docs/verification/vivado_synthesis_timing.md`.
