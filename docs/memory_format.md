# Wave Memory And DDR Refill Contract

Addresses identify signed 16-bit words. In SF2-backed flows, word address zero
is the first 16-bit word of the complete SF2 file image; sample bases therefore
include the `smpl` payload offset.

A mono region has a 32-bit word `base_addr` and 24-bit `length`, `loop_start`,
and exclusive `loop_end` values in sample frames.

## Mono Storage

Frame `n` is stored at:

```text
base_addr + n
```

The renderer fetches one stream and duplicates the interpolated sample before
independent signed Q1.15 left/right gain.

## SF2 Stereo Expansion

The RTL has no stereo voice descriptor. The C++ SF2 loader represents linked
left/right samples as two mono `Region` values and starts two voice IDs:

```text
left voice(n)  = left_base  + wrapped_or_clamped(n)
right voice(n) = right_base + wrapped_or_clamped(n)
```

Each region retains its own address, length, loop, attenuation, pan-derived
channel gains, envelope, filter, runtime state, and sample window. Pitch metadata
follows the SF2 linked-sample rule while both voices start for the same note.

Adjacent compatible hard-panned zones with missing or stale links may also stay
as two mono regions. They are never collapsed into one dual-stream RTL voice.
`linkedSample` type 8 remains unsupported.

## Phase Addressing

Phase is unsigned Q24.8. `VOICE_START_MONO` clears it to zero. For each output
frame:

```text
frame_0 = phase[31:8]
frame_1 = frame_0 + 1, adjusted at sample/loop boundary
addr_0  = base_addr + frame_0
addr_1  = base_addr + frame_1
```

`phase_inc` is added after the current endpoints are selected. LOOP_MODE 1 and
2 wrap at exclusive `loop_end`; mode 2 stops wrapping after RELEASE. Valid loops
satisfy `loop_start < loop_end <= length`.

## Per-Voice Sample Window

`rtl/memory/voice_sample_window.sv` is the production memory adapter. Every voice
owns a persistent 32-word mono window. The renderer issues ordered word requests
for interpolation endpoints. Hits return locally; a miss starts aligned 8-word
refills until the required window contents are available.

Per-voice window-valid and window-base metadata share one synchronous block RAM.
After reset the cache holds request ready low while it clears one metadata entry
per cycle; this logically invalidates all voices without a 512-bit resettable
valid register and its dynamic selection logic. Request acceptance then starts
the metadata read, and the existing lookup state consumes its registered result
on the following cycle. Window sample contents use a separate synchronous block
RAM indexed by voice and line offset.

The window contract is:

- one accepted endpoint request returns exactly one ordered response;
- external refill requests and responses use ready/valid;
- external responses return in request order;
- refill addresses are aligned to eight 16-bit words;
- a refill contains eight words, packed word 0 in bits `[15:0]`;
- reset invalidates tags and contents logically without clearing sample RAM;
- windows persist across render blocks;
- an endpoint outside the resident window can use the documented ordered
  fallback read while preserving response order.

The 8-word object is a DDR transaction width. It is not the removed one-line or
two-line cache architecture. `LINE_WORDS=8` at the external boundary and the
32-word window capacity are separate concepts.

## Smart Artix DDR3 Path

The synthesizable board path is:

```text
voice_sample_window ordered refill
  -> voice_major_system external line port
  -> smart_artix_ddr3_line_reader
  -> smart_artix_ddr3_rw_arbiter
  -> smart_artix_ddr3_subsystem
  -> MIG app interface
```

The existing arbiter also serves SD asset-loader writes and the DDR register
inspection master. The line reader converts each aligned eight-word request to
one 128-bit MIG application read and returns the response on the common ordered
line handshake. No simulation bridge appears in synthesis filelists.

DDR byte address conversion is:

```text
byte_addr = word_addr << 1
```

The complete SF2 image is loaded at DDR byte address zero, so C++/host region
word addresses match board addresses directly.

## Behavioral DDR3 Simulation

The Verilator path is:

```text
voice_sample_window
  -> ordered_line_ddr3_bridge_model
  -> ddr3_timing_model
  -> ddr3_bin_store DPI backing image
```

These files live under `sim/` and are never synthesis sources. The model covers
accepted/returned accounting, row hits and misses, activate/precharge timing,
refresh blocking, and configurable queue/backpressure behavior. It does not
model MIG calibration, board pins, electrical timing, or CDC.

`render-rtl-ddr3` loads the selected SF2 file as the DDR image, drives the same
compact command words as hardware, writes `out.wav`, and emits
`rtl_ddr3_render_config.json` through the shared main-branch report/session code.

## Verification

Focused tests are:

| Test/target | Coverage |
| --- | --- |
| `tb_voice_sample_window` | same-window hits, refill order, voice isolation, boundary fallback, and backpressure |
| `tb_ddr3_timing_model` | row/refresh timing and exact request/response counts |
| `tb_voice_major_throughput` | active-lane traversal and block deadline |
| `measure-voice-major-throughput-ddr3` | renderer plus timed DDR model |
| `measure-voice-major-throughput-512` | full 10-bit voice IDs and capacity timing |
| `render-rtl-ddr3` | real SF2/MIDI control, DDR image, PCM output, and JSON diagnostics |
| `tb_smart_artix_ddr3_line_reader` | ordered line to MIG read conversion |
| `tb_smart_artix_ddr3_rw_arbiter` | loader/read/register ownership and response routing |

Every accepted refill must have exactly one returned response. Deadline checks
must use measured block cycles, not inferred memory bandwidth alone.

## Capacity Notes

At the 512-voice project default, 32 words per voice require 16,384 signed-16
sample words, equivalent to eight RAMB36 blocks before tag/control overhead.
Synthesis must confirm actual BRAM inference and timing; simulation capacity
alone is not an implementation result.

Larger windows reduce fallback/refill pressure but scale linearly with voice
count. Change the window size only from measured refill and post-route data.
