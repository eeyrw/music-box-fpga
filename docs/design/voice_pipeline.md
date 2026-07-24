# Multi-Voice Render Pipeline

This document describes the current `multi_voice_pipeline` implementation. The
numeric contract is in `../fixed_point.md`; memory layout and handshakes are in
`../memory_format.md`.

## Interface

One accepted `sample_tick` requests one stereo PCM frame. The renderer exposes:

- an indexed synchronous control-state read (`voice_read_index`);
- an envelope snapshot/writeback handshake;
- active and START-activation bitmaps;
- ordered word-memory ready/valid traffic;
- a completion pulse with signed 16-bit left/right samples;
- queue occupancy and memory-pressure diagnostics.

`busy` remains asserted from frame acceptance through final PCM generation.

## State Ownership

The control plane owns packed prepared and active records. The renderer reads one
active record at a time and owns the state that changes with sample fetching:

| State | Owner | Storage |
| --- | --- | --- |
| Wave addresses, lengths, loops, initial phase | control | active RAM |
| Phase increment, gain, envelope, filter coefficients | control | active RAM |
| Advancing left/right phase | renderer | distributed RAM |
| Biquad `z1/z2`, left/right | renderer | distributed RAM |
| Active/prepared validity | control | bitmaps |
| Phase/filter-history validity | renderer | bitmaps |

A matching `VOICE_START` produces a one-frame activation pulse. The renderer
then reloads phase from `phase_init` and treats filter history as zero. Runtime
gain, phase-increment, envelope, and filter changes do not reload phase.

## Front-End State Machine

| State | Work |
| --- | --- |
| `IDLE` | Wait for a frame, clear accumulators, and latch activation pulses. |
| `SCAN_VOICE` | Find the next set bit in `config_valid`. |
| `READ_VOICE` | Present the selected synchronous RAM address. |
| `WAIT_VOICE` | Allow active, phase, and filter-state reads to settle; request an envelope snapshot. |
| `WAIT_SNAPSHOT` | Wait for the registered snapshot conversion result. |
| `START_VOICE` | Capture one coherent render context and start prefetching the next valid voice. |
| `PROCESS_VOICE` | Skip disabled/done voices or enqueue endpoint work and write next phase. |
| `DSP_START` | Advance to the prefetched voice, resume scanning, or enter drain. |
| `DRAIN` | Wait for endpoint requests, responses, DSP contexts, and results to retire. |
| `FINISH` | Saturate accumulators and pulse `sample_valid`. |

Sequential bitmap scanning deliberately trades clocks for area. It avoids a
wide next-active priority encoder. Empty slots cost scan clocks but do not issue
RAM, memory, or DSP work.

## Coherent Voice Snapshot

The control RAM, phase RAM, and filter-state RAM use synchronous reads. A voice
therefore passes through `READ_VOICE`, `WAIT_VOICE`, and `START_VOICE` before its
fields are consumed.

During `WAIT_VOICE`, `runtime_snapshot_prepare` asks the executor to advance the
selected volume envelope and write the new active record. A separate
`runtime_snapshot_valid` marks the registered conversion result; the renderer
does not assume combinational RAM or lookup-table output. The snapshot contains
the level for the current output frame.

The front end starts scanning the remaining bitmap while the current voice
enters endpoint fetch. As soon as that scan finds a valid record, its envelope
snapshot request overlaps the current voice's memory wait. A completed prefetched
snapshot advances directly to `START_VOICE`; cancellation clears the associated
prefetch state so a late result cannot be applied to another voice.

## Phase And Looping

Phase is unsigned Q24.8 in sample-frame units:

```text
frame_0  = phase[31:8]
fraction = phase[7:0]
frame_1  = frame_0 + 1, adjusted at the sample or loop boundary
next     = phase + phase_inc, with at most one loop-span subtraction
```

Mono uses one phase and duplicates the interpolated sample before independent
left/right gain. Stereo has independent left/right addresses, lengths, loop
points, and phase state while sharing `phase_inc` and interpolation fraction.

`loop_end` is exclusive. Loop-until-release behaves as continuous looping until
the active record's released bit is set, then proceeds toward the sample end.
No-loop voices stop contributing when phase reaches length.

## Endpoint Fetch

`voice_endpoint_fetch` accepts one complete context and serializes its required
word reads:

- mono: left frame 0 and frame 1;
- stereo: left frame 0/1 and right frame 0/1.

Accepted-request metadata is queued so ordered responses can be placed into the
correct fetch slot. Four fetch slots, a 16-entry word-request queue, and a
16-entry response-metadata queue allow memory latency from several voices to be
overlapped. A completed slot is registered directly as one
`voice_dsp_context_t`; a second full-width context FIFO is unnecessary because
the ordered response port can complete at most one slot per clock and the DSP
accepts one context per clock.

The renderer does not assume asynchronous memory. All request and response
movement follows ready/valid rules.

## DSP Pipeline

`voice_dsp_pipeline` is fixed latency and can accept one complete context every
clock. Different voices may occupy all stages concurrently. Its work is:

1. Linear interpolation using the Q24.8 fraction.
2. Optional transposed direct-form II biquad per channel.
3. Filter state calculation and saturation.
4. Register the independent left/right sample-by-channel-gain products.
5. Apply the shared Q1.15 envelope in a separate multiplier stage.
6. Register signed 16-bit per-voice contribution saturation.

Mono samples are duplicated before channel gain. Stereo samples retain their
independent channels. Results carry the voice index so filter history can be
written back on retirement.

## Accumulation And Completion

DSP results retire into signed 32-bit left/right accumulators. `DRAIN` waits
until endpoint fetch is empty and the outstanding DSP count reaches zero.
`FINISH` then performs the only final mix saturation to signed 16-bit PCM.

Renderer output is a pulse. `wavetable_system_core` converts it to a held
ready/valid frame before the output FIFO.

## Diagnostics

The pipeline exports pulses and high-water marks for:

- cross-line endpoint pairs;
- fetch-slot pressure;
- memory stalls;
- fetch-slot, word-request, response-metadata, and DSP-context occupancy;
- cycles where the DSP is ready but no complete context is available.

The C++ harness also records total/max render cycles, memory reads, active and
audible voices, stereo/filter counts, cache behavior, and saturation metrics.

## Cost Model

For a frame, the fixed front-end cost includes bitmap scanning and synchronous
read staging. Each contributing mono voice needs two PCM words; stereo needs
four. With one accepted word request per clock, the ideal issue limits are one
mono voice per two clocks and one stereo voice per four clocks. The DSP's
one-context-per-clock initiation interval is therefore intentionally higher than
the memory-side supply rate. Cache hits reduce external line traffic but not the
logical endpoint count. The frame cannot complete until the slowest accepted
endpoint response and all DSP results retire.

The current design favors bounded area and simple ordering over maximum
polyphony throughput. Optimize only from measured queue, memory-stall, FIFO, and
post-route data. A future voice-major block renderer is a separate architecture,
not a control-plane compatibility feature.

## Verification

Focused RTL tests cover:

- reset and empty frames;
- DEFINE isolation and atomic START;
- mono/stereo interpolation and exclusive loops;
- no-loop completion and loop-until-release;
- runtime gain/phase/filter changes without phase reload;
- filter width, rounding, saturation, and state reset on START;
- highest voice index and multi-voice mixing;
- cached-memory counters and backpressure;
- coherent control-state debug capture.

Run `make test-rtl-core` for these tests and `make test` for the complete suite.
