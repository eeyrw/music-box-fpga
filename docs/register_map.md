# Register And Command Control Map

`spec/register_map.json` is the source of truth for the 16-bit-address,
32-bit-data global register bus. Run `make generate-register-map` after changing
it. Generated consumers are `rtl/pkg/synth_register_pkg.sv` and
`sim/harness/generated/register_map.h`.

Voice state is not register mapped. There is no per-voice address window and no
shadow/runtime register compatibility path. Voice definition, start, runtime
updates, release, and stop use the transactional command stream documented in
[`design/control_command_stream_plan.md`](design/control_command_stream_plan.md).

## Generic Core Registers

| Address | Name | Access | Meaning |
| ---: | --- | --- | --- |
| `0x9000` | `VERSION` | RO | Interface version, currently `0x00080000`. |
| `0x9010` | `SYSTEM_STATUS` | platform | Common system status. |
| `0x9014` | `COMMON_EVENT_FLAGS` | platform | Sticky underrun, drop, deadline, and memory-response flags. |
| `0x9018` | `AUDIO_STATUS` | platform | Audio FIFO and playback state. |
| `0x901c` | `RENDER_STATUS` | platform | Renderer state. |
| `0x9020` | `MEMORY_STATUS` | platform | Memory interface state. |
| `0x9024` | `UNDERRUN_COUNT` | platform | Saturating underrun counter. |
| `0x9028` | `SAMPLE_DROP_COUNT` | platform | Saturating dropped-sample counter. |
| `0x902c` | `RENDER_DEADLINE_MISS_COUNT` | platform | Saturating deadline counter. |
| `0x9030` | `CURRENT_SAMPLE` | RO | Accepted renderer-output timeline. |
| `0x9034` | `CMD_FIFO_STATUS` | RO | Word/action FIFO state and error flags. |
| `0x9038` | `MEM_RESPONSE_COUNT` | platform | Saturating memory response counter. |
| `0x903c` | `CMD_FIFO_DATA` | WO | One 32-bit command word. |
| `0x9094` | `CMD_ERROR_STATUS` | RO | Command and stale-sequence error summary. |
| `0x909c` | `CMD_ACTION_STATUS` | RO | Decoded action FIFO state. |
| `0x90a0` | `DEBUG_VOICE_INDEX` | RW | Voice selected for the next debug capture. |
| `0x90a4` | `DEBUG_VOICE_CAPTURE` | WO | Write exactly `1` to request a capture. |
| `0x90a8` | `DEBUG_VOICE_STATUS` | RO | Capture state and selected voice metadata. |
| `0x910c` | `COMPRESSOR_STATUS` | RO | Enable, prime, active-reduction, and delay-fill state. |
| `0x9110` | `COMPRESSOR_GAIN_REDUCTION` | RO | Current gain reduction, unsigned cB Q12.20. |
| `0x9114` | `COMPRESSOR_TARGET_GAIN_REDUCTION` | RO | Current detector target, unsigned cB Q12.20. |
| `0x9118` | `COMPRESSOR_DETECTOR_PEAK` | RO | Current linked unsigned 24-bit peak magnitude. |
| `0x911c` | `COMPRESSOR_MAX_GAIN_REDUCTION` | RO | Maximum gain reduction since core reset, cB Q12.20. |
| `0x9120` | `COMPRESSOR_MAX_DETECTOR_PEAK` | RO | Maximum unsigned 24-bit detector peak since core reset. |
| `0x9124` | `COMPRESSOR_INPUT_FRAME_COUNT` | RO | Saturating count of accepted mix frames. |
| `0x9128` | `COMPRESSOR_OUTPUT_FRAME_COUNT` | RO | Saturating count of valid post-delay output frames. |
| `0x912c` | `COMPRESSOR_COMPRESSED_FRAME_COUNT` | RO | Saturating count of output frames with nonzero compressor reduction. |
| `0x9130` | `COMPRESSOR_SATURATION_COUNT` | RO | Saturating count of final PCM16 channel saturation events. |

The generic control plane accepts writes only at `CMD_FIFO_DATA`. Unknown
addresses and writes to read-only generic registers return `bus_error`.
Board-level register fabric may own platform addresses in the same global
window.

### CMD_FIFO_STATUS

| Bits | Meaning |
| ---: | --- |
| `0` | command word FIFO empty |
| `1` | command word FIFO full / not ready |
| `15:2` | command word FIFO level |
| `16` | decoded action FIFO empty |
| `17` | decoded action FIFO full |
| `29:18` | decoded action FIFO level |
| `30` | `command_error_count != 0` |
| `31` | `stale_seq_count != 0` |

`CMD_ERROR_STATUS[0]` reports malformed or semantically invalid commands;
bit 1 reports stale sequences. `CMD_ACTION_STATUS` repeats the action FIFO
empty, full, and level fields in bits `0`, `1`, and `15:2`.

### Compressor Diagnostics

`COMPRESSOR_STATUS` fields are:

| Bits | Meaning |
| ---: | --- |
| `0` | compressor enabled by the active global command |
| `1` | fixed look-ahead delay fully primed |
| `2` | current gain reduction is nonzero |
| `7:3` | reserved, zero |
| `23:8` | accepted frames currently stored while priming the delay |
| `31:24` | reserved, zero |

The current detector peak, target, and applied reduction are published together
after one accepted input frame is analyzed. Maximum values and counters clear on
core reset. `COMPRESSOR_DETECTOR_PEAK` and its maximum register contain the raw
unsigned `max(abs(mix_l), abs(mix_r))` magnitude from the pre-compressor signed
24-bit mix. Interpret magnitude `32768` as `0 dBFS`; for a nonzero value `A`,
`level_dBFS = 20 * log10(A / 32768)`. Values above `32768` therefore represent
positive dBFS before final PCM16 saturation. These registers do not report RMS
or post-master output level.

Input/output/compressed counters count stereo frames;
`COMPRESSOR_SATURATION_COUNT` counts channels, so a frame clipping both left and
right increments it by two. All counters stop at `0xffffffff`.

## Voice Debug Snapshot

The debug aperture provides low-cost, read-only inspection without restoring a
random-access per-voice register bank. Write a voice number to
`DEBUG_VOICE_INDEX`, write `1` to `DEBUG_VOICE_CAPTURE`, then poll
`DEBUG_VOICE_STATUS[0]` until it clears. `DEBUG_VOICE_STATUS[1]` then indicates
that all snapshot words belong to one completed capture.

Capture waits until the renderer and command executor are idle, reuses their
existing prepared/active RAM read ports, and copies one word per clock into a
24-by-32-bit distributed RAM. A capture can therefore briefly defer the next
render frame or control batch, but adds no voice-state BRAM read port and no
full-width snapshot register bank. Snapshot data remains stable until the next
capture.

`DEBUG_VOICE_STATUS` fields are:

| Bits | Meaning |
| ---: | --- |
| `0` | capture busy |
| `1` | completed snapshot valid |
| `2` | selected voice has prepared state |
| `3` | selected voice has active state |
| `4` | active state is audible |
| `5` | active state has been released |
| `8:6` | envelope stage |
| `16:9` | prepared sequence number |
| `24:17` | active sequence number |

The snapshot data registers are:

| Address | Name | Contents |
| ---: | --- | --- |
| `0x90ac` | `DEBUG_VOICE_BASE_L` | left/mono base word address |
| `0x90b0` | `DEBUG_VOICE_BASE_R` | right base word address |
| `0x90b4` | `DEBUG_VOICE_LENGTH_L` | left/mono length, low 24 bits |
| `0x90b8` | `DEBUG_VOICE_LENGTH_R` | right length, low 24 bits |
| `0x90bc` | `DEBUG_VOICE_LOOP_START_L` | left/mono loop start, low 24 bits |
| `0x90c0` | `DEBUG_VOICE_LOOP_START_R` | right loop start, low 24 bits |
| `0x90c4` | `DEBUG_VOICE_LOOP_END_L` | left/mono exclusive loop end, low 24 bits |
| `0x90c8` | `DEBUG_VOICE_LOOP_END_R` | right exclusive loop end, low 24 bits |
| `0x90cc` | `DEBUG_VOICE_PHASE_INIT` | configured initial phase, unsigned Q24.8 |
| `0x90d0` | `DEBUG_VOICE_PHASE_INC` | active phase increment, unsigned Q24.8 |
| `0x90d4` | `DEBUG_VOICE_GAIN` | `{gain_r, gain_l}`, signed Q1.15 each |
| `0x90d8` | `DEBUG_VOICE_ENVELOPE` | control flags and envelope stage; bits `15:0` are reserved zero |
| `0x90dc` | `DEBUG_VOICE_FILTER_CONTROL` | bit 16 enable, bits `15:0` signed Q2.14 `a2` |
| `0x90e0` | `DEBUG_VOICE_FILTER_B0_B1` | `{b1, b0}`, signed Q2.14 each |
| `0x90e4` | `DEBUG_VOICE_FILTER_B2_A1` | `{a1, b2}`, signed Q2.14 each |
| `0x90e8` | `DEBUG_ENV_DELAY` | delay samples, low 24 bits |
| `0x90ec` | `DEBUG_ENV_ATTACK_STEP` | attack step, unsigned Q0.32 |
| `0x90f0` | `DEBUG_ENV_HOLD` | hold samples, low 24 bits |
| `0x90f4` | `DEBUG_ENV_DECAY_STEP` | decay step, unsigned centibel Q12.20 |
| `0x90f8` | `DEBUG_ENV_SUSTAIN` | sustain attenuation, unsigned centibel Q12.20 |
| `0x90fc` | `DEBUG_ENV_RELEASE_STEP` | release step, unsigned centibel Q12.20 |
| `0x9100` | `DEBUG_ENV_ELAPSED` | current stage elapsed samples, low 24 bits |
| `0x9104` | `DEBUG_ENV_ATTACK_LEVEL` | attack accumulator, unsigned Q0.32 |
| `0x9108` | `DEBUG_ENV_ATTENUATION` | current attenuation, unsigned centibel Q12.20 |

`DEBUG_VOICE_ENVELOPE` packs stage in bits `18:16`, audible in bit 19, released
in bit 20, stereo in bit 21, and loop mode in `23:22`; bits `15:0` and `31:24`
are reserved zero. Read `DEBUG_ENV_ATTACK_LEVEL` or `DEBUG_ENV_ATTENUATION` for
the authoritative envelope value. Keeping the raw state avoids a second
centibel-to-Q1.15 converter solely for debug.

This aperture captures command/control-owned active state. `PHASE_INIT` is the
configured restart position; it is not the renderer's advancing phase. Biquad
history is likewise renderer-private and is not included. Those high-rate
datapath states can be added later behind a separate trace/debug build if board
debugging proves they are necessary.

## Command Ingress

Software may write individual words through `CMD_FIFO_DATA`, but normal voice
traffic uses SPI opcode `0xa5` followed by consecutive big-endian 32-bit words.
Both paths feed the same FIFO and parser. The direct stream has priority; a
simultaneous `CMD_FIFO_DATA` write is rejected.

## Board Platform Window

The Smart Artix platform uses `0x9040` through `0x907c` for loader progress,
DDR status, and the debug DDR access aperture. Exact names, fields, and masks
are generated from `spec/register_map.json`. They are board control registers,
not voice-control aliases.
