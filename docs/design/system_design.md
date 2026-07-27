# System Design

本文描述当前唯一有效的 RTL 渲染架构。数值规则见 `../fixed_point.md`，波形存储
格式见 `../memory_format.md`，面向初学者的逐模块解释见
`voice_major_block_renderer_guide.md`。

## 当前范围

当前里程碑是可综合、单时钟的 voice-major block renderer。默认 block 上限为 8
帧，常规验证使用 256 条 mono voice lane；立体声乐器由 host 分配两条 lane。
512 voices 是扩展目标；当前 filter-off/filter-on 测得 4197/4258 cycles，低于保守
16666-cycle deadline。该结论只适用于理想 line memory，尚不是板级签核。

旧的逐输出帧扫描架构、prepared/active 控制 RAM、word-read cache 和相应板级 top
已经删除。它们不再是兼容路径。新的寄存器/SPI 到 `block_voice_event_t` 的适配器、
真实 DDR cache 和新的 Smart Artix top 尚未实现，因此当前不能宣称整机已经可上板。

## 渲染数据流

```text
timestamped voice events
          |
          v
 block_voice_state_store
          |
          v
 voice_major_block_controller
          |
          v
 block_mono_voice_engine
   tagged interleaved envelope frontend
          |
          v
 block_interleaved_voice_renderer
   tagged phase -> contiguous segment read -> scoreboard -> tagged DSP -> retire
          |
          v
 double-buffered block mix
          |
          v
 effects -> compressor/master -> PCM reservoir -> I2S
```

控制状态按描述符、运行参数、包络参数和动态状态拆分。renderer 在 block 边界读出
快照，完成后只写回 phase、envelope 和 biquad z1/z2。generation 跟随 token，防止
旧 voice 的在途结果覆盖重新分配后的状态。

## 计算流水线

renderer 只有一套重 DSP，不复制多套完整引擎。8 个 work slot 保存少量在途 voice
数据；一套 phase 单元、一套 memory engine 和一套 DSP 在 slot 间交错 token，并在
同一 voice 的递归状态未返回时制造 RAW stall。

DSP 是 tagged 多级流水线：

```text
S0 interpolation product
S1 interpolated x
S2 b*x
S3 y
S4 a*y
S5 next filter state / selected sample
S6 left/right gain
S7 envelope, saturation, retire
```

状态更新总线提供同周期 forwarding：前一帧 z1/z2 返回时，可在同一拍发出该 voice
的下一帧。这样采用 CPU 常见的 scoreboard + forwarding 处理 hazard，同时保持 FPGA
适合的静态共享数据通路。

## Memory 边界

核心使用有序 line ready/valid 接口。一条 line 含 8 个 PCM16 word。每个 32-word
对齐 segment 连续发出 4 个 8-word line 请求；segment 中不插入另一 voice 的请求。
返回 word 直接设置 slot 内 endpoint-valid scoreboard，两个端点齐全的 frame 可立即
进入 DSP，不再经过 replay FSM。当前吞吐 TB 使用理想一拍响应；真实 DDR cache、多
outstanding miss、仲裁 stall 与 timeout 仍是下一阶段必须验证的系统边界。

## Mix 与后处理

block mix 使用双 bank，使一个 bank 可以发布/读取时另一个 bank 被填充。效果器不应
复制每 voice 实例，而应在混音后按 frame 流水：dry、chorus、reverb 可分支并行，
再按 frame ID 汇合。chorus-to-reverb 非零时存在必要依赖；chorus/FDN 自身的 delay
状态也必须保持帧序。compressor、输出 reservoir 和 I2S 可以同时处理不同帧。

当前效果器 RTL及其独立 TB仍保留，但还没有接入新的 `voice_major_render_core` 顶层。

## 已测吞吐

100 MHz、48 kHz、8-frame block 的 deadline 为：

```text
100,000,000 / 48,000 * 8 = 16,666 cycles
```

256 active lanes、理想 line memory：

| 配置 | block cycles | deadline |
| --- | ---: | ---: |
| 256, filter off | 2149 | pass |
| 256, filter on | 2191 | pass |
| 512, filter off | 4197 | pass |
| 512, filter on | 4258 | pass |

256-lane 测试精确检查 2048 个 DSP issue、2048 个 contribution、1024 个 line
request 和每段连续地址；filtered DSP 最长连续发射 312 拍。512-lane 数量对应翻倍。
该结果证明计算核心有余量，不证明
真实 DDR stall 和完整 effects 链已经闭合。

## 下一步系统门槛

1. 把连续 line 合并为显式 burst 合同，为 memory 实现多 outstanding、合并和有界
   仲裁，并重放真实 SF2 地址轨迹。
2. 将 mix bank 接到 frame-ID effects 分支/汇合、compressor 和输出 reservoir。
3. 实现 host/SPI command 到 timestamped block event 的新适配器。
4. 新建 Smart Artix top，再做综合、BRAM/DSP 推断、post-route timing 和长时间 underrun
   测试。
