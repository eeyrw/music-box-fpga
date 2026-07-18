# Smart Artix Bring-Up Plan

This document turns the current Smart Artix board integration state into a
hardware bring-up procedure. It assumes the `fpga/smart_artix/` top level is the
target image and that the first board goal is to prove the platform path before
debugging musical behavior.

The intended order is:

```text
Vivado bitstream
  -> clock/reset and DDR3 calibration
  -> SPI debug-window reads
  -> SD raw-image load into DDR3
  -> one programmed voice
  -> I2S electrical/audio smoke test
```

Do not start with MIDI playback or full SoundFont preset policy. The FPGA does
not parse MIDI, allocate voices, or evaluate SoundFont regions; those remain
host, MCU, or later soft-processor responsibilities.

## Current Board Image

`fpga/smart_artix/rtl/smart_artix_top.sv` currently connects:

- `clk_in` from the board `50 MHz` oscillator.
- `smart_artix_clk_50m_to_200m`, feeding MIG `sys_clk_i`.
- `smart_artix_ddr3_mig`, exposing a `100 MHz` MIG `ui_clk`.
- `wavetable_spi_audio_system`, clocked by MIG `ui_clk`.
- native 4-bit SD asset loading into DDR3.
- DDR3 read/write arbitration between asset-loader writes and wavetable reads.
- SPI register control and system debug registers.
- fixed-rate 48 kHz I2S transmit output.
- debug LED outputs for SPI errors, audio underrun/drop/deadline events, asset
  load completion, and loader errors.

The generic core and the MIG application interface intentionally stay in the
same `100 MHz` `ui_clk` domain. This avoids a CDC bridge in the memory request
path during first bring-up.

## Bring-Up Boundaries

The first hardware image should prove these contracts:

- Vivado can generate a bitstream for `xc7a50tfgg484-2` with the generated Clocking
  Wizard and MIG IP.
- The board oscillator, reset input, and MIG DDR3 connection allow
  `init_calib_complete` to assert.
- The SPI transport can read the system debug window after the MIG UI clock is
  available.
- The SD raw-image loader can initialize an SDHC or SDXC card, parse the `WTSF`
  sector-0 header, and copy the SF2 byte image into DDR3.
- The host can write one voice slot through SPI and produce non-silent I2S data.

The first hardware image does not need to prove:

- MIDI file playback.
- full SF2 preset, generator, modulator, or velocity behavior.
- real-time voice allocation policy.
- Ethernet or high-speed asset upload.
- codec configuration over I2C or SPI.

## Before Connecting Hardware

Replace every temporary or unverified board pin assignment before wiring external
hardware. The checked-in XDC records useful intent, but it should be treated as a
bring-up skeleton until it has been checked against the Smart Artix schematic.

Required checks:

- Confirm the exact FPGA part, package, and speed grade: `XC7A50T-2FGG484I`, Vivado
  part `xc7a50tfgg484-2`.
- Confirm `clk_in` is the board `50 MHz` oscillator pin and that the Clocking
  Wizard XDC owns the primary clock constraint.
- Confirm `rst_n` source and polarity. The board top expects active-low reset.
- Confirm SPI, I2S, SD, and debug LED pins against the schematic and connector
  pinout.
- Confirm I/O standards and bank voltages. The skeleton uses `LVCMOS33` for
  non-DDR I/O.
- Keep DDR3 pins and DDR3 timing constraints owned by the MIG-generated XDC.
- Add real constraints for all top-level ports before generating a hardware
  bitstream.

Pay special attention to XDC coverage that must still be checked against the
actual board wiring:

- The SD connector may be marked by SPI-mode names. For native SD mode, map
  `SCK` to `sd_clk`, `MOSI` to `sd_cmd`, `MISO` to `sd_dat[0]`, and `CS` to
  `sd_dat[3]`. Native 4-bit mode also requires `sd_dat[1]` and `sd_dat[2]`.
- The current native SD path is read-only: the card drives `DAT[3:0]` during data
  blocks and the FPGA samples those pins as inputs. Do not make the FPGA actively
  drive `DAT[3:0]` unless a later write-capable SD PHY adds explicit output-enable
  control.
- `sd_cmd` and every `sd_dat` line need pull-ups unless the board already provides
  suitable external pull-ups.
- `led_asset_loaded` and `led_loader_error` are assigned to spare BANK15 expansion
  pins in the current XDC; move them if those pins are needed for lab wiring.
- SPI and I2S external input/output delays are not final until the selected host
  adapter and codec timing are known.

## Pre-Hardware Regression

Run the normal core and board-level tests before building a bitstream:

```bash
make lint
make test
make smart-artix-test
make render-board-loader SECONDS=0.1
```

Expected intent:

- `make lint` catches synthesizable RTL issues.
- `make test` checks exact core register, memory, interpolation, loop, gain, and
  mix behavior.
- `make smart-artix-test` checks the Smart Artix SD, DDR writer, DDR reader,
  read/write arbiter, FAT helper, and loader blocks with focused simulations.
- `make render-board-loader` verifies the raw-image SD-to-DDR path at command level
  and compares rendered samples against the C++ fixed-point reference.

These tests do not prove board pin timing or DDR3 electrical behavior. They are
the regression floor before hardware debugging starts.

## Vivado Flow

Run Vivado from `fpga/smart_artix`. The commands create and enter the generated
build directory so project output stays under `build/`:

```bash
mkdir -p ../../build/fpga/smart_artix/vivado/logs
cd ../../build/fpga/smart_artix/vivado
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/project.tcl \
  -journal logs/project.jou -log logs/project.log
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/impl.tcl \
  -journal logs/impl.jou -log logs/impl.log
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/bitstream.tcl \
  -journal logs/bitstream.jou -log logs/bitstream.log
```

Review at least:

- `reports/post_route_timing.rpt`
- `reports/post_route_utilization.rpt`
- bitstream log messages about unconstrained or unrouted I/O
- MIG IP warnings that mention clocking, reset, or pin incompatibility

The documented recent route result met setup and hold timing with the full Smart
Artix board top. Treat that as a useful baseline, not as proof that a changed XDC
or changed IP configuration is hardware-safe.

Program the board only after the pin constraints have been checked:

```bash
vivado -mode batch -source ../../../../fpga/smart_artix/vivado/scripts/program.tcl \
  -journal logs/program.jou -log logs/program.log
```

## First Power-On Checks

Keep the first power-on observation simple:

- Confirm JTAG sees the FPGA and programming completes.
- Confirm reset release polarity with a scope or logic analyzer if the board does
  not behave as expected.
- Confirm the Clocking Wizard and MIG are not held in reset.
- Confirm DDR3 calibration eventually completes.
- Watch `led_loader_error` and `led_asset_loaded` if those outputs are pinned.

The current SPI debug window is clocked from MIG `ui_clk`. It is available only
after the MIG UI clock exists and the system reset is released. If DDR3
calibration never completes, expect SPI debug reads to fail or stay unavailable.
A future always-on debug island would need a separate clock domain and CDC status
snapshots.

## SPI Debug Smoke Test

Build the CH347 host tools:

```bash
make host-ch347
make host-smart-artix-bringup
```

First test without hardware access:

```bash
build/ch347_control --dry-run --write 0x3000 0
build/ch347_control --dry-run --read 0x3000
build/smart_artix_bringup --dry-run --wait-ddr --ddr-smoke
```

Then use the selected CH347 library and conservative SPI speed. Start around
`1 MHz` until the board-level SPI timing contract is measured:

```bash
build/smart_artix_bringup --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80

build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --read 0x3000
```

The CH347 Linux SDK opens device paths such as `/dev/ch34x_pis0`; the host tool
maps `--device 0` to that path for convenience. The copied x64 vendor library is
used by default from `third_party/ch347_linux/lib/x64/libch347.so`.

`build/smart_artix_bringup` reads the same debug registers as a staged checklist,
decodes the status bits, and exits nonzero when a required stage fails. If CH347
is connected to the host but not to a valid FPGA SPI target, MISO may read back
as all ones. The runner detects the common `0xffff_ffff` snapshot and reports
that CH347 is present but no FPGA SPI target responded.

The useful first reads are:

| Address | Register | Expected use |
| --- | --- | --- |
| `0x3000` | `VERSION` | Proves SPI can reach the register map. |
| `0x3010` | `SYSTEM_STATUS` | Shows core, FIFO, I2S, and external-memory handshake state. |
| `0x3014` | `DEBUG_EVENT_FLAGS` | Shows sticky underrun/drop/deadline/memory events. |
| `0x3018` | `AUDIO_STATUS` | Shows FIFO level and sticky audio errors. |
| `0x3020` | `MEMORY_STATUS` | Shows cache/memory request status and response latency. |
| `0x3040` | `PLATFORM_STATUS` | Main DDR/SD/asset-loader status word. |
| `0x3044` | `PLATFORM_ERRORS` | SD error, loader error, and loader state. |
| `0x3048` | `PLATFORM_BYTES_LOADED` | Loaded byte count. |
| `0x3050` | `PLATFORM_SF2_SIZE` | SF2 byte count from the raw header. |
| `0x3058` | `PLATFORM_CURRENT_LBA` | Current sector being loaded. |
| `0x305c` | `PLATFORM_DDR_STATUS` | MIG calibration, ready flags, and device temperature. |
| `0x3060`..`0x307c` | `DDR_DEBUG_*` | Single-beat DDR read/write debug window. |

`PLATFORM_STATUS` bit meanings:

```text
bit 0      debug window present
bit 1      SD or loader error present
bit 2      DDR calibration complete
bit 3      DDR UI reset
bit 4      SD initialized
bit 5      asset loaded
bit 6      asset loader busy
bit 7      MIG app ready
bit 8      MIG write-data ready
bit 9      MIG read-data valid
bit 10     MIG read-data end
bits 14:11 asset-loader state
```

`PLATFORM_ERRORS` packs:

```text
bits 7:0    SD error code
bits 15:8   loader error code
bits 19:16  asset-loader state
```

For the current native-SD Smart Artix top, decode `SD error code` and `loader
error code` with the `PLATFORM_ERRORS` tables in `docs/register_map.md`. The SD
code identifies the failed native card command or data transfer stage; the loader
code identifies raw `WTSF` header validation, size/range checks, or DDR writer
failure.

After `PLATFORM_DDR_STATUS[0]` reports calibration complete and
`DDR_DEBUG_STATUS.ready` is set, use the DDR debug wrapper in the CH347 tool to
prove direct DDR access before depending on SD-loaded data:

```bash
# Staged runner form. This writes one 16-byte DDR beat at the selected address.
build/smart_artix_bringup --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --wait-ddr --ddr-smoke --ddr-addr 0x00000100

# Write 16 bytes at DDR byte address 0x100.
build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --ddr-byte-enable 0xffff \
  --ddr-write 0x00000100 0x01234567 0x89abcdef 0x76543210 0xfedcba98

# Read back the same 16-byte beat.
build/ch347_control --device 0 \
  --clock-hz 1000000 --mode 0 --cs-mask 0x80 \
  --ddr-read 0x00000100
```

Each DDR debug command accesses one 128-bit MIG beat, which is 16 bytes in the
current Smart Artix build. To inspect or patch 128 bytes, run eight commands and
increment the address by `0x10` each time. The address must be 16-byte aligned;
an unaligned command or a write with `--ddr-byte-enable 0` reports an error and
does not access DDR.

## SD Raw Image Bring-Up

The first product path uses a raw SD image, not a live filesystem. Sector 0 holds
a `WTSF` header; the SF2 byte image starts at the header-provided LBA and is copied
into DDR3 without byte repacking.

The loader currently targets SDHC and SDXC cards:

- SD v2 voltage/check pattern through `CMD8`.
- high-capacity request through `CMD55/ACMD41` with HCS.
- native-mode card identification and selection through `CMD2`, `CMD3`, and
  `CMD7`.
- 4-bit data mode through `CMD55/ACMD6`.
- single-block reads through `CMD17`.

Do not use SDSC cards for the first bring-up path. The RTL intentionally does not
implement the byte-addressed SDSC fallback.

Generate and check the raw image on the host before inserting the card:

```bash
make wtsf-image SF2=assets/soundfonts/MT6276.sf2
make verify-wtsf-image
```

The default output is `build/assets/wavetable.wtsf.img`. To write an SDHC/SDXC
card, pass the whole-card block device, not a partition:

```bash
make flash-wtsf-sd SD_DEVICE=/dev/sdX
```

The burn script refuses mounted devices and requires `SD_DEVICE` because the write
destroys the target card contents. Use `lsblk` before running it if more than one
removable drive is connected.

Expected successful load signs:

- `PLATFORM_STATUS[2] = 1`: DDR calibration complete.
- `PLATFORM_STATUS[4] = 1`: SD initialized.
- `PLATFORM_STATUS[5] = 1`: asset loaded.
- `PLATFORM_STATUS[1] = 0`: no SD or loader error.
- `PLATFORM_BYTES_LOADED == PLATFORM_SF2_SIZE`.

If loading fails:

- Check SD card voltage, pull-ups, and pin mapping first.
- Check whether the card is SDHC or SDXC.
- Read `PLATFORM_ERRORS` to separate SD protocol failure from raw-header or DDR
  writer failure.
- Watch `PLATFORM_CURRENT_LBA` to see whether the loader reached data sectors or
  failed near initialization/header parsing.

## First I2S Test

Do not connect a power amplifier for the first I2S test. Use a scope, logic
analyzer, or codec input with safe gain first.

Check these signals:

- `i2s_bclk` toggles continuously after playback reset is released.
- `i2s_lrclk` runs at the configured sample rate, currently `48 kHz`.
- `i2s_sdata` is initially quiet or low before a voice is programmed.
- After one voice is committed, `i2s_sdata` becomes non-static.

The board assumption is a simple I2S codec with no register initialization and no
MCLK requirement. If the actual codec needs MCLK, reset, mute, or register setup,
add those to the board wrapper before treating silence as a core bug.

## First Voice Programming

After `asset_loaded` is set, program a single conservative voice through SPI.
Start with:

- one voice slot, usually slot 0.
- mono playback.
- no loop.
- filter bypassed.
- envelope level `0x0000_7fff`.
- left and right gain around `0x2000` or lower for external audio safety.
- a known valid `BASE_ADDR` and `LENGTH` from the loaded SF2 sample metadata.

The minimal write order is documented in `../register_map.md` under `Note On`.
For board debug, read the normal per-voice register addresses to verify shadow
configuration and live runtime scalar state.

If audio is silent after the voice commit:

- Read `AUDIO_STATUS`, `RENDER_STATUS`, and `MEMORY_STATUS`.
- Check whether `MEMORY_STATUS` shows line-cache misses and memory responses.
- Check `DEBUG_EVENT_FLAGS` for underrun, sample drop, or render deadline miss.
- Confirm the programmed `BASE_ADDR` includes the SF2 `smpl` payload offset and is
  expressed as a 16-bit word address.
- Confirm `LENGTH` is nonzero and loop fields are valid for the selected loop
  mode.

## Fault Isolation

Use this order when a stage fails:

| Symptom | Likely area | First checks |
| --- | --- | --- |
| FPGA does not program | JTAG, power, part selection | Cable, target voltage, Vivado device list, part name. |
| No SPI response | DDR/MIG clock, SPI pins, reset | MIG calibration, `ui_clk`, `rst_n`, SPI mode, CS polarity, SCLK rate. |
| `PLATFORM_STATUS[2] = 0` | DDR3/MIG | DDR pins, MIG `.prj`, clock wizard, reset, board DDR power. |
| `PLATFORM_STATUS[4] = 0` | SD init | SD pins, pull-ups, card type, clock divider, voltage. |
| `PLATFORM_STATUS[1] = 1` | SD or loader | Decode `PLATFORM_ERRORS`, check raw image header and current LBA. |
| `asset_loaded = 1` but no memory responses | DDR read path | DDR arbiter, line reader, voice base address, memory status counters. |
| Memory responses but silent I2S | voice configuration or I2S | gains, envelope, length, loop mode, codec wiring, LRCLK/BCLK. |
| I2S underruns or deadline misses | throughput | active voice count, DDR latency, output FIFO level, memory cache hit rate. |

## Suggested Milestones

Record each board result in `smart_artix_target.md` or a dated lab log.
Use these milestones as the first checklist:

1. Bitstream generated with all top-level I/O constrained.
2. Board programs over JTAG.
3. MIG DDR3 calibration completes.
4. SPI can read `VERSION` and `PLATFORM_STATUS`.
5. SD card initializes.
6. Raw `WTSF` header parses without loader error.
7. `bytes_loaded == sf2_size_bytes` and `asset_loaded = 1`.
8. A single no-loop mono voice causes memory reads and non-static I2S data.
9. I2S BCLK/LRCLK timing is measured against the codec requirements.
10. Audio output is audible at safe gain with no sustained underrun, sample-drop,
    or render-deadline flags.
