# Mono Voice-Major Control And Render Contract

This document defines the version-10 command encoding retained by interface
version 13 (`0x000d0000`). Version 12 added the aligned SPI length/CRC16
transaction envelope; version 13 replaces only the register wire protocol with
a split-phase mailbox. The old
DEFINE_MONO/DEFINE_STEREO plus prepared/active START protocol is not part of
this interface.

## Ownership

The host parses MIDI and SF2, selects regions, allocates voices, evaluates the
modulator graph, and converts pitch, gain, filter, and envelope parameters to
fixed-point command fields. Linked SF2 stereo samples are expanded into two
mono regions and use two voice IDs.

The FPGA owns the active mono voice store, sample-rate volume envelopes, block
render scheduling, 32-word per-voice sample windows, mixing, global effects,
and fixed-rate audio output.

```text
host MIDI/SF2 policy
  -> 32-bit command word FIFO
  -> transactional parser and dispatcher
  -> active mono voice state
  -> voice-major block renderer
  -> global chorus/reverb/compressor/master chain
  -> I2S FIFO
```

There is one control plane in simulation and hardware. Test harnesses and the
production host send the same command words through the dedicated command
stream; hardware maps that stream to SPI opcode `0xa5`. They do not install
typed voice records through private simulation ports. `CMD_FIFO_DATA` remains a
debug-only word injection register and is not used by the production host.

## Framing

Each command has one header followed by exactly `payload_words` words:

```text
header[31:24] opcode
header[23:14] voice_id
header[13:8]  flags
header[7:0]   payload_words
```

The header voice ID is authoritative. Every voice command carries the 16-bit
generation in payload word 0:

```text
payload0[15:0]  generation
payload0[31:16] reserved, zero
```

The 10-bit ID supports builds through 512 voices. The 16-bit generation rejects
late runtime commands after a slot has been reused. Invalid commands are fully
consumed, make no state change, and set `CMD_FIFO_STATUS[30]`; stale generations
set bit 31.

The parser waits for a complete command before executing it. An aligned
`STREAM_FLUSH` command discards later buffered FIFO words without changing voice
or effect state. It cannot recover a parser already waiting for missing payload,
because its header would be consumed as that payload; transport recovery must
clear both the FIFO and parser state through reset or a future out-of-band
control.

## Voice Commands

| Opcode | Command | Payload words |
| ---: | --- | ---: |
| `0x10` | `VOICE_START_MONO` | 5 to 16 |
| `0x13` | `VOICE_ENV_UPDATE` | 7 |
| `0x14` | `VOICE_RELEASE` | 2 |
| `0x15` | `VOICE_STOP` | 1 |
| `0x16` | `VOICE_GAIN` | 2 |
| `0x17` | `VOICE_FILTER` | 4 |
| `0x18` | `VOICE_PITCH` | 2 |
| `0x7f` | `STREAM_FLUSH` | 0 |

All voice commands begin with the generation word. Runtime-command flags must
be zero. START flags are:

| Flag bits | Meaning |
| ---: | --- |
| `1:0` | loop mode: 0 none, 1 continuous, 2 until release; 3 invalid |
| `2` | three filter words are present |
| `3` | six envelope words are present |
| `5:4` | reserved, zero |

### VOICE_START_MONO

```text
word 0   generation in bits 15:0
word 1   mono base word address
word 2   sample length
[if loop mode != 0] loop start, exclusive loop end
next     phase increment, unsigned Q24.8
next     {gain_r_q1_15, gain_l_q1_15}
[if flags[2]] {b1,b0}, {a1,b2}, {15'b0,enable,a2}
[if flags[3]] delay, attack step, hold, decay step, sustain, release step
```

The exact payload length is `5 + 2*has_loop + 3*has_filter + 6*has_envelope`.
Omitted filter means bypass; omitted envelope means immediate full sustain and
an immediate stop on RELEASE unless a later ENV update supplies a release step.

START validates all fields and atomically replaces the voice slot. It clears
the phase accumulator to zero, clears filter history and release state, and starts a fresh envelope. A
single voice has one mono PCM stream; its sample is duplicated before the
independent left/right gains are applied. There is no stereo voice command.

### Runtime Commands

```text
VOICE_ENV_UPDATE word 0 generation; words 1..6 complete envelope parameters
VOICE_RELEASE    word 0 generation; word 1 release step
VOICE_STOP       word 0 generation
VOICE_GAIN       word 0 generation; word 1 {gain_r, gain_l}
VOICE_FILTER     word 0 generation; words 1..3 complete filter parameters
VOICE_PITCH      word 0 generation; word 1 phase increment
```

Runtime commands require an exact generation match. Gain and pitch are distinct
commands so changing pan or attenuation cannot accidentally change playback
rate. Runtime pitch does not reload phase. RELEASE enters Release from the
current envelope level; STOP immediately removes the voice.

## Global Audio Commands

| Opcode | Command | Payload words |
| ---: | --- | ---: |
| `0x20` | `COMPRESSOR_CONFIG` | 4 |
| `0x21` | `MASTER_VOLUME` | 1 |
| `0x22` | `CHORUS_CONFIG` | 6 |
| `0x23` | `REVERB_CONFIG` | 9 |
| `0x24` | `EFFECT_CLEAR` | 1 |

Global command header voice ID and flags must be zero. A complete
configuration replaces the corresponding active configuration atomically.

```text
COMPRESSOR_CONFIG
  word 0 {ratio_slope_q0_16[15:0], 15'b0, enable}
  word 1 threshold attenuation, unsigned cB Q12.20
  word 2 attack step, unsigned cB Q12.20 per frame
  word 3 release step, unsigned cB Q12.20 per frame

MASTER_VOLUME
  word 0 nonnegative Q1.15 gain in bits 15:0

CHORUS_CONFIG
  word 0 {feedback_q1_15, 15'b0, enable}
  word 1 {8'b0, base_delay_q16_8}
  word 2 {8'b0, depth_q16_8}
  word 3 lfo_phase_inc_q0_32
  word 4 {return_gain_q1_15, input_send_q1_15}
  word 5 stereo_phase_offset_q0_32

REVERB_CONFIG
  word 0 {20'b0, pre_delay_frames[10:0], enable}
  word 1 input_send_q1_15
  word 2 return_gain_q1_15
  word 3 damping_q1_15
  word 4 chorus_to_reverb_q1_15
  words 5..8 two packed Q1.15 feedback gains per word

EFFECT_CLEAR
  word 0 bit 0 clears chorus, bit 1 clears reverb
```

Effects are not bypassed by the voice-major integration. Every completed render
block passes through the shared spatial effects, compressor, and master-volume
chain before entering the I2S FIFO.

## Execution Boundary

Voice and global actions execute only while the renderer is idle. A block
request is held until the parser, command FIFO, and pending dispatcher work are
drained. Consequently every voice in a rendered block observes one coherent
control boundary. Commands arriving after rendering starts apply to a later
block.

The production command stream exposes ready/valid backpressure. The debug-only
`CMD_FIFO_DATA` ingress shares the FIFO; a simultaneous direct-stream word has
priority and the register write returns an error.

## SPI Transport

With chip select low, the command transaction begins with one aligned 32-bit
transport header followed by the declared number of big-endian command words:

```text
CS low -> 0xa5 -> word_count -> CRC16 -> word0 -> ... -> wordN-1 -> CS high
```

The header is `{8'ha5, word_count[7:0], payload_crc16[15:0]}`. Legal
transactions contain 1 through 63 words and may contain multiple complete
commands. CRC-16/CCITT-FALSE covers the word-count byte followed by every
payload word in big-endian byte order. `spi_register_bridge` parameter
`CHECK_COMMAND_CRC` controls whether the received CRC is compared; disabling
the check does not change the four-byte wire header.

The bridge stages the complete CS-delimited transaction, checks its declared
length and command-record boundaries, and publishes it only after CS rises on a
legal word boundary. Downstream backpressure pauses the staged commit without
dropping words.

`CMD_FIFO_STATUS[15:2]` exposes capacity for software preflight, but the current
CH347 transport sends each complete command without reading it first. Register
transactions remain the path for status, diagnostics, and board control.
Transport limitations, compatible atomic staging, and SCLK budget are tracked
in
[`design/transport/spi_command_stream.md`](design/transport/spi_command_stream.md).

## Verification

The required focused coverage is:

- complete and partial command framing, malformed payloads, and flush;
- voice IDs 0, 255, 256, and the configured highest slot;
- stale generations and slot reuse;
- atomic mono start, independent gain and pitch updates, release, and stop;
- linked SF2 stereo expansion into two mono commands;
- global effect dispatch and clear;
- register FIFO and direct stream equivalence;
- command drain before a block boundary and no typed simulation bypass.
