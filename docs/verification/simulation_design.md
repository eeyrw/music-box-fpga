# Verification And Render Flows

生成物只放在 `build/`。

## 必跑检查

```bash
make check-register-map
make lint
make test
make measure-voice-major-throughput
make measure-voice-major-throughput-filtered
make test-voice-major-512
```

`make test` 分为 C++ reference/model、voice-major RTL core、效果器与独立板级外围。
所有 RTL TB 自检并在错误时非零退出。

## 当前核心 TB

| TB | 覆盖范围 |
| --- | --- |
| `tb_voice_major_render_core` | block 请求、状态连续性、mix bank 发布/读取。 |
| `tb_block_voice_state_store` | 状态 bank、generation 和事件仲裁。 |
| `tb_block_voice_event_executor` | start/stop/release/runtime event。 |
| `tb_voice_major_block_controller` | voice scan、engine dispatch、retire。 |
| `tb_block_mono_voice_engine` | envelope、renderer、动态状态写回。 |
| `tb_block_interleaved_voice_renderer` | endpoint/gather/DSP/retire 端到端和 backpressure。 |
| `tb_block_interleaved_voice_dsp` | 精确整数运算、tag、RAW state、retire stall。 |
| `tb_block_interleaved_envelope_frontend` | 8-context envelope tag、level 和背压。 |
| `tb_block_mix_buffer` | 双 bank ownership 和读出。 |
| `tb_voice_major_throughput` | 256/512 lane 周期、issue/retire 数、hazard/forwarding。 |

效果器、compressor、FIFO/I2S、SPI、SD 和 Smart Artix DDR 子系统仍由各自 focused TB
覆盖。它们尚未与新 renderer 组成 full-system TB，不能用独立通过替代整机验证。

## C++ 路径

`make render-reference` 保留为 MIDI/SF2 整数参考渲染。旧
`render-rtl-core`、`render-memory` 和 `render-board-loader` 依赖已删除架构，已经从
Makefile 移除。下一条 RTL C++ harness 应直接驱动 `block_voice_event_t`、ordered line
memory 和 block output，不应复活旧 command/prepared-state 适配层。

`make measure-voice-compute-pipeline` 是架构周期模型，用于比较 work entry 和前端
延迟；最终判断仍以 RTL throughput TB 为准。

## 尚未覆盖的风险

- 真实 DDR burst/stall 与多个 outstanding miss；
- renderer 的 jumped address、fractional phase 和 loop-wrap 定向回归；
- 新 event transport 与 SPI/host 的端到端行为；
- renderer、effects、compressor、reservoir、I2S 同时运行；
- FPGA synthesis、RAM/DSP inference 和 post-route 100 MHz timing；
- 长时间 MIDI/SF2 exact comparison、deadline 和 underrun。
