# Voice-Major Renderer Handoff

Updated: 2026-07-27

## Resume Here

Read, in order:

1. `docs/design/optimized_render_pipeline.md` for the end-to-end architecture.
2. `docs/design/voice_major_render_pipeline_detailed.md` for the authoritative
   stage-by-stage design and verification boundaries.
3. `docs/design/voice_major_block_renderer_guide.md` for a short beginner explanation.
4. `docs/fixed_point.md`, `docs/memory_format.md`, and `docs/register_map.md` for
   contracts that must remain exact.

The old prepared-slot renderer and standalone frame-queue prototype are deleted.
Do not restore a fill-one/drain-one FSM. The production renderer now contains the
tagged scheduling window and real DSP connection.

## Current Production Path

```text
voice_major_block_controller
  -> pending state-read register
  -> block_interleaved_envelope_frontend (8 tagged slots, one shared pipeline)
  -> block_interleaved_voice_renderer
       - 8 tagged phase/memory/DSP work slots
       - one round-robin phase step per clock
       - one voice-major ordered segment reader
       - endpoint-valid scoreboard
       - RAW-aware frame issue
  -> block_interleaved_voice_dsp (one arithmetic pipeline)
  -> tagged dynamic-state writeback + block_mix_buffer
```

`BLOCK_WORK_ENTRY_COUNT=8`, so work IDs are three bits. This is the minimum
binary window comfortably exceeding the five-cycle filter-state feedback
distance while providing elasticity between envelope, phase, memory, and DSP.
It does not instantiate eight DSPs.

The controller can replace its pending state snapshot on the same clock the
engine consumes the previous snapshot. State selection and synchronous read can
therefore run ahead of envelope execution.

The envelope frontend carries `{slot, frame, last}` through one four-stage level
conversion pipeline. Eight slot records hold recursive envelope state and voice
descriptors. The production phase frontend uses the same principle: a single
phase combinational unit advances one selected slot per clock.

## DSP Hazard Contract

After a filtered sample issues, its work slot sets a hazard bit. The slot cannot
issue again until the tagged DSP state update appears. Other slots remain
eligible. If the scheduler selects that slot on the update clock, the token uses
forwarded `z1/z2`; the stored state would only become visible after the edge.

Filter bypass does not set this hazard. DSP backpressure globally freezes all
valid stages and payloads. Same-slot frames remain ordered; different slots may
interleave and retire in pipeline order.

## Memory Contract

External requests remain voice-major even though phase and DSP work are
interleaved. For each selected segment the renderer emits four consecutive
addresses:

```text
base + 0, base + 8, base + 16, base + 24
```

where `base` is 32-word aligned. It does not switch voices in the middle of this
sequence. Ordered responses carry no transaction ID and are associated with the
locked segment. Endpoint-valid bits allow samples to issue without a replay FSM.

The current RTL handles multiple segments for jumped endpoints directly. The
unused serial endpoint planner, segment planner, sample gather, and envelope
walker have been deleted together with their standalone TBs. New jump,
fractional-phase, and loop-wrap coverage must target the production renderer
rather than recreate those intermediate modules.

## Latest Measurements

Ideal one-cycle ordered memory, eight frames:

| Lanes | Filter | Cycles | DSP issues | Lines | Max issue run |
| ---: | :---: | ---: | ---: | ---: | ---: |
| 256 | off | 2149 | 2048 | 1024 | 1608 |
| 256 | on | 2191 | 2048 | 1024 | 312 |
| 512 | off | 4197 | 4096 | 2048 | 3656 |
| 512 | on | 4258 | 4096 | 2048 | 312 |

All are below the conservative 16666-cycle deadline. Filter-on is now close to
filter-off, and the real production path sustains one filtered DSP issue per
clock for hundreds of clocks. Occasional bubbles come from fill/drain, active
group transitions, and upstream scheduling rather than the filter feedback
distance.

## Verification Completed

```text
make lint
make test
make test-rtl-core
make test-voice-major-512
make measure-voice-major-throughput
make measure-voice-major-throughput-filtered
make measure-voice-major-throughput-512
make measure-voice-major-throughput-512-filtered
```

Core regressions include exact renderer arithmetic/backpressure, tagged DSP
feedback, state ownership, controller traversal, and the new eight-context
envelope tag/level/backpressure test. Throughput TBs assert contribution counts,
RAW safety, forwarding, deadline, contiguous per-voice line order, and at least
64 consecutive filtered II=1 issues for the 256/512 workloads.

Verilator can fail internally during concurrent builds; retry a failed target.
Vivado is not in PATH, so there is no synthesis or timing result yet.

## Next Work Order

1. Add fixed and randomized memory stalls plus counters for work occupancy,
   phase starvation, memory starvation, hazard stalls, retire stalls, and useful
   words per segment. Report p50/p99/max block time.
2. Add jumped-address, fractional-phase, and loop-wrap cases directly to
   `tb_block_interleaved_voice_renderer`. The old serial modules and their TBs
   are gone; do not restore them as test scaffolding.
3. Run early Vivado synthesis. Check RAM inference for slot arrays, DSP48 mapping,
   combinational selection depth, resource fit, and 100 MHz timing. Register or
   bank selection trees if needed without changing the scheduling contract.
4. Define a burst adapter and multiple outstanding tagged bursts while retaining
   the per-voice contiguous segment lock. Compare fixed four-line and adaptive
   1/2/4-line traffic with real SF2/MIDI address traces.
5. Connect published mix-bank drain to frame-tagged effects fork/join, compressor,
   PCM reservoir, and I2S. Prove renderer/effects/output overlap on different
   blocks and bounded queue occupancy.
6. Port the long MIDI/SF2 RTL harness to the new mono-lane event/state interfaces
   and run exact comparisons with block-boundary events and memory stalls.

Do not claim board readiness from ideal-memory cycle counts. Do not add more
contexts or duplicate arithmetic until synthesis and stall diagnostics show the
actual limiting resource.
