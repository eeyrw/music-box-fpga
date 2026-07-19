# Wave Memory Format

Addresses identify 16-bit words in the external wave-memory image. For SF2-backed
flows, word address zero is the first 16-bit word of the complete SF2 file image;
sample addresses therefore include the `smpl` chunk payload offset. A voice
configuration gives 32-bit `base_addr` and `base_addr_r` in words and gives
24-bit per-channel `length`, `loop_start`, and `loop_end` values in sample
frames.
A single mono 16-bit sample region can therefore span up to `0x00ff_ffff`
frames, or just under 32 MiB of PCM data. Linked-stereo regions have that limit
per channel because the left and right channels use independent base addresses.

## Mono

When `stereo` is clear, frame `n` is stored at:

```text
base_addr + n
```

The fetched sample is used for both channels before channel gain is applied.
`base_addr_r` is ignored for mono playback.

## Stereo

When `stereo` is set, left and right channels use independent absolute base
addresses and independent sample windows:

```text
left(n)  = base_addr + n_l, where n_l is wrapped or clamped by LENGTH/LOOP_*
right(n) = base_addr_r + n_r, where n_r is wrapped or clamped by LENGTH_R/LOOP_*_R
```

This matches normal SF2 linked-stereo storage, where left and right samples are
separate sample headers linked by `sampleLink`. Interpolation operates
independently on each channel, while both channels use the same phase increment
so the pair is triggered and pitched as one stereo voice.

## Abstract Memory Handshake

The core issues one 32-bit word-address request at a time. A request transfers
when `mem_req_valid && mem_req_ready`. A response transfers when
`mem_rsp_valid`; responses must arrive in request order. The initial simulation
model accepts every request and returns its signed 16-bit value one cycle later.

This single-word core-side contract is intentional. The renderer must not require
a line, burst, pair-endpoint, or cache-line extraction interface because future
board targets may use DDR, SDRAM, parallel NOR, SPI/QSPI NOR, SRAM, or another
adapter with different natural access granularity. Wider reads, line fills,
paired interpolation endpoints, and speculative prefetch are allowed inside an
optional memory adapter such as `wave_memory_subsystem`, but they must remain
implementation details behind the same one-word request/response interface unless
a later project milestone explicitly changes this external contract.

## Minimal Line Memory Subsystem

`rtl/memory/wave_memory_subsystem.sv` adapts the core's one-word read interface
to a wider external line-read interface suitable for an SDRAM/DDR controller
wrapper or a burst-capable memory model. It contains one cached line and supports
one outstanding core request:

- Core side: `core_req_valid`, `core_req_ready`, `core_req_addr`,
  `core_rsp_valid`, and `core_rsp_data` match the existing 16-bit word-addressed
  wavetable read contract.
- External side: `ext_req_valid`, `ext_req_ready`, and `ext_req_addr` request an
  aligned line. `ext_rsp_valid` returns `LINE_WORDS` packed signed 16-bit words
  on `ext_rsp_data`, with word 0 in bits `[15:0]`.
- A same-line hit returns from the cached line without another external request.
  A miss backpressures the core request port until the external line response is
  received and the requested word is returned.

This block does not implement DDR/SDRAM electrical timing, refresh, arbitration,
or clock-domain crossing. Those belong in a board memory controller connected to
the external line-read side.

## Memory Subsystem Test Baseline

The current regression path exercises `wave_memory_subsystem` in both a focused
unit test and the normal synthesis render path:

- `tb_wave_memory_subsystem` checks one line miss, one same-line hit, and one
  second-line miss with `LINE_WORDS = 8` and `line_memory_model LATENCY = 4`.
- `tb_wavetable_render_core` routes the full multi-voice self-checking datapath through
  `wavetable_render_core -> wave_memory_subsystem -> line_memory_model`.
- `tb_wavetable_render_core_asset` uses the same memory path for SF2-derived render
  runs.

Observed focused-test behavior:

- Read `addr = 3`: first access to line `[0,7]`, cache miss, one external line
  request.
- Read `addr = 6`: same line `[0,7]`, cache hit, no additional external request.
- Read `addr = 12`: first access to line `[8,15]`, cache miss, second external
  line request.

With the current model parameters, a cache hit returns with much lower latency
than a miss because no external line request is issued. During a miss, the
core-side request port is backpressured because the minimal subsystem supports
only one outstanding core request. The exact response-latency counter is exposed
through `response_trace_pulse` and `response_trace_latency` so simulation harnesses
can record the observed latency for each request.

The real-SF2 smoke run `make render-instrument SECONDS=1 KEY=60` used
`assets/soundfonts/MT6276.sf2`, selected the `Vibes` instrument sample
`vibes52`, rendered 48,000 stereo samples, and passed with this memory path.

The focused tests assert cache behavior through external request counts and exact
PCM output: a same-line cached access must not issue another external line
request. The C++ MIDI render path records aggregate counters for real render
traffic in `build/render_memory/memory_stats.json`, including external line
requests, sequential line requests, response count, average response latency, and
maximum response latency.

## External Memory Profiles

The simulation models only read behavior for board-memory candidates. These
profiles are not full DDR, SDRAM, or NOR controllers; they approximate line-read
latency, faster sequential line access, and request backpressure while preserving
the same RTL memory-subsystem interface.

`make render-memory` accepts `MEMORY_PROFILE`:

```bash
make render-memory SECONDS=1 MEMORY_PROFILE=ddr
make render-memory SECONDS=1 MEMORY_PROFILE=sdram
make render-memory SECONDS=1 MEMORY_PROFILE=parallel-nor
```

Current C++ render profiles:

| Profile | Random line latency | Sequential line latency | Ready gap |
| --- | ---: | ---: | ---: |
| `ddr` | 10 cycles | 4 cycles | 0 cycles |
| `sdram` | 16 cycles | 8 cycles | 1 cycle |
| `parallel-nor` | 28 cycles | 14 cycles | 3 cycles |

Using the built-in one-second MIDI smoke render against
`assets/soundfonts/MT6276.sf2`, all three profiles produced the same audible
render result and the same external request mix: 50,562 external line requests,
8,490 sequential line requests, and 135,840 responses. The latency counters
changed by profile:

| Profile | Avg response latency | Max response latency |
| --- | ---: | ---: |
| `ddr` | 4.09 cycles | 12 cycles |
| `sdram` | 6.20 cycles | 18 cycles |
| `parallel-nor` | 10.29 cycles | 30 cycles |

The SystemVerilog `line_memory_model` exposes matching parameters for focused
tests: `RANDOM_LATENCY`, `SEQUENTIAL_LATENCY`, and `READY_GAP`. Its legacy
`LATENCY` parameter remains as the default for all three values when a test does
not need a specific memory profile.

## Future Wavetable-Optimized Memory Subsystem

The current subsystem is intentionally small and generic. It is not optimized for
the access pattern of a polyphonic wavetable synthesizer, where each active voice
walks through one sample region with a predictable Q24.8 phase stride while the
renderer interleaves requests from many voices.

A later memory subsystem should evaluate these improvements:

- Per-voice two-line or small set-associative caches so one voice's locality is
  not immediately evicted by another voice's region.
- Stride-aware prefetch using `phase_inc` to fetch the line containing the next
  interpolated frame, including loop-wrap cases.
- Demand-priority scheduling so real sample reads always outrank speculative
  prefetches.
- Larger burst lines, such as 16 or 32 words, when the selected board memory
  controller benefits from longer aligned reads.
- Optional multi-request tracking so cache fills and prefetches can overlap with
  sequential voice rendering.

The generic core-side memory port should still remain a one-word in-order read
interface. Throughput work in the renderer should first use a word-request FIFO
and in-order endpoint assembly queue so voice scanning, register snapshots, and
memory response waits can overlap without assuming line-oriented storage. If an
adapter can internally return both interpolation endpoints from one line fill, it
may do so while still presenting ordered 16-bit word responses to the core.

The likely interface change is to carry `voice_id` with each core memory request,
or to move the optimized cache into/near `multi_voice_pipeline` where the current
voice index, phase, loop range, and stereo mode are already visible. Any such
change must update the RTL interface documentation and add focused tests for hit,
miss, prefetch, loop-boundary, mono/stereo, and backpressure behavior.

Use `render-memory` counters as the comparison baseline: external line requests,
sequential line requests, average and maximum response latency, full render
latency, deadline misses, and output underruns. A representative stress case is a
layered stereo piano MIDI render, which currently stresses the one-line cache
with many interleaved region streams.
