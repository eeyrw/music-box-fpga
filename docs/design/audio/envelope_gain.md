# Envelope Gain Conversion

## Purpose And Ownership

The SoundFont volume envelope crosses two numeric domains:

- Attack is a linear-amplitude Q0.32 accumulator.
- Decay, Sustain, and Release are Q12.20 centibel attenuation.
- The renderer consumes a linear Q1.15 envelope gain.

The FPGA therefore owns both conversions. `cb_to_q15` runs for rendered samples
in the logarithmic envelope stages. `q15_to_cb` runs only when a Release command
interrupts Attack, because the true Attack accumulator is FPGA state and cannot
be mirrored exactly across command queuing and frame boundaries. Moving
`cb_to_q15` to software would require per-voice, per-frame gain streaming and is
not a useful control-bandwidth trade.

The C++ reference synth implements the same integer algorithms. The shared DSP
table generator `tools/gen_dsp_lut.py` is the single source for both RTL and C++
tables. It also owns the normalized magnitude-log table used by global dynamics
processing; envelope logic only consumes the tables described below.

## SoundFont Contract

The local SoundFont specification is
`docs/reference/soundfont-2.04.pdf`. Generator descriptions
34 through 38 state that volume Attack is linear in amplitude, while Decay and
Release make a constant dB change per time unit. A full-scale Release reaches
zero after 100 dB, and 1000 cB conventionally represents full attenuation.
Section 9.1.7 also requires key-off to enter Release immediately from the current
envelope value.

The envelope silence threshold is therefore 1000 cB. The separate 960 cB values
used by the default velocity, MIDI volume, and expression modulators are their
specified modulation excursions and are not the envelope endpoint.

## Centibel To Linear Q1.15

The required nonlinear conversion is:

```text
gain_q15 = round(32767 * 10 ^ (-attenuation_cb / 200))
```

Range reduction uses one binary octave:

```text
OCTAVE_CB = 200 * log10(2) = 60.205999... cB
attenuation_cb = octave_count * OCTAVE_CB + residual_cb
gain = 2 ^ (-octave_count) * 10 ^ (-residual_cb / 200)
```

Hardware performs these steps:

1. A five-level threshold search selects `octave_count` in `0..16`.
2. Subtract the generated Q12.20 octave threshold.
3. Round the residual to a 0.5 cB index in `0..120`.
4. Read a 24-bit mantissa scaled by `32767 * 2^8`.
5. Right-shift by `octave_count`, add the fixed Q1.15 rounding bias, and discard
   the eight guard bits.

The structure uses no multiplier or divider. The guard bits preserve useful
rounding precision after large octave shifts. Inputs at or above 1000 cB return
zero before table access. Snapshot conversion is split across three registered
stages: octave/residual/index selection, mantissa lookup, then shift/round/output.
The control plane exposes an explicit prepare/valid handshake, so the renderer
never consumes a combinational table result or assumes a fixed RAM read shortcut.

The generator samples the complete `0..1000 cB` range at 1/256 cB intervals,
requires monotonic output, and compares against direct floating-point evaluation
rounded to Q1.15. The committed table has a maximum difference of 94 Q1.15
integer units; the enforced limit is 100. At low gains, relative dB error is not
a useful metric because Q1.15 itself has only one or two nonzero codes.

## Linear Q1.15 To Centibel

The inverse needed at an Attack-to-Release transition is:

```text
attenuation_cb = -200 * log10(level_q15 / 32767)
```

For every positive value below full scale, a 15-bit leading-zero encoder moves
the highest set bit to bit 14. The leading-zero count is the binary exponent and
selects the same octave threshold table used by `cb_to_q15`. Bits 13 through 8
of the normalized value select a 64-entry logarithmic mantissa correction table:

```text
attenuation_q12_20 = octave_table[leading_zeros]
                     + log_mantissa_table[normalized[13:8]]
```

Full scale maps to zero attenuation. Zero and negative values map to the 1000 cB
silence threshold. The generator exhaustively checks all 32766 positive,
non-full-scale Q1.15 inputs. The committed table has maximum error 0.670729 cB
and mean absolute error 0.236128 cB; the enforced maximum is 0.68 cB.

## Release State Selection

Only Release from Attack requires `q15_to_cb`. Other stages already have an
exact logarithmic-domain starting point:

```text
Delay                 -> 1000 cB
Attack                -> q15_to_cb(attack_level)
Hold                  -> 0 cB
Decay/Sustain/Release -> retain attenuation_q12_20
```

This state selection keeps logarithmic stages in their native representation and
performs an inverse conversion only when the source state is linear.

## Smart Artix Synthesis

A forced non-incremental Vivado 2025.2 synthesis for `xc7a50tfgg484-2` reports
18 DSP48E1 blocks for the complete design. None belongs to either envelope
conversion. The generated conversion data appears as the shared octave and
inverse-mantissa tables plus the registered forward-mantissa lookup.

The complete post-synthesis result is 13,758 LUTs, 12,335 flip-flops, 17 BRAM
tiles, and 18 DSPs. Post-synthesis WNS is -2.886 ns; the worst setup path is in
the active voice RAM write path rather than either conversion pipeline. DRC
reports zero errors and zero critical warnings. These figures are an
optimization checkpoint, not post-route timing closure.

The current 2026-07-30 routed implementation provides a more precise lookup
mapping result. `ENV_CB_TO_Q15_MANTISSA_LUT` occupies one `RAMB18E1` after being
normalized to 128 x 23, and `ENV_Q15_TO_CB_MANTISSA_LUT` occupies one
`RAMB18E1` after being normalized to 64 x 26. The shared 17-entry octave table
is implemented as Slice LUT logic at each combinational read site. It is not a
large flip-flop array. The complete method, generated-table inventory, physical
primitive check, and current resource interpretation are recorded in
`docs/verification/vivado_synthesis_timing.md` under "Generated Lookup-ROM
Mapping Audit".

## Verification

Run the following checks after changing the algorithm or table precision:

```text
python3 tools/gen_dsp_lut.py
make check-dsp-lut
make lint
make test
```

Then run a forced Smart Artix synthesis and inspect both the total report and the
`control_action_executor` hierarchy. Confirm that no envelope-conversion DSP or
divider is inferred and record LUT, FF, DSP, BRAM, WNS, the worst path, and DRC
counts here when the implementation changes.

Use a non-incremental Vivado rebuild when changing either conversion function so
the report is guaranteed to describe the current generated tables and RTL.
