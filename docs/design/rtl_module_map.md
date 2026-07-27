# RTL Module Map

## 主入口

当前 generic renderer 唯一主入口是 `rtl/top/voice_major_render_core.sv`。
`fpga/common/rtl/wavetable_i2s_output.sv` 是独立 PCM-to-I2S 适配器，不代表完整系统
top。Smart Artix 目前只保留可复用 SD/DDR 外设子系统，新的整机 top 尚未建立。

## 实例树

```text
voice_major_render_core
+- block_voice_state_store
|  +- block_voice_event_executor
+- voice_major_block_controller
   +- block_mono_voice_engine
      +- block_interleaved_envelope_frontend
      +- block_interleaved_voice_renderer
         +- mono_phase_frame (current and look-ahead phase)
         +- block_interleaved_voice_dsp
   +- block_mix_buffer
```

## 目录职责

| 目录 | 当前职责 |
| --- | --- |
| `rtl/pkg` | 公共常量、定点类型、block/event/token payload。 |
| `rtl/control` | timestamped event 执行和 voice 状态 bank。 |
| `rtl/voice` | block 调度、phase/envelope、endpoint、DSP issue 与 mix。 |
| `rtl/memory` | 可复用 memory adapter；当前 segment scoreboard 位于 renderer。 |
| `rtl/dsp` | 一套 tagged、可停顿、带状态前递的 voice DSP。 |
| `rtl/audio` | chorus、reverb、return mix、compressor、FIFO 和 credit。 |
| `rtl/top` | 当前 voice-major generic composition。 |
| `fpga/common/rtl` | SPI/I2S/SD 等可复用板级外围；尚未组成新整机。 |
| `fpga/smart_artix/rtl` | SD loader、MIG adapter、DDR arbiter/debug 子系统。 |

## 共享接口

- `block_voice_event_t`: host 已解码、带 timeline/generation 的 voice 事件。
- `ordered_line_req_t` / `ordered_line_rsp_t`: 有序 8-word PCM line memory。
- `block_dsp_sample_token_t`: work ID、frame sample 和递归状态。
- `block_dsp_state_update_t`: 提前返回的 z1/z2，用于 scoreboard 清除和 forwarding。
- `block_dsp_retire_t`: contribution、最终状态和 last 标志。
- `render_block_*`: block 请求、发布、读取和释放。

ready/valid 不封装进 payload，方向在模块端口上保持显式。

## 已删除架构

以下名称不再存在，也不应重新加入 filelist：`wavetable_render_core`、
`wavetable_cached_render_core`、`multi_voice_pipeline`、`voice_dsp_pipeline`、
`transactional_control_plane`、`voice_line_cache` 和 `wave_memory_subsystem`。
