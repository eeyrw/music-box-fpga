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
This interface is not used for voice configuration; version 14 has no
register-based command submission path.

## SPI Transactions

`Ch347RegisterTransport` implements both boundaries:

- single-register mailbox requests and retained responses for status, DDR
  diagnostics, and board control;
- an aligned four-byte command-transaction header `{0xa5, word_count, CRC16}`
  followed by consecutive big-endian command words for voice control.

The CH347 command API accepts one or more complete commands in a CS assertion,
up to the adapter buffer's 63-word transfer limit. `AsyncCommandScheduler`
combines queued commands up to that limit without splitting a command. It rejects empty vectors,
incomplete final commands, and headers above the command parser's 16-word
payload limit before opening a transfer. The host computes CRC-16/CCITT-FALSE with a table-driven
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

## Asynchronous Command Scheduling

`AsyncCommandScheduler` is the only owner of the blocking command transport.
The MIDI/control thread copies complete fixed commands into bounded storage and
never calls the CH347 driver. START, RELEASE, STOP, and FLUSH use a 2048-entry
lifecycle queue. Other nonreplaceable commands use a 512-entry queue. Gain,
pitch, and filter updates use one replaceable slot per voice and command kind;
the newest matching voice generation replaces the older unsent value.

A producer batch prevents the worker from observing a partially constructed
group, so all layers of one Note On are inserted together and linked-stereo
mono starts remain adjacent. Transactions contain at most 63 words. A failed
driver call retries the identical transaction after 1 ms. One hundred
consecutive failures cause the real-time application to stop accepting input,
queue All Sound Off, and shut down. Commands that still cannot be delivered at
shutdown are reported by `abandoned_commands`; they are never reported as
successfully emitted.

Queue depth/high-water, replacement coalescing and invalidation, transaction
size, driver duration, command age, transient errors, consecutive errors, and
abandoned commands are recorded. `DryRunCommandTransport` uses the same worker,
priorities, batching, retry, and transaction coalescer without opening CH347.

## Real-Time MIDI Host

`realtime_midi_host` supports two mutually exclusive sources. `--midi-input`
opens a Linux raw-MIDI character device such as `/dev/snd/midiC0D0`, and
`--midi-input -` reads a raw byte stream from standard input. `--midi-file`
loads a Standard MIDI File (format 0 or 1 with PPQ timing) and plays its merged
channel events against the monotonic wall clock using the file's tempo map.
When neither option is present, the raw-MIDI default remains
`/dev/snd/midiC0D0`.

Both sources feed the same 2048-event queue with a 256-event lifecycle reserve.
The raw input thread decodes running status and channel messages. File parsing
and tempo conversion finish before its playback clock starts; the main control
loop releases all events due at each iteration while preserving source order
for equal timestamps. Note Off and MIDI mode recovery events can consume the
reserve. Replaceable control events coalesce under pressure, Note On is
explicitly rejected once the normal capacity is exhausted, and lifecycle
exhaustion triggers controlled shutdown.

The host still does not open an ALSA Sequencer port. `aplay` plays PCM and cannot
send MIDI; `aplaymidi` sends an SMF file to an ALSA Sequencer destination and
therefore cannot target `--midi-input` directly. Pass that SMF directly through
`--midi-file`, or use a physical or virtual raw-MIDI device that exposes
`/dev/snd/midiC*D*`. A Sequencer-only `Midi Through` port is not a raw device
path.

Raw-MIDI supplies no event timestamp in this interface. The host captures a
monotonic ingress timestamp immediately after each `read(2)` and preserves the
timestamp assigned when the message's final byte arrives through the event
queue. Commands have no target-frame field: after the SPI worker delivers a
transaction, its state becomes visible at the next command admission and FPGA
render-block boundary. Reported `note_on_enqueue_*` is ingress-to-command-queue
latency for raw input and due-time-to-command-queue latency for file playback;
`maximum_command_age_ns` includes scheduler and driver delay.

Without `--mcu-asset`, the complete SF2 file is loaded and its dynamic lookup is
built before the MIDI device is opened. One process-lifetime
`CommandVoiceControl` preserves voice generations, while `McuModel` supplies
the allocation, pedal, exclusive-class, pitch-bend, pressure, and controller
behavior used by the simulation harness.

With `--mcu-asset PATH`, the host instead uses the offline-compiled direct
dispatch image and fixed-capacity MCU runtime. The sidecar is loaded and fully
validated before the command scheduler starts. Startup fails closed unless its
recorded SF2 byte size and CRC match the `--sf2` file; malformed section bounds,
references, or profile fields are also rejected. The complete SF2 is currently
still parsed by this host application solely to perform the source identity
check. A board integration may validate the same identity from its WTSF bundle
manifest without parsing SF2 metadata. In either mode, the exact wave image
referenced by the control metadata must already be present in FPGA-visible
storage.

Build and run the application with:

```bash
make host-realtime-midi

# Configure the hardware output chain before live playback. This defaults to
# 0 dB master gain, the -2 dBFS, 4:1 compressor, and the musical hall reverb.
python3 tools/configure_audio_effects.py --device 1

# Apply 6 dB of global attenuation while retaining the default effects.
python3 tools/configure_audio_effects.py --device 1 --master-db -6

# Exercise the complete scheduling path without CH347 hardware.
build/realtime_midi_host --dry-run --midi-input /dev/snd/midiC0D0 \
  --sf2 /path/to/soundfont.sf2

# Play an SMF in real time, then leave one second for release tails.
build/realtime_midi_host --dry-run --midi-file /path/to/song.mid \
  --midi-tail-ms 1000 --sf2 /path/to/soundfont.sf2

# Current SGM development workload.
build/realtime_midi_host --dry-run --midi-input /dev/snd/midiC0D0 \
  --sf2 '/home/yuan/下载/SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2' \
  --mcu-asset build/assets/sgm-gm-bank0.msf2
```

SMF playback exits automatically after its final event plus `--midi-tail-ms`
(default 1000 ms); `--run-ms` remains an optional hard process-duration limit.
SIGINT, SIGTERM, MIDI disconnect, lifecycle overflow, and persistent CH347
failure all stop input first, issue All Sound Off on every channel, wait up to
two seconds for the command queue, and report final JSON statistics. The report
identifies the source and file completion counts in addition to Note On latency,
control scheduling jitter, MIDI and command queue high-water marks, transport
failures, current/maximum active voices, voice steals, compiled-path selection,
and region-cache activity.

On 2026-08-01, a dry-run C4 Note On/Off using the 324,800,670-byte SGM workload
selected four layers, reached four active voices and a 63-word transaction,
then drained with no transport errors or abandoned commands. Ingress-to-command
enqueue latency for that single cold lookup was 1,146,115 ns. This is a
functional development-container measurement, not target-PC or physical-USB
qualification.

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

## Python CH347 Test Tool

`tools/ch347_tool.py` is the scripting-oriented board-debug entry point. It
uses Python `ctypes` to call the vendor's official
`third_party/ch347_linux/lib/x64/libch347.so` directly; it does not wrap or
launch the C++ host. The reusable binding and protocol implementation lives in
`tools/ch347_transport.py`. It mirrors the production CRC32 register mailbox,
CRC16 command framing, CH347 clock-step selection, and 16-byte DDR debug
aperture sequencing.

The default device value `auto` accepts exactly one `/dev/ch34x_pis*` node.
Select an index or path explicitly when more than one adapter is attached.
The default SPI request is 30 MHz, mode 0, CS1 (`0x80`):

```bash
python3 tools/ch347_tool.py info
python3 tools/ch347_tool.py read VERSION PLATFORM_STATUS EFFECT_STATUS
python3 tools/ch347_tool.py snapshot --group all --json
python3 tools/ch347_tool.py snapshot --group cache \
  --output build/ch347/cache_snapshot.json
python3 tools/ch347_tool.py clear-diagnostics --verify
```

`tools/configure_audio_effects.py` sends the compressor, master-volume, and
reverb configurations in one command transaction. Its defaults enable the
compressor at a 20 cB (-2 dBFS) threshold, 4:1 ratio, 0 ms attack, and 5000 ms
release; set master gain to 0 dB; and select the `hall` reverb preset. Master
gain accepts `-120..0` dB. Reverb choices are `off`, `studio`, `hall`, and
`reverb-max`; compressor state is selected with `--compressor on|off`.
`--dry-run` prints the encoded command words and transaction without opening a
CH347 device. Hardware runs read back the compressor and reverb enable status
and reject a reverb configuration that the RTL reports as clamped. The current
register interface has no master-volume readback field.

Register operands accept names from `spec/register_map.json` or numeric
addresses. Snapshot JSON includes raw address/value pairs and decoded named
fields so test records remain machine-readable without duplicating the register
map in Python.

DDR reads operate in consecutive 16-byte MIG beats. With `--output`, raw bytes
are written in DDR byte-address order and can be compared directly with an SF2
or WTSF payload:

```bash
python3 tools/ch347_tool.py ddr-read 0x0 --beats 256 \
  --output build/ch347/ddr_0_4k.bin
python3 tools/ch347_tool.py ddr-verify /path/to/soundfont.sf2 \
  --samples 128 --seed 1
```

The read command reports elapsed time and effective payload KiB/s. `ddr-verify`
always includes the first and last complete beat in the selected span, then
uses the supplied seed for reproducible pseudo-random samples. A mismatch exits
with status 2 and prints up to eight expected/actual beats. Use `--ddr-address`,
`--file-offset`, and `--length` when the file is not mapped at DDR byte zero.

`ddr-write` changes live wave memory and is intentionally a separate,
explicit command. It accepts four 32-bit lane words plus an optional 16-bit
byte-enable mask. `command` is also low level: its arguments must contain one
or more complete command records, because the tool validates but does not
invent missing payload words.

Run the protocol and DDR-sequencing unit tests without hardware using:

```bash
make test-ch347-python
```

## Smart Artix Bring-Up

Build the board runner with:

```bash
make host-smart-artix-bringup
```

It requires the exact current interface value `0x000e0000`, reads
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
