# Render Commands

当前只有纯 C++ MIDI/SF2 整数参考渲染是有效的长音频入口：

```bash
make render-reference \
  SF2=assets/soundfonts/example.sf2 \
  MIDI=assets/midi/example.mid \
  SECONDS=10
```

常用参数包括 `START_SECONDS`、`SAMPLE_RATE`、`CONTROL_TICK_MS`、
`COMPRESSOR_ENABLE`、`EFFECTS_PRESET`、`CHORUS_ENABLE`、`REVERB_ENABLE` 和
`EFFECTS_TAIL_SECONDS`。输出写到 `build/render_reference/`。

旧 `render-rtl-core`、`render-memory`、`render-board-loader` 和
`render-instrument` 依赖已删除 RTL，不再是有效命令。新的 RTL 长渲染入口必须驱动
`voice_major_render_core` 的 timestamped event、ordered line memory 与 block output，
并在 effects/compressor/I2S 接入后做逐 sample comparison。
