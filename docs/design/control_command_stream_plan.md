# Timestamped Control Command Stream Plan

This document records the proposed next-generation control plane. It is a
planning document, not the current hardware contract. The goal is to replace the
normal per-voice register-write control path with a timestamped command stream
that is robust to real SPI latency and keeps Note On, envelope, runtime gain,
pitch, and filter changes coherent at the renderer snapshot boundary.

## Goals

- Keep MIDI, SF2, voice allocation, modulators, timecents, and policy in host
  software.
- Make FPGA control changes deterministic in sample time.
- Ensure a voice never becomes audible before its envelope initial state and
  runtime controls are installed.
- Move runtime gain, phase increment, filter, release, stop, and envelope changes
  under one timestamped protocol.
- Preserve renderer timing: the audio pipeline must not wait for SPI or host
  command delivery.
- Keep register access for status, debug, and bring-up fallback, but remove it
  from the normal render-control path.

## Non-Goals

- FPGA voice allocation.
- FPGA SoundFont parsing, timecent exponentiation, or modulator evaluation.
- FPGA command sorting.
- A single large Note On command that writes every state field atomically.
- Renderer stalls while waiting for a command FIFO.

## Target Architecture

```text
Host/C++
  MIDI/SF2 policy, voice allocation, controller state, modulation
  -> timestamp block command stream

SPI bridge
  -> control_cmd_fifo
  -> control_cmd_parser
  -> prepare writer and timed event scheduler
  -> voice/config/runtime/envelope/filter stores
  -> renderer snapshot
```

The command processor owns the main write path into voice state. The renderer
continues to read stable active/runtime/envelope state and never observes a
partially prepared Note On.

## Voice Lifecycle

Separate "configuration is ready" from "voice is audible":

```text
staging[voice]       software/command-prepared region and static fields
prepared[voice]      copied configuration ready for a future enable
audible[voice]       renderer includes this voice in the scan
active_seq[voice]    generation token for stale-command rejection
```

`VOICE_ENABLE_AT` is the only normal command that makes a prepared voice audible.
It must be timestamped and executed at the same voice snapshot boundary as the
initial envelope and runtime controls.

## Command Word Format

Use a 32-bit word stream. A timestamp block supplies a time for subsequent
commands until the next timestamp command.

```text
Header word:
  [31:24] opcode
  [23:16] voice
  [15:8]  seq
  [7:0]   argc_words

Payload:
  argc_words 32-bit words
```

Special timestamp commands:

```text
TIME_ABS
  argc = 1
  payload0 = timestamp[31:0]

TIME_DELTA
  argc = 1
  payload0 = delta_samples[31:0]
```

All following commands inherit `block_time` until the next `TIME_ABS` or
`TIME_DELTA`.

## Command Classes

Commands have one of three execution classes:

| Class | Meaning |
| --- | --- |
| `PREPARE` | May execute before `block_time`; writes staging/prepared state and does not affect audio. |
| `TIMED` | Must become visible at `block_time`, aligned to the target voice snapshot. |
| `IMMEDIATE` | Debug, reset, and status actions that are not part of musical timing. |

The parser may consume and execute `PREPARE` commands early. `TIMED` commands are
queued or scheduled so they apply at `runtime_snapshot_prepare` for the matching
voice.

## Initial Command Set

```text
TIME_ABS
TIME_DELTA

VOICE_BEGIN          clears staging for voice, records seq
VOICE_REGION0        payload0=base_l, payload1=base_r
VOICE_REGION1        payload0=length_l, payload1=length_r
VOICE_LOOP0          payload0=loop_start_l, payload1=loop_start_r
VOICE_LOOP1          payload0=loop_end_l, payload1=loop_end_r
VOICE_PLAYBACK       payload0=phase_inc, payload1=phase_init
VOICE_MIX            payload0={gain_r,gain_l}, payload1=initial_envelope
VOICE_FLAGS          payload0=stereo/loop_mode/valid flags
VOICE_FILTER0        payload0={b1,b0}, payload1={a1,b2}
VOICE_FILTER1        payload0=a2, payload1=filter_enable
VOICE_PREPARE        copy staging to prepared, audible remains false

VOICE_ENABLE_AT      timed audible=1, clears released, installs active seq
VOICE_DISABLE_AT     timed audible=0

RUNTIME_GAIN_AT      timed payload0={gain_r,gain_l}
RUNTIME_PHASE_AT     timed payload0=phase_inc
RUNTIME_FILTER0_AT   timed payload0={b1,b0}, payload1={a1,b2}
RUNTIME_FILTER1_AT   timed payload0=a2, payload1=filter_enable

ENV_SET_AT           timed payload0=value_q15
ENV_ATTACK_AT        timed payload0=target_q15, payload1=duration_samples[23:0]
ENV_DECAY_CB_AT      timed payload0={target_cb,start_cb}, payload1=duration_samples[23:0]
ENV_RELEASE_CB_AT    timed payload0=start_cb, payload1=duration_samples[23:0]
RELEASE_FLAG_AT      timed set loop-until-release flag
STOP_VOICE_AT        timed envelope=0 and audible=0
```

This can be compressed later, but the first version should favor explicit
commands and simple RTL decoding.

## Note On Sequence

Host chooses `voice` and increments `seq` before emitting commands.

```text
TIME_ABS T_prepare
VOICE_BEGIN voice, seq
VOICE_REGION0
VOICE_REGION1
VOICE_LOOP0
VOICE_LOOP1
VOICE_PLAYBACK
VOICE_MIX
VOICE_FLAGS
VOICE_FILTER0
VOICE_FILTER1
VOICE_PREPARE

TIME_ABS T_note
ENV_SET_AT 0
ENV_ATTACK_AT target, duration              if delay == 0 and attack is needed
RUNTIME_GAIN_AT initial_runtime_gain        if not already in prepared state
RUNTIME_PHASE_AT initial_phase_inc          if not already in prepared state
VOICE_ENABLE_AT enable=1

TIME_ABS T_note + delay
ENV_ATTACK_AT target, duration              if delay > 0

TIME_ABS T_note + delay + attack + hold
ENV_DECAY_CB_AT start_cb, sustain_cb, duration
```

For the first audible sample, commands at `T_note` must be ordered so envelope
and runtime state are installed before `VOICE_ENABLE_AT`.

## Note Off Sequence

```text
TIME_ABS T_off
RELEASE_FLAG_AT
ENV_RELEASE_CB_AT start_cb, duration

TIME_ABS T_off + release_duration
STOP_VOICE_AT
```

Late release/stop commands should execute immediately and set a diagnostic flag.

## Runtime Control Updates

All runtime changes that are currently direct register writes should move into
the command stream:

| Source | Command |
| --- | --- |
| CC volume/expression/pan | `RUNTIME_GAIN_AT` |
| Tremolo | `RUNTIME_GAIN_AT` |
| Pitch bend | `RUNTIME_PHASE_AT` |
| Vibrato | `RUNTIME_PHASE_AT` |
| Modulation envelope to pitch | `RUNTIME_PHASE_AT` |
| Filter cutoff/resonance/modulation | `RUNTIME_FILTER*_AT` |

This makes controller, LFO, modulation-envelope, and envelope updates share one
timestamp model.

## Snapshot-Time Atomicity

Timed per-voice commands must be applied at:

```text
runtime_snapshot_prepare && runtime_snapshot_voice == command.voice
```

The event engine must process same-voice, same-timestamp commands in FIFO order
before the renderer snapshots that voice for `START_VOICE`.

Required Note On ordering:

```text
ENV_SET_AT 0
optional ENV_ATTACK_AT
RUNTIME_GAIN_AT
RUNTIME_PHASE_AT
VOICE_ENABLE_AT
```

`VOICE_ENABLE_AT` must be last for the same voice/timestamp so the first audible
sample cannot observe missing envelope or stale runtime state.

## SPI Latency Model

The renderer must not wait for SPI. Host software provides a future timestamp:

```text
T_note = CMD_TIME + safety_offset_samples
```

`safety_offset_samples` must cover:

- SPI burst time for command words.
- Parser and prepare command execution.
- Any `VOICE_PREPARE` copying latency.
- At least one renderer voice-scan margin.

At 48 kHz, 1 ms is 48 samples and 5 ms is 240 samples. Simulation may use zero
offset; board software should use a positive offset and monitor late diagnostics.

## Late Command Policy

Recommended defaults:

| Command | Late Behavior |
| --- | --- |
| `VOICE_ENABLE_AT` | Drop the Note On and set `dropped_note`/`late_enable`. |
| `RUNTIME_*_AT` | Execute immediately and set `late`. |
| `ENV_*_AT` | Execute immediately if `seq` is valid; set `late`. |
| `RELEASE_FLAG_AT` | Execute immediately; set `late`. |
| `STOP_VOICE_AT` | Execute immediately; set `late`. |

Dropping late Note On is preferable to starting a note on the wrong musical beat
or with stale state.

## Generation Tokens

Each voice has an 8-bit generation token:

```text
prepared_seq[voice]
active_seq[voice]
```

Rules:

- Host increments `seq` every time it allocates or steals a voice.
- `VOICE_BEGIN` records the new staging `seq`.
- `VOICE_ENABLE_AT` installs `active_seq`.
- Timed commands must match the expected prepared or active sequence.
- Mismatches are dropped and set `stale_seq`.

This prevents old release, stop, runtime, or envelope commands from affecting a
new note that reused the same voice id.

## FIFO And Scheduler

Suggested first implementation:

```text
control_cmd_fifo: 32-bit wide, depth 1024
timed_event_fifo: compact per-voice timed events, depth 128 or 256
```

Expected resource order:

- `control_cmd_fifo`: about 2 BRAM18 at 1024 words.
- `timed_event_fifo`: about 1 to 2 BRAM18 depending on event width and depth.
- Sequence store: 256 * 8 bits, distributed RAM or small BRAM.
- Parser/decoder FSM: hundreds to low-thousands of LUTs depending on diagnostics
  and arbitration.

Avoid sorting in FPGA. Host must emit timestamp blocks in ascending order and,
within a timestamp, preferably voices in ascending order.

## Write Arbitration

Command writes must not block renderer reads. If a write RAM port conflicts,
stall the command decoder and report max stall/late diagnostics.

Priority guideline:

```text
1. reset
2. renderer snapshot-timed state transitions
3. command decoder prepare/runtime writes
4. legacy/debug bus writes
```

The decoder may stall. The renderer should not.

## Register Map Direction

The main control surface should shrink toward:

```text
VERSION
STATUS
CMD_TIME
CMD_FIFO_DATA
CMD_FIFO_STATUS
CMD_CONTROL
COMMON_EVENT_FLAGS
DEBUG_SELECT
DEBUG_READ_DATA
```

The current `VOICE.*` and `EVENT_FIFO_DATA*` write paths may be retained under a
legacy/debug build option during migration, but the normal render path should use
only the command FIFO.

## Diagnostics

Expose sticky flags and counters for:

```text
cmd_fifo_overflow
cmd_late
cmd_late_enable
cmd_dropped_note
cmd_order_error
cmd_stale_seq
cmd_bad_len
cmd_unknown_opcode
cmd_prepare_stall
cmd_max_prepare_stall
timed_event_fifo_full
```

Render diagnostics JSON should include command write counts, runtime register
write counts, late counts, stale drops, and dropped notes.

## C++ Harness Plan

Add:

```cpp
class ControlCommandSink {
 public:
  virtual ~ControlCommandSink() = default;
  virtual void push_command_word(uint32_t word) = 0;
};

class CommandStreamBuilder {
  void time_abs(uint32_t timestamp);
  void voice_begin(int voice, uint8_t seq);
  void voice_region(...);
  void voice_prepare(...);
  void env_set_at(...);
  void runtime_gain_at(...);
  void voice_enable_at(...);
};
```

`McuModel` should gain a command-stream mode that emits command words instead of
legacy direct register writes.

Suggested modes:

```text
--control-commands
--legacy-register-control
--sample-accurate-envelope
```

Reference rendering should consume the same command stream through a C++ command
decoder. That makes the reference and FPGA share the same control protocol.

## Verification Plan

1. C++ builder tests
   - Note On command order.
   - Note Off release/stop order.
   - Runtime gain/phase/filter command emission.
   - Sequence increment on voice reuse.
   - 24-bit duration clamp.

2. RTL parser tests
   - `TIME_ABS` and `TIME_DELTA`.
   - Header payload count.
   - Unknown opcode and bad length flags.
   - FIFO overflow.

3. RTL prepare tests
   - `VOICE_BEGIN` clears staging.
   - `VOICE_*` writes staging.
   - `VOICE_PREPARE` copies to prepared while audible remains false.

4. RTL timed engine tests
   - `ENV_SET_AT` + `VOICE_ENABLE_AT` same timestamp gives correct first sample.
   - `RUNTIME_GAIN_AT` + enable same timestamp gives correct first sample.
   - Release and stop apply at timestamp.
   - Stale seq commands drop.
   - Late enable drops note.
   - Same timestamp order errors are detected.

5. Core tests
   - Full command Note On renders exact first sample.
   - Runtime gain/phase/filter commands affect exact expected samples.
   - Normal Note On uses no legacy voice register writes.

6. Render harness tests
   - `--control-commands` reference vs legacy sample-accurate output.
   - Long 100s decay is not truncated.
   - Diagnostics show runtime register writes near zero.

## Migration Plan

1. Define command opcodes, docs, and C++ builder tests.
2. Add `control_cmd_fifo` and parser for `TIME_*`, `ENV_*`, and
   `VOICE_ENABLE_AT`.
3. Use command path to fix Note On first-sample envelope synchronization.
4. Add `VOICE_*` prepare commands and move Note On config out of direct register
   commits.
5. Move Note Off release/stop to commands.
6. Move runtime gain/phase/filter to commands.
7. Add C++ reference command decoder and make `render-reference
   --control-commands` use it.
8. Deprecate or remove legacy event FIFO and per-voice write path for normal
   rendering.

## Final Shape

```text
Host:
  fully scheduled primitive command stream

FPGA:
  deterministic command application
  timestamped audible enable/runtime/env changes
  renderer sees coherent state at each voice snapshot

Registers:
  FIFO ingress, status, diagnostics, debug/readback
```

This is a breaking change to the current register-control model, but it directly
addresses the real hardware race where a voice can become audible before its
envelope initial state arrives.
