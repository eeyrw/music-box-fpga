#!/usr/bin/env python3
"""Read compact Vivado JSON summaries emitted by the Smart Artix Tcl flow."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


DEFAULT_REPORT_DIR = Path("build/fpga/smart_artix/vivado/reports")


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError as exc:
        raise SystemExit(f"summary not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit(f"summary root is not an object: {path}")
    return data


def get_path(data: dict[str, Any], dotted: str, default: Any = None) -> Any:
    value: Any = data
    for part in dotted.split("."):
        if not isinstance(value, dict) or part not in value:
            return default
        value = value[part]
    return value


def fmt(value: Any, suffix: str = "") -> str:
    if value is None:
        return "n/a"
    return f"{value}{suffix}"


def utilization_line(data: dict[str, Any], key: str, label: str) -> str:
    util = get_path(data, f"utilization.{key}", {})
    if not isinstance(util, dict):
        return f"{label}: n/a"
    used = util.get("used")
    available = util.get("available")
    pct = util.get("util_pct")
    if used is None:
        return f"{label}: n/a"
    if available is None or pct is None:
        return f"{label}: {used}"
    return f"{label}: {used} / {available} ({pct}%)"


def print_summary(path: Path, data: dict[str, Any]) -> None:
    print(f"{path}")
    print(f"  stage: {fmt(data.get('stage'))}")
    print(f"  top: {fmt(data.get('top'))}  part: {fmt(data.get('part'))}")
    print(
        "  timing: "
        f"WNS {fmt(get_path(data, 'timing.wns_ns'), ' ns')}, "
        f"TNS {fmt(get_path(data, 'timing.tns_ns'), ' ns')}, "
        f"WHS {fmt(get_path(data, 'timing.whs_ns'), ' ns')}, "
        f"THS {fmt(get_path(data, 'timing.ths_ns'), ' ns')}"
    )
    print(
        "  failing endpoints: "
        f"setup {fmt(get_path(data, 'timing.tns_failing_endpoints'))}, "
        f"hold {fmt(get_path(data, 'timing.ths_failing_endpoints'))}"
    )
    for key, label in (
        ("slice_luts", "LUT"),
        ("slice_registers", "FF"),
        ("dsps", "DSP"),
        ("block_ram_tiles", "BRAM tile"),
    ):
        print(f"  {utilization_line(data, key, label)}")
    route = get_path(data, "route_status", {})
    if isinstance(route, dict) and route.get("available"):
        print(
            "  route: "
            f"{fmt(route.get('fully_routed_nets'))} / {fmt(route.get('routable_nets'))} "
            f"fully routed, errors {fmt(route.get('routing_errors'))}"
        )
    drc = get_path(data, "drc", {})
    if isinstance(drc, dict) and drc.get("available"):
        print(
            "  drc: "
            f"errors {fmt(drc.get('error_count'))}, "
            f"critical warnings {fmt(drc.get('critical_warning_count'))}, "
            f"warnings {fmt(drc.get('warning_count'))}, "
            f"advisories {fmt(drc.get('advisory_count'))}"
        )


def numeric(data: dict[str, Any], dotted: str) -> float | None:
    value = get_path(data, dotted)
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def print_compare(base_path: Path, base: dict[str, Any], new_path: Path, new: dict[str, Any]) -> None:
    print(f"base: {base_path}")
    print(f"new:  {new_path}")
    for dotted, label in (
        ("timing.wns_ns", "WNS ns"),
        ("timing.tns_ns", "TNS ns"),
        ("timing.whs_ns", "WHS ns"),
        ("timing.ths_ns", "THS ns"),
        ("utilization.slice_luts.used", "LUT used"),
        ("utilization.slice_registers.used", "FF used"),
        ("utilization.dsps.used", "DSP used"),
        ("utilization.block_ram_tiles.used", "BRAM tile used"),
    ):
        old = numeric(base, dotted)
        current = numeric(new, dotted)
        if old is None or current is None:
            print(f"  {label}: n/a")
            continue
        delta = current - old
        print(f"  {label}: {old:g} -> {current:g} ({delta:+g})")


def default_summaries(report_dir: Path) -> list[Path]:
    order = {"post_synth_summary.json": 0, "post_route_summary.json": 1}
    return sorted(report_dir.glob("*_summary.json"), key=lambda path: (order.get(path.name, 99), path.name))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command")

    show_parser = subparsers.add_parser("show", help="print one or more summary JSON files")
    show_parser.add_argument("summary", nargs="*", type=Path)
    show_parser.add_argument("--report-dir", type=Path, default=DEFAULT_REPORT_DIR)

    compare_parser = subparsers.add_parser("compare", help="compare two summary JSON files")
    compare_parser.add_argument("base", type=Path)
    compare_parser.add_argument("new", type=Path)

    args = parser.parse_args()
    if args.command in (None, "show"):
        paths = args.summary if args.command == "show" else []
        if not paths:
            report_dir = args.report_dir if args.command == "show" else DEFAULT_REPORT_DIR
            paths = default_summaries(report_dir)
        if not paths:
            raise SystemExit(f"no summary JSON files found under {DEFAULT_REPORT_DIR}")
        for index, path in enumerate(paths):
            if index:
                print()
            print_summary(path, load_json(path))
        return 0
    if args.command == "compare":
        print_compare(args.base, load_json(args.base), args.new, load_json(args.new))
        return 0
    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
