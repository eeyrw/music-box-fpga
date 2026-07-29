# Chorus And Reverb RTL Backlog

## Implementation Status

The signed-25 `stereo_chorus`, eight-line `fdn_reverb`, `effect_return_mixer`,
serial `global_effects_chain`, and compressor-inclusive
`global_audio_effects_chain` ready/valid path are implemented and integrated in
`voice_major_system`. The system order is chorus, reverb/return mixing,
look-ahead compression, master volume, and final PCM16 saturation. Reset-default
effect settings preserve the exact dry signed-25 path.

Transactional `CHORUS_CONFIG`, `REVERB_CONFIG`, and `EFFECT_CLEAR` commands are
implemented. `EFFECT_CLEAR[0]` clears chorus state and `[1]` clears reverb state;
either clear drops an in-flight spatial frame without resetting compressor
state. Generated effect status registers occupy `0x9134..0x915c`. Independent
integer C++ models cover both wet engines and return mixing, and focused
self-checking RTL tests cover the isolated blocks and integrated chain.

The initial global-effects implementation is therefore functionally complete.
Qualification is not complete: full-session C++/RTL comparison, long-duration
full-polyphony renders, hardware capture, listening evaluation, and RT60 preset
sweeps remain open. A three-second 512-voice RTL/timed-DDR3 random-access stress
render passes with zero deadline misses. The current Smart Artix post-synthesis
build meets the constrained internal 100 MHz target; implementation and route
signoff remain open. Per-voice
SoundFont/MIDI sends remain a deliberately deferred milestone.

The C++ reference song renderer now accepts musical `chorus`, `studio`, and
`hall` presets plus diagnostic `chorus-max` and `reverb-max` presets. Each
processor can be explicitly disabled while retaining the selected preset's
remaining parameters. Effect configuration uses the same transactional command
layouts consumed by RTL. The renderer runs the exact integer chorus,
reverb routing, return mixer, compressor, and
PCM16 output order, can append a configurable effect tail, and reports effect
clamp and saturation diagnostics. This enables listening qualification but is
not itself a completed listening evaluation or a full-session RTL comparison.

The first 300-second `hall` listening render completed without configuration
clamps or chorus, reverb, return-mixer, or compressor saturation. Its silent
ending settles into a bounded 2-to-3 PCM16-LSB DC residue (about -82 dBFS)
rather than exact zero. This is consistent with the specified negative
arithmetic-right-shift behavior forming a low-level FDN fixed-point limit cycle.
The subsequent C++ and RTL change uses symmetric Q1.15 rounding at recursive
boundaries plus an inclusive 32-LSB internal state deadband. Focused zero-input
tail tests now require exact convergence; whole-song listening requalification
remains open.

This document records implemented architecture plus remaining qualification
work. Stable command layouts, fixed-point behavior, delay lengths, clear
semantics, and register addresses are defined by `docs/fixed_point.md`,
`docs/register_map.md`, `control_command_stream_plan.md`, and the generated
register specification. The mapping from product-style chorus/reverb controls
and listening terminology to the implemented algorithms is documented in
[`effects_parameter_mapping.md`](effects_parameter_mapping.md).

## Current Boundary

The renderer emits both saturated PCM16 compatibility samples and an exact
signed 25-bit stereo mix. `voice_major_system` sends the wide mix through
`global_audio_effects_chain`, which owns the serial spatial-effect path followed
by `lookahead_compressor`. The compressor applies the final master gain,
saturates to PCM16, and feeds the existing output FIFO and I2S path.

The implementation does not modify the per-voice renderer, wave-memory protocol,
phase/filter state, or bare `wavetable_render_core` PCM behavior. The effects
occupy the board-facing system path between the wide mix and the compressor:

```text
signed 25-bit stereo mix
  -> chorus wet processor
  -> reverb wet processor
  -> effect return mixer
  -> look-ahead compressor
  -> master volume and final PCM16 saturation
  -> output FIFO and I2S
```

The first milestone is a global effect bus. It cannot reproduce per-voice
SoundFont or MIDI chorus/reverb sends because the current active voice record
contains no effect-send levels and the renderer produces only one mix bus. That
support is a separate later milestone described below.

## Common Streaming Contract

Each effect block uses an explicit stereo ready/valid frame interface with a
signed 25-bit payload. A block must:

- accept a frame only on `in_valid && in_ready`;
- advance delay pointers, LFO phase, feedback state, counters, and warm-up state
  exactly once per accepted frame;
- hold `out_valid` and output samples stable while `out_ready` is low;
- accept no new frame when its output holding register cannot retire;
- base all modulation and delay timing on accepted audio frames, not system
  clock cycles or raw `sample_tick` pulses;
- snapshot the active configuration for each accepted frame so a transactional
  command cannot partially affect an in-flight calculation.

The target runs at 100 MHz and 48 kHz, giving approximately 2083 system clocks
per frame. Both effects should therefore use a frame-serial state machine and
time-multiplex arithmetic rather than instantiate all delay-line operations in
parallel. Effect delay storage must use local block RAM and must not share the
external wavetable DDR request path.

Disabled effects must have an exact-zero wet return. The dry path must remain
bit-exact with the current signed 25-bit mix. Engines may continue advancing
their history while their return is disabled so that re-enabling an effect does
not expose stale memory.

## Effect Routing

The chorus and reverb modules should produce wet-only samples. A separate
`effect_return_mixer` owns routing and the only dry/wet sum:

```text
reverb_input = dry * reverb_send
             + chorus_wet * chorus_to_reverb

effect_mix = dry
           + chorus_wet * chorus_return
           + reverb_wet * reverb_return
```

This topology preserves a single exact dry path, permits chorus-to-reverb
routing, and avoids hiding dry gain inside either algorithm. The return mixer
uses explicit wide signed products and sums, shifts Q1.15 gains arithmetically,
and saturates once to signed 25-bit at its output. It exposes a saturating count
of channel saturation events.

The effect mix remains signed 25-bit so the existing compressor detector,
look-ahead RAM, fixed-point tables, and C++ model do not need an unrelated width
change. Normal presets should keep send and return levels below unity. The RTL
must still saturate safely for hostile configurations and report that event.

## Chorus Architecture

The implemented `stereo_chorus` is a modulated fractional delay with feedback.
It stores signed 25-bit history in separate left/right circular block RAMs and
evaluates two independent fractional taps:

```text
write_sample = saturate25(input + feedback * delayed_sample)
delay        = base_delay + depth * sine(lfo_phase)
wet          = sample_0 + ((sample_1 - sample_0) * fraction >>> 8)
lfo_phase    = lfo_phase + phase_inc
```

Left and right taps share the LFO frequency but use a configurable phase
offset. The default should be a quarter cycle rather than a fixed inverted LFO.
A generated 257-entry quarter-wave Q1.15 sine table can provide 1024 full-cycle
phase positions using symmetry. The generator must emit matching RTL and C++
tables.

Implemented sizing and formats:

| Item | Value |
| --- | --- |
| Delay capacity | 2048 stereo frames, approximately 42.7 ms at 48 kHz |
| Delay storage | two signed 25-bit channels per frame |
| Base delay and depth | unsigned Q16.8 frames |
| LFO phase and increment | unsigned Q0.32 cycles |
| Feedback | signed Q1.15, initially limited to magnitude 0.75 |
| Input send and wet return | nonnegative Q1.15 |
| Fractional interpolation | signed delta with eight fraction bits |
| Target processing time | no more than 20 system clocks per frame |

The accepted configuration must obey:

```text
base_delay - depth >= 1 frame
base_delay + depth <= DELAY_CAPACITY - 2 frames
abs(feedback) <= configured stability limit
```

The implementation may clamp invalid values if it also raises a sticky
configuration-clamped status. It must not permit pointer underflow or an
out-of-range RAM read. A saturating history-age counter makes taps that predate
valid input return exact zero. Reset and effect clear invalidate the logical
history without clearing every block-RAM word.

Focused chorus tests must cover exact bypass, zero input, constant input,
positive and negative endpoints, fractional interpolation, both pointer-wrap
directions, LFO phase wrap, stereo phase offset, feedback, warm-up, saturation,
configuration changes, reset/clear, and arbitrary output backpressure.

## Reverb Architecture

The preferred reverb is an eight-line stereo Feedback Delay Network (FDN).
Compared with separate per-channel banks of parallel comb and all-pass filters,
an FDN permits one packed delay-state RAM and a small time-multiplexed arithmetic
engine while still producing a decorrelated stereo tail.

For each accepted frame the engine should:

1. Apply the configured input pre-delay.
2. Inject left and right input through two orthogonal sign vectors.
3. Read one signed 25-bit value from each of eight delay lines.
4. Update one-pole damping state for each line.
5. Apply an eight-point Hadamard butterfly.
6. Scale each transformed value by its line feedback coefficient.
7. Add the signed input injection and write each delay line at its ring pointer.
8. Form left and right wet outputs using two different orthogonal output vectors.

Initial sizing and formats:

| Item | Planned value |
| --- | --- |
| FDN size | 8 delay lines |
| Delay range | approximately 30 to 50 ms per line at 48 kHz |
| Total FDN state | approximately 15K to 17K signed 25-bit samples |
| Pre-delay | 0 to 2047 frames |
| Damping coefficient | nonnegative Q1.15 |
| Eight feedback coefficients | nonnegative Q1.15 |
| Input send, wet return, chorus routing | nonnegative Q1.15 |
| Target processing time | no more than 80 system clocks per frame |

Delay lengths are elaboration-time constants and must not change while audio is
running. Candidate odd, mutually decorrelated lengths should first be swept in
the C++ reference and evaluated with impulse metrics and listening tests. They
become part of the numeric contract only after that validation.

The host should convert an RT60 value into one coefficient per line:

```text
gain_i = 10 ^ (-3 * delay_i / (rt60_seconds * sample_rate))
```

The host may fold the Hadamard `1/sqrt(8)` normalization into those coefficients
so that the RTL needs one feedback multiply per line. Coefficients must be
validated against a documented stability limit before activation.

All logical delay lines should occupy one packed RAM with fixed base offsets.
The FSM can issue sequential reads and writes because the frame budget is much
larger than the expected operation count. Per-line valid ages return zero until
the corresponding delay has been filled. Reset and clear reset pointers,
validity, damping registers, and counters without iterating over the RAM.

Focused reverb tests must cover the exact impulse response, silence, stereo
injection/output signs, every delay pointer wrap, all Hadamard butterfly signs,
damping extremes, feedback extremes, pre-delay, line warm-up, long decay,
state clear, saturation, configuration updates, and arbitrary backpressure.

## Reverb Spatial Extension Backlog

The implemented FDN supplies a stable late reverberant tail, but it does not
yet model explicit early reflections, input diffusion, runtime room size, or a
separate wet-output tone control. These are suitable for FPGA implementation;
they are deferred because they expand the command contract, state RAM,
arithmetic schedule, preset policy, and verification surface.

The target topology is not a single serial chain. Early reflections must remain
a separately mixable branch so the diffuser does not erase their discrete
arrival and stereo-position cues:

```text
signed-25 stereo input
  -> pre-delay
       +-> multi-tap early-reflection engine --------------------+
       |                                                         |
       +-> two to four input all-pass diffusers                   |
             -> eight-line FDN                                   |
                  -> in-loop frequency-dependent damping         |
                  -> late wet output                             |
                       -> optional wet-output high-shelf EQ ------+
                                                                 |
exact dry --------------------------------------------------------+
                                                                 v
            saturate25(dry + early_return + late_return) -> compressor
```

The early and late branches may use independent return gains. A configurable
early-to-late send may inject some early-reflection energy into the diffuser or
FDN, but early reflections must not be forced through the late path as their
only audible route. The exact dry path remains unity and is still owned by the
return mixer.

### Early Reflections

The preferred first extension is an 8-tap stereo early-reflection engine backed
by one signed-25 stereo circular RAM. One tap is evaluated per system clock so
the design does not require a separate RAM or multiplier for every reflection.
Each tap needs a delay and independent signed left/right gains. Related fields
should cross module boundaries as a packed SystemVerilog structure, for
example:

```systemverilog
typedef struct packed {
  logic [15:0]        delay_frames;
  logic signed [15:0] gain_l_q1_15;
  logic signed [15:0] gain_r_q1_15;
} early_reflection_t;
```

The final field widths and array ownership must be frozen in the fixed-point and
command contracts before RTL implementation. Tap delays must fit the allocated
history capacity. Signed gains permit polarity changes as well as stereo
placement. Wide accumulation must retain every tap product and saturate only
once per output channel.

The initial engine should use fixed tap count with preset-authored delays and
gains. It does not need runtime geometric room modeling. Focused tests must
cover exact tap arrival frames, left/right gains and signs, coincident-tap
accumulation, uninitialized history, pointer wrap, clear, saturation,
configuration replacement, and randomized backpressure.

### Input Diffusers

Two to four short Schroeder all-pass stages should precede the late FDN path:

```text
y[n]       = delayed[n] - g * x[n]
delay_write = x[n] + g * y[n]
```

The exact algebraic form, rounding points, and sign convention must be selected
once and used by both RTL and the independent C++ model. Each stage requires a
short delay state, signed coefficient, validity age, and saturating arithmetic.
Stages should be processed serially and may share a multiplier if the combined
effect latency stays within the frame-cycle gate.

Candidate delay lengths must be mutually non-harmonic, differ between left and
right, and be swept in C++ before becoming generated constants. Four stages are
a listening candidate, not an automatic requirement. Qualification must reject
settings that create ringing, metallic coloration, excessive transient smear,
or a fixed-point limit cycle. Early-reflection output must remain available
before this diffusion path.

### Size And Density

Room `size` is a late-network property and must not be approximated by
pre-delay alone. A first hardware implementation should provide discrete
`small`, `medium`, and `large` line-length sets rather than a continuously
moving size control. Each line may reserve its maximum RAM partition and use a
configured effective ring length within that partition. Changing size must
also regenerate all eight feedback gains to preserve the requested RT60.

Changing a live delay length reinterprets existing history and can create a
discontinuity. The first contract should therefore clear the reverb state, or
perform a documented fade-out, clear, reconfigure, and fade-in sequence. A
click-free continuous size sweep would require dual state or crossfaded taps
and is outside the initial extension.

`Density` is not initially a scalar register because its audible meaning
combines line count, line lengths, diffuser stages, early taps, and output taps.
The first density choices should be preset-level topology choices. Add a
runtime density field only after impulse metrics and listening tests establish
a stable mapping. Increasing the FDN from eight to sixteen lines is possible
but is not the preferred first step because it approximately doubles line
state and processing work; input diffusion and early taps should be evaluated
first.

### Damping And Output Tone

Frequency-dependent decay belongs inside the FDN feedback loop. A filter in
that loop causes high frequencies to lose additional energy on every round
trip, permitting high-frequency RT60 to differ from low-frequency RT60. The
existing per-line one-pole damping is already in-loop and must not be replaced
by an output high shelf.

An optional high-shelf after the FDN output may be added as `wet_output_tone`
or equivalent. It changes the final wet spectrum but does not change the
network's frequency-dependent decay. Documentation, register names, and UI
labels must preserve this distinction:

```text
in-loop damping filter -> controls spectral decay over time
post-FDN high shelf     -> controls static wet-output tone
```

If a biquad or shelf replaces the current one-pole in each feedback line, it
must retain independent state per line even if arithmetic is time-multiplexed.
Tests must measure low- and high-band decay separately and prove stability at
all accepted coefficients. A post-FDN shelf needs independent exact-response,
saturation, bypass, and clear/configuration tests but must not be reported as
an RT60 damping control.

### Extension Order And Gates

The proposed implementation order is:

1. Build an independent integer C++ 8-tap stereo early-reflection model and
   add it as a separately controlled wet branch.
2. Add two input all-pass diffusers in C++, then sweep two versus four stages,
   delay sets, and coefficients using impulses and full-song listening.
3. Freeze the chosen early-reflection and diffuser arithmetic, implement
   focused RTL blocks, and integrate them before the existing FDN.
4. Add discrete size presets with maximum-sized fixed RAM partitions and a
   clear-on-change control contract.
5. Evaluate an in-loop shelf or higher-order damping filter only if the current
   one-pole cannot produce acceptable frequency-dependent tails.
6. Add an optional post-FDN wet-output shelf only when a separate tone control
   is justified by listening tests.
7. Reconsider a density control or sixteen-line FDN only after the cheaper
   diffusion and early-reflection options have been measured.

The complete extended spatial chain must remain within the existing signed-25
streaming and backpressure contract. Its initial target remains no more than
128 system clocks per stereo frame for the combined effects path at 100 MHz,
subject to revision only after synthesis data. Each added RAM and multiplier
must be included in Smart Artix utilization, timing, full-polyphony render, and
long-tail power/thermal qualification. No new block may access wavetable DDR.

## Control-Plane Backlog

Effects use the existing transactional command stream. The global opcodes are:

| Opcode | Action | Payload |
| ---: | --- | ---: |
| `0x22` | `CHORUS_CONFIG` | 6 words |
| `0x23` | `REVERB_CONFIG` | 9 words |
| `0x24` | `EFFECT_CLEAR` | 1 word |

The header `voice` and `seq` fields must both be zero, matching the compressor
and master-volume global actions. The action executor owns the active effect
configuration and applies complete structures at a render-frame boundary.

The chorus payload contains enable, base delay, depth, LFO phase
increment, input send, wet return, feedback, and stereo phase offset. The
reverb payload contains enable, input send, wet return, damping,
chorus-to-reverb level, pre-delay, and eight packed line gains. `EFFECT_CLEAR`
contains a mask selecting chorus and/or reverb state.

The implemented command path crosses:

- `synth_pkg` opcode and configuration types;
- command parser length and global-header validation;
- action-executor semantic validation and active state;
- `synth_control_plane` and `wavetable_render_core` configuration outputs;
- C++ command builders, sinks, and bit-exact reference model;
- command parser and transactional-control self-checking tests.

The command contract is included in interface version `0x000a0000`. Exact
payload fields and validation rules are documented in
[`control_command_stream_plan.md`](control_command_stream_plan.md).

## Diagnostics

The implemented read-only effect diagnostics expose:

- enable, busy, chorus-history-valid, reverb-line-valid, and configuration-
  clamped flags;
- input and output stereo-frame counters;
- effect-return signed-25 saturation count;
- maximum effect processing cycles;
- chorus history level and current LFO phase;
- reverb valid-line mask and pre-delay occupancy.

Addresses `0x9134..0x915c` are assigned contracts in `spec/register_map.json`.
The generated RTL and C++ constants, common-status register fabric, and exact
field descriptions in `docs/register_map.md` are synchronized from that
specification.

## Resource And Timing Gates

The earlier 9-BRAM/26-DSP baseline and incremental estimates predated the final
effect and control implementation and are retired as acceptance data. The
19,306-LUT result below is the last routed smaller-configuration result, not the
current 512-voice signoff. The current comparable build is post-synthesis only:

| Resource or timing field | Earlier routed result | Current 512-voice, 8-slot synthesis |
| --- | ---: | ---: |
| LUT | 19,306 / 32,600 (59.22%) | 32,016 / 32,600 (98.21%) |
| FF | 20,750 / 65,200 (31.83%) | 31,830 / 65,200 (48.82%) |
| Block RAM tiles | 39.5 / 75 (52.67%) | 44 / 75 (58.67%) |
| DSP48E1 | 47 / 120 (39.17%) | 39 / 120 (32.50%) |
| Combined spatial-effect processing test gate | no more than 96 clocks/frame | no more than 96 clocks/frame |
| Reverb processing test gate | no more than 88 clocks/frame | no more than 88 clocks/frame |
| Setup timing | post-route WNS +0.226 ns | post-synthesis WNS +0.401 ns |

The first effects-enabled synthesis did not fit because chorus and reverb delay
storage failed to infer BRAM. After separate physical memories, synchronous
reads, validity/age tracking, and arithmetic/control staging, the implementation
used 39.5 BRAM tiles and 47 DSPs and was fully routed. Source-level bit counts and
`ram_style` attributes are not proof of inference; the detailed failure and
closure history is in `../verification/vivado_synthesis_timing.md`.

The focused effect tests meet their bounded processing-cycle gates. The complete
renderer plus effects path still requires long full-polyphony qualification with
realistic memory stalls. Effect latency is system-clock latency only: neither
effect may add a sample-domain delay to the dry path. The existing logical
startup latency remains the compressor look-ahead plus output-FIFO lead.

## Implementation Sequence

1. Build an independent integer C++ chorus and FDN prototype. Select delay
   constants and presets using exact impulse tests plus listening evaluation.
   **Models, delay constants, focused impulse tests, and whole-song listening
   render presets implemented; subjective evaluation and broader preset sweeps
   remain.**
2. Freeze fixed-point arithmetic, rounding, saturation, reset, warm-up, and
   configuration-update behavior in `docs/fixed_point.md`.
   **Implemented.**
3. Implement and test `stereo_chorus` as an isolated ready/valid block.
   **Implemented.**
4. Implement and test the packed-RAM `fdn_reverb` as an isolated ready/valid
   block.
   **Implemented.**
5. Implement the effect return mixer and end-to-end backpressure chain.
   **Implemented.**
6. Add transactional actions and matching C++ command construction.
   **Implemented.**
7. Integrate the effects between the wide renderer mix and compressor in
   `voice_major_system`; keep bare render-core behavior unchanged.
   **Implemented.**
8. Add generated status registers, JSON diagnostics, and bit-exact C++/RTL
   render comparison.
   **Status registers, JSON diagnostics, and the command-driven integrated C++
   song model are implemented; focused independent model tests pass;
   full-session C++/RTL comparison remains.**
9. Run full-polyphony cached-memory renders and Smart Artix synthesis,
   implementation, timing, and utilization checks.
   **Current 512-voice synthesis and a three-second real-SF2 timed-DDR3 stress
   render complete; implementation, route signoff, and long-duration stress
   renders remain.**
10. Qualify the result on hardware with impulse capture, sustained tails,
    silence, rapid configuration changes, and long underrun-free playback.
    **Open.**

## Completion Matrix

| Area | Status | Evidence or remaining gate |
| --- | --- | --- |
| Chorus RTL and integer model | Complete | Focused RTL and C++ self-checking tests pass. |
| Reverb RTL and integer model | Complete | Focused RTL and C++ self-checking tests pass. |
| Return routing and saturation | Complete | Mixer and integrated spatial-chain tests pass. |
| Compressor-inclusive ordering | Complete | `global_audio_effects_chain` and system wrapper use one serial path. |
| Transactional configuration | Complete | Opcodes `0x22..0x24`, builders, parser, and executor tests pass. |
| `EFFECT_CLEAR` | Complete | Selective chorus/reverb clear and compressor isolation are tested. |
| Generated diagnostics | Complete | Registers `0x9134..0x915c` and generated constants are checked. |
| Focused lint and regression | Complete | `make lint`, `make test`, and generator checks pass. |
| Full-session C++/RTL comparison | Open | Integrated reference/render comparison has not been added. |
| Full-polyphony memory stress | Open | Representative long cached-memory renders are still required. |
| FPGA resource and timing gates | Complete | Forced Vivado implementation fits, fully routes, and closes setup/hold at 100 MHz; external I/O delays remain board qualification. |
| Hardware/audio qualification | Open | Capture, sustained-tail, listening, RT60, and long-run tests remain. |
| Early-reflection branch | Open | Define 8-tap C++ model, packed tap configuration, RTL, routing, and impulse tests. |
| Input diffusion | Open | Sweep two versus four all-pass stages before freezing delay sets and arithmetic. |
| Discrete room size | Open | Define maximum RAM partitions, derived RT60 gains, and clear-on-change semantics. |
| Frequency-dependent damping | Partial | One-pole in-loop damping exists; band-decay qualification and any higher-order filter remain open. |
| Wet-output tone shelf | Deferred | Optional post-FDN EQ must remain distinct from in-loop damping. |
| Runtime density control | Deferred | Establish a measurable preset/topology mapping before adding a scalar field. |
| Per-voice effect sends | Deferred | Explicitly outside the initial global-effects milestone. |

## Acceptance Criteria

- Reset defaults produce output bit-for-bit identical to the current no-effect
  system path.
- RTL and the independent C++ model agree exactly for focused vectors and full
  render sessions, including rounding and saturation.
- State changes exactly once per accepted frame under randomized backpressure.
- No RAM location is read as valid before it has been initialized by accepted
  audio history.
- Clearing an effect does not require a synthesized bulk RAM reset.
- Effect processing stays within the cycle and resource gates above.
- Existing compressor look-ahead, master gain, output FIFO, and I2S behavior
  remain unchanged except that they consume the post-effect mix.
- `make lint`, `make test`, representative C++/RTL renders, and Smart Artix
  post-route timing all pass.

## Deferred Per-Voice Sends

SoundFont and MIDI effect-send semantics require distinct per-voice values. A
later milestone must add chorus and reverb send levels to the prepared/active
voice and runtime command state, carry them through the voice DSP context, and
accumulate three signed stereo buses:

```text
dry mix
chorus-send mix
reverb-send mix
```

That change expands voice RAM records, START/runtime command payloads, per-voice
gain arithmetic, accumulators, C++ MCU policy, and verification workload. It
also needs a fresh renderer throughput and DSP-resource analysis. It must not be
silently approximated from the final global mix and is intentionally excluded
from the initial effects milestone.
