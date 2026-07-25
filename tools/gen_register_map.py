#!/usr/bin/env python3
import argparse
import json
import sys
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


FIELD_GROUP_ORDER = [
    "COMMON_EVENT_FLAGS",
    "PLATFORM_STATUS",
    "DDR_ACCESS_CONTROL",
    "DDR_ACCESS_STATUS",
]


def load_spec(path):
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def normalize_spec(spec):
    if "device" not in spec:
        return spec

    device = spec["device"]
    normalized = {
        "bus": {
            "address_width": device["addressWidth"],
            "data_width": device["width"],
        },
        "global_registers": [],
        "fields": {},
        "numeric_constants": {},
    }

    for peripheral in device["peripherals"]:
        base = parse_int(peripheral["baseAddress"])
        for reg in peripheral["registers"]:
            address = base + parse_int(reg["addressOffset"])
            normalized["global_registers"].append({
                "name": reg["name"],
                "address": address,
            })
            if reg["name"] == "VERSION":
                normalized["version"] = {
                    "name": reg["name"],
                    "address": address,
                    "value": reg["resetValue"],
                }
            normalize_fields(normalized["fields"], reg)

    for constant in spec.get("constants", []):
        normalized["numeric_constants"][constant["name"]] = constant["value"]

    normalized["fields"] = order_field_groups(normalized["fields"])

    return normalized


def order_field_groups(groups):
    ordered = {}
    for name in FIELD_GROUP_ORDER:
        if name in groups:
            ordered[name] = groups[name]
    for name, fields in groups.items():
        if name not in ordered:
            ordered[name] = fields
    return ordered


def normalize_fields(groups, reg):
    fields = {}
    for field in reg.get("fields", []):
        name = field["name"]
        if "value" in field:
            fields[name] = field["value"]
        if "mask" in field:
            fields[f"{name}_MASK"] = field["mask"]
        elif "bitOffset" in field and "bitWidth" in field:
            offset = parse_int(field["bitOffset"])
            width = parse_int(field["bitWidth"])
            if width == 1:
                fields[f"{name}_BIT"] = offset
            else:
                fields[f"{name}_LSB"] = offset
                fields[f"{name}_WIDTH"] = width
    if fields:
        groups[reg["name"]] = fields


def render_sv(spec):
    spec = normalize_spec(spec)
    addr_width = parse_int(spec["bus"]["address_width"])
    data_width = parse_int(spec["bus"]["data_width"])
    version_value = parse_int(spec["version"]["value"])

    lines = [
        "// Generated from spec/register_map.json by tools/gen_register_map.py.",
        "// Do not edit by hand.",
        "/* verilator lint_off UNUSEDPARAM */",
        "/* verilator lint_off UNUSEDSIGNAL */",
        "package synth_register_pkg;",
        f"  localparam int REG_BUS_ADDR_WIDTH = {addr_width};",
        f"  localparam int REG_BUS_DATA_WIDTH = {data_width};",
        f"  localparam logic [31:0] REG_VERSION_VALUE = {sv_hex(version_value, 32)};",
        "",
    ]

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
        "endpackage",
        "/* verilator lint_on UNUSEDSIGNAL */",
        "/* verilator lint_on UNUSEDPARAM */",
        "",
    ])
    return "\n".join(lines)


def render_cpp(spec):
    spec = normalize_spec(spec)
    addr_width = parse_int(spec["bus"]["address_width"])
    data_width = parse_int(spec["bus"]["data_width"])
    version_value = parse_int(spec["version"]["value"])

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
        "",
    ]

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
        "}  // namespace render::regs",
        "",
    ])
    return "\n".join(lines)


def write_if_changed(path, text):
    if path.exists() and path.read_text(encoding="utf-8") == text:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def check_matches(path, text):
    return path.exists() and path.read_text(encoding="utf-8") == text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", default="spec/register_map.json")
    parser.add_argument("--sv-out", default="rtl/pkg/synth_register_pkg.sv")
    parser.add_argument("--cpp-out", default="sim/harness/generated/register_map.h")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    spec = load_spec(Path(args.spec))
    sv_path = Path(args.sv_out)
    cpp_path = Path(args.cpp_out)
    sv_text = render_sv(spec)
    cpp_text = render_cpp(spec)
    if args.check:
        stale = [str(path) for path, text in ((sv_path, sv_text), (cpp_path, cpp_text))
                 if not check_matches(path, text)]
        if stale:
            print("stale generated register map: " + ", ".join(stale), file=sys.stderr)
            return 1
        return 0
    write_if_changed(sv_path, sv_text)
    write_if_changed(cpp_path, cpp_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
