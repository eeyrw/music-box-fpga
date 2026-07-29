# 512-Voice Renderer 破坏性重构计划

## 1. 文档定位

本文是下一次 renderer 破坏性重构的实施依据，不描述当前 RTL，也不要求保持内部模块
接口兼容。外部命令字、PCM 数值、SF2 固定点行为、ordered DDR line 数据和 I2S 音频顺序
原则上保持不变。

当前 8-slot 实现必须先作为可复现基线提交。新通路只有同时通过逐位回归、真实 SF2/MIDI
压力、RTL DDR3、板级等价 memory profile、fresh synthesis 和 post-route 后才能替换它。

本文不把任何一种遍历顺序当作先验答案。结论来自四个实际约束：

1. 512 voices 的实时算术工作量；
2. phase、envelope 和 filter 的不同递归距离；
3. 32-word/voice window 与 DDR transaction 顺序；
4. xc7a50t 当前 LUT/路由紧张、BRAM/DSP 有余量的资源结构。

## 2. 已知基线

### 2.1 配置和截止时间

当前 Makefile 默认：

```text
NUM_VOICES=512
BLOCK_WORK_ENTRIES=8
MAX_BLOCK_FRAMES=8
SYS_CLK=100 MHz
SAMPLE_RATE=48 kHz
```

每个输出 sample 的平均预算与 render block 长度无关：

```text
100,000,000 / 48,000 = 2,083.33 clocks/output-frame
2,083.33 / 512 = 4.069 clocks/voice-sample
```

八 frame block 当前有：

```text
deadline = 8 * 2,083.33 = 16,666.7 clocks
work     = 512 * 8 = 4,096 voice-samples
```

因此 `II=4` 只是没有控制、DDR、fill/drain 和路由余量的理论临界点。任何方案都必须用
完整 block cycles 和 output FIFO 水位验收，不能只报告某个 DSP pipeline 的 II。

### 2.2 当前资源和时序

现有最新完整实现报告的可用基线为：

| 资源 | post-route | 器件容量 | 占用 |
| --- | ---: | ---: | ---: |
| Slice LUT | 29,984 | 32,600 | 91.98% |
| Slice FF | 28,287 | 65,200 | 43.38% |
| BRAM36 等效 tile | 44 | 75 | 58.67% |
| DSP48E1 | 39 | 120 | 32.50% |

该次 route 全部网络完成，DRC error 为 0，hold WHS 为 `+0.040 ns`，但 setup WNS 为
`-0.134 ns`。最差路径跨 envelope slot 状态选择和 renderer slot 写入。后续局部寄存修改
仍需重新实现，因此这些数字是架构估算基线，不是最终 signoff。

post-synthesis 层次的主要占用为：

| 区域 | LUT | FF | BRAM tile | DSP |
| --- | ---: | ---: | ---: | ---: |
| generic render core | 17,589 | 18,035 | 20 | 12 |
| state store | 2,355 | 1,915 | 9.5 | 0 |
| command plane | 2,106 | 1,628 | 0.5 | 0 |
| block controller + engine + mix | 13,128 | 14,463 | 9.5 | 12 |
| envelope frontend | 3,381 | 4,120 | 1 | 0 |
| renderer，含 DSP/window | 8,206 | 8,265 | 4.5 | 12 |
| renderer own control/storage | 3,367 | 6,811 | 0.5 | 0 |
| per-voice DSP pipeline | 3,142 | 1,209 | 0 | 12 |
| sample window | 1,169 | 245 | 4 | 0 |
| mix buffer | 1,140 | 867 | 0 | 0 |
| global effects | 5,302 | 3,413 | 22.5 | 27 |
| generated MIG | 5,114 | 4,146 | 0 | 0 |

层次数字包含父子层级，不能相加为全芯片总数；它们用于确定优化优先级。

### 2.3 当前真实压力证据

3 秒、512 voices、复杂 pitch bend、SGM SF2、RTL DDR3 timing model 的 A/B 结果：

| endpoint scan | 平均 block cycles | 最大 block cycles | DDR reads | deadline miss |
| --- | ---: | ---: | ---: | ---: |
| 16-way parallel | 8,464 | 11,682 | 10,392,980 | 0 |
| 1-way serial | 9,544 | 13,477 | 10,392,980 | 0 |
| 4-way grouped | 9,206 | 12,983 | 10,392,980 | 0 |

4-way 版本每块平均约 577 条 DDR line。三种实现 transaction 数完全相同，但 row-hit/miss
和最大周期不同，说明请求时序本身会改变 DDR 调度。理论 MB/s 只能做容量检查，不能替代
trace replay。

另一个必须纳入重构的事实是：仿真 timing model 有 32-entry request queue，而当前板级
`smart_artix_ddr3_line_reader` 只有 `IDLE/SEND_READ/WAIT_DATA`，一次只允许一条 MIG read
在途。仿真通过不能证明当前板级 wrapper 已利用 DDR3 并发能力。

## 3. 硬目标与非目标

### 3.1 硬目标

- 固定支持 512 voices，不以降低复音数换资源。
- 100 MHz、48 kHz 下，合格 DDR profile 的完整 render 最大占用低于可播放时间的 90%。
- 48-frame output lead 的持续压力测试无 underrun、drop 或 deadline miss。
- post-route LUT 目标 `24,000..26,000`，硬上限 26,080，即 80%。
- post-route setup/hold 均非负，所有网络完成路由，DRC error 为 0。
- generation、start/release/stop/pitch/gain/filter/envelope 语义逐位保持。
- 同一 voice 的 phase、envelope、filter state 严格按音频 frame 顺序演进。
- 首次可听输出的新增架构 latency 小于 1 ms；总目标仍小于现有几毫秒预算。
- runtime command 的额外量化等待不超过选定最大 render block，即候选 16 帧时 0.333 ms。

### 3.2 非目标

- 不做通用 CPU、微指令 ISA、NoC、reservation station 或乱序 retirement。
- 不做跨 voice sample-line CAM 或通用 MSHR。
- 不为了节省 DSP 建立共享乘法器仲裁；DSP 有余量。
- 不改变 PCM16、Q24.8 phase、Q1.15 gain、filter rounding/saturation。
- 第一版不把 memory job 跨越 control epoch；参数更新仍在 render-block 边界生效。
- 第一版不让 memory quantum、control quantum 和 output quantum 彼此独立；这种解耦需要
  timestamp、epoch 和 invalidation，收益未证明而验证面显著扩大。

## 4. 候选架构比较

| 候选 | DDR 局部性 | 递归 hazard | LUT/路由 | DDR stall 覆盖 | 结论 |
| --- | --- | --- | --- | --- | --- |
| 当前 8 个动态 slot | 好 | scoreboard + forwarding | 差 | 好 | 仅作基线 |
| 全局 frame-major | window 数据不被驱逐，但 line lookup 被拆散 | 简单 | 中 | 中 | 不采用 |
| 单 voice 从 state 一直算到 DSP 完成 | 好 | 简单 | 最低 | 差，miss 时全停 | 不采用 |
| 通用 token FIFO + MSHR | 好 | 可处理 | 中到差 | 最好 | 复杂度无证据支持 |
| 完整 voice job + 顺序 memory + 静态 DSP barrel | 好 | 固定 modulo | 低 | 好 | 推荐 |

### 4.1 为什么不采用全局 frame-major

`voice_sample_window` 是每 voice 独占 32 words，不是小型共享 cache。其他 voice 不会驱逐
当前 voice 的 window，因此全局 frame-major 不必增加 DDR transaction；但它仍有三项
明确代价：

1. 当前 renderer 先得到一个 voice 的全部 endpoint，再按 unique line 合并。逐 frame
   访问会把这一操作拆成最多 `2 * frames` 次 client lookup。
2. state/parameter BRAM 从每 voice 一次读取变成每 voice-frame 一次读取。
3. refill 后的消费被推迟 512 个 frame operation，line service 的 head-of-line 行为改变。

若重新设计一个 fully pipelined multi-port window，可以补回吞吐，但会引入更多端口、
pending state 和验证复杂度。它不是当前 LUT 紧张器件的优先解。

### 4.2 为什么不把一个 voice 串到底

phase/envelope 可以在一个 local context 中顺序算完，但 sample 必须等待 DDR。若 context
一直占住整个 renderer，一次 row miss、precharge 或 refresh 会同时停住 state frontend、
DSP 和 mix。当前 12,983-cycle 压力结果证明可变 DDR latency 必须与片内算术重叠。

因此正确边界是：在 DDR 前形成完整 voice job，然后把 job 放入有界 RAM；不是让完整
context 留在 FF slot，也不是让一条 job 阻塞全通路。

### 4.3 为什么只在 DSP 使用 barrel interleave

phase 和 envelope 的递归 next-state 可以在一个注册边界后反馈。慢的 cB-to-Q15 level
转换不反馈到 envelope state，可以作为独立流水。因此 frontend 可用单 local context，
无需八路 interleave。

biquad 不同：当前 filter state update 在 sample token 接受后约 5 拍才可用。若强行连续
处理同一 voice，会产生气泡；若做动态 slot，就回到 scoreboard。固定 8-lane barrel 以
`A0,B0,...,H0,A1,...` 顺序运行，使同 lane 间隔 8 拍，天然覆盖反馈距离。

八的依据是物理反馈 latency 至少 5、3-bit counter 简单以及 3 拍时序余量，不是因为旧
设计恰好有八个 slot。若重构后的 post-route filter feedback 大于 8 拍，应该增加 DSP
pipeline 的 early-state 输出或局部寄存，不得扩大为动态 16-slot scheduler。

## 5. 推荐总体结构

```text
command stream
    -> parser
    -> update FIFO
    -> block-boundary state-update engine
                         |
                         v
voice_id counter -> 512-depth state BRAM
                         |
                         v
single-context phase/envelope/endpoint microengine
                         |
                         v
                 16-entry voice-job RAM
                         |
                         v
       sequential line planner + per-voice window
                         |
                ordered line-descriptor FIFO
                         |
                         v
               queued Smart Artix MIG reader
                         |
                         v
                  sample-ready job FIFO
                         |
                         v
              fixed 8-lane filter/DSP barrel
                         |
               8-voice group reducer
                         |
                  BRAM block mix banks
                         |
          effects -> compressor -> output FIFO -> I2S
```

只有三个地方保存多项工作：

- 16-entry voice-job RAM，用于隔离 frontend、DDR 和 DSP；
- 固定 8 个 DSP lane，只保存 filter feedback 所需的最小 context；
- 固定深度 ordered line descriptor，用于关联 MIG response。

它们都由 head/tail 或 modulo counter 直接寻址，没有 ready-slot 搜索。

## 6. Render Block 长度选择

### 6.1 不把 8 当作合同

`MAX_BLOCK_FRAMES=8` 是当前优化选择，不是外部音频格式。下一版必须在 Phase 1 用相同
SF2/MIDI trace 比较 8、16 和 32；4 只作为短块/事件边界测试。

| 最大帧数 | block 时间 | 512-voice samples | unity-pitch endpoint span | 主要影响 |
| ---: | ---: | ---: | ---: | --- |
| 4 | 83.3 us | 2,048 | 5 words | 固定开销高 |
| 8 | 166.7 us | 4,096 | 9 words | 当前已验证基线 |
| 16 | 333.3 us | 8,192 | 17 words | 推荐候选；整除 48-frame FIFO lead |
| 32 | 666.7 us | 16,384 | 33 words | unity 已超过 32-word window，scratch 翻四倍 |

当前 SGM region 的初始 `phase_inc` 分布为：中位数 `198/256=0.773`，p90
`339/256=1.324`，p95 `483/256=1.887`，p99 `821/256=3.207`。这不是 runtime pitch
bend 的完整分布，但说明 16 帧通常仍能在一个 32-word forward window 内形成良好局部性；
32 帧即使 unity pitch 也必跨 window。

### 6.2 推荐决策

推荐以 `MAX_RENDER_FRAMES=16` 作为 RTL 候选，保留 `frame_count=1..16` 的功能支持。
选择 16 的原因：

- state snapshot、command drain、job header 和 block publish 的固定开销相对 8 减半；
- 48-frame output target 正好容纳三个完整 block；
- 最大新增 control 量化仅 0.333 ms；
- 32-word window 对主流 phase increment 仍有意义；
- 两倍 job/mix storage 可用 BRAM 吸收。

但这是有退出条件的推荐，不是未经测量的定案。Phase 1 只有在 16 相对 8 同时满足以下
条件时才能冻结为生产常量：

1. DDR lines/output-frame 不增加超过 5%；
2. 真实压力的最大 render 时间小于 30,000 clocks；
3. command/event 量化误差满足 0.333 ms 合同；
4. job RAM 和 mix RAM 的 post-synth BRAM 增量不超过 8 tiles；
5. LUT 不因更宽 mask、mux 或 accumulator 增加。

若任一项失败，保持 8；第一版不选 32。

### 6.3 短 block 的 deadline 定义

state scan 有每 voice 固定开销，所以一帧短 block 不能简单要求在 `2,083 clocks` 内遍历
512 voices。实时安全性应以 48-frame FIFO lead 和连续 rolling deadline 为准。诊断需要
同时保留：

- 单 block render cycles；
- render cycles/frame；
- minimum output lead；
- deadline miss/underrun。

满 512-voice signoff 使用完整 16-frame block。短 block 必须功能正确，并由 FIFO credit
证明不会造成 underrun；不能用不合理的按短 block 线性 deadline 误报架构失败。

## 7. 控制面和 State BRAM

### 7.1 Update record

parser 只产生紧凑记录：

```text
update_record = {
  opcode,
  voice_id,
  generation,
  field_mask,
  payload
}
```

FIFO 深度固定 16。state-update engine 在 renderer 不持有新 block snapshot 时做 2 至 8 拍
read-modify-write。START 可以用 shadow record + COMMIT，但不设计通用微指令。

命令不会直接组合驱动 render BRAM write enable。控制面等待是允许的，generation 和完整
record 的原子可见性不可放松。

### 7.2 State bank

保留当前已经成功推断的四个 512-depth 宽 BRAM：

| Bank | 当前约宽度 | 内容 |
| --- | ---: | --- |
| region | 106 bit | base/length/loop |
| event | 146 bit | phase_inc/gain/filter/released |
| envelope params | 176 bit | ADSR step/target |
| dynamic | 208 bit | active/generation/phase/env/filter state |

第一版不为了形式上的 SoA 继续拆 bank。frontend 一次读完整 snapshot，最终 DSP retire 一次
写完整 dynamic；这样不会产生 phase/env 和 filter 两个 writer 的端口冲突，也保持当前
原子 dynamic writeback。

当前单独的 `active_q[511:0]` 和 `generation_tag[511:0]` 是 dynamic state 的重复影子。
新 sequencer 固定扫描 `voice_id=0..511` 并读取 dynamic.active，因此删除 active bitmap、
group priority select 和 generation shadow。control generation 比较走多拍 dynamic read，
不要求组合查询 512x16 LUTRAM。

### 7.3 Block consistency

一个 active voice snapshot 被复制一次到 job RAM。该 block render 期间 update FIFO 不修改
state banks，所以 gain、phase_inc 和 filter coefficients 对整个 job 一致。frontend 产生的
final phase/env state、初始 filter state 和 generation 都随 job 保存；DSP 最后合并并写回。

这份 job context 是为了跨 DDR variable latency 保存一致快照，物理上位于 RAM；它不是
多个 FF slot，也不经过全局宽 mux。

## 8. Single-Context Frontend

### 8.1 Voice scan

sequencer 使用一个 9-bit counter 顺序读取 512 voices，不检查 active bitmap。读取延迟
固定，inactive snapshot 直接跳过；active snapshot 只有在 job ring 有空 entry 时才进入
local context。

第一版只保留一个 local context，不做宽 snapshot FIFO。可在 level pipeline drain 时预读
下一个 voice，但只有周期模型证明这一项影响最大 block cycles 才增加一个单 entry skid。

### 8.2 每 frame 两拍

对一个 active voice 的 `frame=0..frame_count-1` 使用固定 microsequence：

```text
ENV  : 从 local env state 计算 next env、active、render、phase_advance
PHASE: 根据 local phase 和 phase_advance 计算 addr0/addr1/fraction/next phase
```

ENV 沿写回 local env state；PHASE 沿写回 local phase，并向 job frame RAM 写一条：

```text
frame_job = {
  render,
  addr0,
  addr1,
  fraction,
  envelope_level_tag
}
```

cB-to-Q15 conversion 是独立 registered pipeline。它接受 ENV 结果及 `{job_id, frame}`，
数拍后写 job RAM 的 level 字段；它不反馈到 envelope state。release-during-attack 的 level
初始化允许额外固定拍，但不得恢复 per-slot state machine。

### 8.3 周期上限

以 16 frames 估计：

| 操作 | 上限 |
| --- | ---: |
| snapshot request/capture | 3 clocks |
| 16 次 ENV/PHASE | 32 clocks |
| level pipeline 最后 drain | 4 clocks |
| job publish / next voice | 1 clock |
| active voice 总计 | 40 clocks |

全 512 active 的 frontend 上限约 `20,480 clocks`，低于 16-frame 的 33,333-clock 可播放
时间。memory 和 DSP 在前几个 job 发布后并行运行，所以该数字不与其他 stage 直接相加。

如果 post-route 证明 ENV 或 PHASE 仍是最差路径，允许各自再拆一级并把 active voice 上限
提高到 48 clocks；超过 48 必须重新做完整 rolling-deadline 模型，不能继续无界串行化。

## 9. 16-Entry Voice-Job Ring

### 9.1 为什么是 16

variable DDR latency 需要多个 voice job 在途。删除并发只会把 DDR stall 传播到 frontend。
16 entries 允许 memory 等待一组 job 时 frontend 继续，并允许 DSP 固定装入八个 lane 后
memory 填下一组。它是两个 8-job 工作集的容量，不是 16 个动态 scheduler slot。

Phase 1 必须同时模拟深度 8 和 16。若 8 在所有 trace 下的 frontend stall 和 DSP starvation
与 16 相同，生产值可以降为 8；不得增加到 32，除非 16 的 occupancy histogram 明确满载。

### 9.2 逻辑布局

以 16-frame 候选估算：

| RAM | 逻辑形状 | 约 bit 数 | 访问 |
| --- | ---: | ---: | --- |
| job header/context | 16 x 约 350 | 5.6 Kbit | frontend write，DSP/final writeback read |
| frame job | 256 x 约 84 | 21.5 Kbit | frontend write，memory/DSP read |
| sample pair | 256 x 32 | 8.2 Kbit | memory write，DSP read |
| valid/pending/count | 16 x 小于 64 | 小于 1 Kbit | 各 owner pointer |

实际 RAMB packing 可能为 3 至 6 个 BRAM36 tile。endpoint 地址不得展开成
`16 entries x 32 endpoints` 的异步宽读矩阵。frame job 按 `{job_id, frame}` 存储，一次
同步读一个 frame 的两个连续 endpoint。

### 9.3 Ownership

job 只按以下单向顺序移动：

```text
FREE -> FRONTEND -> MEMORY -> DSP_READY -> DSP -> WRITEBACK -> FREE
```

每个边界使用 head/tail 或 job-ID FIFO。任何 engine 都只能访问自己持有的 ID；不扫描
16 个 owner state，不做 round-robin candidate select。所有 FIFO payload 只有 job ID。

DSP retirement 必须保持 job 顺序，因此 ring entry 可以按序释放。若实现发现需要乱序
释放，说明 memory/DSP 合同已经偏离本计划，应停止而不是增加 reorder buffer。

## 10. Memory 和 Window

### 10.1 以完整 job 为输入

memory planner 锁定一个 job 后按 frame 顺序读取 `addr0/addr1`。两个 endpoint 始终是
连续 sample word，通常落在同一 8-word line，line 边界时才分为两条。

planner 使用一组窄寄存器：

```text
job_id
frame_index
endpoint_select
current_line
run_start
run_count
pending_line_count
```

它顺序形成连续 endpoint run，不保存 16/32-bit endpoint mask，也不把所有地址送入并行
比较器。loop wrap 或高 phase_inc 只会结束当前 run 并开始下一 line；同一 line 以后再次
出现可以形成第二个 descriptor，正确性不依赖地址单调。

一拍一个 frame-pair 的 scanner 对 16-frame job 最多读 16 次 frame RAM。当前 1-way
endpoint 实测在更紧的 8-frame deadline 下仍以 13,477 clocks 通过，因此 serial scan 是
LUT 优先方案。只有 trace 证明 scanner 而不是 DDR wait 成为瓶颈时，才升级为固定 2-way；
不恢复 16/32-way 比较。

### 10.2 32-word per-voice window

window 容量保持 32 words/voice：

```text
512 voices * 32 words * 16 bit = 262,144 bit
```

数据 RAM 是 2,048 条 128-bit line；其他 voice 不能驱逐该空间。window base/meta 也必须
保持 512-depth BRAM，不回退为 FF。

实现分两步：

1. compatibility mode 保持当前语义：block 的第一条 window miss refill 四条连续 line，
   后续 window 外 line fallback，不替换 window。先证明 sample、transaction 和状态一致。
2. trace model 再评估 4-bit sector-valid meta。sector 模式只读取当前 job 真正需要的 line，
   可选最多一条顺序 lookahead；它不增加容量，不做 associativity，也不跨 voice merge。

sector 模式只有在真实压力中同时降低 DDR reads 和最大 block cycles 时才进入生产。不能因
平均带宽下降但 p99/max 变差而采用。64-word/voice window 不作为第一版：它会额外使用约
7 BRAM tiles，并可能把冷 miss refill 流量翻倍。

### 10.3 Ordered line descriptor

每条外部 read 都伴随窄 descriptor：

```text
line_desc = {
  job_id,
  voice_id,
  line_addr,
  run_start,
  run_count,
  window_write,
  window_offset
}
```

request 和 response 严格有序，所以 descriptor FIFO 的 head 就是当前 response 的归属。
不需要 associative tag search。返回 line 由 gather FSM 顺序写 sample-pair RAM；允许对
board response 施加 backpressure，任何无 backpressure 边界前必须有至少一条 line skid。

descriptor depth 候选为 8，最大允许 16。选择依据是 MIG `app_rdy`、read-data latency、
FIFO occupancy 和 max block cycles，不以“更多一定更快”为依据。

### 10.4 修复板级单 outstanding reader

当前 Smart Artix line reader 必须改成 request FIFO + issued counter：

- `line_req_ready` 由 request FIFO 空位决定，不由 `WAIT_DATA` 决定；
- MIG `app_en/app_cmd/app_addr` 在 `app_rdy` 时连续发出 queued read；
- read data 按命令顺序返回并逐条产生 ordered line response；
- outstanding 不超过选定固定深度；
- reset、MIG calibration loss 和 arbiter ownership 必须清空/阻止半 transaction。

这只是 ordered pipeline，不是乱序 memory controller。RTL DDR3 model 的 request queue
depth 必须设置为同样的 1/4/8/16 做 A/B；最终报告不能继续只使用 32-depth model。

## 11. Filter/DSP Barrel

### 11.1 Lane 装载

DSP 从 `DSP_READY` FIFO 按序装载最多八个 job ID。少于八个时其余 lane invalid。每个 lane
只保存：

```text
valid, job_id, voice_id, frame_index, z1, z2
```

gain 和 filter coefficients 可以在 lane 装载时从 job header 读入一个 8-deep compact
bank。不得把完整 header 复制穿过每个 DSP stage。

### 11.2 固定 schedule

issue counter 固定产生：

```text
A0 B0 C0 D0 E0 F0 G0 H0
A1 B1 C1 D1 E1 F1 G1 H1
...
```

invalid lane 发 bubble。没有 ready 搜索、hazard bit 或 tag compare。state update 按 pipeline
中携带的 3-bit lane ID 写回对应 z1/z2；同 lane 下一次 issue 距离八拍。

### 11.3 DSP stage payload

当前 pipeline 每级携带完整 `block_voice_context_t`。新 pipeline 按使用位置携带字段：

- interpolation stage：sample pair、fraction、lane/job/frame ID；
- feed-forward stage：`b0/b1/b2`；
- feedback stage：`a1/a2` 和 lane z state；
- gain stage：`gain_l/gain_r`、envelope level；
- retire：voice/generation/frame contribution。

字段可从 lane compact bank 在 issue 时读出并按最短必要距离流水。若单个 8-deep bank 的
多读口导致复制，优先把 `b*`、`a*`、gain 分成三个窄 bank；不回到完整 context 广播。

DSP 数量不设节省目标。允许使用额外 DSP input/output register，甚至增加少量 DSP48，
换取 LUT 和 post-route timing。所有 arithmetic 顺序、舍入和 saturation 必须逐位一致。

### 11.4 Partial group 和尾部

一个 DSP group 最多八 voice。frame_count 对整个 render block 相同。最后不足八个 voice
仍运行完整 lane round，invalid lane bubble；额外开销最多 `7 * frame_count` clocks，远小于
低 active-count 时的空闲预算。

frame 末尾 state update 和 retire 必须完成后才能释放 lane/job。最后一个 group drain 是
显式固定周期，不使用 COMPLETE slot 搜索。

## 12. BRAM Mix Accumulator

固定 DSP 顺序使同一 output frame 的最多八个 voice contribution 连续出现。mix 不再每个
contribution 对 16 个 FF accumulator 做随机选择，而是：

1. group 的第一个 valid lane 读取该 frame 的旧 BRAM accumulator；
2. 八个 lane contribution 在 local 32-bit L/R group sum 中累加；
3. 最后一个 lane 把 `old + group_sum` 写回；
4. 第一 voice group 忽略旧值，直接写 group sum，因此无需逐 frame clear FSM。

两个 published/fill bank 与 frame index 一起编码进一块或两块 true-dual-port BRAM：fill
使用 A 口，effects/output drain 使用 B 口。16 frames 的逻辑容量只有约 2 Kbit，但用 BRAM
换掉当前约 1,140 LUT/867 FF 和 clear/select 网络是符合本器件资源结构的。

group reducer 必须保持 32-bit accumulation 和最终 signed-25 边界。invalid lane、voice
deactivate 和 generation reject 不得改变 frame 对应关系。

## 13. Effects 和其他全局优化

renderer 重构不是唯一 LUT 来源。当前 effects 约 5,302 LUT，且每 stereo sample 有：

```text
100,000,000 / 48,000 = 2,083 clocks
```

策略为：

- 保留 chorus/reverb/compressor 各自的 DSP，不跨效果共享；
- compressor 的搜索/控制允许固定多拍；
- chorus/reverb 只在 hierarchy report 指出具体宽控制/多端口逻辑时串行化；
- 乘法、MAC 和宽加法优先放 DSP48，不为了保持 39 DSP 而消耗 LUT；
- 每个效果最坏处理小于 1,500 clocks/sample，保留至少 25% 余量。

command plane 的宽 start decode 也应在 update-record 边界注册。SD/MIG generated logic 不在
generic core 重写，但 board line reader 和 arbiter 必须按本计划验证真实吞吐。

## 14. 吞吐和延迟预算

以 16-frame 候选、512 active voices 为例：

| Engine | 估计工作量 | 硬上限/目标 |
| --- | ---: | ---: |
| frontend | 约 40 clocks/voice | <=20,480 clocks/block |
| frame-job serial scan | 16 reads/voice，和 DDR wait 重叠 | 不单独相加 |
| DSP barrel | 8,192 valid issues + fill/drain | <8,400 clocks/block |
| group mix | 包含在 DSP retire | 不降低 DSP issue rate |
| effects | 16 samples | 与下一 render block/output drain 重叠 |
| 可播放时间 | 16 / 48 kHz | 33,333 clocks |
| 完整 render 验收 | trace dependent | <30,000 clocks |

stage 通过 job ring 并行，完整 latency 近似：

```text
pipeline fill + max(frontend service, memory service, DSP service) + tail drain
```

而不是三项求和。周期模型必须输出：

- frontend blocked by full job ring；
- memory planner idle / descriptor-full / response wait；
- DSP starvation / invalid-lane bubble；
- job-ring occupancy histogram；
- line outstanding histogram；
- p50/p95/p99/max render cycles；
- minimum output FIFO lead。

首次 block 即使接近 30,000 clocks 也只有 0.3 ms；现有 compressor lookahead 和 output FIFO
各约 1 ms，因此该重构不会突破几毫秒首次输出约束。

## 15. 初步资源预算

以下是架构估算，不是综合结果：

| 变化 | LUT 估计 | FF 估计 | BRAM tile |
| --- | ---: | ---: | ---: |
| 删除 envelope 8-slot context/search | -1,400..-2,000 | -2,500..-3,500 | 0..-1 |
| 删除 renderer work-state/ready/hazard search | -1,200..-1,900 | -2,000..-3,000 | 0 |
| single-context frontend + job/ring control | +500..+900 | +500..+900 | +3..+6 |
| slim DSP context + static lane select | -300..-700 | -200..-500 | 0..+1 |
| BRAM group mix | -600..-900 | -500..-800 | +1 |
| active/generation shadow removal | -300..-700 | -300..-600 | 0 |
| ordered line queues / board reader | +150..+400 | +100..+300 | 0..+1 |
| effects/control 后续定点优化 | -300..-800 | 不定 | 0..+2 |

相对约 29,984 post-route LUT，净目标为减少约 4,000 至 5,500，得到：

| 资源 | 目标区间 | 验收 |
| --- | ---: | --- |
| Slice LUT | 24,000..26,000 | 必须 <=26,080 |
| Slice FF | 21,500..25,500 | 无硬上限，关注控制集/布线 |
| BRAM36 tile | 48..56 | 目标 <60，允许用 BRAM 换 LUT |
| DSP48E1 | 39..60 | 不作为节省指标 |

若第一版 LUT 高于 26,080，按 hierarchy report 查找残留宽 mux、未推断 RAM 和 reset fanout；
不得通过减少 voices、缩小 window 或降低数值精度达标。

## 16. 时序设计规则

- 所有 BRAM 使用同步读，输出后允许一级寄存。
- frontend ENV、PHASE、level conversion 是独立寄存边界，不组成长组合链。
- job RAM 只由 owner pointer 寻址，不从多个候选 ID 做宽 mux。
- line planner 的每拍地址比较固定为两个 endpoint 或更少。
- DSP lane 由 modulo counter 直接索引，不做 priority encoder。
- mix BRAM 的 read/group-reduce/write 明确定义 RAW forwarding；不依赖 RAM 模式猜测。
- 宽 valid/reset 不清空 payload RAM；reset 只清 owner pointers、valid bits 和 metadata init。
- 不使用 multicycle timing exception 掩盖实际单拍逻辑；多拍必须由 FSM/register 实现。

每个 phase 都要记录 post-synth hierarchy、WNS 和 RAM inference。最终只接受 post-route
setup/hold、route status 和 DRC，不以 positive synth WNS 代替。

## 17. 验证计划

### 17.1 算法逐位回归

- reset、inactive、start/commit isolation；
- phase Q24.8、fractional increment、loop boundary、one-subtraction wrap；
- mono endpoint、positive/negative PCM extremes；
- envelope Delay/Attack/Hold/Decay/Sustain/Release 和 release-during-attack；
- filter enable/disable、z1/z2 recursion、rounding/saturation；
- gain/envelope Q1.15、signed-25 mix；
- generation stale start/update/writeback；
- variable frame_count `1, 2, 7, 8, 15, 16`；
- ready/valid stall at every new boundary。

### 17.2 Static schedule assertions

- frontend 同一 job 的 frame index 严格递增；
- job ownership 只沿规定方向移动；
- 任一 job 只 publish、writeback 和 free 一次；
- DSP 同 lane 相邻 issue 间隔至少 8；
- state update 的 lane/job/generation 一致；
- line request 数等于 descriptor push，response 数等于 descriptor pop；
- block publish 前所有 accepted active voice 已 writeback；
- mix 每个 `{voice, frame}` 恰好贡献一次。

### 17.3 Memory A/B

同一 endpoint trace 比较：

- block length 8/16/32；
- compatibility window 与 sector-valid window；
- serial/2-way scanner；
- outstanding depth 1/4/8/16；
- client lookup、DDR reads、refill/fallback、useful words；
- DDR row hit/miss、activate/precharge/refresh；
- average/p99/max block cycles。

要求使用两种 memory profile：

1. simulation DDR timing model，queue depth 与硬件候选一致；
2. board-line-reader 等价 profile，包含 MIG `app_rdy`、read-data latency 和 single-rank
   refresh 行为。

### 17.4 系统压力

- `NUM_VOICES=512`、所有 filter enabled 的 directed throughput；
- SGM SF2 + 复杂 pitch bend stress MIDI，至少 3 秒；
- `DETAILED_DIAGNOSTICS=0`，使用硬件计数器/summary；
- 与当前基线 WAV byte-identical；
- zero stale dynamic corruption、zero deadline miss、zero underrun/drop；
- 记录 minimum FIFO lead、最大 render cycles 和所有 DDR/window 统计。

最终运行 `make lint`、`make test`、fresh Vivado synthesis 和完整 implementation。

## 18. 分阶段实施和退出条件

### Phase 0：冻结当前基线

- 完成当前局部优化的 lint/test/3 秒 stress/fresh implementation。
- 提交 RTL、WAV hash、JSON summary、resource/timing/route/DRC 文档。

退出：干净 worktree 可复现，不把未闭合 RTL 混入重构。

### Phase 1：只做 trace 和周期模型

- 给现有 RTL 导出 endpoint/job/line 和 stage occupancy trace。
- 建立独立 scheduler model，不修改 production top。
- 比较 block 8/16/32、job depth 8/16、outstanding 1/4/8/16。
- 冻结 `MAX_RENDER_FRAMES`、job depth、line depth 和 window policy。

退出：推荐参数满足第 6.2 节全部条件；否则明确保持 8-frame compatibility。

### Phase 2：控制面和 state access

- parser -> update FIFO -> 多拍 state-update engine。
- 固定 voice scan，删除 active bitmap/group priority/generation shadow。
- 旧 renderer 仍作为 consumer，先验证命令语义。

退出：所有 command TB 逐位通过；command-to-BRAM 长组合路径消失。

### Phase 3：single-context frontend + job RAM

- 实现 snapshot local context、ENV/PHASE 两拍 microsequence 和 tagged level pipeline。
- 实现选定深度 job ring，memory/DSP 暂用 test sink。
- 新旧 frontend 比较 endpoint、level 和 final dynamic state。

退出：512 voices、所有 frame_count、loop/release/pitch case 逐位一致；job payload 全部推断
为预期 BRAM/LUTRAM；frontend 最大周期符合预算。

### Phase 4：memory/window + queued board reader

- 接入 serial line planner、ordered descriptor、sample RAM 和 compatibility window。
- 改造 Smart Artix line reader 支持选定有序 outstanding depth。
- 在相同 depth 的 RTL DDR model 下逐 transaction 比较。
- compatibility 通过后，只有 Phase 1 已选择 sector policy 才启用 sector-valid。

退出：DDR/request accounting 精确，真实 trace 最大 render 投影小于预算，无 unordered
response 或 sample association 错误。

### Phase 5：DSP barrel + BRAM mix

- 接入固定 8-lane DSP，删除 hazard search/forward compare。
- 缩短 DSP stage payload。
- 接入 group reducer 和 ping-pong BRAM mix。
- 新旧 renderer 逐 block/WAV 比较。

退出：DSP valid issue 达到预算，filter state 逐位一致，512-voice RTL DDR stress 无 miss。

### Phase 6：effects 和 timing closure

- 只按 hierarchy/timing 报告继续处理 effects/control LUT。
- fresh synthesis 后完整 place/route。
- 若 LUT 或 timing 不达标，回到具体 hierarchy/path，不增加 scheduler 泛化。

退出：LUT <=80%，setup/hold clean，fully routed，DRC error 0，系统压力通过。

### Phase 7：切换和清理

- production top 切换到新通路。
- 删除旧 slot scheduler 和只服务旧接口的类型/TB。
- 更新 system design、详细 pipeline、memory、verification 和 board 文档。

## 19. 防止过度设计的硬规则

1. frontend 只有一个 voice context；没有证据不增加第二个。
2. DSP 固定八 lane；没有动态 ready search。
3. job ring 最大 16；没有 occupancy 证据不增到 32。
4. line descriptor 最大 16；response 严格有序。
5. 不做跨 voice merge、CAM、通用 MSHR 或 reorder buffer。
6. window 第一版保持 32 words/voice；64-word 只允许作为独立测量实验。
7. block length 是 compile-time constant，不做 runtime 多模式硬件。
8. control update engine 只实现现有 opcode，不做微指令 ISA。
9. effects 不跨模块共享 DSP。
10. 每个新模块必须替代旧模块或有独立、量化的资源/吞吐收益。

## 20. 当前推荐参数

在 Phase 1 数据推翻它们之前，下一次重构按以下候选开始建模：

```text
NUM_VOICES             = 512
MAX_RENDER_FRAMES      = 16
FRONTEND_CONTEXTS      = 1
FRONTEND_CLOCKS/FRAME  = 2
JOB_RING_DEPTH         = 16
ENDPOINT_SCAN_WIDTH    = 1 frame pair/clock
WINDOW_WORDS/VOICE     = 32
WINDOW_POLICY          = compatibility first, sector-valid only after A/B
DSP_BARREL_LANES       = 8
LINE_OUTSTANDING_DEPTH = 8, compare against 1/4/16
MIX_STORAGE            = ping-pong BRAM + 8-voice group reducer
```

最关键的评审点不是“voice-major 还是 frame-major”，而是确认以下分层选择：frontend 对
一个 voice 顺序生成完整 block；memory 只看完整 voice job；DSP 在局部固定八路中做
frame interleave。这个组合分别匹配 state amortization、DDR locality 和 filter feedback，
避免用一种全局遍历顺序勉强解决三个不同问题。
