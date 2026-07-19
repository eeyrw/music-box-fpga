# Documentation Index

The documentation is grouped by ownership. Stable hardware and software
contracts keep their existing paths because other code, docs, and agent
instructions refer to them directly. Board-specific status lives beside the
board project under `fpga/`.

## Start Here

- [`../README.md`](../README.md): project overview, repository layout, common
  build/test/render commands, and the short roadmap.
- [`design/system_design.md`](design/system_design.md): current RTL architecture,
  control split, real-time budget, and board-facing backlog.
- [`design/rtl_module_map.md`](design/rtl_module_map.md): where each generic RTL
  module lives and how the main tops instantiate each other.

## Stable Contracts

These files define externally visible behavior. Update the matching file in the
same change as any interface, memory layout, register, or numeric behavior
change.

- [`fixed_point.md`](fixed_point.md): numeric formats and arithmetic rules.
- [`memory_format.md`](memory_format.md): wave-memory layout, core memory
  handshake, line-memory adapter contract, and memory-profile assumptions.
- [`register_map.md`](register_map.md): software-visible register addresses and
  commit/runtime behavior. Register constants are generated from
  [`../spec/register_map.json`](../spec/register_map.json).

## Architecture Notes

- [`design/system_design.md`](design/system_design.md): broad architecture and
  roadmap notes.
- [`design/rtl_module_map.md`](design/rtl_module_map.md): concise RTL reading map
  and instantiation tree.
- [`design/voice_pipeline.md`](design/voice_pipeline.md): detailed renderer
  pipeline, latency/cycle accounting, limitations, and optimization notes.
- [`design/control_memory_refactor_plan.md`](design/control_memory_refactor_plan.md):
  historical and remaining control-plane and wave-memory cleanup plan.

## Verification And Render Flows

- [`verification/simulation_design.md`](verification/simulation_design.md):
  self-checking tests, SoundFont/MIDI render harnesses, memory-profile renders,
  C++ harness source layout, board-loader simulation, and generated register-map
  consistency checks.

## Host Control

- [`host/host_control.md`](host/host_control.md): reusable C++ control boundary,
  CH347 USB-to-SPI utility notes, and Smart Artix bring-up runner commands.

## Board Integration

- [`../fpga/README.md`](../fpga/README.md): board workspace layout, expected board
  directory contents, and synthesis source-list guidance.
- [`../fpga/common/README.md`](../fpga/common/README.md): reusable board-facing RTL
  boundary for transports, debug windows, tick generation, and audio serializers.
- [`../fpga/smart_artix/README.md`](../fpga/smart_artix/README.md): Smart Artix
  board assumptions, current top, Vivado flow/status, resource notes, and local
  checks.
- [`board/smart_artix_bringup.md`](board/smart_artix_bringup.md): practical Smart
  Artix hardware bring-up sequence and debug checklist.
- [`board/asset_loading.md`](board/asset_loading.md): SD raw-image to DDR3 asset
  loading contract and Smart Artix loader blocks.

## Local Notes

Short README files under `assets/`, `fpga/<board>/assets/`, `fpga/<board>/vivado/`,
and `third_party/` describe only the local directory contents. They are not
primary design references.
