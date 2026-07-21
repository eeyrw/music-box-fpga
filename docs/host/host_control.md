# Host Control And CH347 Integration

The project now treats the MCU-side policy as host-side C++ that can run either
inside a simulation harness or in a PC tool connected through USB-to-SPI hardware
such as CH347.

## Reusable C++ Layers

The simulation harness already contains reusable control-side code under
`sim/harness/`:

- `formats/midi_parser.*`: parses MIDI events and converts them to timed note
  events.
- `formats/sf2_loader.*`: extracts SoundFont regions and builds the wave-memory
  image. It preserves normal SF2 `sampleLink` stereo pairs and also collapses
  common hard-panned left/right instrument-zone pairs with stale or missing
  links into one stereo region when their ranges and sample pitch metadata are
  compatible and both selected sample windows are usable. Per-channel sample
  names, sample type flags, lengths, and loop windows may differ. Sample loop
  endpoints are validated when a region is built and are clamped to the selected
  sample window, which keeps otherwise playable SoundFonts with stale unused
  sample-loop metadata loadable. For any stereo region the loader centers the
  per-zone pan and takes each channel's base gain from its own side's
  `initialAttenuation`, because the left/right sample routing already provides
  the stereo image.
- `render/render_support.*`: contains `McuModel`, which owns voice allocation,
  note on, note off, ADSR stepping, and region selection for the current render
  path.
- `control/register_control.*`: converts voice-control operations into register
  writes.

`control/register_control.*` is the boundary intended for real hardware
transport. It defines:

```cpp
class RegisterWriteSink {
 public:
  virtual ~RegisterWriteSink() = default;
  virtual void write_register(uint16_t address, uint32_t data) = 0;
};
```

`RegisterVoiceControl` implements the documented voice register sequence on top
of that interface. The C++ DUT adapters under `sim/harness/dut/`, the demo
full-system harness, the board-loader harness, and the CH347 host tools all share
this class so that note setup, envelope updates, release handling, and commit
ordering stay identical.

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
build/ch347_control --dry-run --write 0x9000 0
build/ch347_control --dry-run --read 0x9000

# Read VERSION through CH347 device 0.
build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --read 0x9000

# The Linux SDK also accepts explicit device paths.
build/ch347_control --device /dev/ch34x_pis0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --read 0x9000

# Write one register through CH347 device 0.
build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --write 0x9014 0x3f

# Read the SD asset-load byte progress from the platform SPI registers.
build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --read-load-progress

# Print the SPI register sequence for one 16-byte DDR register-access write.
build/ch347_control --dry-run \
  --ddr-byte-enable 0xffff \
  --ddr-write 0x00000100 0x01234567 0x89abcdef 0x76543210 0xfedcba98

# Read one 16-byte DDR register access beat through CH347 device 0.
build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --ddr-read 0x00000100

# Program and commit voice 0 from command-line region parameters.
build/ch347_control --dry-run \
  --set-envelope 0 0 \
  --commit-voice 0 --enable 1 --stereo 0 --base 0 --length 1024 \
  --loop-start 0 --loop-end 1024 --loop-mode 1 \
  --phase-inc 0x00000100 --gain-l 0x4000 --gain-r 0x4000 \
  --envelope 0x0000
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

The transport also exposes auto-increment helpers for consecutive 32-bit
registers. Burst writes use command byte `0xc0` followed by the start address and
one or more 32-bit data words. Burst reads use command byte `0x40` followed by
the start address and one 32-bit readback phase per requested word. The bridge
increments the byte address by four after each beat and ends the burst when chip
select deasserts.

Per-voice configuration and runtime registers read back through their normal
addresses. Some reads take multiple system-clock cycles because the register bank
uses synchronous RAM internally; the SPI bridge waits for the internal
`bus_ready` response before shifting out the 32-bit read data. Hardware-facing
burst transfers must leave enough system-clock cycles between readback words, and
between write data words, for the internal register-bus beat to complete.

For a `100 MHz` FPGA system clock, use `--clock-hz 1000000` for initial
hardware bring-up. After basic single-register reads and writes are stable,
`2000000` and `5000000` are reasonable next test points. Treat `10000000` as a
board-measured target, not a default guarantee. The current SPI bridge is sampled
by the FPGA system clock and has no wire-level ready signal, so gapless
high-speed burst transfers are not guaranteed. Single reads need an
address-to-data turnaround gap; burst reads need a gap before each readback word;
burst writes need a gap after each data word. Long-latency writes such as
`VOICE_CONTROL.apply` should be the final word of a burst or sent as separate
single-register writes.

The command-line tool also wraps the Smart Artix DDR register-access window:

```bash
build/ch347_control --ddr-write ADDR D0 D1 D2 D3
build/ch347_control --ddr-read ADDR
```

`ADDR` is a DDR byte address and must be 16-byte aligned. `D0` through `D3` map to
`DDR_ACCESS_DATA0` through `DDR_ACCESS_DATA3`; `D0` is the lowest-address 32-bit
word. Each operation transfers one 128-bit DDR beat, so writing 128 bytes takes
eight `--ddr-write` operations with addresses incremented by `0x10`. Use
`--ddr-byte-enable MASK` before `--ddr-write` to select which bytes in later
writes are updated; the default `0xffff` writes all 16 bytes. The mask uses one
bit per byte, where bit 0 controls the byte at `ADDR + 0`.

For real hardware, the tool clears sticky DDR register-access status, checks
`ready`, starts the command, polls `DDR_ACCESS_STATUS.done`, and fails on
`error` or timeout. Use `--ddr-timeout N` to change the poll limit for later DDR
register-access operations. In `--dry-run` mode, DDR commands print the
underlying register read/write frames; no status can be observed without
hardware.

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

## Smart Artix Bring-Up Runner

`host/smart_artix_bringup_main.cpp` wraps the practical Smart Artix checklist
from `../board/smart_artix_bringup.md` into a staged CH347 program. Build it with:

```bash
make host-smart-artix-bringup
```

The default run reads and decodes the common status and platform register
windows:

```bash
build/smart_artix_bringup --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80
```

If the CH347 adapter is present but the FPGA SPI target is not connected or not
driving MISO, reads commonly return `0xffff_ffff`. The runner treats an all-ones
snapshot as a hard failure and exits with status `2`, which distinguishes a
working USB adapter from a missing FPGA response.

Useful staged hardware checks:

```bash
# Poll until MIG calibration and the DDR register access window are ready.
build/smart_artix_bringup --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --wait-ddr

# Wait for SD raw-image load, then prove a single 128-bit DDR register-access beat.
build/smart_artix_bringup --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --wait-ddr --wait-asset --ddr-smoke --ddr-addr 0x100

# After choosing valid sample metadata from the loaded SF2, program voice 0.
build/smart_artix_bringup --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --wait-asset --voice-smoke --voice 0 \
  --base 0 --length 1024 --phase-inc 0x00010000 \
  --gain-l 0x2000 --gain-r 0x2000 --envelope 0x7fff
```

`--ddr-smoke` writes the selected 16-byte-aligned DDR address before reading it
back, so use an address that is safe to overwrite for the current lab setup.
`--voice-smoke` intentionally requires explicit sample bounds because the FPGA
does not parse SF2 metadata.
