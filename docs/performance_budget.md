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
- One pair of one-pole low-pass filter calculations.
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
sample fetch -> interpolation multiply -> filter multiply -> gain multiply -> envelope multiply -> accumulator
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
- Add pipeline registers around interpolation, filter, gain, and envelope multiplication.
- Add a wave cache or prefetch layer before external Flash.
- Add an output FIFO so I2S consumes samples at a fixed rate even if render
  latency varies slightly.

## Minimal Next Step

The current RTL sets `NUM_VOICES = 32` while retaining the sequential renderer.
Before rewriting the renderer, measure the current design under
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

## FPGA Porting Checklist

The C++ MIDI render harness is an offline, demand-driven model: it requests one
audio frame with `sample_tick`, advances the Verilator clock until
`sample_valid`, and then writes that frame into a WAV file. A board design must
instead be a fixed-rate real-time system. One output frame must be available
every `1 / sample_rate_hz` seconds regardless of temporary memory or control-side
delays.

Clock and sample-rate generation:

- Add a real `sample_tick` generator from the board/system clock.
- If `sys_clk_hz` is not an integer multiple of the target sample rate, use a
  fractional accumulator/NCO tick generator and document the long-term rate
  error and jitter.
- Keep the relation explicit: `cycles_per_sample = sys_clk_hz / sample_rate_hz`.
  The current C++ harness does not model this divider.

Real-time deadline:

- Measure worst-case `sample_valid - sample_tick` latency with maximum active
  voices, mono and stereo waves, and realistic memory latency.
- Decide the underrun policy if the renderer misses the audio deadline. Options
  include holding the previous sample, outputting zero, dropping lower-priority
  voices, or using a deeper output FIFO.
- Treat sample-rate changes as a full timing-budget change because they affect
  both the deadline and `phase_inc` calculation.

Wave memory:

- Replace the one-cycle simulation memory model with the chosen board memory
  interface.
- Account for command overhead, bus turnaround, cache misses, arbitration, and
  burst alignment, not only raw payload bandwidth.
- Add a wave cache or prefetch layer before high-latency or serial storage such
  as SPI Flash.
- Preserve the RTL ready/valid ordering contract or add tags/FIFOs if responses
  can return out of order.

Audio output:

- Replace WAV-file writing with the board output path, such as I2S, PWM, or an
  external DAC interface.
- Add clock-domain handling if the audio serializer uses clocks derived from a
  different PLL or clock enable.
- Add an output FIFO so the audio interface consumes samples at a fixed cadence
  even when render latency varies slightly.
- Define startup, reset, mute, and underrun behavior to avoid pops and clicks.

Control plane:

- Decide whether MIDI parsing, SF2 region lookup, voice allocation, and ADSR stay
  on an external MCU/host, move to a soft core, or move partly into RTL.
- If ADSR remains software-driven, budget the per-control-tick register writes
  for all active voices.
- If ADSR moves into RTL, update the register map and tests so runtime envelope
  behavior has a hardware contract.
- Account for Note On programming latency: several voice registers must be
  written before the commit register can atomically activate the slot.
- Consider a timestamped event queue if MCU or bus latency makes sample-accurate
  event timing unreliable.

SoundFont and MIDI assets:

- Do not rely on runtime `.sf2` parsing in FPGA fabric. Preprocess SF2 assets
  into a flash/memory image plus region metadata tables, or have the MCU load
  those tables before playback.
- Keep the documented wave-memory format: mono one word per frame, stereo
  interleaved left/right words, and exclusive `loop_end` frame indexes.
- Track the SF2/MIDI behavior gaps listed in `docs/simulation_design.md`; those
  gaps become user-visible playback limitations on hardware.

Verification before board bring-up:

- Add tests for a real `sample_tick` generator, including non-integer clock-rate
  ratios if supported.
- Add memory-latency stress tests and output-FIFO underrun tests.
- Add render latency counters or assertions that fail when the pipeline exceeds
  the configured cycles-per-sample budget.
- Run long MIDI/SF2 renders that stress high polyphony, stereo samples, loop
  boundaries, release tails, positive/negative PCM extremes, and mixer saturation.
