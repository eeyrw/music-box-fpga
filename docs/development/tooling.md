# Tooling Architecture

The root `Makefile` is the supported entry point for routine work. Individual
scripts remain directly usable for analysis and debugging, but generated paths,
shared build parameters, and source lists should flow through Make targets when
one exists.

## Toolchain Map

```text
spec/register_map.json ----> gen_register_map.py ----> SV/C++ register constants
spec/mcu_asset_profiles.json -> offline MCU asset compiler profile selection
tools/gen_dsp_lut.py ------> generated DSP tables ----> RTL + C++ reference

RTL filelists + SV TBs ----> Verilator -------------> self-checking executables
SF2 + MIDI ----------------> C++ reference ----------> WAV + JSON
SF2 + MIDI + RTL ----------> Verilated harness ------> WAV + timing/memory JSON
render artifacts ----------> analysis tools ---------> JSON/Markdown diagnostics

SF2 -----------------------> make_wtsf_image.py -----> raw WTSF SD image
WTSF image ----------------> flash_wtsf_sd.sh -------> physical SD card
CH347 host tools ----------> SPI mailbox/commands ---> Smart Artix board

RTL filelists + XDC + IP --> Vivado Tcl flow --------> DCP/reports/bitstream
Vivado reports ------------> vivado_report_summary.py -> signoff summary/analysis
```

All generated artifacts belong under `build/` except these checked-in generated
interfaces:

- `rtl/pkg/synth_register_pkg.sv`;
- `sim/harness/generated/register_map.h`;
- `rtl/generated/synth_dsp_lut_pkg.sv`;
- `sim/harness/generated/dsp_lut.h`.

## Build And Verification Tools

| Tool | Supported entry point | Role |
| --- | --- | --- |
| GNU Make | `make <target>` | Orchestrates shared parameters, source lists, output directories, and tools. |
| Documentation checker | `make check-docs` | Validates local links, path-like code spans, and index coverage. |
| Verilator | `make lint`, `make test-*`, `make render-rtl-*` | Lints synthesizable RTL, builds self-checking SystemVerilog tests, and builds RTL memory-backend render harnesses. |
| C++ compiler | `make test-cpp-unit`, `make render-reference`, host targets | Builds parser/model tests, the bit-exact reference synth, and CH347 utilities. |
| Vivado 2025.2 | `make vivado-*` | Creates the Smart Artix project, synthesizes, implements, writes reports/bitstream, and programs SRAM. |
| FluidSynth and FFmpeg | `tools/compare_reference_fluidsynth.py` | Optional external listening/numeric comparison; not an RTL golden model. |

The project parameters `NUM_VOICES`, `BLOCK_WORK_ENTRIES`,
`BLOCK_JOB_ENTRIES`, and `MAX_BLOCK_FRAMES` are supplied by the Makefile to RTL,
C++, and Vivado. Do not invoke a tool manually with a different set and compare
the results as if they were the same build.

## Generators

| Script | Input | Output | Normal command |
| --- | --- | --- | --- |
| `tools/gen_register_map.py` | `spec/register_map.json` | SV and C++ register constants | `make generate-register-map` |
| `tools/gen_dsp_lut.py` | Generator formulas in the script | RTL/C++ envelope, dynamics, and DSP lookup tables | `make generate-dsp-lut` |
| `tools/check_mcu_asset_profiles.py` | `spec/mcu_asset_profiles.json` and the generated-interface source contract | Target-neutral profile schema and command-interface consistency | `make check-mcu-asset-profiles` |
| `tools/check_docs.py` | Repository Markdown | Link, path-reference, and documentation-index validation | `make check-docs` |

Use `make check-generated` in normal verification. The exact
`generate-register-map`, `generate-dsp-lut`, `check-register-map`, and
`check-dsp-lut` targets operate only on the named output; `generate-generated`
and `check-generated` are the aggregate targets. Generation is an intentional
source update, not a harmless check.

## Render And Analysis Tools

| Entry point | Purpose |
| --- | --- |
| `make render-reference` | Pure C++ integer reference using the production command words and host policy. |
| `make render-rtl-memory RENDER_MEMORY=<backend>` | Shared implementation target for the RTL memory render harness; normally use one of the backend-specific entries below. |
| `make render-rtl-direct` | Fast functional Verilator render using the production voice/block configuration and simulation-only direct line memory. |
| `make render-rtl-ddr3` | Verilated production renderer with timed DDR3 and WAV/JSON output. |
| `make render-rtl-qspi` | The same renderer and report contract with the timed QSPI NOR backend. |
| `make render-rtl-parallel-nor` | The same renderer and report contract with the timed x16 parallel NOR backend. |
| `tools/analyze_render_artifacts.py` | Finds PCM transients and correlates them with MIDI/control timing. |
| `tools/analyze_sf2_access_span.py` | Models SF2/MIDI phase steps, loop wraps, and address locality; see [`../verification/sf2_access_span_analysis.md`](../verification/sf2_access_span_analysis.md). |
| `make analyze-polyphony-stress` | Generates the deterministic stress MIDI and writes its complete SF2 access JSON/Markdown reports. |
| `tools/compare_reference_fluidsynth.py` | Builds a dry FluidSynth comparison and audio statistics report. |
| `tools/sf2_extract.py` | Lists or extracts one SF2 instrument/sample for focused work. |
| `tools/sf2_filter_report.py` | Audits SoundFont filter-generator use and can emit probe MIDI. |
| `make benchmark-sf2-loader SF2_BENCHMARK=path/to/file.sf2` | Reports SF2 file size, load time, peak RSS, retained and compiled-table bytes, metadata counts, and compiled candidate counts. |
| `make benchmark-mcu-sf2-baseline SF2_BENCHMARK=path/to/file.sf2` | Writes the target-neutral 48 kHz/1 ms profile's exhaustive preset/key/velocity selection, compiled-memory, and cold/warm region-lookup baseline to `build/mcu_sf2_baseline.json`. |
| `tools/render_report_schema_test.py` | Validates normalized render-report catalogs and every cross-catalog reference. |
| `tools/make_filter_probe_assets.py` | Generates a tiny filtered SF2/MIDI regression fixture under `build/`. |
| `make polyphony-stress-midi` | Builds the deterministic high-polyphony stress MIDI generator and writes its fixture under `build/`. |

See [`../verification/render_commands.md`](../verification/render_commands.md)
for reproducible command lines and output-directory conventions. The C++ source
layers are:

```text
sim/harness/formats   MIDI, SF2, and byte parsing
sim/harness/control   command packing and transport-independent sinks
sim/harness/render    MCU policy, integer reference, sessions, and reports
sim/harness/dut       Verilated DUT adapters
sim/harness/common    WAV, memory profiles, and small helpers
sim/harness/apps      executable entry points
```

## Asset And Board Tools

| Entry point | Purpose |
| --- | --- |
| `make wtsf-image` | Wraps an SF2 byte image in the board loader's WTSF sector format. |
| `make verify-wtsf-image` | Validates the header, bounds, optional CRCs, and SF2 payload. |
| `make flash-wtsf-sd SD_DEVICE=...` | Writes the verified image to an explicitly selected whole-card device. |
| `make host-ch347` | Builds the generic CH347 register/command utility. |
| `make host-smart-artix-bringup` | Builds the board snapshot and smoke-test runner. |

`tools/flash_wtsf_sd.sh` is intentionally behind a Make target and requires an
explicit device. The host tools dynamically load the vendor CH347 library from
`third_party/ch347_linux`; they do not link vendor code into RTL or simulation.

## Vivado Flow And Reports

The Smart Artix flow is source controlled as Tcl plus XDC and IP configuration:

```text
rtl/filelist.f
fpga/smart_artix/filelist.f
fpga/smart_artix/constraints/
fpga/smart_artix/vivado/ip/
fpga/smart_artix/vivado/scripts/
                |
                v
build/fpga/smart_artix/vivado/
```

Use `make vivado-project`, `make vivado-synth`, `make vivado-impl`, and
`make vivado-bitstream`. `tools/vivado_report_summary.py` provides `show`,
`compare`, and `analyze` commands; `make vivado-summary` and
`make vivado-analyze` cover the normal current-run case.

The required gate is defined by
[`rtl_change_workflow.md`](rtl_change_workflow.md). Local script behavior and
report filenames are documented in
[`../../fpga/smart_artix/vivado/README.md`](../../fpga/smart_artix/vivado/README.md).

## Adding Or Changing A Tool

- Put reusable project utilities under `tools/`; board-independent host
  executables belong under `host/`.
- Give generated output an explicit path under `build/`.
- Add a Make target when the tool needs project parameters, several inputs, or
  destructive safeguards.
- Add a unit test for parsers, generators, and report interpretation.
- Update this inventory and the owning workflow or contract in the same change.
- Do not make synthesis depend on Python/C++ simulation models or host tools.
