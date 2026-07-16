# Multi-Voice Register Map

The simplified bus uses 16-bit byte addresses and 32-bit data. Transactions are
single-beat and 32-bit aligned. The 32-bit data word is the bus container; many
fields are narrower and explicitly define which bits are meaningful. Wave-memory
base addresses are 32-bit word addresses. Writes to configuration registers
update per-voice shadow state. `COMMIT` copies the selected shadow configuration
into renderer-facing active storage and stages a render-boundary commit pulse for
phase reload and filter-history clear. Writes to runtime registers do not require
`COMMIT`, update live runtime state directly, and do not reload playback phase.

`spi_register_bridge` exposes this same register bus through a simple 56-bit SPI
frame: 8-bit command, 16-bit byte address, then 32-bit data phase. Command bit 7
selects write when set and read when clear; command bits 6:0 are reserved. Read
data is shifted out most-significant bit first during the data phase. The SPI
master must leave enough system-clock cycles between the address phase and read
data phase for the bridge to complete the internal register-bus access. This is
a simulation-friendly transport, not a board timing contract.

The core exposes 32 voice slots. Slot 0 keeps the original base address. Slot N
uses `0x0100 + N * 0x80` plus the offsets below.

```text
voice_base(slot) = 0x0100 + slot * 0x80
register_addr    = voice_base(slot) + offset
```

| Offset | Name | Description |
| --- | --- | --- |
| `0x00` | CONTROL | bit 0 enable, bit 1 stereo |
| `0x04` | BASE_ADDR | left/mono 16-bit-word memory address |
| `0x08` | LENGTH | number of sample frames in bits 23:0 |
| `0x0c` | LOOP_START | first loop frame in bits 23:0 |
| `0x10` | LOOP_END | exclusive loop end frame in bits 23:0 |
| `0x14` | PHASE_INIT | unsigned Q24.8 initial position |
| `0x18` | PHASE_INC | unsigned Q24.8 frames per output sample |
| `0x1c` | GAIN_L | signed Q1.15 in bits 15:0 |
| `0x20` | GAIN_R | signed Q1.15 in bits 15:0 |
| `0x24` | COMMIT | write bit 0 as one to activate this voice slot and stage render-boundary reload |
| `0x28` | STATUS | bit 0 configuration valid for this voice slot |
| `0x2c` | ENVELOPE_LEVEL | runtime signed Q1.15 envelope level in bits 15:0 |
| `0x30` | PHASE_INC_RUNTIME | runtime unsigned Q24.8 phase increment |
| `0x34` | LOOP_MODE | bits 1:0 loop mode |
| `0x38` | FILTER_CONTROL | bit 0 shadow enable |
| `0x3c` | FILTER_B0 | signed Q4.28 `b0` |
| `0x40` | FILTER_B1 | signed Q4.28 `b1` |
| `0x44` | FILTER_B2 | signed Q4.28 `b2` |
| `0x48` | FILTER_A1 | signed Q4.28 `a1` |
| `0x4c` | FILTER_A2 | signed Q4.28 `a2` |
| `0x50` | GAIN_RUNTIME | bits 15:0 left Q1.15, bits 31:16 right Q1.15 |
| `0x54` | RELEASE_CONTROL | bit 0 released runtime flag |
| `0x58` | BASE_ADDR_R | right-channel 16-bit-word memory address |
| `0x5c` | FILTER_COMMIT | write bit 0 as one to commit shadow filter settings to runtime |
| `0x60` | LENGTH_R | right-channel number of sample frames in bits 23:0 |
| `0x64` | LOOP_START_R | right-channel first loop frame in bits 23:0 |
| `0x68` | LOOP_END_R | right-channel exclusive loop end frame in bits 23:0 |
| `0x3000` | VERSION | design version, currently `0x0005_0000` |
| `0x3004` | READBACK_ADDR | write a 16-bit register address to sample through the readback window |
| `0x3008` | READBACK_DATA | read sampled 32-bit data for `READBACK_ADDR` |
| `0x3010` | SYSTEM_STATUS | system wrapper status bits |
| `0x3014` | DEBUG_EVENT_FLAGS | sticky event flags, write one to clear |
| `0x3018` | AUDIO_STATUS | output FIFO and audio flags |
| `0x301c` | RENDER_STATUS | render pending, deadline flag, and last latency |
| `0x3020` | MEMORY_STATUS | memory request/cache status and last response latency |
| `0x3024` | UNDERRUN_COUNT | saturating I2S underrun counter |
| `0x3028` | SAMPLE_DROP_COUNT | saturating output FIFO overflow/drop counter |
| `0x302c` | RENDER_DEADLINE_MISS_COUNT | saturating render deadline miss counter |
| `0x3030` | MEM_HIT_COUNT | saturating line-cache hit counter |
| `0x3034` | MEM_MISS_COUNT | saturating line-cache miss counter |
| `0x3038` | MEM_RESPONSE_COUNT | saturating external memory response counter |
| `0x3040` | PLATFORM_STATUS | Smart Artix SD/DDR/asset-loader status bits |
| `0x3044` | PLATFORM_ERRORS | SD error, loader error, and loader state |
| `0x3048` | PLATFORM_BYTES_LOADED_LO | low 32 bits of SD asset bytes loaded |
| `0x304c` | PLATFORM_BYTES_LOADED_HI | high 32 bits of SD asset bytes loaded |
| `0x3050` | PLATFORM_SF2_SIZE_LO | low 32 bits of SF2 byte size from the SD image header |
| `0x3054` | PLATFORM_SF2_SIZE_HI | high 32 bits of SF2 byte size from the SD image header |
| `0x3058` | PLATFORM_CURRENT_LBA | current SD LBA being loaded |
| `0x305c` | PLATFORM_DDR_STATUS | Smart Artix MIG status and temperature |
| `0x3060` | DDR_DEBUG_CONTROL | single-beat DDR debug command control |
| `0x3064` | DDR_DEBUG_STATUS | single-beat DDR debug command status |
| `0x3068` | DDR_DEBUG_ADDR | 128-bit-beat-aligned DDR byte address |
| `0x306c` | DDR_DEBUG_BYTE_ENABLE | write byte-enable bits, bit 0 controls byte 0 |
| `0x3070` | DDR_DEBUG_DATA0 | write data/readback bits 31:0 |
| `0x3074` | DDR_DEBUG_DATA1 | write data/readback bits 63:32 |
| `0x3078` | DDR_DEBUG_DATA2 | write data/readback bits 95:64 |
| `0x307c` | DDR_DEBUG_DATA3 | write data/readback bits 127:96 |

A mono configuration is valid when `length != 0`. A stereo configuration is valid
when both `length != 0` and `length_r != 0`. `length`, `length_r`, loop starts,
and loop ends are 24-bit frame counts. Looping modes additionally require each
active channel to satisfy `loop_start < loop_end` and `loop_end <= length` for
that channel. Invalid active configurations do not produce memory requests or
audio samples.
The maximum represented region length is `0x00ff_ffff` frames.

`LOOP_MODE` values are:

| Value | Name | Behavior |
| --- | --- | --- |
| `0` | no loop | play through `length`, then stop contributing |
| `1` | continuous loop | wrap from exclusive `loop_end` to `loop_start` |
| `2` | loop until release | loop while `released == 0`, then play through to `length` |

Configuration registers are `CONTROL`, `BASE_ADDR`, `BASE_ADDR_R`, `LENGTH`,
`LENGTH_R`, `LOOP_START`, `LOOP_START_R`, `LOOP_END`, `LOOP_END_R`,
`PHASE_INIT`, `PHASE_INC`, `GAIN_L`, `GAIN_R`, `LOOP_MODE`, and the filter
registers. The resource-optimized register bank does
not preserve per-voice writeback read data for these addresses; reads from
per-voice configuration and runtime data registers return zero except for
`STATUS`. To inspect per-voice state over SPI, write the target 16-bit register
address to `READBACK_ADDR`, then read `READBACK_DATA`. This readback window is a
debug and inspection path; control software should still treat the main per-voice
map as write-dominant and maintain host-side mirror state for normal operation.

Runtime registers are `ENVELOPE_LEVEL`, `PHASE_INC_RUNTIME`, `GAIN_RUNTIME`, and
`RELEASE_CONTROL`. Filter coefficient and control writes update shadow filter
state; writing `FILTER_COMMIT` with bit 0 set commits the complete shadow
filter group to runtime without a phase reload. Reads from runtime registers are
not a live-state inspection path in the resource-optimized RTL unless accessed
through `READBACK_ADDR` and `READBACK_DATA`.

`READBACK_ADDR` accepts the same 16-bit addresses used by the register map. The
sampled value is captured when `READBACK_ADDR` is written and remains stable until
the next readback-address write. For per-voice configuration and filter
registers, the sampled value is the shadow state. For `ENVELOPE_LEVEL`,
`PHASE_INC_RUNTIME`, `GAIN_RUNTIME`, and `RELEASE_CONTROL`, the sampled value is
the live runtime scalar state. `STATUS` and `VERSION` can be read either directly
or through the readback window. Unsupported readback addresses return zero.

The system debug registers are implemented by `wavetable_core_system`, so they
are visible through SPI in system-level and Smart Artix builds. In non-board
system simulations, the platform fields read zero unless the testbench drives the
platform status inputs. The debug window remains available while the playback
core/audio path is held in `core_rst`; non-debug core register accesses during
that reset return a bus error instead of stalling the SPI bridge.

All unspecified or reserved bits in the system debug registers read as zero. The
status bits below are live snapshots unless explicitly marked sticky or counted.

`SYSTEM_STATUS` (`0x3010`) is the main live activity snapshot:

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `core_busy` | `wavetable_core_memory` is currently rendering or servicing work. |
| `1` | `render_pending` | A sample tick has been accepted and the wrapper is waiting for `core_sample_valid`. |
| `2` | `core_sample_valid` | The core produced a stereo sample in the current cycle. |
| `3` | `fifo_sample_valid` | The output FIFO contains at least one sample for I2S. |
| `4` | `i2s_sample_ready` | The I2S transmitter is ready to accept the next stereo sample. |
| `5` | `ext_req_valid` | The line-memory subsystem is requesting an external memory line. |
| `6` | `ext_req_ready` | The board memory adapter can accept the line request. |
| `7` | `ext_rsp_valid` | A packed external memory-line response is valid in this cycle. |
| `31:8` | reserved | Reads zero. |

`DEBUG_EVENT_FLAGS` (`0x3014`) contains sticky event flags. Write ones to clear
selected bits. Events that occur in the same cycle as a clear remain set.

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `underrun` | I2S needed a sample when the output FIFO was empty. |
| `1` | `sample_drop` | The core produced a sample when the output FIFO could not accept it. |
| `2` | `render_deadline_miss` | A new sample tick arrived while the previous render was still pending. |
| `3` | `mem_hit` | The wave-memory subsystem served a word from its line cache. |
| `4` | `mem_miss` | The wave-memory subsystem missed its line cache and requested an external line. |
| `5` | `mem_response` | The wrapper observed an external memory-line response. |
| `31:6` | reserved | Reads zero. |

The matching counters at `0x3024` through `0x3038` increment on the same events
and saturate at `0xffff_ffff`. They are reset only by system reset and are not
cleared by writes to `DEBUG_EVENT_FLAGS`.

`AUDIO_STATUS` (`0x3018`) summarizes the output FIFO and audio sticky flags:

| Bits | Field | Meaning |
| --- | --- | --- |
| `15:0` | `output_fifo_level` | Current number of samples stored in the output FIFO. |
| `16` | `underrun` | Mirror of sticky `DEBUG_EVENT_FLAGS[0]`. |
| `17` | `sample_drop` | Mirror of sticky `DEBUG_EVENT_FLAGS[1]`. |
| `31:18` | reserved | Reads zero. |

`RENDER_STATUS` (`0x301c`) reports render scheduling state:

| Bits | Field | Meaning |
| --- | --- | --- |
| `15:0` | `render_latency_cycles` | Last completed render latency in `clk` cycles, measured from `sample_tick` until `core_sample_valid`. Saturates internally while pending at `0xffff`. |
| `16` | `render_pending` | Same live pending bit as `SYSTEM_STATUS[1]`. |
| `17` | `render_deadline_miss` | Mirror of sticky `DEBUG_EVENT_FLAGS[2]`. |
| `31:18` | reserved | Reads zero. |

`MEMORY_STATUS` (`0x3020`) reports line-memory activity:

| Bits | Field | Meaning |
| --- | --- | --- |
| `15:0` | `mem_response_latency` | Last measured latency from an external line request to its response, in `clk` cycles. |
| `16` | `ext_req_valid` | Same live request-valid bit as `SYSTEM_STATUS[5]`. |
| `17` | `ext_req_ready` | Same live request-ready bit as `SYSTEM_STATUS[6]`. |
| `18` | `ext_rsp_valid` | Same live response-valid bit as `SYSTEM_STATUS[7]`. |
| `19` | `mem_hit` | Mirror of sticky `DEBUG_EVENT_FLAGS[3]`. |
| `20` | `mem_miss` | Mirror of sticky `DEBUG_EVENT_FLAGS[4]`. |
| `21` | `mem_response` | Mirror of sticky `DEBUG_EVENT_FLAGS[5]`. |
| `31:22` | reserved | Reads zero. |

The event counters are direct 32-bit saturating reads:

| Address | Name | Event counted |
| --- | --- | --- |
| `0x3024` | `UNDERRUN_COUNT` | I2S underrun pulses. |
| `0x3028` | `SAMPLE_DROP_COUNT` | Output FIFO sample-drop pulses. |
| `0x302c` | `RENDER_DEADLINE_MISS_COUNT` | New sample ticks that arrive while a previous render is pending. |
| `0x3030` | `MEM_HIT_COUNT` | Wave-memory line-cache hit pulses. |
| `0x3034` | `MEM_MISS_COUNT` | Wave-memory line-cache miss pulses. |
| `0x3038` | `MEM_RESPONSE_COUNT` | External memory-line response pulses. |

`PLATFORM_STATUS` (`0x3040`) is the Smart Artix board-status word. In generic
system simulations without platform inputs, most bits read zero.

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `platform_debug_present` | Always `1` in `wavetable_core_system`, so software can detect this debug window. |
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

`PLATFORM_ERRORS` (`0x3044`) captures board loader error detail:

| Bits | Field | Meaning |
| --- | --- | --- |
| `7:0` | `sd_error_code` | SD command/data path error code from the board loader. Zero means no SD error. |
| `15:8` | `loader_error_code` | Raw-image header, bounds, CRC, or DDR writer-side loader error code. Zero means no loader error. |
| `19:16` | `asset_loader_state` | Same loader state code as `PLATFORM_STATUS[14:11]`. |
| `31:20` | reserved | Reads zero. |

`PLATFORM_BYTES_LOADED_LO` (`0x3048`) and `PLATFORM_BYTES_LOADED_HI` (`0x304c`)
form the 64-bit count of SF2 asset bytes written to DDR3. `PLATFORM_SF2_SIZE_LO`
(`0x3050`) and `PLATFORM_SF2_SIZE_HI` (`0x3054`) form the 64-bit SF2 byte size
read from the raw SD image header. A successful load should end with
`bytes_loaded == sf2_size_bytes` and `PLATFORM_STATUS[5] = 1`.

`PLATFORM_CURRENT_LBA` (`0x3058`) reports the current SD logical block address the
loader is reading or most recently requested. During bring-up it helps distinguish
SD initialization, sector-0 header parsing, and later SF2 data-copy progress.

`PLATFORM_DDR_STATUS` (`0x305c`) gives a DDR/MIG-focused view:

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

The DDR debug window at `0x3060` through `0x307c` is a Smart Artix bring-up path
for single 128-bit DDR beat reads and writes through the same SPI register
transport. It is not part of the generic playback memory interface. The address
is a MIG byte address and must be 16-byte aligned for the current 128-bit board
configuration. Unaligned commands report `error` and do not access DDR.

`DDR_DEBUG_CONTROL` (`0x3060`) starts and clears a command:

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `start` | Write one to start one DDR debug command when `DDR_DEBUG_STATUS.ready = 1`. |
| `1` | `write` | Command direction sampled with `start`: one writes DDR, zero reads DDR. |
| `2` | `clear` | Write one to clear latched `done` and `error` status bits. |
| `31:3` | reserved | Reads zero. |

`DDR_DEBUG_STATUS` (`0x3064`) reports command state:

| Bits | Field | Meaning |
| --- | --- | --- |
| `0` | `present` | DDR debug window is implemented. |
| `1` | `ready` | A new command can be accepted. |
| `2` | `busy` | A command is in progress. |
| `3` | `done` | Sticky completion flag; clear through `DDR_DEBUG_CONTROL.clear`. |
| `4` | `error` | Sticky command error flag; clear through `DDR_DEBUG_CONTROL.clear`. |
| `5` | `write` | Direction of the most recently accepted command. |
| `31:6` | reserved | Reads zero. |

For writes, load `DDR_DEBUG_ADDR`, `DDR_DEBUG_BYTE_ENABLE`, and the four
`DDR_DEBUG_DATA*` words, then write `DDR_DEBUG_CONTROL = 0x3`. `BYTE_ENABLE`
uses one bit per byte, where one means the byte is written; the board wrapper
converts it to the MIG active-high write-data mask. A write with no enabled bytes
reports `error` and does not access DDR. For reads, load `DDR_DEBUG_ADDR`, write
`DDR_DEBUG_CONTROL = 0x1`, poll `DDR_DEBUG_STATUS.done`, then read
`DDR_DEBUG_DATA0` through `DDR_DEBUG_DATA3`.

`RELEASE_CONTROL.released` is runtime state. Writes update the runtime released
flag without reloading phase. A commit clears the runtime released flag so a
reused voice starts in the held state. `LOOP_MODE` is a shadow configuration
field and becomes active on commit.

`ENVELOPE_LEVEL` is runtime state supplied by the MCU/control model. Writes update
the runtime value without requiring `COMMIT` and without reloading playback phase.
A commit preserves the current runtime envelope value while it loads the rest of
the voice configuration. This lets MCU firmware or a testbench model advance
attack, decay, sustain, and release curves while the FPGA pipeline keeps rendering
the same note.

`GAIN_L` and `GAIN_R` are shadow configuration fields copied into runtime gain by
`COMMIT`. `GAIN_RUNTIME` updates both runtime channel gains in one bus write
without copying shadow registers and without reloading playback phase. Use this
path for MIDI volume, expression, pan, or similar low-rate controller changes
where a two-write left/right gain update could otherwise be visible over SPI.

`PHASE_INC_RUNTIME` writes update the runtime phase increment without copying
shadow registers and without reloading runtime phase. Use this path for
pitch bend or low-rate vibrato control.

The filter registers configure a per-voice biquad IIR filter placed after
interpolation and before channel gain. `FILTER_CONTROL[0]` and `FILTER_B0` through
`FILTER_A2` form one shadow filter group. A voice `COMMIT` copies that group into
runtime filter state for a new note. During active playback, write the desired
shadow filter group first, then write `FILTER_COMMIT` with bit 0 set; that copies
the shadow enable plus all five coefficients to runtime together without
reloading phase. Filter history is per voice and per
channel and is cleared on voice `COMMIT`. `FILTER_CONTROL.enable = 0` bypasses the
filter. The denominator convention is `1 + a1*z^-1 + a2*z^-2`; the RTL computes
`b0*x + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]` using a transposed form.

The RTL does not implement SF2 preset selection, velocity mapping, modulators, or
coefficient calculation; software writes already-quantized filter coefficients.
A value of `0x7fff` is treated as full envelope level and bypasses the extra
envelope multiply so existing full-scale voice gains are not attenuated by one
least-significant bit.

## Minimal Control Sequences

The FPGA does not allocate voices or parse MIDI. Software chooses a free slot,
loads sample metadata into that slot, and drives runtime controls over time. The
smallest useful actions are below.

### Note On

For a new note, write the runtime envelope first, then write the shadow
configuration, then commit. `COMMIT` updates the active renderer configuration,
stages `PHASE_INC` and `GAIN_L/R` into runtime pitch/gain, clears the staged
`RELEASE_CONTROL.released`, and requests phase reload from `PHASE_INIT` plus
filter-history clear at the next accepted output-frame boundary. Software should
not depend on a committed voice being rendered before that boundary pulse has
been accepted.

Minimal mono no-loop Note On for `slot`:

| Write order | Address | Data |
| ---: | --- | --- |
| 1 | `voice_base(slot) + 0x2c` `ENVELOPE_LEVEL` | initial Q1.15 level, commonly `0x0000_7fff` |
| 2 | `voice_base(slot) + 0x00` `CONTROL` | bit 0 `enable = 1`, bit 1 `stereo = 0` |
| 3 | `voice_base(slot) + 0x04` `BASE_ADDR` | first left/mono wave-memory word |
| 4 | `voice_base(slot) + 0x58` `BASE_ADDR_R` | ignored for mono; commonly mirror `BASE_ADDR` |
| 5 | `voice_base(slot) + 0x08` `LENGTH` | sample-frame count |
| 6 | `voice_base(slot) + 0x60` `LENGTH_R` | ignored for mono; commonly mirror `LENGTH` |
| 7 | `voice_base(slot) + 0x0c` `LOOP_START` | `0` for no-loop voices |
| 8 | `voice_base(slot) + 0x64` `LOOP_START_R` | ignored for mono; commonly mirror `LOOP_START` |
| 9 | `voice_base(slot) + 0x10` `LOOP_END` | `0` for no-loop voices |
| 10 | `voice_base(slot) + 0x68` `LOOP_END_R` | ignored for mono; commonly mirror `LOOP_END` |
| 11 | `voice_base(slot) + 0x14` `PHASE_INIT` | usually `0x0000_0000` |
| 12 | `voice_base(slot) + 0x18` `PHASE_INC` | Q24.8 playback increment |
| 13 | `voice_base(slot) + 0x1c` `GAIN_L` | signed Q1.15 initial left gain |
| 14 | `voice_base(slot) + 0x20` `GAIN_R` | signed Q1.15 initial right gain |
| 15 | `voice_base(slot) + 0x34` `LOOP_MODE` | `0` no loop |
| 16 | `voice_base(slot) + 0x38` `FILTER_CONTROL` | `0` to bypass filter |
| 17 | `voice_base(slot) + 0x3c` `FILTER_B0` | `0x1000_0000` unity, harmless when bypassed |
| 18 | `voice_base(slot) + 0x40` `FILTER_B1` | `0` |
| 19 | `voice_base(slot) + 0x44` `FILTER_B2` | `0` |
| 20 | `voice_base(slot) + 0x48` `FILTER_A1` | `0` |
| 21 | `voice_base(slot) + 0x4c` `FILTER_A2` | `0` |
| 22 | `voice_base(slot) + 0x24` `COMMIT` | `1` |

For stereo playback, write `CONTROL.stereo = 1`; `BASE_ADDR` names the first left
sample word and `BASE_ADDR_R` names the first right sample word. Write the right
channel window through `LENGTH_R`, `LOOP_START_R`, and `LOOP_END_R`. Phase and
phase increment are still measured in sample frames. For continuous loop or
loop-until-release, write valid per-channel loop starts, exclusive loop ends, and
`LOOP_MODE = 1` or `2` before `COMMIT`.

### Envelope Update

To update amplitude during attack, decay, sustain, or release, write only:

```text
voice_base(slot) + 0x2c ENVELOPE_LEVEL = current Q1.15 envelope level
```

This does not require `COMMIT` and does not reload phase. The renderer samples
the live runtime value when it accepts each voice for rendering.

### Note Off

There are two common Note Off policies.

For `LOOP_MODE = 2` loop-until-release samples:

| Write order | Address | Data |
| ---: | --- | --- |
| 1 | `voice_base(slot) + 0x54` `RELEASE_CONTROL` | `1` |
| 2..N | `voice_base(slot) + 0x2c` `ENVELOPE_LEVEL` | decreasing release levels |

When the release envelope reaches zero, free the slot:

| Write order | Address | Data |
| ---: | --- | --- |
| 1 | `voice_base(slot) + 0x00` `CONTROL` | bit 0 `enable = 0`, keep bit 1 stereo as desired |
| 2 | `voice_base(slot) + 0x24` `COMMIT` | `1` |

For one-shot no-loop voices, software may either let playback naturally stop at
`LENGTH` or immediately start reducing `ENVELOPE_LEVEL` and then disable/commit
the slot when silent.

### Runtime Pitch And Gain

Pitch bend or low-rate vibrato writes:

```text
voice_base(slot) + 0x30 PHASE_INC_RUNTIME = new Q24.8 phase increment
```

Runtime gain, volume, expression, or pan writes both channels atomically:

```text
voice_base(slot) + 0x50 GAIN_RUNTIME = {right_gain[15:0], left_gain[15:0]}
```

Neither write reloads phase or changes shadow configuration. A later `COMMIT`
will overwrite runtime pitch and gain with the shadow `PHASE_INC` and `GAIN_L/R`
values staged for the next note setup.

### Reusing A Slot

Before reusing a slot, software should explicitly write the new note's
`ENVELOPE_LEVEL`, gains, pitch, loop mode, filter settings, and `CONTROL.enable`,
then `COMMIT`. Do not rely on runtime state left by the previous note except for
the documented commit behavior: commit clears `RELEASE_CONTROL.released` and
reloads phase/filter history at the next accepted output-frame boundary, but
preserves the live runtime envelope level.
