# MIDI Panic And Emergency Silence Backlog

This document tracks the gap between the current host-expanded voice shutdown
and a bounded, reliable emergency-silence path. It is a backlog, not a current
command or RTL contract. Current behavior remains defined by
[`../command_stream.md`](../command_stream.md) and
[`../host/host_control.md`](../host/host_control.md).

Status reviewed against MIDI 1.0 Detailed Specification 4.2.1, the real-time
MIDI host, both MCU policies, the command scheduler, and production RTL on
2026-08-03.

## Terminology And Required MIDI Semantics

"MIDI Panic" is an operator term rather than one MIDI 1.0 message. The
relevant standardized operations are:

- CC120 `All Sound Off` silences all notes currently sounding on the receiving
  MIDI channel. Voices are turned off and their volume envelopes are set to
  zero as soon as possible.
- CC123 `All Notes Off` behaves as note release, not an abrupt kill. Sustain
  and sostenuto remain authoritative until their pedals are released.
- CC124 through CC127 also perform the All Notes Off function in addition to
  their channel-mode meaning.
- CC121 `Reset All Controllers` restores controller, pitch-bend, and pressure
  state. It is not a substitute for All Sound Off.
- System Reset `0xff`, when supported, includes turning voices off, resetting
  controllers, stopping playback, clearing running status, and restoring the
  receiver's power-up state. It is broader than panic and must not be emitted
  automatically.

The local reference is
[`../reference/midi-1.0-detailed-specification-v4.2.1.pdf`](../reference/midi-1.0-detailed-specification-v4.2.1.pdf),
especially Channel Mode Messages pages 24-25, System Reset, and Appendix A-5.

## Current Baseline

| Operation | Runtime-parsed SF2 policy | Compiled MCU asset policy | RTL operation |
| --- | --- | --- | --- |
| CC120 All Sound Off | Implemented per channel | Implemented per channel | Expanded into generation-matched `VOICE_STOP` commands |
| CC123 All Notes Off | Implemented per channel with pedal deferral | Not implemented | Expanded into `VOICE_RELEASE` when applicable |
| CC124-127 mode messages | Perform All Notes Off; mode state is not modeled | Not implemented | No mode or channel semantics |
| CC121 Reset All Controllers | Implemented per channel | Not implemented | Reflected through later per-voice updates only |
| System Reset `0xff` | Not decoded as a host control event | Not decoded | No operation |
| Global emergency silence | Host may send CC120 over all 16 channels | Shutdown loops over all 16 channels | No global or atomic operation |

The real-time host gives note-off and CC120/CC123/CC124-127 events lifecycle
queue treatment. At normal shutdown it stops MIDI input, expands CC120 over all
16 channels, waits up to two seconds for the command scheduler to drain, and
then shuts the scheduler down.

Production RTL understands only individual voice IDs and generations. It does
not store MIDI channel ownership. `VOICE_STOP` immediately clears one matching
voice's active state; `VOICE_RELEASE` starts one matching voice's envelope
release. This division is intentional: MIDI routing, pedals, and channel modes
belong to the MCU policy rather than the renderer.

SPI `0xa6` FLUSH is not panic. It clears unpublished bridge staging, the
command FIFO, and parser state while preserving active voices, accepted state
actions, audio/effect state, and diagnostics. That contract must remain
unchanged.

## Open Defects And Risks

### PANIC-001: No Bounded Global RTL Silence

Current CC120 cost scales with the number of active voices. Up to 512
generation-matched STOP commands may span multiple 63-word SPI transactions
and execute serially. Silence latency therefore depends on scheduler backlog,
USB/SPI latency, renderer control availability, and active polyphony.

There is no RTL operation that makes all voices inaudible at one defined frame
boundary. Reset is not an acceptable run-time substitute.

### PANIC-002: Queued Starts Can Survive A Host Panic

The scheduler prioritizes lifecycle commands but keeps them FIFO-ordered.
CC120 invalidates replaceable updates for each stopped voice, but it does not
atomically discard already queued START, RELEASE, or STOP commands. The FPGA
may also contain staged or FIFO-resident START commands. A voice can therefore
start after an operator has requested panic unless input, host queues, bridge
staging, the command FIFO, and active state are coordinated.

### PANIC-003: MCU Policies Are Not MIDI-Equivalent

The runtime-parsed SF2 policy implements CC120, CC121, CC123, and the All Notes
Off aspect of CC124-127. The compiled MCU asset policy implements only CC120
among those messages. A MIDI file or live input can therefore behave
differently when `--mcu-asset` is selected.

The compiled policy also requires focused tests proving that CC120 stops
active, sustain-held, and released voices on only the addressed channel.

### PANIC-004: System Reset Policy Is Undefined

The live byte decoder accepts channel voice messages but does not surface MIDI
System Reset `0xff`. The project must explicitly choose either to ignore it, as
permitted for devices that do not use system real-time messages, or implement
the complete reset behavior. It must not be treated as an alias for CC120
without documenting the omitted reset semantics.

### PANIC-005: Effect And Output Tail Policy Is Undefined

Stopping all oscillator voices does not necessarily silence samples already in
the audio FIFO, compressor lookahead, chorus history, or reverb delay lines.
The MIDI specification allows All Sound Off to be used to clear audio effects,
but channel-scoped CC120 cannot selectively remove one channel from shared
global effect history. The project needs two explicit policies:

- standards-facing CC120: stop the addressed channel's voices without
  unexpectedly destroying other channels' shared effect tail;
- operator emergency panic: guarantee bounded silence, which may clear shared
  effect history and buffered output.

## Proposed Ownership And Dependency Order

Keep MIDI semantics in the host. Do not add MIDI channels, sustain state, or
controller parsing to each RTL voice merely to support panic.

1. Bring `McuSf2AssetRuntime` to semantic parity for CC121, CC123, and the All
   Notes Off aspect of CC124-127, including sustain behavior.
2. Add a scheduler panic API that first blocks new Note On submission and
   atomically abandons unsent host commands with explicit diagnostics.
3. Choose and document an out-of-band FPGA emergency operation. A normal A5
   opcode alone is insufficient because it remains ordered behind pending
   commands. Do not overload A6 FLUSH with voice-state changes.
4. Make the emergency operation cancel unpublished bridge staging and command
   FIFO contents, prevent a pending START from becoming visible, and force
   bounded global silence independent of the active-voice count.
5. Define whether emergency silence clears the output FIFO, compressor
   lookahead, chorus, and reverb. Preserve the narrower CC120 behavior.
6. Decide whether MIDI System Reset is ignored or implemented completely.
7. Add operator entry points only after host queue cancellation and RTL
   acknowledgement are both observable.

An RTL implementation may use a global kill epoch plus background state-RAM
invalidation, or a bounded state sweep combined with an immediate output mute.
The selected design must prove that stale state cannot reappear after the mute
is released.

## Acceptance Gates

- CC120 stops all active, sustain-held, and released voices on only its MIDI
  channel in both MCU policies; unrelated channels continue.
- CC123 and CC124-127 enter or defer Release according to sustain/sostenuto and
  never perform an abrupt STOP solely because All Notes Off was received.
- CC121 restores documented controller defaults and releases pedal-deferred
  voices consistently in both MCU policies.
- A panic request cannot be dropped as replaceable traffic or delayed behind
  an unbounded host lifecycle queue.
- Once panic is accepted, no command queued before it can start or reactivate a
  voice afterward.
- Global audible output reaches zero within a documented number of audio
  frames independent of whether 1 or 512 voices are active.
- Panic acknowledgement is software-readable, and timeout/failure leaves the
  host in a stopped state rather than resuming Note On traffic.
- Normal CC120 does not clear unrelated-channel voices or shared effects unless
  that behavior is explicitly selected and documented.
- A6 FLUSH tests continue to prove that FLUSH preserves active voice and effect
  state.
- Focused C++ tests cover both MCU policies and scheduler cancellation;
  self-checking RTL tests cover pending START cancellation, all-active-state
  invalidation, effect/output policy, reset, and backpressure.
- Hardware qualification measures panic-to-silence latency at maximum
  polyphony and with host, bridge, command FIFO, renderer, and output buffers
  deliberately occupied.

