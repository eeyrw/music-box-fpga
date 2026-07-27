# Wave Memory And Ordered-Line Contract

Updated: 2026-07-27

本文定义当前 `voice_major_render_core` 使用的波表地址、mono lane 和外部有序 line
memory 契约。它替代已经删除的单 word renderer、`voice_line_cache` 和
`wave_memory_subsystem` 说明。

## Address Unit And Image Origin

所有地址都是 32-bit **16-bit word address**，不是 byte address。地址 `A` 对应 image
中的字节 `[2*A, 2*A+1]`，解释为 signed PCM16 little-endian sample。

对直接使用完整 SF2 文件 image 的流程，word address 0 是 SF2 文件的第一个 16-bit
word。voice 的 `base_addr` 必须已经包含 `smpl` chunk payload 在文件中的 word offset；
FPGA 不解析 RIFF/SF2 结构。

一个生产 hardware voice 是一条 mono lane，配置为：

```text
base_addr : 32-bit absolute word address
length    : 24-bit sample-frame count
loop_start: 24-bit offset from base_addr
loop_end  : 24-bit exclusive offset from base_addr
loop_mode : none / continuous / until-release
```

普通 sample `n` 的地址为：

```text
addr(n) = base_addr + n
```

有效 region 满足：

```text
length > 0
0 <= loop_start < loop_end <= length        // looping region
```

`loop_end` 是 exclusive。最大 mono region 为 `0x00ff_ffff` samples，接近 32 MiB
PCM16 数据。

## Stereo Ownership

当前生产 RTL 没有单 slot 的 left/right 双波表 region。需要 SF2 linked stereo 时，
host/MCU 把左右 sample 分配成两条普通 mono lane：

```text
left lane : left base/length/loop, gain_l != 0, gain_r normally 0
right lane: right base/length/loop, gain_l normally 0, gain_r != 0
```

两条 lane 可以共享 pitch policy，但拥有独立 phase、envelope 和 filter history。C++
SF2 parser 目前仍能产生 collapsed stereo `Region` 供 reference renderer 使用；新的 RTL
harness/MCU adapter 必须在提交 `block_voice_state_snapshot_t` 前完成上述 lane expansion。
这个 adapter 尚未实现，因此不能把 C++ stereo region 支持当作新 RTL 的端到端覆盖。

## Phase To Endpoint Addresses

phase 使用 unsigned Q24.8：

```text
frame_0 = phase[31:8]
fraction = phase[7:0]
```

无 loop 时：

```text
frame_1 = (frame_0 + 1 >= length) ? frame_0 : frame_0 + 1
```

loop active 时：

```text
frame_1 = (frame_0 + 1 >= loop_end) ? loop_start : frame_0 + 1
```

renderer 为一个输出 frame 建立两个 endpoint：

```text
endpoint_addr[0] = base_addr + frame_0
endpoint_addr[1] = base_addr + frame_1
```

两个 endpoint 返回后进行线性插值：

```text
sample = sample_0 + (((sample_1 - sample_0) * fraction) >>> 8)
```

## Ordered Line Interface

当前 generic core 的板级 memory 边界是 8-word line，不是旧单-word request。

```systemverilog
typedef struct packed {
  logic [31:0] aligned_line_addr;
} ordered_line_req_t;

typedef struct packed {
  logic [7:0][15:0] words;
} ordered_line_rsp_t;
```

握手端口为：

```text
line_req_valid / line_req_ready / line_req
line_rsp_valid / line_rsp_ready / line_rsp
```

request 只在 `line_req_valid && line_req_ready` 的上升沿被接受；response 只在
`line_rsp_valid && line_rsp_ready` 的上升沿被接受。valid 被 backpressure 时，producer
必须保持 payload 不变。

`aligned_line_addr` 是 word address，必须 8-word 对齐：

```text
aligned_line_addr[2:0] == 0
```

response word 排列为：

```text
words[0] = memory[aligned_line_addr + 0]
...
words[7] = memory[aligned_line_addr + 7]
```

## Ordering And Outstanding Rules

response payload 没有 voice ID、request ID 或 address。memory adapter 必须严格按 request
被接受的顺序返回 response。当前 renderer 允许同一 segment 的多个 line request 在
response 返回前已经被接受，因此 adapter 至少要保持这些 request 的有序 association。

允许：

- request 与 response 使用不同延迟；
- `line_req_ready` 和 `line_rsp_valid` 任意合法 stall；
- adapter 内部使用 DDR burst、cache、bank scheduler 或多个 controller transaction；
- 内部 DDR response 乱序，只要 adapter 在 core 边界重新排序。

不允许：

- 在 core 边界乱序返回；
- response 丢失、重复或合并；
- 依赖 combinational/asynchronous wave array read；
- response stall 时改变 `line_rsp.words`；
- 把 byte address 当作 word address。

如果未来要在 core 边界暴露多个 voice 的乱序 response，必须修改 payload，至少增加
transaction tag，并在 renderer 中增加 issued-segment table。不能在现有无 tag 协议上
仅放宽 ordering 文字。

## Voice-Major Segment Policy

renderer 当前参数 `SEGMENT_BEATS=4`，每个 beat 是 8 words，因此：

```text
segment_words = 4 * 8 = 32 words
segment_base = floor(first_remaining_endpoint / 32) * 32
```

锁定一个 work slot 后，request 顺序固定为：

```text
segment_base + 0
segment_base + 8
segment_base + 16
segment_base + 24
```

四条 request 全部属于同一 voice 的一个连续 32-word window。segment 完成前 memory
engine 不切换 voice。这个 voice-major lock 是为了利用 DDR row/burst、SDRAM、SRAM、
parallel memory 和 cache 都常见的连续地址优势。

phase planner 可以交错处理不同 voice，DSP 也可以交错 issue，不影响外部 memory 保持
voice-major。不同层使用不同顺序：

```text
phase:  A0 B0 C0 D0 ...
memory: A line0/1/2/3, then B line0/1/2/3
DSP:    any slot whose next frame endpoints are ready
```

## Endpoint Scoreboard And Response Association

每个 renderer work slot 最多保存 8 个 job、16 个 endpoint sample 和 16-bit valid
scoreboard。启动 segment 时，renderer 保存：

- `memory_work_id_q`：response 属于哪个 slot；
- `memory_segment_base_q`：32-word window；
- `memory_segment_mask_q`：该 window 覆盖哪些 endpoint；
- request beat 和 response beat 独立计数器。

第 `r` 个 response 的隐含 line address 为：

```text
memory_segment_base + r*8
```

renderer 比较 endpoint 地址高位，并从 `line_rsp.words[addr[2:0]]` 取出 sample。相同地址
可以同时满足多个 job 的 endpoint bit。

DSP 不必等整个 segment 完成。一个 job 的两个 endpoint valid 后，它就能参加 issue；
与此同时 memory engine 可以继续接收该 segment 的后续 response。这是 memory fetch 与
DSP pipeline overlap 的关键。

刚在某上升沿写入的 sample/valid 最早下一拍被 issue 逻辑看到。设计不依赖目标 FPGA
RAM 的 write-first/read-first 行为。

## Multiple Segments, Loops And Jumps

若 8 个 frame 的 endpoint 跨越多个 32-word window，完成当前 segment 后 renderer 会
重新计算 remaining mask，再锁定下一个 segment。loop wrap、较大 phase increment 或
接近 region 边界都可能产生多个 segment。

V1 phase 契约要求：

```text
phase_inc < (loop_end - loop_start) << 8
```

所以一次 phase step 最多越过一个 loop boundary。该限制简化 phase wrap，但不意味着
所有 block 只访问一个 memory segment。

当前基础 renderer/throughput TB 覆盖连续 line 和完整 request/response 数量。jumped
address、fractional phase、loop-wrap 以及随机 memory stall 仍需直接补到生产 renderer
TB；旧 standalone planner/gather TB 已删除。

## DDR Adapter Responsibilities

Smart Artix 或其他板级 adapter 至少需要处理：

1. 把 16-bit word address 转换成 DDR byte/burst address。
2. 将一个 8-word request 组成或提取为 128-bit PCM line。
3. 保持 ready/valid，吸收 MIG `app_rdy`、read latency 和 refresh stall。
4. 对内部 outstanding reads 保存顺序，向 core 有序返回。
5. 与 SD asset-loader writes、host debug 和其他 DDR master 仲裁。
6. 在 loader 写入期间阻止 renderer 读到部分更新的 SF2 image。
7. 跨 clock domain 时使用正式 async FIFO/CDC，不直接同步多 bit payload。

当前仓库保留 Smart Artix SD/DDR peripheral modules，但旧 board top 已删除；还没有 adapter
把它们与 `voice_major_render_core` 的 ordered line 接口组成可综合整机。

## Bandwidth Reference

理想 throughput TB 的测量：

| lanes | frames | line requests | bytes/block | 48 kHz bandwidth |
| ---: | ---: | ---: | ---: | ---: |
| 256 | 8 | 1024 | 16384 | 98.304 MB/s |
| 512 | 8 | 2048 | 32768 | 196.608 MB/s |

换算使用：

```text
bytes/block = line_requests * 8 words * 2 bytes
blocks/second = 48000 / 8 = 6000
```

这些是当前 ideal trace 的 payload bytes，不包含 DDR command、refresh、row miss、总线
填充、仲裁或 CDC overhead。固定四-line segment 也会读取无用 words。真实验证必须
统计 burst starts、average burst length、useful-word ratio 和 p50/p99/max response
latency。

## Verification Commands

```bash
make lint
make test
make test-voice-major-512
make measure-voice-major-throughput
make measure-voice-major-throughput-filtered
make measure-voice-major-throughput-512
make measure-voice-major-throughput-512-filtered
```

当前理想 memory 周期为 256 lanes `2149/2191`（filter off/on），512 lanes
`4197/4258`。这些结果证明 generic renderer 的计算吞吐，不构成 DDR、综合、布局布线
或板级实时签核。
