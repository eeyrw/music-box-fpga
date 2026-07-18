#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def parse_int(value):
    if isinstance(value, int):
        return value
    return int(value, 0)


def sv_hex(value, width):
    digits = (width + 3) // 4
    return f"{width}'h{value:0{digits}x}"


def cpp_hex(value, width):
    digits = (width + 3) // 4
    return f"0x{value:0{digits}x}"


def macro_name(prefix, name):
    return f"{prefix}_{name}"


def load_spec(path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def render_sv(spec):
    addr_width = parse_int(spec["bus"]["address_width"])
    data_width = parse_int(spec["bus"]["data_width"])
    version_value = parse_int(spec["version"]["value"])
    voice_base = parse_int(spec["voice_window"]["base"])
    voice_stride = parse_int(spec["voice_window"]["stride"])

    lines = [
        "// Generated from spec/register_map.json by tools/gen_register_map.py.",
        "// Do not edit by hand.",
        "/* verilator lint_off UNUSEDPARAM */",
        "/* verilator lint_off UNUSEDSIGNAL */",
        "package synth_register_pkg;",
        f"  localparam int REG_BUS_ADDR_WIDTH = {addr_width};",
        f"  localparam int REG_BUS_DATA_WIDTH = {data_width};",
        f"  localparam logic [31:0] REG_VERSION_VALUE = {sv_hex(version_value, 32)};",
        f"  localparam logic [15:0] REG_VOICE_BASE = {sv_hex(voice_base, 16)};",
        f"  localparam logic [15:0] REG_VOICE_STRIDE = {sv_hex(voice_stride, 16)};",
        "",
    ]

    for reg in spec["voice_registers"]:
        name = reg["name"]
        offset = parse_int(reg["offset"])
        lines.append(f"  localparam logic [15:0] REG_OFF_{name} = {sv_hex(offset, 16)};")

    lines.append("")
    for reg in spec["global_registers"]:
        name = reg["name"]
        address = parse_int(reg["address"])
        lines.append(f"  localparam logic [15:0] REG_{name} = {sv_hex(address, 16)};")

    lines.append("")
    for group, fields in spec["fields"].items():
        for name, value in fields.items():
            parsed = parse_int(value)
            if name.endswith("_BIT") or name.endswith("_LSB") or name.endswith("_WIDTH"):
                lines.append(f"  localparam int REG_{group}_{name} = {parsed};")
            else:
                lines.append(f"  localparam logic [31:0] REG_{group}_{name} = {sv_hex(parsed, 32)};")

    lines.append("")
    for name, value in spec["numeric_constants"].items():
        lines.append(f"  localparam logic [31:0] REG_{name} = {sv_hex(parse_int(value), 32)};")

    lines.extend([
        "",
        "  function automatic logic [15:0] reg_voice_addr(input logic [15:0] voice, input logic [15:0] offset);",
        "    reg_voice_addr = REG_VOICE_BASE + (voice * REG_VOICE_STRIDE) + offset;",
        "  endfunction",
        "endpackage",
        "/* verilator lint_on UNUSEDSIGNAL */",
        "/* verilator lint_on UNUSEDPARAM */",
        "",
    ])
    return "\n".join(lines)


def render_cpp(spec):
    addr_width = parse_int(spec["bus"]["address_width"])
    data_width = parse_int(spec["bus"]["data_width"])
    version_value = parse_int(spec["version"]["value"])
    voice_base = parse_int(spec["voice_window"]["base"])
    voice_stride = parse_int(spec["voice_window"]["stride"])

    lines = [
        "// Generated from spec/register_map.json by tools/gen_register_map.py.",
        "// Do not edit by hand.",
        "#pragma once",
        "",
        "#include <cstdint>",
        "",
        "namespace render::regs {",
        f"constexpr int kBusAddrWidth = {addr_width};",
        f"constexpr int kBusDataWidth = {data_width};",
        f"constexpr uint32_t kVersionValue = {cpp_hex(version_value, 32)}u;",
        f"constexpr uint16_t kVoiceBase = {cpp_hex(voice_base, 16)}u;",
        f"constexpr uint16_t kVoiceStride = {cpp_hex(voice_stride, 16)}u;",
        "",
    ]

    for reg in spec["voice_registers"]:
        name = reg["name"]
        offset = parse_int(reg["offset"])
        lines.append(f"constexpr uint16_t kOff{name.title().replace('_', '')} = {cpp_hex(offset, 16)}u;")

    lines.append("")
    for reg in spec["global_registers"]:
        name = reg["name"]
        address = parse_int(reg["address"])
        lines.append(f"constexpr uint16_t k{name.title().replace('_', '')} = {cpp_hex(address, 16)}u;")

    lines.append("")
    for group, fields in spec["fields"].items():
        group_name = group.title().replace("_", "")
        for name, value in fields.items():
            field_name = name.title().replace("_", "")
            parsed = parse_int(value)
            if name.endswith("_BIT") or name.endswith("_LSB") or name.endswith("_WIDTH"):
                lines.append(f"constexpr int k{group_name}{field_name} = {parsed};")
            else:
                lines.append(f"constexpr uint32_t k{group_name}{field_name} = {cpp_hex(parsed, 32)}u;")

    lines.append("")
    for name, value in spec["numeric_constants"].items():
        lines.append(f"constexpr uint32_t k{name.title().replace('_', '')} = {cpp_hex(parse_int(value), 32)}u;")

    lines.extend([
        "",
        "constexpr uint16_t voice_addr(int voice, uint16_t offset) {",
        "  return uint16_t(kVoiceBase + voice * kVoiceStride + offset);",
        "}",
        "",
        "}  // namespace render::regs",
        "",
    ])
    return "\n".join(lines)


def write_if_changed(path, text):
    if path.exists() and path.read_text(encoding="utf-8") == text:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", default="spec/register_map.json")
    parser.add_argument("--sv-out", default="rtl/pkg/synth_register_pkg.sv")
    parser.add_argument("--cpp-out", default="sim/harness/generated/register_map.h")
    args = parser.parse_args()

    spec = load_spec(Path(args.spec))
    write_if_changed(Path(args.sv_out), render_sv(spec))
    write_if_changed(Path(args.cpp_out), render_cpp(spec))


if __name__ == "__main__":
    main()
