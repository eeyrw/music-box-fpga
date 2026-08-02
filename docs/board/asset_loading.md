# SD Asset Loading To DDR3

This document defines the planned board-level path for loading large SoundFont
assets from an SD card into DDR3 before wavetable playback starts. It is a board
system contract, not part of the generic wavetable core under `rtl/`.

## Design Position

The FPGA should not parse the full SF2 preset model, allocate voices, or evaluate
SoundFont regions. Those remain owned by the external MCU, host tool, or later
soft control processor. The FPGA-side loader only needs to move a contiguous raw
asset image from SD card sectors into DDR3 and expose enough status for software
to know when playback can start.

The existing wave-memory contract is preserved: word address zero is the first
16-bit word of the complete SF2 file image in DDR3, and voice `BASE_ADDR` values
include the `smpl` chunk payload offset. Software sends voice commands using
metadata produced by a host-side SF2 parser or preprocessing tool.

The Smart Artix MT41K256M16 device has 512 MiB of byte-addressed capacity. Its
native MIG application address is expressed in 16-bit DRAM words, so board RTL
converts loader and debug byte addresses by dividing by two. Renderer sample
addresses are already 16-bit word addresses and pass to the native MIG address
unchanged. A 128-bit MIG beat therefore advances the native application address
by eight while covering 16 consecutive bytes.

```text
SD raw image
  -> FPGA SD block reader
  -> sector FIFO / width adapter
  -> DDR3 write DMA
  -> DDR3 wave image

MCU / host control
  -> SF2 or preprocessed metadata
  -> transactional voice commands over SPI
  -> voice_major_render_core reads PCM through its sample windows
```

## Raw SD Image Format

Use raw sectors rather than a filesystem for the first board path. Sector 0 holds
a fixed little-endian header, followed by the SF2 byte image and optional metadata
tables.

```text
offset  size  field
0x00    4     magic = "WTSF"
0x04    4     version = 1
0x08    4     header_size_bytes
0x0c    4     flags
0x10    8     sf2_start_lba
0x18    4     sf2_size_bytes
0x1c    4     reserved, must be zero
0x20    8     ddr_base_byte_addr
0x28    8     metadata_start_lba
0x30    8     metadata_size_bytes
0x38    4     sf2_crc32, optional when flags enable it
0x3c    4     header_crc32, optional when flags enable it
```

The first implementation should require `ddr_base_byte_addr = 0` so the current
wave-memory address convention remains direct. If a later board reserves low DDR
space for diagnostics or firmware buffers, software must add the base offset when
programming voice `BASE_ADDR` registers.

The optional metadata region is intended for MCU or host software. The FPGA loader
may copy it to DDR or ignore it, depending on board control needs. The loader does
not need to understand metadata contents.

## FPGA Loader Blocks

Board-specific RTL should keep these responsibilities separate:

```text
sd_raw_reader
  - initialize card in the selected SD mode
  - issue single-block or multi-block reads
  - produce a 512-byte sector stream with valid/ready/last/error

asset_loader
  - read and validate sector 0 header
  - sequence sector reads over the SF2 byte range
  - generate byte counts, CRC state, and loader status

ddr3_asset_writer
  - pack sector bytes into MIG application write beats
  - generate aligned DDR write addresses and byte enables
  - backpressure the SD stream when MIG cannot accept writes

ddr3_arbiter
  - grant loader writes before playback starts
  - grant wavetable line reads during playback
  - optionally support low-priority writes only when the audio path is idle
```

These blocks belong under a concrete board directory such as `fpga/smart_artix/`.
The generic `voice_major_render_core`, `voice_sample_window`, and register map should not
depend on SD, MIG, or board clocking signals.

The first Smart Artix implementation provides the board-side middle of this path:

- `smart_artix_asset_loader` parses sector 0, validates the raw-image header,
  requests SF2 data sectors, and exposes loader status.
- `smart_artix_ddr3_asset_writer` packs the byte stream into MIG write-data beats,
  emits write masks for a partial final beat, and tracks the independent MIG
  command and write-data ready handshakes.
- `smart_artix_ddr3_rw_arbiter` multiplexes wavetable reads, loader writes, and
  reg-access reads/writes onto one MIG application port. Read commands have priority
  when no read response is outstanding; each write command and write-data beat is
  locked to the same owner until both sides of the 7-series MIG app interface
  accept the write.
- `sd_native_block_reader` implements the matching command-level
  native SD path above the pin PHY: `CMD0`, `CMD8`,
  `CMD55`/`ACMD41`, `CMD2`, `CMD3`, R1b-aware `CMD7`, `CMD55`/`ACMD42` to
  disconnect the card-side DAT3 detect pull-up, and `CMD55`/`ACMD6` to enter
  4-bit bus mode. It queries CMD6 Function Group 1 before attempting High Speed,
  validates the switch result, and falls back to 25 MHz Default Speed when High
  Speed is unsupported or busy. It reads SCR with `CMD55`/`ACMD51`, uses `CMD23`
  only when CMD_SUPPORT advertises it, and transfers multi-block requests with
  `CMD18`. Without CMD23 it terminates the requested extent using R1b-aware
  `CMD12`. A failed middle block is stopped with CMD12 and retried from its LBA
  using bounded `CMD17` recovery, without repeating clean output blocks.
- `smart_artix_sd_native_asset_loader` connects the native reader to the raw
  image loader and DDR3 writer at the command/data interface.
- `sd_native_pin_phy` provides the direct FPGA-pin native SD layer for
  `SD_CLK`, bidirectional `CMD` through `cmd_o/cmd_oe/cmd_i`, and `DAT[3:0]` read
  sampling. It generates command CRC7, captures short/long responses, and converts
  4-bit data nibbles into the reader's byte stream, and validates the four
  DAT-line CRC16 values before releasing the final byte of a block. After reset it
  emits the SD-required idle clocks before accepting commands, checks the data-block
  end bit on all four DAT lines, and emits idle clocks after each transaction so
  the card has bus-turnaround clocks before the next command.
- `smart_artix_sd_card_detect` synchronizes and debounces the active-low `SD_CD`
  socket switch on U17. A stable insertion waits at least 1 ms before releasing
  the SD session reset. Removal clears SD initialization, High Speed, loader,
  and asset-valid state; reinsertion starts a fresh power-up-clock sequence.
  While the session reset is asserted, including the no-card state,
  `loader_busy` remains low. Releasing the reset after one stable insertion
  produces one load-start edge, so the card is reloaded once per insertion.
- `smart_artix_ddr3_subsystem` wires the native pin layer through the native
  command/data asset loader and arbitrates the resulting DDR3 writes with runtime
  wavetable reads.

Native 4-bit SD keeps command/control sequencing separate from the byte data
stream. The current native pin layer generates command CRC7, receives data bytes,
and checks DAT-line CRC16 at the end of each block. A CRC mismatch is reported
through the data status attached to the final byte. SPI-mode SD and FAT
filesystem loading are intentionally not part of the Smart Artix board RTL; the
product path uses the raw `WTSF` SD image.

Board simulation also includes `fake_sd_native_phy_model`, a card-side behavioral
model following the fake-card testing style used by standalone SD-reader projects.
It maintains initialization state, app-command state, RCA selection, 4-bit bus
mode, high-speed switch status data, OCR/CID-style responses, and delayed
single- and multi-block read data, including SCR capability-dependent CMD23
behavior and CMD12 termination. This gives the native command reader a more
realistic regression than a scripted response list, while still stopping at the
command/data interface rather than modeling pin-level `CMD`/`DAT` electrical
timing.
`fake_sd_native_pin_model` complements it at the pin-transport layer by observing
48-bit command frames from `sd_cmd_o/sd_cmd_oe`, driving `sd_cmd_i` responses, and
driving `DAT[3:0]` data nibbles into `sd_native_pin_phy`.

These models are intentionally not interchangeable. The command-level fake
tests reader/card policy and fast asset/DDR integration without serial-wire
overhead. The pin-level fake tests serialization, response/data framing,
CRC7/CRC16, busy, start-token latency, and clock phase. Neither is hardware
timing qualification or a substitute for tests with physical cards.

The SD initialization sequence intentionally borrows the practical bring-up shape
used by simple FPGA SD readers:

```text
SPI mode:
  power-up dummy clocks with CS high
  CMD0            -> idle
  CMD8            -> SD v2 voltage/check pattern
  CMD55/ACMD41    -> retry until ready, request HCS
  CMD58           -> confirm CCS/SDHC
  CMD17           -> single-block reads by LBA

Native mode:
  power-up idle clocks with CMD released and DAT idle
  CMD0            -> idle
  CMD8            -> SD v2 voltage/check pattern
  CMD55/ACMD41    -> retry until ready, request HCS
  CMD2            -> read CID
  CMD3            -> capture RCA
  CMD7 (R1b)      -> select card and wait for DAT0 busy release
  CMD55/ACMD42    -> disconnect the card-side DAT3 detect pull-up
  CMD55/ACMD6     -> switch DAT bus to 4-bit mode
  CMD55/ACMD51    -> read SCR and discover optional CMD23 support
  CMD6 mode 0     -> query Function Group 1 High Speed support/busy
  CMD6 mode 1     -> request High Speed and validate the returned selection
  CMD17           -> single-block reads by LBA
  CMD23/CMD18     -> discovered-count optimized multi-block read
  CMD18/CMD12     -> multi-block read when CMD23 is unsupported or rejected
  CMD12/CMD17     -> stop a failed CMD18 and retry from the failed LBA
```

The fake-card regression exercises the native-mode retry path by returning busy
OCR values before the ready/SDHC OCR. The command reader tests therefore cover the
important initialization state transitions rather than only the successful final
responses.

Some compatibility behavior from broader SD-reader examples is deliberately not
adopted:

- SDv1 and SDv2 SDSC fallback paths are not implemented.
- `CMD16` block-length setup is not used because SDHC/SDXC cards have fixed
  512-byte block addressing for this path.
- The reader does not switch pin clocks internally. The subsystem selects 400 kHz
  during initialization, 25 MHz after Default Speed initialization, and 50 MHz
  only after a successful CMD6 mode-1 result and the PHY's eight old-rate guard
  clocks have completed. The Smart Artix 50 MHz pin path is post-route closed and
  hardware-qualified for the board/card combination recorded in
  `smart_artix_bringup.md`; production-card and waveform margin remain separate
  electrical qualification work.
- Pin-level pull-up behavior on `CMD` and `DAT[3:0]` is handled in the Smart Artix
  XDC skeleton with conditional `PULLUP` constraints that become active when the
  board top exposes native SD ports.

Both current SD block readers intentionally target SDHC/SDXC block-addressed cards. They
request high-capacity support with `ACMD41(HCS)` and require the capacity-status
bit before accepting the card. SDSC byte-addressed cards are not supported because
the asset loaders and FAT layer operate in 512-byte logical block addresses.

In this document, "native SD" or "4-bit SD" means the SD memory-card protocol over
`CMD` and `DAT[3:0]`. It does not mean the separate SDIO I/O-card function
protocol with `CMD5`/function registers.

`smart_artix_top` uses the native 4-bit SD pin loader as the board asset source,
starts loading automatically after DDR3 calibration, arbitrates loader writes and
wavetable line reads onto the MIG application port, and keeps the playback core
in reset until `asset_loaded` is set.

## Verification Coverage

The Version 9.10 protocol audit and remaining qualification work are tracked in
[`sd_native_backlog.md`](sd_native_backlog.md). The passing simulations below
cover the implemented functional contracts but do not replace exhaustive fault
injection, post-route external timing, or physical-card qualification.

The board-level regression target runs all focused Smart Artix simulations:

```bash
make smart-artix-test
```

This covers the raw-image header parser, DDR3 asset writer masks and byte order,
DDR3 read/write arbitration, native SD command reader, native fake-card
initialization and reads, native pin PHY command/data/CRC behavior, and the
command-level native SD asset-loader path.

Use `make smart-artix-test` for the focused loader/DDR writer/arbiter checks and
`make render-rtl-ddr3` for the current voice-major render path. A combined
multi-megabyte pin-level SD load and render is not a current target.

## Host Image Tools

Generate the same raw-image format for hardware with:

```bash
make wtsf-image SF2=assets/soundfonts/MT6276.sf2
make verify-wtsf-image
```

This writes `build/assets/wavetable.wtsf.img` by default. To burn an SDHC/SDXC
card, pass the whole-card block device, not a partition:

```bash
make flash-wtsf-sd SD_DEVICE=/dev/sdX
```

The burn script refuses mounted devices and requires the explicit `SD_DEVICE`
argument because it overwrites the target device.

## SD Mode Choice

The loader interface should abstract sector reads so the physical SD mode can be
changed without touching DDR or wavetable logic.

Start with one of these modes:

| Mode | Use | Expected result |
| --- | --- | --- |
| SPI mode | Simplest bring-up and bring-up | Low bandwidth; a 500 MB image may take minutes |
| Native 4-bit SD | Practical product path | Higher PHY complexity; tens of seconds for a 500 MB image |

SD card latency is not deterministic enough for real-time wavetable reads. The SD
card is an asset source only; DDR3 remains the audio read memory.

## DDR3 Addressing

The wavetable core addresses signed 16-bit PCM words. The loader writes the SF2
file bytes into DDR3 without changing the SF2 byte order. The board DDR line
reader returns aligned 8-word little-endian refill data to
`voice_sample_window`.

```text
ddr_byte_addr = ddr_base_byte_addr + wave_word_addr * 2
pcm_word      = {sf2_byte[ddr_byte_addr + 1], sf2_byte[ddr_byte_addr]}
```

For SF2 sample playback, software calculates:

```text
base_addr = (smpl_payload_byte_offset / 2) + sample_start_frame
```

For linked SF2 stereo samples, software allocates two mono hardware voices. Each
voice has its own `BASE_ADDR`, `LENGTH`, loop points, gains, envelope, and filter
state. There are no right-channel sample-address fields in one voice command.

## Capacity Policy

The current Smart Artix target assumes one 512 MB DDR3 device. A nominal 500 MB
SoundFont leaves little margin for metadata, diagnostics, test buffers, or future
double-buffering. The first board software should enforce a conservative maximum,
such as:

```text
sf2_size_bytes <= 480 MiB
```

Larger practical libraries should be preprocessed on a PC into a compact wave
image containing only required presets and samples. Keeping a full original SF2
image in DDR3 is useful for bring-up and simple control software, but it is not
the most space-efficient long-term format.

## Loader State And Status

The board wrapper should expose a small status/control surface to the MCU or host.
The exact register transport can be board-specific, but the minimum observable
state is:

```text
idle
ddr_calibrating
sd_initializing
reading_header
loading_sf2
verifying
loaded
error
```

Recommended counters and flags:

```text
bytes_loaded
sf2_size_bytes
current_lba
error_code
crc_expected
crc_observed
asset_loaded
loader_busy
```

Playback should remain disabled until DDR3 calibration has completed and
`asset_loaded` is set. The first implementation should not support concurrent SD
loads and active audio playback; that requires a DDR arbiter policy with strict
read priority and underrun testing.

## Bring-Up Sequence

The intended hardware bring-up order is:

1. Generate a small raw SD image with the header and a known SF2 or PCM test
   payload.
2. Bring up DDR3 calibration and a simple write/read memory test.
3. Implement SD block reads and validate sector 0 header fields.
4. Stream a small image from SD to DDR3 and verify the copied bytes through a test
   readback path.
5. Connect `voice_sample_window` to the DDR line reader and existing DDR3
   arbiter, then play a known sample from DDR3 through the effects chain and I2S.
6. Increase image size and measure full-load time, CRC behavior, and error paths.
7. Increase native 4-bit SD clock rate once board timing constraints are
   schematic-verified.

## Open Decisions

These choices should be made when the concrete board wrapper is implemented:

- Whether metadata is copied into DDR3 or consumed only by the MCU/host.
- Whether sector 0 is enough for the header or a larger aligned header area should
  be reserved.
- Whether CRC32 is required for every load or only for diagnostics.
- Whether the initial SD reader uses SPI mode or native 4-bit SD.
- How loader status is exposed: existing SPI register bridge, a separate board
  status register bank, UART, or MCU-local GPIO/status pins.
