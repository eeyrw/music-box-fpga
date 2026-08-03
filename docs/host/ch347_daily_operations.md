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

The current RTL must report `version=0x000f0000`. A successful asset wait shows
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
opening hardware by adding `--dry-run`. The tool reads back compressor and
reverb enable state; the current interface has no master-volume readback field.

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
