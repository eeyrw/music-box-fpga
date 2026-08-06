# MIDI Panic And Emergency Silence Backlog

This document tracks the gap between the current host-expanded voice shutdown
and a bounded, reliable emergency-silence path. It is a backlog, not a current
command or RTL contract. Current behavior remains defined by
[`../command_stream.md`](../command_stream.md) and
[`../host/host_control.md`](../host/host_control.md).

Status reviewed against MIDI 1.0 Detailed Specification 4.2.1, the real-time
MIDI host, both MCU policies, the command scheduler, and production RTL on
2026-08-06.

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
| CC123 All Notes Off | Implemented per channel with pedal deferral | Implemented per channel with pedal deferral | Expanded into `VOICE_RELEASE` when applicable |
| CC124-127 mode messages | Perform All Notes Off; mode state is not modeled | Perform All Notes Off; mode state is not modeled | No mode or channel semantics |
| CC121 Reset All Controllers | Implemented per channel | Implemented per channel | Reflected through later per-voice updates only |
| System Reset `0xff` | Not decoded as a host control event | Stops voices and resets channel policy | Expanded STOPs; no atomic global operation |
| Global emergency silence | Host may send CC120 over all 16 channels | Shutdown loops over all 16 channels | No global or atomic operation |

The RP2040 UART `a` command now expands immediate STOPs across the dense set of
voices owned by the current MCU runtime. It is useful for current-session
silence, but remains generation-matched and therefore cannot stop a voice whose
generation was lost in an earlier MCU reset.

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

### PANIC-003: MCU Policy Equivalence Requires Ongoing Regression

Both policies implement CC120, CC121, CC123, and the All Notes Off aspect of
CC124-127. The compiled firmware also has focused pedal, controller reset,
RPN/NRPN, and System Reset tests. Future channel-mode changes must continue to
update both policies and their exact command regressions together.

### PANIC-004: System Reset Is Not Atomic Panic

The RP2040 USB-MIDI decoder handles System Reset `0xff` by stopping every owned
voice and restoring controller, bank, program, RPN, and NRPN defaults. This is a
standards-facing reset policy, but it still expands to per-voice commands and
therefore does not solve the bounded global panic requirement.

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

### PANIC-006: MCU Reset Loses Voice Ownership

The FPGA preserves active voices across SPI `0xa6` FLUSH, while the RP2040
runtime initializes a new generation table after reset. The command protocol
requires an exact generation match and exposes no readable per-voice generation
table. Consequently, neither a 512-slot MCU scan nor current-session UART `a`
can address voices accepted before the reset.

The RP2040 now detects an FPGA-only cold restart through low-rate platform
status monitoring, discards MIDI during SD loading, and creates a fresh local
voice session after the FPGA reports the expected loaded asset. This handles
the case where FPGA reset already erased the render state. It does not solve an
MCU-only reset, firmware update, watchdog reset, or missing transaction
acknowledgement while the FPGA preserves active voices. The bounded global RTL
operation proposed below remains the required recovery mechanism.

The two counters have different fault semantics. A command-error increase
enters quarantine. Two consecutive mailbox failures instead mark the FPGA
session offline and begin recoverable loading-state monitoring. A
stale-generation increase is observable but nonfatal: the FPGA has already
prevented an old command from modifying the current voice. Treating that
protected rejection as a sink failure caused a 2026-08-06 MIDI stoppage while
USB capture remained alive and was removed. Note On also no longer sends
redundant control updates immediately behind START, avoiding an unnecessary
not-yet-installed race. Post-fix hardware tests still observed stale rejection
on per-layer RELEASE, including after a short key press, so FPGA-side lifecycle
attribution remains open even though it no longer causes global MIDI
quarantine.

### PANIC-007: No Explicit Render-Session Reset

The FPGA has no software-requested operation that establishes a completely new
render session without a board reset. A future register or out-of-band command
must atomically block command acceptance, discard bridge/parser/FIFO contents,
invalidate every voice generation, reset the renderer and scheduler, clear
effect history and the audio FIFO according to an explicit policy, and then
acknowledge completion with a new readable session epoch.

This is broader than MIDI CC120 and different from emergency output mute. It is
also different from SPI `0xa6` FLUSH, whose state-preserving contract must not
change. The MCU must use the acknowledged render-session reset before rebuilding
its local ownership table after an MCU-only recovery. A reset request cannot be
considered complete merely because it was written into the normal ordered
command FIFO.

## Proposed Ownership And Dependency Order

Keep MIDI semantics in the host. Do not add MIDI channels, sustain state, or
controller parsing to each RTL voice merely to support panic.

1. Keep the two MCU policies in semantic parity for controller and channel-mode
   behavior, including combined sustain/sostenuto sequences.
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
6. Keep MIDI System Reset distinct from the future bounded emergency operation.
7. Add operator entry points only after host queue cancellation and RTL
   acknowledgement are both observable.
8. Add the explicit render-session reset described above, with a monotonically
   changing readable epoch so MCU/FPGA ownership can be reconciled after either
   side restarts.

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
- Render-session reset acknowledgement includes a changed epoch; after it, no
  voice, queued command, scheduler job, effect sample, or audio-FIFO sample from
  the preceding epoch can become observable.
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
