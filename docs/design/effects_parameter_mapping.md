# Effects Parameter Mapping

This document records how common chorus and reverb controls map onto the
implemented fixed-point algorithms and listening presets. It separates three
different concepts that must not be treated as interchangeable:

1. A product or plug-in control name, such as `Size`, `Depth`, or `Hall`.
2. The mathematical control available in the current chorus or FDN algorithm.
3. The fixed-point command field sent to RTL and mirrored by the C++ model.

The current implementation contains one stereo chorus algorithm and one
eight-line feedback delay network (FDN) reverb algorithm. `studio` and `hall`
are parameter sets for those algorithms. They are not separate room, hall,
plate, or early-reflection models.

Stable arithmetic behavior is specified in [`../fixed_point.md`](../fixed_point.md).
Command payload packing is specified in
[`control_command_stream_plan.md`](control_command_stream_plan.md). Listening
commands are listed in
[`../verification/render_commands.md`](../verification/render_commands.md).

## Signal Flow And Gain Meaning

The spatial processing order is:

```text
chorus_wet = Chorus(dry, chorus_send, chorus_feedback)

reverb_input = saturate24(
    dry * reverb_send
  + chorus_wet * chorus_to_reverb)

reverb_wet = FDN(reverb_input)

output = saturate24(
    dry
  + chorus_wet * chorus_return
  + reverb_wet * reverb_return)
```

The dry path is always unity inside `effect_return_mixer`. A `return` field is
therefore an additive wet-return gain, not a conventional crossfading wet/dry
knob. For a linear, unsaturated effect, perceived wet level is approximately
proportional to `input_send * return_gain`. Send and return are kept separate
because send controls internal excitation and headroom, while return controls
the final mix. Feedback, signed-24 saturation, and the compressor make the
complete path nonlinear at its limits.

`chorus_to_reverb` provides an optional serial route in addition to the direct
dry-to-reverb route. It is zero for `chorus`, `hall`, `chorus-max`, and
`reverb-max`; `studio` uses a small value so a little chorus energy shares the
short room tail.

## Unit And Fixed-Point Conversion

Listening presets are expressed in seconds, milliseconds, hertz, and linear
gains in C++. They are converted to the hardware command formats before the
configuration command is emitted.

### Linear gain to Q1.15

For nonnegative send, return, damping, and reverb feedback controls:

```text
q1_15(x) = clamp(round(x * 32768), 0, 32767)
```

`0x7fff` has explicit unity bypass behavior in the input and return mixers.
This avoids losing one least-significant bit merely because Q1.15 cannot encode
positive `1.0` exactly. Chorus feedback is signed Q1.15 and can represent
negative feedback, although the current presets use only nonnegative values.

### Milliseconds to chorus Q16.8 frames

```text
delay_q16_8 = round(milliseconds * sample_rate * 256 / 1000)
```

At 48 kHz, one millisecond is 48 frames or `12288` Q16.8 units. The eight
fractional bits select linear interpolation between adjacent history samples.

### Hertz to LFO Q0.32 phase increment

```text
lfo_phase_inc = round(hertz * 2^32 / sample_rate)
```

The phase accumulator wraps naturally after one cycle. The generated sine
table reconstructs 1024 positions per cycle from one quarter-wave table.

### Milliseconds to reverb pre-delay frames

```text
pre_delay_frames = round(milliseconds * sample_rate / 1000)
```

Pre-delay changes when the reverberant field begins. It does not change FDN
room size, modal spacing, diffusion, or decay rate.

## Chorus Control Mapping

The chorus reads two independently modulated taps from a 2048-frame stereo
circular history:

```text
delay_l = base_delay + depth * sin(phase)
delay_r = base_delay + depth * sin(phase + stereo_phase_offset)
```

The wet tap is linearly interpolated. The history write is:

```text
history_l = saturate24(input_l * input_send + wet_l * feedback)
history_r = saturate24(input_r * input_send + wet_r * feedback)
```

The common control mapping is:

| Product control or description | Implemented field | Mapping quality | Notes |
| --- | --- | --- | --- |
| Rate | `lfo_phase_inc_q0_32` | Direct | Expressed as cycles per second before conversion. |
| Depth | `depth_q16_8` | Direct | Peak delay deviation, so total sweep width is twice this value. |
| Center delay | `base_delay_q16_8` | Direct | Center of the sinusoidal delay sweep. |
| Chorus pre-delay | `base_delay_q16_8` | Approximate | Some products define pre-delay differently, but it is the closest current control. |
| Feedback | `feedback_q1_15` | Direct | Raises moving-comb resonance; high values can sound metallic or flanger-like. |
| Effect level | `return_gain_q1_15` | Approximate | Adds wet signal without reducing unity dry. |
| Input/send level | `input_send_q1_15` | Direct | Controls excitation and internal headroom. |
| Stereo width/spread | `stereo_phase_offset_q0_32` | Approximate | Changes inter-channel modulation phase, not mid/side width directly. |
| Voice count | Fixed at two taps | Not controllable | One independently modulated tap per channel. |
| Waveform | Fixed sine | Not controllable | No triangle, random, or multi-LFO mode. |

All current chorus-enabled presets use a quarter-cycle (`0x40000000`,
90-degree) stereo phase offset. This decorrelates left and right delay motion
without creating two different LFO rates.

The metallic character heard in the diagnostic `chorus-max` render follows
from its combination of a large delay sweep, high feedback, and unity wet
return. A modulated delay creates moving comb-filter notches when mixed with
the dry path. Increasing feedback narrows and emphasizes those notches. This is
expected chorus/flanger behavior rather than reverb instability.

## Reverb Control Mapping

The reverb has eight fixed delay lines with production lengths:

```text
1451, 1559, 1663, 1777, 1879, 1999, 2131, 2371 frames
```

At 48 kHz these span approximately 30.2 through 49.4 ms. Each line read passes
through a one-pole damping state, then all eight values pass through an
unnormalized Hadamard feedback matrix. Orthogonal sign rows inject left/right
input and extract left/right wet output.

### Decay and RT60

RT60 is a preset-authoring value, not a command field. For line length `D_i`,
sample rate `Fs`, and requested decay time `T60`, C++ derives:

```text
round_trip_decay_i = 10^(-3 * D_i / (T60 * Fs))
feedback_gain_i    = round_trip_decay_i / sqrt(8)
```

`10^-3` is an amplitude ratio of `0.001`, or -60 dB. Division by `sqrt(8)`
compensates the gain norm of the unnormalized eight-way Hadamard transform.
Each result is quantized independently to unsigned Q1.15 and limited to the
Q1.15 approximation of `1/sqrt(8)`. Longer RT60 values move the coefficients
closer to that non-decaying boundary but never cross it.

The formula predicts the nominal linear-network decay. Damping, quantization,
the 32-LSB recursive-state deadband, program material, and final return gain
affect the measured tail. Listening qualification must therefore verify the
rendered result instead of treating requested RT60 as a measurement.

### Damping

For line output `read` and previous low-pass state `state`:

```text
damped = deadband32(read + round_q15((state - read) * damping))
```

Consequently `damping = 0` passes the line read unchanged and sounds brightest.
Increasing damping retains more previous state, reduces high-frequency motion,
and produces a darker tail. This direction must not be confused with APIs that
label the complementary coefficient as damping. The current damping is a
single broadband one-pole control; it is not an independent high-frequency
RT60 or a configurable low/high-cut filter.

### Common reverb control mapping

| Product control or description | Current representation | Mapping quality | Notes |
| --- | --- | --- | --- |
| Decay time / RT60 | Eight derived feedback gains | Direct target, approximate result | Gains account for each line length and Hadamard norm. |
| Pre-delay | `pre_delay_frames` | Direct | Delays wet-field excitation only. |
| Damping | `damping_q1_15` | Approximate | One fixed one-pole low-pass state per delay line. |
| Effect level | `return_gain_q1_15` | Approximate | Additive wet return over unity dry. |
| Input/send level | `input_send_q1_15` | Direct | Scales dry input before the FDN. |
| Chorus-to-reverb send | `chorus_to_reverb_q1_15` | Direct | Adds chorus wet energy to FDN input. |
| Room size | Fixed line lengths | Not runtime controllable | Pre-delay is not a substitute for size. |
| Density | Eight lines and fixed lengths | Fixed design property | No density field. |
| Diffusion | Fixed Hadamard matrix and line set | Fixed design property | No input/output all-pass stages or diffusion field. |
| Early reflections | None | Not implemented | The wet response begins with pre-delay plus FDN line arrivals. |
| Hall/room/studio/plate type | Preset family | Coarse approximation | All presets run the same FDN topology. |
| Low cut / high cut | None | Not implemented | Damping only provides a limited low-pass-like behavior. |
| Modulation | None | Not implemented | FDN line lengths do not move. |

This means `hall` currently denotes a long, delayed, moderately damped FDN
tail. It does not claim to reproduce a vendor Hall algorithm. A convincing
plate or room model would likely require distinct early-reflection, diffusion,
filtering, or line-length policy rather than only another preset name.

## Current Listening Presets

The preset builder currently requires 48 kHz because the production delay
lengths are defined in frames at that sample rate.

### Musical and combined presets

| Parameter | `chorus` | `studio` | `hall` |
| --- | ---: | ---: | ---: |
| Chorus enabled | yes | yes | no |
| Chorus center delay | 8.0 ms | 8.0 ms | n/a |
| Chorus depth | 1.5 ms | 1.0 ms | n/a |
| Chorus rate | 0.60 Hz | 0.45 Hz | n/a |
| Chorus send | 1.00 | 1.00 | 0.00 |
| Chorus return | 0.28 | 0.12 | 0.00 |
| Chorus feedback | 0.04 | 0.00 | 0.00 |
| Reverb enabled | no | yes | yes |
| Nominal RT60 | n/a | 1.0 s | 4.5 s |
| Reverb pre-delay | n/a | 8 ms | 35 ms |
| Reverb send | 0.00 | 0.30 | 0.75 |
| Reverb return | 0.00 | 0.18 | 0.55 |
| Damping | 0.00 | 0.55 | 0.58 |
| Chorus-to-reverb | 0.00 | 0.05 | 0.00 |

`chorus` targets audible thickening without the strong moving resonances of the
diagnostic preset. `studio` combines a subtler chorus with a short, relatively
quiet FDN tail. `hall` removes chorus coloration and obtains space from longer
pre-delay, longer nominal decay, and higher reverb send/return.

### Representative encoded command values

At 48 kHz, the musical preset values above produce the following integer
fields. Decimal values are shown where they make frame counts easier to audit;
hexadecimal values match the packed command representation.

| Field | `chorus` | `studio` | `hall` |
| --- | ---: | ---: | ---: |
| Chorus base Q16.8 | `98304` (`0x00018000`) | `98304` (`0x00018000`) | `0` |
| Chorus depth Q16.8 | `18432` (`0x00004800`) | `12288` (`0x00003000`) | `0` |
| LFO increment Q0.32 | `53687` (`0x0000d1b7`) | `40265` (`0x00009d49`) | `0` |
| Chorus send Q1.15 | `0x7fff` | `0x7fff` | `0x0000` |
| Chorus return Q1.15 | `0x23d7` | `0x0f5c` | `0x0000` |
| Chorus feedback Q1.15 | `0x051f` | `0x0000` | `0x0000` |
| Stereo phase Q0.32 | `0x40000000` | `0x40000000` | `0x00000000` |
| Reverb pre-delay frames | `0` | `384` | `1680` |
| Reverb send Q1.15 | `0x0000` | `0x2666` | `0x6000` |
| Reverb return Q1.15 | `0x0000` | `0x170a` | `0x4666` |
| Damping Q1.15 | `0x0000` | `0x4666` | `0x4a3d` |
| Chorus-to-reverb Q1.15 | `0x0000` | `0x0666` | `0x0000` |

The derived reverb line gains, ordered by the production delay lengths, are:

| Nominal RT60 | Eight feedback gains in unsigned Q1.15 |
| --- | --- |
| 1.0 s (`studio`) | `24ba 2429 239f 230b 2288 21f1 214d 202c` |
| 4.5 s (`hall`) | `2b34 2b0e 2ae9 2ac1 2a9e 2a74 2a46 29f3` |
| 8.0 s (`reverb-max`) | `2c17 2c01 2bec 2bd5 2bc0 2ba8 2b8e 2b5d` |

These values are consequences of the current 48 kHz line set and rounding
rule. They must be regenerated rather than copied if the sample rate, delay
lengths, matrix normalization, or Q format changes.

### Diagnostic presets

| Parameter | `chorus-max` | `reverb-max` |
| --- | ---: | ---: |
| Chorus enabled | yes | no |
| Chorus center/depth | 18 / 8 ms | n/a |
| Chorus rate | 0.8 Hz | n/a |
| Chorus send/return | 1.0 / 1.0 | 0.0 / 0.0 |
| Chorus feedback | 0.4 | 0.0 |
| Reverb enabled | no | yes |
| Nominal RT60 | n/a | 8.0 s |
| Reverb pre-delay | n/a | 30 ms |
| Reverb send/return | 0.0 / 0.0 | 1.0 / 1.0 |
| Damping | 0.0 | 0.55 |

These presets make an effect easy to identify and exercise command-field and
headroom limits. They are not recommended musical defaults. In particular,
`chorus-max` intentionally exposes strong moving-comb coloration.

## Enable Overrides

`EFFECTS_PRESET` chooses all parameters first. `CHORUS_ENABLE` and
`REVERB_ENABLE` then apply `auto`, `on`, or `off` overrides:

- `auto` preserves the preset enable bit;
- `off` clears that processor's enable bit while retaining other preset fields;
- `on` verifies that the preset already contains an enabled, populated setup.

An explicit `on` does not synthesize missing parameters. For example,
`EFFECTS_PRESET=chorus REVERB_ENABLE=on` is rejected because the chorus preset
does not define a reverb configuration. To hear only the reverb portion of
`studio`, use `EFFECTS_PRESET=studio CHORUS_ENABLE=off REVERB_ENABLE=on`.

Disabling a processor forces its wet output to zero. At the algorithm level its
state still advances for every accepted frame, matching the RTL contract. The
C++ song renderer skips the complete spatial chain only when both final enable
bits are false.

## Interpretation Limits

Preset names communicate listening intent, not acoustic measurement. The
following claims are deliberately not made:

- `studio` does not model a measured studio impulse response;
- `hall` does not implement a vendor Hall topology or independent early
  reflections;
- pre-delay does not change the FDN's physical size;
- damping is not a complete frequency-dependent decay model;
- `return_gain` is not a crossfading wet/dry control;
- nominal RT60 is not guaranteed to equal a measured broadband RT60 after
  quantization, damping, deadband, mixing, compression, and PCM16 conversion.

Any future addition of runtime room size, diffusion, density, early-reflection,
cut-filter, or modulation controls must update the RTL command structure,
fixed-point contract, C++ model, self-checking tests, and this mapping document.
Adding only another preset name is insufficient when the requested behavior is
not representable by the existing fields.

## Reference Basis

The exact numeric preset values are project listening choices. The parameter
categories and initial ranges were informed by these primary vendor/library
documents:

- [JUCE `dsp::Chorus`](https://docs.juce.com/master/classjuce_1_1dsp_1_1Chorus.html):
  modulated-delay interpretation, classic chorus delay region, and the
  transition toward flanging with shorter delay and more feedback.
- [Roland GX-100 Prime Chorus parameters](https://static.roland.com/manuals/gx-100_parameter/eng/25630354.html):
  rate, depth, effect level, pre-delay, stereo behavior, and longer-delay
  doubling description.
- [Roland GX-100 Reverb parameters](https://static.roland.com/manuals/gx-100_parameter/eng/25630401.html):
  room/hall/studio/plate categories, decay, pre-delay, density, level, and cut
  controls.
- [Roland SH-4d Reverb parameters](https://static.roland.com/manuals/sh-4d/eng/66978025.html):
  hall decay, size, density, diffusion, and damping control categories.

Those references guide terminology and listening ranges; they do not imply
that this implementation duplicates JUCE or Roland algorithms.
