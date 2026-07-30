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
This interface is not used for voice configuration. In particular, the host
does not submit command words through the debug-only `CMD_FIFO_DATA` register.

## SPI Transactions

`Ch347RegisterTransport` implements both boundaries:

- normal register read/write frames for status, DDR diagnostics, and board
  control;
- opcode `0xa5` followed by consecutive big-endian command words for voice
  control.

The CH347 command API accepts one or more complete commands in a CS assertion,
up to the adapter buffer's 63-word transfer limit. It rejects empty vectors,
incomplete final commands, and headers above the command parser's 16-word
payload limit before opening a transfer. Current command producers still send
one command per CS. This host-side framing guard does not fix the FPGA bridge's
near-full-FIFO atomicity defect.

The register and command-stream timing limits are intentionally separate, but
neither has a released physical rating yet. The current host requests `1 MHz`
by default, which selects the CH347 `937.5 kHz` step. Bring-up then measures the
actual `1.875 MHz` and `3.75 MHz` steps; `7.5 MHz` is an upper stress point for
the present oversampling bridge. The former `15 MHz` write target is retained
only as a throughput-analysis point until CDC, I/O constraints, and hardware
measurements justify it. See
[`../design/spi_command_stream_throughput.md`](../design/spi_command_stream_throughput.md)
for the derivation, FIFO-capacity rule, CH347 transaction limit, and required
hardware stress test. Register transaction limits and wire throughput are
analyzed separately in
[`../design/spi_register_timing.md`](../design/spi_register_timing.md).
Only SPI mode 0 is accepted. Both host CLIs print the requested and selected
clock so dry runs and hardware runs use the same discrete-frequency policy.
Requests below the CH347 minimum `468.75 kHz` step are rejected rather than
silently selecting a faster clock.

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
