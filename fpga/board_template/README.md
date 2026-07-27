# Board Template

复制到 `fpga/<board-name>/` 后填写器件、时钟、复位、引脚、电压、memory 与 audio
信息。Vivado、Quartus 和 Yosys 脚本模板均保留。

当前 `filelist.f` 指向 voice-major RTL；`board_top.sv.template` 只是可编译的 IO/clock
smoke scaffold，不是完整 synthesizer。新 board top 需要完成：

1. PLL/MMCM 与同步复位；
2. SPI/host command 到 `block_voice_event_t` 的适配；
3. ordered line DDR cache/arbiter；
4. block drain、effects、compressor、PCM FIFO 和 I2S；
5. underrun/fault/status；
6. synthesis、post-route timing 和硬件验证。

不要恢复旧 `wavetable_demo_system` 来填补这些边界。
