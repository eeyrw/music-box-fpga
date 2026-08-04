#!/usr/bin/env python3
import argparse
import math
from pathlib import Path


CB_MAX = 1000
Q15_FULL = 32767
CB_Q20_SCALE = 1 << 20
CB_TO_Q15_GUARD_BITS = 8
CB_TO_Q15_RESIDUAL_STEP_Q20 = 1 << 19
CB_TO_Q15_RESIDUAL_LAST_INDEX = 120
CB_TO_Q15_MAX_INTEGER_ERROR = 100
Q15_TO_CB_MANTISSA_BITS = 6
Q15_TO_CB_MANTISSA_SIZE = 1 << Q15_TO_CB_MANTISSA_BITS
Q15_TO_CB_MAX_ERROR_CB = 0.68
MAG_TO_CB_MANTISSA_BITS = 7
MAG_TO_CB_MANTISSA_SIZE = 1 << MAG_TO_CB_MANTISSA_BITS
MAG_TO_CB_MAX_ERROR_CB = 0.35
MAG_TO_CB_REFERENCE_EXPONENT = 15
MAG_TO_CB_INDEX_SHIFT = 31 - MAG_TO_CB_MANTISSA_BITS
MAG_TO_CB_ROUND_BIT = MAG_TO_CB_INDEX_SHIFT - 1
FDN_DELAY_LENGTHS = [1451, 1559, 1663, 1777, 1879, 1999, 2131, 2371]
SV_OUT = Path("rtl/generated/synth_dsp_lut_pkg.sv")
CPP_OUT = Path("sim/harness/generated/dsp_lut.h")
MCU_MSF2_OUT = Path("mcu/generated/msf2_lut.h")
MCU_MSF2_PROFILE = "generic-le32-48k-tick48-v15"


def round_away(value):
    return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)


def msf2_source_curves_q16():
    def concave(value):
        if value <= 0:
            return 0.0
        if value >= 127:
            return 1.0
        return (-400.0 / 960.0) * math.log10((127 - value) / 127.0)

    def convex(value):
        if value <= 0:
            return 0.0
        if value >= 127:
            return 1.0
        return 1.0 - (-400.0 / 960.0) * math.log10(value / 127.0)

    result = []
    for curve in range(16):
        curve_type = curve & 3
        bipolar = (curve & 4) != 0
        negative = (curve & 8) != 0
        row = []
        for value in range(128):
            directed = 127 - value if negative else value
            x = directed / 128.0
            shaped = x
            if bipolar:
                bipolar_value = -1.0 + 2.0 * x
                magnitude = abs(bipolar_value)
                native = round_away(magnitude * 128.0)
                if curve_type == 1:
                    curved = concave(native)
                    shaped = min(curved, 127.0 / 128.0) if bipolar_value >= 0 else -curved
                elif curve_type == 2:
                    curved = convex(native)
                    shaped = min(curved, 127.0 / 128.0) if bipolar_value >= 0 else -curved
                elif curve_type == 3:
                    shaped = 1.0 if bipolar_value >= 0 else -1.0
                else:
                    shaped = bipolar_value
            elif curve_type == 1:
                shaped = min(concave(directed), 127.0 / 128.0)
            elif curve_type == 2:
                shaped = min(convex(directed), 127.0 / 128.0)
            elif curve_type == 3:
                shaped = 1.0 if x >= 0.5 else 0.0
            row.append(round_away(shaped * (1 << 16)))
        result.append(row)
    return result


def chorus_sine_quarter_q15():
    return [
        int(round(Q15_FULL * math.sin((math.pi * index) / 512.0)))
        for index in range(257)
    ]


def fdn_delay_bases():
    bases = []
    offset = 0
    for length in FDN_DELAY_LENGTHS:
        bases.append(offset)
        offset += length
    return bases


def octave_q20():
    return int(round(200.0 * math.log10(2.0) * CB_Q20_SCALE))


def octave_lut():
    octave = octave_q20()
    return [index * octave for index in range(17)]


def cb_to_q15_mantissa():
    scale = Q15_FULL << CB_TO_Q15_GUARD_BITS
    return [
        int(round(scale * math.pow(10.0, -(index * 0.5) / 200.0)))
        for index in range(CB_TO_Q15_RESIDUAL_LAST_INDEX + 1)
    ]


def approximate_cb_to_q15(cb_q20, octaves, mantissa):
    if cb_q20 >= CB_MAX * CB_Q20_SCALE:
        return 0
    exponent = max(index for index, threshold in enumerate(octaves)
                   if threshold <= cb_q20)
    residual = cb_q20 - octaves[exponent]
    index = min(
        CB_TO_Q15_RESIDUAL_LAST_INDEX,
        (residual + CB_TO_Q15_RESIDUAL_STEP_Q20 // 2)
        // CB_TO_Q15_RESIDUAL_STEP_Q20,
    )
    scaled = mantissa[index] >> exponent
    return (scaled + (1 << (CB_TO_Q15_GUARD_BITS - 1))) >> CB_TO_Q15_GUARD_BITS


def validate_cb_to_q15(octaves, mantissa):
    max_integer_error = 0
    previous = Q15_FULL
    for cb_q8 in range(CB_MAX * 256 + 1):
        cb = cb_q8 / 256.0
        exact = 0 if cb >= CB_MAX else int(round(
            Q15_FULL * math.pow(10.0, -cb / 200.0)
        ))
        approx = approximate_cb_to_q15(cb_q8 << 12, octaves, mantissa)
        if approx > previous:
            raise RuntimeError("centibel-to-Q15 approximation is not monotonic")
        previous = approx
        max_integer_error = max(max_integer_error, abs(approx - exact))

    if max_integer_error > CB_TO_Q15_MAX_INTEGER_ERROR:
        raise RuntimeError(
            f"centibel-to-Q15 maximum integer error {max_integer_error} exceeds "
            f"{CB_TO_Q15_MAX_INTEGER_ERROR}"
        )
    return max_integer_error


def exact_q15_to_cb_q20(level):
    return int(round(-200.0 * math.log10(level / Q15_FULL) * CB_Q20_SCALE))


def q15_to_cb_tables():
    octave = octave_q20()
    residuals = [[] for _ in range(Q15_TO_CB_MANTISSA_SIZE)]

    for level in range(1, Q15_FULL):
        leading_zeros = 14 - (level.bit_length() - 1)
        normalized = level << leading_zeros
        index = (normalized >> (14 - Q15_TO_CB_MANTISSA_BITS)) & (
            Q15_TO_CB_MANTISSA_SIZE - 1
        )
        residuals[index].append(
            exact_q15_to_cb_q20(level) - leading_zeros * octave
        )

    mantissa = []
    for bucket in residuals:
        if not bucket:
            raise RuntimeError("empty Q15-to-centibel mantissa bucket")
        mantissa.append((min(bucket) + max(bucket) + 1) // 2)

    return mantissa


def validate_q15_to_cb(octave_lut, mantissa):
    max_error_q20 = 0
    total_error_q20 = 0
    for level in range(1, Q15_FULL):
        leading_zeros = 14 - (level.bit_length() - 1)
        normalized = level << leading_zeros
        index = (normalized >> (14 - Q15_TO_CB_MANTISSA_BITS)) & (
            Q15_TO_CB_MANTISSA_SIZE - 1
        )
        approx = octave_lut[leading_zeros] + mantissa[index]
        error = abs(approx - exact_q15_to_cb_q20(level))
        max_error_q20 = max(max_error_q20, error)
        total_error_q20 += error

    max_error_cb = max_error_q20 / CB_Q20_SCALE
    if max_error_cb > Q15_TO_CB_MAX_ERROR_CB:
        raise RuntimeError(
            f"Q15-to-centibel maximum error {max_error_cb:.6f} cB exceeds "
            f"{Q15_TO_CB_MAX_ERROR_CB:.6f} cB"
        )
    return max_error_cb, total_error_q20 / ((Q15_FULL - 1) * CB_Q20_SCALE)


def magnitude_to_cb_mantissa():
    return [
        int(round(200.0 * math.log10(
            1.0 + index / MAG_TO_CB_MANTISSA_SIZE
        ) * CB_Q20_SCALE))
        for index in range(MAG_TO_CB_MANTISSA_SIZE + 1)
    ]


def approximate_magnitude_to_cb_q20(magnitude, mantissa):
    if magnitude <= 0:
        raise ValueError("magnitude must be positive")
    exponent = magnitude.bit_length() - 1
    normalized = magnitude << (31 - exponent)
    index = (
        ((normalized >> (31 - MAG_TO_CB_MANTISSA_BITS)) &
         (MAG_TO_CB_MANTISSA_SIZE - 1)) +
        ((normalized >> (30 - MAG_TO_CB_MANTISSA_BITS)) & 1)
    )
    return ((exponent - 15) * octave_q20()) + mantissa[index]


def exact_magnitude_to_cb_q20(magnitude):
    return int(round(
        200.0 * math.log10(magnitude / float(1 << 15)) * CB_Q20_SCALE
    ))


def validate_magnitude_to_cb(mantissa):
    max_error_q20 = 0
    previous = None
    # Quantization error depends only on the normalized mantissa. Checking every
    # rounding boundary at every exponent also covers the octave transitions.
    for exponent in range(32):
        unit_shift = max(0, exponent - MAG_TO_CB_MANTISSA_BITS - 1)
        unit = 1 << unit_shift
        candidates = {1 << exponent, (1 << (exponent + 1)) - 1}
        for index in range(MAG_TO_CB_MANTISSA_SIZE * 2 + 1):
            base = (1 << exponent) + index * unit
            for magnitude in (base - 1, base, base + 1):
                if (1 << exponent) <= magnitude < (1 << (exponent + 1)):
                    candidates.add(magnitude)
        for magnitude in sorted(candidates):
            approx = approximate_magnitude_to_cb_q20(magnitude, mantissa)
            exact = exact_magnitude_to_cb_q20(magnitude)
            if previous is not None and approx < previous:
                raise RuntimeError("magnitude-to-centibel approximation is not monotonic")
            previous = approx
            max_error_q20 = max(max_error_q20, abs(approx - exact))

    max_error_cb = max_error_q20 / CB_Q20_SCALE
    if max_error_cb > MAG_TO_CB_MAX_ERROR_CB:
        raise RuntimeError(
            f"magnitude-to-centibel maximum error {max_error_cb:.6f} cB exceeds "
            f"{MAG_TO_CB_MAX_ERROR_CB:.6f} cB"
        )
    return max_error_cb


def append_sv_array(lines, declaration, vals, columns, width=32):
    lines.append(declaration)
    for idx in range(0, len(vals), columns):
        chunk = vals[idx:idx + columns]
        suffix = "," if idx + columns < len(vals) else ""
        lines.append(
            "    " + ", ".join(f"{width}'d{value}" for value in chunk) + suffix
        )
    lines.append("  };")


def render_sv(octaves, cb_mantissa, q15_mantissa, mag_mantissa, chorus_sine,
              fdn_bases,
              max_integer_error, max_error_cb, mean_error_cb,
              mag_max_error_cb):
    lines = [
        "// Generated by tools/gen_dsp_lut.py.",
        "// Do not edit by hand.",
        f"// Centibel-to-Q15 max integer error: {max_integer_error}.",
        f"// Q15-to-centibel max/mean error: {max_error_cb:.6f}/{mean_error_cb:.6f} cB.",
        f"// Magnitude-to-centibel max error: {mag_max_error_cb:.6f} cB.",
        "/* verilator lint_off UNUSEDPARAM */",
        "package synth_dsp_lut_pkg;",
        f"  localparam logic [31:0] ENV_CB_SILENCE_Q12_20 = 32'd{CB_MAX << 20};",
    ]
    lines.append(f"  localparam int ENV_CB_TO_Q15_GUARD_BITS = {CB_TO_Q15_GUARD_BITS};")
    lines.append("  localparam int ENV_CB_TO_Q15_RESIDUAL_INDEX_SHIFT = 19;")
    append_sv_array(
        lines,
        f"  localparam logic [31:0] ENV_CB_OCTAVE_Q12_20_LUT [0:{len(octaves) - 1}] = '{{",
        octaves,
        4,
    )
    append_sv_array(
        lines,
        f"  localparam logic [23:0] ENV_CB_TO_Q15_MANTISSA_LUT [0:{len(cb_mantissa) - 1}] = '{{",
        cb_mantissa,
        4,
        24,
    )
    lines.append(f"  localparam int ENV_Q15_TO_CB_MANTISSA_BITS = {Q15_TO_CB_MANTISSA_BITS};")
    append_sv_array(
        lines,
        f"  localparam logic [31:0] ENV_Q15_TO_CB_MANTISSA_LUT [0:{len(q15_mantissa) - 1}] = '{{",
        q15_mantissa,
        4,
    )
    lines.append(f"  localparam logic [31:0] COMP_CB_SILENCE_Q12_20 = 32'd{CB_MAX << 20};")
    lines.append(f"  localparam int COMP_CB_TO_Q15_GUARD_BITS = {CB_TO_Q15_GUARD_BITS};")
    lines.append("  localparam int COMP_CB_TO_Q15_RESIDUAL_INDEX_SHIFT = 19;")
    append_sv_array(
        lines,
        f"  localparam logic [31:0] COMP_CB_OCTAVE_Q12_20_LUT [0:{len(octaves) - 1}] = '{{",
        octaves,
        4,
    )
    append_sv_array(
        lines,
        f"  localparam logic [23:0] COMP_CB_TO_Q15_MANTISSA_LUT [0:{len(cb_mantissa) - 1}] = '{{",
        cb_mantissa,
        4,
        24,
    )
    lines.append(f"  localparam int COMP_MAG_TO_CB_MANTISSA_BITS = {MAG_TO_CB_MANTISSA_BITS};")
    lines.append(f"  localparam int COMP_MAG_TO_CB_REFERENCE_EXPONENT = {MAG_TO_CB_REFERENCE_EXPONENT};")
    lines.append(f"  localparam int COMP_MAG_TO_CB_INDEX_SHIFT = {MAG_TO_CB_INDEX_SHIFT};")
    lines.append(f"  localparam int COMP_MAG_TO_CB_ROUND_BIT = {MAG_TO_CB_ROUND_BIT};")
    append_sv_array(
        lines,
        f"  localparam logic [25:0] COMP_MAG_TO_CB_MANTISSA_LUT [0:{len(mag_mantissa) - 1}] = '{{",
        mag_mantissa,
        4,
        26,
    )
    append_sv_array(
        lines,
        "  localparam logic [15:0] CHORUS_SINE_QUARTER_Q1_15_LUT [0:256] = '{",
        chorus_sine,
        8,
        16,
    )
    lines.append(f"  localparam int FDN_LINE_COUNT = {len(FDN_DELAY_LENGTHS)};")
    lines.append(f"  localparam int FDN_TOTAL_SAMPLES = {sum(FDN_DELAY_LENGTHS)};")
    append_sv_array(
        lines,
        "  localparam logic [15:0] FDN_DELAY_LENGTH_LUT [0:7] = '{",
        FDN_DELAY_LENGTHS,
        8,
        16,
    )
    append_sv_array(
        lines,
        "  localparam logic [15:0] FDN_DELAY_BASE_LUT [0:7] = '{",
        fdn_bases,
        8,
        16,
    )
    lines.extend([
        "endpackage",
        "/* verilator lint_on UNUSEDPARAM */",
        "",
    ])
    return "\n".join(lines)


def append_cpp_array(lines, declaration, vals, columns):
    lines.append(declaration)
    for idx in range(0, len(vals), columns):
        chunk = vals[idx:idx + columns]
        suffix = "," if idx + columns < len(vals) else ""
        lines.append("    " + ", ".join(f"{value}u" for value in chunk) + suffix)
    lines.append("};")


def render_cpp(octaves, cb_mantissa, q15_mantissa, mag_mantissa, chorus_sine,
               fdn_bases,
               max_integer_error, max_error_cb, mean_error_cb,
               mag_max_error_cb):
    lines = [
        "// Generated by tools/gen_dsp_lut.py.",
        "// Do not edit by hand.",
        f"// Centibel-to-Q15 max integer error: {max_integer_error}.",
        f"// Q15-to-centibel max/mean error: {max_error_cb:.6f}/{mean_error_cb:.6f} cB.",
        f"// Magnitude-to-centibel max error: {mag_max_error_cb:.6f} cB.",
        "#pragma once",
        "",
        "#include <array>",
        "#include <cstdint>",
        "",
        "namespace render::dsp_lut {",
        f"constexpr uint32_t kEnvCbSilenceQ12_20 = {CB_MAX}u << 20;",
    ]
    lines.append(f"constexpr uint32_t kEnvCbToQ15GuardBits = {CB_TO_Q15_GUARD_BITS}u;")
    lines.append("constexpr uint32_t kEnvCbToQ15ResidualIndexShift = 19u;")
    append_cpp_array(
        lines,
        f"constexpr std::array<uint32_t, {len(octaves)}> kEnvCbOctaveQ12_20 = {{",
        octaves,
        4,
    )
    append_cpp_array(
        lines,
        "constexpr std::array<uint32_t, 257> kChorusSineQuarterQ1_15 = {",
        chorus_sine,
        8,
    )
    lines.append(f"constexpr uint32_t kFdnTotalSamples = {sum(FDN_DELAY_LENGTHS)}u;")
    append_cpp_array(
        lines,
        "constexpr std::array<uint32_t, 8> kFdnDelayLengths = {",
        FDN_DELAY_LENGTHS,
        8,
    )
    append_cpp_array(
        lines,
        "constexpr std::array<uint32_t, 8> kFdnDelayBases = {",
        fdn_bases,
        8,
    )
    append_cpp_array(
        lines,
        f"constexpr std::array<uint32_t, {len(cb_mantissa)}> kEnvCbToQ15Mantissa = {{",
        cb_mantissa,
        4,
    )
    lines.append(f"constexpr uint32_t kEnvQ15ToCbMantissaBits = {Q15_TO_CB_MANTISSA_BITS}u;")
    append_cpp_array(
        lines,
        f"constexpr std::array<uint32_t, {len(q15_mantissa)}> kEnvQ15ToCbMantissa = {{",
        q15_mantissa,
        4,
    )
    lines.append(f"constexpr uint32_t kCompCbSilenceQ12_20 = {CB_MAX}u << 20;")
    lines.append(f"constexpr uint32_t kCompCbToQ15GuardBits = {CB_TO_Q15_GUARD_BITS}u;")
    lines.append("constexpr uint32_t kCompCbToQ15ResidualIndexShift = 19u;")
    append_cpp_array(
        lines,
        f"constexpr std::array<uint32_t, {len(octaves)}> kCompCbOctaveQ12_20 = {{",
        octaves,
        4,
    )
    append_cpp_array(
        lines,
        f"constexpr std::array<uint32_t, {len(cb_mantissa)}> kCompCbToQ15Mantissa = {{",
        cb_mantissa,
        4,
    )
    lines.append(f"constexpr uint32_t kCompMagToCbMantissaBits = {MAG_TO_CB_MANTISSA_BITS}u;")
    lines.append(f"constexpr uint32_t kCompMagToCbReferenceExponent = {MAG_TO_CB_REFERENCE_EXPONENT}u;")
    lines.append(f"constexpr uint32_t kCompMagToCbIndexShift = {MAG_TO_CB_INDEX_SHIFT}u;")
    lines.append(f"constexpr uint32_t kCompMagToCbRoundBit = {MAG_TO_CB_ROUND_BIT}u;")
    append_cpp_array(
        lines,
        f"constexpr std::array<uint32_t, {len(mag_mantissa)}> kCompMagToCbMantissa = {{",
        mag_mantissa,
        4,
    )
    lines.extend([
        "}  // namespace render::dsp_lut",
        "",
    ])
    return "\n".join(lines)


def append_c_array(lines, declaration, vals, columns, formatter=str):
    lines.append(declaration)
    for idx in range(0, len(vals), columns):
        chunk = vals[idx:idx + columns]
        suffix = "," if idx + columns < len(vals) else ""
        lines.append("    " + ", ".join(formatter(value) for value in chunk) + suffix)
    lines.append("};")


def render_mcu_msf2():
    exp2_fraction = [round(math.pow(2.0, index / 256.0) * (1 << 32)) - (1 << 32)
                     for index in range(256)]
    pan_sine = [round(math.sin(index * math.pi / 512.0) * (1 << 30))
                for index in range(257)]
    source_curves = msf2_source_curves_q16()

    lines = [
        "// Generated by tools/gen_dsp_lut.py.",
        "// Do not edit by hand.",
        f"// Profile: {MCU_MSF2_PROFILE}.",
        "#ifndef MSF2_GENERATED_LUT_H",
        "#define MSF2_GENERATED_LUT_H",
        "",
        "#include <stdint.h>",
        "",
        "#define MSF2_LUT_SAMPLE_RATE 48000u",
        "#define MSF2_LUT_CONTROL_TICK_SAMPLES 48u",
        "#define MSF2_LUT_EXP2_MANTISSA_BITS 8u",
        "#define MSF2_LUT_EXP2_MANTISSA_COUNT 256u",
        "#define MSF2_LUT_PAN_QUARTER_COUNT 257u",
        "#define MSF2_LUT_SOURCE_CURVE_COUNT 16u",
        "#define MSF2_LUT_SOURCE_CURVE_SIZE 128u",
        "",
    ]
    append_c_array(lines, "static const uint32_t msf2_lut_exp2_fraction_q32[256] = {",
                   exp2_fraction, 8, lambda value: f"UINT32_C({value})")
    lines.append("")
    append_c_array(lines, "static const uint32_t msf2_lut_pan_quarter_sine_q30[257] = {",
                   pan_sine, 8, lambda value: f"UINT32_C({value})")
    lines.append("")
    lines.append("static const int32_t msf2_lut_source_curve_q16[16][128] = {")
    for curve, values in enumerate(source_curves):
        lines.append(f"    {{ /* curve {curve} */")
        for idx in range(0, len(values), 8):
            chunk = values[idx:idx + 8]
            suffix = "," if idx + 8 < len(values) else ""
            lines.append("        " + ", ".join(str(value) for value in chunk) + suffix)
        lines.append("    }," if curve != 15 else "    }")
    lines.append("};")
    lines.extend(["", "#endif", ""])
    return "\n".join(lines)


def generated_outputs():
    octaves = octave_lut()
    cb_mantissa = cb_to_q15_mantissa()
    q15_mantissa = q15_to_cb_tables()
    mag_mantissa = magnitude_to_cb_mantissa()
    chorus_sine = chorus_sine_quarter_q15()
    fdn_bases = fdn_delay_bases()
    max_integer_error = validate_cb_to_q15(octaves, cb_mantissa)
    max_error_cb, mean_error_cb = validate_q15_to_cb(octaves, q15_mantissa)
    mag_max_error_cb = validate_magnitude_to_cb(mag_mantissa)
    return {
        SV_OUT: render_sv(
            octaves,
            cb_mantissa,
            q15_mantissa,
            mag_mantissa,
            chorus_sine,
            fdn_bases,
            max_integer_error,
            max_error_cb,
            mean_error_cb,
            mag_max_error_cb,
        ),
        CPP_OUT: render_cpp(
            octaves,
            cb_mantissa,
            q15_mantissa,
            mag_mantissa,
            chorus_sine,
            fdn_bases,
            max_integer_error,
            max_error_cb,
            mean_error_cb,
            mag_max_error_cb,
        ),
        MCU_MSF2_OUT: render_mcu_msf2(),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify that generated outputs are current without rewriting them",
    )
    args = parser.parse_args()

    outputs = generated_outputs()
    if args.check:
        stale = [
            path for path, expected in outputs.items()
            if not path.exists() or path.read_text(encoding="utf-8") != expected
        ]
        if stale:
            paths = ", ".join(str(path) for path in stale)
            raise SystemExit(f"stale generated DSP LUT output: {paths}")
        return

    for path, contents in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")


if __name__ == "__main__":
    main()
