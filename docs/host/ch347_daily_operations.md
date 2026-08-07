# CH347 Daily Operations

This is the routine operator guide for the Smart Artix CH347 connection. Use
Python for board inspection, configuration, recovery, DDR access, and smoke
tests. Use the C++ host only for latency-sensitive real-time MIDI playback.

## Ownership Rule

Only one process may own a CH347 device at a time. Stop `realtime_midi_host`
before running a Python command against the same `/dev/ch34x_pis*` node. Do not
issue FLUSH from a second process while the real-time host still has commands in
its local scheduler; FPGA FLUSH cannot clear host memory.

The examples below use the verified board connection:

```bash
cd /home/yuan/music-box-fpga
export CH347_DEVICE=/dev/ch34x_pis1
export CH347_CLOCK=30000000
```

Pass those values before the subcommand:

```bash
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" info
```

Start at `1000000` Hz after rewiring or changing boards. The CH347 rounds a
requested rate down to a supported step and `info` prints the selected rate.

## Start-Of-Day Check

Confirm the adapter, interface version, DDR/SD load, and decoded board state:

```bash
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" info
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" wait asset
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" snapshot --group all
```

The current RTL must report `version=0x00100000`. A successful asset wait shows
DDR ready, SD initialized, `asset_loaded=1`, no platform error, and equal
loaded/declared byte counts. Do not interpret current register fields when the
version differs.

For a shorter health check:

```bash
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" \
  read VERSION PLATFORM_STATUS PLATFORM_ERRORS CMD_FIFO_STATUS
```

An idle command plane normally has FIFO empty, parser idle, and no action
pending. Sticky command/stale bits may remain set from an earlier test until the
diagnostic interval is cleared.

## Configure Audio

Enable the normal compressor/reverb setup at unity master gain:

```bash
python3 tools/configure_audio_effects.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" \
  --compressor on --master-db 0 --reverb hall
```

For 6 dB output attenuation use `--master-db -6`. Inspect encoding without
opening hardware by adding `--dry-run`. A successful hardware run prints the
requested configuration followed by decoded register state, for example:

```text
configured compressor=on master_db=0 reverb=hall
COMPRESSOR_STATUS=0x00003003 [enabled=on, primed=yes, gain_reduction=inactive, delay_level_frames=48]
EFFECT_STATUS=0x00000ffa [chorus=off, reverb=on, busy=no, chorus_history=valid, reverb_valid_lines=0xff (8/8), clamped=none]
```

The tool verifies compressor and reverb enable readback. `primed`,
`chorus_history`, and `reverb_valid_lines` describe retained processing history,
so they can remain valid after an effect is disabled. `busy` is an instantaneous
pipeline state, and `clamped` names any effect configuration adjusted by RTL.
Raw hexadecimal values are retained for register-level diagnosis. The current
interface has no master-volume readback field.

## Real-Time MIDI Playback

Build the only CH347 C++ application, then run it with the selected MIDI and
SoundFont files:

```bash
make host-realtime-midi
build/realtime_midi_host \
  --midi-file '/path/to/song.mid' \
  --sf2 '/path/to/soundfont.sf2' \
  --midi-tail-ms 1000 \
  --device "$CH347_DEVICE" \
  --clock-hz "$CH347_CLOCK"
```

The process owns transport scheduling, voice generations, MIDI timing, and
shutdown. Let it finish or stop it before using `ch347_tool.py`.

### Non-GM SoundFont Preset Mapping

Do not treat an audible but incorrect instrument as an asset-loader failure
until the MIDI bank/program requests have been compared with the SoundFont
preset directory. A SoundFont can use valid `(bank, program)` numbers without
following the General MIDI instrument assignments. `realtime_midi_host` uses
the MIDI file's bank and program state; `--sf2` does not remap a non-GM bank to
General MIDI.

The 2026-08-04 investigation of `Undertale.sf2` established this concrete case:

- The source was 499,844,752 bytes with SHA-256
  `c4c25182da11a86284a3b36f16060c65fd314529aa2b05e54bbc4609ba2c8326`.
  Its size and preset directory identify it as the community
  [`Undertale V3 (PC).sf2`](https://anapan.ca/Anapan/FM/NON%20GM%20Soundfonts/),
  which is distributed as a non-GM SoundFont.
- The local WTSF payload was byte-exact with the source SF2. On hardware,
  `PLATFORM_BYTES_LOADED` and `PLATFORM_SF2_SIZE` both reported 499,844,752,
  with `asset_loaded=1` and no SD, loader, underrun, sample-drop, or render
  deadline error.
- `debussy_bergamasque_03.mid` contained 1,489 Note On events, all requesting
  bank 0, program 0. General MIDI assigns that location to Acoustic Grand
  Piano, but this SoundFont assigns it to `100 Over. Gt.`. Its numeric preset
  name prefixes refer to Undertale soundtrack entries rather than GM program
  categories.
- A three-second dry run covered the first four Note On events, reached four
  active voices, emitted complete command transactions, and reported zero
  unmapped Note Ons or transport errors. The wrong timbre was therefore preset
  selection, not failed parsing or voice generation.

Use a GM-compatible SoundFont for arbitrary GM MIDI files. To use this
Undertale bank, author bank/program changes for its preset directory instead;
for example, its bank 0, program 29 preset is named `086 Grand Piano`. The
current real-time host has no command-line program override, so this selection
must be present in the MIDI data.

## Diagnostics

Clear interval diagnostics immediately before a workload, then capture the
same groups after the workload stops:

```bash
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" \
  clear-diagnostics --verify

# Run the workload, then stop it.

python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" \
  snapshot --group all --output build/ch347/after.json
```

For repeated comparisons, keep the JSON output and record the bitstream/MCS
hash alongside it. Snapshot reads are separate mailbox transactions, not an
atomic multi-register capture.

## FLUSH Recovery

After the command producer is stopped, clear pending FPGA command work with:

```bash
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" flush
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" read CMD_FIFO_STATUS
```

FLUSH cancels unpublished bridge staging, clears the FPGA command FIFO, and
resets the parser. It preserves active voices, global audio/effect state, and
diagnostics. Expected post-FLUSH status is FIFO empty, parser idle, and action
pending clear. Deterministic hardware cancellation qualification remains
tracked as `SPI-004` in the SPI backlog.

## DDR Inspection

Read a small range without modifying DDR:

```bash
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" \
  ddr-read 0 --beats 256 --output build/ch347/ddr_0_4k.bin
```

Perform a complete sequential benchmark and byte-exact comparison:

```bash
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" \
  ddr-benchmark --address 0 --bytes 65536 \
  --verify '/path/to/source.sf2' \
  --output build/ch347/ddr_0_64k.bin
```

The benchmark reports elapsed time, payload KiB/s, Mbit/s, FNV-1a, and mismatch
count. Use `ddr-verify` when reproducible sparse sampling is sufficient.

`ddr-smoke` and `ddr-write` are destructive. Use an address known to be outside
live sample data, or reload the asset afterward:

```bash
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" \
  ddr-smoke 0x100 0x01234567 0x89abcdef 0x76543210 0xfedcba98
```

## Voice Smoke Test

After `wait asset`, test a known valid mono sample range:

```bash
python3 tools/ch347_tool.py \
  --device "$CH347_DEVICE" --clock-hz "$CH347_CLOCK" \
  voice-smoke --voice 0 --generation 1 \
  --base 0 --length 48000 --phase-inc 0x100 \
  --gain-l 0x2000 --gain-r 0x2000 --duration-ms 100
```

The command validates DDR readiness, parser drain, memory-response activity,
and audio event flags. It always sends the matching STOP after a successful
START, including exception paths.
The base and length must describe real loaded PCM data; arbitrary DDR header
bytes are not a safe audible test source.

## Failure Triage

Use this order so transport failure is not confused with asset or audio failure:

1. `info`: adapter open, mailbox CRC, and interface version.
2. `read PLATFORM_STATUS PLATFORM_ERRORS`: DDR/SD/loader state.
3. `wait asset`: bounded readiness and loaded-size equality.
4. `read CMD_FIFO_STATUS COMMAND_ERROR_COUNT STALE_GENERATION_COUNT`: command health.
5. `snapshot --group core`: renderer, FIFO, effects, and compressor state.
6. `ddr-read`: sample-memory accessibility without a destructive write.

Run `make test-ch347-python` after changing the Python binding or board CLI.
Run `make host-realtime-midi` and the C++ unit tests after changing the real-time
transport or scheduler.
