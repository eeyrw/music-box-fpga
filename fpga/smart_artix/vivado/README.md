# Smart Artix Vivado Inputs

This directory contains source-controlled Vivado inputs only.

- `ip/`: IP configuration sources such as `.xci` files and MIG `.prj` files.
- `scripts/`: Tcl entry points that create local Vivado projects and run flows.

Generated Vivado projects, runs, checkpoints, bitstreams, reports, logs, and IP
output products belong under `../../../build/fpga/smart_artix/vivado/`. Do not
commit a generated `.xpr`; the source of truth is still the Tcl scripts plus the
source-controlled IP configuration. The scripts keep the generated project in the
build tree between runs so unchanged synthesis runs can be reused.

Common entry points from `fpga/smart_artix/`. Run Vivado from the build
directory so `.Xil/`, logs, and project output all stay out of the board source
tree:

```bash
mkdir -p ../../build/fpga/smart_artix/vivado/logs
cd ../../build/fpga/smart_artix/vivado
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/project.tcl \
  -journal logs/project.jou -log logs/project.log
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/synth.tcl \
  -journal logs/synth.jou -log logs/synth.log
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/impl.tcl \
  -journal logs/impl.jou -log logs/impl.log
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/bitstream.tcl \
  -journal logs/bitstream.jou -log logs/bitstream.log
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/program.tcl \
  -journal logs/program.jou -log logs/program.log
```

For GUI work, open the generated project at
`../../build/fpga/smart_artix/vivado/smart_artix.xpr`. If IP settings change in
the GUI, copy only the updated source configuration files back into `ip/`.

## Reuse Behavior

`project.tcl` opens the existing generated project when it exists. It copies IP
source directories and runs `generate_target` only when build-tree IP products are
missing, or when forced. It also avoids repeatedly adding the same RTL and XDC
files to the project.

`synth.tcl` reuses an up-to-date completed `synth_smart_artix_top` run. If Vivado marks the run
stale after source or constraint changes, the script resets and relaunches
`synth_smart_artix_top` automatically. This avoids the common batch-flow failure where Vivado
refuses to launch a completed stale run until it has been reset.

Each synthesis run writes these stable report files under
`../../build/fpga/smart_artix/vivado/reports/`:

- `post_synth_utilization.rpt`: flat device utilization summary.
- `post_synth_utilization_hier.rpt`: full hierarchical utilization report.
- `post_synth_utilization_hier_depth4.rpt`: compact hierarchy report deep enough
  to compare `core_system`, `voice_register_bank`, `multi_voice_pipeline`, memory,
  and MIG resource ownership.
- `post_synth_timing.rpt`: post-synthesis timing summary.
- `post_synth_summary.json`: compact machine-readable summary generated inside
  Vivado from timing, utilization, route-status, and DRC queries.

Implementation writes matching post-route files:

- `post_route_utilization.rpt`: flat routed utilization summary.
- `post_route_timing.rpt`: routed timing summary.
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
VIVADO_FORCE_REBUILD=1 vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/synth.tcl \
  -journal logs/synth.jou -log logs/synth.log

VIVADO_REGENERATE_IP=1 vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/synth.tcl \
  -journal logs/synth.jou -log logs/synth.log
```

This is project/run reuse for synthesis. It is not implementation incremental
checkpointing; RTL changes still require synthesis to run again.
