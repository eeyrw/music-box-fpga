# System Design

This document describes the current wavetable synthesizer architecture. Stable
external contracts live in:

- `../fixed_point.md`: numeric formats and arithmetic rules.
- `../memory_format.md`: PCM layout and memory handshakes.
- `../register_map.md`: global registers, command ingress, and debug snapshot.
- `control_command_stream_plan.md`: command words and voice lifecycle.
- `spi_command_stream_throughput.md`: SPI command-stream workload and SCLK
  sizing analysis.
- `spi_register_timing.md`: SPI register read/write and burst timing analysis.
- `spi_transport_backlog.md`: SPI correctness bugs and DMA-safe transport work.
- `../verification/simulation_design.md`: tests and render flows.

## Scope

The generic core is synthesizable, single-clock SystemVerilog. It implements
multi-voice wavetable playback but does not contain a vendor PLL, DDR PHY,
physical SPI timing constraint, or FPGA pin constraint. Those belong under
`fpga/`.

The voice count is parameterized. The package default is 32 voices; normal
regressions override it to 256 to cover the complete 8-bit command voice field.

## Architecture

```text
register bus ---------> synth_control_plane -----------+
dedicated command ---> command FIFO/parser/executor    |
                                                       v
sample/frame request ------------------------> multi_voice_pipeline
                                                       |
                                                       v
                                       word memory request/response
                                                       |
                                                       v
                                             stereo PCM frame
```

`wavetable_render_core` composes the control plane and renderer.
`wavetable_cached_render_core` adds the per-voice line cache.
`wavetable_system_core` adds the common line-memory adapter and a held
ready/valid PCM output. `wavetable_i2s_output` places a PCM FIFO between that
output and the I2S serializer.

See `rtl_module_map.md` for file ownership and the full instantiation tree.

## Voice Control

Voice control is a transactional command stream. There is no writable per-voice
register window and no compatibility register bank.

The control plane contains:

- a 1024-word command FIFO implemented by one synchronous simple-dual-port
  block RAM;
- a parser that emits only complete, length-checked actions;
- a 32-entry decoded action FIFO;
- a bounded executor that applies at most 16 actions before releasing a waiting
  render frame;
- one packed prepared RAM and one packed active RAM;
- sequence validation and command/stale-sequence error counters.

`VOICE_DEFINE_MONO` and `VOICE_DEFINE_STEREO` replace prepared state only.
`VOICE_START` with a matching sequence atomically promotes the prepared
configuration and installs gain, phase increment, filter, and fresh envelope
state. Runtime commands replace complete logical fields and never reload phase.

The active record contains command-owned state:

- audibility and sequence;
- wave addresses, lengths, loop points, initial phase, stereo and loop mode;
- Q24.8 phase increment;
- independent Q1.15 left/right gains;
- filter coefficients and enable;
- six-stage volume-envelope parameters and state.

The renderer owns advancing phase and biquad history. A START activation pulse
reloads phase from `phase_init` and clears filter history at the next frame.

## Volume Envelope

The FPGA advances one voice envelope when that voice is snapshotted for an
output frame. Stages are Delay, Attack, Hold, Decay, Sustain, and Release.

The host converts SF2 durations and levels into the fixed-point START fields.
The FPGA owns subsequent volume-envelope progression, including release and
automatic deactivation at silence. `VOICE_ENV_UPDATE` changes selected envelope
parameters without reloading phase or restarting the envelope.

Modulation envelopes and LFO policy remain in C++. They send changed gain/phase
or filter values through runtime commands.

## Rendering

`multi_voice_pipeline` renders one stereo frame at a time:

1. Latch START activation pulses for the frame.
2. Scan the active bitmap in voice-index order.
3. Read one packed active record through the synchronous control RAM port.
4. Snapshot command-owned state and renderer-owned phase/filter history.
5. Compute interpolation endpoints and next phase.
6. Queue mono or stereo word reads through `voice_endpoint_fetch`.
7. Run interpolation, optional biquad filtering, independent left/right gain,
   envelope gain, and saturation in `voice_dsp_pipeline`.
8. Retire contributions into signed 32-bit stereo accumulators.
9. Emit one saturated signed 16-bit stereo frame after all work drains.

The renderer overlaps the next valid-voice scan and envelope snapshot with the
current voice's endpoint traffic. Four fetch slots plus independent 16-entry
request and response-metadata queues keep several voices in flight while the
fixed-latency DSP accepts one completed context per clock. Memory remains the
main variable-latency and throughput boundary: the single word-request port
needs at least two accepted cycles per mono voice and four per stereo voice.

Detailed state and arithmetic ownership are documented in `voice_pipeline.md`.

## Memory

The bare core uses ordered ready/valid word reads. A request carries voice,
left/right stream ID, and absolute 16-bit word address. Responses are returned
in accepted-request order.

`voice_endpoint_fetch` tracks outstanding endpoint metadata and assembles a
complete DSP context. `voice_line_cache` converts word reads to external line
reads and preserves per-voice/per-stream locality. Board-specific DDR control is
outside the generic core.

## Audio Scheduling

The common wrapper uses a credit scheduler and output FIFO:

- `OUTPUT_FIFO_DEPTH` defaults to 64 frames.
- `TARGET_LEVEL` defaults to 48 frames.
- playback starts after `START_LEVEL`, normally 48 frames, is reached;
- renderer output is held until the FIFO accepts it;
- startup does not count as underrun;
- rendered, played, lead, minimum-level, underrun, and drop diagnostics are
  exposed through common status registers.

## Debug Snapshot

The global debug aperture captures one selected voice's coherent command/control
state. It waits for the renderer and action executor to become idle, reuses the
prepared/active RAM read ports, and serializes 24 words into a 768-bit
distributed RAM.

It intentionally excludes renderer-private advancing phase and biquad history.
This keeps the default build inexpensive. Add a separate datapath trace aperture
only if hardware bring-up demonstrates that those states are necessary.

## Board Boundary

Reusable board-facing RTL under `fpga/common/rtl` provides:

- SPI register and dedicated command-stream transport;
- common status and platform register routing;
- sample-clock generation;
- held PCM output and line-memory adaptation;
- output FIFO and I2S serialization.

The Smart Artix implementation additionally owns native SD loading, DDR3
arbitration, MIG integration, DDR debug access, clocking, and constraints.

## Next Hardware Work

The generic command/control and render architecture is complete. Board work now
centers on post-route timing closure, long memory-stall/full-polyphony stress,
and physical SPI/I2S validation. Voice observability should grow through bounded
snapshot or trace apertures rather than a writable per-voice register window.
