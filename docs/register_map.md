# Multi-Voice Register Map

The address and bit-mask constants in this document are mirrored from
`spec/register_map.json`. The JSON source uses a CMSIS-SVD-inspired structure:
`device.peripherals[].registers[].fields[]` describes the software-visible
address space, while top-level `constants` holds shared non-register numeric
values exported to generated RTL and C++ headers. Run
`make generate-register-map` after changing the JSON source so RTL and C++ users
pick up the same register contract.

The simplified bus uses 16-bit byte addresses and 32-bit data. Transactions are
single-beat and 32-bit aligned. The abstract register bus carries a numeric
32-bit word; it is not a byte-addressable memory port and does not define a CPU
little-endian or big-endian storage order. Register fields use normal
SystemVerilog bit numbering: bit 0 is the least-significant bit, and ranges such
as bits 15:0 or 31:16 refer to positions in that 32-bit word. Many fields are
narrower than 32 bits and explicitly define which bits are meaningful.
RTL module boundaries that consume the generic register bus use
`synth_pkg::reg_bus_req_t` for `valid/write/address/wdata` and
`synth_pkg::reg_bus_rsp_t` for `rdata/ready/error`. Top-level and board transport
wrappers may still expose the same fields as separate pins when that keeps
external integration stable.
Wave-memory base addresses are 32-bit word addresses. Writes to configuration
registers update per-voice shadow state. Writing `VOICE_CONTROL.apply` copies the
selected shadow configuration into renderer-facing active storage and stages a
render-boundary commit pulse for phase reload and filter-history clear. Writes
to runtime registers do not require a voice commit, update live runtime state
directly, and do not reload playback phase.

Board-level adapters expose this same register bus through the selected physical
transport. The current `fpga/common/rtl/spi_register_bridge.sv` adapter supports
single-register and auto-increment SPI frames. Each frame starts with an 8-bit
command and a 16-bit byte address. Command bit 7 selects write when set and read
when clear. Command bit 6 selects an auto-increment burst when set. Command bits
5:0 are reserved. Single-register writes use `0x80`, single-register reads use
`0x00`, burst writes use `0xc0`, and burst reads use `0x40`.

Each SPI data beat is one 32-bit register word serialized most-significant byte
first and most-significant bit first within each byte. For example, register
value `0x12345678` is transferred on SPI as bytes `12 34 56 78`, with bit 31
seen first on the data phase. Burst frames keep chip select asserted after the
first data beat and access the next register at `address + 4` for each
additional beat. Chip-select deassertion ends the burst. The SPI master must
leave enough system-clock cycles between the address phase and the first read
data phase, and between burst read data beats, for the bridge to complete the
internal register-bus access. Burst writes also require enough system-clock
cycles between data beats for the previous internal write to be accepted. This is
a simulation-friendly transport, not a board timing contract.

The current SPI bridge is not a nonstop streaming SPI target. The SPI pins are
sampled into `clk`, and the bridge has no wire-level ready/backpressure signal.
For a `100 MHz` system clock, start hardware bring-up around `1 MHz` SCLK. After
basic read/write smoke tests pass, `2 MHz` and `5 MHz` are reasonable next test
points. Treat `10 MHz` as something that must be measured on the selected board,
and do not assume higher rates without adding board timing constraints and a more
complete SPI front end. A rough edge-sampling limit is `SCLK <= clk / 10`, but
internal register latency can require slower operation or explicit gaps even
when edge sampling itself is reliable.

Single-register writes are the least sensitive case because the data word is
captured before the internal write starts, but chip select must remain asserted
long enough for the accepted write to reach `bus_ready`. Single-register reads
must leave a turnaround gap after the address phase before the 32 read-data
clocks. Burst writes must leave a gap after each 32-bit data beat so the previous
internal write can complete; otherwise later MOSI bits can be ignored while the
bridge is in its write-wait state. Burst reads must leave a gap before each
readback word so the next internal read can complete. Put long-latency writes
such as `VOICE_CONTROL.apply` at the end of a burst or issue them as separate
single-register writes. Supporting gapless high-speed burst traffic requires additional RTL, such
as a write-side RX FIFO and read-side prefetch/FIFO or a protocol-defined fixed
dummy-cycle interval.

The default build exposes 256 voice slots. Slot 0 keeps the original base
address. Slot N uses `0x0100 + N * 0x80` plus the offsets below.

```text
voice_base(slot) = 0x0100 + slot * 0x80
register_addr    = voice_base(slot) + offset
```

| Offset | Name | Description |
| --- | --- | --- |
| `0x00` | BASE_ADDR | left/mono 16-bit-word memory address |
| `0x04` | BASE_ADDR_R | right-channel 16-bit-word memory address |
| `0x08` | LENGTH | left/mono sample-frame count in bits 23:0 |
| `0x0c` | LENGTH_R | right-channel sample-frame count in bits 23:0 |
| `0x10` | LOOP_START | left/mono first loop frame in bits 23:0 |
| `0x14` | LOOP_START_R | right-channel first loop frame in bits 23:0 |
| `0x18` | LOOP_END | left/mono exclusive loop end frame in bits 23:0 |
| `0x1c` | LOOP_END_R | right-channel exclusive loop end frame in bits 23:0 |
| `0x20` | PHASE_INIT | unsigned Q24.8 initial position |
| `0x24` | PHASE_INC | unsigned Q24.8 frames per output sample |
| `0x28` | GAIN | bits 15:0 left signed Q1.15, bits 31:16 right signed Q1.15 |
| `0x2c` | ENVELOPE | initial signed Q1.15 envelope copied to runtime on commit |
| `0x30` | FILTER_CONTROL | bit 0 shadow enable |
| `0x34` | FILTER_B0_B1 | bits 15:0 signed Q2.14 `b0`, bits 31:16 signed Q2.14 `b1` |
| `0x38` | FILTER_B2_A1 | bits 15:0 signed Q2.14 `b2`, bits 31:16 signed Q2.14 `a1` |
| `0x3c` | FILTER_A2 | bits 15:0 signed Q2.14 `a2`; write bit 16 as one to commit shadow filter settings to runtime; read bits 31:16 as zero |
| `0x40` | VOICE_CONTROL | bit 0 stereo, bits 2:1 loop mode, bit 3 enable, write bit 4 as one to commit the voice |
| `0x44` | PHASE_INC_RUNTIME | runtime unsigned Q24.8 phase increment |
| `0x48` | GAIN_RUNTIME | bits 15:0 left Q1.15, bits 31:16 right Q1.15 |
| `0x4c` | ENVELOPE_RUNTIME | runtime signed Q1.15 envelope level in bits 15:0 |
| `0x50` | RELEASE_CONTROL | bit 0 released runtime flag |
| `0x54` | STATUS | bit 0 configuration valid for this voice slot |
| `0x9000` | VERSION | design version, currently `0x0006_0000` |
| `0x9010` | SYSTEM_STATUS | system wrapper status bits |
| `0x9014` | COMMON_EVENT_FLAGS | sticky event flags, write one to clear |
| `0x9018` | AUDIO_STATUS | output FIFO and audio flags |
| `0x901c` | RENDER_STATUS | render pending, deadline flag, and last latency |
| `0x9020` | MEMORY_STATUS | external line-memory request/response status and last response latency |
| `0x9024` | UNDERRUN_COUNT | saturating I2S underrun counter |
| `0x9028` | SAMPLE_DROP_COUNT | saturating output FIFO overflow/drop counter |
| `0x902c` | RENDER_DEADLINE_MISS_COUNT | saturating render deadline miss counter |
| `0x9030` | EVENT_TIME | next accepted render sample timestamp |
| `0x9034` | EVENT_FIFO_STATUS | envelope event FIFO empty/full/level and error flags |
| `0x9038` | MEM_RESPONSE_COUNT | saturating external memory response counter |
| `0x9040` | PLATFORM_STATUS | Smart Artix SD/DDR/asset-loader status bits |
| `0x9044` | PLATFORM_ERRORS | SD error, loader error, and loader state |
| `0x9048` | PLATFORM_BYTES_LOADED | SD asset bytes loaded |
| `0x9050` | PLATFORM_SF2_SIZE | SF2 byte size from the SD image header |
| `0x9058` | PLATFORM_CURRENT_LBA | current SD LBA being loaded |
| `0x905c` | PLATFORM_DDR_STATUS | Smart Artix MIG status and temperature |
| `0x9060` | DDR_ACCESS_CONTROL | single-beat DDR register-access command control |
| `0x9064` | DDR_ACCESS_STATUS | single-beat DDR register-access command status |
| `0x9068` | DDR_ACCESS_ADDR | 128-bit-beat-aligned DDR byte address |
| `0x906c` | DDR_ACCESS_BYTE_ENABLE | write byte-enable bits, bit 0 controls byte 0 |
| `0x9070` | DDR_ACCESS_DATA0 | write data/readback bits 31:0 |
| `0x9074` | DDR_ACCESS_DATA1 | write data/readback bits 63:32 |
| `0x9078` | DDR_ACCESS_DATA2 | write data/readback bits 95:64 |
| `0x907c` | DDR_ACCESS_DATA3 | write data/readback bits 127:96 |
| `0x9080` | EVENT_FIFO_DATA0 | envelope event timestamp word |
| `0x9084` | EVENT_FIFO_DATA1 | envelope event payload0/opcode/voice word |
| `0x9088` | EVENT_FIFO_DATA2 | envelope event payload1 word |
| `0x908c` | EVENT_FIFO_PUSH | write one to push the assembled event |

A mono configuration is valid when `length != 0`. A stereo configuration is valid
when both `length != 0` and `length_r != 0`. `length`, `length_r`, loop starts,
and loop ends are 24-bit frame counts. Looping modes additionally require each
active channel to satisfy `loop_start < loop_end` and `loop_end <= length` for
that channel. Invalid active configurations do not produce memory requests or
audio samples.
The maximum represented region length is `0x00ff_ffff` frames.

`VOICE_CONTROL` fields are:

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `stereo` | `0` mono, `1` stereo with independent right-channel region fields. |
| `2:1` | `loop_mode` | Loop policy copied to active state on `VOICE_CONTROL.apply`. |
| `3` | `enable` | Shadow voice enable copied to active state on `VOICE_CONTROL.apply`. |
| `4` | `apply` | Write-only commit strobe; reads zero. |
| `31:5` | reserved | Reads zero. |

`VOICE_CONTROL.loop_mode` values are:

| Value | Name | Behavior |
| --- | --- | --- |
| `0` | no loop | play through `length`, then stop contributing |
| `1` | continuous loop | wrap from exclusive `loop_end` to `loop_start` |
| `2` | loop until release | loop while `released == 0`, then play through to `length` |

Configuration registers are `VOICE_CONTROL`, `BASE_ADDR`, `BASE_ADDR_R`, `LENGTH`,
`LENGTH_R`, `LOOP_START`, `LOOP_START_R`, `LOOP_END`, `LOOP_END_R`,
`PHASE_INIT`, `PHASE_INC`, `GAIN`, `ENVELOPE`, and the filter
registers. Reads from these addresses return the current shadow state through the
normal per-voice register map. Because the underlying storage is synchronous RAM,
read transactions may take multiple `clk` cycles; bus masters must hold the
request until `bus_ready` is asserted.

Runtime registers are `ENVELOPE_RUNTIME`, `PHASE_INC_RUNTIME`, `GAIN_RUNTIME`, and
`RELEASE_CONTROL`. Filter coefficient and control writes update shadow filter
state; writing `FILTER_A2` with bit 16 set commits the complete shadow filter
group to runtime without a phase reload. Reads from `ENVELOPE_RUNTIME`,
`PHASE_INC_RUNTIME`, `GAIN_RUNTIME`, and `RELEASE_CONTROL` return the live
runtime scalar state. `VOICE_CONTROL[4]` and `FILTER_A2[31:16]` read as zero.
Unsupported addresses report a bus error.

The system event FIFO is a low-rate envelope primitive path. `EVENT_TIME`
returns the timestamp that will be assigned to the next accepted render sample.
The core captures that timestamp when `sample_tick && !busy` is accepted, so an
event with `timestamp == EVENT_TIME` is eligible for the sample requested by the
next accepted tick.

An envelope event is assembled in three 32-bit data registers and pushed by
writing `EVENT_FIFO_PUSH`:

```text
EVENT_FIFO_DATA0[31:0] = timestamp
EVENT_FIFO_DATA1[31:16] = payload0
EVENT_FIFO_DATA1[15:8]  = opcode
EVENT_FIFO_DATA1[7:0]   = voice_id
EVENT_FIFO_DATA2[31:0]  = payload1
```

`EVENT_FIFO_STATUS` fields are:

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `empty` | Event FIFO contains no entries. |
| `1` | `full` | Event FIFO cannot accept `EVENT_FIFO_PUSH`; pushing while full reports a bus error. |
| `7:2` | `level` | Current FIFO level, saturated by the implemented FIFO depth. |
| `16` | `late` | Sticky flag: an event was processed after its timestamp. |
| `17` | `order_error` | Sticky flag: a same-timestamp event targets a voice whose scan slot has already passed. |
| `31:18` | reserved | Reads zero. |

Supported envelope event opcodes are:

| Opcode | Name | Payload |
| --- | --- | --- |
| `1` | `EVT_ENV_SET` | `payload0 = value_q15`; sets the generated envelope level. |
| `2` | `EVT_VOL_ATTACK` | `payload0 = target_q15`, `payload1 = duration_samples`; linear ramp from zero. |
| `3` | `EVT_VOL_DECAY_CB` | `payload0 = start_cb`, `payload1[15:0] = target_cb`, `payload1[31:16] = cb_step`; integer cB fields are converted to Q8.8 internally. |
| `4` | `EVT_VOL_RELEASE_CB` | `payload0 = start_cb`, `payload1[31:16] = cb_step`; output reaches zero at 960 cB or above. |
| `5` | `EVT_RELEASE_FLAG` | Sets the runtime `released` flag for loop-until-release voices. |
| `6` | `EVT_STOP_VOICE` | Sets generated envelope to zero and stops the generated envelope state. |

Decay and release advance linearly in cB, but the renderer-facing Q1.15 envelope
uses the generated SoundFont amplitude table:
`round(32767 * 10 ^ (-centibel / 200))`. The generated table covers `0..960 cB`
at 4 cB intervals; RTL and C++ reference both linearly interpolate adjacent table
entries with the internal Q8.8 cB fraction. The table is generated by
`tools/gen_envelope_lut.py`.

Software must write events in timestamp order and, within the same timestamp, in
ascending voice order. The renderer scans voices in ascending order; at each
runtime snapshot it consumes FIFO-head events whose `timestamp <= current sample`
and whose `voice_id` matches the scanned voice. Up to four same-voice events may
be consumed at one snapshot so common sequences such as `SET` followed by
`ATTACK` at the same timestamp take effect without an extra sample of delay.

The per-voice register bank keeps three classes of state. Shadow state is the
software-editable configuration staged for the next commit. Active state is the
stable renderer-facing region configuration copied from shadow by
`VOICE_CONTROL.apply`.
Runtime state holds controls that may change while a voice is playing.

| Register or field | Shadow | Active | Runtime | Notes |
| --- | --- | --- | --- | --- |
| `BASE_ADDR`, `BASE_ADDR_R` | yes | yes | no | Sample-region word base addresses. |
| `LENGTH`, `LENGTH_R` | yes | yes | no | Sample-frame counts. |
| `LOOP_START`, `LOOP_START_R`, `LOOP_END`, `LOOP_END_R` | yes | yes | no | Loop-window frame counts. |
| `VOICE_CONTROL.stereo`, `VOICE_CONTROL.loop_mode`, `VOICE_CONTROL.enable` | yes | yes | no | Voice mode and enable copied on `VOICE_CONTROL.apply`. |
| `PHASE_INIT` | yes | yes | no | Initial phase used when a commit reloads the voice. |
| `PHASE_INC` | yes | no | yes | Initial phase increment copied into runtime on voice commit. |
| `PHASE_INC_RUNTIME` | no | no | yes | Immediate runtime pitch update; does not change shadow. |
| `GAIN` | yes | no | yes | Initial packed channel gains copied into runtime on voice commit. |
| `GAIN_RUNTIME` | no | no | yes | Immediate packed runtime gain update; does not change shadow. |
| `ENVELOPE` | yes | no | yes | Initial envelope copied into runtime on voice commit. |
| `ENVELOPE_RUNTIME` | no | no | yes | Immediate runtime envelope update; does not change shadow. |
| `RELEASE_CONTROL` | no | no | yes | Runtime release flag; voice commit clears it. |
| `FILTER_CONTROL`, `FILTER_B0_B1`, `FILTER_B2_A1`, `FILTER_A2` | yes | no | yes | Shadow filter group is copied to runtime by voice commit or `FILTER_A2[16]`. |
| `STATUS` | no | no | no | Read-only view of the committed configuration-valid bit. |

The common status registers are implemented by
`fpga/common/rtl/wavetable_common_status_regs.sv` and are composed into the
current SPI/I2S system wrapper. They are visible through whichever board-level
register transport is connected to that wrapper. Platform status and DDR
register-access controls are implemented by board-specific platform register
windows such as `fpga/smart_artix/rtl/smart_artix_platform_regs.sv`; wrappers
without that window may report those addresses as normal unsupported register
accesses. The platform register window remains available while the playback
core/audio path is held in `core_rst`; core register accesses during that reset
return a bus error instead of stalling the transport bridge.

All unspecified or reserved bits in the common status registers read as zero. The
status bits below are live snapshots unless explicitly marked sticky or counted.

`SYSTEM_STATUS` (`0x9010`) is the main live activity snapshot:

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `core_busy` | `wavetable_cached_render_core` is currently rendering or servicing work. |
| `1` | `render_pending` | A sample tick has been accepted and the wrapper is waiting for `core_sample_valid`. |
| `2` | `core_sample_valid` | The core produced a stereo sample in the current cycle. |
| `3` | `fifo_sample_valid` | The output FIFO contains at least one sample for I2S. |
| `4` | `i2s_sample_ready` | The I2S transmitter is ready to accept the next stereo sample. |
| `5` | `ext_req_valid` | The line-memory subsystem is requesting an external memory line. |
| `6` | `ext_req_ready` | The board memory adapter can accept the line request. |
| `7` | `ext_rsp_valid` | A packed external memory-line response is valid in this cycle. |
| `31:8` | reserved | Reads zero. |

`COMMON_EVENT_FLAGS` (`0x9014`) contains sticky event flags. Write ones to clear
selected bits. Events that occur in the same cycle as a clear remain set.

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `underrun` | I2S needed a sample when the output FIFO was empty. |
| `1` | `sample_drop` | The core produced a sample when the output FIFO could not accept it. |
| `2` | `render_deadline_miss` | A new sample tick arrived while the previous render was still pending. |
| `3` | `mem_response` | The wrapper observed an external memory-line response. |
| `31:4` | reserved | Reads zero. |

The matching counters at `0x9024` through `0x9038` increment on the same events
and saturate at `0xffff_ffff`. They are reset only by system reset and are not
cleared by writes to `COMMON_EVENT_FLAGS`.

`AUDIO_STATUS` (`0x9018`) summarizes the output FIFO and audio sticky flags:

| Bits | Field | Meaning |
| --- | --- | --- |
| `15:0` | `output_fifo_level` | Current number of samples stored in the output FIFO. |
| `16` | `underrun` | Mirror of sticky `COMMON_EVENT_FLAGS[0]`. |
| `17` | `sample_drop` | Mirror of sticky `COMMON_EVENT_FLAGS[1]`. |
| `31:18` | reserved | Reads zero. |

`RENDER_STATUS` (`0x901c`) reports render scheduling state:

| Bits | Field | Meaning |
| --- | --- | --- |
| `15:0` | `render_latency_cycles` | Last completed render latency in `clk` cycles, measured from `sample_tick` until `core_sample_valid`. Saturates internally while pending at `0xffff`. |
| `16` | `render_pending` | Same live pending bit as `SYSTEM_STATUS[1]`. |
| `17` | `render_deadline_miss` | Mirror of sticky `COMMON_EVENT_FLAGS[2]`. |
| `31:18` | reserved | Reads zero. |

`MEMORY_STATUS` (`0x9020`) reports line-memory activity:

| Bits | Field | Meaning |
| --- | --- | --- |
| `15:0` | `mem_response_latency` | Last measured latency from an external line request to its response, in `clk` cycles. |
| `16` | `ext_req_valid` | Same live request-valid bit as `SYSTEM_STATUS[5]`. |
| `17` | `ext_req_ready` | Same live request-ready bit as `SYSTEM_STATUS[6]`. |
| `18` | `ext_rsp_valid` | Same live response-valid bit as `SYSTEM_STATUS[7]`. |
| `19` | `mem_response` | Mirror of sticky `COMMON_EVENT_FLAGS[3]`. |
| `31:20` | reserved | Reads zero. |

The event counters are direct 32-bit saturating reads:

| Address | Name | Event counted |
| --- | --- | --- |
| `0x9024` | `UNDERRUN_COUNT` | I2S underrun pulses. |
| `0x9028` | `SAMPLE_DROP_COUNT` | Output FIFO sample-drop pulses. |
| `0x902c` | `RENDER_DEADLINE_MISS_COUNT` | New sample ticks that arrive while a previous render is pending. |
| `0x9038` | `MEM_RESPONSE_COUNT` | External memory-line response pulses. |

`PLATFORM_STATUS` (`0x9040`) is the Smart Artix board-status word. Generic
wrappers may leave this address unimplemented unless they attach a board-specific
platform-register extension.

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `platform_regs_present` | `1` when the board wrapper implements this platform register window. |
| `1` | `platform_error_present` | `sd_error_code != 0` or `loader_error_code != 0`. |
| `2` | `ddr_init_calib_complete` | MIG DDR3 calibration complete. This must be `1` before normal DDR-backed playback. |
| `3` | `ddr_ui_rst` | MIG UI-clock reset is asserted. This should be `0` for normal operation. |
| `4` | `sd_initialized` | The SD initialization sequence completed. |
| `5` | `asset_loaded` | The raw SD asset image has been copied into DDR3 and playback reset can release. |
| `6` | `asset_loader_busy` | The SD-to-DDR loader is active. |
| `7` | `mig_app_rdy` | MIG app command channel can accept a command. |
| `8` | `mig_app_wdf_rdy` | MIG app write-data channel can accept write data. |
| `9` | `mig_app_rd_data_valid` | MIG read-data beat is valid in this cycle. |
| `10` | `mig_app_rd_data_end` | MIG read-data beat marks the end of the read response. |
| `14:11` | `asset_loader_state` | Board loader state code, useful for locating SD/header/write progress or failure. |
| `31:15` | reserved | Reads zero. |

`PLATFORM_ERRORS` (`0x9044`) captures board loader error detail:

| Bits | Field | Meaning |
| --- | --- | --- |
| `7:0` | `sd_error_code` | SD command/data path error code from the board loader. Zero means no SD error. |
| `15:8` | `loader_error_code` | Raw-image header, bounds, CRC, or DDR writer-side loader error code. Zero means no loader error. |
| `19:16` | `asset_loader_state` | Same loader state code as `PLATFORM_STATUS[14:11]`. |
| `31:20` | reserved | Reads zero. |

In the current Smart Artix top, `sd_error_code` is produced by the native-mode SD
block reader:

| Code | Name | Meaning |
| --- | --- | --- |
| `0` | `ERROR_NONE` | No SD error. |
| `1` | `ERROR_CMD8` | SD v2 interface-condition command failed or returned an unexpected response. |
| `2` | `ERROR_ACMD41` | Card did not complete high-capacity initialization before the retry limit. |
| `3` | `ERROR_NOT_SDHC` | Card initialized but did not report SDHC/SDXC high-capacity addressing. |
| `4` | `ERROR_CMD2` | Card-identification command failed. |
| `5` | `ERROR_CMD3` | Relative-card-address assignment failed. |
| `6` | `ERROR_CMD7` | Card-select command failed. |
| `7` | `ERROR_ACMD6` | 4-bit bus-width selection failed. |
| `8` | `ERROR_CMD17` | Single-block read command failed. |
| `9` | `ERROR_DATA` | Read data stream ended with a nonzero PHY data status. |
| `10` | `ERROR_CMD6` | High-speed switch command or its 64-byte status data block failed. |
| `11` | `ERROR_CMD23` | Predeclared multi-block count command failed. |
| `12` | `ERROR_CMD18` | Multi-block read command failed. |

`loader_error_code` is produced by the raw SD-to-DDR asset loader:

| Code | Name | Meaning |
| --- | --- | --- |
| `0` | `ERROR_NONE` | No loader error. |
| `1` | `ERROR_BAD_MAGIC` | Sector-0 raw-image header magic was not `WTSF`. |
| `2` | `ERROR_BAD_VERSION` | Raw-image header version was unsupported. |
| `3` | `ERROR_EMPTY_IMAGE` | Header reported an SF2 byte size of zero. |
| `4` | `ERROR_WRITER` | DDR writer reported an error while copying the asset payload. |
| `5` | `ERROR_LBA_RANGE` | Header SF2 start LBA could not fit the configured SD LBA width. |
| `6` | `ERROR_SIZE_RANGE` | Header reserved size word was nonzero, so the SF2 size exceeded the current 32-bit loader limit. |

`PLATFORM_BYTES_LOADED` (`0x9048`) reports the 32-bit count of SF2 asset bytes
written to DDR3. `PLATFORM_SF2_SIZE` (`0x9050`) reports the 32-bit SF2 byte size
read from the raw SD image header. For the current board-loading flow, assets are
expected to fit below 4 GiB. A successful load should end with
`PLATFORM_BYTES_LOADED == PLATFORM_SF2_SIZE` and `PLATFORM_STATUS[5] = 1`.

`PLATFORM_CURRENT_LBA` (`0x9058`) reports the current SD logical block address the
loader is reading or most recently requested. During bring-up it helps distinguish
SD initialization, sector-0 header parsing, and later SF2 data-copy progress.

`PLATFORM_DDR_STATUS` (`0x905c`) gives a DDR/MIG-focused view:

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `ddr_init_calib_complete` | Same as `PLATFORM_STATUS[2]`. |
| `1` | `ddr_ui_rst` | Same as `PLATFORM_STATUS[3]`. |
| `2` | `mig_app_rdy` | Same as `PLATFORM_STATUS[7]`. |
| `3` | `mig_app_wdf_rdy` | Same as `PLATFORM_STATUS[8]`. |
| `4` | `mig_app_rd_data_valid` | Same as `PLATFORM_STATUS[9]`. |
| `5` | `mig_app_rd_data_end` | Same as `PLATFORM_STATUS[10]`. |
| `15:6` | reserved | Reads zero. |
| `27:16` | `ddr_device_temp` | MIG `device_temp` field, passed through from the generated DDR3 controller. |
| `31:28` | reserved | Reads zero. |

The DDR register-access window at `0x9060` through `0x907c` is a Smart Artix
bring-up path for single 128-bit DDR beat reads and writes through the same SPI
register transport. It is not part of the generic playback memory interface. The
address is a MIG byte address and must be 16-byte aligned for the current 128-bit
board configuration. Unaligned commands report `error` and do not access DDR.

`DDR_ACCESS_CONTROL` (`0x9060`) starts and clears a command:

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `start` | Write one to start one DDR register-access command when `DDR_ACCESS_STATUS.ready = 1`. |
| `1` | `write` | Command direction sampled with `start`: one writes DDR, zero reads DDR. |
| `2` | `clear` | Write one to clear latched `done` and `error` status bits. |
| `31:3` | reserved | Reads zero. |

`DDR_ACCESS_STATUS` (`0x9064`) reports command state:

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `present` | DDR register-access window is implemented. |
| `1` | `ready` | A new command can be accepted. |
| `2` | `busy` | A command is in progress. |
| `3` | `done` | Sticky completion flag; clear through `DDR_ACCESS_CONTROL.clear`. |
| `4` | `error` | Sticky command error flag; clear through `DDR_ACCESS_CONTROL.clear`. |
| `5` | `write` | Direction of the most recently accepted command. |
| `31:6` | reserved | Reads zero. |

For writes, load `DDR_ACCESS_ADDR`, `DDR_ACCESS_BYTE_ENABLE`, and the four
`DDR_ACCESS_DATA*` words, then write `DDR_ACCESS_CONTROL = 0x3`. `BYTE_ENABLE`
uses one bit per byte, where one means the byte is written; the board wrapper
converts it to the MIG active-high write-data mask. A write with no enabled bytes
reports `error` and does not access DDR. For reads, load `DDR_ACCESS_ADDR`, write
`DDR_ACCESS_CONTROL = 0x1`, poll `DDR_ACCESS_STATUS.done`, then read
`DDR_ACCESS_DATA0` through `DDR_ACCESS_DATA3`.

`RELEASE_CONTROL.released` is runtime state. Writes update the runtime released
flag without reloading phase. A voice commit clears the runtime released flag so
a reused voice starts in the held state. `VOICE_CONTROL.loop_mode` is a shadow
configuration field and becomes active on voice commit.

`ENVELOPE` is a shadow configuration field copied into runtime envelope by voice
commit. The default reset value is zero; software must write the desired initial
level explicitly. `ENVELOPE_RUNTIME` updates the live envelope value without
requiring a voice commit and without reloading playback phase. This lets MCU
firmware or a testbench model advance attack, decay, sustain, and release curves
while the FPGA pipeline keeps rendering the same note.

`GAIN` is a shadow configuration field copied into runtime gain by voice
commit. It uses the same packed layout as `GAIN_RUNTIME`: bits 15:0 hold left
Q1.15 gain and bits 31:16 hold right Q1.15 gain. `GAIN_RUNTIME` updates both
runtime channel gains in one bus write
without copying shadow registers and without reloading playback phase. Use this
path for MIDI volume, expression, pan, or similar low-rate controller changes
where a two-write left/right gain update could otherwise be visible over SPI.

`PHASE_INC_RUNTIME` writes update the runtime phase increment without copying
shadow registers and without reloading runtime phase. Use this path for
pitch bend or low-rate vibrato control.

The filter registers configure a per-voice biquad IIR filter placed after
interpolation and before channel gain. `FILTER_CONTROL[0]`, `FILTER_B0_B1`,
`FILTER_B2_A1`, and `FILTER_A2` form one shadow filter group. A voice commit
copies that group into runtime filter state for a new note. During active
playback, write the desired shadow filter group first, then write `FILTER_A2`
with bit 16 set; that writes `a2` and copies the shadow enable plus all five
coefficients to runtime together without reloading phase. Filter history is per voice and per
channel and is cleared on voice commit. `FILTER_CONTROL.enable = 0` bypasses the
filter. The denominator convention is `1 + a1*z^-1 + a2*z^-2`; the RTL computes
`b0*x + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]` using a transposed form.

The RTL does not implement SF2 preset selection, velocity mapping, modulators, or
coefficient calculation; software writes already-quantized signed Q2.14 filter
coefficients. `FILTER_A2[16]` is a write-only commit strobe; `FILTER_A2[31:17]`
is unused. Reads return all `FILTER_A2` upper bits as zero.
A value of `0x7fff` is treated as full envelope level and bypasses the envelope
factor. For other envelope values, the renderer applies channel gain and envelope
as one wide output-scale product and saturates once to PCM16, avoiding the extra
precision loss of an intermediate gain-stage PCM16 truncation.

## Minimal Control Sequences

The FPGA does not allocate voices or parse MIDI. Software chooses a free slot,
loads sample metadata into that slot, and drives runtime controls over time. The
smallest useful actions are below.

### Note On

For a new note, write the complete shadow configuration, then commit. Writing
`VOICE_CONTROL.apply` updates the active renderer configuration, stages
`PHASE_INC`, `GAIN`, and `ENVELOPE` into runtime pitch/gain/envelope, clears the staged
`RELEASE_CONTROL.released`, and requests phase reload from `PHASE_INIT` plus
filter-history clear at the next accepted output-frame boundary. Software should
not depend on a committed voice being rendered before that boundary pulse has
been accepted.

Minimal mono no-loop Note On for `slot`:

| Write order | Address | Data |
| ---: | --- | --- |
| 1 | `voice_base(slot) + 0x00` through `+ 0x40` | Burst write the fields below in order. |
| 1.0 | `voice_base(slot) + 0x00` `BASE_ADDR` | first left/mono wave-memory word |
| 1.1 | `voice_base(slot) + 0x04` `BASE_ADDR_R` | ignored for mono; commonly mirror `BASE_ADDR` |
| 1.2 | `voice_base(slot) + 0x08` `LENGTH` | sample-frame count |
| 1.3 | `voice_base(slot) + 0x0c` `LENGTH_R` | ignored for mono; commonly mirror `LENGTH` |
| 1.4 | `voice_base(slot) + 0x10` `LOOP_START` | `0` for no-loop voices |
| 1.5 | `voice_base(slot) + 0x14` `LOOP_START_R` | ignored for mono; commonly mirror `LOOP_START` |
| 1.6 | `voice_base(slot) + 0x18` `LOOP_END` | `0` for no-loop voices |
| 1.7 | `voice_base(slot) + 0x1c` `LOOP_END_R` | ignored for mono; commonly mirror `LOOP_END` |
| 1.8 | `voice_base(slot) + 0x20` `PHASE_INIT` | usually `0x0000_0000` |
| 1.9 | `voice_base(slot) + 0x24` `PHASE_INC` | Q24.8 playback increment |
| 1.10 | `voice_base(slot) + 0x28` `GAIN` | `{right_gain[15:0], left_gain[15:0]}` initial gains |
| 1.11 | `voice_base(slot) + 0x2c` `ENVELOPE` | initial Q1.15 envelope; normal ADSR Note On starts at `0` |
| 1.12 | `voice_base(slot) + 0x30` `FILTER_CONTROL` | `0` to bypass filter |
| 1.13 | `voice_base(slot) + 0x34` `FILTER_B0_B1` | `0x0000_4000` packs `b1=0`, `b0=unity`; harmless when bypassed |
| 1.14 | `voice_base(slot) + 0x38` `FILTER_B2_A1` | `0` |
| 1.15 | `voice_base(slot) + 0x3c` `FILTER_A2` | `0` |
| 1.16 | `voice_base(slot) + 0x40` `VOICE_CONTROL` | `enable=1`, `apply=1`, and desired stereo/loop bits; mono no-loop is `0x18` |

For stereo playback, write `VOICE_CONTROL.stereo = 1`; `BASE_ADDR` names the first
left sample word and `BASE_ADDR_R` names the first right sample word. Write the
right channel window through `LENGTH_R`, `LOOP_START_R`, and `LOOP_END_R`. Phase
and phase increment are still measured in sample frames. For continuous loop or
loop-until-release, write valid per-channel loop starts, exclusive loop ends, and
`VOICE_CONTROL.loop_mode = 1` or `2` when applying the voice.

### Envelope Update

To update amplitude during attack, decay, sustain, or release, write only:

```text
voice_base(slot) + 0x4c ENVELOPE_RUNTIME = current Q1.15 envelope level
```

This does not require a voice commit and does not reload phase. The renderer samples
the live runtime value when it accepts each voice for rendering.

### Note Off

There are two common Note Off policies.

For `VOICE_CONTROL.loop_mode = 2` loop-until-release samples:

| Write order | Address | Data |
| ---: | --- | --- |
| 1 | `voice_base(slot) + 0x50` `RELEASE_CONTROL` | `1` |
| 2..N | `voice_base(slot) + 0x4c` `ENVELOPE_RUNTIME` | decreasing release levels |

When the release envelope reaches zero, free the slot:

| Write order | Address | Data |
| ---: | --- | --- |
| 1 | `voice_base(slot) + 0x40` `VOICE_CONTROL` | current stereo/loop bits, `enable = 0`, `apply = 1` |

For one-shot no-loop voices, software may either let playback naturally stop at
`LENGTH` or immediately start reducing `ENVELOPE_RUNTIME` and then disable/commit
the slot when silent.

### Runtime Pitch And Gain

Pitch bend or low-rate vibrato writes:

```text
voice_base(slot) + 0x44 PHASE_INC_RUNTIME = new Q24.8 phase increment
```

Runtime gain, volume, expression, or pan writes both channels atomically:

```text
voice_base(slot) + 0x48 GAIN_RUNTIME = {right_gain[15:0], left_gain[15:0]}
```

Neither write reloads phase or changes shadow configuration. A later voice commit
will overwrite runtime pitch and gain with the shadow `PHASE_INC` and `GAIN`
values staged for the next note setup.

### Reusing A Slot

Before reusing a slot, software should explicitly write the new note's
`ENVELOPE`, gains, pitch, `VOICE_CONTROL`, filter settings, and then apply
the voice. Do not rely on runtime state left by the
previous note except for the documented commit behavior: commit clears
`RELEASE_CONTROL.released` and reloads phase/filter history at the next accepted
output-frame boundary, but preserves the live runtime envelope level.
