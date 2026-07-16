# Documentation Index

The documentation is grouped by stability and ownership. Stable hardware and
software contracts stay in this directory so external references do not move.
Design notes, verification flows, host tooling, and board bring-up notes live in
subdirectories.

## Stable Contracts

- [`fixed_point.md`](fixed_point.md): numeric formats and arithmetic rules.
- [`memory_format.md`](memory_format.md): wave-memory layout and memory handshake.
- [`register_map.md`](register_map.md): software-visible register addresses and
  commit/runtime behavior.

## Design Notes

- [`design/system_design.md`](design/system_design.md): current RTL architecture,
  control split, timing budget, and board-facing backlog.
- [`design/voice_pipeline.md`](design/voice_pipeline.md): current multi-voice
  renderer pipeline, throughput status, metrics, limitations, and optimization
  notes.

## Verification And Render Flows

- [`verification/simulation_design.md`](verification/simulation_design.md):
  self-checking tests, SoundFont/MIDI render harnesses, memory-profile renders,
  and board-loader simulation.

## Host Control

- [`host/host_control.md`](host/host_control.md): reusable C++ control boundary and
  CH347 USB-to-SPI tool notes.

## Board Integration

- [`board/smart_artix_target.md`](board/smart_artix_target.md): Smart Artix board
  assumptions, integration boundary, Vivado snapshots, and milestone state.
- [`board/smart_artix_bringup.md`](board/smart_artix_bringup.md): practical
  hardware bring-up sequence and debug checklist.
- [`board/asset_loading.md`](board/asset_loading.md): SD raw-image to DDR3 asset
  loading contract and Smart Artix loader blocks.
