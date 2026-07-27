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
- [`register_map.md`](register_map.md): generated compatibility addresses and
  the explicit gap between retained board registers and the replacement typed
  voice-control ports. Register constants are generated from
  [`../spec/register_map.json`](../spec/register_map.json).

## Architecture Notes

- [`design/system_design.md`](design/system_design.md): broad architecture and
  roadmap notes.
- [`design/rtl_module_map.md`](design/rtl_module_map.md): concise RTL reading map
  and instantiation tree.
- [`design/voice_major_block_renderer_handoff.md`](design/voice_major_block_renderer_handoff.md):
  current branch checkpoint, implemented replacement modules, verification
  state, missing integration, legacy deletion boundary, and exact restart order.
- [`design/voice_major_block_renderer_guide.md`](design/voice_major_block_renderer_guide.md):
  beginner-oriented Chinese walkthrough of the current block renderer,
  pipeline boundaries, state ownership, memory flow, and measured cycle budget.
- [`design/voice_major_render_pipeline_detailed.md`](design/voice_major_render_pipeline_detailed.md):
  detailed Chinese specification of the selected eight-slot pipeline, including
  every stage, handshake, state owner, memory rule, hazard, mix/effects boundary,
  throughput calculation, invariant, and remaining verification gate.
- [`design/optimized_render_pipeline.md`](design/optimized_render_pipeline.md):
  selected end-to-end pipeline from timestamped events through voice DSP,
  DDR, effects, compressor, PCM reservoir, and I2S, including feasibility gates.
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
  legacy host/SPI command-word contract still used by software models. It is
  not yet adapted to the new timestamped RTL event ingress.
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
  current self-checking tests, throughput measurements, C++ reference flow,
  and remaining full-system gaps.
- [`verification/ddr3_timing_model.md`](verification/ddr3_timing_model.md):
  simulation-only DDR3 bank/row/refresh timing model, C++ bin loading contract,
  ordered-line integration, and renderer throughput command.
- [`verification/render_commands.md`](verification/render_commands.md): C++
  reference and production RTL+DDR3 render commands and output conventions.
- [`verification/vivado_synthesis_timing.md`](verification/vivado_synthesis_timing.md):
  historical Smart Artix timing case studies plus the explicit requirement to
  re-synthesize and route the replacement voice-major core.
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
  retained memory subsystem, removed old top, and new integration boundary.
- [`board/smart_artix_bringup.md`](board/smart_artix_bringup.md): archived bring-up
  sequence for the deleted top; retained as input to the replacement board plan.
- [`board/smart_artix_io_constraints_backlog.md`](board/smart_artix_io_constraints_backlog.md):
  confirmed non-DDR pin facts, SPI/SD/I2S timing analysis, open RTL and XDC
  work, and board-level signoff gates.
- [`board/asset_loading.md`](board/asset_loading.md): SD raw-image contract and
  retained loader details, with deleted memory-integration references marked.
- [`board/sd_native_backlog.md`](board/sd_native_backlog.md): SD Part 1 v9.10
  protocol audit history, remaining qualification work, recovery requirements,
  and focused verification gates. Use `asset_loading.md` for the current path.

## Local Notes

Short README files under `assets/`, `fpga/<board>/assets/`, `fpga/<board>/vivado/`,
and `third_party/` describe only the local directory contents. They are not
primary design references.
