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
`phase_inc` is added. If the result reaches the exclusive loop end, the loop
length is subtracted once. V1 therefore requires the increment to be smaller
than one loop length.

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

## Mixing

The multi-voice renderer accumulates signed 16-bit voice outputs in a signed
32-bit stereo accumulator. Saturation back to signed 16-bit PCM happens once, at
the final mixed output sample.
