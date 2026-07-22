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
the request and response payloads. `wave_word_req_t` carries `valid`, `voice`,
and `addr`; `voice` lets cache adapters preserve per-voice locality while the
word address remains the memory lookup key. The initial simulation model accepts
every request and returns its signed 16-bit value one cycle later.

This single-word core-side contract is intentional. The renderer must not require
a line, burst, pair-endpoint, or cache-line extraction interface because future
board targets may use DDR, SDRAM, parallel NOR, SPI/QSPI NOR, SRAM, or another
adapter with different natural access granularity. Wider reads, line fills,
paired interpolation endpoints, and speculative prefetch are allowed inside an
optional memory adapter such as `voice_line_cache` or `wave_memory_subsystem`,
but they must remain implementation details behind the same one-word
request/response interface unless a later project milestone explicitly changes
this external contract.

## Voice Line Cache

`rtl/memory/voice_line_cache.sv` is the current cached render path used by
`wavetable_cached_render_core`. It adapts ordered one-word requests to an
external aligned line-read interface while keeping two cached lines per voice.
The default line size is `LINE_WORDS = 32`.

- Core side: `req` carries `valid/voice/addr`, `req_ready` accepts one request,
  and `rsp` returns `valid/data` in accepted-request order.
- External side: `ext_req_valid`, `ext_req_ready`, and `ext_req_addr` request an
  aligned line. `ext_rsp_valid` returns `LINE_WORDS` packed signed 16-bit words
  on `ext_rsp_data`, with word 0 in bits `[15:0]`.
- A demand hit returns the requested word from the selected voice's cached lines.
  A miss backpressures the core-side request port, issues one external aligned
  line request, fills one way for that voice, and returns the requested word.
- The cache includes a conservative stride prefetch path. When a demand hit
  reads the second half of a line, the adapter may queue a request for the next
  aligned line for the same voice. It does not predict loop wrap or sample-region
  boundaries. Demand requests take priority over queued prefetches, and prefetch
  requests issue only while the external line interface is otherwise idle.
  External traffic remains one outstanding line request at a time.
- Cache observability is exposed as hit, miss, line fill, same-line endpoint hit,
  replacement, prefetch issued, prefetch filled, prefetch used, prefetch dropped,
  and prefetch late pulses. `prefetch_used` fires once when a later demand lookup
  hits a line filled by prefetch before any ordinary demand hit consumes that
  line. `prefetch_late` means a demand miss needed a queued or in-flight
  prefetch line before it became a normal hit. `response_trace_pulse` and
  `response_trace_latency` still report one pulse per returned word.

## Minimal Line Memory Subsystem

`rtl/memory/wave_memory_subsystem.sv` adapts the core's one-word read interface
to a wider external line-read interface suitable for an SDRAM/DDR controller
wrapper or a burst-capable memory model. It contains one cached line and supports
one outstanding core request. It remains as a small baseline adapter and is still
used by some common/board wrapper paths:

- Core side: `core_req` carries `valid/voice/addr`; this baseline adapter ignores
  `voice` and caches by address only. `core_req_ready` and `core_rsp` complete
  the ordered one-word handshake.
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

The current regression path exercises both the baseline `wave_memory_subsystem`
and the per-voice `voice_line_cache`:

- `tb_wave_memory_subsystem` checks one line miss, one same-line hit, and one
  second-line miss with `LINE_WORDS = 32` and `line_memory_model LATENCY = 4`.
- `tb_voice_line_cache` checks same-line hits, cross-line misses, per-voice
  cache isolation, two-way replacement, reset invalidation, and miss
  backpressure.
- `tb_wavetable_render_core` routes the full multi-voice self-checking datapath
  through `wavetable_render_core -> voice_line_cache -> line_memory_model`.
- `tb_wavetable_render_core_asset` uses the same per-voice cache path for
  SF2-derived render runs.

Observed focused-test behavior:

- Read `addr = 3`: first access to line `[0,31]`, cache miss, one external line
  request.
- Read `addr = 6`: same line `[0,31]`, cache hit, no additional external request.
- Read `addr = 36`: first access to line `[32,63]`, cache miss, second external
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
PCM output: a same-line cached access must not issue another external demand line
request, second-half hits issue next-line prefetch when the external interface is
idle, prefetched lines can satisfy later demand hits, demand misses outrank
queued prefetches, and reset clears prefetch pending state. The C++ MIDI render
path records aggregate counters for real render traffic in
`build/render_memory/memory_stats.json`, including external line requests,
sequential line requests, response count, average response latency, and maximum
response latency. The same JSON now includes demand hit, demand miss, line fill,
same-line endpoint hit, replacement, prefetch, render-cycle, deadline-miss, and
over-budget counts from the RTL cache/render top.

## External Memory Profiles

The simulation models only read behavior for board-memory candidates. These
profiles are not full DDR, SDRAM, NOR, or MIG controller models; they approximate
line-read latency, faster sequential line access, and request backpressure while
preserving the same RTL memory-subsystem interface.

The `ddr` profile should be treated as an optimistic DDR-like line-memory timing
profile, not as board-proven DDR3 behavior. It is useful for comparing cache
policies, line sizes, hit/miss counts, external request counts, and first-order
miss latency effects. It does not model refresh, bank or row conflicts, command
scheduling, read-data bus turnaround, calibration, CDC, MIG `app_rdy`/
`app_wdf_rdy` behavior, finite controller FIFOs, or the throughput benefit of
multiple outstanding reads. Real 256-voice acceptance still requires a board DDR
line-reader model or hardware measurements.

`make render-memory` accepts `MEMORY_PROFILE` for the external line-memory timing
model:

```bash
make render-memory SECONDS=1 MEMORY_PROFILE=ddr
make render-memory SECONDS=1 MEMORY_PROFILE=sdram
make render-memory SECONDS=1 MEMORY_PROFILE=parallel-nor
make render-memory MIDI=song.mid START_SECONDS=144 SECONDS=30 MEMORY_PROFILE=ddr
```

`START_SECONDS` is a render-window convenience for MIDI-driven harnesses. Events
inside `[START_SECONDS, START_SECONDS + SECONDS)` are shifted to start at zero;
non-note MIDI events before `START_SECONDS` are replayed at output time zero so
controller, pitch-bend, pressure, and similar channel state can affect the
window. Notes that began before `START_SECONDS` are not recreated, so this mode
is not a fully faithful preroll snapshot for sustained voices.

Current C++ render profiles:

| Profile | Random line latency | Sequential line latency | Ready gap |
| --- | ---: | ---: | ---: |
| `ddr` | 10 cycles | 4 cycles | 0 cycles |
| `sdram` | 16 cycles | 8 cycles | 1 cycle |
| `parallel-nor` | 28 cycles | 14 cycles | 3 cycles |

Using the built-in two-second MIDI smoke render against
`assets/soundfonts/MT6276.sf2` with the current `LINE_WORDS = 32` per-voice cache,
`MEMORY_PROFILE=ddr` produced the exact reference PCM result with 1,539 external
line requests, 623 sequential line requests, 265,440 word responses, 263,901
demand hits, 1,539 demand misses/fills, 171,119 same-line endpoint hits, and
1,535 replacements. The observed response-latency counters were 0.055 average
cycles and 12 maximum cycles. These numbers are workload and profile dependent;
use them as a regression reference, not as a DDR bandwidth proof.

The SystemVerilog `line_memory_model` exposes matching parameters for focused
tests: `RANDOM_LATENCY`, `SEQUENTIAL_LATENCY`, and `READY_GAP`. Its legacy
`LATENCY` parameter remains as the default for all three values when a test does
not need a specific memory profile.

The pure C++ `render-reference` target and the direct `render-rtl-core`
comparison target do not use these profiles. The reference synthesizer reads from
an in-memory word vector, and `render-rtl-core` serves the RTL memory port with an
ideal one-cycle word responder only to keep the core interface active.

## Future Wavetable-Optimized Memory Subsystem

The current subsystem is intentionally small and generic. It is not optimized for
the access pattern of a polyphonic wavetable synthesizer, where each active voice
walks through one sample region with a predictable Q24.8 phase stride while the
renderer interleaves requests from many voices.

A later memory subsystem should evaluate these improvements in order:

1. Add the next layer of counters that separates voice-scheduler cost from
   memory-service cost: cross-line endpoint pairs, endpoint queue depth,
   fetch-slot pressure, DSP context queue occupancy, memory-stall cycles, and
   DSP-ready/no-context cycles. The current top-level render/deadline counters
   and cache demand/prefetch counters are already present.
2. Carry explicit channel/stream locality into the endpoint/cache path. The
   current cache keys by `voice_id` and line tag only; linked-stereo regions need
   independent left/right stream tags because left and right samples usually live
   in separate memory regions but share one voice id.
3. Move stride prediction closer to `voice_endpoint_fetch`, or add enough request
   metadata for `voice_line_cache` to know the current channel, endpoint kind,
   `phase_inc`, next phase, loop range, release state, and sample length. This is
   the information needed to predict the actual next endpoint line instead of
   blindly fetching `aligned_addr + LINE_WORDS`.
4. Replace the current second-half next-line prefetch with phase-aware prefetch:
   prefetch the next output frame's L0/L1 and, for stereo, R0/R1 endpoint lines;
   suppress same-line duplicates; handle loop-wrap targets; and stop prefetching
   no-loop or released voices near the end of the region. Demand reads must
   continue to outrank speculative prefetches.
5. Re-run the fixed stress windows and compare `cache_demand_misses`,
   `prefetch_used / prefetch_issued`, `avg_render_cycles`, `max_render_cycles`,
   `deadline_misses`, and `over_budget_frames`. Keep PCM exact-match as the
   gating correctness check.
6. Evaluate larger burst lines only after phase-aware prefetch counters exist.
   Larger lines can amortize DDR command overhead, but the current stress result
   shows enough dropped or unused speculative reads that line-size changes should
   be justified by render-cycle counters, not hit-rate alone.
7. Add multi-request tracking so cache fills and prefetches can overlap with
   sequential voice rendering when the single-fill path is measured as the
   remaining limiter.
8. Add tagged or reordered endpoint assembly only if in-order responses still
   block useful DDR/cache overlap.

Current measurement caveat: in the 144-second Hedwig/SGM DDR stress window, the
simple next-line prefetch reached only about `11.1%` useful prefetches
(`887,025 / 7,965,833`) before the run was interrupted near completion. It still
completed the measured frames without deadline misses, but the low useful ratio
means the next optimization should improve prefetch targeting before adding more
speculation.

The generic core-side memory port should still remain a one-word in-order read
interface for the first optimized pass where practical. Throughput work in the
renderer should first use a word-request FIFO, in-order endpoint assembly queue,
and voice-aware cache/prefetch policy so voice scanning, register snapshots, and
memory response waits can overlap without assuming line-oriented storage at the
outer contract. If an adapter can internally return both interpolation endpoints
from one line fill, it may do so while still presenting ordered 16-bit word
responses to the core.

The likely interface change is to carry `voice_id` with each core memory request,
or to move the optimized cache into/near `multi_voice_pipeline` where the current
voice index, phase, loop range, and stereo mode are already visible. Any such
change must update the RTL interface documentation and add focused tests for hit,
miss, same-line endpoint extraction, cross-line endpoints, prefetch, loop
boundary, mono/stereo, per-voice eviction isolation, and backpressure behavior.

Use `render-memory` counters as the comparison baseline: external line requests,
sequential line requests, average and maximum response latency, full render
latency, deadline misses, and output underruns. A representative stress case is a
layered stereo piano MIDI render, which stresses cache locality with many
interleaved region streams.
