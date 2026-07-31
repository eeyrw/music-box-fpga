# Render, Sample Window, And DDR3 Merge Inventory

本文记录 `voice-major-block-renderer` 功能选择性合并到 `main` 后的 production
边界和验收入口。它不是删除清单。`main` 已有的文档、板级寄存器转发、legacy RTL
和测试内容均保留；不用的旧源码被隔离到明确的 legacy 目录，production filelist
和 Smart Artix top 只使用新路径。

## Merge Method

功能内容来自以下提交，并按 cherry-pick 顺序审查后选择性落入 main：

```text
62aed3e rtl: replace renderer with tagged voice-major pipeline
751fa81 docs: detail voice-major pipeline runtime
59748e0 rtl: integrate mono renderer with cached DDR3 model
1938f11 rtl: optimize voice renderer DDR sample windows
6172acd sim: improve DDR3 timing model and remove old line cache
```

没有接受功能分支中的文件删除，也没有用功能分支整份覆盖 main 文档。中间提交的
`ordered_line_cache` 不属于最终设计；生产 memory policy 是
`voice_sample_window`。接口冲突以 main 的 register fabric、SPI transport、platform
status、effects 和 I2S 边界为基础做语义合并。

## Production Data Path

```text
MIDI + SF2 C++ policy
  -> mono Region allocation (stereo pair = two voices)
  -> version-10 command words
  -> SPI opcode-0xa5 production command stream
  -> voice_major_command_plane
  -> block_voice_state_store
  -> voice_major_block_controller
  -> mono engine / endpoint planner
  -> 32-word per-voice voice_sample_window
  -> ordered 8-word DDR burst adapter
  -> signed-25 block mix
  -> chorus/reverb -> compressor/master
  -> PCM FIFO -> I2S
```

The 8-word ordered interface is the refill transaction size, not a second
cache. One 32-word window refill issues four ordered DDR reads. In simulation it
connects to `ordered_line_ddr3_bridge_model` and `ddr3_timing_model`. On Smart
Artix it connects to `smart_artix_ddr3_line_reader`, which uses the existing
`smart_artix_ddr3_rw_arbiter` to share MIG with the SD loader and register DDR
access master.

## Imported And Modified Owners

| Area | Production owners |
| --- | --- |
| Control | `rtl/control/voice_major_command_plane.sv`, `block_voice_state_store.sv` |
| Render | `rtl/top/voice_major_render_core.sv`, `rtl/voice/voice_major_block_controller.sv`, block mono/interleaved modules |
| Memory | `rtl/memory/voice_sample_window.sv`, ordered request/response types in `synth_pkg.sv` |
| Effects/output | existing `global_audio_effects_chain`, `wavetable_i2s_output`, and new `fpga/common/rtl/voice_major_system.sv` |
| Smart Artix | existing register fabric, platform registers, DDR line reader/subsystem/arbiter; `smart_artix_top` selects the new common wrapper |
| C++ | `sf2_loader`, `command_control`, `reference_synth`, RTL DDR3 render harness |
| Simulation | DDR3 timing/bridge models, sample-window TB, block renderer TBs, throughput TBs, real SF2 render |

The SF2 loader does not collapse two sample streams into a stereo region for
the production renderer. Linked and compatible hard-panned pairs remain two
mono regions with separate address, loop, gain, envelope, filter, and runtime
state. `CommandVoiceControl` rejects a residual stereo `Region`.

## Preserved Main Content

The following remain in the repository even when they are outside the current
production filelist:

- main documentation outside the localized protocol/architecture updates;
- legacy renderer/control/cache RTL under `rtl/legacy`;
- legacy common wrappers under `fpga/common/legacy` and historical C++/RTL
  simulations under `sim/legacy`;
- Smart Artix SD loading, register forwarding, DDR debug aperture, constraints,
  Vivado scripts, and bring-up documentation;
- board templates and host tools.

These files are retained for history only. They are excluded from current
filelists, default tests, and compatibility contracts.

## Verification Entry Points

| Command | Coverage |
| --- | --- |
| `make lint` | generic renderer plus effects/I2S common top and board DDR subsystem lint |
| `make test-cpp-unit` | SF2 mono expansion, command construction, reference behavior |
| `make test-rtl-core` | block state/event, renderer, DSP, mix, and unified control regressions |
| `make test-sample-window` | four-line refill, hit, fallback, isolation, backpressure |
| `make test-ddr3-model` | row hit/miss/conflict, refresh, image-backed data |
| `make measure-voice-major-throughput` | 256-voice cycle budget |
| `make measure-voice-major-throughput-512` | full 10-bit voice-ID and capacity budget |
| Removed historical `measure-voice-major-throughput-ddr3` target | used a single repeated adjacent-line workload and was not representative of DDR pressure; use `render-rtl-ddr3` |
| `make tb_smart_artix_ddr3_line_reader tb_smart_artix_ddr3_rw_arbiter` | board DDR request conversion and MIG ownership |
| `make render-rtl-ddr3` | real SF2/MIDI C++ policy through Verilated RTL and timed DDR model |

Generated output belongs under `build/` and is not committed.

## Stable Contracts

- [`../register_map.md`](../register_map.md): version-10 commands and debug/status registers.
- [`../memory_format.md`](../memory_format.md): mono layout, SF2 expansion, window and DDR refill path.
- [`../design/system_design.md`](../design/system_design.md): production architecture and board boundary.
- [`simulation_design.md`](simulation_design.md): self-checking and render-flow details.
