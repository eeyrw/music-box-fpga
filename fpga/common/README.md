# Common FPGA RTL

这里仅保留可独立复用的板级外围：fractional tick、SPI register bridge、register
fabric/status、I2S、SD native reader/PHY 和 `wavetable_i2s_output`。

旧 renderer 的 system/demo wrapper 已删除。当前 common RTL 不构成完整 synthesizer
top；新 wrapper 应围绕 `voice_major_render_core`、effects graph 和 ordered line memory
重新设计。

相关 focused TB 由 `make test-rtl-peripheral` 运行。
