# Render Commands

## C++ Reference

纯 C++ MIDI/SF2 整数参考渲染：

```bash
make render-reference \
  SF2=assets/soundfonts/example.sf2 \
  MIDI=assets/midi/example.mid \
  SECONDS=10
```

常用参数包括 `START_SECONDS`、`SAMPLE_RATE`、`CONTROL_TICK_MS`、
`COMPRESSOR_ENABLE`、`EFFECTS_PRESET`、`CHORUS_ENABLE`、`REVERB_ENABLE` 和
`EFFECTS_TAIL_SECONDS`。输出写到 `build/render_reference/`。

## Production RTL With DDR3 Timing

当前 production mono-lane renderer、line cache 和 controller-level DDR3 模型的
长音频入口：

```bash
make render-rtl-ddr3 \
  SF2=assets/soundfonts/example.sf2 \
  MIDI=assets/midi/example.mid \
  START_SECONDS=10 \
  SECONDS=10
```

C++ 在运行时解析 SF2/MIDI、执行 MCU policy、voice allocation 和 WAV 写出；SV 负责
envelope、phase、cache、DSP、mix 和 DDR3 周期。输出默认写到
`build/render_rtl_ddr3/out.wav`。`RENDER_RTL_OUT_DIR` 可指定独立输出目录；
`RENDER_RTL_CACHE_SET_COUNT` 和 `RENDER_RTL_MSHR_DEPTH` 可用于 cache sweep。

该流程检查非零输出、DDR request/response 计数、deadline miss，并报告 cache、MSHR、
bank/row 和 refresh 统计。它不是 MIG pin model，也不替代 Vivado 时序和板级验证。

旧 `render-rtl-core`、`render-memory`、`render-board-loader` 和
`render-instrument` 依赖已删除 RTL，不再是有效命令。effects/compressor/I2S 尚未并入
这个 RTL 长渲染入口；与 C++ reference 的逐 sample comparison 也仍是后续验证项。
