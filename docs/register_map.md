# Register And Command Control Map

`spec/register_map.json` is the source of truth for the 16-bit-address,
32-bit-data global register bus. Run `make generate-register-map` after changing
it. Generated consumers are `rtl/pkg/synth_register_pkg.sv` and
`sim/harness/generated/register_map.h`.

Voice state is not register mapped. There is no per-voice address window and no
shadow/runtime register compatibility path. Voice definition, start, runtime
updates, release, and stop use the transactional command stream documented in
[`command_stream.md`](command_stream.md).

## Generic Core Registers

| Address | Name | Access | Meaning |
| ---: | --- | --- | --- |
| `0x9000` | `VERSION` | RO | Interface version, currently `0x00110000`. This register remains readable while the renderer core is held in reset. Version 17 adds the FPGA-authoritative voice-active bitmap transaction. |
| `0x9010` | `SYSTEM_STATUS` | platform | Common system status. |
| `0x9014` | `COMMON_EVENT_FLAGS` | platform | Sticky underrun, drop, deadline, and memory-response flags. |
| `0x901c` | `PIPELINE_LATENCY_STATUS` | platform | Last render and memory-response latencies. |
| `0x9024` | `UNDERRUN_COUNT` | platform | Saturating underrun counter. |
| `0x9028` | `SAMPLE_DROP_COUNT` | platform | Saturating dropped-sample counter. |
| `0x902c` | `RENDER_DEADLINE_MISS_COUNT` | platform | Saturating deadline counter. |
| `0x9030` | `CURRENT_SAMPLE` | RO | Accepted renderer-output timeline. |
| `0x9034` | `CMD_FIFO_STATUS` | RO | Command-word FIFO, parser state, and error flags. |
| `0x9038` | `MEM_RESPONSE_COUNT` | platform | Saturating memory response counter. |
| `0x9080` | `DIAGNOSTIC_CONTROL` | WO | Bit 0 clears the diagnostic interval without resetting voices, caches, or playback. Reads return zero. |
| `0x9084` | `PIPELINE_LATENCY_MAX` | RO | Maximum completed-render and memory-response latencies. |
| `0x9088` | `AUDIO_FIFO_DIAGNOSTICS` | RO | Current/minimum FIFO occupancy and playback-started state. |
| `0x908c` | `AUDIO_LEAD` | RO | Live rendered-minus-played stereo-frame lead. |
| `0x9090` | `COMMAND_ERROR_COUNT` | RO | Exact saturating malformed/unsupported command count. |
| `0x9094` | `STALE_GENERATION_COUNT` | RO | Exact saturating stale-generation rejection count. |
| `0x9098` | `RENDER_SESSION_EPOCH` | RO | Render-session epoch, incremented after each acknowledged `0xa7` reset. |
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
| `0x9160` | `SAMPLE_WINDOW_REQUEST_COUNT` | RO | Accepted sample-window requests. |
| `0x9164` | `SAMPLE_WINDOW_HIT_COUNT` | RO | Requests served from a valid window. |
| `0x9168` | `SAMPLE_WINDOW_REFILL_COUNT` | RO | Full-window refill misses. |
| `0x916c` | `SAMPLE_WINDOW_FALLBACK_READ_COUNT` | RO | One-line fallback misses. |
| `0x9170` | `SAMPLE_WINDOW_MEMORY_READ_COUNT` | RO | External line reads issued. |
| `0x9174` | `SAMPLE_WINDOW_EVICTION_COUNT` | RO | Valid windows replaced. |
| `0x9178` | `SAMPLE_WINDOW_STALL_CYCLE_COUNT` | RO | Blocked client-request cycles. |

Writes to command-plane read-only registers return `bus_error`. The
common-status and Smart Artix platform-status blocks acknowledge writes to
their recognized read-only addresses and ignore the data.
`COMMON_EVENT_FLAGS` implements write-one-to-clear and
`DIAGNOSTIC_CONTROL.CLEAR` has the interval-reset side effect described below.
The DDR debug aperture also has the explicitly writable registers listed below.
Unknown addresses return `bus_error`.

### Common Status Fields

`SYSTEM_STATUS` contains live signals rather than sticky history:

| Bits | Field | Meaning |
| ---: | --- | --- |
| `0` | `CORE_BUSY` | renderer core is busy |
| `1` | `RENDER_INFLIGHT` | an admitted render block is in flight |
| `2` | `CORE_SAMPLE_VALID` | renderer is presenting a completed sample |
| `3` | `FIFO_SAMPLE_VALID` | output FIFO is presenting a sample |
| `4` | `I2S_SAMPLE_READY` | I2S output can accept a sample |
| `5` | `EXT_REQ_VALID` | external-memory request is valid |
| `6` | `EXT_REQ_READY` | external-memory request sink is ready |
| `7` | `EXT_RSP_VALID` | external-memory response is valid |
| `23:8` | `OUTPUT_FIFO_LEVEL` | current output FIFO occupancy |
| `31:24` | reserved | zero |

`PIPELINE_LATENCY_STATUS[15:0]` is the most recently reported render latency;
bits `31:16` are the most recently traced external-memory response latency.
Both values count system clocks.

The four event flags clear on reset, by writing ones to
`COMMON_EVENT_FLAGS`, or through `DIAGNOSTIC_CONTROL.CLEAR`; a new event in the
same clock as either clear is retained. The four saturating event counters clear
on reset or diagnostic clear.

`PIPELINE_LATENCY_MAX[15:0]` records the maximum latency of a completed render
request; bits `31:16` record the maximum traced external-memory response
latency. Both are 16-bit system-clock counts. The render value is sampled once,
when completion is first observed, even when ownership of the completed block
is backpressured by an older block.

`AUDIO_FIFO_DIAGNOSTICS[7:0]` is current FIFO occupancy, bits `15:8` are the
minimum occupancy since reset or diagnostic clear, and bit 16 says playback has
started. `AUDIO_LEAD` is the live unsigned difference between accepted rendered
frames and frames consumed by I2S. Diagnostic clear re-bases the minimum to the
current level; it does not stop playback or empty the FIFO.

Writing bit 0 of `DIAGNOSTIC_CONTROL` clears common event flags and counters,
pipeline maxima, exact command error/stale counts, all seven sample-window
counters, and the FIFO minimum level. It deliberately preserves command FIFO
contents and parser state, voices, render state, sample-window tags/data,
effect state, FIFO contents, playback-started state, and all live values. Effect
and compressor counters retain their existing effect-clear/core-reset
contracts. A zero write has no effect.

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

Version 11 removed `CMD_ERROR_STATUS` and `CMD_ACTION_STATUS` because they were
exact aliases of `CMD_FIFO_STATUS[31:30]` and `[17:16]`.

Version 12 retains those register semantics and changes the external SPI
command-transaction envelope as documented under Command Ingress.

Version 13 retains the earlier register meanings, but replaces the external SPI
direct/burst register frames with the single-register request/fetch mailbox
documented in
[`design/transport/spi_register_mailbox.md`](design/transport/spi_register_mailbox.md).

Version 14 removes `CMD_FIFO_DATA`; all command submission now uses the
transactional command stream. It adds the diagnostic interval control and exact
status registers at `0x9080` through `0x9094`.

Version 15 removes the `0x7f` command-word FLUSH and adds the dedicated SPI
`0xa6` FLUSH transaction. Register addresses and field meanings are otherwise
unchanged.

Version 16 adds the dedicated SPI `0xa7` render-session reset and the read-only
`RENDER_SESSION_EPOCH` register. The epoch starts at zero after FPGA reset and
increments only after the render core, voice validity, scheduler, effect and
compressor history, output FIFO, and I2S state have received the session reset.
It is not cleared by `DIAGNOSTIC_CONTROL.CLEAR`.

Version 17 adds the fixed-length SPI `0x5c` voice-active-status transaction
documented in
[`design/transport/spi_voice_status.md`](design/transport/spi_voice_status.md).
The register addresses and field meanings are otherwise unchanged.

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

### Sample-Window Diagnostics

All seven sample-window registers are 32-bit saturating counters and clear on
`core_reset` or diagnostic clear. Diagnostic clear preserves valid window data
and tags. A request eventually contributes to exactly one hit, refill, or
fallback count. A refill issues one external read per line in the window, so
`MEMORY_READ_COUNT` is intentionally not a duplicate of `REFILL_COUNT`.
`EVICTION_COUNT` increments only when a refill replaces a previously valid
window. `STALL_CYCLE_COUNT` counts blocked cycles, not blocked requests, and
excludes the reset-time metadata initialization sweep.

## Command Ingress

Production voice and global control uses an aligned SPI transaction header
`{8'ha5, word_count[7:0], payload_crc16[15:0]}` followed by `word_count`
big-endian 32-bit words. Legal transactions contain 1 through 63 words and may
contain multiple complete commands. CRC-16/CCITT-FALSE covers the count byte
and payload bytes; FPGA builds may disable CRC comparison without changing the
wire layout. `CMD_FIFO_STATUS` is the diagnostic observation of the downstream
command path.

Version 14 has no register-based command injection. This removes the partial
command and mixed-ingress failure modes of the former `CMD_FIFO_DATA` debug
path. Hardware, simulation harnesses, and production hosts all submit complete
command transactions through the dedicated command stream.

Version 15 recovery uses the independent four-byte frame `a6 00 aa d7`.
It cancels unpublished SPI staging, clears `CMD_FIFO_STATUS` occupancy, and
resets the parser without changing active voices or audio/effect configuration.

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
through 511. A stale generation is rejected and summarized in
`CMD_FIFO_STATUS[31]`.

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

`PLATFORM_STATUS` fields are:

| Bits | Field | Meaning |
| ---: | --- | --- |
| `0` | `PLATFORM_REGS_PRESENT` | constant one when this platform window responds |
| `1` | `ERROR_PRESENT` | SD or loader primary error code is nonzero |
| `2` | `DDR_CALIBRATED` | MIG initialization/calibration completed |
| `4` | `SD_INITIALIZED` | SD initialization completed |
| `5` | `ASSET_LOADED` | WTSF payload load completed |
| `6` | `ASSET_LOADER_BUSY` | asset loader is active |
| `15` | `SD_CARD_PRESENT` | debounced active-low card-detect input reports a card |
| `16` | `SD_HIGH_SPEED_ACTIVE` | CMD6 selected SD High Speed mode |

Bits `3`, `14:7`, and `31:17` are zero. Detailed MIG handshake/reset state is
reported only by `PLATFORM_DDR_STATUS`, and loader state is reported only by
`PLATFORM_ERRORS`. An initialized Default Speed-only card has
`SD_INITIALIZED` set and `SD_HIGH_SPEED_ACTIVE` clear.

`PLATFORM_ERRORS` packs the SD error code in bits `7:0`, loader error code in
bits `15:8`, loader state in bits `19:16`, and the saturating SD block-retry count
in bits `27:20`. Bits `31:28` report SD recovery status: `0` means no secondary
recovery failure, `1` means CMD12 transport/card-status failure, and `2` means
CMD12 DAT0 busy timeout. When a failed CMD18 block is followed by a CMD12 failure,
the primary SD error remains the original data error while this field records the
stop failure.

The SD error codes are:

| Code | Meaning |
| ---: | --- |
| `0` | no error |
| `1` | CMD8 failure |
| `2` | ACMD41 failure |
| `3` | card is not SDHC/SDXC |
| `4` | CMD2 failure |
| `5` | CMD3 failure |
| `6` | CMD7 failure |
| `7` | ACMD6 failure |
| `8` | CMD17/CMD18 read-command failure |
| `9` | data-transfer or recovery-data failure |
| `10` | CMD6 query failure |
| `13` | card-status error bits set |
| `14` | unexpected card state |
| `15` | DAT0 busy timeout |
| `16` | initialization timeout |
| `17` | ACMD42 failure |
| `18` | CMD6 High Speed selection failure |
| `19` | card requires a power cycle after failed mode selection |
| `20` | ACMD51 failure |
| `21` | CMD12 failure |

The asset-loader error codes are:

| Code | Meaning |
| ---: | --- |
| `0` | no error |
| `1` | invalid WTSF magic |
| `2` | unsupported WTSF version |
| `3` | empty image |
| `4` | DDR writer failure |
| `5` | LBA range overflow |
| `6` | image-size range error |

The loader-state field uses `0` for idle, `1` for DDR calibration, `2` for
header reading, `3` for SF2 loading, `4` for verification, `5` for loaded, and
`15` for error. Values not listed in the error-code tables are reserved.

`PLATFORM_DDR_STATUS` separates the same live MIG signals from the loader
summary:

| Bits | Field | Meaning |
| ---: | --- | --- |
| `0` | `DDR_CALIBRATED` | MIG initialization/calibration completed |
| `1` | `DDR_UI_RESET` | MIG UI clock domain is in reset |
| `2` | `MIG_APP_READY` | application command channel ready |
| `3` | `MIG_WRITE_DATA_READY` | write-data channel ready |
| `4` | `MIG_READ_DATA_VALID` | read-data output valid |
| `5` | `MIG_READ_DATA_END` | read-data burst end |
| `27:16` | `DEVICE_TEMP_RAW` | raw 12-bit MIG device-temperature code |

`DDR_ACCESS_CONTROL` is written with `START` at bit 0, `WRITE` at bit 1, and
`CLEAR` at bit 2. `START` is accepted only while `DDR_ACCESS_STATUS.READY` is
set. `CLEAR` clears the sticky completion and error flags. Reading the control
register returns only the last accepted direction in bit 1.

`DDR_ACCESS_STATUS` contains constant `PRESENT` at bit 0, live `READY` and
`BUSY` at bits 1 and 2, sticky `DONE` and `ERROR` at bits 3 and 4, and the last
accepted `WRITE` direction at bit 5. `DDR_ACCESS_ADDR` is a byte address and
must be 16-byte aligned and within the MIG range. `DDR_ACCESS_BYTE_ENABLE[15:0]`
selects bytes for writes and resets to all ones; an all-zero mask is rejected.
Writes to `DDR_ACCESS_DATA0` through `DATA3` stage a 128-bit write beat, while
reads return the most recently captured DDR read beat rather than the staged
write data.
