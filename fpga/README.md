# FPGA Integration

This tree binds the generic core under `rtl/` to clocks, pins, memories, control
transports, and audio devices. The current production target is
[`smart_artix/`](smart_artix/). The old template and renderer wrappers under
the former `legacy/` directories have been removed.

## Ownership

```text
common/rtl/          reusable synthesizable transport/audio/system adapters
smart_artix/rtl/     board-specific SD, DDR3, status, clock, and top-level RTL
smart_artix/filelist.f  board/common production source list
smart_artix/constraints/ board XDC
smart_artix/vivado/  source-controlled Tcl and IP configuration
smart_artix/sim/     board-specific models and self-checking tests
```

Generic RTL is listed only in `rtl/filelist.f`. A board flow reads that list,
then its own integration list. Never copy the generic list into a board
directory and never add `sim/` sources to synthesis.

## New Board Requirements

A new `fpga/<board>/` target must define:

- exact FPGA part, package, speed grade, oscillator, board revision, and I/O
  bank voltages;
- a board top and reset/clock sequence;
- physical memory adaptation for the ordered line-read contract;
- control transport and audio serialization;
- pin, clock, CDC, and external I/O timing constraints;
- a deterministic asset-loading and host/firmware control path;
- self-checking board-adapter tests and a source-controlled synthesis flow;
- routed timing, utilization, DRC, and hardware bring-up evidence.

Start from the current Smart Artix ownership boundaries. Project contracts are indexed in
[`../docs/project_contracts.md`](../docs/project_contracts.md), and required
verification is defined in
[`../docs/development/rtl_change_workflow.md`](../docs/development/rtl_change_workflow.md).
