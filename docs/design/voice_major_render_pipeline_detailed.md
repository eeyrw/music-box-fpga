# Voice-Major 渲染流水线详细设计

Updated: 2026-07-28

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

Initiation interval，简称 II，是流水线连续接受两条新工作的最小间隔。DSP 算术流水线
本身支持 `II=1`，但当前 I0/I1 issue 前端为缩短 8 路宽选择路径而非重叠执行，所以系统
sample token 的最小间隔是 2 clocks。II 不代表输入 token 当拍就输出。

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
    |       +-- mono_phase_frame x1
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
- 一套 phase combinational datapath和单独的 final-check 调度拍；
- 一个两级选择的外部 line request engine；
- 一套 interpolation/filter/gain DSP pipeline；
- 一个 contribution retire 端口。

为什么不是 2 个 slot：filtered sample 发射后，要等新的 `z1/z2` 从 DSP 中段返回。
两条上下文很快都会等待反馈，DSP 会出现空拍。8 个独立上下文超过当前约五拍的反馈
距离，round-robin 调度可以在 A 等待时发射 B、C、D、E、F 的 sample。

为什么暂时不是更多：增加 slot 会线性增加 descriptor、job、sample scratch 和选择器，
当前两级 issue 已成为吞吐下限；增加 slot 不会改变其 2-clock interval，反而会线性增加
浅状态和选择器。256/512 deadline 仍通过，所以继续增加 slot 没有证据支持。

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

四组 memory 各自只有一个 canonical synchronous read port 和一个统一 write port。snapshot
read 与 control-event read 共用读地址选择，install、parameter、control apply 和 dynamic
write 在 memory 外先仲裁成单一写使能/地址/数据。memory payload 不做整阵列 reset，
`active_q`、generation 检查和 response valid 承担初始化与可见性语义。这一写法用于让
Vivado 能把大数组映射到 BRAM，而不是因异步读、多写口或 bulk reset 展开成 FF/LUT。

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
                    \
                     -> SLOT_RELEASE_VALUE -> SLOT_RELEASE_APPLY -> SLOT_WALK
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

runtime `released` 第一次置位时，frontend 在当前输出 frame 进入 `ENV_RELEASE`。
release step 为 0 表示立即静音。若 release 发生在 ATTACK，先用生成的
Q1.15-to-Q12.20 LUT 把当前 attack level 转为 attenuation，再执行第一步 release，避免
电平跳回 full scale。

ATTACK 到 RELEASE 的转换不放在一个组合周期内完成。`SLOT_WALK` 先做 leading-zero
priority encode，并把 `{slot, level flags, octave, mantissa index}` 锁进 tagged
`release_q`。下一拍由 `release_q` 完成 octave/mantissa LUT 近似并写该 slot 的基准
attenuation，slot 从 `SLOT_RELEASE_VALUE` 进入 `SLOT_RELEASE_APPLY`；它不再重新经过
8-slot arbiter 或浅分布式 RAM。slot 回到 `SLOT_WALK` 后，普通 `ENV_RELEASE` 路径累加
第一步 release step，所以数值和原实现逐 frame 一致，但 priority encoder、LUT/add 和
release add 之间均有寄存边界。

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
  -> WORK_PLAN_FINAL
  -> WORK_MEM_WAIT
  -> WORK_MEM_FETCH
  -> WORK_READY
  -> WORK_DRAIN
  -> WORK_COMPLETE
  -> WORK_FREE
```

这些状态描述的是 slot 当前需要哪种共享资源：

- `WORK_PLAN`：round-robin phase planner 仍要为 frame 生成 endpoint job。
- `WORK_PLAN_FINAL`：使用已经寄存的最终 phase 做一次 done 检查并形成 phase result。
- `WORK_MEM_WAIT`：有尚未覆盖的 endpoint，等待 memory engine 选中。
- `WORK_MEM_FETCH`：已有 line 请求在途或继续选择缺失 line；已到数据仍可提前发 DSP。
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

`mono_phase_frame` 是组合逻辑，renderer 只保留一个实例。普通 `WORK_PLAN` 访问生成
当前 endpoint 和 `next_phase`；最后一步先进入 `WORK_PLAN_FINAL`，下一次 planner 访问
同一 slot 时再用已寄存 phase 检查 done 并形成最终 `active/phase/frames_walked`。这样避免
在同一拍串接两份 loop/end 比较和 phase arithmetic。

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

## 11. Memory：per-voice 连续样本窗口

### 11.1 外部接口

renderer 与 `voice_sample_window` 之间使用带 work ID、voice ID 和 refill 属性的内部
line 接口：

- request 包含 8-word 对齐地址、work ID、voice ID，以及它是否是当前 work 的第一次访问；
- response 返回地址、work ID 和 8 个连续 PCM16 word；
- 不要求不同 work 的内部 response 保持 request 顺序。

window 面向板级 DDR 的接口仍是 ordered line memory：

- request payload 只有 `aligned_line_addr`；
- 每个 response 返回 8 个连续 16-bit word；
- response 必须严格按已接受 request 的顺序返回；
- response 没有 transaction ID；

板级 DDR adapter 必须把 DDR/MIG 的 burst、重排和时钟域细节隐藏在这个接口后。
window 同一时刻只维护一个事务，因此用 refill 内的 request/response line counter 关联
无 tag DDR response；一次 refill 的四条请求可以连续进入 MIG 队列。

### 11.2 按实际 endpoint 请求 line

memory scheduler 分两级工作。第一级只在每个 `WORK_MEM_WAIT/WORK_MEM_FETCH` slot 的
compact required/valid/pending bitmap 上选 work ID；第二级在已寄存的 work ID 内扫描
endpoint，并选择一条尚未 valid 且未 pending 的 8-word line：

```text
line_addr = floor(endpoint_addr / 8) * 8
```

同一 work 中落在该 line 的 endpoint 一次标记为 pending。renderer 本身只按实际 endpoint
请求 line；第一次 window miss 可能由 window 层顺序预取 32 samples。memory scheduler
不会因 refill 锁定某个 work，其他已就绪 work 的 DSP issue 仍可继续，但当前 window
模块一次只接受一个 client line transaction。

两级之间允许一拍选择延迟，目的是切断“8 个 work x 16 个 endpoint x 地址比较”的大
组合选择器。`work_endpoint_required_q` 在 phase planning 时按 job 置位；判断全部 endpoint
ready 只做 `required & ~valid` 的 reduction，不再逐 job 重新展开 mask 和范围比较。

### 11.3 Per-voice 连续样本窗口

生产路径已经用 `voice_sample_window` 替换通用 2-way cache。256 个 voice 各保留一个
32-sample 连续窗口；sample data 总计 8192 x 16 bit = 16 KiB，按 1024 条 128-bit line
组织为同步 BRAM。每 voice 的元数据只有 `valid + aligned_base_line`，不存在 set index、
tag compare、LRU、MSHR waiter bitmap 或多 MSHR response service mux。

renderer 在 work 开始时清 `work_window_checked_q`。该 work 第一次接受 memory request
时携带 `refill=1`，随后置 checked：

- 地址已在该 voice 的持久窗口内：同步 BRAM read，返回对应 8-word line；
- 第一次访问越界：把请求地址作为新窗口 base，连续发四条 DDR line 并写满 32 samples；
- 同一 work 后续访问越界：只做一条 fallback DDR read，不替换持久窗口。

最后一条规则保护 loop wrap：接近 `loop_end` 的主访问可以保留顺序窗口，跳回
`loop_start` 的第二插值 endpoint 不会触发整窗替换。模块的 response register 支持
backpressure；refill 期间只服务一个 client transaction，但四条 DDR request 可连续发出。
该串行边界显著简化 association 状态，实际 256-voice 压力 trace 仍远低于 block deadline。

client request 接收后先锁存 address、work tag、voice ID 和 refill 属性，下一拍才读取
该 voice 的 window metadata 并判定 hit/miss。这个 `IDLE -> LOOKUP` 寄存边界增加每次
client line request 1 cycle，但切断了 renderer endpoint 选择到 window refill counter 的
长组合路径；Vivado 结果见 20.4。

### 11.4 Endpoint scoreboard 与 DSP 重叠

带 tag 的 window response 与对应 work 的 pending endpoint 地址比较，匹配者写入：

```text
work_endpoint_sample_q[work_id][endpoint]
work_endpoint_valid_q[work_id][endpoint] = 1
```

如果一个 endpoint 地址重复出现于多个 frame，一条 response 可以同时满足多个 valid
bit。slot 处于 `WORK_MEM_FETCH` 时不必等全部 line 返回；如果下一个待发 job 的两个
endpoint valid 已经为 1，它可以立刻参加 DSP issue。这使 response、后续 line fetch
和 DSP 对不同工作重叠。

## 12. DSP issue scoreboard 和 RAW hazard

issue scheduler 由 `issue_rr_q` round-robin 扫描 8 个 slot。一个 slot 可发射当且仅当：

```text
state is WORK_MEM_FETCH or WORK_READY
&& issue_index < job_count
&& 当前 job 所需 endpoint 全部 valid
&& (!hazard || same-cycle state_update for this work_id)
&& issue-select register 为空
```

scheduler 不直接驱动 DSP 的宽 payload。I0 的 `issue_select_capture` 只锁存
`work_id/job_index`；I1 下一拍用已寄存 ID 读取该 slot 的 context、job 和 sample scratch，
在 elastic token register 可写时产生 `issue_capture`。issue index、last 状态和 filtered
hazard 在 I1 更新，DSP 再通过自己的 ready/valid 接收 token。

I0 和 I1 当前不重叠，因此 issue 前端峰值是每两拍一个 token。这个取舍把 8 路
round-robin、endpoint/hazard 判定与宽 payload mux 分隔开，避免 Vivado 跨层优化后形成
`work_issue_index_q -> DSP48 B` 的 11-level 路径。256/512 voice 的 deadline 回归仍有
足够余量，所以这里优先保证 100 MHz 时序和降低 LUT，而不是保留没有系统必要性的
sample `II=1`。

filtered token 被 `issue_capture` 锁存后，该 slot 的 `work_hazard_q` 置 1。其他 slot 不受影响。DSP
产生相同 work ID 的 `state_update_valid` 时，把新 `z1/z2` 写入 slot 并清 hazard。

如果 A 的 state update 正在返回，I0 可以同拍再次选择 A；该上升沿先写回 A 的
`work_z1_q/work_z2_q`，I1 下一拍读取更新后的状态。I1 仍保留 state-update forwarding
mux，覆盖恰好同拍出现 update 的情况。

一个示意调度序列：

```text
cycle 0: select A0
cycle 1: capture A0, A.hazard=1
cycle 2: select B0
cycle 3: capture B0, B.hazard=1
cycle 4: select C0
cycle 5: capture C0
...
```

这与 CPU 的 scoreboard 加 bypass/forwarding 是同一类方法。区别在于 FPGA 这里没有
通用指令、寄存器重命名和乱序提交；tag 只标识 8 个固定硬件上下文，资源成本更低且
音频顺序更容易证明。

filter bypass 不产生递归状态依赖，因此 bypass token 不设置 hazard。同一 slot 可以在
下一个 I0 选择机会再次被选中，但 round-robin 公平性仍允许其他 ready slot 使用 DSP。

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

DSP 各级 payload register 和 retire payload 不做同步 reset，只 reset `valid_q` 与
`retire_count_q`。renderer 和 envelope 同样只 reset slot state、scoreboard/valid、RR
pointer 等控制状态，宽 payload 在 start 或有效 transfer 时覆盖。无效 payload 不会被
消费；减少 bulk reset 能降低复位扇出，并避免阻碍 RAM/SRL/DSP 周边寄存器优化。

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

DSP 的 retire 端使用 2-entry FIFO，pipeline advance 只依赖寄存的 occupancy：

```text
advance = (retire_count_q != 2)
token_ready = advance
```

正常每拍 pop/push 时 FIFO occupancy 保持 1，稳态仍为 `II=1`。mix buffer 短暂阻塞时
FIFO 可吸收两个 retire；只有 occupancy 已为 2 时，下一拍 `advance=0`，所有 valid bits
和 stage payload 才整体保持。`retire_ready` 不再组合穿透到 `state_update_valid`、
`token_ready` 或 DSP 输入 mux，代价是 FIFO 满后即使本拍下游恢复，也先 drain 一项，
下一拍才恢复 pipeline。该固定边界避免一个长 ready path 跨过 mix、DSP 和 renderer。

renderer 的 retire ready 还要求：

- mix contribution port ready；
- 若当前 token 是 last，result register 必须空闲或同拍被消费。

因此最后一个 contribution 和最终 dynamic result 在逻辑上同拍完成，不会出现 mix 已
接收 last sample、但 final state 被丢失的情况。

memory request 和 response 分别遵循 ready/valid。外部 ordered response 无 tag，window
一次只维护一个 refill 或 fallback transaction，并用 request/response line counter 关联
返回；window 到 renderer 的 response 保留锁存的 work ID。renderer 的其他 work 可以继续
phase planning 或 DSP issue，但新的 client line request 要等当前 window transaction 完成。

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

## 19. 整条流水线的运行时模拟

本节不再只画概念框图，而是用可以逐拍对照 RTL 的方式模拟一次运行。先定义时钟记法，
再分别模拟每个局部流水，最后把它们叠加成整机稳态。局部表中的拍序按当前 RTL 精确
描述；最后的全局叠加表用于说明并行关系，不承诺某个真实 block 中 voice 字母固定落在
该列，因为 ready/valid 和 round-robin 会随地址、envelope 和 stall 改变选择。

### 19.1 给所有环节统一编号

为了避免“frontend”“DSP 中段”这类模糊说法，本文给运行环节使用以下名字：

| 编号 | RTL 所有者 | 每拍最多完成的工作 | 主要持久状态 |
| --- | --- | --- | --- |
| B0 | `block_mix_buffer` | 接受一个 block request | fill bank、frame count |
| B1 | `block_mix_buffer` | 清零一个 mix frame | clear index、32-bit accumulators |
| C0 | controller | 选择一个非空 32-voice group | group bitmap |
| C1 | controller | 从 group 选择一条 voice | active bitmap、voice ID |
| C2 | state store | 接受一个 snapshot read request并发起同步 RAM read | read voice、capture pending |
| C3 | state store | 锁存四组 RAM read data并产生 response | response register |
| C4 | controller | 接收并缓存一个 snapshot | pending snapshot register |
| E0 | envelope scheduler | 选择一个 slot，推进一帧 envelope | per-slot envelope state |
| E1 | envelope L0 | 锁存 zero/direct/cB token | slot/frame/last tag |
| E2 | envelope L1 | 求 attenuation octave | tagged level token |
| E3 | envelope L2 | 求 residual LUT index | tagged level token |
| E4 | envelope L3 | 读取 mantissa LUT | tagged mantissa token |
| E5 | envelope writeback | 舍入 Q1.15，写 slot/frame | level array、slot READY |
| P0 | phase scheduler | 选择一个 WORK_PLAN slot | plan round-robin pointer |
| P1 | phase datapath | 生成 endpoint job并更新 phase，或 final check | job array、phase、cursor |
| M0 | memory scheduler | 从 compact missing mask 选择 work | registered work ID |
| M1 | request engine | 在选中 work 内选择并接受一条 line | pending mask |
| M2 | response gather | 接受一条 ordered line response | sample scratch、valid bits |
| I0 | DSP issue selector | 选择 ready、无 hazard job | registered work/job ID |
| I1 | DSP token capture | 读取已选 slot 的 context/job/sample并锁存 elastic token | issue index、hazard |
| D0 | DSP S0 | interpolation difference multiply | interpolation product |
| D1 | DSP S1 | 完成 interpolation | signed sample `x` |
| D2 | DSP S2 | 计算 `b0*x/b1*x/b2*x` | feed-forward products |
| D3 | DSP S3 | 计算和饱和 `y` | 20-bit filter output |
| D4 | DSP S4 | 计算 `a1*y/a2*y` | feedback products |
| D5 | DSP S5 | 生成新 z1/z2，filter/bypass 选择 | early state update |
| D6 | DSP S6 | 左右 channel gain multiply | gain products |
| D7 | DSP retire | envelope multiply、sat16 | contribution、final state |
| R0 | renderer/engine | last result 合并 | phase/env/filter final state |
| R1 | state store | generation 检查和 dynamic write | next-block voice state |
| B2 | mix buffer | contribution 累加 | selected frame accumulator |
| B3 | controller/mix | 发布并转移 bank ownership | complete descriptor |

这些编号不是 24 个串行等待的 FSM 状态。B、C、E、P、M、I/D 和 R 是不同硬件，能在
同一拍处理不同 voice。只有表中属于同一共享资源的工作才互斥。

### 19.2 一拍到底发生什么

SystemVerilog 的一拍应按下面顺序理解：

```text
1. 寄存器保持上一上升沿提交的值。
2. always_comb 根据这些旧寄存器计算：
   - round-robin winner
   - ready/valid
   - endpoint-ready
   - hazard 是否在本拍由 forwarding 解除
   - 下一份 payload
3. 若 valid && ready，本拍末尾的上升沿发生 transfer。
4. always_ff 中所有非阻塞赋值在同一上升沿共同提交。
5. 下一拍组合逻辑看到新的寄存器值。
```

因此“response 在 clock 10 返回”表示 clock 10 上升沿写 sample scratch。issue 组合逻辑
在该上升沿之前仍看到旧 valid，最早在 clock 11 上升沿接受这个 sample token。

为了逐拍模拟，可以把 RTL 抽象成下面的伪代码。各个 `select` 并行计算，不是按文本
先后串行执行：

```text
for every clock:
  free_env       = select_free_envelope_slot()
  walk           = round_robin(SLOT_WALK)
  env_result     = round_robin(SLOT_READY)
  free_work      = select_free_or_same_cycle_retiring_work_slot()
  plan           = round_robin(WORK_PLAN)
  memory_work    = round_robin(work with required & ~valid & ~pending)
  memory_line    = select_line(registered_memory_work)
  issue          = round_robin(endpoint_ready && dependency_ready)
  complete       = select(WORK_COMPLETE)

  compute every ready/valid handshake
  compute phase, addresses, DSP arithmetic and forwarding muxes

  at rising edge:
    commit all accepted starts, requests, responses, issues and retires
    advance all non-stalled DSP valid/payload registers together
```

### 19.3 模拟输入条件

先用一个容易手算的 block：

```text
block frames       = 8
active voices      = A, B, C, D, E, F, G, H
all voices         = active, ENV_SUSTAIN, envelope level 0x7fff
phase              = 0.0
phase_inc          = 1.0 = 0x0000_0100
length             > 8, no loop boundary in this block
base addresses     = different 32-word-aligned regions
filter             = enabled
line_req_ready     = always 1
line response      = accepted request order, one-cycle return latency
contribution_ready = always 1
result_ready       = always 1
```

字母表示 voice/work context，数字表示这个 block 内的 frame，例如 `A3` 是 voice A 的
第 3 个输出 frame。真实 controller 的 slot ID 可以复用，不能假设 voice A 永远等于
work ID 0；这里只为阅读方便使用字母。

### 19.4 Block 接收、mix clear 和第一条 voice dispatch

以下以 block request transfer 的上升沿为 `b0`。这是 controller/mix 的精确初始拍序，
假设 bank 0 原来为 FREE、state store 和 envelope 都 ready：

| edge | controller 状态在沿前 | mix 动作 | state 动作 | 沿后主要结果 |
| ---: | --- | --- | --- | --- |
| b0 | IDLE | 接受 block，bank0 -> CLEARING | - | 锁存 frame_count/active bitmap |
| b1 | WAIT_FILL | clear frame 0 | - | clear index=1 |
| b2 | WAIT_FILL | clear frame 1 | - | clear index=2 |
| b3 | WAIT_FILL | clear frame 2 | - | clear index=3 |
| b4 | WAIT_FILL | clear frame 3 | - | clear index=4 |
| b5 | WAIT_FILL | clear frame 4 | - | clear index=5 |
| b6 | WAIT_FILL | clear frame 5 | - | clear index=6 |
| b7 | WAIT_FILL | clear frame 6 | - | clear index=7 |
| b8 | WAIT_FILL | clear frame 7 | - | bank0 -> FILLING |
| b9 | WAIT_FILL | fill ready | - | controller -> SELECT_GROUP |
| b10 | SELECT_GROUP | - | 选择 A 所在 group | -> SELECT_VOICE |
| b11 | SELECT_VOICE | - | 选择 A，清 active bit | -> REQUEST_STATE |
| b12 | REQUEST_STATE | - | A read request transfer | store `read_pending=1` |
| b13 | WAIT_STATE | - | 同步读取 A 四组 memory | response valid=1 |
| b14 | WAIT_STATE | - | A response transfer | pending snapshot=A |
| b15 | SELECT_VOICE | - | engine 接受 A snapshot | envelope slot0 -> WALK |

下一条 voice 可以继续经过 C1/C2/C3。无 backpressure 时，早期 dispatch 受 controller
状态转换和同步 state read 限制；运行一段时间后，更常见的限制是 envelope/renderer
是否有 free slot。pending register 支持旧 snapshot 被 engine 消费的同拍接收新
response，但当前 controller FSM 并没有每拍发一个 state read request。

### 19.5 Envelope 的精确流水模拟

为了单独展示 E0-E5 的满流水，假设 A-H 已经都处于 `SLOT_WALK`。E0 round-robin 每拍
选一个 frame，后面四级 conversion 同时处理之前的 token：

| edge | E0/L0 新 token | L1 | L2 | L3 | E5 writeback |
| ---: | --- | --- | --- | --- | --- |
| e0 | A0 | - | - | - | - |
| e1 | B0 | A0 | - | - | - |
| e2 | C0 | B0 | A0 | - | - |
| e3 | D0 | C0 | B0 | A0 | - |
| e4 | E0 | D0 | C0 | B0 | A0 level |
| e5 | F0 | E0 | D0 | C0 | B0 level |
| e6 | G0 | F0 | E0 | D0 | C0 level |
| e7 | H0 | G0 | F0 | E0 | D0 level |
| e8 | A1 | H0 | G0 | F0 | E0 level |
| e9 | B1 | A1 | H0 | G0 | F0 level |

一旦灌满，E5 每拍写回一个 level，即 envelope sample throughput 为一拍一个。每条
voice 仍每 8 拍才递归推进一次，所以写回 A0 后，A1 使用的是 E0 已经写入 slot 的新
envelope state。

对 8 voices x 8 frames：

```text
A0 在 e0 发入，e4 写回
A7 在 e56 发入，e60 写回并令 A slot READY
H7 在 e63 发入，e67 写回并令 H slot READY
```

所以不需要等所有 voice 的 envelope 完成才启动 renderer。A 在 e60 可以通过 result
handshake 进入 renderer，而 B-H 仍在 envelope drain/ready 路径中。

### 19.6 Phase planner 的精确模拟

假设 A-H renderer slot 均为 `WORK_PLAN`。P0 每拍选一个 slot，P1 是组合 phase datapath
加上升沿 job/phase 写回：

| edge | selected slot/frame | 写入 job | slot phase 沿后值 |
| ---: | --- | --- | --- |
| p0 | A0 | addr A+0/A+1, frac 0 | A=1.0 |
| p1 | B0 | addr B+0/B+1, frac 0 | B=1.0 |
| p2 | C0 | addr C+0/C+1, frac 0 | C=1.0 |
| p3 | D0 | addr D+0/D+1, frac 0 | D=1.0 |
| p4 | E0 | addr E+0/E+1, frac 0 | E=1.0 |
| p5 | F0 | addr F+0/F+1, frac 0 | F=1.0 |
| p6 | G0 | addr G+0/G+1, frac 0 | G=1.0 |
| p7 | H0 | addr H+0/H+1, frac 0 | H=1.0 |
| p8 | A1 | addr A+1/A+2, frac 0 | A=2.0 |

A7 在 `p56` 规划。该沿保存最后一个 job 并把 A 转到 `WORK_PLAN_FINAL`；A 下一次赢得
planner 时才用寄存后的 phase 做 final done check、写 `phase_result`，然后转到
`WORK_MEM_WAIT`。因此 final check 与最后一个 phase step 之间有寄存边界。H7 仍可在此
期间继续规划，phase planning 与较早完成 slot 的 memory fetch 继续重叠。

若 `phase_inc` 有 fraction，例如 1.5=`0x180`，A 的 endpoint 会依次为：

```text
frame0: addr 0/1, fraction 0x00, next phase 1.5
frame1: addr 1/2, fraction 0x80, next phase 3.0
frame2: addr 3/4, fraction 0x00, next phase 4.5
```

这只改变 job 内容，不改变 planner 每拍一个 slot step 的调度方式。

### 19.7 两级 line 选择与同步 window lookup 的精确模拟

当前 renderer 不锁定 32-word segment。把 M0 选中 A work 的上升沿记为 `m0`，window hit
response 无 backpressure：

| edge | M0/M1 动作 | window 动作 | renderer 沿后动作 |
| ---: | --- | --- | --- |
| m0 | M0 锁存 A work ID | - | `memory_select_valid=1` |
| m1 | M1 从 A endpoint 选 line A+0，请求 transfer | 锁存 request payload，进入 LOOKUP | A 对应 endpoint 置 pending |
| m2 | selector 可寻找下一 work，但 window 暂不 ready | 比较该 voice metadata；hit 时发起同步 BRAM read | - |
| m3 | - | BRAM 输出锁进 response register | - |
| m4 | - | window response transfer | 匹配 A 地址的 sample 写 scratch，valid=1、pending=0 |
| m5 | A 当前 job 两 endpoint valid 时可 `issue_select_capture` | - | work/job ID 写入选择寄存器 |
| m6 | I1 读取 A payload并执行 `issue_capture` | - | token 写入 elastic register |

miss 时 m2 初始化四-line refill 或单-line fallback，外部 ordered response 到达后返回
锁存的 work ID。M0 只看 compact missing bitmap，M1 只扫描一个已寄存 work 的 endpoint，
所以不再存在跨 8 work x 16 endpoint 的单拍嵌套地址选择。代价是每次 client line 多一个
LOOKUP 寄存拍；不同 work 的 phase planning、已有 window response 和 DSP issue 仍可并行。

### 19.8 DSP 的精确 token latency

把 A0 被 I0 的 `issue_select_capture` 选中的上升沿记为 `i0`。I1 在 `i1` 读取 payload、
执行 `issue_capture` 并锁进 elastic register；无 backpressure 时，DSP 在下一上升沿
`d0` 通过 `token_valid && token_ready` 接受它。hazard、issue index 和 last 状态在
`i1` 更新，下面 DSP 内部 latency 从 `d0` 起算：

| edge 后 | A0 所在寄存级 | 本级得到的结果 | 对 renderer 可见事件 |
| ---: | --- | --- | --- |
| d0 | S0 | interpolation product | token 已从 elastic register 进入 DSP |
| d1 | S1 | interpolated `x` | - |
| d2 | S2 | b0/b1/b2 products | - |
| d3 | S3 | saturated filter `y` | - |
| d4 | S4 | a1/a2 products，新 z1/z2 组合值 | `state_update_valid(A0)` |
| d5 | S5 | selected sample、注册新 state | renderer 在沿上写 A z1/z2 |
| d6 | S6 | left/right gain products | - |
| d7 | retire FIFO | envelope 和 sat16 结果 | `retire_valid(A0)` 拉高 |
| d8 | - | - | contribution transfer；若 last，同时发布 result |

因此当前语义是：

```text
accept 到 early state-update 可用：约 4 个寄存级，下一接受沿可 forwarding
accept 到 retire transfer：8 clocks
I0 select 到 DSP accept：2 clocks
```

这里把 `d4` 称为 state update “可见周期”：A0 在 d4 上升沿进入 S4 后，d4-d5 周期的
组合输出有效；renderer 和下一 token 在 d5 上升沿共同消费它。

### 19.9 Filter hazard 和 forwarding 的逐拍模拟

为了展示两级 issue 与 hazard，暂时只让 A、B 两个 slot 的 endpoint ready：

| edge | issue 选择 | A hazard | B hazard | state update | 说明 |
| ---: | --- | :---: | :---: | --- | --- |
| h0 | I0 select A0 | 0 | 0 | - | 只锁存 A/job ID |
| h1 | I1 capture A0 | 1 | 0 | - | A0 使用旧 A z1/z2 |
| h2 | I0 select B0 | 1 | 0 | - | - |
| h3 | I1 capture B0 | 1 | 1 | - | B0 使用旧 B z1/z2 |
| h4 | bubble | 1 | 1 | - | A/B 都有 unresolved RAW |
| h5 | I0 select A1 | 0 | 1 | A0 | A 在 update 同拍 dependency-ready |
| h6 | I1 capture A1 | 1 | 0 | B0 | 读取已经写回的 A0 state |
| h7 | I0 select B1 | 1 | 0 | - | B0 state 已写回 |

h5-h6 跨两个上升沿发生：

1. renderer 把 A0 的新 z1/z2 写进 `work_z1_q/work_z2_q[A]`；
2. I0 锁存 A1 的 work/job ID；
3. I1 下一拍读取新 state 并锁存 A1 token，再把 A hazard 置 1。

如果 A-H 八个 slot 都 ready，round-robin 通常会先发：

```text
select/capture A0, select/capture B0, ... select/capture H0, select/capture A1 ...
```

再次轮到 A 时，A0 update 已经返回，所以不出现 h2-h4 的 bubble。真实吞吐测试仍会
记录 forwarding，因为 memory ready 分布、slot completion 和尾部 context 数量会让
某 slot 恰好在 update 周期再次被选择。

### 19.10 DSP backpressure 的逐拍模拟

假设 retire FIFO 中已有 A0，随后 `contribution_ready=0`：

| cycle | FIFO occupancy | retire_ready | advance/token_ready | 动作 |
| ---: | ---: | :---: | :---: | --- |
| s0 | 1 | 0 | 1 | pipeline 可再 push 一项 |
| s1 | 2 | 0 | 0 | FIFO 满，所有 DSP stage 保持 |
| s2 | 2 | 1 | 0 | pop A0；本拍仍不让 ready 组合穿透 |
| s3 | 1 | 1 | 1 | pipeline 恢复，可同拍 pop/push |

FIFO 未满时 stall 不冻结 D0-D7；FIFO 满后才整体冻结，否则上游 token 会覆盖下游或使
tag 与 sample 错位。memory response 仍可继续填 endpoint scratch，直到 slot 容量和上游
状态自然形成 backpressure；它不需要跟 DSP 每级锁步。

### 19.11 Contribution、last result 和动态状态写回

对 A0-A7，普通 contribution 可以按以下顺序与其他 voice 交错：

```text
A0 B0 C0 ... H0 A1 B1 ...
```

每个 token 携带原始 `block_frame_index`，所以 B0 即使在 A1 后退休，也只更新 frame0
accumulator，不会混入 frame1。

A7 的 issue token 带 `last=1`。其 retire transfer 沿必须同时满足：

```text
contribution_ready
&& (!result_valid_q || result_ready)
```

该沿发生：

```text
mix[A7.block_frame_index] += A7 contribution
result_q = {A final phase, A final z1/z2}
result_env_* = A final envelope state
A work slot -> FREE，或同拍直接被新 start 重用
```

下一拍 engine 把 phase/env/filter 合成 `voice_dynamic_state_t`，state store 做 generation
比较后写回 A。controller 的 outstanding 只有在这次 result handshake 后才减一，而不是
在 A7 contribution 出现时提前减一。

### 19.12 Block drain 和 mix bank 发布

controller 清完 active bitmap 后进入 `CTRL_DRAIN`。假设最后一条 voice H 的 last result
在 `r0` 写回：

| edge | outstanding/ports | controller 动作 | mix bank 动作 |
| ---: | --- | --- | --- |
| r0 | H result transfer | outstanding 减一 | 接收 H last contribution |
| r1 | outstanding=0，无 pending/result | DRAIN -> FINISH | bank 仍 FILLING |
| r2 | finish valid && ready | FINISH -> IDLE | bank -> PUBLISHED，complete valid=1 |
| r3+ | consumer 接受 complete | 可接下一 block | bank -> OWNED，可逐 frame 读取 |

consumer 读完全部 frame 后必须 release bank，bank 才回到 FREE。另一个 bank 可以被下一
block 清零和填充；同一 bank 绝不能在 OWNED 时被 renderer 覆盖。

### 19.13 全局稳态叠加示意

把前面的独立局部时序叠加后，一个稳态窗口可能如下。此表只表示同拍并行，不作为
精确 testbench waveform：

| clock | C: state | E: envelope | P: phase | M: memory | I/D0: issue | D4: update | D7/R: retire |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| t0 | req H | G0 | F0 | select E work | capture A0 | - | - |
| t1 | store RAM read H | H0 | G0 | E line request | capture B0 / DSP A0 | - | - |
| t2 | rsp H | I0 | H0 | cache lookup/next select | C0 | - | - |
| t3 | start H/select I | J0 | I0 | E line response | D0 | - | - |
| t4 | req I | K0 | J0 | select F work | E0 | A0 update | - |
| t5 | store RAM read I | L0 | K0 | F line request | F0 | B0 update | - |
| t6 | rsp I | M0 | L0 | cache lookup | G0 | C0 update | - |
| t7 | start I/select J | N0 | M0 | F line response | H0 | D0 update | A0 valid |
| t8 | req J | G1 | N0 | select next work | A1 | E0 update | A0 transfer/B0 valid |

同一拍中可能同时有 state response、envelope step、phase job、line request、line response、
DSP issue、state update 和 retire。它们通过 tag 关联数据，通过 ready/valid 独立停顿。

### 19.14 为什么总周期接近 voice 数乘 frame 数

对所有 active voice 都 render 8 frames 的理想负载：

```text
useful DSP jobs = active_lanes * 8
256 lanes -> 2048 jobs
512 lanes -> 4096 jobs
```

各共享资源的有效工作量大致是：

| 资源 | 256-lane 工作量 | 理想稳态能力 |
| --- | ---: | ---: |
| envelope walker | 2048 frame steps | 1 step/clock |
| phase planner | 2048 frame steps | 1 step/clock |
| DDR memory request | 2 lines in shared-wave trace | 1 request/clock |
| DSP issue | 2048 tokens | 1 token/2 clocks |
| mix contribution | 2048 contributions | 1 contribution/clock |

它们彼此重叠，所以不能把各项工作量直接相加。当前下限由两级 issue 的 4096 clocks
决定，再加 block clear、初始 state/envelope/phase/memory/DSP fill、尾部 drain 和
调度气泡。

实测 filter-off：

```text
256: 4189 clocks
512: 8285 clocks
```

filter-on 因尾部 ready context 减少、RAW 等待和调度交接增加一些 bubble：

```text
256: 4202 clocks
512: 8298 clocks
```

相对 2026-07-27 的纯组合 frontend 基线，新增 overhead 主要来自 state/cache 同步 RAM
读、phase final check、两级 line 选择、两级 DSP issue 和 tagged envelope advance stage。
这是为 BRAM inference 和缩短组合路径支付的明确延迟；2-entry retire FIFO 在无
backpressure 测试中不增加 block 周期。最坏 512 filtered 使用 8298/16666 clocks，即
100 MHz 下 82.98 us，低于 8-frame 的 166.66 us 预算。

这也是为什么当前架构比 2-slot 好：大部分 block 时间都由必要的 sample 数决定，而不再
由 filter feedback latency 乘以 sample 数决定。

### 19.15 如何从 SV 复现这套运行模拟

生产吞吐仿真入口是 `sim/tb/tb_voice_major_throughput.sv`。运行：

```bash
make measure-voice-major-throughput
make measure-voice-major-throughput-filtered
make measure-voice-major-throughput-512
make measure-voice-major-throughput-512-filtered
```

输出字段解释：

| 字段 | 含义 |
| --- | --- |
| `cycles` | block render 完成耗时 |
| `deadline` | 100 MHz/48 kHz/8-frame 的 16666-clock 上限 |
| `max_outstanding` | controller 同时 dispatch、尚未写回的 voice 峰值 |
| `frontend_dsp_overlap` | `(plan_found || memory_active)` 与任一 DSP stage/retire 同时有效的拍数 |
| `line_requests` | accepted 8-word line request 数 |
| `dsp_issues` | accepted sample token 数 |
| `max_issue_run` | 最长连续每拍 issue 区间 |
| `forwards` | state update 与同 work ID issue 同周期次数 |
| `contributions` | accepted mix contribution 数 |

`render-rtl-ddr3` 还记录第一次实际含 active voice 的 block 输出首帧时序：

| 字段 | 含义 |
| --- | --- |
| `first_output_frame_index` | 渲染窗口内第一次非空 voice block 的首个 frame index |
| `first_output_active_voices` | 该 block 提交时 state store 的 active voice 数 |
| `first_output_frame_core_cycle` | 从 RTL reset 后到 C++ 收到该 frame read response 的绝对 core cycle |
| `first_output_frame_latency_cycles` | 该 block 开始渲染到首个 `block_read_rsp_valid` 的周期数 |
| `first_output_frame_latency_ns` | 按当前 100 MHz core clock 换算的纳秒数 |
| `peak_active_voices` | 整个窗口在 block 提交边界观察到的最大 active mono lane 数 |

这个指标不检查 NoteOn、PCM 是否非零或 WAV onset。空 voice block 不锁存结果；第一次
`active_voice_count != 0` 的 block 必须等全部 active voice contribution 累加并发布 mix
bank，随后 C++ 读回 `frame_index=0` 时才记录一次。

TB 还在层次路径上检查：

- unresolved hazard 时不得 issue；
- forwarding token 必须拿到 update bus 的 z1/z2；
- 外部请求只包含 endpoint 实际需要的 8-word 对齐 line；
- 同地址在途 miss 被 MSHR 合并，cache response tag 回到正确 work；
- issue select、DSP accept 和 retire/contribution 数相等；
- block 必须在 deadline 前完成。

如果需要生成 waveform，应只把它作为定位工具；PASS/FAIL 仍必须来自这些 self-checking
条件。增加 waveform 后，建议按本节编号给观察信号分组：C、E、P、M、I、D0-D7、R、B，
并同时显示 `work_id`、`frame_index`、valid/ready 和 slot state。

## 20. 当前测量和含义

条件：8 frames、理想 ordered memory 每拍可接受一个 line request、下一拍开始有序返回。

| active mono lanes | filter off | filter on | DSP issues | line requests |
| ---: | ---: | ---: | ---: | ---: |
| 256 | 4189 clocks | 4202 clocks | 2048 | 2（共享 wave trace） |
| 512 | 8285 clocks | 8298 clocks | 4096 | 2（共享 wave trace） |

四种规模的最长连续 DSP transfer 都是 1 clock，这是 I0/I1 非重叠设计的预期结果。
吞吐回归不再把 sample `II=1` 当目标，而是检查 issue select/DSP accept/contribution
计数一致、RAW hazard、frontend/DSP overlap 和 16666-clock deadline。

相对历史架构的 256-lane 周期：

| 架构 | filter off | filter on |
| --- | ---: | ---: |
| 旧 single-voice DSP FSM | 13328 | 21520 |
| 已删除 prepared-slot renderer | 7218 | 13625 |
| 2-entry streaming/forwarding | 5928 | 7734 |
| 8 tags、串行 frontend | 5928 | 5956 |
| interleaved phase/memory frontend | 3373 | 3401 |
| 2026-07-27 组合 frontend tagged pipeline | 2149 | 2191 |
| BRAM/timing 优化、单级 issue | 2405 | 2685 |
| 当前两级 issue timing-closed pipeline | 4189 | 4202 |

当前架构相对 2-slot 版本明显更快，特别是 filter-on 已接近 filter-off。因此已选定该
架构，旧串行 envelope/endpoint/segment/gather RTL 和专属 TB 已删除。

上述结果是 Verilator 周期/功能基线，不是 FPGA timing 或 BRAM signoff。本次 RTL 已按
`docs/verification/vivado_synthesis_timing.md` 的规则改成 canonical synchronous RAM、
无 payload bulk reset、较短选择级和 registered handoff；仍必须在有 Vivado 的环境中
检查 inferred RAM primitives、post-route WNS/TNS/WHS/THS、DRC 与层次 utilization，才能
确认实际映射和 100 MHz closure。

### 20.1 SGM/《我的舞台》10 秒真实窗口

输入为 SGM v2.01 SoundFont 和《我的舞台.mid》，`START_SECONDS=10`、`SECONDS=10`、
48 kHz、512-set/16 KiB cache、8 MSHR。以下是 I0/I1 分级前的单级 issue 基线，保留用于
WAV 与 cache 回归；它不是当前 RTL 的周期数：

```text
frames=480000
render_blocks=60054
total_render_cycles=21879078
max_render_cycles=574
deadline_misses=0
first_output_frame_index=3934
first_output_active_voices=9
first_output_frame_latency_cycles=138
first_output_frame_latency_ns=1380
cache_requests=2761938
cache_misses=1141138
cache_miss_stall_cycles=0
ddr_reads=1141138
```

相对改造前同一 16 KiB-cache trace，total render cycles 从 20,851,713 增到 21,879,078
（约 4.93%），worst block 从 521 增到 574 cycles。按每个 block 自己的 frame_count
计算，实测最高 deadline utilization 为 8.064%，没有 deadline miss。DDR read 只增加
63 次，miss-allocation stall 从 4 降到 0。新旧 WAV 的
SHA-256 都是
`59cb5527de6170f6aa93e6baf91d0c29ef94e28972c173fa1a2a70fcbe83682c`，逐字节相同。

### 20.2 SGM/Butter-Fly 100 秒长 trace 与 cache 利用率

输入为同一个 SGM v2.01 SoundFont 和 `butter fly ver2.mid`，从 0 秒开始渲染
100 秒，其他条件仍为 48 kHz、512-set/2-way/16 KiB cache、8 MSHR。以下同样是 I0/I1
分级前的单级 issue 长 trace：

```text
frames=4800000
render_blocks=604786
total_render_cycles=286781740
max_render_cycles=1012
max_deadline_utilization_ppm=169920
deadline_misses=0
first_output_frame_index=61091
first_output_active_voices=4
first_output_frame_latency_cycles=79
first_output_frame_latency_ns=790
cache_requests=39520140
cache_hits=23144160
cache_mshr_merges=934
cache_misses=16375046
cache_evictions=16374022
cache_miss_stall_cycles=70
ddr_reads=16375046
```

cache 对每个完成分类的 client line request 恰好记入 hit、在途 MSHR merge 或新 miss
之一，因此本 trace 满足：

```text
cache_requests = cache_hits + cache_mshr_merges + cache_misses
39520140      = 23144160   + 934               + 16375046

resident hit rate       = cache_hits / cache_requests
                        = 58.562950%
MSHR merge rate         = cache_mshr_merges / cache_requests
                        = 0.002363%
DDR miss rate           = cache_misses / cache_requests
                        = 41.434686%
DDR access avoided rate = (cache_hits + cache_mshr_merges) / cache_requests
                        = 58.565314%
```

`ddr_reads == cache_misses` 是接口的预期一一对应关系：每个新 line miss 发出一次 DDR
read，而 resident hit 和 MSHR merge 都不再发 DDR read。它不表示 cache 没有效果；若
每个 client request 都直接访问 DDR，本 trace 将需要 39,520,140 次 line read，当前只
需要 16,375,046 次，避免了 23,145,094 次。

cache 共 `512 * 2 = 1024` 条 line，每条 16 bytes。reset 后 valid 全空；fill 仅在目标
set 两个 way 都 valid 时增加 eviction。本 trace 有：

```text
cache_misses - cache_evictions = 16375046 - 16374022 = 1024
```

这证明 trace 已把全部 1024 条 line 填满，之后绝大多数新 line fill 都替换一个旧
line，即 cache 长期处于满容量并持续 churn。该差值只能证明最终 occupancy 和替换
行为，不能给出时间平均 occupancy、逐 set 冲突热点或 line 被淘汰前的 reuse count；
若需要这些指标，必须增加 occupancy-time、per-set conflict 和 reuse-distance 计数器。

这种结果符合多复音波表的固有访问模式：每个 voice 的独立 phase、phase increment、
sample region 和 loop 让全局 DDR line 地址在 voice 间跳转，工作集又远大于 16 KiB。
线性插值的 `sample[n]` 和 `sample[n+1]` 通常落在同一条 8-sample line，不能把约 50%
命中率简单解释成“第二个插值样本命中”；实际 reuse 还来自同一 voice 相邻 frame 的
line 局部性、偶发的跨 voice 共享，以及 MSHR 的在途合并。本 trace 的 58.565% DDR
访问避免率说明这些局部性有效，但 41.435% miss rate 和接近一 miss 一 eviction 也
说明普通小容量 set-associative cache 无法保留完整活跃波表工作集。

生成 WAV 为 48 kHz、16-bit stereo PCM，大小 19,200,044 bytes，SHA-256 为
`e207622f0e27e538de64ab9eab5d8dd338fafaa32e711e59a6598665702aa7c2`。

### 20.3 Vivado 2025.2 renderer/cache/MIG 综合（window 替换前基线）

`smart_artix_voice_major_synth_top` 把 `voice_major_render_core` 的 ordered-line 接口接到
Smart Artix line reader、read/write arbiter、SD loader 和真实 DDR3 MIG XCI。Clock
Wizard 只给 MIG 提供 200 MHz `sys_clk_i`；renderer、cache 和 memory subsystem 统一使用
MIG 100 MHz `ui_clk`，本次没有引入独立同频系统时钟或 CDC。

运行：

```bash
/opt/Xilinx2051.1/2025.2/Vivado/bin/vivado -mode batch \
  -source fpga/smart_artix/vivado/scripts/render_core_synth.tcl
```

目标 `xc7a50tfgg484-2` 的 post-synth 总资源：

| resource | used | available | utilization |
| --- | ---: | ---: | ---: |
| Slice LUT | 29254 | 32600 | 89.74% |
| Slice FF | 31857 | 65200 | 48.86% |
| BRAM tile | 15.5 | 75 | 20.67% |
| DSP48E1 | 12 | 120 | 10.00% |

主要层次资源：

| hierarchy | LUT | FF | RAMB36 | RAMB18 | DSP |
| --- | ---: | ---: | ---: | ---: | ---: |
| `core` | 20342 | 21972 | 12 | 7 | 12 |
| `renderer` | 14288 | 15704 | 4 | 2 | 12 |
| `renderer` 自身（不含 DSP/cache/phase） | 2762 | 12400 | 0 | 0 | 0 |
| `renderer.dsp` | 3470 | 1209 | 0 | 0 | 12 |
| `line_cache` | 7646 | 2095 | 4 | 2 | 0 |
| `envelope` | 3383 | 4120 | 0 | 2 | 0 |
| `state_store` | 1607 | 266 | 8 | 3 | 0 |
| `memory_subsystem` | 3797 | 5610 | 0 | 0 | 0 |
| DDR3 MIG | 5114 | 4146 | 0 | 0 | 0 |

cache data 的四个 `512 x 64` bank 均映射为 RAMB36E1，两个 `512 x 29` tag bank
映射为 RAMB18E1，说明同步 read/fill 结构已经成功推断成 block RAM。Vivado 同时报告
这些 RAM 没有可吸收到 primitive 内的可选 output register；若它们进入 post-route
关键路径，需要再增加明确的 BRAM output stage，而不是退回组合 read。

state store 已改成四组显式 packed-vector synchronous RAM，在读写边界转换 struct。
256 voice 配置映射为 8 RAMB36 + 3 RAMB18，层次内只剩 1607 LUT/266 FF；此前由 struct
field 拆分形成的 30 个浅 RAMB18 已消失。四个 bank 仍分离，以支持 install 同拍更新
region/event/env/dynamic。

LUT/FF 的主要来源不能只看顶层百分比。真实 MIG 加 memory subsystem 固定占约 8911 LUT
和 9756 FF；core 本身占 20342 LUT/21972 FF。core 内最大 LUT 块是 line cache：BRAM 只
保存 data/tag，MSHR、waiter mask、fill gather、replacement、compare 和 response mux 仍需
7646 LUT。renderer 自身的 12400 FF 主要来自 8 个浅 work slot：每 slot 保存最多 8 个
job、16 个 endpoint sample/valid/pending/required，以及 context、phase、envelope 和 filter
状态；深度 8 不适合直接按 256-voice RAM 的方式映射。DSP 的 tagged pipeline 和 retire
FIFO 另占 1209 FF。层次资源是包含关系，不能把 renderer 与其 DSP/cache 子项重复相加。

I0/I1 两级 issue 后，100 MHz post-synth setup 已通过：`clk_pll_i` WNS +0.309 ns、TNS 0、
0 个 setup failing endpoint。此前 `work_issue_index_q -> DSP48 B` 的 -0.682 ns 路径已被
寄存边界切断；新的最差 setup 是 renderer endpoint gather 到 pending mask，17 logic
levels、data path 9.512 ns。分层最差 slack 为 state store +3.442 ns、envelope +1.908 ns、
DSP +0.414 ns、line cache +0.813 ns、mix +4.193 ns、memory subsystem +2.908 ns、MIG
+0.983 ns，未把负路径转移到其他模块。

总 timing summary 仍显示跨 MIG 派生时钟的 post-synth hold 负值；100 MHz `clk_pll_i`
域内 WHS 是 +0.029 ns。跨域 hold 必须在正式 place/route 和 MIG 约束上下文中判断，不能
把综合期跨时钟估算当作 core hold failure。该结果仍不是 post-route signoff。

此 harness 为保留完整动态 core 行为而直接导出 raw install/parameter/block 接口，导致
报告有 1191 个 bonded I/O，超过器件的 250 个 I/O；因此它只用于 renderer/cache/MIG
资源和内部 timing 检查，不能直接进入 implementation。最终板级 top 必须接入正式控制
transport，并重新运行带完整 XDC、DRC、place/route 和 hold exception 的实现流程。

### 20.4 Vivado 2025.2 window/MIG 综合（当前实现）

32-sample per-voice window 替换 cache、并在 request 接收后增加 LOOKUP 寄存级后，用与
20.3 相同的 top、器件、MIG XCI 和 100 MHz `ui_clk` 约束重新综合。总资源为：

| resource | used | available | utilization | 相对 20.3 cache 基线 |
| --- | ---: | ---: | ---: | ---: |
| Slice LUT | 26116 | 32600 | 80.11% | -3138 |
| Slice FF | 30323 | 65200 | 46.51% | -1534 |
| BRAM tile | 14.5 | 75 | 19.33% | -1.0 |
| DSP48E1 | 12 | 120 | 10.00% | 0 |

主要当前层次资源：

| hierarchy | LUT | FF | RAMB36 | RAMB18 | DSP |
| --- | ---: | ---: | ---: | ---: | ---: |
| `core` | 17192 | 20426 | 12 | 5 | 12 |
| `renderer` | 11164 | 14157 | 4 | 0 | 12 |
| `renderer` 自身（不含子模块） | 3368 | 12425 | 0 | 0 | 0 |
| `voice_sample_window` | 4226 | 513 | 4 | 0 | 0 |

`window_data` 被推断成一个 `1024 x 128` simple dual-port RAM，精确使用 4 个 RAMB36E1；
per-voice metadata 和控制不再使用额外 RAMB18。相对旧 `line_cache` 层次本身，window
减少 3420 LUT、1582 FF 和 2 RAMB18。总设计下降较小是因为 MIG、memory subsystem、
state store、envelope 和 renderer work slots 均未随 cache 替换而消失。

100 MHz post-synth setup 为 `WNS +0.112 ns / TNS 0`，0 个 failing endpoint；同域 hold
仍为 `WHS +0.029 ns / THS 0`。最差 setup 已回到 renderer 的 endpoint valid 到 pending
mask，15 logic levels、data path 9.709 ns。未加 LOOKUP 寄存级的中间版本曾出现 renderer
pending 到 window response counter 的 19-level 跨层路径，WNS -3.133 ns；因此 request
锁存不是功能性延迟装饰，而是当前 100 MHz 时序成立所需的边界。以上仍是 post-synth，
不替代正式板级 top 的 place/route signoff。

## 21. 估算带宽时不能漏掉什么

256 voices、8 frames 有 2048 个有效 sample job。window 替换前的 cache 吞吐 trace 让
全部 voice 共享同一 wave 和 phase，因此只有两条唯一 endpoint line；共享 cache/MSHR
后曾实测只发出 2 条 DDR line：

```text
2 lines * 8 words/line * 2 bytes/word = 32 bytes/block
```

在 48 kHz、8-frame block 下每秒 6000 blocks：

```text
32 * 6000 = 0.192 MB/s
```

这个数字只证明旧 cache 对共享 wave 的跨 voice 复用路径，不代表真实音乐带宽，也不是
当前 per-voice window 的冷启动流量。window reset 后每个 voice 都需独立 refill；不同
preset、随机 phase、大 phase increment 或 fallback 又会提高流量，同时还需计入 DDR
command、refresh、row miss、其他 master 和 MIG 效率。板级容量规划必须基于真实
SF2/MIDI request trace 的 p50/p99/max window hit rate 和 block latency。

### 21.1 Per-voice 连续样本窗口实验

通用 2-way line cache 的主要资源代价不是 sample data BRAM，而是 tag compare、替换、
MSHR waiter 和 response 路由。一个更贴近波表访问模式的候选结构是：每个 voice 拥有一个
固定长度的连续 sample window，只保存 `valid + base_addr` 元数据；当前 endpoint 不在窗口
时，从包含当前 phase 整数地址的 8-word 对齐 DDR line 开始顺序 refill。loop wrap 或异常
大 phase increment 越界时允许单 line fallback，不因此立即破坏当前顺序窗口。

仿真 harness 在 phase planner 生成 job 时记录原始两个插值 endpoint，因此统计不受当前
cache 命中和 memory scheduler 顺序影响。2026-07-28 使用
`SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2` 和
`sgm_polyphony_random_access_stress.mid` 从 0 秒渲染 0.5 秒；全程峰值 256 mono voices，
共 3000 个 render block、766310 个有效 voice-block、12256904 个 endpoint：

| window samples/voice | sample BRAM36 | 单次装入后的 endpoint 覆盖 | 整 voice-block 覆盖 | 每 block 重装 DDR lines | 跨 block 保留 DDR lines |
|---:|---:|---:|---:|---:|---:|
| 8 | 1 | 59.693% | 23.951% | 1437404 | 1232681 |
| 16 | 2 | 97.239% | 91.245% | 1621016 | 973499 |
| 32 | 4 | 99.959% | 99.722% | 3067445 | 821661 |
| 64 | 8 | 99.992% | 99.983% | 6130684 | 745864 |
| 128 | 16 | 99.992% | 99.983% | 12261164 | 708128 |

同一 trace 的替换前 512-set/2-way/16 KiB cache 有 1437404 个 client line request、
688613 个 resident hit、553 个 MSHR merge 和 748238 个 DDR read。由此可得：

- 不能在每个 voice-block 开头无条件 refill。32-sample 配置虽然覆盖 99.722% 的完整
  voice-block，却会产生 3067445 条 DDR line read，是旧 cache 的约 4.10 倍；连续访问
  带来的 row-hit 改善不足以合理抵消这种过读。
- window 必须按 voice 跨 block 保留。32-sample 配置估算 821661 条 DDR read，比旧
  cache 多 9.81%，但 sample 存储只需 4 个 RAMB36；64-sample 配置估算 745864 条，已与
  cache 基本相同，并需要 8 个 RAMB36。
- 128-sample 只比 64-sample 再减少约 5.1% 的 window DDR read，却把 sample BRAM 从 8
  增到 16，不适合作为默认值。16-sample 虽只用 2 个 RAMB36，但相对当前 cache 多约
  30.1% DDR read。
- “越界立即重装窗口”在该 trace 上不如保留原窗口并对离群 endpoint 做单 line fallback；
  64-sample 两者分别为 832288 和 745864 条 line。loop 边界的第二 endpoint 尤其不应触发
  整窗替换。

production RTL 已采用 32 samples/voice。用同一 0.5 秒 trace 连接 DDR3 timing model 的
最终实测与 estimator 完全一致：1437404 个 client request 中有 1093715 次 window hit、
159324 次四-line refill、184365 次单-line fallback，共 821661 次 DDR read。旧 cache 为
748238 次，因此增加 9.81%；最终 run 的 DDR row-hit 为 523467/821661=63.71%，旧 cache
为 222105/748238=29.68%。最大 render block 从旧 cache 的 4364 增到 4467 cycles，deadline
最大利用率从 26.184% 增到 26.802%，仍无 miss。LOOKUP 寄存级相对未寄存 window 版本只
增加 377 total render cycles/3000 blocks，最大 block 增加 7 cycles；首次完成所有复音
mix 后输出 frame 仍为 2373 cycles，即 23.73 us。新旧 WAV SHA-256 均为
`f3203d50cdc4ff4862344af4ccb99225dc87a7ca8eff7f5a448c7c8af2ad0843`，逐字节相同。

同一 MIDI、SF2 和 0.5 秒区间也用 `SYNTH_NUM_VOICES=512`、
`RENDER_NUM_VOICES=512` 重建并运行。DDR3 harness 原先把 raw `install_voice` 和
`params_voice` 强制转换为 8 bit，使 256..511 回卷；改为保留 Verilated 9-bit port 后，
峰值达到 512 voices，且 stale parameter update 为 0。最终 3000 blocks 的最大 render
latency 为 8755 cycles，deadline 利用率 52.530%，无 miss；首次输出 block 当时有 465
个 active voices，全部 mix 后首帧延迟 4254 cycles，即 42.54 us。2829668 个 client
request 中有 2151421 次 window hit、310885 次四-line refill、367362 次 fallback，共
1610902 次 DDR read；row-hit 为 1046265/1610902=64.949%。输出 WAV SHA-256 为
`c7d77e80111f708d6e622ed4ea4d9bd5fcacad08434890929c1ac31966793f25`。

该结果证明当前单 lane renderer/window/DDR3 model 在 512-voice 压力下仍有周期余量，
不等于 512 voices 的数值范围已经签核。最坏同号 PCM16 求和为
`512 * 32767 = 16776704`，需要 signed 25 bit；当前 mix accumulator 是 32 bit，但发布
接口仍截取为 signed 24 bit，极端输入可能回卷。512 配置接入音频链前必须把发布宽度扩为
至少 25 bit，或在 24-bit 边界明确做饱和。

64-sample 仍可作为后续带宽档，但当前先保留 32，以限制 BRAM。window 替换后的 Vivado
资源和 post-synth timing 见 20.4；20.3 仅保留为替换前对比基线。

## 22. 必须保持的设计不变量

修改流水线时至少保持以下条件：

1. 同一 voice 的 envelope、phase 和 filter state 按 frame 顺序演进。
2. 不同 voice 可以交错，但 contribution 必须携带正确 voice/generation/frame tag。
3. filtered slot 有未返回 state update 时不得使用旧 z1/z2 发下一 token。
4. state update 与再发同拍时必须 forwarding。
5. DSP stall 时 valid、数据和 tag 全部保持。
6. 同一 work/line 最多有一个 pending 请求；window transaction 串行期间不得重复提交。
7. 外部无 tag memory response 必须有序；内部 window response 必须带正确 work tag。
8. block 发布前所有 accepted voice 必须完成 dynamic writeback。
9. generation 不匹配的 parameter/dynamic/control write 不得修改新 voice。
10. mix bank 未被 consumer release 前不得重新用于 fill。
11. fixed-point 的移位、舍入、饱和和 signed extension 必须与文档及 TB 一致。
12. effects 接入后，任何 fork 的每个分支都必须恰好消费一次 frame。

## 23. 当前验证覆盖

生产路径的 focused SV TB 包括：

- `tb_block_interleaved_envelope_frontend`：8-context tag、level、普通/立即/Attack 中
  release 和 backpressure；
- `tb_block_interleaved_voice_renderer`：基础 endpoint/memory/DSP/result 和 stall；
- `tb_block_interleaved_voice_dsp`：精确整数运算、tag、state update 和 retire stall；
- `tb_block_mono_voice_engine`：envelope 到最终 dynamic result；
- `tb_voice_major_block_controller`：active scan、state dispatch、drain 和 mix；
- `tb_voice_major_render_core`：state continuity、block 发布和读取；
- `tb_voice_sample_window`：refill、hit、fallback 保窗、voice 隔离、response backpressure
  和精确统计；
- `tb_voice_major_throughput`：256/512、filter on/off、连续 line、hazard、forwarding、
  issue select/accept/retire 数量和 deadline。

效果器、compressor、FIFO/I2S、SPI、SD 和 Smart Artix DDR subsystem 有各自 focused TB，
但目前没有一个 TB 同时覆盖全部模块。

## 24. 尚未证明和下一步验证

### 24.1 Memory realism

需要给 production renderer TB 增加固定和随机 request/response stall，并统计：slot
occupancy、phase starvation、memory starvation、hazard stall、retire stall、window
hit/refill/fallback/eviction、p50/p99/max block cycles。还要补 jumped address、fractional phase 和
loop-wrap 的直接 renderer 回归。

### 24.2 Synthesis and timing

Vivado 2025.2 已完成包含真实 MIG XCI 的综合，100 MHz post-synth setup 已通过，但
synthesis harness 的 raw control I/O 不具备 implementation 可行性。当前已确认：

- window sample data 成功映射为 4 RAMB36，不再使用 cache tag RAMB18；
- state store 的显式 packed-vector bank 映射为 8 RAMB36 + 3 RAMB18；
- renderer 使用 12 个 DSP48E1；
- `clk_pll_i` setup WNS +0.112 ns、TNS 0，同域 WHS +0.029 ns、THS 0；
- 当前最紧路径是 renderer endpoint gather，window request 已用 LOOKUP 寄存级隔离；
- 全设计仍需正式板级 control transport 和 post-route signoff。

下一步应建立可实现的板级 control transport，再检查 post-route WNS/TNS/WHS/THS、
DRC、route status 和层次资源。若 place 后 renderer endpoint gather 或 window 失去余量，
应继续拆分相应选择/更新路径；不能通过降低测试负载掩盖 timing failure。

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
