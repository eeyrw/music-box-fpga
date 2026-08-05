# System Design

This document describes the current wavetable synthesizer architecture. Stable
external contracts live in:

- `../fixed_point.md`: numeric formats and arithmetic rules.
- `../memory_format.md`: PCM layout and memory handshakes.
- `../register_map.md`: global registers, command ingress, and debug snapshot.
- `../command_stream.md`: command words and voice lifecycle.
- `../backlog/envelope.md`: envelope timing and Delay compatibility backlog.
- `../backlog/effects.md`: implemented global chorus/reverb path, completion
  matrix, remaining resource/verification gates, and deferred per-voice sends.
- `audio/effects_parameters.md`: common effect-control terminology mapped to
  the implemented chorus/FDN fields, preset values, and modeling limits.
- `transport/spi_command_stream.md`: SPI command-stream workload and SCLK
  sizing analysis.
- `transport/spi_register_mailbox.md`: SPI register mailbox timing and throughput analysis.
- `../backlog/spi_transport.md`: compatible transaction-atomicity fixes, physical
  timing work, and optional packetized DMA transport.
- `../verification/simulation_design.md`: tests and render flows.
- `../backlog/system_architecture.md`: measured system-level limitations and
  candidate control/render/memory/audio redesigns.

## Scope

The generic core is synthesizable, single-clock SystemVerilog. It implements
multi-voice wavetable playback but does not contain a vendor PLL, DDR PHY,
physical SPI timing constraint, or FPGA pin constraint. Those belong under
`fpga/`.

The project voice count is selected by the top-level Makefile through
`NUM_VOICES`, which defaults to 512 and drives RTL, C++ harness, and Vivado
builds. Explicit 256- and 512-voice throughput targets are workload regressions,
not separate project defaults. Version 10 commands carry an authoritative
10-bit voice ID in payload word zero.

## Architecture

```text
register bus / SPI command stream
              |
              v
voice_major_command_plane -> block_voice_state_store
              |                       |
              +-----------------------+
                                      v
voice_major_block_controller -> mono engine -> 32-word/voice sample window
                                      |                    |
                                      v                    v
                           signed 25-bit block mix   ordered DDR burst adapter
                                      |
                                      v
                       chorus/reverb -> compressor/master
                                      |
                                      v
                              PCM FIFO -> I2S
```

`voice_major_render_core` is the production generic top. The Smart Artix top
uses `voice_major_system` to retain main's SPI bridge, register fabric,
platform/common status windows, effects, PCM FIFO, and I2S serializer. The
superseded single-frame tops and their compatibility wrappers have been removed;
the voice-major path is the only supported implementation.

The production control and USB bridge is now an RP2040 firmware target under
`mcu/`. USB-MIDI enters the compact MSF2 policy, which allocates voices and sends
the existing `0xa5` transactional command stream over SPI. FPGA-generated I2S
returns to the RP2040 through PIO/DMA and is exposed as asynchronous UAC2 stereo
capture. This does not move PCM synthesis or effects into the MCU. See
[`../mcu/rp2040_firmware.md`](../mcu/rp2040_firmware.md) for the exact ownership,
wiring, USB topology, and current hardware qualification.

See `rtl_module_map.md` for file ownership and the full instantiation tree.

## Voice Control

Voice control is a transactional command stream. There is no writable per-voice
register window and no compatibility register bank.

The control plane contains a 1024-word FIFO, a length/semantic-checking parser,
the block state store, generation validation, and command/stale-generation
counters. Commands enter only through the dedicated SPI `0xa5` stream; version
15 adds an `0xa6` transport FLUSH that cancels unpublished bridge words, clears
the command FIFO, and resets the parser. A render block is admitted only after pending commands
have drained, so state changes occur at an output-block boundary.

`VOICE_START_MONO` installs a complete descriptor, runtime parameters, and fresh
envelope state in a 5-to-16-word compact payload. Runtime ENV, RELEASE, STOP, GAIN, FILTER,
and PITCH commands carry the same 16-bit generation and never reload phase.
Global compressor, master-volume, chorus, reverb, and effect-clear commands are
decoded by the same plane.

The active record contains command-owned state:

- active state and 16-bit generation;
- one mono wave address, length, optional loop points, and loop mode;
- Q24.8 phase increment;
- independent Q1.15 left/right gains;
- filter coefficients and enable;
- six-stage volume-envelope parameters and state.

The renderer owns advancing phase and biquad history. A start clears phase to
zero and clears filter history before its first block.

## Volume Envelope

The FPGA advances one voice envelope when that voice is snapshotted for an
output frame. Stages are Delay, Attack, Hold, Decay, Sustain, and Release.

The host converts SF2 durations and levels into the fixed-point START_MONO fields.
The FPGA owns subsequent volume-envelope progression, including release and
automatic deactivation at silence. `VOICE_ENV_UPDATE` changes selected envelope
parameters without reloading phase or restarting the envelope.

Modulation envelopes and LFO policy remain in C++. They send changed gain/phase
or filter values through runtime commands.

## Rendering

The controller renders up to sixteen output frames per request. It scans voice
IDs 0 through 511 and uses the synchronous dynamic-state snapshot to skip
inactive voices; there is no active-group priority encoder in the render path.
The envelope frontend owns one recursive voice context. Prepared jobs overlap
sample-window traffic with a fixed eight-lane DSP barrel whose modulo lane
counter directly selects the next context; an unavailable lane produces a
bubble rather than a ready search or filter-hazard comparison. Contributions
retire into the ping-pong signed-25 block mix buffer. Published buffers are read
by the top while the other bank can be filled.

Linked SF2 stereo is represented by two host-owned mono voices. Each voice
fetches two interpolation endpoints per audible output frame, duplicates the
interpolated mono sample, and applies independent left/right gain.

## Memory

`voice_sample_window` owns one persistent 32-word window per voice. A miss chosen
for refill issues four aligned 8-word requests; later out-of-window endpoint
reads can use a single-line fallback without replacing the main window. The
generic external contract is ordered, untagged, 8-word/128-bit ready/valid.

On Smart Artix this request enters `smart_artix_ddr3_line_reader`, then the
existing `smart_artix_ddr3_rw_arbiter`, which shares MIG `app_*` with SD asset
writes and the register debug aperture. The line reader queues eight requests
and responses, while the arbiter tracks multiple accepted render reads; both
preserve response order and propagate core response backpressure. The
simulation-only DDR bridge and timing model exercise the same ordered contract
but do not instantiate these board wrappers and are not synthesis sources.

## RTL Interface Bundles

Stable groups of related values are declared as packed structs in
`rtl/pkg/synth_pkg.sv`. Register requests/responses and wave-word
requests/responses therefore cross module boundaries as one typed payload.
Global audio configuration and the audio, cache, voice-pipeline, and render
timing diagnostic groups follow the same rule. Ready/valid control remains
explicit where its direction differs from the payload, and physical board pins
remain flat. This keeps field names visible without duplicating long port lists
through every composition layer.

## Audio Scheduling

The common wrapper uses a credit scheduler and output FIFO:

- `OUTPUT_FIFO_DEPTH` defaults to 64 frames.
- `TARGET_LEVEL` defaults to 48 frames.
- playback starts after `START_LEVEL`, normally 48 frames, is reached;
- renderer output is held until the FIFO accepts it;
- startup does not count as underrun;
- rendered, played, lead, minimum-level, underrun, and drop diagnostics are
  exposed through common status registers.

## Look-Ahead Compressor

The post-mix compressor operates before the final PCM saturation and before
the existing output FIFO. Its stereo-linked detector observes the undelayed mix,
while a fixed 48-frame delay line holds the corresponding stereo samples. The
current approximately 1 ms output FIFO remains after the compressor and retains
its renderer/I2S decoupling and underrun-protection role; it is not the
look-ahead delay line.

Detector dBFS is referenced to PCM16 magnitude `32768`, not to the wider 24-bit
container. It measures `max(abs(left), abs(right))` on each pre-compressor frame,
so a wide mix above the PCM16 range produces positive dBFS. It is an
instantaneous sample-peak detector rather than RMS or LUFS. Post-compressor
master-volume changes therefore do not affect threshold crossing. The exact
numeric contract and threshold conversion are in `docs/fixed_point.md`.

The delay line never drains its stored frames as a burst. With the default
48-frame look-ahead, input frames 0 through 47 only prime the delay. Accepting
input frame 48 detects that future frame and releases delayed frame 0; each
subsequent accepted input releases exactly one subsequent delayed frame. The
post-compressor FIFO must then accumulate its own 48-frame startup level before
I2S playback begins. The default sample-domain latency is therefore additive:

```text
48-frame compressor look-ahead + 48-frame output-FIFO lead
= 96 frames = 2 ms at 48 kHz
```

Pre-rendering may fill both stages faster than real time, so wall-clock startup
can be shorter than 2 ms. That does not change the 96-frame logical latency from
a rendered input sample to its queued I2S playback. Reducing the FIFO target
level reduces total latency but also reduces tolerance for renderer and memory
service jitter.

Each voice contribution is already saturated to signed 16-bit PCM. With the
512-voice project configuration, the exact worst-case mix range is
`-16,777,216..16,776,704`, so a signed 25-bit sample preserves the mix without
loss. The look-ahead storage and spatial effects therefore use signed 25-bit
channels. Gain multiplication widens explicitly before the only final PCM16
rounding and saturation.

Compressor parameters use the dedicated command stream rather than the register
window. One four-word global compressor action replaces enable, threshold,
ratio slope, attack, and release fields atomically before a render frame. A
separate global action updates master volume. Master gain is applied after the
compressor gain in the wide datapath, before final PCM16 saturation and the
output FIFO.

The common read-only status window exposes coherent current detector peak,
target and applied gain reduction, delay prime state, maxima, input/output and
compressed-frame counts, and final channel-saturation count. Maxima and 32-bit
saturating counters clear with core reset. These diagnostics use only registers,
comparators, and carry-chain incrementers; they add no sample RAM or multiplier.

## Board Boundary

Reusable board-facing RTL under `fpga/common/rtl` provides:

- SPI register and dedicated command-stream transport;
- common status and platform register routing;
- sample-clock generation;
- held PCM output and line-memory adaptation;
- output FIFO and I2S serialization.

The Smart Artix implementation additionally owns native SD loading, DDR3
arbitration, MIG integration, DDR debug access, clocking, and constraints.

The RP2040 board boundary owns USB device enumeration, MIDI policy, MSF2
metadata, voice allocation, command serialization, and I2S-to-USB capture. The
FPGA remains the SPI target and I2S source. Both links use 3.3 V signaling and a
verified common ground.

## Next Hardware Work

The generic command/control and render architecture is complete. The current
Smart Artix top fits and closes the constrained internal 100 MHz domain after
routing. Board work now centers on schematic-verified non-DDR pins, external
SPI/I2S delay constraints, long memory-stall/full-polyphony stress, physical
audio validation, and hardware qualification of the SD/DDR path. The current
resource and timing baseline and the remaining narrow path clusters are recorded
in `../verification/vivado_synthesis_timing.md`.

Voice observability should grow through bounded snapshot or trace apertures
rather than a writable per-voice register window.
