# Voice-Major 渲染流水线入门导读

本文从 FPGA 初学者的角度解释当前硬件到底做了什么。重点不是某个模块的代码，
而是数据为什么能在多个阶段同时流动，以及哪些结论仍然只是仿真结果。

## 1. 先算实时预算

系统时钟 100 MHz、音频 48 kHz 时，每个输出 frame 约有 2083 clocks。当前一次渲染
8 frames，所以保守期限为：

```text
100,000,000 * 8 / 48,000 = 16666 clocks
```

256 条 mono lane 是基本目标，512 条是扩展目标。一条 lane 读一个 mono 波表，但有
独立的左右 gain；立体声 SoundFont 由软件分配两条普通 lane。

## 2. 流水线不是“把模块画成很多方框”

真正的流水线要求不同工作能同时占据不同级。例如同一时刻可以是：

```text
controller 读取 voice H 的状态
envelope 处理 voice G 的 frame 3
phase      处理 voice F 的 frame 5
memory     连续读取 voice E 的 segment
DSP S0     接收 voice D 的 sample
DSP S4     计算 voice C 的滤波反馈
retire     写回 voice B 的贡献和状态
effects    处理上一个已完成 block
```

如果必须等一个 voice 完整走完所有步骤才开始下一个，这些方框再多也不是高吞吐
流水线。当前设计已经删除这种串行所有权。

## 3. 为什么使用 8 个 slot

slot 是小型“在途记录”，不是计算引擎。一个 renderer slot 保存一条 voice 的：

- block 描述和 phase/filter 状态；
- 最多 8 个 endpoint job；
- 已返回的 sample 和 valid 位；
- 已规划、已发射、是否等待反馈等进度。

只有一套 envelope 算术、一套 phase 算术、一套 memory request engine 和一套重 DSP。
各级每拍从 8 个 slot 中选择一个可运行项，并让 token 带 3-bit slot tag 向后流动。

8 是二进制规整的窗口，也大于滤波状态约 5 拍的反馈距离。它的作用类似 CPU 的
硬件线程：A 因 RAW dependency 暂停时，让 B、C、D 使用流水线，而不是复制 ALU。

## 4. 内存顺序和 DSP 顺序不同

DDR 和许多 SRAM/Flash 都喜欢连续地址，所以外部访问保持 voice-major：

```text
voice A: base+0, base+8, base+16, base+24
voice B: base+0, base+8, base+16, base+24
```

一个 32-word segment 的四条 8-word line 发完前不会切换 voice。内部 endpoint-valid
scoreboard 记录哪些插值端点已返回。一帧的两个端点齐全后，它就可以参加 DSP 调度，
不再经过额外的 replay FSM。

DSP 侧则按 ready slot 交错：

```text
A0 B0 C0 D0 E0 F0 ... A1 B1 C1 ...
```

因此连续 memory locality 和逐 sample DSP 吞吐可以同时得到，不需要把 DDR 请求也
打散成随机访问。

## 5. phase 和 envelope 也需要交错

旧 envelope walker 对 8 帧递归更新后，还要等待 4 级电平换算流水排空，导致一个
block 约每 13 拍才能进入后级。新 `block_interleaved_envelope_frontend` 让一套电平
流水携带 `{slot, frame, last}` tag；旧 block 排空时，新 block 已经在更新状态。

renderer 中的 phase 也采用 round-robin slot 调度。一套 `mono_phase_frame` 每拍推进
一个 slot，产生 `frame_0/frame_1/fraction`。不同 voice 独立，所以可以交错；同一
voice 的 phase 和 envelope 仍严格按 frame 顺序更新。

## 6. DSP 的 RAW hazard 怎么处理

二阶滤波器有真实递归依赖：

```text
y[n]     = b0*x[n] + z1[n]
z1[n+1]  = b1*x[n] - a1*y[n] + z2[n]
z2[n+1]  = b2*x[n] - a2*y[n]
```

某 slot 发射 filtered sample 后设置 hazard。调度器暂时跳过它，选择其他 slot。DSP
产生带 tag 的新 `z1/z2` 时清除 hazard；如果同拍再次选择该 slot，输入 token 直接
使用 forwarding bus 上的新状态。这与 CPU 的 scoreboard 和 bypass 是同一种思想。

`block_interleaved_voice_dsp` 本身约有 8 个寄存级，覆盖插值、biquad 乘加、左右
gain、envelope、饱和和 retire。不同级同时处理不同 token，backpressure 时所有 valid
和 payload 一起冻结。

## 7. 状态写回是什么

phase、envelope 和滤波 `z1/z2` 都会跨 block 延续。最后一个 sample 退休后，tag 找回
所属 voice，把最终动态状态写回集中 state store。下一个音频 block 再从这里继续。
配置参数和动态状态分开保存，generation 防止旧工作写坏已经重新分配的 voice。

每个 contribution 携带 `frame_index`，所以不同 voice 即使交错退休，也能加到正确的
宽累加器。中途不逐 voice 饱和，发布 block 时才缩位，整数结果不依赖 voice 到达顺序。

## 8. 当前实际数据

理想 ordered memory、8 frames：

| lanes | filter off | filter on | deadline |
| ---: | ---: | ---: | ---: |
| 256 | 2149 | 2191 | 16666 |
| 512 | 4197 | 4258 | 16666 |

256 filtered 精确发射/退休 2048 个 sample，最长连续 312 clocks 每拍发射一个 sample；
512 filtered 精确处理 4096 个 sample，也出现 312-clock 连续区段。filter on/off 已经
接近，说明递归 hazard 不再决定总吞吐。

这仍不是 DDR 签核。测试 memory 每拍可接收请求，并在下一拍有序返回。真实 DDR3
还有 row、refresh、仲裁和随机 stall；Vivado 也尚未验证 slot array 是否推断为合适
BRAM、乘法是否进入 DSP48、组合选择树是否满足 100 MHz。

## 9. effects 怎样并行

目标不是 renderer 做完后全系统停住等 effects，而是：

```text
renderer 填 block N
effects 处理 block N-1
compressor/FIFO 处理 block N-2
I2S 播放更早的 frame
```

同一 effects block 中，dry、chorus、reverb 在没有连接依赖时可以 fork/join。若
chorus 输出发送到 reverb，该边必须保持顺序。delay、FDN、compressor 等带历史状态
的效果器可以多级流水，但同一流的相邻 frame 仍有 RAW dependency，也要使用明确的
调度/forwarding 或保持顺序。

## 10. 建议阅读顺序

1. `rtl/pkg/synth_pkg.sv`：宽度、slot tag 和 token 类型。
2. `rtl/voice/block_interleaved_envelope_frontend.sv`：带 tag 的共享 envelope 流水。
3. `rtl/voice/block_interleaved_voice_renderer.sv`：phase、segment、scoreboard 和 issue。
4. `rtl/dsp/block_interleaved_voice_dsp.sv`：真实多级定点 DSP。
5. `rtl/voice/voice_major_block_controller.sv`：state prefetch、outstanding 和 writeback。
6. `sim/tb/tb_voice_major_throughput.sv`：deadline、连续 line、hazard 和 issue 统计。
7. `docs/design/voice_major_block_renderer_handoff.md`：验证状态和下一步工作。

下一阶段最重要的是带真实 memory stall 的统计、早期综合，以及把 mix/effects/I2S
接成持续运行的整机流水，而不是继续增加 slot 或复制 DSP。
