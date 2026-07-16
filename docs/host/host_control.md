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

The binary is written to `build/ch347_control`. It loads the copied WCH CH347
shared library from `third_party/ch347_linux/lib/x64/libch347.so` by default, so
it can compile without linking against the vendor library. Use `--lib` to point
at a different architecture or system-installed library. The matching WCH
`ch34x_pis` kernel driver source is copied under `third_party/ch347_linux/driver`;
see `third_party/ch347_linux/README.md` for manual build and load commands.

Examples:

```bash
# Print SPI frames without opening hardware.
build/ch347_control --dry-run --write 0x3000 0
build/ch347_control --dry-run --read 0x3000

# Read VERSION through CH347 device 0.
build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --read 0x3000

# The Linux SDK also accepts explicit device paths.
build/ch347_control --device /dev/ch34x_pis0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --read 0x3000

# Write one register through CH347 device 0.
build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --write 0x3014 0x3f

# Read the SD asset-load byte progress from the platform SPI registers.
build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --read-load-progress

# Print the SPI register sequence for one 16-byte DDR debug write.
build/ch347_control --dry-run \
  --ddr-byte-enable 0xffff \
  --ddr-write 0x00000100 0x01234567 0x89abcdef 0x76543210 0xfedcba98

# Read one 16-byte DDR debug beat through CH347 device 0.
build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --ddr-read 0x00000100

# Program and commit voice 0 from command-line region parameters.
build/ch347_control --dry-run \
  --set-envelope 0 0 \
  --commit-voice 0 --enable 1 --stereo 0 --base 0 --length 1024 \
  --loop-start 0 --loop-end 1024 --loop-mode 1 \
  --phase-inc 0x00000100 --gain-l 0x4000 --gain-r 0x4000
```

For stereo regions, pass `--base` for the left sample and `--base-r` for the
right sample. If the right sample header has different bounds, also pass
`--length-r`, `--loop-start-r`, and `--loop-end-r`; otherwise the tool mirrors the
left-channel values.

`Ch347RegisterTransport` emits the SPI frames documented in
`../register_map.md`. Writes use:

```text
command byte: 0x80 for write
address:      16-bit byte address, most-significant byte first
data:         32-bit data, most-significant byte first
```

Reads use the Linux SDK signature
`CH347SPI_WriteRead(fd, false, chip_select, length, buffer)` so the
command/address phase and 32 returned data bits remain in one CS assertion:

```text
command byte: 0x00 for read
address:      16-bit byte address, most-significant byte first
data clocks:  32-bit readback, most-significant bit first on MISO
```

Most per-voice configuration registers are write-dominant and read back as zero
through their normal addresses. Use `READBACK_ADDR` and `READBACK_DATA` from
`../register_map.md` when inspecting per-voice shadow or runtime state.

The command-line tool also wraps the Smart Artix DDR debug register window:

```bash
build/ch347_control --ddr-write ADDR D0 D1 D2 D3
build/ch347_control --ddr-read ADDR
```

`ADDR` is a DDR byte address and must be 16-byte aligned. `D0` through `D3` map to
`DDR_DEBUG_DATA0` through `DDR_DEBUG_DATA3`; `D0` is the lowest-address 32-bit
word. Each operation transfers one 128-bit DDR beat, so writing 128 bytes takes
eight `--ddr-write` operations with addresses incremented by `0x10`. Use
`--ddr-byte-enable MASK` before `--ddr-write` to select which bytes in later
writes are updated; the default `0xffff` writes all 16 bytes. The mask uses one
bit per byte, where bit 0 controls the byte at `ADDR + 0`.

For real hardware, the tool clears sticky DDR debug status, checks `ready`, starts
the command, polls `DDR_DEBUG_STATUS.done`, and fails on `error` or timeout. Use
`--ddr-timeout N` to change the poll limit for later DDR debug operations. In
`--dry-run` mode, DDR commands print the underlying register read/write frames;
no status can be observed without hardware.

The current RTL transport is intentionally simple and simulation-friendly. Before
using CH347 against hardware, the board-level SPI contract still needs to define:

- SPI mode, clock polarity, and clock phase.
- Maximum SCLK relative to the FPGA system clock.
- CS setup and hold requirements.
- MISO turnaround timing for reads.
- Whether the board wrapper synchronizes SPI pins into the FPGA clock domain.

## Suggested Host Tool Split

Keep hardware and policy code separate:

- `host/ch347_transport.*`: CH347 open/configure/close and SPI register frames.
- `host/ch347_control_main.cpp`: low-level register, envelope, release, and voice
  commit commands for board bring-up.
- Future `host/wave_image.*`: generated wave-memory image loading or Flash
  programming.
- Future real-time host app: MIDI/SF2 loading, event scheduling, and calls into
  `McuModel`.

The current command-line tool is intentionally low-level. A later real-time host
app can reuse `McuModel`, `RegisterVoiceControl`, and `Ch347RegisterTransport`
once it has a scheduler and a board asset-loading flow.
