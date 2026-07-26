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
- [`register_map.md`](register_map.md): software-visible global registers,
  command ingress, and the read-only voice debug snapshot. Register constants
  are generated from
  [`../spec/register_map.json`](../spec/register_map.json).

## Architecture Notes

- [`design/system_design.md`](design/system_design.md): broad architecture and
  roadmap notes.
- [`design/rtl_module_map.md`](design/rtl_module_map.md): concise RTL reading map
  and instantiation tree.
- [`design/rtl_refactoring_backlog.md`](design/rtl_refactoring_backlog.md):
  prioritized structural cleanup for executor ownership, renderer working
  records, typed voice-layer boundaries, debug capture, and cache state, with
  RAM-inference and timing-preservation gates.
- [`design/voice_pipeline.md`](design/voice_pipeline.md): renderer state,
  synchronous snapshots, phase/filter ownership, DSP flow, and cost model.
- [`design/envelope_gain_conversion.md`](design/envelope_gain_conversion.md):
  SoundFont envelope-domain ownership, range-reduced cB/Q1.15 conversion,
  generated tables, error bounds, and synthesis history.
- [`design/envelope_backlog.md`](design/envelope_backlog.md): SoundFont envelope
  time ranges, Delay playback semantics, FluidSynth comparison, and open RTL
  and host compatibility work.
- [`design/effects_backlog.md`](design/effects_backlog.md): implemented global
  chorus/reverb architecture, completion matrix, remaining qualification gates,
  and deferred per-voice sends.
- [`design/effects_parameter_mapping.md`](design/effects_parameter_mapping.md):
  mapping from common chorus/reverb controls and listening terminology to the
  implemented fixed-point algorithms, presets, and known limitations.
- [`design/control_command_stream_plan.md`](design/control_command_stream_plan.md):
  transactional command-stream and continuous-render contract.
- [`design/spi_command_stream_throughput.md`](design/spi_command_stream_throughput.md):
  command-stream workload model, renderer/control-plane throughput analysis,
  SCLK target, FIFO limits, and board-qualification requirements.
- [`design/spi_register_timing.md`](design/spi_register_timing.md): register
  read/write timing paths, burst boundaries, wire throughput, separate SCLK
  targets, and hardware-qualification requirements.
- [`design/spi_transport_backlog.md`](design/spi_transport_backlog.md): known
  SPI transaction-atomicity bugs and the packetized DMA transport backlog.

## Verification And Render Flows

- [`verification/simulation_design.md`](verification/simulation_design.md):
  self-checking tests, SoundFont/MIDI render harnesses, memory-profile renders,
  C++ harness source layout, board-loader simulation, and generated register-map
  consistency checks.
- [`verification/render_commands.md`](verification/render_commands.md): common
  reference, compressor, diagnostic, RTL, and memory render command lines.
- [`verification/vivado_synthesis_timing.md`](verification/vivado_synthesis_timing.md):
  Smart Artix source-list ownership, BRAM inference repairs, per-module timing
  case studies, residual path clusters, run-freshness checks, and closure
  criteria.
- [`Standard MIDI file format, updated.html`](Standard%20MIDI%20file%20format,%20updated.html):
  local copy of the Standard MIDI File format reference used when validating the
  C++ MIDI parser.
- [`M1_v4-2-1_MIDI_1-0_Detailed_Specification_96-1-4.pdf`](M1_v4-2-1_MIDI_1-0_Detailed_Specification_96-1-4.pdf):
  MIDI 1.0 Detailed Specification 4.2.1, including channel messages and the
  registered-parameter/Data Entry state-machine rules.

## Host Control

- [`host/host_control.md`](host/host_control.md): reusable C++ control boundary,
  CH347 USB-to-SPI utility notes, and Smart Artix bring-up runner commands.

## Board Integration

- [`../fpga/README.md`](../fpga/README.md): board workspace layout, expected board
  directory contents, and synthesis source-list guidance.
- [`../fpga/common/README.md`](../fpga/common/README.md): reusable board-facing RTL
  boundary for transports, platform register windows, tick generation, and audio serializers.
- [`../fpga/smart_artix/README.md`](../fpga/smart_artix/README.md): Smart Artix
  board assumptions, current top, Vivado flow/status, resource notes, and local
  checks.
- [`board/smart_artix_bringup.md`](board/smart_artix_bringup.md): practical Smart
  Artix hardware bring-up sequence and bring-up checklist.
- [`board/smart_artix_io_constraints_backlog.md`](board/smart_artix_io_constraints_backlog.md):
  confirmed non-DDR pin facts, SPI/SD/I2S timing analysis, open RTL and XDC
  work, and board-level signoff gates.
- [`board/asset_loading.md`](board/asset_loading.md): SD raw-image to DDR3 asset
  loading contract and Smart Artix loader blocks.

## Local Notes

Short README files under `assets/`, `fpga/<board>/assets/`, `fpga/<board>/vivado/`,
and `third_party/` describe only the local directory contents. They are not
primary design references.
