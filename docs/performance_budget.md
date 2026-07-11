# Performance Budget And Pipeline Direction

This document estimates whether the current multi-voice renderer can meet a
real-time audio deadline, and outlines the pipeline direction needed for a
32-voice design.

It is an architecture note, not a current RTL contract. The current RTL favors a
clear functional simulation path over maximum throughput.

## Current Renderer

The current `multi_voice_pipeline` is a time-multiplexed sequential renderer:

```text
sample_tick
  -> scan voice 0
  -> fetch/interpolate/gain/envelope/accumulate if active
  -> scan voice 1
  -> fetch/interpolate/gain/envelope/accumulate if active
  -> ...
  -> saturate mixer
  -> sample_valid
```

It uses one shared datapath:

- One wave-memory request stream.
- One pair of interpolators.
- One pair of gain multipliers.
- One pair of envelope multipliers.
- One stereo mixer accumulator.

This is efficient in area and easy to verify, but it is not a CPU-style pipeline.
It does not overlap fetch for one voice with interpolation or gain for another
voice. Each active voice is completed before the next active voice is processed.

## Audio Deadline

For real-time output, one mixed stereo sample must be produced every audio sample
period:

```text
cycles_per_sample = sys_clk_hz / sample_rate_hz
```

Examples:

| System clock | Sample rate | Cycles per output sample |
| --- | ---: | ---: |
| 25 MHz | 48 kHz | 520 |
| 50 MHz | 48 kHz | 1041 |
| 100 MHz | 48 kHz | 2083 |
| 50 MHz | 44.1 kHz | 1133 |

The renderer must finish all active voices, final saturation, and any output
handoff inside that budget.

## Current Cycle Model

With the current memory model, one memory response arrives one cycle after each
accepted request. The state machine also spends cycles issuing requests,
waiting for responses, accumulating, and moving between voices.

Approximate per-active-voice cost:

```text
mono voice   ~= START + 2 request/response pairs + ACCUMULATE
stereo voice ~= START + 4 request/response pairs + ACCUMULATE
```

With one-cycle memory latency, a rough estimate is:

```text
mono_cycles_per_voice   ~= 6 to 8 cycles
stereo_cycles_per_voice ~= 10 to 12 cycles
```

The total render time is approximately:

```text
render_cycles ~= scan_overhead
              + active_mono_voices   * mono_cycles_per_voice
              + active_stereo_voices * stereo_cycles_per_voice
              + finish_cycles
```

For 32 active voices with the current ideal memory model:

```text
32 mono voices   ~= 200 to 260 cycles
32 stereo voices ~= 320 to 390 cycles
```

That is feasible at 48 kHz if the system clock is comfortably above 25 MHz and
memory behaves like the current one-cycle simulation model. It is not a safe
assumption for external Flash or a high-latency memory controller.

## Memory Bandwidth

Linear interpolation fetches two frames per channel.

Memory reads per output sample:

```text
mono voice   = 2 words
stereo voice = 4 words
```

Worst-case 32-voice read rate:

```text
mono:   sample_rate * 32 * 2
stereo: sample_rate * 32 * 4
```

At 48 kHz:

```text
mono:   48,000 * 32 * 2 = 3.072M 16-bit reads/s
stereo: 48,000 * 32 * 4 = 6.144M 16-bit reads/s
```

In bytes per second:

```text
mono:   6.144 MB/s
stereo: 12.288 MB/s
```

This is only the raw sample-read payload. It excludes command overhead, address
turnaround, cache misses, arbitration, and any bus protocol inefficiency.

Parallel memory or on-chip RAM can support this more naturally than SPI Flash.
For serial or high-latency storage, a cache or prefetch layer becomes necessary.

## Why A Pipeline Helps

A CPU-style pipeline overlaps different stages for different voices. A possible
voice rendering pipeline looks like this:

```text
cycle N:     voice0 address generation / fetch request
cycle N+1:   voice0 response capture, voice1 fetch request
cycle N+2:   voice0 interpolation, voice1 response capture, voice2 fetch request
cycle N+3:   voice0 gain/envelope, voice1 interpolation, voice2 response capture
cycle N+4:   voice0 mix accumulate, voice1 gain/envelope, voice2 interpolation
```

The goal is one accepted voice contribution every cycle or every few cycles once
the pipeline is full, instead of completing all steps for one voice before
starting the next.

Pipeline registers would also improve timing closure by splitting long
combinational paths:

```text
sample fetch -> interpolation multiply -> gain multiply -> envelope multiply -> accumulator
```

The current implementation leaves these operations close together because the
first milestone prioritizes correctness and testability.

## Pipeline Hazards

A pipelined 32-voice renderer must handle several hazards explicitly.

Memory latency:
The pipeline needs either predictable memory latency or tags/FIFOs that preserve
which voice and channel a response belongs to.

Loop endpoint pairing:
For each voice, `frame_0`, `frame_1`, and `fraction` must stay associated with
the returned samples through the pipeline.

Runtime envelope updates:
The MCU can write `ENVELOPE_LEVEL` while rendering is active. The design must
define whether a voice uses the envelope value sampled at voice-start time or the
latest value at gain/envelope stage time.

Mixer accumulation:
All voice contributions target the same stereo accumulator for the current output
sample. The pipeline must clear the accumulator once per output sample, add each
active voice exactly once, and saturate only after the final contribution.

Commit and phase reload:
If firmware commits a voice while the renderer is scanning, the design must
define whether the new config applies immediately, at the next output sample, or
after a voice-safe boundary. The current sequential renderer naturally samples
config as it reaches each slot; a pipelined renderer may need a frame boundary
snapshot.

Backpressure:
If memory stalls, the audio output deadline can be missed unless the design has
prefetch, buffering, or a policy for underrun.

## Recommended 32-Voice Direction

For a robust 32-voice design, the likely architecture is:

```text
Register Bank / MCU Writes
        |
        v
Voice State Snapshot at audio-frame boundary
        |
        v
Voice Scheduler
        |
        v
Address Generation / Wave Cache Request
        |
        v
Sample Response FIFO with voice tags
        |
        v
Interpolation Stage
        |
        v
Gain + Envelope Stage
        |
        v
Mixer Accumulator
        |
        v
Saturate -> Output FIFO / I2S
```

Key design choices:

- Snapshot active voice config at the start of each output sample.
- Keep runtime phase per voice in the renderer.
- Use a scheduler that emits one voice job per cycle or per small fixed number of
  cycles.
- Add pipeline registers around interpolation, gain, and envelope multiplication.
- Add a wave cache or prefetch layer before external Flash.
- Add an output FIFO so I2S consumes samples at a fixed rate even if render
  latency varies slightly.

## Minimal Next Step

Before rewriting the renderer, measure the current sequential design under
simulation with a simple cycle counter:

```text
latency_cycles = sample_valid_cycle - sample_tick_cycle
```

Run this for:

- 1, 4, 8, 16, and 32 active voices.
- Mono and stereo waves.
- One-cycle memory and artificial multi-cycle memory latency.

That measurement will show whether the immediate bottleneck is the voice state
machine, memory reads, or DSP stage timing.

## Practical Interpretation

The current renderer is a good functional baseline. It can validate register
semantics, loop behavior, phase increments, envelope writes, and mixing.

For 32 voices, the main question is not only `NUM_VOICES = 32`. The real design
question is whether the memory system and renderer can deliver all needed sample
fetches inside one audio sample period. If not, the next architectural work is a
pipelined scheduler plus wave cache/prefetch, not more register slots.
