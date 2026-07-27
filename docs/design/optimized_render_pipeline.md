# Optimized Render Pipeline

Updated: 2026-07-27

## Goal

The optimization target is sustained end-to-end throughput, not the latency of
one voice. At 100 MHz and 48 kHz an eight-frame block has 16666 clocks. The
generic core must render 256 active mono lanes; 512 lanes is the current stretch
target. The architecture uses one copy of each arithmetic pipeline rather than
duplicating complete render engines.

## Selected Architecture

```text
active scan / state read (prefetched)
  -> 8-slot tagged envelope walk, one frame step per clock
  -> 8-slot tagged phase planning, one frame step per clock
  -> one voice-major segment reader, four consecutive lines per segment
  -> endpoint-valid scoreboard and frame-interleaved issue
  -> one tagged 8-stage interpolation/filter/gain DSP
  -> tagged state retire and wide block mix
  -> published-block effects / compressor / FIFO / I2S (next integration)
```

Eight is a binary scheduling window, not eight engines. A slot holds one small
block descriptor, up to eight endpoint jobs, returned samples, progress bits,
and recursive state. Envelope conversion, phase stepping, memory issue, and DSP
arithmetic each remain single shared resources.

This is the FPGA equivalent of CPU hardware multithreading plus a scoreboard:
when one context has a true filter RAW dependency or waits for memory, another
context uses the pipeline. Tagged state forwarding permits a context to issue
again on the same clock its new `z1/z2` appears.

## Memory Order

Phase jobs from different blocks may be interleaved internally, but external
memory traffic remains voice-major. The segment reader selects one planned
voice, aligns the first uncovered endpoint to 32 words, and emits four
consecutive 8-word line requests before choosing another segment. Returned words
set per-endpoint valid bits in that voice's slot. A frame can issue as soon as
both interpolation endpoints are valid, so there is no separate replay pass.

The fixed four-line segment is a current interface contract, not a claim that it
is optimal for every memory. Real traces must report burst starts, average burst
length, words fetched, endpoint hits, and useful-word ratio. A future 1/2/4-line
adaptive policy must preserve voice-major continuity.

## Measured Throughput

Conditions: eight frames, ideal ordered memory accepting one line request per
clock and returning it one clock later.

| Active lanes | Filter off | Filter on | Deadline |
| ---: | ---: | ---: | ---: |
| 256 | 2149 | 2191 | 16666 |
| 512 | 4197 | 4258 | 16666 |

The 256 filtered run issues and retires exactly 2048 samples, makes 1024 line
requests, and reaches a 312-clock uninterrupted DSP issue run. The 512 filtered
run handles 4096 samples and 2048 line requests with the same 312-clock maximum
run. This proves that the production SV path reaches one sample per clock for
long steady-state intervals; fill, controller group transitions, the final
drain, and ideal-memory scheduling still create occasional bubbles.

Historical 256-lane checkpoints:

| Architecture | Filter off | Filter on |
| --- | ---: | ---: |
| old single-voice DSP FSM | 13328 | 21520 |
| deleted prepared-slot renderer | 7218 | 13625 |
| two-entry streaming/forwarding renderer | 5928 | 7734 |
| eight work tags, still serial frontend | 5928 | 5956 |
| interleaved phase/memory frontend | 3373 | 3401 |
| current tagged envelope + render pipeline | 2149 | 2191 |

## Effects Parallelism

Voice rendering and effects should process different published blocks at the
same time. Within one effects block, dry, chorus, and reverb may fork and join
when no routing edge connects them. If chorus feeds reverb, that edge remains a
real dependency. Delay, FDN, compressor, and other recursive histories still
process each stream in frame order; independent channels or branches can be
pipelined, but recursive frames cannot be reordered blindly.

The intended whole-system flow is therefore block-overlapped and frame-streamed:
renderer fills mix bank N while effects drain bank N-1 and I2S consumes the PCM
reservoir. Queue occupancy must remain bounded under the real memory and effects
latency distributions.

## What Is Not Proven

- The current tests model ideal ordered line memory, not DDR3/MIG latency,
  arbitration, refresh, or row behavior.
- Vivado is unavailable in the current environment. BRAM/DSP48 inference,
  utilization, routing, and post-route 100 MHz timing are unsigned.
- The combinational endpoint/segment scans and eight-slot descriptor arrays need
  early synthesis review; they may require registered selection trees or RAM
  banking without changing behavior.
- Published mix-bank drain, effects fork/join, compressor, reservoir, and I2S
  are not yet integrated into one sustained end-to-end test.
- Long MIDI/SF2 exact comparison has not been ported to the replacement RTL top.

The 4258-cycle 512-lane result is compute headroom, not board sign-off.
