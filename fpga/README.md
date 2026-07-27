# FPGA Integration

`fpga/` 保存 vendor/board 边界，不属于 generic renderer。

- `common/rtl`: SPI、register fabric、I2S、SD native 和 PCM 输出适配器。
- `smart_artix/rtl`: SD loader、MIG adapter、DDR arbiter/debug 和平台寄存器。
- `smart_artix/vivado/ip`: Smart Artix clock/MIG IP 配置。
- `smart_artix/vivado/scripts`: 保留的 Vivado 工程、综合、实现和报告脚本。

旧 `wavetable_system_core`、`wavetable_demo_system` 和 `smart_artix_top` 已随旧 renderer
删除。Vivado 脚本保留作为工程脚手架，但在新的 board top 接入前不能生成完整
bitstream。不要为让脚本暂时运行而恢复旧 renderer。

独立外围验证使用：

```bash
make test-rtl-peripheral
make smart-artix-test
```

新板级集成应把 `voice_major_render_core` 的 ordered line 接口接到 DDR cache/arbiter，
把 block mix drain 接到 effects/compressor/FIFO/I2S，并实现 SPI/host 到
`block_voice_event_t` 的适配。
