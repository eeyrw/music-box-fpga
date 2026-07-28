# Host Control And CH347 Integration

The host owns MIDI/SF2 parsing, voice allocation, modulation policy, and
conversion to the fixed-point command fields. The FPGA owns active mono voice
state, the per-sample volume envelope, rendering, and audio scheduling.

## Reusable C++ Layers

- `formats/midi_parser.*`: MIDI parsing and ordered control events.
- `formats/sf2_loader.*`: SoundFont region extraction and wave-memory image
  construction.
- `render/render_support.*`: MCU policy, allocation, controllers, modulators,
  and command decisions.
- `control/command_control.*`: transactional voice command construction.
- `render/reference_synth.*`: integer reference that consumes the same command
  words as RTL.

`CommandWordSink` is the transport boundary:

```cpp
class CommandWordSink {
 public:
  virtual ~CommandWordSink() = default;
  virtual void write_command_words(const std::vector<uint32_t>& words) = 0;
};
```

`CommandVoiceControl` implements `VOICE_START_MONO`, independent gain and pitch
replacement, filter replacement, RELEASE, and STOP. `CommandFanout` sends identical words to
RTL and the C++ reference. No C++ voice-register adapter exists.

Global status and board control remain separate behind `host::RegisterIo`.
This interface is not used for voice configuration.

## SPI Transactions

`Ch347RegisterTransport` implements both boundaries:

- normal register read/write frames for status, asset loading, and board debug;
- opcode `0xa5` followed by consecutive big-endian command words for voice
  control.

The register and command-stream timing limits are intentionally separate. The
current command-stream workload model selects `15 MHz` as the physical
validation target and `7.5 MHz` as its fallback; register reads retain the
conservative board bring-up sequence because MISO turnaround is more
restrictive. See
[`../design/spi_command_stream_throughput.md`](../design/spi_command_stream_throughput.md)
for the derivation, FIFO-capacity rule, CH347 transaction limit, and required
hardware stress test. Register transaction limits and wire throughput are
analyzed separately in
[`../design/spi_register_timing.md`](../design/spi_register_timing.md).

Build the low-level tool with:

```bash
make host-ch347
```

Examples:

```bash
# Inspect a global register without opening hardware.
build/ch347_control --dry-run --read 0x9000

# Emit one complete mono START command.
build/ch347_control --dry-run \
  --start-voice 0 --base 0x1000 --length 48000 \
  --loop-start 0 --loop-end 48000 --loop-mode 1 \
  --phase-inc 0x100 --gain-l 0x4000 --gain-r 0x4000

# Start and release in one session so the command builder owns the sequence.
build/ch347_control --dry-run \
  --start-voice 0 --base 0x1000 --length 48000 --phase-inc 0x100 \
  --release 0
```

`phase-inc` is unsigned Q24.8; `0x100` is one sample frame per output frame.
`--stop-voice` stops an active voice immediately. `--release` enters the FPGA
release stage. The standalone low-level CLI keeps sequence state only for its
own process lifetime; a real-time application must retain one
`CommandVoiceControl` instance.

## Smart Artix Bring-Up

Build the board runner with:

```bash
make host-smart-artix-bringup
```

It reads platform/global status through `RegisterIo`, exercises the DDR debug
aperture, and sends its voice smoke test through the same `0xa5` command path as
simulation. `--dry-run` prints both transaction classes without opening CH347.

The transport still requires board validation of SPI mode, maximum SCLK, CS
timing, read turnaround, and any pin-to-system-clock CDC implementation.
