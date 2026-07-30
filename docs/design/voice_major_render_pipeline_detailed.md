# Voice-Major Render Pipeline Detailed Design

Updated: 2026-07-30

本文是当前 production RTL 的 cycle-level detailed design。旧 8-slot baseline 保留在 Git
历史中，不再与当前实现混写。稳定的数值和外部接口合同分别见 `../fixed_point.md`、
`../memory_format.md` 和 `../register_map.md`；本文重点解释 renderer 内部为什么这样分层、
各级拥有什么状态，以及并行度实际出现在哪里。

当前默认配置为：

| 项目 | 当前值 |
| --- | ---: |
| voices | 512 |
| 最大 block frames | 16 |
| renderer work entries | 8 |
| DSP hazard lanes | 8 |
| 外部 line | 8 words / 128 bits |
| 每 voice sample window | 32 words / 4 lines |
| 系统时钟 / 采样率 | 100 MHz / 48 kHz |

## 1. 设计目标与核心取舍

一次 16-frame block 的实时预算为：

```text
100,000,000 / 48,000 = 2,083.33 clocks/frame
16 * 2,083.33        = 33,333.33 clocks/block
```

512 voices 全部 active 时，一个 block 包含最多 8,192 个 voice-frame。平均预算只有
`33,333 / 8,192 = 4.069 clocks/voice-frame`。因此设计不能把 envelope、DDR、filter 和
mix 全部按 voice 串行执行，但也不能为了理论上的全并行复制 512 份状态和选择器。

当前架构遵循五条原则：

1. **按所有权切开状态。** command、动态 voice 状态、block 临时状态、sample window、
   mix bank 各有唯一写入者，避免多端口寄存器阵列和隐含一致性协议。
2. **便宜且确定的工作串行化。** controller 固定扫描 voice ID，envelope 只保留一个
   context。这里宁可付出固定周期，也不复制宽状态和优先编码器。
3. **只在可隐藏延迟处保留多 context。** renderer 的 8 个 work entry 用来覆盖 DDR
   等待和 biquad feedback 距离，不代表 8 套 renderer 或 8 套 DSP。
4. **用顺序和隐含信息换存储宽度。** memory response 保序，descriptor 只保存 line
   address 和连续区间终点；区间起点由每个 work 的 cursor 隐含。
5. **允许局部 bubble，限制全局选择逻辑。** phase、memory、lane load 和 DSP issue
   使用固定 modulo 指针。当前候选不能工作时允许空拍，不做全表 ready search。

第五条是有意的面积/时序取舍。512-voice 设计的主要风险是 LUT 和长组合选择路径，不是
每个局部单元都必须达到名义 `II=1`。是否值得增加 look-ahead，只能由完整 block 周期和
post-route 结果决定。

## 2. 当前数据流与并行边界

```text
SPI command stream / register bus
                 |
                 v
       voice_major_command_plane
                 |
                 v
       block_voice_state_store
                 |
          synchronous snapshot
                 |
                 v
   voice_major_block_controller
                 |
                 v
       block_mono_voice_engine
        |                    |
        |                    +-- one-context envelope frontend
        |
        +-- 8-entry renderer work ring
             |       |       |
             |       |       +-- fixed 8-lane DSP barrel
             |       +---------- 32-word/voice sample window
             +------------------ phase/job/descriptor planner
                 |
          PCM16 stereo contributions
                 |
                 v
        two-bank block_mix_buffer
                 |
                 v
 chorus/reverb -> compressor/master -> output FIFO -> I2S
```

这里有三个不同层次的“顺序”：

- **block 顺序**：控制命令先在 block 边界排空，随后才接受下一次 render request。
- **voice-major 顺序**：controller 固定读取 voice 0 到 511；一个 voice 生成本 block 的
  全部 frame 工作后才最终写回动态状态。
- **renderer 内部交错**：多个 voice 的 phase、memory 和 DSP 工作可以同时在途，实际
  retire 顺序不要求等于 voice ID 顺序。

只要每个 voice 自身的 phase、envelope 和 filter 顺序保持，跨 voice 的交错不会改变
PCM 数值。所有贡献通过原始 `block_frame_index` 回到正确的 mix frame。

### 2.1 “Voice-major”不等于一个 voice 独占 DSP

当前流水线在不同边界使用不同粒度：

| 边界 | 一项工作的粒度 | 是否跨 voice 交错 |
| --- | --- | --- |
| controller/state store | 一个 voice 的完整 snapshot | 按 voice ID 顺序请求 |
| envelope frontend | 一个 voice 的整个 block | 不交错，单 context |
| phase planner | 一个 voice 的一个 output frame | 在 8 个 work entry 间交错 |
| sample window | 一条 descriptor / 8-word line | 单项 modulo 指针轮询 work |
| DSP | 一个 voice 的一个 audible output frame | 在 8 个 hazard lane 间交错 |
| mix | 一个 voice-frame 的 stereo contribution | 按 `block_frame_index` 汇合 |
| dynamic writeback | 一个 voice 的 block 最终状态 | 每个 accepted active voice 一次 |

因此 controller 的顺序是：先取得 voice A 的完整状态并让 envelope 生成 A 在本 block 的
mask/level，然后取得 voice B；但 A 一旦被 engine 接受，controller 不会等待 A 的最终
DSP result，A 会作为 outstanding work 留在 renderer 中。B、C 等 voice 可以继续进入其余
work entry。

稳态且各 voice 的 sample 都 ready 时，DSP issue 更接近：

```text
A0 B0 C0 D0 E0 F0 G0 H0 A1 B1 C1 D1 ...
```

这里 `A0` 表示 voice A 对 block frame 0 的一次 DSP token，而不是 A 的整个 block。每个
token 完成两个 endpoint 的插值、可选 filter、左右 gain 和 envelope gain。A 的下一 frame
要等 issue 指针绕过其他 lane 后才有资格再次进入；这段间隔让 A0 的新 filter `z1/z2`
在 A1 issue 前返回。8-lane 描述的是 context 重访规则，不是“严格每 8 clocks 接受一个
A token”；同步 job/sample RAM 和 token staging 还会增加固定拍数。

如果只有 voice A active，它只绑定一个 lane，不会复制到其余 7 个 lane：

```text
A0  -  -  -  -  -  -  -  A1  -  -  -  -  -  -  -  A2 ...
```

`-` 表示 modulo 指针访问空 lane 产生的 bubble。当前设计有意不在低复音时压缩 lane，也
不允许同一递归 filter context 同时占多个 lane。这样控制和 hazard 逻辑固定、简单；代价是
低复音 DSP 利用率低，但低复音 workload 的总 deadline 余量很大。

上面的顺序是说明粒度的稳态示例，不是全局完成顺序保证。某个 lane 的 sample 尚未到齐会
产生 bubble，其他 work 的 DDR、phase 或 DSP 仍可在途；Delay、Release 静音或 sample done
也可能让某个 voice 少于 16 个 audible job。唯一必须保持的是同一 voice 内部的 job 顺序。

### 2.2 一个 Block 从请求到释放的完整时间顺序

下面的图表示依赖关系和允许重叠的区间，不按字符宽度表示精确 clocks：

```text
time ------------------------------------------------------------------------>

command     [ drain pending actions ]
block req                            [accept]
mix bank                              [clear 0..15][       accumulate       ][publish]
controller                                         [scan voice 0 ........ 511][drain]
envelope                                            [ A block ][ B block ][ C block ]...
renderer A                                                    [plan][memory----][DSP----][result]
renderer B                                                              [plan][memory----][DSP----][result]
renderer C                                                                        [plan][memory----][DSP----][result]
DDR/window                                                       [refill/hit/fallback responses........]
DSP                                                                    [A0 B0 C0 ... A1 B1 ...]
result handoff/check                                                      [A] [B] ... [last]
block complete                                                                            [handshake]
mix read/effects                                                                                 [0..15]
bank release                                                                                           [release]
next block req                                                                                           [accept]
```

完整顺序分为以下阶段：

1. **命令边界。** command plane 排空已接收 action；有 pending action 时 block request 被挡住。
2. **接受与清零。** block 和一个 free mix bank 同拍绑定。mix bank 用 `frame_count` 个 clocks
   逐项清零；controller 在 `WAIT_FILL` 等到 bank 进入 `FILLING`。
3. **扫描和派发。** controller 从 voice 0 到 511 发同步 snapshot request。inactive voice
   直接跳过；active voice 等 envelope `start_ready` 后进入 engine。controller 随后可请求
   下一 voice，不等刚派发 voice 完成。
4. **voice 内前后依赖。** 对任一 voice，必须先完成整个 block 的 envelope walk，renderer
   才能得到 masks/levels；之后 phase planning 才生成 job 和 descriptor。对同一 voice，
   `envelope -> phase/job -> endpoint data -> DSP -> result` 不能颠倒。
5. **voice 间重叠。** envelope 处理 B 时，A 可以规划、等待 DDR 或执行 DSP；A、B、C 的
   renderer work 可以同时处于不同阶段。这是当前主要的 latency hiding。
6. **累加和 result handoff。** 每个 DSP retire 同拍提交一个 contribution。某 voice 的
   last retire 还会生成一次 dynamic result；state store 接受它后取得写回所有权，再执行
   generation check 和 RAM apply。
7. **block drain。** voice 511 扫描结束不等于 block 完成。controller 在 `DRAIN` 等所有
   outstanding result 交给 state store，再用 `FINISH` 发布 mix bank。`outstanding` 本身只
   证明 handoff；block 边界的状态顺序还依赖 state store 在 generation check / RAM apply
   完成前拒绝下一次 state read。
8. **读出和释放。** consumer 获得 bank ownership，逐帧读出并送进 effects；最后一帧被
   effects 接受后才 release bank。

### 2.3 单条 Voice 的因果链与跨 Voice 重叠

对 voice A 的严格因果链是：

```text
snapshot A
  -> envelope A[0..15]
  -> phase/job A[0..15]
  -> descriptors/endpoints A
  -> DSP tokens A0..An（严格按 job 顺序）
  -> last retire A
  -> dynamic result handoff A
  -> generation check / dynamic RAM apply A
```

但全局不要求等 A writeback 后才开始 B：

```text
snapshot/envelope:  [ A ][ B ][ C ][ D ]...
renderer work:          [ A plan/mem/DSP -------- ]
                              [ B plan/mem/DSP -------- ]
                                    [ C plan/mem/DSP -------- ]
DSP issue:                           A0 B0 A1 C0 B1 D0 ...
writeback:                                      A    B  C ...
```

所以“voice-major”只约束 snapshot/dispatch 的外层遍历和每个 voice 的内部顺序，不要求
voice 的最终完成顺序，也不要求一条 voice 连续占用 DSP 直到 16 frames 全部结束。

### 2.4 无 Backpressure 时的局部拍级顺序

下表从各局部 handshake 的接受沿开始计数。它用于理解寄存边界，不是把所有行相加得到
block latency；不同 voice、DDR transaction 和 DSP token 会重叠。

| 局部过程 | 上升沿顺序 |
| --- | --- |
| mix bank clear | block 在 `T0` 接受；随后每拍清一个 frame，16-frame 在 16 个 clear clocks 后进入 `FILLING` |
| state snapshot | `R0` 接受 read request并触发同步 RAM；`R1` capture 四组 RAM 输出并拉高 response；`R2` controller 接受 response，随后 dispatch/skip |
| envelope 一帧 | 选择当前 state -> 计算 next state -> apply next state，递归主链约三拍；cB-to-Q1.15 level 继续经过四级 pipeline |
| envelope 完成 | last frame apply 后进入 `DRAIN`；last level writeback 后才进入 `READY` 并允许 renderer 接收 |
| phase/job | `P0` 选择 work 并锁存规划输入；`P1` 计算 phase/endpoints 并写 job payload；随后 descriptor stage 合并 open line，必要时写一或两个 bank |
| descriptor issue | 选择 work -> 同步读 descriptor bank -> 锁存 window request；只有 window `ready` 时 cursor 才前进 |
| window hit | 接受 client request -> 同步 metadata lookup -> 同步 data read -> client response |
| window miss | lookup 判 miss 后发一条 fallback 或四条 refill request；response 保序，第一条所需 line 可先返回给 gather |
| response gather | 锁存 line/tag/endpoint range；从下一拍开始每拍写一个 endpoint sample 和 valid bit |
| DSP issue | 选择 lane并同步读 job/sample RAM -> 组装 token register -> DSP 接受 token |
| DSP feedback | token 穿过 interpolation/filter 前半；stage 4 提前发布新 `z1/z2`，早于最终 contribution retire |
| DSP retire | gain/envelope 尾级完成后进入两项 retire FIFO；`contribution_ready` 决定何时真正累加和发布 last result |
| dynamic write | state store 接受 result -> 同步读当前 generation -> capture/compare -> 匹配时 apply RAM write |

这些寄存边界解释了为什么“8 lane”不能直接换算成“同一 voice 每 8 clocks 一个 frame”。
即使 issue pointer 每八个 lane 位置回到原 context，job/sample 的同步读和 token register 仍在
lane 选择与 DSP acceptance 之间。真正的周期数应从 handshake trace 或 block counter 量取。

## 3. Block 与控制边界

`voice_major_render_core` 同时组合 command plane、state store 和 block controller。
command FIFO、parser 或 dispatcher 还有 action 时，`command_action_pending=1`，新的 block
request 不会被接受。state store 也只在 `render_busy=0` 时接受 install 和 runtime event。

因此当前一致性模型是：

```text
drain commands -> atomically update state -> accept block -> render/writeback
```

它不是 sample 内 timestamp event，也没有 command 与 renderer 并发写同一个 voice。
代价是命令可能推迟 block 启动；收益是 block 内 snapshot 稳定，不需要多版本参数或复杂
读写冲突处理。

每个 block request 携带：

- `start_frame`：输出时间线位置；
- `frame_count`：`1..16`，板级调度器固定请求 16。

完成后 renderer 发布一个 mix buffer ID、起始 frame 和 frame count。consumer 必须逐帧
读取，并显式 release；发布不等于自动释放。

## 4. Voice 状态所有权

`block_voice_state_store` 使用四组 512-depth 同步 RAM：

| bank | 内容 | 主要写入者 |
| --- | --- | --- |
| `region_mem` | base、length、loop start/end、loop mode | START/install |
| `event_mem` | phase increment、gain、release、filter | command/control |
| `env_mem` | envelope durations、steps、sustain | command/control |
| `dynamic_mem` | active、generation、phase、envelope state、z1/z2 | install / renderer writeback |

宽 packed struct 在 RAM 边界转成单个 vector word，避免 Vivado 把每个成员拆成大量浅 RAM。

动态写回带 16-bit generation。START 重新分配 voice 时 generation 改变；旧工作即使晚到，
写回前也会重新读取当前 active/generation。只有二者匹配才更新 `dynamic_mem`，否则增加
stale 诊断而不破坏新 voice。

一次 renderer snapshot 同时取得四个 bank 的同一 voice 内容。接口为 ready/valid，响应
在下游 backpressure 时保持，不假设组合异步读。

## 5. Controller：固定扫描而不是 active bitmap

当前 `voice_major_block_controller` 状态机是：

```text
IDLE
  -> WAIT_FILL
  -> REQUEST_STATE
  -> WAIT_STATE
  -> DISPATCH_STATE
  -> ... voice 0..511 ...
  -> DRAIN
  -> FINISH
  -> IDLE
```

### 5.1 为什么扫描全部 512 voices

旧设计维护 active bitmap、group bitmap 和优先选择器。它能跳过 inactive voice，却增加
宽寄存状态、更新一致性和优先编码路径。当前设计固定 `scan_voice_q++`，每个 voice 做一次
同步 snapshot，inactive voice 在 `DISPATCH_STATE` 直接跳过。

这使控制成本与 512 固定相关，而不是与 active voice 数相关。它对低复音不是最省周期，
但状态机小、访问顺序确定，并且避免为控制面复制一套 active 索引。当前压力目标接近
512 active voices，这个取舍符合实际 workload。

### 5.2 Pending snapshot 与 outstanding

controller 有一个 `pending_state_q`，只缓存 state-store 到 engine 边界的一条 snapshot。
它不是 renderer work entry，也不是 envelope 多 context 队列。

active snapshot 成功进入 engine 时，`outstanding_voices_q` 加一；engine result 与 state store
完成 `dynamic_write_valid && dynamic_write_ready` handoff 时减一。这个计数跟踪的是 renderer
尚未交出的 result，不是 state store 内部 generation-check pipeline 是否已完成。
一次 `engine_start_fire` 后，controller 就可继续请求下一 voice，不等待刚派发 voice 的
result；并行上限由单 context envelope 的接收速率和 renderer 的 8 个 free work entry
共同决定。
扫描到 voice 511 后，只有满足：

```text
outstanding_voices == 0
&& !engine_result_valid
&& !pending_state_valid
```

才进入 `FINISH`。这保证没有在途 DSP、result backpressure 或待派发 snapshot 时提前发布
mix block。

## 6. Envelope frontend：单递归 context

`block_interleaved_envelope_frontend` 当前明确设置 `SLOT_COUNT=1`。它接收一个 voice
snapshot，连续推进请求 block 中的 envelope，然后一次性交给 renderer：

```text
phase_advance_mask[0..15]
render_mask[0..15]
envelope_levels[0..15]
final envelope state / active
```

两个 mask 的含义不同：

- `phase_advance_mask` 决定这一 output frame 是否推进 source phase；
- `render_mask` 决定是否生成 interpolation job。

例如 Delay 中 voice 仍 active，但不产生 sample；Release 到静音时可以停止后续 phase 和
memory 工作。renderer 不需要重新解释 envelope stage，只消费这三个结果。

### 6.1 为什么不在这里保留 8 context

envelope state 是严格递归的，同一 voice 的 frame N+1 依赖 frame N。旧多 slot frontend
需要保存和搜索多份宽 envelope 状态，但后面已经有 8-entry renderer 吸收 variable DDR
latency。把 buffer boundary 放在 envelope 之后，可以让前端只保留一个 context，同时让
已准备好的 voice 在 renderer 内交错。

这会限制 state scan 到 renderer 的峰值 dispatch 速率，但当前综合结果证明节省的 LUT/FF
比复制 envelope context 更有价值。未来只有 block 周期显示 frontend 成为主瓶颈时，才应
增加 context，而不是为了结构对称而增加。

### 6.2 Envelope 数值流水

Delay、Attack、Hold、Decay、Sustain、Release 由 FPGA 持续推进。Attack 使用 Q0.32 level；
Decay/Sustain/Release 使用 Q12.20 centibel attenuation。cB 到 Q1.15 的转换经过 range
reduction 和 LUT pipeline，最后一级写入对应 frame 的 level。

最后一个 frame 发入转换流水并不代表 voice 已完成。frontend 必须等待最后一个 level
writeback 后才拉高 result valid，这就是 `SLOT_DRAIN` 的含义。

## 7. Renderer：8 个 work entry 的职责

`block_interleaved_voice_renderer` 有 8 个 work entry。一个 entry 保存一条 voice 在当前
block 内尚未完成的上下文：

- voice ID、generation、gain 和 filter coefficients；
- phase、loop region、phase increment 和 release 状态；
- 最终 envelope state/active；
- job count、descriptor count 和各阶段 cursor；
- 当前 filter `z1/z2`；
- endpoint required/valid scoreboard；
- 是否已绑定 DSP hazard lane。

它的状态机为：

```text
WORK_FREE
  -> WORK_PLAN
  -> WORK_PLAN_CALC
  -> WORK_PLAN_FINAL
  -> WORK_MEM_WAIT / WORK_MEM_FETCH
  -> WORK_READY
  -> WORK_DRAIN
  -> WORK_FREE

无 audible job：WORK_PLAN_FINAL -> WORK_COMPLETE -> WORK_FREE
```

`PLAN_CALC` 和 `PLAN_FINAL` 是为组合 phase 计算、descriptor 更新和同步 RAM 写入插入的明确
边界。`MEM_WAIT/FETCH/READY` 允许 sample 到齐的 job 提前进入 DSP，不要求先取回整条 voice
的所有 endpoints。`DRAIN` 表示最后一个 token 已 issue，等待 retire 和最终状态发布。

last retire 或 empty completion 与新 start 可以同拍复用同一个 entry，避免人为增加一拍
空洞。

## 8. Phase、Job 与紧凑 Descriptor

### 8.1 Phase 规划

phase 是 unsigned Q24.8：

```text
frame_0  = phase[31:8]
fraction = phase[7:0]
frame_1  = frame_0 + 1，并按 sample/loop 边界调整
next     = phase + phase_inc，并按 loop 规则调整
```

`loop_end` 为 exclusive。V1 要求 `phase_inc < (loop_end-loop_start)<<8`，所以一次 step
最多跨越一个 loop span，只需一次减法，不需要多拍除法或 while loop。

planner 使用单项 modulo 指针选择一个 `WORK_PLAN` entry。每拍最多规划一个 frame pair。
只有 `phase_advance_mask=1` 才推进 phase；只有同时 `render_mask=1` 且尚未 done 才存 job。

### 8.2 Job 只保存 DSP 真正需要的内容

audible frame 被紧凑存入同步 BRAM，payload 为：

```text
{block_frame_index[3:0], fraction[7:0], envelope_level[15:0]}
= 28 bits
```

`block_frame_index` 保留原始输出 frame，因此中间不 render 的 frame 不会改变 mix 位置。
两个 endpoint 的 line 内 3-bit word offset 另存为 `128x6` distributed RAM；sample-0 和
sample-1 各自进入一个同步 BRAM。地址、sample 和 payload 不在 work entry 中展开成宽
寄存器阵列。

### 8.3 Descriptor 表示连续 endpoint run

每个 audible job 产生两个按顺序编号的 endpoint：

```text
endpoint 2*j     = sample_0
endpoint 2*j + 1 = sample_1
```

相邻 endpoint 如果落在同一 8-word line，就合并到同一个 descriptor。当前 descriptor 是
34 bits：

```text
{line_addr[28:0], last_endpoint[4:0]}
```

它不保存 first endpoint，也不保存 32-bit mask。每个 work 的
`work_descriptor_next_endpoint_q` 就是下一条 descriptor 的隐含起点。因为 request 和
response 保序，response gather 只需从 first 递增到 inclusive last。

为什么需要两个 descriptor bank：一个 planner step 可能先关闭旧 open line，随后发现
sample-0 与 sample-1 又跨 line，因此同拍最多关闭两条 descriptor。两 bank 允许最多双
emit，仍保持每拍规划一个 frame pair。memory issue 用 descriptor index 的 parity 选择
bank，逻辑顺序不变。

这个表示法的关键前提是 endpoint 按紧凑 job 顺序生成、descriptor 不重排。若未来外部
memory 允许乱序 response，就必须增加 transaction tag 或 reorder buffer，不能继续依赖
隐含 cursor。

## 9. Sample Window 与外部 Memory

### 9.1 32-word/voice window 的真实含义

`voice_sample_window` 为每条 voice 保存一个 32-word 连续窗口，即四条 8-word line。
metadata 记录 valid 和 window base，data 存在 BRAM。它是持久的 per-voice sample window，
不是通用组相联 cache。

一条 work 的第一条 descriptor 带 `client_req_refill=1`：

- 命中已有 window 时直接返回对应 line；
- 未命中时从请求 line 开始连续读取四条 line，建立新 window。

该 work 后续 descriptor 带 `client_req_refill=0`。若仍在 window 内就命中；若越界则只读
一条 fallback line，不替换主 window。这避免线性插值在窗口边界偶尔多取一个 endpoint
时反复抖动整个窗口。

### 9.2 Client 与 DDR 并行度不要混淆

sample window 的 client 侧当前是单事务状态机：`IDLE -> LOOKUP -> HIT_WAIT/MISS`。
renderer 一次只向它提交一条 descriptor。一次四-line refill 内部可以先接受多个外部
request，再按顺序接收 response；Smart Artix line reader 和 DDR arbiter 也能保存多个
ordered render read。这些能力覆盖 DDR latency，但不等于 renderer 同时有多个独立
window miss state machine。

外部合同为 ordered、untagged、8-word ready/valid：

- request 只携带 aligned word address；
- response 不携带 transaction ID；
- response 顺序必须等于 accepted request 顺序；
- backpressure 时 request/response payload 必须保持。

### 9.3 Response gather

window 返回 line 和 work tag 后，gather 每拍处理一个 endpoint：

1. 用 endpoint parity 选择 sample-0 或 sample-1 BRAM；
2. 用 job offset RAM 选择 line 中的 word；
3. 写 sample BRAM；
4. 设置对应 endpoint valid bit；
5. 到 `last_endpoint` 后释放 gather。

DSP issue 只检查该 work 下一 job 的两个 endpoint valid，因此前面的 line 到达后可以与
后续 descriptor fetch 重叠。

诊断计数满足：

```text
client_requests - window_hits = window_refills + fallback_reads
memory_reads = 4 * window_refills + fallback_reads
```

`memory_reads` 才是外部 8-word read 数；不要把它命名或解释为 cache miss 数。

## 10. DSP Hazard Lane 与算术流水

### 10.1 Lane 不是一套 DSP

renderer 有 8 个逻辑 lane，但只有一套 `block_interleaved_voice_dsp`。work 的第一对 sample
ready 后绑定一个空 lane，直到该 work 的 last token retire 才释放。issue 指针固定按 lane
modulo 轮转：

```text
lane 0 -> 1 -> 2 -> ... -> 7 -> 0
```

某 lane 无 work 或下一 job sample 未到齐时产生 bubble，不搜索其他 ready lane。这样没有
8-way ready priority encoder，也不需要比较所有在途 filter tag。

DSP 的输入单位始终是一个 `voice-frame` token，不是一个 voice block。所谓 8-lane 是把
最多 8 条 voice 的递归 context 映射到同一套 DSP 的八个时间位置，不是复制八套算术单元。
一个 work 只能绑定一个 lane；即使只有它 ready，也不会借用其他空 lane。

8-lane 间隔大于 filter state update 的反馈距离。同一 work 再次被 issue 前，前一 token
的新 `z1/z2` 已写回；若 update 与 issue 同拍，token 构造逻辑显式 forward 新状态。这是
固定 barrel 的主要设计目的。

### 10.2 DSP stage

七级 valid pipeline 执行：

```text
linear interpolation
  -> b0*x, b1*x, b2*x
  -> y = b0*x + z1，round/saturate
  -> a1*y, a2*y
  -> new z1/z2，选择 filtered/bypass sample
  -> left/right gain
  -> envelope gain，PCM16 saturation
```

filter 是 transposed direct-form II。stage 4 提前输出 `{work_id,new_z1,new_z2}`；最终 retire
只携带 `{work_id,last,frame_index,left contribution,right contribution}`。voice identity、
generation 和最终 filter state 保留在 work entry，不重复穿过尾级和两项 retire FIFO。

DSP 在 retire FIFO 未满时整体 advance。backpressure 会冻结 valid pipeline，不能丢 token
或只冻结 payload 的一部分。

## 11. Result、写回与 generation

最后一个 audible job retire 时，renderer 同时完成三件事：

1. 将 PCM16 左右 contribution 交给 mix buffer；
2. 从 work entry 组合最终 phase、filter state、envelope state 和 identity；
3. 释放 lane 和 work entry。

没有 audible job 的 voice 走 `WORK_COMPLETE`，仍写回 phase/envelope/active 结果，但不产生
mix contribution。

`block_mono_voice_engine` 合并 envelope 和 renderer 结果：最终 active 是 phase active 与
envelope active 的 AND。state store 再用 voice ID 和 generation 验证该动态写回。

## 12. Mix Buffer：双 bank 是所有权解耦

`block_mix_buffer` 有两个 bank，每个 bank 保存最多 16 个 stereo signed-32 accumulator。
状态为：

```text
BANK_FREE -> BANK_CLEARING -> BANK_FILLING
          -> BANK_PUBLISHED -> BANK_OWNED -> BANK_FREE
```

接收 block 后先逐 frame 清零，再进入 FILLING。每个 DSP retire 最多产生一个 frame 的左右
贡献，按 `block_frame_index` 做 read-modify-write 累加。发布时只把 buffer ID 和范围交给
consumer；consumer 获取所有权后逐帧读取，最后显式 release。

两个 bank 的作用是让 consumer 持有上一 block 时，renderer 可以选择另一个 free bank。
当前实现一次仍只允许一个 bank 处于 CLEARING/FILLING，因此它不是两个 render block 的
并行累加器。accumulator 当前实现为小型寄存器阵列，post-route 层级占用约 1,041 LUT 和
1,671 FF；用 BRAM group reducer 替换它仍是候选优化，不是当前实现。

这是 generic core 提供的 ownership 能力，不代表 production wrapper 已经利用该重叠。
外部 consumer 若在上一 bank 为 `OWNED` 时提交下一 block，core 可以在另一个 free bank
填充；但当前 `voice_major_system` 要等上一 bank release 后才回到 `OUTPUT_IDLE` 并提交
下一 block。

对 512 路 PCM16，signed 25-bit published mix 精确覆盖理论和，不需要在 mix bank 内提前
饱和。后级 effects/compressor/master 最后才执行 PCM16 输出饱和。

## 13. Board 系统中的 Block 生命周期

`voice_major_system` 在 output FIFO 有至少一个 block 空间时请求固定 16-frame block：

```text
OUTPUT_IDLE
  -> request block
  -> OUTPUT_WAIT_BLOCK：等待 renderer publish
  -> OUTPUT_READ_REQUEST / OUTPUT_READ_RESPONSE：逐帧读 0..15
  -> 每个 response 必须先被 global effects chain 接受
  -> OUTPUT_RELEASE：释放 mix bank
  -> OUTPUT_IDLE：此时才允许 request 下一 block
```

effects input backpressure 会停住 mix read response，完整传播回 block owner；bank 不会在
最后一个 frame 被 effects 接受前释放。output FIFO 与 I2S 继续以 sample rate 消费，render
和播放通过 FIFO lead 解耦。

当前 wrapper 因此没有让“下一 block render”与“上一 block mix read”重叠。effects 在接收
最后一帧后仍可能有内部 token 或 compressor look-ahead 输出在途；bank release 只表示
effects 已取得全部输入，不表示 effects 输出已全部进入 FIFO。因此下一 block render 可以
与上一 block 的 effects 尾部重叠，但不能与其 mix-bank 读出阶段重叠。

这也定义了两个不同的周期指标：

```text
render latency:
  block request accepted -> block_complete accepted

production block initiation interval:
  current block request accepted -> next block request accepted
  = render latency + mix read/effects-input acceptance + release/control overhead
```

`render_latency_cycles` 只测第一个区间。评估 output FIFO 是否会 underrun 时，还必须看第二个
区间或 harness 的 render-to-effects-release latency；只用 renderer publish 时间会高估余量。

Smart Artix 上 control、renderer、effects 和 audio 都使用 MIG UI clock。DDR calibration
失败时完整系统没有可用 sample memory，因此系统选择共同 reset/clock 依赖，而不是为 control
另建 always-on clock island 和 CDC 协议。

## 14. Ready/Valid 与必须保持的不变量

所有接口只在 `valid && ready` 的上升沿 transfer。实现和修改时必须保持：

- `valid=1 && ready=0` 时 payload 稳定；
- line request 数等于外部接受数，response 严格保序且不丢失；
- 每个 required endpoint 最终只写到所属 work/job/sample bank；
- 同一 work 的 DSP issue 顺序等于 job 顺序；
- 每个 accepted active voice 恰好产生一次动态 result；
- 每个 audible job 恰好产生一次 contribution；
- block 只能在所有 voice result 被 state store 接收后发布；下一次 state read 必须等待
  generation check / RAM apply 完成；
- published/owned bank 在 release 前不得重新分配。

不要用波形“看起来连续”代替这些计数和 ownership 检查。

## 15. 当前性能与资源证据

最终 34-bit descriptor、16-frame、512-voice 配置的 2026-07-30 Smart Artix 结果：

| 指标 | post-route |
| --- | ---: |
| 全芯片 LUT / FF | 24,365 / 25,525 |
| BRAM tile / DSP | 46 / 39 |
| render core LUT / FF | 10,947 / 15,100 |
| engine LUT / FF | 8,145 / 9,491 |
| mix buffer LUT / FF | 1,041 / 1,671 |
| setup WNS / hold WHS | +0.194 ns / +0.056 ns |
| routed nets / route errors | 45,561 / 0 |

与前一版 descriptor 实现相比，整机减少 1,268 LUT、1,349 FF 和 4 BRAM tile，DSP 不变；
最差 setup path 已从 descriptor storage 转移到 compressor。

1 秒、48 kHz、512 peak voices、timed DDR3、关闭 effects 的 dry run 完成 48,000 frames，
`max_render_cycles=31,876`，zero renderer deadline miss。它距离 16-frame 的 33,333-clock
理论 deadline 已不宽裕，因此当前优化优先级仍应看完整 render latency，而不是单独追求
某一级的名义 II。

打开 production RTL effects 的一秒压力中，最大 renderer latency 为 31,905 clocks，最大
request-to-effects-release latency 为 33,228 clocks。后者更接近当前 `voice_major_system`
能够开始下一 block 的时刻，只剩 105 clocks 的 full-block 理论余量。这正是为什么后续优化
不能只报告 DSP issue rate 或 `block_complete` 时间。

## 16. 已知限制与下一步候选

当前设计有意保留以下限制：

- 固定扫描 512 voices，低复音时仍支付 state-read 成本；
- envelope frontend 只有一个 context；
- phase、memory 和 DSP issue 只看一个 modulo 候选，可能产生可避免 bubble；
- sample window client 一次只处理一个 descriptor transaction；
- response gather 每拍只写一个 endpoint；
- mix accumulator 仍是 LUT/FF 阵列；
- 单次 placement 的内部时序已闭合，但外部 SPI/I2S delay 仍未完整约束。

候选改进必须针对测得的瓶颈：

1. sample-ready FIFO，用已到齐 job 吸收 modulo issue bubble；
2. 8-voice group reducer 加 true-dual-port BRAM mix；
3. 在不恢复宽优先选择器的前提下，对 memory 或 issue 增加有限 look-ahead；
4. 只有 state scan 被证明占主要周期时，才增加 active index 或批量 state read。

任何改动都必须同时检查 bit-exact fixed-point 行为、512-voice timed-DDR3 deadline、BRAM
推断、post-route setup/hold、route status 和 DRC。post-synthesis WNS 不能代替实现签核。

## 17. 代码与验证入口

主要 RTL：

- `rtl/top/voice_major_render_core.sv`
- `rtl/control/block_voice_state_store.sv`
- `rtl/voice/voice_major_block_controller.sv`
- `rtl/voice/block_mono_voice_engine.sv`
- `rtl/voice/block_interleaved_envelope_frontend.sv`
- `rtl/voice/block_interleaved_voice_renderer.sv`
- `rtl/dsp/block_interleaved_voice_dsp.sv`
- `rtl/memory/voice_sample_window.sv`
- `rtl/voice/block_mix_buffer.sv`
- `fpga/common/rtl/voice_major_system.sv`

常用验证：

```text
make lint
make test
make test-voice-major-512
make measure-voice-major-throughput-512-ddr3
make render-rtl-ddr3
make vivado-synth
make vivado-impl
python3 tools/vivado_report_summary.py show
python3 tools/vivado_report_summary.py analyze
```

`render-rtl-ddr3` 使用 simulation timing model，不实例化 Smart Artix MIG wrapper；它用于
renderer/DDR workload 验收，不能替代板级 implementation 和真实 DDR3 验收。
