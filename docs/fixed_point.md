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
gain before mixing. Software supplies the current level at runtime; the RTL does
not calculate an SF2 ADSR curve. Updating `envelope_level` does not reload
playback phase. `0x7fff` means full level and is treated as a bypass to preserve
exact samples from the channel-gain stage.

## Biquad IIR Filter

Each voice can enable a second-order IIR filter after interpolation and before
channel gain. Coefficients are signed 16-bit Q2.14 values packed into
`FILTER_B0_B1`, `FILTER_B2_A1`, and `FILTER_A2`. `0x4000` is unity, `0x2000` is
0.5, and negative feedback coefficients use two's-complement signed values.
`FILTER_A2[16]` is a write-only runtime commit strobe and is not part of the
coefficient value.
The implemented transposed direct-form II equation is:

```text
y_q14 = b0 * x + z1
y     = saturate_i20(y_q14 >>> 14)
z1    = saturate_i34(b1 * x - a1 * y + z2)
z2    = saturate_i34(b2 * x - a2 * y)
```

Software writes normalized coefficients as `b0`, `b1`, `b2`, `a1`, and `a2`, where
the denominator is `1 + a1*z^-1 + a2*z^-2`. Disabling the filter bypasses this
stage. Filter state is signed 34-bit Q14 per voice and per channel, and is
cleared on commit.

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
32-bit stereo accumulator. Saturation back to signed 16-bit PCM happens once, at
the final mixed output sample.

## Current Voice Render Calculation

At each accepted `sample_tick`, the renderer scans active voice slots in index
order. Committed configuration is stored in renderer-facing active storage, while
runtime registers remain live state. The renderer reads one voice snapshot at a
time through the register bank's synchronous read path and samples runtime values
when that voice is accepted for the current render. It accumulates each enabled,
valid, not-completed voice into one stereo output.

For each contributing voice:

```text
phase_l  = phase[voice]
phase_r  = phase_right[voice]      // stereo only; mono duplicates left samples
frame_l0 = phase_l[31:8]
frame_r0 = phase_r[31:8]
fraction = phase_l[7:0]
```

Endpoint frame selection uses the active loop mode:

```text
loop_active = (loop_mode == continuous) ||
              ((loop_mode == until_release) && (released == 0))

if loop_active:
  frame_l1 = (frame_l0 + 1 >= loop_end) ? loop_start : frame_l0 + 1
  frame_r1 = (frame_r0 + 1 >= loop_end_r) ? loop_start_r : frame_r0 + 1
else:
  frame_l1 = (frame_l0 + 1 >= length) ? frame_l0 : frame_l0 + 1
  frame_r1 = (frame_r0 + 1 >= length_r) ? frame_r0 : frame_r0 + 1
```

The phase advances after `frame_0`, `frame_1`, and `fraction` are captured:

```text
phase_l_sum = phase_l + phase_inc_runtime
phase_r_sum = phase_r + phase_inc_runtime

if loop_active && phase_l_sum >= (loop_end << 8):
  phase_l_next = phase_l_sum - ((loop_end - loop_start) << 8)
else:
  phase_l_next = phase_l_sum[31:0]

if stereo && loop_active && phase_r_sum >= (loop_end_r << 8):
  phase_r_next = phase_r_sum - ((loop_end_r - loop_start_r) << 8)
else:
  phase_r_next = phase_r_sum[31:0]
```

V1 requires `phase_inc_runtime` to be smaller than each active channel's loop
length in Q24.8 units, so this single subtraction is sufficient. No-loop voices
and released loop-until-release voices stop contributing when all active channels
have reached their configured length.

Memory addressing is in signed 16-bit words using 32-bit base addresses and
24-bit frame offsets:

```text
if stereo == 0:
  l0 = mem[base_addr + frame_l0]
  l1 = mem[base_addr + frame_l1]
  r0 = l0
  r1 = l1
else:
  l0 = mem[base_addr + frame_l0]
  l1 = mem[base_addr + frame_l1]
  r0 = mem[base_addr_r + frame_r0]
  r1 = mem[base_addr_r + frame_r1]
```

Interpolation is applied independently per channel:

```text
interp_l = l0 + (((l1 - l0) * fraction) >>> 8)
interp_r = r0 + (((r1 - r0) * fraction) >>> 8)
```

If the runtime filter is enabled, each channel then runs through the per-voice
biquad using that channel's filter history. If disabled, the interpolated sample
is sign-extended into the post-filter 20-bit sample path:

```text
filter_in_l = interp_l
filter_in_r = interp_r

post_filter_l = filter_enable ? biquad_l(filter_in_l) : filter_in_l
post_filter_r = filter_enable ? biquad_r(filter_in_r) : filter_in_r
```

Runtime channel gain and envelope level are then applied as one output scaling
step. The value `0x7fff` is a special full-level envelope bypass to preserve
exact channel-gain samples:

```text
if envelope_level == 0x7fff:
  voice_l = saturate_pcm((post_filter_l * gain_l_runtime) >>> 15)
  voice_r = saturate_pcm((post_filter_r * gain_r_runtime) >>> 15)
else:
  voice_l = saturate_pcm((post_filter_l * gain_l_runtime * envelope_level) >>> 30)
  voice_r = saturate_pcm((post_filter_r * gain_r_runtime * envelope_level) >>> 30)
```

All contributing voices are accumulated in signed 32-bit integer PCM units:

```text
accum_l += sign_extend_32(voice_l)
accum_r += sign_extend_32(voice_r)
```

After the last voice slot, the final stereo output is saturated once:

```text
sample_l = saturate_pcm(accum_l)
sample_r = saturate_pcm(accum_r)
```

The implemented order is therefore:

```text
phase/frame selection
  -> memory endpoint fetch
  -> linear interpolation
  -> optional biquad filter
  -> combined channel gain and envelope/full-level bypass
  -> 32-bit mix accumulation
  -> final 16-bit saturation
```
