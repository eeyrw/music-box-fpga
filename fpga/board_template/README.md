# Board Template

Copy this directory to `fpga/<board-name>/` and replace every template value with
the selected board details.

## Board Facts To Fill In

- Board name:
- FPGA part/package/speed grade:
- Toolchain and version:
- Input oscillator frequency:
- Required core clock frequency:
- Audio output device:
- Audio master clock requirement:
- Control interface:
- Wave-memory device:
- Memory bus width and clocking:
- Reset source and polarity:
- I/O bank voltages:

## Integration Decisions

- Top-level module name:
- Core wrapper used: `wavetable_render_core`, `wavetable_line_memory_core`, or
  `wavetable_spi_audio_system`
- Clock generation method:
- Reset sequencing method:
- SPI mode and maximum SCLK:
- Memory image format:
- Codec configuration method:
- Host/MCU/soft-core control path:

## Bring-Up Order

1. Build a bitstream with only clock/reset and simple pin toggles.
2. Add I2S clocks and verify BCLK/LRCLK frequency on hardware.
3. Add a tiny BRAM-backed waveform source and play a fixed tone.
4. Add SPI register programming and commit one voice from the host.
5. Add the selected external memory controller.
6. Load a preprocessed wave-memory image and verify readback or checksum.
7. Run one-voice audio, then increase polyphony while watching underruns.
8. Run a longer MIDI/SF2-derived stress case through the real memory path.

## Pass Criteria

- Timing closes at the selected system clock.
- Reset exits cleanly and deterministically.
- SPI register writes and reads match `docs/register_map.md`.
- I2S BCLK/LRCLK/data format matches the attached DAC or codec.
- Memory line reads return correct signed 16-bit PCM words.
- `underrun_pulse` is absent after startup.
- `sample_drop_pulse` remains low during steady-state playback.
