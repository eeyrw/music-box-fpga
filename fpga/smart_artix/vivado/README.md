# Smart Artix Vivado Inputs

This directory contains source-controlled Vivado inputs only.

- `ip/`: IP configuration sources such as `.xci` files and MIG `.prj` files.
- `scripts/`: Tcl entry points that create local Vivado projects and run flows.

Generated Vivado projects, runs, checkpoints, bitstreams, reports, logs, and IP
output products belong under `../../../build/fpga/smart_artix/vivado/`. Do not
treat a generated `.xpr` as the authoritative project source; regenerate it from
the Tcl scripts instead. The batch scripts copy `ip/` into the build tree before
generating IP output products so the source-controlled IP configuration stays
clean.

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
