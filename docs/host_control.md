# Host Control And CH347 Integration

The project now treats the MCU-side policy as host-side C++ that can run either
inside a simulation harness or in a PC tool connected through USB-to-SPI hardware
such as CH347.

## Reusable C++ Layers

The simulation harness already contains reusable control-side code under
`sim/harness/`:

- `midi_parser.*`: parses MIDI events and converts them to timed note events.
- `sf2_loader.*`: extracts SoundFont regions and builds the wave-memory image.
- `render_support.*`: contains `McuModel`, which owns voice allocation, note on,
  note off, ADSR stepping, and region selection for the current render path.
- `register_control.*`: converts voice-control operations into register writes.

`register_control.*` is the boundary intended for real hardware transport. It
defines:

```cpp
class RegisterWriteSink {
 public:
  virtual ~RegisterWriteSink() = default;
  virtual void write_register(uint16_t address, uint32_t data) = 0;
};
```

`RegisterVoiceControl` implements the documented voice register sequence on top
of that interface. The Verilator bus harness, full-system SPI harness, and future
CH347 host tool should all share this class so that note setup, envelope updates,
release handling, and commit ordering stay identical.

## CH347 Transport Shape

The repository includes a CH347-backed implementation in `host/ch347_transport.*`
and a command-line tool in `host/ch347_control_main.cpp`. Build it with:

```bash
make host-ch347
```

The binary is written to `build/ch347_control`. It loads the WCH CH347 shared
library at runtime, so it can compile on a machine that does not currently have
the device library installed. Use `--lib` if the library is not in the dynamic
loader search path.

Examples:

```bash
# Print the SPI frame without opening hardware.
build/ch347_control --dry-run --write 0x3000 0

# Write one register through CH347 device 0.
build/ch347_control --lib /usr/local/lib/libch347.so --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --write 0x3000 0

# Program and commit voice 0 from command-line region parameters.
build/ch347_control --dry-run \
  --set-envelope 0 0 \
  --commit-voice 0 --enable 1 --stereo 0 --base 0 --length 1024 \
  --loop-start 0 --loop-end 1024 --loop-mode 1 \
  --phase-inc 0x00000100 --gain-l 0x4000 --gain-r 0x4000
```

For stereo regions, pass `--base` for the left sample and `--base-r` for the
right sample.

`Ch347RegisterTransport::write_register` emits the SPI frame documented in
`docs/register_map.md`:

```text
command byte: 0x80 for write
address:      16-bit byte address, most-significant byte first
data:         32-bit data, most-significant byte first
```

The current RTL transport is intentionally simple and simulation-friendly. Before
using CH347 against hardware, the board-level SPI contract still needs to define:

- SPI mode, clock polarity, and clock phase.
- Maximum SCLK relative to the FPGA system clock.
- CS setup and hold requirements.
- MISO turnaround timing for reads.
- Whether the board wrapper synchronizes SPI pins into the FPGA clock domain.

## Suggested Host Tool Split

Keep hardware and policy code separate:

- `host/ch347_transport.*`: CH347 open/configure/close and SPI frame writes.
- `host/ch347_control_main.cpp`: low-level register, envelope, release, and voice
  commit commands for board bring-up.
- Future `host/wave_image.*`: generated wave-memory image loading or Flash
  programming.
- Future real-time host app: MIDI/SF2 loading, event scheduling, and calls into
  `McuModel`.

The current command-line tool is intentionally low-level. A later real-time host
app can reuse `McuModel`, `RegisterVoiceControl`, and `Ch347RegisterTransport`
once it has a scheduler and a board asset-loading flow.
