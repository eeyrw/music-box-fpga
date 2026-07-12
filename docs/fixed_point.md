# Fixed-Point Formats

## Audio Samples

Wave memory and output samples are signed 16-bit PCM. DSP blocks treat them as
Q1.15 values. Intermediate interpolation and gain calculations retain extra
bits and saturate only at the output boundary.

## Playback Phase

`phase` and `phase_inc` are unsigned Q16.16 values measured in sample frames.
The upper 16 bits select a frame and the lower 16 bits are the interpolation
fraction. For example, `0x0001_8000` identifies the point halfway between frame
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
value = sample_0 + ((delta * fraction) >>> 16)
```

The mathematical result remains in the signed 16-bit sample range.

## Gain

Left and right gains are signed Q1.15 values. `0x0000` is silence and `0x7fff`
is just below unity. Multiplication uses a signed 32-bit product, arithmetic
right shift by 15, and saturation to signed 16-bit PCM.

## Envelope Level

Each voice has a signed Q1.15 `envelope_level` applied after channel gain and
before mixing. Software supplies the current level at runtime; the RTL does not
calculate an SF2 ADSR curve. Updating `envelope_level` does not reload playback
phase. `0x7fff` means full level and is treated as a bypass to preserve exact
samples from the gain stage.

## Biquad IIR Filter

Each voice can enable a second-order IIR filter after interpolation and before
channel gain. Coefficients are signed Q4.28 values. `0x1000_0000` is unity,
`0x0800_0000` is 0.5, and negative feedback coefficients use two's-complement signed values.
The implemented transposed direct-form II equation is:

```text
y_q28 = b0 * x + z1
y     = saturate(y_q28 >>> 28)
z1    = saturate_i64(b1 * x - a1 * y + z2)
z2    = saturate_i64(b2 * x - a2 * y)
```

Software writes normalized coefficients as `b0`, `b1`, `b2`, `a1`, and `a2`, where
the denominator is `1 + a1*z^-1 + a2*z^-2`. Disabling the filter bypasses this
stage. Filter state is per voice and per channel, and is cleared on commit.

## Mixing

The multi-voice renderer accumulates signed 16-bit voice outputs in a signed
32-bit stereo accumulator. Saturation back to signed 16-bit PCM happens once, at
the final mixed output sample.

## Current Voice Render Calculation

At each `sample_tick`, the renderer snapshots active configuration and runtime
state for all voices. Register writes that arrive after this snapshot affect the
next output sample render. The renderer then scans voice slots in index order and
accumulates each enabled, valid, not-completed voice into one stereo output.

For each contributing voice:

```text
phase_now = phase[voice]
frame_0   = phase_now[31:16]
fraction  = phase_now[15:0]
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
phase_sum = phase_now + phase_inc_runtime

if loop_active && phase_sum >= (loop_end << 16):
  phase_next = phase_sum - ((loop_end - loop_start) << 16)
else:
  phase_next = phase_sum[31:0]
```

V1 requires `phase_inc_runtime < ((loop_end - loop_start) << 16)` for looped
voices so this single subtraction is sufficient. No-loop voices and released
loop-until-release voices stop contributing when `phase_now[31:16] >= length`.

Memory addressing is in signed 16-bit words:

```text
if stereo == 0:
  l0 = mem[base_addr + frame_0]
  l1 = mem[base_addr + frame_1]
  r0 = l0
  r1 = l1
else:
  l0 = mem[base_addr + 2*frame_0]
  l1 = mem[base_addr + 2*frame_1]
  r0 = mem[base_addr + 2*frame_0 + 1]
  r1 = mem[base_addr + 2*frame_1 + 1]
```

Interpolation is applied independently per channel:

```text
interp_l = l0 + (((l1 - l0) * fraction) >>> 16)
interp_r = r0 + (((r1 - r0) * fraction) >>> 16)
```

If the runtime filter is enabled, each channel then runs through the per-voice
biquad using that channel's filter history. If disabled, the interpolated sample
passes through unchanged:

```text
filter_in_l = interp_l
filter_in_r = interp_r

post_filter_l = filter_enable ? biquad_l(filter_in_l) : filter_in_l
post_filter_r = filter_enable ? biquad_r(filter_in_r) : filter_in_r
```

Channel gain is applied next using runtime gains:

```text
gained_l = saturate_pcm((post_filter_l * gain_l_runtime) >>> 15)
gained_r = saturate_pcm((post_filter_r * gain_r_runtime) >>> 15)
```

Envelope level is applied after channel gain. The value `0x7fff` is a special
full-level bypass to preserve exact gained samples:

```text
if envelope_level == 0x7fff:
  voice_l = gained_l
  voice_r = gained_r
else:
  voice_l = saturate_pcm((gained_l * envelope_level) >>> 15)
  voice_r = saturate_pcm((gained_r * envelope_level) >>> 15)
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
  -> channel gain
  -> envelope/full-level bypass
  -> 32-bit mix accumulation
  -> final 16-bit saturation
```
