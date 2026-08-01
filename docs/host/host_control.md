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
struct CommandWordView {
  const uint32_t* data() const;
  std::size_t size() const;
};

class CommandWordSink {
 public:
  virtual ~CommandWordSink() = default;
  virtual void write_command_words(CommandWordView words) = 0;
};
```

Producers build one `FixedCommand`, which contains a 17-word array and an
explicit length. The view is valid only for the duration of the sink call;
sinks that defer work copy it into bounded owned storage. Command construction
and insertion into `FrameBatchedCommandSink` perform no heap allocation. The
frame-batched queue has 1024 entries and reports overflow instead of growing.

`CommandVoiceControl` implements `VOICE_START_MONO`, independent gain and pitch
replacement, filter replacement, RELEASE, and STOP. `CommandFanout` sends identical words to
RTL and the C++ reference. No C++ voice-register adapter exists.

Global status and board control remain separate behind `host::RegisterIo`.
This interface is not used for voice configuration. In particular, the host
does not submit command words through the debug-only `CMD_FIFO_DATA` register.

## SPI Transactions

`Ch347RegisterTransport` implements both boundaries:

- single-register mailbox requests and retained responses for status, DDR
  diagnostics, and board control;
- an aligned four-byte command-transaction header `{0xa5, word_count, CRC16}`
  followed by consecutive big-endian command words for voice control.

The CH347 command API accepts one or more complete commands in a CS assertion,
up to the adapter buffer's 63-word transfer limit. It rejects empty vectors,
incomplete final commands, and headers above the command parser's 16-word
payload limit before opening a transfer. Current command producers still send
one command per CS. The host computes CRC-16/CCITT-FALSE with a table-driven
byte update over the word-count byte and all big-endian payload bytes. A
retained bit-at-a-time implementation is the independent unit-test oracle.
Command transactions are encoded directly into a fixed 256-byte buffer. The
FPGA wire layout always includes the CRC field; its `CHECK_COMMAND_CRC` build
parameter may disable comparison.

Each register API call first writes a fixed 12-byte request, then issues fixed
16-byte fetch transactions until the FPGA returns a completed response. Both
frames carry CRC32. The inherited `RegisterIo::write_registers` convenience
method performs independent single-register mailbox operations, and callers
read multiple addresses individually; there is no SPI register burst opcode.

The register and command-stream timing limits are intentionally separate, but
neither has a released physical rating yet. The current host requests `1 MHz`
by default, which selects the CH347 `937.5 kHz` step. Bring-up then measures the
actual `1.875 MHz` and `3.75 MHz` steps; `7.5 MHz` is an upper stress point for
the present oversampling bridge. The former `15 MHz` write target is retained
only as a throughput-analysis point until CDC, I/O constraints, and hardware
measurements justify it. See
[`../design/transport/spi_command_stream.md`](../design/transport/spi_command_stream.md)
for the derivation, FIFO-capacity rule, CH347 transaction limit, and required
hardware stress test. Register transaction limits and wire throughput are
analyzed separately in
[`../design/transport/spi_register_mailbox.md`](../design/transport/spi_register_mailbox.md).
Only SPI mode 0 is accepted. Both host CLIs print the requested and selected
clock so dry runs and hardware runs use the same discrete-frequency policy.
Requests below the CH347 minimum `468.75 kHz` step are rejected rather than
silently selecting a faster clock.

## Bounded MCU Control

`McuModel` keeps a dense active-voice array, so periodic ticks do not inspect
silent slots. Controller handlers select independent gain, pitch, and filter
dirty groups; channel updates walk only active voices on that channel. Periodic
gain and pitch updates default to every control tick, while filter modulation
defaults to every fourth tick. Event-driven filter changes remain immediate.

Pitch ratio uses a quarter-cent table with bounded interpolation, attenuation
uses an eighth-centibel table, and pan uses integer-pan factor tables. Filter
keys are quantized to one cent and two centibels and stored in a fixed
4096-entry direct-mapped cache keyed by cutoff, resonance, and sample rate. The
high-coverage unit sweep limits filter coefficient deviation from the original
floating-point formula to 96 Q2.14 LSB; the measured maximum is 89. Pitch phase
and attenuation are exact at their respective validation grids.

Control diagnostics report tick count, total and maximum tick nanoseconds,
current and maximum active voices, modulator evaluations, dirty-group
evaluations, and emitted commands. `make benchmark-mcu-control` runs the same
representative controller/modulator workload at 128, 256, and 512 active mono
voices after a warm-up interval.

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

It requires the exact current interface value `0x000d0000`, reads
platform/global and command-parser status through the CRC32 mailbox, exercises
the DDR debug aperture as acknowledged single-register operations, and sends
its voice smoke test through the same atomic `0xa5` command path as simulation.
The voice test is mono, waits for the command FIFO/parser to drain, checks for
new audio and parser errors, observes memory activity, and sends STOP before
returning. `--dry-run` executes the complete workflow against a synthetic ready
board while tracing every register and command transaction; it does not open
CH347.

The transport still requires board validation of SPI mode, maximum SCLK, CS
timing, read turnaround, and any pin-to-system-clock CDC implementation.
