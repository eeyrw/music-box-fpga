# Voice-Major 渲染流水线详细设计

Updated: 2026-07-27

本文是当前 voice-major block renderer 的详细设计说明。目标读者包括第一次接触
FPGA 流水线、ready/valid 和递归 DSP hazard 的开发者。本文描述的是当前仓库中实际
保留的生产 RTL，同时明确区分尚未接入顶层的后续整机流水。

本文中的三个状态标记含义如下：

- **已实现**：存在于 `rtl/filelist.f` 的当前生产实例树，并有 focused SV TB。
- **已测量**：在理想有序 line memory 模型下得到过周期或吞吐量数据。
- **待集成/待签核**：模块可能单独存在，但还没有组成持续运行的整机，或还没有经过
  FPGA 综合、布局布线和真实 DDR 验证。

## 1. 问题定义与实时预算

系统按音频 block 工作。当前 `MAX_BLOCK_FRAMES=8`，即一次请求最多产生 8 个连续的
立体声输出 frame。一个 frame 包含同一采样时刻的 left 和 right sample。

在 100 MHz 系统时钟和 48 kHz 采样率下：

```text
每个音频 frame 的时钟预算 = 100,000,000 / 48,000
                         ~= 2083.33 clocks

8-frame block 的时钟预算 = 8 * 100,000,000 / 48,000
                          ~= 16666.67 clocks
```

文档和 TB 使用 16666 clocks 作为保守 deadline。这个数字与复音数无关；复音数增加
意味着更多 voice 必须共享同一个 16666-clock block 窗口。

当前基本负载是 256 条 mono lane，扩展负载是 512 条 mono lane。每条 lane 从一个
mono 波表取样，经过一次 mono filter，再用独立 `gain_l/gain_r` 形成左右贡献。需要
立体声波表时，host/MCU 分配两条普通 mono lane。这样生产 RTL 只保留一种渲染数据
通路，不为 stereo 再复制 endpoint、filter state 和调度逻辑。

## 2. 初学者必须区分的四个指标

### 2.1 Latency

Latency 是某一条工作从输入到输出经历多少拍。例如一个 DSP token 进入插值级后，
必须穿过多个寄存级才退休。多级流水通常会增加单 token latency。

### 2.2 Initiation interval

Initiation interval，简称 II，是流水线连续接受两条新工作的最小间隔。当前 DSP 的
目标是稳定区间 `II=1`，即每拍接受一条 sample token。`II=1` 不代表输入 token 当拍
就输出，只代表流水线灌满后可以每拍进一个、每拍出一个。

### 2.3 Occupancy

Occupancy 是某一时刻有多少 voice block 正在硬件中等待、计算或返回。8 个 work slot
允许最多 8 个独立 voice block 在 renderer 内在途，但不等于有 8 套算术单元。

### 2.4 Throughput

Throughput 是单位时间完成的有效 sample 数。最终需要看从 state read、envelope、
phase、memory、DSP、mix 到输出的端到端吞吐，而不能只看一个乘法器能否每拍工作。

## 3. 当前实例树和目标整机

当前已实现的生产实例树：

```text
voice_major_render_core
|
+-- block_voice_state_store
|   +-- block_voice_event_executor
|
+-- voice_major_block_controller
    |
    +-- block_mono_voice_engine
    |   |
    |   +-- block_interleaved_envelope_frontend
    |   |
    |   +-- block_interleaved_voice_renderer
    |       +-- mono_phase_frame x2 (当前 phase 和一步 look-ahead)
    |       +-- block_interleaved_voice_dsp
    |
    +-- block_mix_buffer
```

目标整机还要把已发布 mix block 接到以下链路：

```text
mix bank reader
  -> effects fork/join
  -> effect return mixer
  -> look-ahead compressor
  -> PCM reservoir / output FIFO
  -> I2S serializer
```

这些 audio 模块已有独立 RTL 和 focused TB，但尚未连接到
`voice_major_render_core`。因此当前吞吐量只能证明 voice render core，不能证明真实
DDR、effects 和 I2S 同时运行时仍然无 underrun。

## 4. 为什么选择 8 个 slot

`BLOCK_WORK_ENTRY_COUNT=8`，`BLOCK_WORK_ID_WIDTH=3`。8 是调度窗口，不是 8 个
renderer，也不是 8 套 DSP。

一个 slot 的作用类似 CPU 中一条在途指令的上下文，保存：

- voice identity：`voice_index` 和 `generation`；
- 当前 block 的 `frame_count`；
- playback region、gain、phase increment 和 filter coefficients；
- 跨 block 的 phase、envelope state、filter `z1/z2`；
- 最多 8 个 frame 对应的 endpoint job；
- 最多 16 个插值 endpoint 的 sample 和 valid scoreboard；
- phase planning、memory fetch、DSP issue 和完成进度；
- filter RAW hazard 位。

共享资源仍然只有：

- 一套每拍处理一个 slot 的 envelope state step；
- 一套四级 envelope level conversion pipeline；
- 一套 phase combinational datapath；
- 一个外部 line request engine；
- 一套 interpolation/filter/gain DSP pipeline；
- 一个 contribution retire 端口。

为什么不是 2 个 slot：filtered sample 发射后，要等新的 `z1/z2` 从 DSP 中段返回。
两条上下文很快都会等待反馈，DSP 会出现空拍。8 个独立上下文超过当前约五拍的反馈
距离，round-robin 调度可以在 A 等待时发射 B、C、D、E、F 的 sample。

为什么暂时不是更多：增加 slot 会线性增加 descriptor、job、sample scratch 和选择器，
但当前理想模型已经长时间达到 `II=1`。没有综合和真实 memory stall 统计之前，继续
增加 slot 没有证据支持。

## 5. 公共数据格式

主要常量定义在 `rtl/pkg/synth_pkg.sv`：

| 数据 | 格式/宽度 | 含义 |
| --- | --- | --- |
| PCM | signed 16-bit | 外部波表 sample 和每 voice 最终贡献 |
| mix | signed 24-bit | 发布给后级的 block sample |
| accumulator | signed 32-bit | voice contribution 累加空间 |
| phase | unsigned Q24.8 | 高 24 位 frame index，低 8 位 fraction |
| gain/envelope level | signed Q1.15 | 正常范围 `0..0x7fff` |
| filter coefficient | signed Q2.14, 16-bit | `b0/b1/b2/a1/a2` |
| filter sample | signed 20-bit | biquad 的饱和输出 |
| filter state | signed 34-bit Q14 | 每条 voice 的 `z1/z2` |
| address | 32-bit word address | 一个地址对应一个 16-bit PCM word |
| line | 8 words | 一次 response 返回 8 个连续 PCM word |
| segment | 4 lines = 32 words | renderer 当前锁定的连续访问单位 |

几个核心 payload：

- `block_voice_state_snapshot_t`：region、运行参数、envelope 参数和动态状态的原子快照。
- `block_endpoint_job_t`：输出 frame index、fraction、两个 endpoint 地址和 envelope level。
- `block_dsp_sample_token_t`：`work_id`、job、两个 sample、voice context 和输入 `z1/z2`。
- `block_dsp_state_update_t`：DSP 中段提前返回的 tag 和新 `z1/z2`。
- `block_dsp_retire_t`：最终左右 contribution、tag、last 和最终 filter state。

ready/valid 不放进这些 payload。模块端口显式给出 `*_valid` 和 `*_ready`，只有
`valid && ready` 为 1 的上升沿才发生一次 transfer。

## 6. Voice 状态的所有权

`block_voice_state_store` 把状态分成四组 memory：

| memory | 内容 | 更新频率 |
| --- | --- | --- |
| `region_mem` | base、length、loop 范围和 loop mode | voice start/安装 |
| `event_mem` | phase increment、gain、release、filter 参数 | runtime event |
| `env_mem` | ADSR 每 sample step 和 sustain | envelope event |
| `dynamic_mem` | active、generation、phase、envelope state、z1/z2 | 每个 render block 写回 |

`generation_tag` 是防止陈旧写回的版本号。voice 被重新分配时 generation 改变；旧
block 即使晚到，其 `dynamic_write_data.generation` 不匹配，state store 只产生
`stale_dynamic_write_pulse`，不会覆盖新 voice。

当前 top 在 `render_busy=1` 时允许 state read 和 dynamic write，在 render 空闲时允许
install、parameter write 和 control event。也就是说当前版本把 runtime control 的
应用边界放在 block 之间，尚未完成 timestamped event 与 renderer 的整机并行入口。

同步读时序是：

```text
T0: controller 发 state_read_req，state store 记录 voice id
T1: state store 从四组 memory 取得 snapshot，拉高 response valid
T2+: controller 接收；如果下游忙，response payload 和 valid 保持
```

## 7. Controller：从 active bitmap 到连续工作流

`voice_major_block_controller` 的状态为：

```text
IDLE -> WAIT_FILL -> SELECT_GROUP -> SELECT_VOICE
     -> REQUEST_STATE -> WAIT_STATE -> ... -> DRAIN -> FINISH -> IDLE
```

### 7.1 接收 block

`IDLE` 中只有 mix buffer 有 free bank 且 `frame_count` 合法时，block request 才能
transfer。controller 锁存 `frame_count` 和当拍的 `active_bitmap`，后续新 start/stop
不会改变正在渲染的这一个 block 的 voice 集合。

### 7.2 两级 bitmap 扫描

active voices 先按 32 voice 分组，生成 `active_group_bitmap_q`。调度先找第一个非空
group，再在 32-bit group 内找第一个 active bit。每选中一条 voice 就清掉对应 bit。
这样组合优先选择器的输入宽度被限制为 group 数和 32，而不是直接做一个 256/512-bit
全宽优先编码器。

当前扫描仍包含 group/voice 状态转换开销。这是理想 memory 测量中少量气泡的来源
之一，未来可以做 registered tree 或一次产生多个 voice id，但不能破坏 block 开始时
active bitmap 的快照语义。

### 7.3 单项 pending state prefetch

state response 放入 `pending_state_q`。当 engine 同拍消费旧 pending snapshot 时，
`state_read_rsp_ready` 仍可为 1，新 response 可以在同一个上升沿替换旧 snapshot。
所以这是一个支持 same-cycle pop/push 的单项 elastic register。

它不是四份 voice context，也不是旧 prepared slot。真正的多上下文存储在 envelope 和
renderer 的 8 个 slot 内。controller 只保留一个跨 state-store/engine 边界的预取项。

### 7.4 outstanding 计数

每次 `engine_start_fire`，`outstanding_voices_q` 加一；每次最终 dynamic result 写回，
计数减一。两者同拍发生时计数不变。扫描完 active bitmap 后进入 `DRAIN`，必须满足：

```text
outstanding_voices_q == 0
&& !engine_result_valid
&& !pending_state_valid_q
```

才允许发布 mix block。这样不会在 DSP 或 result register 仍有 voice 时提前完成。

## 8. Envelope frontend：8-context、每拍一步

`block_interleaved_envelope_frontend` 有 8 个独立 slot，每个 slot 状态为：

```text
SLOT_FREE -> SLOT_WALK -> SLOT_DRAIN -> SLOT_READY -> SLOT_FREE
```

`start_ready` 在存在 free slot 且 `1 <= frame_count <= 8` 时为 1。若一个 READY result
同拍被下游消费，该 slot 可以同拍作为新输入的 free slot，实现 pop/push 替换。

### 8.1 Round-robin envelope walk

`walk_rr_q` 从 8 个 slot 中选择一个 `SLOT_WALK`，每拍只推进该 slot 的一个 audio
frame。tag `{slot, frame_index, last}` 随 level conversion 流水向后移动。下一拍可以
选择另一 slot，因此典型顺序是：

```text
A0 B0 C0 D0 E0 F0 G0 H0 A1 B1 C1 ...
```

同一个 slot 的 envelope state 始终按 frame 顺序递归更新，不允许 A1 越过 A0。

### 8.2 六个 envelope stage 的行为

- `ENV_DELAY`：只增加 elapsed；到期后进入 ATTACK，或在 attack step 为零时直接满幅并
  进入 HOLD/DECAY/SUSTAIN。delay 期间 voice active，但不 render sample。
- `ENV_ATTACK`：Q0.32 amplitude 加 `attack_step_q0_32`，饱和到全幅。
- `ENV_HOLD`：输出 full scale，计数结束后进入 DECAY 或 SUSTAIN。
- `ENV_DECAY`：Q12.20 centibel attenuation 向 sustain 值逼近，不越过目标。
- `ENV_SUSTAIN`：固定使用 sustain attenuation。
- `ENV_RELEASE`：attenuation 加 release step；达到 1000 cB 后先令 active=0，本 frame
  不再 phase advance，也不发 memory/DSP 工作。

每个 frame 都是先推进 state，再由新 state 产生三个输出：

- `phase_advance_mask[frame]`：active 时为 1；
- `render_mask[frame]`：active 且不在 DELAY 时为 1；
- `envelope_levels[frame]`：用于最终 gain 的 Q1.15 电平。

### 8.3 四级 centibel-to-Q1.15 pipeline

Attack 和 Hold 可以直接产生 Q1.15。Decay/Sustain/Release 需要把 centibel attenuation
转换成线性 gain。四级流水为：

| 级 | 主要工作 | 随级携带的控制 |
| --- | --- | --- |
| L0 | 锁存 attenuation 或 direct/zero 类型 | slot、frame、last、kind |
| L1 | 用 octave threshold tree 求二进制衰减 octave | 同上 |
| L2 | 减 octave 基准、舍入并生成 mantissa LUT index | 同上 |
| L3 | 读取 24-bit mantissa LUT | 同上 |
| writeback | 右移 octave、guard-bit 舍入、写对应 slot/frame | tag 决定目标 |

slot 在最后一个 frame 被发入 L0 后进入 `SLOT_DRAIN`，不能立刻输出。只有带 `last`
的 token 到达 writeback、最后一个 level 真正写入 slot 后，才转为 `SLOT_READY`。
这就是流水线 drain 的实际含义。

## 9. Renderer work slot 状态机

`block_interleaved_voice_renderer` 的每个 slot 依次经过：

```text
WORK_FREE
  -> WORK_PLAN
  -> WORK_MEM_WAIT
  -> WORK_MEM_FETCH
  -> WORK_READY
  -> WORK_DRAIN
  -> WORK_COMPLETE
  -> WORK_FREE
```

这些状态描述的是 slot 当前需要哪种共享资源：

- `WORK_PLAN`：round-robin phase planner 仍要为 frame 生成 endpoint job。
- `WORK_MEM_WAIT`：有尚未覆盖的 endpoint，等待 memory engine 选中。
- `WORK_MEM_FETCH`：当前 segment 已锁定并正在发请求/收响应；已到数据仍可提前发 DSP。
- `WORK_READY`：全部 endpoint 已返回，但可能还有 frame 未发入 DSP。
- `WORK_DRAIN`：所有 frame 已发入 DSP，等待最后一个 token retire。
- `WORK_COMPLETE`：没有任何 render job，例如 inactive/delay/done，等待 result port 发布。

`start_ready` 不只看当前 free slot。如果某个 last retire 或 empty completion 同拍发布，
旧 slot 可以在该拍结束时直接重用于新 start，避免人为制造一拍空洞。

## 10. Phase planning

phase 使用 unsigned Q24.8。假设：

```text
phase = integer_frame * 256 + fraction
```

则线性插值需要：

```text
frame_0 = integer_frame
frame_1 = next frame, with end/loop handling
fraction = phase[7:0]
next_phase = phase + phase_inc, with at most one loop subtraction
```

`mono_phase_frame` 是组合逻辑。renderer 有两个实例：一个计算当前 endpoint 和
`next_phase`，另一个只检查下一步是否 done，用于正确生成最终 `active` 状态。

V1 契约要求 `phase_inc < (loop_end-loop_start)<<8`，所以一次 phase step 最多跨越一个
loop length，只需要一次减法，不需要 while loop 或多拍除法。

phase planner 由 `plan_rr_q` round-robin 选择一个 `WORK_PLAN` slot，每拍最多处理一个
frame。只有 `phase_advance_mask=1` 才推进 phase；只有 `render_mask=1` 才保存 job。
因此 Delay 可以保持不取样，Release 到静音可以在 block 中途终止后续工作。

每个保存的 job 包含：

```text
block_frame_index
fraction
endpoint_addr[0] = base_addr + frame_0
endpoint_addr[1] = base_addr + frame_1
endpoint_mask = 2'b11
envelope_level
```

job 按该 voice 的 frame 顺序紧凑存储。即使某些 block frame 不 render，job 自身携带
原始 `block_frame_index`，退休时仍会累加到正确 mix frame。

## 11. Memory：voice-major 连续 segment

### 11.1 外部接口

当前 renderer 面向 ordered line memory：

- request payload 只有 `aligned_line_addr`；
- 每个 response 返回 8 个连续 16-bit word；
- response 必须严格按已接受 request 的顺序返回；
- response 没有 transaction ID；
- renderer 当前只允许一个 active segment。

板级 DDR adapter 必须把 DDR/MIG 的 burst、ID、重排和时钟域细节隐藏在这个接口后，
或者未来显式扩展为带 tag 的多 outstanding 协议。不能让无 tag response 乱序返回。

### 11.2 Segment 的选择

一个 segment 是 32 word，即四条 8-word line。memory scheduler round-robin 找到一个
`WORK_MEM_WAIT` slot，从其 remaining endpoint 中取最低地址对应的 32-word 对齐基址：

```text
segment_base = floor(endpoint_addr / 32) * 32
```

然后生成该 segment 覆盖的 endpoint mask，并锁定这条 voice，依次请求：

```text
segment_base + 0
segment_base + 8
segment_base + 16
segment_base + 24
```

四条 request 没有全部 transfer 前不会换 voice。这样保留 DDR、SDRAM、SRAM burst
adapter 和带预取存储器都能利用的连续访问特性。

### 11.3 Request 和 response 独立计数

`memory_request_beat_q` 只在 `line_req_valid && line_req_ready` 时增加；
`memory_response_beat_q` 只在 `line_rsp_valid && line_rsp_ready` 时增加。二者可以不同，
所以 memory 可以先接受多个 line request，再稍后依次返回。

response 的隐含地址由锁存的 segment base 和 response beat 计算。每个返回 word 会与
当前 segment mask 中所有 endpoint 地址比较，匹配者写入：

```text
work_endpoint_sample_q[work_id][endpoint]
work_endpoint_valid_q[work_id][endpoint] = 1
```

如果一个 endpoint 地址重复出现于多个 frame，一条 response 可以同时满足多个 valid
bit。segment 完成后，若仍有 remaining endpoint，slot 回到 `WORK_MEM_WAIT` 并选择下
一个 segment；否则进入 `WORK_READY`。

### 11.4 Scoreboard 使 memory 和 DSP 重叠

slot 处于 `WORK_MEM_FETCH` 时并不必等全部四条 line 返回。如果下一个待发 job 的两个
endpoint valid 已经为 1，它可以立刻参加 DSP issue。这使 response、后续 line fetch
和 DSP 对不同工作重叠。

当前策略固定读完整 32-word segment，可能读取未使用的 word。它优先保证长连续请求，
但不保证所有音色地址轨迹的带宽利用率最优。后续必须用真实 SF2/MIDI trace 比较固定
4-line 和 adaptive 1/2/4-line 策略，并统计 useful-word ratio。

## 12. DSP issue scoreboard 和 RAW hazard

issue scheduler 由 `issue_rr_q` round-robin 扫描 8 个 slot。一个 slot 可发射当且仅当：

```text
state is WORK_MEM_FETCH or WORK_READY
&& issue_index < job_count
&& 当前 job 所需 endpoint 全部 valid
&& (!hazard || same-cycle state_update for this work_id)
&& DSP token_ready
```

filtered token transfer 后，该 slot 的 `work_hazard_q` 置 1。其他 slot 不受影响。DSP
产生相同 work ID 的 `state_update_valid` 时，把新 `z1/z2` 写入 slot 并清 hazard。

关键的同拍 forwarding 是：如果 A 的 state update 正在返回，issue scheduler 可以同拍
再次选择 A。新 token 的 `filter_z1/z2` 从 state-update bus 取得，而不是从仍未在本拍
上升沿更新的 `work_z1_q/work_z2_q` 取得。这解决了非阻塞赋值导致的“读到旧状态”问题。

一个示意调度序列：

```text
cycle 0: issue A0, A.hazard=1
cycle 1: issue B0, B.hazard=1
cycle 2: issue C0
cycle 3: issue D0
cycle 4: issue E0
cycle 5: update A0; forwarding issue A1
cycle 6: update B0; forwarding issue B1
...
```

这与 CPU 的 scoreboard 加 bypass/forwarding 是同一类方法。区别在于 FPGA 这里没有
通用指令、寄存器重命名和乱序提交；tag 只标识 8 个固定硬件上下文，资源成本更低且
音频顺序更容易证明。

filter bypass 不产生递归状态依赖，因此 bypass token 不设置 hazard。同一 slot 可以
连续发射，但 round-robin 公平性仍允许其他 ready slot 使用 DSP。

## 13. DSP 每一级到底计算什么

`block_interleaved_voice_dsp` 是一条共享的 tagged pipeline。每一级寄存器同时保存数据
和 `work_id/last/voice/frame` 等控制，不能只延迟 sample 而漏延迟 tag。

| 级 | 主要运算 | 主要寄存结果 |
| --- | --- | --- |
| input/S0 | `(sample1-sample0)*fraction` | sample0、interp product、tag、z1/z2 |
| S1 | `sample0 + (product >>> 8)` | interpolated signed PCM `x` |
| S2 | `b0*x`、`b1*x`、`b2*x` | 三个 coefficient product |
| S3 | `y=sat20((b0*x+z1)>>>14)` | filter output `y` |
| S4 | `a1*y`、`a2*y` | feedback products |
| S5 | 计算并 sat34 新 z1/z2；选择 filter/bypass sample | selected sample、new state |
| S6 | selected sample 分别乘 `gain_l/gain_r` | 左右 gain product |
| retire | 再乘 envelope、缩放、sat16 | contribution、final state、last |

线性插值公式：

```text
x = sample0 + ((sample1 - sample0) * fraction >>> 8)
```

biquad 为 transposed direct form II：

```text
y  = sat20((b0*x + z1) >>> 14)
z1 = sat34(b1*x - a1*y + z2)
z2 = sat34(b2*x - a2*y)
```

filter disabled 时 `selected_sample=x`，`z1/z2` 保持原值。filter enabled 时选择 `y`。

左右输出的概念公式：

```text
left  = sat16(selected_sample * gain_l * envelope_level)
right = sat16(selected_sample * gain_r * envelope_level)
```

RTL 保留中间乘积宽度，按 Q1.15 缩放。envelope 为 `0x7fff` 时走专门路径，避免把已经
接近 unity 的 level 再带来不必要误差。所有比较、右移和饱和都显式使用 signed 宽度。

`state_update` 在新 filter state 已算出、但 token 还未 retire 时提前输出，用于缩短
hazard 距离。`retire` 只在最终 contribution 完整时输出。两者的 tag 必须相同，但用途
不同，不能合并成一个晚返回通道，否则 filtered II 会恶化。

## 14. 多个在途 token 会不会争抢同一 voice 参数

这是理解本设计最重要的问题之一。结论是：当前生产入口把参数分成“只读快照”和
“递归动态状态”两类，用不同方法消除冲突，并不是让 DSP 的每一级同时访问集中
voice RAM。

### 14.1 同一 voice 不会同时占两个 work slot

controller 接受 block 时锁存 active bitmap。一个 voice bit 被选中后立即清零，所以在
该 block 内只 dispatch 一次。controller 又必须在 `DRAIN` 等全部 outstanding voice
写回，才允许完成 block 并接受下一个 block。因此当前生产路径满足：

```text
对任意 voice V：同一时刻最多有一个属于 V 的 envelope/renderer block context
```

renderer 模块自身的裸接口没有用全局 bitmap 阻止测试平台故意重复提交同一个 voice；
“一个 block 内每个 voice 最多提交一次”是 controller 到 engine 的接口前置条件。未来
若允许多个 block 同时在 renderer 中在途，就必须增加 `{voice, block sequence}` tag、
版本化写回或显式 per-voice busy scoreboard，不能继续依赖当前条件。

### 14.2 Phase 和 envelope 参数只由一个共享端口读取

phase、region 和 event params 在 renderer start 时复制进对应 slot。phase planner 每拍
只选择一个 slot，所以这一组 slot array 在逻辑上只有一个被选中的读地址和一个更新的
phase 写地址。N 个 slot 在途不等于 N 个 slot 同拍更新。

envelope frontend 同理：每拍只有 `walk_slot` 对应的一个 context 读取/更新 envelope
state。四级 level pipeline 后续只按 tag 写 `envelope_levels[slot][frame]`，不再次读取
集中 voice state。

### 14.3 Filter coefficient 和 gain 随 token 携带

renderer start 时把 `gain_l/gain_r` 和五个 filter coefficient 复制到
`work_context_q[work_id]`。issue 时又把这个 context 放入 DSP token。DSP 各级寄存器
携带自己所需的 context 副本，因此可以出现：

```text
S0 正在使用 voice A 的参数
S2 正在使用 voice B 的参数
S4 正在使用 voice C 的参数
S6 正在使用 voice D 的 gain
```

它们读取的是各级寄存器，不是同一个单口 parameter RAM，所以没有 read-port 冲突。
即使 A0 和 A1 同时位于不同 DSP 级，它们携带的也是同一 block 边界取得的一致参数
快照。

这个选择用更宽的 pipeline register 换取简单、确定的多级并行和时序隔离。未来若为
省寄存器改成“token 只带 work_id、每级回读 slot parameter RAM”，就会真正产生多读
口、bank 冲突和 RAM latency 问题，必须重新设计 replicated/banked parameter store，
不能只删掉 payload 字段。

### 14.4 Runtime 参数不会在 block 中途改变快照

当前 `block_voice_state_store` 只在 `render_busy=0` 时接受 install、params write 和
control event。渲染期间只允许 snapshot read 和 dynamic writeback。因此某个 block
已进入 slot 后，host 不会在中途改变其 gain、phase increment 或 coefficients。
参数更新在 block 边界生效，整个 block 内使用同一个一致快照。

将来接入 timestamped event 时，如果要求 8-frame block 中途更新参数，需要把 block
按 event timestamp 切段，或让每个 sample token 携带对应 epoch 的参数。直接修改 slot
中的共享参数会让已经进入 DSP 的旧 token 和尚未 issue 的新 token 混用版本。

### 14.5 真正存在的 RAW：phase、envelope 和 filter state

| 状态 | producer/consumer | 当前解决方法 |
| --- | --- | --- |
| phase | 同一 slot 相邻 phase step | planner 每拍只选一个 slot；写回后下次再选 |
| envelope state | 同一 slot 相邻 envelope frame | round-robin walk；每 slot 严格顺序 |
| filter z1/z2 | DSP 中相邻 filtered sample | hazard bit、tagged early update、同拍 forwarding |

phase 和 envelope 的递归计算在一个时钟沿更新 slot register，同一 slot 最快也要等后续
调度拍再次被选择，因此下一次读取自然看到新值。filter 的计算跨越多级流水，不能只
靠下一拍寄存器可见性，所以必须使用显式 hazard 和 forwarding。

### 14.6 Sample scratch 的同拍读写

memory response 写 `work_endpoint_sample_q` 并设置 endpoint valid。issue 组合逻辑在该
上升沿之前看到的仍是旧 valid，因此刚返回的 endpoint 最早下一拍才能 issue。这个
一拍隔离避免依赖 FPGA RAM 的 write-first/read-first 模式。它可能损失极少量 latency，
但让不同器件上的行为更确定。

### 14.7 State store 的端口冲突边界

渲染期间 state store 可能同拍读取下一条 voice snapshot，并写回上一条 voice dynamic
state。正常 controller 顺序保证二者不是同一条 voice：一条 active bit只 dispatch
一次，写回前不会再次请求它。control/install 与 dynamic write 又由 `render_busy`
互斥。

RTL 用独立 `region_mem/event_mem/env_mem/dynamic_mem` 数组表达这些资源，但最终是
BRAM、LUTRAM 还是寄存器，以及同拍 read/write 是否映射成期望的端口结构，仍必须由
Vivado synthesis report 验证。这是物理实现签核问题，不是功能仿真已经证明的结论。

## 15. Backpressure 如何传播

DSP 使用整体停顿：

```text
advance = !retire_valid_q || retire_ready
token_ready = advance
```

如果 retire 端被 mix buffer 阻塞，`advance=0`，所有 valid bits 和所有 stage payload
保持不变。这样不会覆盖最后一级，也不会让 tag 与数据错位。代价是单个 retire stall
会冻结整条 DSP；这是当前简单且可证明的 elastic 策略。

renderer 的 retire ready 还要求：

- mix contribution port ready；
- 若当前 token 是 last，result register 必须空闲或同拍被消费。

因此最后一个 contribution 和最终 dynamic result 在逻辑上同拍完成，不会出现 mix 已
接收 last sample、但 final state 被丢失的情况。

memory request 和 response 分别遵循 ready/valid。response 无 tag，所以一旦 segment
active，renderer 必须保持其 association，不能因为 DSP stall 而切换 response owner。

## 16. Retire、状态写回和 slot 释放

普通 token retire 时：

- contribution 携带 `block_frame_index` 送 mix buffer；
- filter state 更新 slot 中的最终状态；
- slot 已在发完全部 job 后处于 `WORK_DRAIN`。

last token retire 时，还会形成 `block_voice_dsp_result_t`：

- `phase_result`：最终 phase、active、generation 和 walked frame 数；
- `filter_z1/z2`：最终递归状态；
- renderer 旁带保留 envelope final active/state。

`block_mono_voice_engine` 合并三种动态结果：

```text
active = phase_active && envelope_active
generation = phase_result.generation
phase = phase_result.phase
env_state = envelope final state
filter_z1/z2 = DSP final state
```

合并结果写回 state store。没有 render job 的 voice 走 `WORK_COMPLETE` 路径：它没有
DSP last token，但仍必须发布 phase/envelope/filter 状态，不能让 Delay 或刚结束的
voice 永远占住 slot。

## 17. Mix buffer 的双 bank ownership

`block_mix_buffer` 有两个 bank，每个 bank 为最多 8 个 frame 保存 signed 32-bit 左右
累加器。bank 状态为：

```text
BANK_FREE -> BANK_CLEARING -> BANK_FILLING
          -> BANK_PUBLISHED -> BANK_OWNED -> BANK_FREE
```

流程如下：

1. block request 选择一个 free bank。
2. 每拍清零一个 frame，清完后 `block_fill_ready=1`。
3. 每个 contribution 按 `frame_index` 加入对应 32-bit accumulator。
4. controller 确认所有 voice result 已写回后发 `block_finish`。
5. bank 发布 `buffer_id/start_frame/frame_count`。
6. consumer 接受 complete 后拥有该 bank，通过 read request 逐 frame 读取 24-bit mix。
7. consumer 完成后显式 release，bank 才回到 FREE。

不同 voice 的 contribution 可以交错退休，因为它们都带 frame index。32-bit 累加在
所有 voice 到齐前不逐项饱和，所以加法顺序不改变数学结果。读出时取 accumulator 的
低 `MIX_WIDTH=24` 位；当前 256 voice 的最坏 PCM16 和能装入 signed 24-bit，512 voice
扩展目标需要重新确认累加/发布宽度契约，不能仅凭 renderer 周期达标就视为数值安全。

双 bank 的目的，是让 renderer 填 bank N 时，下游读取 bank N-1。当前 controller 一次
只发起一个 render block，但 bank ownership 接口已经为后续跨 block overlap 留出边界。

## 18. Effects、compressor 和 I2S 应怎样并行

正确的整机目标是不同 block 同时占据不同阶段：

```text
时间段 K:
  renderer   正在填 block N
  effects    正在处理 block N-1
  compressor 正在处理 block N-2
  FIFO/I2S   正在播放更早的 frame
```

这不是给每条 voice 复制 effects。chorus/reverb 是 global effects，输入是混音后的 frame
stream。当前已有模块边界：

- `global_effects_chain`：chorus、reverb 和 effect return mixer；
- `global_audio_effects_chain`：在 global effects 后连接 look-ahead compressor；
- `output_sample_fifo`：吸收 producer/consumer 的短时速率差；
- `render_credit_scheduler`：依据 reservoir 余量决定何时请求新 block；
- `wavetable_i2s_output`：PCM FIFO 到 I2S serializer。

同一 frame 内可以在没有依赖的分支 fork：dry、chorus send、reverb send 可并行计算；
若配置了 chorus-to-reverb，reverb 的该输入边必须等待 chorus 输出。delay、FDN reverb
和 compressor 都有历史状态，同一 stream 的 frame n+1 不能无条件越过 frame n。

后续连接必须使用 bounded FIFO 或明确的 ready/valid fork/join。不能简单把一个 valid
同时连到两个分支，却只用其中一个 ready；否则一个分支可能重复消费或另一个分支丢帧。

## 19. 一段稳态时序示例

以下只表示并行关系，不代表固定 voice ID：

| clock | state read | envelope | phase | memory | DSP issue | DSP middle | retire |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 0 | voice H | G0 | F0 | E line0 | A0 | - | - |
| 1 | voice I | H0 | G0 | E line1 | B0 | A interp | - |
| 2 | voice J | I0 | H0 | E line2 | C0 | B interp | - |
| 3 | voice K | J0 | I0 | E line3 | D0 | C coeff | - |
| 4 | voice L | K0 | J0 | F line0 | E0 | D filter | - |
| 5 | voice M | L0 | K0 | F line1 | A1 forwarded | A state update | - |
| 7+ | ... | ... | ... | ... | ... | ... | A0/B0/... |

同一拍可以有多个模块各完成一次 transfer，因为它们是独立硬件。每个共享模块内部仍
每拍最多选择一项：一个 envelope step、一个 phase step、一个 line request、一个 DSP
token 和一个 retire。

## 20. 当前测量和含义

条件：8 frames、理想 ordered memory 每拍可接受一个 line request、下一拍开始有序返回。

| active mono lanes | filter off | filter on | DSP issues | line requests |
| ---: | ---: | ---: | ---: | ---: |
| 256 | 2149 clocks | 2191 clocks | 2048 | 1024 |
| 512 | 4197 clocks | 4258 clocks | 4096 | 2048 |

256 filtered 和 512 filtered 都观察到最长 312 clocks 连续每拍 issue。这证明当前生产
SV 在长稳态区间能达到 sample `II=1`。它不证明整个 block 从第一拍到最后一拍无气泡；
fill/drain、group scan、memory segment 交接和尾部不足 8 个 ready context 都会产生空拍。

相对历史架构的 256-lane 周期：

| 架构 | filter off | filter on |
| --- | ---: | ---: |
| 旧 single-voice DSP FSM | 13328 | 21520 |
| 已删除 prepared-slot renderer | 7218 | 13625 |
| 2-entry streaming/forwarding | 5928 | 7734 |
| 8 tags、串行 frontend | 5928 | 5956 |
| interleaved phase/memory frontend | 3373 | 3401 |
| 当前 envelope + renderer tagged pipeline | 2149 | 2191 |

当前架构相对 2-slot 版本明显更快，特别是 filter-on 已接近 filter-off。因此已选定该
架构，旧串行 envelope/endpoint/segment/gather RTL 和专属 TB 已删除。

## 21. 估算带宽时不能漏掉什么

256 voices、8 frames 有 2048 个有效 sample job。理想连续 phase 的两个 endpoint 高度
重叠，但固定 segment 策略当前测量发出 1024 条 line request：

```text
1024 lines * 8 words/line * 2 bytes/word = 16384 bytes/block
```

在 48 kHz、8-frame block 下每秒 6000 blocks：

```text
16384 * 6000 = 98.304 MB/s
```

512 lane 对应约 196.608 MB/s。这里是当前理想 TB 请求数换算，不包含 DDR command
overhead、refresh、row miss、其他 master、ECC、总线宽度填充，也不保证真实音乐轨迹
完全相同。板级设计必须基于实测 request trace 和 MIG 效率留余量。

## 22. 必须保持的设计不变量

修改流水线时至少保持以下条件：

1. 同一 voice 的 envelope、phase 和 filter state 按 frame 顺序演进。
2. 不同 voice 可以交错，但 contribution 必须携带正确 voice/generation/frame tag。
3. filtered slot 有未返回 state update 时不得使用旧 z1/z2 发下一 token。
4. state update 与再发同拍时必须 forwarding。
5. DSP stall 时 valid、数据和 tag 全部保持。
6. 一个 memory segment 锁定后，四条 line request 连续且 response association 不变。
7. 无 tag memory response 必须有序；若允许乱序，协议必须增加显式 transaction tag。
8. block 发布前所有 accepted voice 必须完成 dynamic writeback。
9. generation 不匹配的 parameter/dynamic/control write 不得修改新 voice。
10. mix bank 未被 consumer release 前不得重新用于 fill。
11. fixed-point 的移位、舍入、饱和和 signed extension 必须与文档及 TB 一致。
12. effects 接入后，任何 fork 的每个分支都必须恰好消费一次 frame。

## 23. 当前验证覆盖

生产路径的 focused SV TB 包括：

- `tb_block_interleaved_envelope_frontend`：8-context tag、level 和 backpressure；
- `tb_block_interleaved_voice_renderer`：基础 endpoint/memory/DSP/result 和 stall；
- `tb_block_interleaved_voice_dsp`：精确整数运算、tag、state update 和 retire stall；
- `tb_block_mono_voice_engine`：envelope 到最终 dynamic result；
- `tb_voice_major_block_controller`：active scan、state dispatch、drain 和 mix；
- `tb_voice_major_render_core`：state continuity、block 发布和读取；
- `tb_voice_major_throughput`：256/512、filter on/off、连续 line、hazard、forwarding、
  issue/retire 数量、deadline 和至少 64 拍连续 `II=1`。

效果器、compressor、FIFO/I2S、SPI、SD 和 Smart Artix DDR subsystem 有各自 focused TB，
但目前没有一个 TB 同时覆盖全部模块。

## 24. 尚未证明和下一步验证

### 24.1 Memory realism

需要给 production renderer TB 增加固定和随机 request/response stall，并统计：slot
occupancy、phase starvation、memory starvation、hazard stall、retire stall、segment
useful words、p50/p99/max block cycles。还要补 jumped address、fractional phase 和
loop-wrap 的直接 renderer 回归。

### 24.2 Synthesis and timing

当前环境没有 Vivado。必须确认：

- slot descriptor/job/sample array 推断成 LUTRAM/BRAM 还是大量寄存器；
- DSP 乘法是否映射到 DSP48，数量是否符合器件预算；
- 8-slot round-robin scan 和 endpoint compare 的组合路径能否达到 100 MHz；
- fanout、routing、BRAM port 冲突是否引入额外级；
- reset 方式是否阻碍 RAM inference。

如果 timing 不通过，应优先给 selection tree 加寄存、bank slot arrays 或分离 arbitration
级，同时保持 tag/scoreboard 契约。不能仅通过降低测试负载掩盖 timing failure。

### 24.3 Whole-system overlap

需要建立持续运行 TB：credit scheduler 请求 block，renderer 填 bank，effects 读取前一
bank，compressor/FIFO/I2S 消费，同时 memory 注入 realistic stalls。判定条件应包括：

- 输出 frame 数和 exact integer sample 正确；
- 所有 block start_frame 连续；
- FIFO occupancy 有界；
- 不发生 overflow/underflow/underrun；
- 最坏 renderer + effects 延迟仍低于 reservoir 提供的 slack；
- 长 MIDI/SF2 trace 与独立 reference 一致。

## 25. 修改架构时的检查顺序

1. 先写清楚改变的是 latency、II、memory bandwidth 还是 resource。
2. 列出新增/删除的状态和 tag，确认每个 backpressure 路径如何保持 payload。
3. 对所有递归状态画出 producer、consumer、hazard clear 和 forwarding 时刻。
4. 对 memory 写出 request 接受顺序和 response association，不依赖波形猜测。
5. 增加 exact self-checking SV TB，再测 256/512 filter on/off 周期。
6. 运行 `make lint`、`make test`、四个 throughput target 和 512 回归。
7. 运行综合和 post-route timing，检查 RAM/DSP inference 后再决定 slot 数或复制资源。
8. 同步更新本文、handoff、module map 和 verification 文档。

## 26. 推荐源码阅读顺序

1. `rtl/pkg/synth_pkg.sv`：宽度、状态和 token 定义。
2. `rtl/top/voice_major_render_core.sv`：顶层边界。
3. `rtl/control/block_voice_state_store.sv`：状态所有权和 generation。
4. `rtl/voice/voice_major_block_controller.sv`：block 生命周期和 active scan。
5. `rtl/voice/block_interleaved_envelope_frontend.sv`：第一个 tagged pipeline。
6. `rtl/voice/mono_phase_frame.sv`：Q24.8、loop 和 endpoint。
7. `rtl/voice/block_interleaved_voice_renderer.sv`：8-slot scheduler、memory 和 hazard。
8. `rtl/dsp/block_interleaved_voice_dsp.sv`：逐级定点计算。
9. `rtl/voice/block_mix_buffer.sv`：双 bank ownership。
10. `sim/tb/tb_voice_major_throughput.sv`：吞吐量判定依据。

快速了解可先读 `voice_major_block_renderer_guide.md`；恢复开发状态看
`voice_major_block_renderer_handoff.md`；本文作为逐项核对当前实现的主设计说明。
