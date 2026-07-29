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
| `0x9000` | `VERSION` | RO | Interface version, currently `0x000a0000`. Version 10 introduces the mono voice-major command payloads below. |
| `0x9010` | `SYSTEM_STATUS` | platform | Common system status. |
| `0x9014` | `COMMON_EVENT_FLAGS` | platform | Sticky underrun, drop, deadline, and memory-response flags. |
| `0x9018` | `AUDIO_STATUS` | platform | Audio FIFO and playback state. |
| `0x901c` | `RENDER_STATUS` | platform | Renderer state. |
| `0x9020` | `MEMORY_STATUS` | platform | Memory interface state. |
| `0x9024` | `UNDERRUN_COUNT` | platform | Saturating underrun counter. |
| `0x9028` | `SAMPLE_DROP_COUNT` | platform | Saturating dropped-sample counter. |
| `0x902c` | `RENDER_DEADLINE_MISS_COUNT` | platform | Saturating deadline counter. |
| `0x9030` | `CURRENT_SAMPLE` | RO | Accepted renderer-output timeline. |
| `0x9034` | `CMD_FIFO_STATUS` | RO | Command-word FIFO, parser state, and error flags. |
| `0x9038` | `MEM_RESPONSE_COUNT` | platform | Saturating memory response counter. |
| `0x903c` | `CMD_FIFO_DATA` | WO | One 32-bit command word. |
| `0x9094` | `CMD_ERROR_STATUS` | RO | Command and stale-sequence error summary. |
| `0x909c` | `CMD_ACTION_STATUS` | RO | Parser/dispatcher execution state. |
| `0x910c` | `COMPRESSOR_STATUS` | RO | Enable, prime, active-reduction, and delay-fill state. |
| `0x9110` | `COMPRESSOR_GAIN_REDUCTION` | RO | Current gain reduction, unsigned cB Q12.20. |
| `0x9114` | `COMPRESSOR_TARGET_GAIN_REDUCTION` | RO | Current detector target, unsigned cB Q12.20. |
| `0x9118` | `COMPRESSOR_DETECTOR_PEAK` | RO | Current linked unsigned 25-bit peak magnitude. |
| `0x911c` | `COMPRESSOR_MAX_GAIN_REDUCTION` | RO | Maximum gain reduction since core reset, cB Q12.20. |
| `0x9120` | `COMPRESSOR_MAX_DETECTOR_PEAK` | RO | Maximum unsigned 25-bit detector peak since core reset. |
| `0x9124` | `COMPRESSOR_INPUT_FRAME_COUNT` | RO | Saturating count of accepted mix frames. |
| `0x9128` | `COMPRESSOR_OUTPUT_FRAME_COUNT` | RO | Saturating count of valid post-delay output frames. |
| `0x912c` | `COMPRESSOR_COMPRESSED_FRAME_COUNT` | RO | Saturating count of output frames with nonzero compressor reduction. |
| `0x9130` | `COMPRESSOR_SATURATION_COUNT` | RO | Saturating count of final PCM16 channel saturation events. |
| `0x9134` | `EFFECT_STATUS` | RO | Spatial-effect enable, activity, history-valid, and clamp flags. |
| `0x9138` | `EFFECT_INPUT_FRAME_COUNT` | RO | Saturating count of frames accepted by the spatial-effect chain. |
| `0x913c` | `EFFECT_OUTPUT_FRAME_COUNT` | RO | Saturating count of spatial-effect output handshakes. |
| `0x9140` | `EFFECT_SATURATION_COUNT` | RO | Saturating count of signed-25 effect-return mixer channel clamps. |
| `0x9144` | `EFFECT_MAX_PROCESSING_CYCLES` | RO | Maximum spatial-chain clocks from input acceptance to output valid. |
| `0x9148` | `CHORUS_HISTORY_LEVEL` | RO | Valid stereo frames in chorus history, low 16 bits. |
| `0x914c` | `CHORUS_LFO_PHASE` | RO | Current chorus LFO phase, unsigned Q0.32. |
| `0x9150` | `CHORUS_SATURATION_COUNT` | RO | Saturating chorus signed-25 channel clamp count. |
| `0x9154` | `REVERB_STATUS` | RO | Reverb pre-delay occupancy and valid-line mask. |
| `0x9158` | `REVERB_SATURATION_COUNT` | RO | Saturating reverb signed-25 channel clamp count. |
| `0x915c` | `REVERB_MAX_PROCESSING_CYCLES` | RO | Maximum clocks used by the reverb FSM. |

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
| `16` | parser and dispatcher idle |
| `17` | a command is buffered, being parsed, or waiting for execution |
| `29:18` | reserved, zero |
| `30` | `command_error_count != 0` |
| `31` | `stale_seq_count != 0` |

`CMD_ERROR_STATUS[0]` reports malformed or semantically invalid commands;
bit 1 reports stale generations. `CMD_ACTION_STATUS[0]` is one only when the
parser/dispatcher is idle; bit 1 reports pending work. Bits `31:2` are zero.

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
25-bit mix. Interpret magnitude `32768` as `0 dBFS`; for a nonzero value `A`,
`level_dBFS = 20 * log10(A / 32768)`. Values above `32768` therefore represent
positive dBFS before final PCM16 saturation. These registers do not report RMS
or post-master output level.

Input/output/compressed counters count stereo frames;
`COMPRESSOR_SATURATION_COUNT` counts channels, so a frame clipping both left and
right increments it by two. All counters stop at `0xffffffff`.

### Effect Diagnostics

`EFFECT_STATUS` fields are:

| Bits | Meaning |
| ---: | --- |
| `0` | chorus enabled |
| `1` | reverb enabled |
| `2` | a frame is active in the spatial-effect chain |
| `3` | chorus history contains at least one valid frame |
| `11:4` | reverb valid delay-line mask |
| `12` | chorus configuration was clamped |
| `13` | reverb configuration was clamped |
| `14` | return-mixer configuration was clamped |
| `31:15` | reserved, zero |

`REVERB_STATUS[15:0]` is the pre-delay occupancy and bits `23:16` are the
valid-line mask. Spatial input/output counters count stereo handshakes. The
three saturation counters count clamped channels, not frames, and stop at
`0xffffffff`. `EFFECT_CLEAR` clears spatial histories and their diagnostics,
including these counters and maxima; compressor diagnostics are unchanged.

## Command Ingress

Software may write individual words through `CMD_FIFO_DATA`, but normal voice
traffic uses SPI opcode `0xa5` followed by consecutive big-endian 32-bit words.
Both paths feed the same FIFO and parser. The direct stream has priority; a
simultaneous `CMD_FIFO_DATA` write is rejected.

### Voice-Major Mono Commands (Version 10)

The production voice-major renderer accepts one complete mono sample lane per
voice. A command header is `{opcode[7:0], voice_id[9:0], flags[5:0],
payload_words[7:0]}` from most- to least-significant field. Every voice command
carries its generation in payload word 0:

| Bits | Meaning |
| ---: | --- |
| `15:0` | 16-bit generation |
| `31:16` | reserved, zero |

This layout supports the 512-voice configuration without truncating IDs 256
through 511. A stale generation is rejected and counted in
`CMD_ERROR_STATUS[1]`.

For `VOICE_START_MONO`, flags `[1:0]` are loop mode, bit 2 includes the
three-word filter group, bit 3 includes the six-word envelope group, and bits
`5:4` are zero. Other voice commands require zero flags.

| Opcode | Name | Payload words | Payload after generation word |
| ---: | --- | ---: | --- |
| `0x10` | `VOICE_START_MONO` | 5 to 16 | base, length, optional loop pair, Q24.8 phase increment, `{gain_r,gain_l}`, optional filter group, optional envelope group |
| `0x13` | `VOICE_ENV_UPDATE` | 7 | delay, attack step, hold, decay step, sustain attenuation, release step |
| `0x14` | `VOICE_RELEASE` | 2 | release step |
| `0x15` | `VOICE_STOP` | 1 | none |
| `0x16` | `VOICE_GAIN` | 2 | `{gain_r,gain_l}` |
| `0x17` | `VOICE_FILTER` | 4 | B0/B1, B2/A1, A2/control |
| `0x18` | `VOICE_PITCH` | 2 | Q24.8 phase increment |
| `0x7f` | `STREAM_FLUSH` | 0 | none |

There is no stereo-definition opcode in version 10 and `START` is not split
from definition. Linked SF2 stereo samples and compatible hard-panned pairs are
expanded by the C++ loader into two mono regions. Each region receives its own
voice and channel gains, so the renderer never combines two sample streams in
one voice. START always clears that voice's phase accumulator to zero.

## Board Platform Window

The Smart Artix platform uses `0x9040` through `0x907c` for loader progress,
DDR status, and the debug DDR access aperture. Exact names, fields, and masks
are generated from `spec/register_map.json`. They are board control registers,
not voice-control aliases.

`PLATFORM_STATUS[15]` reports the debounced active-low Smart Artix SD card-detect
switch, and bit 16 reports that CMD6 successfully selected High Speed. Bit 4
continues to mean that initialization completed; an initialized Default
Speed-only card therefore has bit 4 set and bit 16 clear.

`PLATFORM_ERRORS` packs the SD error code in bits `7:0`, loader error code in
bits `15:8`, loader state in bits `19:16`, and the saturating SD block-retry count
in bits `27:20`. Bits `31:28` report SD recovery status: `0` means no secondary
recovery failure, `1` means CMD12 transport/card-status failure, and `2` means
CMD12 DAT0 busy timeout. When a failed CMD18 block is followed by a CMD12 failure,
the primary SD error remains the original data error while this field records the
stop failure.
