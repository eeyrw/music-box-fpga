# WaveTable Synth FPGA 项目设计书（V1.0）

## 1. 项目目标

构建一个工业级架构的开源 WaveTable Synth Core。

### V1 功能

  项目            规格
  --------------- --------------------------------
  Polyphony       32 Voice
  Sample Rate     48 kHz
  Sample Format   16-bit PCM
  Output          Stereo I2S
  Wave Storage    Parallel NOR Flash
  MCU             MIDI、Voice Manager、ADSR、LFO
  FPGA            Sample Playback Engine
  MCU Interface   SPI

V1 不实现：

-   Reverb
-   Chorus
-   Filter
-   Pitch Envelope
-   DSP Effects

------------------------------------------------------------------------

## 2. 总体架构

``` text
MIDI
 │
 ▼
MCU
 ├─ MIDI Parser
 ├─ Voice Allocate
 ├─ ADSR/LFO
 └─ SPI Master
        │
        ▼
+---------------------------+
| FPGA                      |
|---------------------------|
| SPI Bridge                |
| Register Bus              |
| Shadow Register           |
| Commit Engine             |
| Voice Scheduler           |
| Flash Scheduler           |
| Interpolator              |
| Mixer                     |
| I2S TX                    |
+---------------------------+
      │            │
 Parallel NOR    Audio DAC
      │            ▲
      └────I2S─────┘
```

------------------------------------------------------------------------

## 3. 设计原则

-   FPGA 负责实时音频
-   MCU 负责控制逻辑
-   Synth Core 与 MCU 接口解耦
-   SPI 只是 Register Bus Bridge
-   全部 RTL 可综合
-   Golden Model 优先

------------------------------------------------------------------------

## 4. 模块划分

### Core

-   phase_accumulator
-   voice_scheduler
-   multi_voice_pipeline
-   interpolator
-   mixer

### Memory

-   flash_scheduler
-   flash_prefetch
-   cache（后续）

### Bus

-   register_bus
-   decoder
-   register_bank

### Peripheral

-   spi_slave
-   i2s_tx
-   debug_uart

### Common

-   fifo
-   cdc_sync
-   edge_detect
-   counter

------------------------------------------------------------------------

## 5. 推荐目录

``` text
wavetable-synth/

├── rtl/
│   ├── pkg/
│   ├── common/
│   ├── bus/
│   ├── control/
│   ├── voice/
│   ├── memory/
│   ├── dsp/
│   ├── interface/
│   └── top/
│
├── sim/
│   ├── tb/
│   ├── models/
│   ├── wave/
│   ├── expected/
│   └── scripts/
│
├── reference/
├── tests/
├── docs/
├── tools/
├── fpga/
└── .github/workflows/
```

`fpga/` 保存板级工程、约束、综合脚本、资产镜像说明和 bring-up 记录；通用可综合 RTL 仍放在
`rtl/`，不要把供应商 IP 或板卡专用约束混入通用核心目录。

------------------------------------------------------------------------

## 6. 工具链

  分类           工具
  -------------- ------------------------------
  HDL            SystemVerilog
  仿真           Verilator
  波形           GTKWave
  Golden Model   Python + NumPy
  Testbench      cocotb
  自动测试       pytest
  Lint           Verible + Verilator
  Format         Verible-format
  Build          Make
  CI             GitHub Actions
  编辑器         VS Code
  综合           Vivado / Gowin IDE / Radiant

------------------------------------------------------------------------

## 7. Register Bus

SPI 只负责桥接：

``` text
SPI
 ↓
SPI Bridge
 ↓
Register Bus
 ↓
Modules
```

Bus 字段：

-   valid
-   write
-   address
-   data
-   ready

------------------------------------------------------------------------

## 8. Register 架构

``` text
MCU
 ↓
Shadow Register
 ↓
Commit
 ↓
Active Register
 ↓
Runtime State
```

MCU 永远不能修改 Runtime State。

------------------------------------------------------------------------

## 9. Memory Map

``` text
0x0000 Global
0x0100 Voice0
0x0200 Voice1
...
0x1000 Mixer
0x2000 Debug
0x3000 Version
```

全部采用 32-bit 对齐。

------------------------------------------------------------------------

## 10. Simulation

``` text
Python Golden Model
        │
        ▼
 RTL (Verilator)
        │
        ▼
 Compare Output
        │
        ▼
 PASS / FAIL
```

Behavior Models：

-   NOR Flash
-   I2S Receiver
-   FIFO
-   Clock Generator

------------------------------------------------------------------------

## 11. 开发路线

  阶段   内容
  ------ ----------------------
  M0     工具链、CI、代码规范
  M1     Register Bus + SPI
  M2     Phase Accumulator
  M3     Flash Model
  M4     Interpolator
  M5     Mixer
  M6     I2S
  M7     FPGA 上板
  M8     Cache 与优化

------------------------------------------------------------------------

## 12. Coding Standard

-   使用 SystemVerilog
-   always_ff / always_comb
-   logic 代替 reg/wire
-   参数化设计
-   RTL/Testbench 分离
-   每个模块必须有测试
-   每次修改必须通过回归测试
-   综合结果定期检查

------------------------------------------------------------------------

## 13. 长期目标

V2： - Cubic Interpolation - Prefetch Cache

V3： - FPGA ADSR - FPGA LFO - Digital Filter

V4： - Reverb - Chorus - Delay

V5： - SoundFont (.sf2) 支持 - 完整硬件音源平台
