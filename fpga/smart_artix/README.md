# Smart Artix

当前保留 Smart Artix 的可复用存储子系统：native SD asset loader、DDR3 MIG 适配、
read/write arbiter、line reader、debug access 和平台状态寄存器。

旧 `smart_artix_top` 已删除，因为它绑定旧 renderer/system wrapper。Vivado IP、引脚
约束和综合脚本仍保留，待新的 voice-major board top 接入后更新。

子系统仿真：

```bash
make smart-artix-test
```

新 top 必须验证：ordered line 多 outstanding/cache、loader/debug 有界仲裁、
renderer/effects/I2S timeline、underrun recovery、BRAM/DSP inference，以及 100 MHz
post-route timing。
