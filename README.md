# WaveTable Synth FPGA

当前仓库实现一条可综合的 voice-major wavetable block renderer，以及独立验证的
effects、compressor、输出 FIFO、I2S、SPI/SD 和 Smart Artix DDR 外设模块。

当前计算目标是 100 MHz、48 kHz、8-frame block 下的 256 mono voice lanes。
256-lane filter-off/filter-on 理想 memory 测量分别为 2149/2191 cycles。
512-lane 对应为 4197/4258 cycles，均低于 16666-cycle deadline。

## 当前架构

```text
timestamped events -> prefetched voice state -> tagged envelope/phase slots
 -> voice-block contiguous segment reader -> endpoint scoreboard
 -> hazard-aware frame issue -> one tagged 8-stage DSP -> block mix banks
```

同一 voice 的 biquad RAW hazard 由 scoreboard 和 z1/z2 forwarding 处理；不同 voice
在同一套 DSP 中交错执行。当前 filtered 路径已出现连续 312 拍一拍一个 sample。
没有多套完整 renderer，也没有旧 prepared-slot 路径。

当前 generic top 是 `rtl/top/voice_major_render_core.sv`。旧逐帧 renderer、旧 cache、
旧控制 plane 和旧板级 top 已删除。Effects 和板级外设仍保留，但尚未与新 renderer
组成可上板的完整系统。

## 验证

```bash
make lint
make test
make test-voice-major-512
make measure-voice-major-throughput
make measure-voice-major-throughput-filtered
make measure-voice-major-throughput-512
make measure-voice-major-throughput-512-filtered
```

真实 MIDI/SF2 的纯 C++ 整数参考路径仍可使用：

```bash
make render-reference SF2=assets/soundfonts/example.sf2 SECONDS=1
```

旧 `render-rtl-core`、`render-memory` 和 `render-board-loader` 依赖已删除架构，不再
提供。新的 RTL harness 必须直接驱动 timestamped block events、ordered line memory
和 block output。

## 文档

- `docs/README.md`: 文档导航。
- `docs/design/system_design.md`: 当前整机边界和数据流。
- `docs/design/voice_major_block_renderer_guide.md`: FPGA 初学者导向的设计解释。
- `docs/design/optimized_render_pipeline.md`: 吞吐架构、hazard 与 effects 并行。
- `docs/design/voice_major_block_renderer_handoff.md`: 最新测量、验证状态和下一步。
- `docs/fixed_point.md`: 定点格式与精确算术。
- `docs/memory_format.md`: wavetable 存储格式。

生成物只放在 `build/`。
