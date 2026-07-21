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
separate sample headers linked by `sampleLink`. The C++ SF2 loader also accepts
a common non-spec SoundFont practice where one instrument contains adjacent
hard-panned matching zones, normally pan `-500` and `+500`, for left and right
sample headers whose `sampleLink` fields are missing or stale. Those zones are
collapsed into one stereo region when their key/velocity ranges, sample pitch
metadata, and sample windows are usable. Their sample names, sample type flags,
sample lengths, and loop windows may differ; lengths and loops are preserved as
independent left and right playback controls. Interpolation operates
independently on each channel, while both channels use the same phase increment
so the pair is triggered and pitched as one stereo voice. Because a stereo
region already routes the left sample to the left channel and the right sample
to the right channel, the loader neutralizes each region's per-zone SF2 pan
generator for both linked-stereo and unlinked hard-panned pairs: the per-zone
pan (commonly `-500` and `+500`) is centered so it does not additionally
attenuate either channel to silence. Following the SF2 rule that the remaining
non-pitch generators still apply as normal, each channel's base gain is taken
from its own side's `initialAttenuation`: the left zone drives the left base
gain and the right zone drives the right, so an asymmetric stereo pair keeps
independent left/right attenuation rather than collapsing to a single gain.

## SF2 Stereo Conformance And Trade-offs

This section records the deliberate design choices for stereo playback relative
to the SoundFont 2.01 specification (`docs/sfspec24.pdf`, section 7.10 SHDR,
`sfSampleType`/`wSampleLink`). Keep it in sync when stereo behavior changes.

Normative spec model: a left/right pair references each other through
`wSampleLink`. Both samples "should be played entirely synchronously, with their
pitch controlled by the right sample's generators. All non-pitch generators
should apply as normal; in particular the panning of the individual samples to
left and right should be accomplished via the pan generator." In other words the
reference model is two independent voices, each panned by its own pan generator
(conventionally `-500` for the left sample and `+500` for the right).

Implementation model: this core plays a linked pair as a single stereo voice
that hard-routes the left sample to the left channel and the right sample to the
right channel, with one shared phase increment. This is a deliberate departure
from the two-voice reference model chosen to spend one voice instead of two per
stereo note, which conserves polyphony in the fixed voice array.

Conformed spec points:

- Pitch and pitch-routing generators come from the right sample's zone. The
  shared Q24.8 phase increment is derived only from the right sample's
  `sampleRate`, `originalPitch`, and `pitchCorrection` plus the right zone's
  tuning generators (`keynum`, `overridingRootKey`, `scaleTuning`, `fineTune`,
  `coarseTune`).
- Left/right pairs are resolved only within the same instrument, and only when
  the link is reciprocal.
- Per-channel sample windows, lengths, and loop points come from each side's own
  zone, so the "non-pitch generators apply as normal" rule holds for addressing.
- Per-channel base gain comes from each side's own `initialAttenuation`, so an
  asymmetric stereo pair keeps independent left/right attenuation.

Deliberate deviations and known limitations:

- The single phase increment derived from the right sample is applied to the
  left channel as well. The left sample's own `sampleRate`, `originalPitch`, and
  `pitchCorrection` are ignored, so a pair whose two headers disagree on pitch
  metadata would mistune the left channel. This is harmless in practice because
  the two channels of a stereo recording share identical pitch metadata, and it
  is what keeps the pair sample-synchronous.
- Panning is realized by the fixed left-to-left / right-to-right routing, not by
  applying the pan generator as a gain crossfade. The per-zone pan is therefore
  centered. Only the hard-pan convention (`-500` / `+500`) is reproduced
  exactly; a stereo pair authored with non-hard or asymmetric pan (for example
  `-300` / `+300`) cannot be represented and is played as full separation.
- If a linked pair carries no pan generators (both centered), a strict two-voice
  renderer would sum both samples into both channels (a near-mono image). This
  core instead always gives full left/right separation for a stereo region.
- The single stereo voice has one volume envelope, one filter, and one set of
  non-pitch LFOs; these are taken from the left zone only. If the right zone
  specifies a different envelope, filter cutoff, or non-pitch modulation, that
  difference is dropped. Real SoundFonts almost always keep these symmetric
  between the two sides except for pan.
- Beyond the spec, the loader also pairs adjacent hard-panned mono zones whose
  `sampleLink` is missing or stale into one stereo region (`stereo_source` =
  `hard_pan_unlinked`). This is a pragmatic accommodation for real-world
  SoundFonts and is not part of the standard.
- The `linkedSample` type (8), which the spec leaves as a not-yet-defined
  circularly linked list, is not supported and is rejected at load time.

## Abstract Memory Handshake

The core issues one 32-bit word-address request at a time. A request transfers
when the request struct's `valid` field is high and the separate ready signal is
high. A response transfers when the response struct's `valid` field is high;
responses must arrive in request order. In RTL, generic core-internal module
boundaries use `synth_pkg::wave_word_req_t` and `synth_pkg::wave_word_rsp_t` for
the request and response payloads. The initial simulation model accepts every
request and returns its signed 16-bit value one cycle later.

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
  wavetable read contract at legacy wrapper boundaries. Inside generic RTL
  module connections, the same contract is carried as `core_req` with
  `valid/addr`, `core_req_ready`, and `core_rsp` with `valid/data`.
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
