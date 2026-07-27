# Fixed-Point Formats

## Audio Samples

Wave memory and output samples are signed 16-bit PCM. DSP blocks treat them as
Q1.15 values. Intermediate interpolation and gain calculations retain extra
bits and saturate only at the output boundary.

## Playback Phase

`phase` and `phase_inc` are unsigned Q24.8 values measured in sample frames.
The upper 24 bits select a frame and the lower 8 bits are the interpolation
fraction. For example, `0x0000_0180` identifies the point halfway between frame
1 and frame 2.

At each accepted sample request, the current phase is rendered and then
`phase_inc` is added. In continuous loop mode, or loop-until-release before the
released flag is set, reaching the exclusive loop end subtracts the loop length
once. V1 therefore requires the increment to be smaller than one loop length for
looping playback. No-loop playback and released loop-until-release playback stop
contributing once phase reaches `length`.

The eight fractional bits can make dense pitch-bend automation audibly step at
low phase increments. For example, one `phase_inc` LSB is about 7.8 cents at an
increment of 222 and 13.8 cents at an increment of 125. Increasing phase
precision, or adding an error-accumulation scheme while preserving the command
format, is deferred for a separate architecture discussion; the current Q24.8
interface and behavior are unchanged.

## Interpolation

Linear interpolation is evaluated with signed intermediate values:

```text
delta = sample_1 - sample_0
value = sample_0 + ((delta * fraction) >>> 8)
```

The mathematical result remains in the signed 16-bit sample range.

### Datapath Widths

The implemented per-voice sample datapath uses these integer widths:

```text
wave memory endpoints
  sample_0/sample_1: signed16 PCM

linear interpolation
  delta = sample_1 - sample_0: signed17
  fraction: unsigned8
  delta * fraction: signed25
  scaled delta after >>> 8: signed17
  interpolated sum: signed18 internal
  interpolation output: signed16 PCM

biquad input
  x: signed16
  b0/b1/b2/a1/a2: signed16 Q2.14

biquad feed-forward products
  b0*x, b1*x, b2*x: signed32
  z1/z2 state: signed34 Q14
  y_q14 = sign_extend_38(b0*x) + sign_extend_38(z1): signed38
  y = saturate_i20(y_q14 >>> 14): signed20

biquad feedback products
  a1*y, a2*y: signed36
  next_z raw: signed38
  next_z stored: saturate_i34(next_z raw)

post-filter sample
  filter enabled: signed20 y
  filter disabled: signed16 interpolation result sign-extended to signed20

output scaling
  post-filter sample: signed20
  gain: signed16 Q1.15
  envelope: signed16 Q1.15
  product arithmetic: signed64 internal
  voice contribution: saturate_pcm(product >>> 15 or >>> 30)

mixing
  voice contribution: signed16 PCM
  stereo accumulator: signed32
  final sample: saturate_pcm(accumulator)
```

## Gain

Left and right gains are signed Q1.15 values. `0x0000` is silence and `0x7fff`
is just below unity. For output scaling, the signed post-filter sample is
multiplied by the channel gain and envelope level in one wide signed product, then
arithmetically shifted and saturated once to signed 16-bit PCM. If
`envelope_level == 0x7fff`, the envelope multiply is bypassed and the sample is
scaled by channel gain only with a wide signed product shifted right by 15.

## Envelope Level

Each voice has a signed Q1.15 `envelope_level` folded into the per-channel output
gain before mixing. The FPGA derives it once per rendered sample from the packed
Delay, Attack, Hold, Decay, Sustain, and Release state installed by `VOICE_START`.
SoundFont timecent, modulator, and region-policy calculations remain
software-owned. `VOICE_ENV_UPDATE` changes envelope parameters without reloading
playback phase.
`0x7fff` means full level and is treated as a bypass to preserve exact samples
from the channel-gain stage.

During Delay, the renderer advances Q24.8 phase and applies the normal loop
wrapping rules without fetching interpolation endpoints or entering the DSP
pipeline. The voice remains active, its output is exact zero, and biquad history
is unchanged. The first frame whose advanced envelope state is Attack uses the
normal memory and DSP path.

The replacement block walker preserves that per-frame ordering: it advances
the envelope state first, then derives the frame's Q1.15 level from the advanced
state. A Release step that reaches the 1000 cB silence threshold deactivates the
voice before phase or sample work for that frame.

Attack advances a Q0.32 linear-amplitude accumulator. Decay, Sustain, and
Release store Q12.20 centibel attenuation and convert it to Q1.15 with a
generated SoundFont amplitude curve:

```text
level_q15 ~= round(32767 * 10 ^ (-centibel / 200))
```

The FPGA range-reduces this exponential conversion using the identity
`60.205999 cB = 6.0205999 dB = one binary octave`. A threshold lookup selects
the binary right-shift count, and a 121-entry table at 0.5 cB intervals converts
the residual within one octave to a 24-bit linear mantissa. The shifted mantissa
is rounded once to Q1.15. This removes interpolation multipliers while preserving
the required nonlinear cB-to-linear-gain mapping. Generator validation over
`0..1000 cB` at 1/256 cB intervals checks monotonicity and limits deviation from
the directly evaluated Q1.15 curve to 100 integer units (the measured maximum is
recorded in the generated-file header).

Values at or above `1000 cB` clamp to zero. This matches the SoundFont
volume-envelope definition: a full-scale Release reaches zero at 100 dB
attenuation. The separate default MIDI volume and expression modulators retain
their specified 960 cB excursion.

Release may begin during the linear Attack stage, so the FPGA also approximates
the inverse conversion from Q1.15 level to Q12.20 centibel attenuation. It counts
leading zeroes to split the logarithm into a binary exponent and a normalized
mantissa, then adds a 15-entry exponent table to a 64-entry mantissa table. This
avoids a variable divider and a wide linear search. Exhaustive generator
validation over all positive non-full-scale Q1.15 values limits maximum error to
`0.68 cB`; the generated-file header records the actual maximum and mean error.

`tools/gen_dsp_lut.py` generates both
`rtl/generated/synth_dsp_lut_pkg.sv` and
`sim/harness/generated/dsp_lut.h` so the FPGA datapaths and C++ reference use
matching integer tables. Envelope and compressor constants have separate names
and separate generated arrays, even where the current exponential values are
identical. This keeps the ROM inference and precision choices application-local
instead of coupling future envelope and dynamics changes.

The compressor-specific set contains a leading-zero-normalized
magnitude-to-centibel mantissa table. The compressor combines the binary
exponent with this mantissa correction to produce a signed level relative to
`2^15` PCM full scale, then uses its own centibel-to-Q1.15 table for gain
conversion. Seven mantissa bits plus the next-bit rounding decision address 129
table nodes. Generator checks cover every rounding boundary and every exponent
in the signed 24-bit mix range, including magnitude `2^23`; maximum logarithmic
error is limited to `0.35 cB`.

## Biquad IIR Filter

Each voice can enable a second-order IIR filter after interpolation and before
channel gain. Coefficients are signed 16-bit Q2.14 values. DEFINE and
`VOICE_FILTER` pack `{b1,b0}`, `{a1,b2}`, and `{reserved,enable,a2}` into three
command words. `0x4000` is unity, `0x2000` is 0.5, and negative feedback
coefficients use two's-complement signed values.
The implemented transposed direct-form II equation is:

```text
y_q14 = b0 * x + z1
y     = saturate_i20(y_q14 >>> 14)
z1    = saturate_i34(b1 * x - a1 * y + z2)
z2    = saturate_i34(b2 * x - a2 * y)
```

Software writes normalized coefficients as `b0`, `b1`, `b2`, `a1`, and `a2`, where
the denominator is `1 + a1*z^-1 + a2*z^-2`. Disabling the filter bypasses this
stage. In the current mono-lane renderer, filter state is signed 34-bit Q14 per
hardware voice and is cleared when a new generation starts.

The replacement mono-lane block renderer keeps exactly one signed 34-bit Q14
`z1/z2` pair per hardware voice. It filters the interpolated mono sample once,
then applies independent left and right Q1.15 gains. An SF2 stereo pair uses two
ordinary mono voices and therefore two independent filter histories. The old
per-channel stereo renderer has been removed.

### Biquad Range Analysis

The filter format was narrowed from the earlier Q4.28 coefficient and 48-bit
state implementation using the range analysis below.

The SoundFont 2.04 specification defines `initialFilterFc` over the useful range
`1500..13500` cents and `initialFilterQ` over `0..960` centibels. It also states
that practical SoundFont renderers may approximate filter behavior according to
perceptual criteria. The current C++ loader and MCU model convert those values to
a normalized digital low-pass biquad before writing RTL coefficients.

Using the existing `filter_for()` coefficient formula at 48 kHz and sweeping the
useful SoundFont ranges gives these approximate coefficient maxima:

```text
abs(b0) <= 0.930
abs(b1) <= 1.861
abs(b2) <= 0.930
abs(a1) <= 2.000
abs(a2) <= 1.000
```

The implemented RTL recurrence keeps `y` as a signed 20-bit value before it is
used in the `a1*y` and `a2*y` products:

```text
y_q14 = b0 * x + z1
y     = saturate_i20(y_q14 >>> 14)
z1    = saturate_i34(b1 * x - a1 * y + z2)
z2    = saturate_i34(b2 * x - a2 * y)
```

With `x` constrained to signed PCM16 and `y` constrained to signed 20-bit, a
conservative one-step bound for the current coefficient generator is about:

```text
abs(b*x) <= 1.861 * 32768 * 2^14
abs(a*y) <= 2.000 * 524288 * 2^14
abs(z2)  <= (0.930 * 32768 + 1.000 * 524288) * 2^14
abs(z1)  <= (1.861 * 32768 + 2.000 * 524288 +
              0.930 * 32768 + 1.000 * 524288) * 2^14
```

The implementation therefore uses signed 16-bit Q2.14 coefficients, a signed
20-bit post-filter sample, a signed 34-bit Q14 filter state, and signed 38-bit
raw state expressions before the state is saturated back to 34 bits.

## Mixing

The multi-voice renderer accumulates signed 16-bit voice outputs in a signed
32-bit stereo accumulator. With at most 256 voices, the exact range is
`-8,388,608..8,388,352`, which fits a signed 24-bit sample. The common system
path therefore narrows the accumulator exactly to a signed 24-bit stereo mix
and stores 48 such frames in the compressor delay line.

## Stereo Chorus

The isolated chorus processor uses signed 24-bit stereo samples and a 2048-frame
power-of-two circular history. Delay base and depth are unsigned Q16.8 frame
values. LFO phase and increment are unsigned Q0.32 cycles; the upper ten phase
bits address 1024 full-cycle positions reconstructed from the generated
257-entry quarter-wave Q1.15 sine table.

For a modulated delay `N.f`, the tap uses the samples preceding the current
write position by `N` and `N + 1` accepted frames:

```text
newer = history[write_position - N]
older = history[write_position - N - 1]
wet   = newer + ((older - newer) * f >>> 8)
```

Arithmetic right shifts round negative values toward negative infinity. A tap
whose requested age exceeds the saturating history-age counter is exact zero.
The accepted-frame configuration is clamped so that the complete modulated
delay remains from one through `DELAY_CAPACITY - 2` frames. Feedback is signed
Q1.15 and clamps to `-0x6000..0x6000`; input send is nonnegative Q1.15 and
clamps to `0..0x7fff`. An input send of `0x7fff` bypasses multiplication to
preserve the signed-24 input exactly. History writes use:

```text
write = saturate24(input_send * input + feedback * wet)
```

Products shift arithmetically by 15 bits and the sum saturates once. Saturation
is counted per channel. Disabling the processor forces its wet output to exact
zero but continues to advance history and LFO state. Reset or clear invalidates
history by resetting pointers and age; it does not clear the RAM array.

## Eight-Line FDN Reverb

The isolated reverb processor stores eight signed-24 delay lines in one packed
RAM. The production line lengths at 48 kHz are the odd prime frame counts below;
the generated RTL and C++ tables also contain their packed base offsets.

```text
1451, 1559, 1663, 1777, 1879, 1999, 2131, 2371
```

They span approximately 30.2 through 49.4 ms and total 14,830 signed-24
samples. A separate 2048-frame signed-24 stereo RAM provides zero through 2047
frames of pre-delay. Saturating age counters make all pre-delay and FDN reads
that precede valid written history return exact zero. Clear resets pointers,
ages, damping state, and diagnostics without clearing either RAM.

Damping and the eight feedback gains are nonnegative Q1.15. Damping clamps to
`0..0x7fff`. Each feedback gain clamps to `0x2d41`, the Q1.15 approximation of
`1/sqrt(8)`, because the Hadamard transform itself is not normalized. The FDN
input is already scaled and routed by `effect_return_mixer`; the engine does not
apply the reverb-send gain a second time.

For delay-line value `read` and previous damping state `state`, damping is:

```text
damped = deadband32(read + round_q15((state - read) * damping))
```

Thus zero damping passes the delay read exactly, while `0x7fff` nearly retains
the previous state outside the internal deadband. `round_q15` rounds the
magnitude to nearest with exact half values away from zero, then restores the
sign. `deadband32` maps inclusive signed-24 values from `-32` through `32` to
zero. The eight damped samples pass through the standard
unnormalized three-stage Hadamard butterfly. Left and right pre-delayed inputs
use Hadamard rows 0 and 1 as orthogonal injection sign vectors, with their sum
shifted right once. Wet left and right use rows 2 and 3 as output sign vectors,
with the signed sums shifted right three times:

```text
injection_i = (left + sign(row1, i) * right) >>> 1
write_i = deadband32(saturate24(
    injection_i + round_q15(hadamard_i * feedback_gain_i)))
wet_l = sum(sign(row2, i) * damped_i) >>> 3
wet_r = sum(sign(row3, i) * damped_i) >>> 3
```

Line-write saturation is counted once per affected line. Disabled reverb emits
an exact-zero wet return while pre-delay, line pointers, damping, and feedback
continue advancing once per accepted frame. The serial RTL performs one line
read, damping multiply, and feedback write per clock group and currently
completes a frame in fewer than 30 system clocks. Symmetric product rounding
removes the negative DC bias of arithmetic shifting at the two recursive
boundaries, while the state deadband guarantees that a stable zero-input tail
eventually reaches exact digital silence.

## Effect Routing And Return Mix

`effect_return_mixer` is the only owner of the dry/wet sums. It accepts signed
24-bit dry, chorus-wet, and reverb-wet samples. The four routing and return
gains are nonnegative Q1.15 values clamped to `0..0x7fff`; `0x7fff` uses an
exact bypass instead of multiplying, so default dry routing and unity returns
do not lose one least-significant step. A gain above `0x7fff` sets the sticky
configuration-clamped diagnostic.

The reverb input is evaluated when the chorus output is accepted:

```text
reverb_input = saturate24(
    scale_q1_15(dry, reverb_input_send)
  + scale_q1_15(chorus_wet, chorus_to_reverb))
```

The final return is evaluated when the reverb output is accepted:

```text
effect_mix = saturate24(
    dry
  + scale_q1_15(chorus_wet, chorus_return)
  + scale_q1_15(reverb_wet, reverb_return))
```

For gains below `0x7fff`, `scale_q1_15(sample, gain)` is the wide signed product
shifted arithmetically right by 15 bits. Negative values therefore round toward
negative infinity. Each sum retains all product bits and saturates only once at
its signed-24 boundary. A saturating 32-bit counter records each channel that
saturates in either the committed reverb-input route or final return mix.

`global_effects_chain` is the internal signed-24 spatial-effects segment. It
accepts at most one frame at a time, snapshots both complete configurations with
the dry input, and sequences chorus, reverb, and return-mixer handshakes. Delay
state advances once per accepted frame regardless of output stalls. The dry
sample and chorus wet result remain registered until the matching reverb result
and final mixed output retire. The two effect-clear bits independently clear
chorus and reverb state; either bit also drops an in-flight spatial frame and
clears return-mixer diagnostics.

`global_audio_effects_chain` is the complete user-visible processing chain. It
feeds the signed-24 spatial result into `lookahead_compressor`, which also owns
master gain and final PCM16 saturation. The compressor remains a distinct inner
module because its output format and look-ahead fill semantics differ from the
wet processors, but system integration uses the unified wrapper rather than
constructing two unrelated paths. Effect clear does not reset compressor
look-ahead, gain-reduction history, or compressor diagnostics.

### Compressor dBFS Reference

The compressor uses the PCM16 numerical full scale as its dBFS reference even
though its input and delay line are signed 24-bit. For each undelayed stereo mix
frame it computes the instantaneous linked peak

```text
A = max(abs(mix_l), abs(mix_r))
level_dBFS = 20 * log10(A / 32768)
level_cBFS = 200 * log10(A / 32768)
```

Thus magnitude `32768` is exactly `0 dBFS`, `16384` is approximately
`-6.0206 dBFS`, and `65536` is approximately `+6.0206 dBFS`. Signed PCM16's
positive maximum `32767` is approximately `-0.00027 dBFS`; its negative maximum
`-32768` has magnitude `32768` and is exactly `0 dBFS`. The signed 24-bit mix may
legitimately exceed PCM16 full scale, up to approximately `+48.16 dBFS`, so the
detector can measure overload before final saturation. It is not referenced to
24-bit full scale.

This is a per-frame sample-peak detector, not RMS, LUFS, or a windowed energy
measurement. There is no detector averaging. Attack and release smooth the gain
reduction after the current peak has been converted to level. The detector is
before compressor gain, master volume, and PCM16 saturation, so changing master
volume does not change whether compression is triggered.

The LZC plus normalized-mantissa table approximates the formula above in signed
cB Q12.20. A configured threshold is stored as positive attenuation `T`; the
compressor is above threshold when `level_cBFS + T > 0`. For example, `T = 20 cB`
means `-2 dBFS`, corresponding to magnitude approximately `26029`. With a 4:1
ratio the target reduction is `(level_cBFS + T) * (1 - 1/4)`. As a concrete
check, magnitude `26603` is approximately `-1.81 dBFS`; it is about `0.19 dB`
above that threshold and produces approximately `0.14 dB` target reduction.

Threshold, gain reduction, and attack/release steps are unsigned cB Q12.20; the
ratio field is the unsigned Q0.16 slope `1 - 1/ratio`. Gain is applied to the
sample leaving the fixed delay, and left and right always receive the same gain.

Master volume is a nonnegative signed Q1.15 gain applied after compressor gain.
The two gain products use explicit wide signed intermediates and are shifted
only after multiplication. Saturation back to signed 16-bit PCM happens once,
after both gains and before the final output FIFO. `0x7fff` has an exact bypass
path so the default does not attenuate samples by one Q1.15 least-significant
step.

The C++ `LookaheadCompressorModel` mirrors these integer boundaries and exposes
output validity with `std::optional`: the first look-ahead frames update detector
state and fill the delay without producing PCM. `ReferenceSynth::render_mix()`
provides its unsaturated accumulator for feeding this model without changing the
existing bare-core `render_sample()` contract.

## Current Voice Render Calculation

The current renderer accepts blocks of up to eight frames. The controller reads
one atomic voice snapshot, and tagged envelope/phase/memory/DSP stages may work
on different voices at the same time. Each hardware voice is one mono lane; an
SF2 stereo pair is represented by two host-owned mono lanes.

For each contributing voice:

```text
frame_0 = phase[31:8]
fraction = phase[7:0]
```

Endpoint frame selection uses the active loop mode:

```text
loop_active = (loop_mode == continuous) ||
              ((loop_mode == until_release) && (released == 0))

if loop_active:
  frame_1 = (frame_0 + 1 >= loop_end) ? loop_start : frame_0 + 1
else:
  frame_1 = (frame_0 + 1 >= length) ? frame_0 : frame_0 + 1
```

The phase advances after `frame_0`, `frame_1`, and `fraction` are captured:

```text
phase_sum = phase + phase_inc

if loop_active && phase_sum >= (loop_end << 8):
  phase_next = phase_sum - ((loop_end - loop_start) << 8)
else:
  phase_next = phase_sum[31:0]
```

V1 requires `phase_inc` to be smaller than the active loop length in Q24.8
units, so one subtraction is sufficient. A no-loop voice, or a released
loop-until-release voice, stops when its phase reaches `length`.

Memory addressing is in signed 16-bit words using 32-bit base addresses and
24-bit frame offsets:

```text
sample_0 = mem[base_addr + frame_0]
sample_1 = mem[base_addr + frame_1]
```

The mono sample is interpolated once:

```text
interpolated = sample_0 + (((sample_1 - sample_0) * fraction) >>> 8)
```

If enabled, the mono interpolated sample passes through the voice's single
biquad history. Otherwise it is sign-extended into the 20-bit sample path:

```text
selected = filter_enable ? biquad(interpolated) : interpolated
```

Runtime channel gain and envelope level are then applied as one output scaling
step. The value `0x7fff` is a special full-level envelope bypass to preserve
exact channel-gain samples:

```text
if envelope_level == 0x7fff:
  voice_l = saturate_pcm((selected * gain_l) >>> 15)
  voice_r = saturate_pcm((selected * gain_r) >>> 15)
else:
  voice_l = saturate_pcm((selected * gain_l * envelope_level) >>> 30)
  voice_r = saturate_pcm((selected * gain_r * envelope_level) >>> 30)
```

All contributing voices are accumulated in signed 32-bit integer PCM units:

```text
accum_l += sign_extend_32(voice_l)
accum_r += sign_extend_32(voice_r)
```

The mix bank keeps signed 32-bit accumulators and publishes their low signed
24-bit values to the future effects/output path:

```text
mix_l = accum_l[23:0]
mix_r = accum_r[23:0]
```

The implemented order is therefore:

```text
phase/frame selection
  -> memory endpoint fetch
  -> linear interpolation
  -> optional biquad filter
  -> combined channel gain and envelope/full-level bypass
  -> 32-bit mix accumulation
  -> signed 24-bit published mix
```
