# MIDI Panic And Emergency Silence Backlog

This document tracks the gap between the current host-expanded voice shutdown
and a bounded, reliable emergency-silence path. It is a backlog, not a current
command or RTL contract. Current behavior remains defined by
[`../command_stream.md`](../command_stream.md) and
[`../host/host_control.md`](../host/host_control.md).

Status reviewed against MIDI 1.0 Detailed Specification 4.2.1, the real-time
MIDI host, both MCU policies, the command scheduler, and production RTL on
2026-08-07. Interface version 16 implements the FPGA/RP2040 render-session reset
path and has passed functional board qualification. Desktop-host integration,
maximum-load latency measurement, and audible-pop qualification remain open.

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
| Global emergency silence | Host may send CC120 over all 16 channels | UART `a` cancels MCU queues and performs acknowledged `0xa7` reset | Atomic render/audio session reset |

The RP2040 UART `a` command and the Music Box reset-session SysEx invoke the
out-of-band `0xa7` operation. They do not expand generation-matched STOPs and
therefore also clear voices whose ownership was lost across an MCU restart.

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

### PANIC-001: Bounded Global RTL Silence Implemented; Hardware Timing Open

Current CC120 cost scales with the number of active voices. Up to 512
generation-matched STOP commands may span multiple 63-word SPI transactions
and execute serially. Silence latency therefore depends on scheduler backlog,
USB/SPI latency, renderer control availability, and active polyphony.

Interface version 16 adds the dedicated out-of-band `0xa7` operation. It asserts
reset on the complete render/audio path independent of voice count, then keeps
that reset asserted while discarding any pre-reset ordered DDR responses before
acknowledgement. Physical panic-to-I2S silence latency still requires
maximum-load board qualification.

### PANIC-002: MCU Queued Starts Cancelled; Desktop Host Work Open

The RP2040 UART panic path and fixed System Exclusive command
`f0 7d 4d 42 01 01 f7` block/discard MIDI ingress, abandon the unpublished
command batch, wait for the finite DMA queue to drain, then issue `0xa7`.
Bridge staging and the FPGA command FIFO/parser are cancelled by that request.
The desktop scheduler still needs equivalent producer blocking and queue
cancellation before it exposes a panic entry point.

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

### PANIC-005: Effect And Output Tail Policy Implemented; Pop Testing Open

Stopping all oscillator voices does not necessarily silence samples already in
the audio FIFO, compressor lookahead, chorus history, or reverb delay lines.
The MIDI specification allows All Sound Off to be used to clear audio effects,
but channel-scoped CC120 cannot selectively remove one channel from shared
global effect history. The project needs two explicit policies:

- standards-facing CC120: stop the addressed channel's voices without
  unexpectedly destroying other channels' shared effect tail;
- operator emergency panic: guarantee bounded silence, which may clear shared
  effect history and buffered output.

Interface version 16 implements that split: CC120 retains the channel-scoped
policy, while `0xa7` resets the effects, compressor, output FIFO, and I2S path.
Whether the abrupt transition produces an audible pop remains part of physical
panic-to-silence qualification; this revision intentionally does not add a
release or output ramp.

### PANIC-006: MCU Reset Voice Ownership Recovery Implemented

SPI `0xa6` still preserves active FPGA voices and their generations. Startup,
watchdog recovery, and FPGA reconnect now use `0xa7` plus the changing session
epoch before rebuilding the MCU generation table. An MCU cannot resume MIDI
after a reset timeout, so an unacknowledged old session is not silently reused.

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

### PANIC-007: Render-Session Reset Implemented In FPGA And RP2040

SPI `0xa7` is a CRC-protected out-of-band request. It blocks command acceptance,
discards bridge/parser/FIFO contents, invalidates every voice through a resettable
valid bitmap, and synchronously resets the renderer, scheduler, memory response
holding state, effects, compressor, audio FIFO, and I2S serializer. The reset
controller increments `RENDER_SESSION_EPOCH` only after applying the reset.

The RP2040 reads the old epoch, sends `0xa7`, and remains stopped until it reads
a changed epoch. Startup, reconnect recovery, and UART `a` use this path before
rebuilding local ownership. Failure or timeout leaves MIDI ingress blocked for
operator panic. SPI `0xa6` remains state-preserving.

### PANIC-008: Voice ID Versus Generation Needs A Contract Decision

A physical voice ID identifies one FPGA slot. The slot can serve only one
audible voice instance at a time, but it is reused for many successive note
lifetimes. Generation currently distinguishes those lifetimes: a runtime
command for an older occupant is rejected after a new START replaces the same
slot. This protects the new note from a late PITCH, GAIN, RELEASE, or STOP.

That protection is not automatically necessary merely because SPI and FPGA
execution are asynchronous. If all of the following invariants are proved,
voice ID alone is sufficient at the external command boundary during one MCU
session:

- exactly one owner serializes every lifecycle and parameter command;
- the MCU command batch, DMA queue, SPI bridge, command FIFO, parser, and state
  store preserve that order without retry or replay;
- slot reuse is ordered after every already-produced command for the previous
  occupant;
- a sliced or deferred MCU calculation validates that the slot still belongs
  to its captured note before it publishes a command;
- cancellation and transport recovery cannot reinsert an older command after
  a replacement START.

The RP2040 now captures voice generation in each sliced control job and skips a
slot if it was freed or reused before that slice executes. Core 1 is the sole
MSF2/SPI command producer, and the DMA transport is FIFO ordered. Those facts
make generation potentially redundant for correctly produced commands, but do
not yet prove every invariant above. Hardware has also observed nonzero stale
rejections on RELEASE. Until the rejected command is attributed to an exact
producer and state transition, removing FPGA generation validation would turn
an observable rejected command into a command that could affect the current
slot occupant.

Generation is also not a recovery protocol. It makes an MCU-only reset worse
if used without a session-reset operation: the new MCU cannot discover the old
generation and therefore cannot stop the preserved voice. Per-voice generation
readback could make reconciliation possible, but reading 512 mutable records is
expensive and races with renderer state changes unless accompanied by a frozen
snapshot. It is more mechanism than recovery requires.

The design decision must compare four explicit alternatives:

| Alternative | Normal stale-command protection | MCU-only recovery | Cost and risk |
| --- | --- | --- | --- |
| Keep current per-voice generation only | Yes | Impossible for unknown voices | Current incomplete behavior |
| Remove generation and rely on ordered single ownership | Only through proved producer/order invariants | A forced command by voice ID is possible | Simplest wire format, but an invariant violation can affect a reused note |
| Keep generation plus out-of-band session reset/epoch | Yes | Bounded and atomic | Selected and implemented in interface version 16 |
| Add readable per-voice state/generation snapshot | Yes | Reconciliation is possible | Largest interface and verification burden; snapshot atomicity is required |

An unconditional `FORCE_STOP voice_id` is a narrower temporary operation, but
512 such commands still have latency proportional to polyphony and can race a
queued START unless paired with queue cancellation. A single out-of-band
`RENDER_SESSION_RESET` is the selected recovery boundary. It retains
per-voice generation for normal commands while deliberately ignoring it during
whole-session invalidation.

Before deciding whether generation remains in the long-term command protocol:

1. Attribute every stale rejection with opcode, voice ID, requested generation,
   current generation/active state, and command sequence or session epoch.
2. Add self-checking tests that delay a parameter calculation across STOP and
   slot reuse, fill every transport queue, FLUSH a partial transaction, and
   recover each side independently.
3. Prove or disprove the single-owner FIFO invariants at every queue boundary.
4. Measure the RTL/state cost of generation validation separately from the
   session-reset design; do not remove it merely to simplify MCU cleanup.
5. Select the session reset and acknowledgement contract before changing normal
   voice-command semantics.

## Proposed Ownership And Dependency Order

Keep MIDI semantics in the host. Do not add MIDI channels, sustain state, or
controller parsing to each RTL voice merely to support panic.

1. Keep the two MCU policies in semantic parity for controller and channel-mode
   behavior, including combined sustain/sostenuto sequences.
2. Add a scheduler panic API that first blocks new Note On submission and
   atomically abandons unsent host commands with explicit diagnostics.
3. Maintain the implemented out-of-band FPGA emergency operation. A normal A5
   opcode alone is insufficient because it remains ordered behind pending
   commands. Do not overload A6 FLUSH with voice-state changes.
4. Make the emergency operation cancel unpublished bridge staging and command
   FIFO contents, prevent a pending START from becoming visible, and force
   bounded global silence independent of the active-voice count.
5. Define whether emergency silence clears the output FIFO, compressor
   lookahead, chorus, and reverb. Preserve the narrower CC120 behavior.
6. Keep MIDI System Reset distinct from the bounded emergency operation.
7. Add operator entry points only after host queue cancellation and RTL
   acknowledgement are both observable.
8. Extend the implemented render-session reset and monotonically changing epoch
   to desktop-host recovery without changing its FPGA contract.
9. Resolve PANIC-008 from attributed stale-command evidence and queue-ordering
   proofs; until then, retain generation on normal runtime commands and bypass
   it only in the whole-session reset operation.

The implemented RTL uses a resettable per-voice validity bitmap in front of the
state RAM. Reset invalidates all slots in one clock without resetting the BRAM
contents; every snapshot and generation check is gated by the bitmap, so stale
RAM state cannot reappear after reset is released.

## 2026-08-07 Hardware Qualification

The interface-version-16 image was implemented, written to the Smart Artix
configuration Flash, verified, and booted from Flash. The boot status reported
`DONE=1`, `DONE_PIN=1`, `EOS=1`, `CRC_ERROR=0`, and `IDCODE_ERROR=0`. The RP2040
then completed its production startup handshake with `VERSION=0x00100000`, the
expected SGM source size of 324,800,670 bytes, and no SPI, command-format, stale,
enqueue-timeout, underrun, sample-drop, or render-deadline errors.

A USB-MIDI test selected zero-based General MIDI program 48 (Strings Ensemble
1), held C4 without Note Off, and captured three separate UAC2 intervals:

| Interval | Overall peak | Overall RMS | Result |
| --- | ---: | ---: | --- |
| Sustained Strings before SysEx | -17.232910 dBFS | -27.782813 dBFS | Continuous nonzero audio |
| After `f0 7d 4d 42 01 01 f7` | `-inf` | `-inf` | Exact digital silence |
| New Strings Note On after reset | -17.427844 dBFS | -28.528334 dBFS | Normal audio resumed |

The first SysEx changed the session epoch from 13 to 14 and cleared the MCU
active-voice set. A final cleanup SysEx changed it to 15 and left active voices
at zero. The test also exposed that the short FPGA I2S reset can restart serial
bit phase without satisfying the MCU's 4 ms clock-loss detector. Firmware now
explicitly restarts its PIO/DMA frame synchronizer after startup or operator
session reset; the post-reset Note On above verifies recovery without full-scale
frame-misalignment data.

This establishes functional silence, acknowledgement, and post-reset recovery.
It does not establish a worst-case frame count from SysEx receipt to silence or
whether the abrupt FIFO/effect reset produces an audible pop.

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
