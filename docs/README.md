# Documentation

This directory separates current contracts and architecture from open work,
historical records, and third-party reference material. Start with the first
three links below; follow the topic indexes only when working in that area.

## Start Here

- [`../README.md`](../README.md): project overview, repository layout, and common
  build and render commands.
- [`design/system_design.md`](design/system_design.md): current system
  architecture, ownership boundaries, and board boundary.
- [`design/rtl_module_map.md`](design/rtl_module_map.md): production RTL entry
  points, source ownership, and instantiation tree.
- [`verification/simulation_design.md`](verification/simulation_design.md):
  required checks, self-checking tests, and render harnesses.
- [`project_contracts.md`](project_contracts.md): authoritative project
  definitions and command opcode quick reference.
- [`development/rtl_change_workflow.md`](development/rtl_change_workflow.md):
  mandatory RTL change, verification, and Vivado signoff workflow.
- [`development/register_change_workflow.md`](development/register_change_workflow.md):
  practical workflow for adding, changing, or removing global registers.
- [`development/tooling.md`](development/tooling.md): build graph, generators,
  render/analyzer tools, board utilities, and Vivado entry points.

## Stable Contracts

These files define externally visible or numerically exact behavior. Update the
matching contract whenever its RTL or host implementation changes.

- [`fixed_point.md`](fixed_point.md): numeric formats, rounding, and saturation.
- [`memory_format.md`](memory_format.md): wave layout and ordered memory
  handshakes.
- [`register_map.md`](register_map.md): generated register, status, and debug
  fields.
- [`command_stream.md`](command_stream.md):
  command framing, payloads, voice lifecycle, and commit boundaries.

## Current Design

### Renderer

- [`design/renderer/overview.md`](design/renderer/overview.md): concise block
  renderer behavior and state ownership.
- [`design/renderer/pipeline.md`](design/renderer/pipeline.md): cycle-level
  pipeline, hazards, memory traffic, and measured limits.
- [`design/renderer/optimization_plan.md`](design/renderer/optimization_plan.md):
  active optimization record and replacement acceptance gates.

### Audio Processing

- [`design/audio/envelope_gain.md`](design/audio/envelope_gain.md): SoundFont
  envelope-domain conversion and generated lookup tables.
- [`design/audio/effects_parameters.md`](design/audio/effects_parameters.md):
  chorus/reverb controls, fixed-point fields, and presets.

### Transport

- [`command_stream.md`](command_stream.md):
  production command protocol.
- [`design/transport/spi_command_stream.md`](design/transport/spi_command_stream.md):
  command workload, FIFO sizing, and SCLK analysis.
- [`design/transport/spi_register_mailbox.md`](design/transport/spi_register_mailbox.md):
  split-phase register wire protocol and timing.
- [`host/host_control.md`](host/host_control.md): host ownership and CH347
  integration.
- [`host/ch347_daily_operations.md`](host/ch347_daily_operations.md): routine
  board checks, audio setup, playback, diagnostics, FLUSH, DDR, and smoke-test
  commands.

## Verification

- [`verification/simulation_design.md`](verification/simulation_design.md): test
  ownership and simulation architecture.
- [`verification/render_commands.md`](verification/render_commands.md): reusable
  C++ and RTL render commands.
- [`verification/sf2_access_span_analysis.md`](verification/sf2_access_span_analysis.md):
  SF2/MIDI phase-step, loop-wrap, and sample-line locality analysis.
- [`verification/nor_flash_feasibility.md`](verification/nor_flash_feasibility.md):
  QSPI and x16 parallel NOR models, one-second SGM comparison, and board limits.
- [`verification/global_sample_cache_evaluation.md`](verification/global_sample_cache_evaluation.md):
  one-second SGM A/B results for the per-voice window and experimental global
  line cache on DDR3 and QSPI timing models.
- [`verification/smart_artix_mig_latency_calibration.md`](verification/smart_artix_mig_latency_calibration.md):
  board/PC DDR3 discrepancy, MIG completion-latency calibration, root cause,
  and renderer optimization priorities.
- [`verification/vivado_synthesis_timing.md`](verification/vivado_synthesis_timing.md):
  source lists, RAM inference, timing case studies, and closure criteria.
- [`verification/vivado_strategy_and_report_analysis.md`](verification/vivado_strategy_and_report_analysis.md):
  measured Vivado strategy comparison and report review.

## Board Integration

- [`../fpga/README.md`](../fpga/README.md): board workspace conventions.
- [`../fpga/common/README.md`](../fpga/common/README.md): reusable board-facing
  RTL.
- [`../fpga/smart_artix/README.md`](../fpga/smart_artix/README.md): current Smart
  Artix top and build status.
- [`board/smart_artix_bringup.md`](board/smart_artix_bringup.md): practical
  hardware bring-up sequence.
- [`board/smart_artix_sd_50mhz_debug.md`](board/smart_artix_sd_50mhz_debug.md):
  complete 25/50 MHz A/B investigation, failed I/O approaches, final timing
  closure, and hardware evidence.
- [`board/asset_loading.md`](board/asset_loading.md): current SD-to-DDR3 asset
  loading contract.
- [`board/smart_artix_io_constraints_backlog.md`](board/smart_artix_io_constraints_backlog.md):
  unresolved external timing and constraint work.
- [`board/sd_native_backlog.md`](board/sd_native_backlog.md): native SD protocol
  audit and remaining qualification.

## Work Tracking And History

- [`backlog/README.md`](backlog/README.md): unresolved architecture, RTL,
  envelope, effects, and SPI work. Backlogs do not override current contracts.
- [`archive/README.md`](archive/README.md): completed migration and merge records.
  Archived documents are evidence, not descriptions of the current design.
- [`reference/README.md`](reference/README.md): local third-party SoundFont, MIDI,
  and SD specifications.
- [`development/README.md`](development/README.md): contributor workflows and
  completion gates.

Short README files under `assets/`, `fpga/<board>/assets/`,
`fpga/<board>/vivado/`, and `third_party/` describe only their local directory
contents and are not primary design references.
