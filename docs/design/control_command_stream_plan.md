# Transactional Control And Continuous Render Plan

> Legacy architecture (2026-07-27): this document records the deleted
> command-word/prepared-state renderer and is not a current RTL contract. The
> remaining C++ reference model may still use parts of the command vocabulary.
> New RTL integration must target `block_voice_event_t`, the voice state store,
> and the voice-major block pipeline.

This document is retained as the old control-plane and audio-scheduling record.

## Ownership

The host owns MIDI and SF2 parsing, voice allocation, the modulation envelope,
LFOs, the modulator graph, and conversion of pitch, filter, and envelope timing
to fixed-point values. The FPGA owns prepared and active voice state, the SF2
volume envelope, continuous rendering, the PCM FIFO, and fixed-rate I2S output.

There are no command timestamps. A complete, valid command becomes eligible at
the next PCM frame whose rendering has not started. Audible latency is the
current PCM lead, normally about 48 samples or 1 ms at 48 kHz.

```text
host SF2/MIDI/modulators
  -> 32-bit command word FIFO
  -> parser and decoded action FIFO
  -> prepared/active voice state and volume envelope
  -> credit-driven renderer
  -> configurable-depth stereo PCM FIFO
  -> fixed-rate 48 kHz I2S
```

## Command Framing

Each command starts with one 32-bit header followed by exactly `payload_words`
32-bit words.

```text
header[31:24] opcode
header[23:16] voice
header[15:8]  seq
header[7:0]   payload_words
```

The parser does not emit an action until the complete command is present and
validated. Unknown opcodes, invalid voice ids, and incorrect payload lengths
increment `command_error_count`; their declared payload is consumed. A partial
command remains pending without changing voice state. `STREAM_FLUSH` discards a
pending partial command and all currently buffered command words, resets parser
framing, and does not modify voice state.

The command ingress applies backpressure. Hosts must not assume a word was
accepted unless the command FIFO reports space. The 1024-by-32 word queue is a
synchronous simple-dual-port block RAM with an output-valid cache. Its write
port accepts ingress independently while its read port prefetches the next word
on a pop, so a buffered command can be parsed at one word per system clock.
The first word after an empty interval has the normal synchronous RAM startup
latency; this does not change the ready/valid contract.

## SPI Transport

SPI command traffic uses a dedicated stream transaction. With chip select low,
the host sends opcode `0xa5` followed immediately by any whole number of 32-bit
command words, most-significant byte first:

```text
CS low -> 0xa5 -> word0 -> word1 -> ... -> wordN -> CS high
```

There is no register address between the opcode and data and no address or
opcode overhead between words. The host reads command FIFO free capacity before
the transaction and sends no more words than that capacity. If capacity is
exhausted during a transaction, the bridge sets the SPI error flag and discards
each word that cannot be accepted. Ending a transaction with a partial word
discards the partial word.

Register SPI transactions are used for status, diagnostics, asset loading, and
board control only.

The command-stream SCLK workload model, FIFO sizing rules, and separate
register-versus-stream timing recommendations are documented in
[`spi_command_stream_throughput.md`](spi_command_stream_throughput.md).

The current per-word overflow behavior and silent partial-final-word discard
are known correctness bugs, not acceptable DMA flow control. The required
packet-atomic replacement and acceptance criteria are tracked in
[`spi_transport_backlog.md`](spi_transport_backlog.md).

## Opcodes And Payloads

The command opcodes are:

| Value | Command | Payload words |
| --- | --- | ---: |
| `0x10` | `VOICE_DEFINE_MONO` | 11 |
| `0x11` | `VOICE_DEFINE_STEREO` | 15 |
| `0x12` | `VOICE_START` | 8 |
| `0x13` | `VOICE_ENV_UPDATE` | 1 to 7 |
| `0x14` | `VOICE_RELEASE` | 1 |
| `0x15` | `VOICE_STOP` | 0 |
| `0x16` | `VOICE_GAIN_PHASE` | 2 |
| `0x17` | `VOICE_FILTER` | 3 |
| `0x20` | `COMPRESSOR_CONFIG` | 4 |
| `0x21` | `MASTER_VOLUME` | 1 |
| `0x22` | `CHORUS_CONFIG` | 6 |
| `0x23` | `REVERB_CONFIG` | 9 |
| `0x24` | `EFFECT_CLEAR` | 1 |
| `0x7f` | `STREAM_FLUSH` | 0 |

All reserved bits must be zero. Samples and coefficients use the formats in
`docs/fixed_point.md`. Loop ends are exclusive.

`COMPRESSOR_CONFIG`, `MASTER_VOLUME`, `CHORUS_CONFIG`, `REVERB_CONFIG`, and
`EFFECT_CLEAR` are global actions. Their header `voice` and `seq` fields must
both be zero. They are applied with the same bounded action batch that precedes
a render frame.

### COMPRESSOR_CONFIG

```text
word 0  control: bit 0 enable, bits 16:1 ratio slope Q0.16, bits 31:17 zero
word 1  threshold attenuation, unsigned cB Q12.20
word 2  attack step, unsigned cB Q12.20 per frame
word 3  release step, unsigned cB Q12.20 per frame
```

The ratio slope is `1 - 1/ratio`: `0x0000` is 1:1, `0x8000` is
2:1, and `0xffff` approaches limiting. A zero attack or release step means an
immediate transition to the current target. Each command replaces the complete
compressor configuration atomically. Centibel fields must not exceed 1000 cB.

### MASTER_VOLUME

```text
word 0  signed nonnegative Q1.15 master gain in bits 15:0; bits 31:15 zero
```

`0x7fff` is the exact bypass setting and is the reset default. Master volume is
applied after compressor gain and before the only final PCM16 saturation.

### CHORUS_CONFIG

```text
word 0  {feedback_q1_15, 15'b0, enable}
word 1  {8'b0, base_delay_q16_8}
word 2  {8'b0, depth_q16_8}
word 3  lfo_phase_inc_q0_32
word 4  {return_gain_q1_15, input_send_q1_15}
word 5  stereo_phase_offset_q0_32
```

The complete chorus configuration is replaced atomically. The two gains must
not exceed `0x7fff`; signed feedback must be in `-0x6000` through `0x6000`.
Delay values are validated again by the chorus against its physical history
capacity, with any clamp reported through effect diagnostics.

### REVERB_CONFIG

```text
word 0  {20'b0, pre_delay_frames[10:0], enable}
word 1  {16'b0, input_send_q1_15}
word 2  {16'b0, return_gain_q1_15}
word 3  {16'b0, damping_q1_15}
word 4  {16'b0, chorus_to_reverb_q1_15}
word 5  {feedback_gain_1_q1_15, feedback_gain_0_q1_15}
word 6  {feedback_gain_3_q1_15, feedback_gain_2_q1_15}
word 7  {feedback_gain_5_q1_15, feedback_gain_4_q1_15}
word 8  {feedback_gain_7_q1_15, feedback_gain_6_q1_15}
```

The complete reverb configuration is replaced atomically. Send, return,
damping, and chorus-to-reverb gains must not exceed `0x7fff`. Each feedback
gain must not exceed the stability limit `0x2d41`.

### EFFECT_CLEAR

```text
word 0  bits 1:0 clear mask; bit 0 chorus, bit 1 reverb; bits 31:2 zero
```

At least one mask bit must be set. The command emits a one-cycle clear pulse,
resets only the selected effect histories without clearing RAM contents, and
drops a frame currently in the spatial effect chain. Compressor state and its
look-ahead history are unchanged.

### VOICE_DEFINE_MONO

```text
word 0  base_addr_l
word 1  length_l
word 2  loop_start_l
word 3  loop_end_l
word 4  phase_init_q24_8
word 5  flags: [1:0] loop_mode, all other bits zero
word 6  filter: {b1_q2_14, b0_q2_14}
word 7  filter: {a1_q2_14, b2_q2_14}
word 8  filter: {15'b0, enable, a2_q2_14}
word 9  reserved, zero
word 10 reserved, zero
```

Mono duplicates the left stream before independent left and right gain. The two
reserved words keep DEFINE size fixed while leaving room for future mono storage
fields.

### VOICE_DEFINE_STEREO

```text
word 0  base_addr_l
word 1  base_addr_r
word 2  length_l
word 3  length_r
word 4  loop_start_l
word 5  loop_start_r
word 6  loop_end_l
word 7  loop_end_r
word 8  phase_init_q24_8
word 9  flags: [1:0] loop_mode, all other bits zero
word 10 filter: {b1_q2_14, b0_q2_14}
word 11 filter: {a1_q2_14, b2_q2_14}
word 12 filter: {15'b0, enable, a2_q2_14}
word 13 reserved, zero
word 14 reserved, zero
```

### VOICE_START

```text
word 0 {gain_r_q1_15, gain_l_q1_15}
word 1 runtime_phase_inc_q24_8
word 2 {8'b0, delay_samples[23:0]}
word 3 attack_step_q0_32
word 4 {8'b0, hold_samples[23:0]}
word 5 decay_step_cb_q12_20
word 6 sustain_cb_q12_20
word 7 release_step_cb_q12_20
```

`VOICE_START` is accepted only when `seq == prepared_seq[voice]`. It atomically
copies prepared configuration to active configuration, installs active seq,
gain, phase increment, and a fresh volume envelope, reloads phase from
`phase_init`, clears released state, and makes the voice audible. A mismatch is
consumed and increments `stale_seq_count`.

### VOICE_ENV_UPDATE

Word 0 is a field mask. Selected values follow in ascending mask-bit order.
`payload_words` must equal one plus the mask population count.

| Mask bit | Following value |
| ---: | --- |
| 0 | `delay_samples` in bits 23:0 |
| 1 | `attack_step_q0_32` |
| 2 | `hold_samples` in bits 23:0 |
| 3 | `decay_step_cb_q12_20` |
| 4 | `sustain_cb_q12_20` |
| 5 | `release_step_cb_q12_20` |

Bits 31:6 are zero. An empty mask is invalid. Future stages use replacement
values. A currently running Attack, Decay, or Release preserves its current
level and uses the new step on the next sample. Delay and Hold preserve elapsed
time and advance immediately if the new duration has already expired. A
Sustain target change moves continuously using the decay step.

### Runtime Actions

```text
VOICE_RELEASE word 0: release_step_cb_q12_20
VOICE_GAIN_PHASE word 0: {gain_r_q1_15, gain_l_q1_15}
                 word 1: phase_inc_q24_8
VOICE_FILTER word 0: {b1_q2_14, b0_q2_14}
             word 1: {a1_q2_14, b2_q2_14}
             word 2: {15'b0, enable, a2_q2_14}
```

`VOICE_RELEASE` atomically installs the supplied release step, sets released,
and enters Release from the current envelope level. `VOICE_STOP` immediately
clears audible state. Gain/phase and filter commands replace the complete named
runtime group in one action. Every runtime action must match `active_seq`; a
mismatch has no state effect and increments `stale_seq_count`.

## Prepared And Active State

Each of 256 voice slots has:

```text
prepared_config[voice]
prepared_seq[voice]
prepared_valid[voice]
active_config[voice]
active_seq[voice]
audible[voice]
runtime_gain[voice]
runtime_phase_inc[voice]
volume_envelope_parameter_and_state[voice]
```

DEFINE validates and writes only prepared state. It never changes an active
voice, including when redefining a slot that is still audible. START is the only
command that promotes prepared configuration and reloads phase. Runtime actions
never reload phase. STOP does not invalidate prepared state.

Packed voice and envelope records use synchronous inferred RAM. Reset clears
only valid/audible generation bitmaps and queue state; it must not loop over RAM
entries.

## Frame Boundary And Action Batching

Decoded actions enter a FIFO while rendering continues. A new frame may start
only after the renderer is idle and a bounded action batch has completed.

When idle, the controller snapshots:

```text
batch_count = min(action_fifo_level, 16)
```

It executes exactly those actions in FIFO order. Actions decoded after the
snapshot remain for the next frame. After at most 16 actions, the scheduler must
render one frame when it has PCM credit even if more actions are queued. This
prevents a continuous control stream from starving audio and gives every voice
in one renderer scan the same control boundary.

The limit is an audio-scheduling fairness bound, not a parser throughput limit.
If more than 16 actions are ready at one boundary, the first 16 affect that
frame, the next 16 affect the following frame, and so on. START therefore also
defines the voice envelope and phase origin at the frame where that START action
is applied. A layered MIDI note may intentionally start over several adjacent
frames when its command burst exceeds the bound.

The exact RTL/reference comparison mirrors this rule with a queue of complete
command vectors. The C++ comparison sink applies at most 16 vectors immediately
before each reference sample. A STREAM_FLUSH vector is applied in FIFO order and
then discards the remaining queued vectors, matching the transactional control
plane. The standalone `render-reference` flow remains an MCU-policy and sound
rendering tool and does not introduce this artificial FPGA scheduler queue.

The C++ command builder also mirrors the active START fields. It does not emit
an immediately following GAIN_PHASE or FILTER action when every corresponding
field is unchanged. This is command coalescing only: a changed gain, phase
increment, or filter configuration still emits a complete runtime action.

## Volume Envelope

The FPGA implements Delay, Attack, Hold, Decay, Sustain, and Release at one
update per rendered sample. Attack uses unsigned Q0.32 linear amplitude. Decay
and Release use Q12.20 centibel attenuation. Values at or above the documented
silence attenuation clamp to Q1.15 zero.

```text
Delay:   retain zero until elapsed reaches delay_samples
Attack:  add attack_step; clamp at full scale, then enter Hold
Hold:    retain full scale until elapsed reaches hold_samples
Decay:   increase attenuation by decay_step until sustain_cb
Sustain: retain sustain attenuation until Release
Release: increase attenuation by release_step until silence, then audible=0
```

A range-reduced `cb_to_q15` lookup converts Decay, Sustain, and Release state to
renderer gain. Releasing during Attack uses a leading-zero encoder plus fixed
exponent and normalized-mantissa tables for `q15_to_cb`, so Release begins within
`0.68 cB` of the current linear level without a divider or wide search. The
algorithms and error bounds are documented in
[`envelope_gain_conversion.md`](envelope_gain_conversion.md).
Zero-duration stages advance without adding an extra rendered sample. Step
values must retain non-zero progress for durations through 100 seconds at 48 kHz.

## PCM FIFO And Scheduler

The default parameters are:

```text
OUTPUT_FIFO_DEPTH = 64
TARGET_LEVEL      = 48
START_LEVEL       = 48
MAX_ACTION_BATCH  = 16
```

The RTL instantiation and exact-comparison C++ constant must remain equal.
Changing this value requires the 16+1 batching regression to be updated, an
exact real-song RTL/reference comparison, and evidence that the new worst-case
control work still meets the audio-frame deadline. Removing the bound is not a
valid optimization because a continuous command stream could then starve PCM
rendering.

`OUTPUT_FIFO_DEPTH`, `TARGET_LEVEL`, and `START_LEVEL` are elaboration
parameters. `START_LEVEL` defaults to `TARGET_LEVEL`; both must be within the
configured FIFO depth.

Exactly one renderer frame may be in flight. The scheduling equations are:

```text
render_inflight = renderer_busy or completed output waiting for FIFO ready
occupancy       = fifo_level + render_inflight
render_credit   = occupancy < TARGET_LEVEL
render_start    = core_idle and render_credit and control_batch_complete
```

The renderer output is ready/valid and retains a completed PCM frame until the
FIFO accepts it. Overflow/drop is not a normal backpressure mechanism.

After reset, I2S clocks run and data is zero. FIFO data is not offered to I2S
until the level first reaches exactly `START_LEVEL`; this sets
`playback_started`. Startup silence does not increment `underrun_count`. Once
started, every missing frame at an I2S consume boundary is a real underrun and
outputs zero. A consumption below `TARGET_LEVEL` immediately creates one render
credit. After a memory stall, the renderer runs continuously until occupancy
returns to `TARGET_LEVEL`.

## Counters And Diagnostics

The new status surface provides:

```text
render_sample_counter  accepted renderer outputs
played_sample_counter  I2S frame boundaries after playback_started
audio_lead             render_sample_counter - played_sample_counter
minimum_fifo_level     minimum post-start level observed at consume boundaries
render_inflight
playback_started
stale_seq_count
command_error_count
underrun_count
```

Counters saturate rather than wrap unless their register description explicitly
says otherwise. `render_sample_counter` is the command-effect timeline.
`played_sample_counter` is the audible timeline.

## Register Access

Register access is limited to global status, diagnostics, asset loading, and
explicit bring-up/debug functions. Voice operation uses the command stream.

## Verification Gates

Self-checking tests must cover exact `START_LEVEL` prefill, startup silence without
underrun, one-credit refill, memory-stall catch-up, true steady-state underrun,
DEFINE isolation, atomic START first-sample state, stale-seq rejection, all six
envelope stages and boundaries, Note Off from every pre-release stage,
continuous current-stage updates, 100-second steps, and 256-voice isolation.

The C++ reference and RTL must consume the same command stream and compare exact
integer PCM. SPI Note On and Note Off tests must verify the complete command
path.

RTL acceptance requires `make lint`, `make test`, generated-table consistency,
and a forced non-incremental Smart Artix implementation. The constrained
internal 100 MHz domain now closes post-route. Minimum FIFO level under long
memory stalls and external I/O validation remain board-level qualification
gates.

## Implementation Status

The following architecture is implemented. Each item has focused self-checking
coverage in the tree.

1. Freeze this command, state, batching, FIFO, and timing contract.
2. Establish the parameterized PCM FIFO and complete renderer ready/valid
   output boundary.
3. Add credit-driven continuous rendering, parameterized startup prefill, and
   the I2S startup gate.
4. Expose render/played counters, audio lead, FIFO minimum, inflight state, and
   playback-start state through the global status surface.
5. Connect the command word FIFO to the transactional parser and decoded action
   FIFO, including parser recovery and error counting.
6. Implement packed synchronous prepared configuration RAM, prepared/active seq
   state, atomic START promotion, and audible/generation bitmaps.
7. Implement packed volume-envelope parameter/state RAM, the six-stage engine,
   shared conversion pipelines, and exact fixed-point boundary behavior.
8. Implement every action executor and stale-seq path: DEFINE, START,
   ENV_UPDATE, RELEASE, STOP, GAIN_PHASE, FILTER, and STREAM_FLUSH.
9. Move the C++ command builder, reference renderer, DUT adapters, and MCU model
   to the command stream and exact FPGA envelope arithmetic.
10. Consolidate RTL, simulation sources, tests, and generated contracts around
    the transactional control plane and continuous renderer.
11. Synchronize the register map, fixed-point rules, system design, RTL map,
    host-control documentation, board documentation, and verification guide.

## Resume Checkpoint

Checkpoint date: 2026-07-24.

Completed and tested:

- This target-state protocol and scheduling contract.
- Parameterized `OUTPUT_FIFO_DEPTH`, `TARGET_LEVEL`, and `START_LEVEL`, with
  defaults 64, 48, and `TARGET_LEVEL` respectively.
- Renderer completion holding at the system-core ready/valid boundary.
- Credit scheduler using FIFO level plus one possible inflight frame.
- I2S startup gating, startup-underrun suppression, and render/played/lead/FIFO
  minimum signals.
- Dedicated SPI command-stream opcode `0xa5`, accepting consecutive 32-bit
  words without register addresses.
- New command enum, packed decoded action, transactional parser, and action FIFO
  modules.
- The transactional parser and action FIFO now exclusively consume the command
  word FIFO; the timestamp-block parser, prepare engine, and timed event FIFOs
  have been removed.
- Frame requests snapshot and execute at most 16 decoded actions before the
  renderer starts, so continuous command traffic cannot starve PCM production.
- Packed synchronous prepared voice RAM, prepared/active validity and seq state,
  DEFINE isolation, matching START promotion, and stale START rejection.
- Focused scheduler, startup gate, SPI stream, and parser tests.
- Focused transactional lifecycle and 16+1 action-batch tests.
- Packed active envelope parameter/state, all six stages, runtime envelope
  updates, release/stop, gain/phase, filter, and stale-sequence handling.
- C++ command construction, reference synthesis, DUT adapters, MCU policy, and
  host tools use the command stream directly; the compatibility register path
  has been deleted.
- A low-cost coherent debug snapshot reuses the prepared/active RAM read port
  and exposes 24 read-only words through global registers.
- The 1024-word command FIFO uses one simple-dual-port RAMB36 and prefetches on
  pop for one-word-per-clock buffered output.
- Envelope conversion is a registered request/valid pipeline generated from one
  shared RTL/C++ table source.
- Next-voice scan and envelope snapshot overlap current-voice endpoint traffic;
  the DSP gain and envelope multipliers occupy separate registered stages.
- `make lint` and the full `make test` suite pass at this checkpoint.

The renderer-private advancing phase and biquad history remain outside the
low-cost control-state snapshot. Hardware bring-up can add a separate bounded
datapath trace aperture if those states prove necessary.

Files that define the current boundary:

```text
docs/design/control_command_stream_plan.md
rtl/pkg/synth_pkg.sv
rtl/control/control_action_parser.sv
rtl/control/control_action_fifo.sv
rtl/control/control_action_executor.sv
rtl/control/transactional_control_plane.sv
rtl/control/synth_control_plane.sv
rtl/audio/render_credit_scheduler.sv
rtl/audio/output_sample_fifo.sv
fpga/common/rtl/spi_register_bridge.sv
fpga/common/rtl/wavetable_system_core.sv
fpga/common/rtl/wavetable_i2s_output.sv
fpga/common/rtl/wavetable_demo_system.sv
sim/tb/tb_control_cmd_parser.sv
sim/tb/tb_transactional_control_plane.sv
sim/tb/tb_wavetable_render_core.sv
sim/tb/tb_render_credit_scheduler.sv
sim/tb/tb_wavetable_i2s_output.sv
sim/tb/tb_spi_register_bridge.sv
host/ch347_control_main.cpp
```

## Detailed Verification Matrix

### FIFO And Scheduling

- Prefill reaches exactly `START_LEVEL` before playback starts.
- Startup clocks and zero output do not increment underrun diagnostics.
- Every new credit below `TARGET_LEVEL` starts a refill as soon as the renderer
  and control batch permit it.
- A memory stall lowers the level and rendering automatically catches up to the
  configured target after the stall clears.
- A long-term average render time above the sample period produces real
  underruns rather than sample drops or hidden deadline events.
- Renderer output remains stable while valid and not ready.
- Continuous control traffic cannot prevent a frame after
  `MAX_ACTION_BATCH` actions.

### Voice Lifecycle And Commands

- DEFINE updates prepared state without changing the active audible voice.
- START with matching seq atomically installs configuration, gain, phase
  increment, initial phase, filter, and fresh envelope state.
- The first rendered and first audible sample after START use the complete new
  state.
- START with a mismatched prepared seq and every runtime action with a
  mismatched active seq are consumed without state changes and increment
  `stale_seq_count`.
- STOP immediately excludes the voice without invalidating its prepared state.
- Mono and stereo DEFINE payloads validate reserved bits, bounds, loop rules,
  and exact word counts.
- STREAM_FLUSH recovers parser framing and queues without modifying voice RAM.
- SPI Note On and Note Off traverse the dedicated command transaction through
  the same action stream used by simulation.

### Volume Envelope

- Delay, Attack, Hold, Decay, Sustain, and Release cover zero, one-sample, and
  multi-sample boundaries.
- Note Off is tested during Delay, Attack, Hold, Decay, and Sustain.
- Attack reaches full scale without wrap; Decay and Release reach their targets
  without overshoot.
- Releasing during Attack starts continuously from the current Q1.15 level.
- Updating the current Attack, Decay, or Release step changes the next sample
  without a level discontinuity.
- Delay and Hold duration changes preserve elapsed time and advance immediately
  when the updated duration has already elapsed.
- Sustain changes move using the decay step and do not jump.
- 100-second Attack, Decay, and Release conversions retain non-zero progress
  and complete without accumulator overflow.
- All 256 voice slots retain independent parameters, stage, elapsed count, and
  level under interleaved updates.

### Host And Reference

- C++ and RTL consume identical command words and compare exact integer output,
  including rounding, lookup interpolation, and saturation.
- A mono Note On emits 21 total words, a stereo Note On emits 25, and Note Off
  emits 2.
- Fixed modulator sources are folded into START parameters.
- Real-time source changes update only voices and destinations recorded in the
  dependency graph.
- Note Off computes the then-current release step and carries it atomically in
  VOICE_RELEASE.
- System qualification covers voice allocation, stealing, controller changes,
  pressure, NRPN, pitch/filter modulation, and sustained polyphony when that
  phase is enabled.

## Historical Control-Plane Synthesis Checkpoint

Forced non-incremental Vivado 2025.2 synthesis for
`xc7a50tfgg484-2` on 2026-07-24 reports:

```text
LUT             13,758 / 32,600  (42.20%)
FF              12,335 / 65,200  (18.92%)
BRAM tiles          17 / 75      (22.67%)
DSP                 18 / 120     (15.00%)
post-synth WNS  -2.886 ns
post-synth TNS -81.645 ns, 44 failing endpoints
DRC              0 errors, 0 critical warnings
```

The command FIFO is one `1024 x 32` RAMB36. At this historical checkpoint, the
DSP tail no longer owned the worst setup path; the worst path was the active
voice RAM write path,
from its BRAM clock pin to `DIADI[10]`, with 12.464 ns data-path delay and 22
logic levels.

This result is retained to explain the control-plane optimization history; it is
not the current board baseline. The current full design, including global
effects, uses 19,306 LUTs, 20,750 FFs, 39.5 BRAM tiles, and 47 DSPs and closes
post-route at 100 MHz with WNS +0.226 ns and WHS +0.036 ns. The current worst
passing setup cluster is DEFINE validation/action decode to prepared-RAM write
enable. See `../verification/vivado_synthesis_timing.md` for its routed path,
the executor staging changes, and the remaining margin.

## Later Performance Phase

Keep the single-frame renderer for this control-plane and producer/consumer
refactor. First measure its steady-state render cycles, FIFO minimum, memory
request pattern, and recovery after stalls.

Only if those measurements show that per-frame descriptor scans and discrete
memory requests remain the bottleneck, implement a separate 48-frame
voice-major block renderer:

```text
for each active voice:
  read its configuration once
  calculate 48 phase/envelope/sample results consecutively
  accumulate into a 48-entry stereo accumulator RAM
after all voices:
  write the 48 completed frames to the PCM FIFO
```

That phase owns descriptor-read reduction and memory burst improvement. It must
not be combined with the transactional command, prepared/active state, volume
envelope, or FIFO scheduling implementation. The stable ready/valid and credit
interfaces in this document are the prerequisite and measurement boundary for
the block renderer.
