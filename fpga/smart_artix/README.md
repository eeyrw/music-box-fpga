# Smart Artix

当前保留 Smart Artix 的可复用存储子系统：native SD asset loader、DDR3 MIG 适配、
read/write arbiter、line reader、debug access 和平台状态寄存器。

旧 `smart_artix_top` 已删除，因为它绑定旧 renderer/system wrapper。Vivado IP、引脚
约束和综合脚本仍保留，待新的 voice-major board top 接入后更新。

`rtl/smart_artix_voice_major_synth_top.sv` 是综合检查 harness：它把 voice-major cache
通过 ordered-line adapter 接到 line reader、arbiter、loader 和真实 MIG，并让 generic
core 使用 MIG `ui_clk`。它直接导出 raw core control 接口以阻止综合常量折叠，因此 I/O
数量超过器件能力，不是最终板级 top，也不能直接生成 bitstream。综合入口：

```bash
/opt/Xilinx2051.1/2025.2/Vivado/bin/vivado -mode batch \
  -source fpga/smart_artix/vivado/scripts/render_core_synth.tcl
```

综合后可单独重跑全层级 setup 和 high-fanout 分析：

```bash
/opt/Xilinx2051.1/2025.2/Vivado/bin/vivado -mode batch \
  -source fpga/smart_artix/vivado/scripts/render_core_post_synth_analysis.tcl
```

子系统仿真：

```bash
make smart-artix-test
```

新 top 必须验证：ordered line 多 outstanding/cache、loader/debug 有界仲裁、
renderer/effects/I2S timeline、underrun recovery、BRAM/DSP inference，以及 100 MHz
post-route timing。
