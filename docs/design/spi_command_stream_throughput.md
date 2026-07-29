# SPI Command-Stream Throughput

This document sizes Smart Artix SPI opcode `0xa5` traffic for interface version
10. Register reads have separate turnaround constraints documented in
[`spi_register_timing.md`](spi_register_timing.md).

## Current Configuration

| Item | Value |
| --- | ---: |
| System clock | 100 MHz |
| Audio sample rate | 48 kHz |
| Command word width | 32 bits |
| Command word FIFO | 1024 words |
| Default voice slots | 256 |
| Sample window | 32 mono words per voice |
| DDR refill transaction | 8 words / 128 bits |

One audio frame has about 2083 system clocks. The renderer works in 8-frame
blocks and drains pending control commands before starting a block. Commands do
not carry timestamps.

## Data Path

```text
SPI mode 0, opcode 0xa5
  -> consecutive big-endian 32-bit words
  -> 1024-word command FIFO
  -> transactional parser/dispatcher
  -> active mono voice store or global effects configuration
  -> next eligible render block
```

The same FIFO also accepts `CMD_FIFO_DATA` register writes. Simulation uses the
same command boundary; there is no typed control bypass.

Before asserting chip select, the host reads `CMD_FIFO_STATUS` and calculates:

```text
free_words = 1024 - CMD_FIFO_STATUS[15:2]
```

The transaction must not exceed `free_words`. The present SPI slave cannot
backpressure after a transaction begins; rejected words set `spi_error`.
Packet-atomic transport improvements remain tracked in
[`spi_transport_backlog.md`](spi_transport_backlog.md).

The CH347 transport has a 256-byte local transfer buffer. With one opcode byte,
one transaction carries at most 63 command words (`1 + 63 * 4 = 253` bytes).

## Command Sizes

Sizes include the header:

| Operation | Words | Bits |
| --- | ---: | ---: |
| `VOICE_START_MONO`, no loop/filter/envelope | 6 | 192 |
| `VOICE_START_MONO`, loop only | 8 | 256 |
| `VOICE_START_MONO`, envelope only | 12 | 384 |
| `VOICE_START_MONO`, loop/filter/envelope | 17 | 544 |
| `VOICE_ENV_UPDATE` | 8 | 256 |
| `VOICE_RELEASE` | 3 | 96 |
| `VOICE_STOP` | 2 | 64 |
| `VOICE_GAIN` | 3 | 96 |
| `VOICE_FILTER` | 5 | 160 |
| `VOICE_PITCH` | 3 | 96 |
| compressor config | 5 | 160 |
| master volume | 2 | 64 |
| chorus config | 7 | 224 |
| reverb config | 10 | 320 |
| effect clear | 2 | 64 |

Linked stereo SF2 material consumes two `VOICE_START_MONO` commands and two
voice slots. It does not use a larger stereo command or a dual-stream voice.

## Runtime Workloads

For `N` active voices, update rate `F`, and `W` words per update:

```text
payload_bits_per_second = N * F * W * 32
```

For the 512-voice project default:

| Per-voice update rate | Gain, 3 words | Pitch, 3 words | Filter, 5 words | All, 11 words |
| ---: | ---: | ---: | ---: | ---: |
| 50 Hz | 2.458 Mbps | 2.458 Mbps | 4.096 Mbps | 9.011 Mbps |
| 100 Hz | 4.915 Mbps | 4.915 Mbps | 8.192 Mbps | 18.022 Mbps |
| 200 Hz | 9.830 Mbps | 9.830 Mbps | 16.384 Mbps | 36.045 Mbps |

Updating every parameter group on every voice at 100 Hz is a stress workload,
not expected MIDI traffic. Independent gain and pitch commands avoid paying for
unmodified fields. The MCU command builder also suppresses unchanged groups.

At 70 percent sustained link utilization, a 15 MHz SCLK provides about
10.5 Mbps of useful command bits, enough for the 512-voice/50-Hz all-groups
stress point with limited margin but not the 100-Hz row. The 7.5 MHz fallback
is appropriate for normal sparse musical updates, not full-density stress.

## Start Bursts

One maximum-size CH347 transaction can carry three worst-case mono starts
(`3 * 17 = 51` words). Default six-word starts fit ten per transaction. A linked
stereo note consumes two independently sized mono commands.

The FIFO holds 60 worst-case starts with four words remaining, or 170 default
starts with four words remaining. Hosts must still preflight exact word capacity
and should keep linked stereo pairs adjacent.

## Renderer And DDR Context

Wave samples do not cross SPI. Each active voice consumes one logical mono
sample stream, duplicated only after sampling. A 32-word per-voice window serves
hits locally and issues ordered 8-word refills through the existing Smart Artix
DDR3 line reader and read/write arbiter to the MIG app interface.

The measured 512-voice, eight-slot block renderer completes within the 48 kHz
deadline with the timed DDR3 model. The capacity tests also validate voice IDs
256 through 511. These RTL measurements determine render capacity; SPI rate
alone does not prove DDR or audio deadline margin.

## Hardware Qualification

Before raising board SCLK:

1. constrain SPI input/output timing and review CDC paths;
2. validate register reads independently from stream writes;
3. stream bursts across FIFO wrap and empty/nonempty transitions;
4. exercise malformed and partial commands and verify error flags;
5. run sustained gain, pitch, and filter traffic during maximum intended
   polyphony;
6. check `CMD_FIFO_STATUS`, `CMD_ERROR_STATUS`, deadline flags, and audio output;
7. validate 15 MHz first, retaining 7.5 MHz as the fallback.
