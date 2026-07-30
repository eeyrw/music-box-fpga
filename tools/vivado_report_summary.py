#!/usr/bin/env python3
"""Read compact Vivado JSON summaries emitted by the Smart Artix Tcl flow."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import re
from typing import Any


DEFAULT_REPORT_DIR = Path("build/fpga/smart_artix/vivado/reports")


@dataclass(frozen=True)
class TimingPath:
    status: str
    slack_ns: float
    source: str
    destination: str
    source_type: str
    destination_type: str
    path_group: str
    path_type: str
    requirement_ns: float | None
    datapath_delay_ns: float
    logic_delay_ns: float
    route_delay_ns: float
    logic_pct: float
    route_pct: float
    logic_levels: int
    clock_skew_ns: float | None
    clock_uncertainty_ns: float | None


FLOAT_PATTERN = r"[-+]?[0-9]+(?:\.[0-9]+)?"


def match_float(text: str, pattern: str) -> float | None:
    match = re.search(pattern, text, re.MULTILINE)
    return float(match.group(1)) if match else None


def parse_timing_paths(text: str) -> list[TimingPath]:
    blocks = re.split(r"(?=^Slack \()", text, flags=re.MULTILINE)
    paths: list[TimingPath] = []
    for block in blocks:
        slack_match = re.search(
            rf"^Slack \(([^)]+)\)\s*:\s*({FLOAT_PATTERN})ns", block, re.MULTILINE
        )
        source_match = re.search(
            r"^  Source:\s+(\S+)\s*\n\s+\([^\n]* cell (\S+) clocked by", block, re.MULTILINE
        )
        destination_match = re.search(
            r"^  Destination:\s+(\S+)\s*\n\s+\([^\n]* cell (\S+) clocked by",
            block,
            re.MULTILINE,
        )
        delay_match = re.search(
            rf"^  Data Path Delay:\s*({FLOAT_PATTERN})ns\s*"
            rf"\(logic ({FLOAT_PATTERN})ns \(({FLOAT_PATTERN})%\)\s*"
            rf"route ({FLOAT_PATTERN})ns \(({FLOAT_PATTERN})%\)\)",
            block,
            re.MULTILINE,
        )
        levels_match = re.search(r"^  Logic Levels:\s*(\d+)", block, re.MULTILINE)
        if not all((slack_match, source_match, destination_match, delay_match, levels_match)):
            continue
        group_match = re.search(r"^  Path Group:\s+(\S+)", block, re.MULTILINE)
        type_match = re.search(r"^  Path Type:\s+(.+)$", block, re.MULTILINE)
        paths.append(
            TimingPath(
                status=slack_match.group(1),
                slack_ns=float(slack_match.group(2)),
                source=source_match.group(1),
                destination=destination_match.group(1),
                source_type=source_match.group(2),
                destination_type=destination_match.group(2),
                path_group=group_match.group(1) if group_match else "unknown",
                path_type=type_match.group(1).strip() if type_match else "unknown",
                requirement_ns=match_float(block, rf"^  Requirement:\s*({FLOAT_PATTERN})ns"),
                datapath_delay_ns=float(delay_match.group(1)),
                logic_delay_ns=float(delay_match.group(2)),
                logic_pct=float(delay_match.group(3)),
                route_delay_ns=float(delay_match.group(4)),
                route_pct=float(delay_match.group(5)),
                logic_levels=int(levels_match.group(1)),
                clock_skew_ns=match_float(block, rf"^  Clock Path Skew:\s*({FLOAT_PATTERN})ns"),
                clock_uncertainty_ns=match_float(
                    block, rf"^  Clock Uncertainty:\s*({FLOAT_PATTERN})ns"
                ),
            )
        )
    return paths


def normalized_cell(endpoint: str) -> str:
    cell = endpoint
    if "/" in endpoint:
        candidate, leaf = endpoint.rsplit("/", 1)
        if re.fullmatch(r"[A-Z][A-Z0-9]*(?:\[\d+\])?", leaf):
            cell = candidate
    cell = re.sub(r"\[\d+\]", "[]", cell)
    cell = re.sub(r"_replica(?:_\d+)?", "_replica", cell)
    cell = re.sub(r"_repN_\d+", "_repN", cell)
    return cell


def compact_cell(endpoint: str, depth: int = 4) -> str:
    parts = normalized_cell(endpoint).split("/")
    return "/".join(parts[-depth:])


def cluster_timing_paths(paths: list[TimingPath]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str], list[TimingPath]] = defaultdict(list)
    for path in paths:
        key = (normalized_cell(path.source), normalized_cell(path.destination), path.path_group)
        grouped[key].append(path)
    clusters: list[dict[str, Any]] = []
    for (source, destination, group), members in grouped.items():
        worst = min(members, key=lambda item: item.slack_ns)
        clusters.append(
            {
                "source": source,
                "destination": destination,
                "path_group": group,
                "count": len(members),
                "worst_slack_ns": worst.slack_ns,
                "max_datapath_delay_ns": max(item.datapath_delay_ns for item in members),
                "max_logic_levels": max(item.logic_levels for item in members),
                "max_route_pct": max(item.route_pct for item in members),
                "source_type": worst.source_type,
                "destination_type": worst.destination_type,
            }
        )
    return sorted(clusters, key=lambda item: (item["worst_slack_ns"], -item["count"]))


def parse_check_timing(text: str) -> dict[str, int]:
    checks: dict[str, int] = {}
    for name, count in re.findall(r"^\d+\. checking (\S+) \((\d+)\)$", text, re.MULTILINE):
        checks.setdefault(name, int(count))
    return checks


def parse_port_list_after(text: str, sentence_pattern: str) -> list[str]:
    match = re.search(
        sentence_pattern + r"\s*\n\n(.*?)(?=\n\n There |\n\n\d+\. checking|\Z)",
        text,
        re.DOTALL,
    )
    if not match:
        return []
    return [line.strip() for line in match.group(1).splitlines() if line.strip()]


def parse_io_delay_coverage(text: str) -> dict[str, list[str]]:
    return {
        "inputs_without_delay": parse_port_list_after(
            text, r"There are \d+ input ports with no input delay specified\. \(HIGH\)"
        ),
        "inputs_without_delay_false_pathed": parse_port_list_after(
            text,
            r"There is \d+ input port with no input delay but user has a false path constraint\. \(MEDIUM\)",
        ),
        "outputs_without_delay": parse_port_list_after(
            text, r"There are \d+ ports with no output delay specified\. \(HIGH\)"
        ),
    }


def parse_rule_summary(text: str) -> list[dict[str, Any]]:
    rules: list[dict[str, Any]] = []
    pattern = re.compile(
        r"^\|\s*([A-Z][A-Z0-9_-]+)\s*\|\s*"
        r"(Error|Critical Warning|Warning|Advisory)\s*\|\s*(.*?)\s*\|\s*(\d+)\s*\|$",
        re.MULTILINE,
    )
    for rule, severity, description, count in pattern.findall(text):
        rules.append(
            {"rule": rule, "severity": severity, "description": description, "count": int(count)}
        )
    return rules


def parse_design_timing_summary(text: str) -> dict[str, float | int]:
    marker = "| Design Timing Summary"
    if marker not in text:
        return {}
    section = text.split(marker, 1)[1]
    match = re.search(
        r"WNS\(ns\).*?\n\s*-+.*?\n\s*"
        rf"({FLOAT_PATTERN})\s+({FLOAT_PATTERN})\s+(\d+)\s+(\d+)\s+"
        rf"({FLOAT_PATTERN})\s+({FLOAT_PATTERN})\s+(\d+)\s+(\d+)\s+"
        rf"({FLOAT_PATTERN})\s+({FLOAT_PATTERN})\s+(\d+)\s+(\d+)",
        section,
        re.DOTALL,
    )
    if not match:
        return {}
    names = (
        "wns_ns",
        "tns_ns",
        "setup_failing_endpoints",
        "setup_total_endpoints",
        "whs_ns",
        "ths_ns",
        "hold_failing_endpoints",
        "hold_total_endpoints",
        "wpws_ns",
        "tpws_ns",
        "pulse_width_failing_endpoints",
        "pulse_width_total_endpoints",
    )
    integer_names = {
        "setup_failing_endpoints",
        "setup_total_endpoints",
        "hold_failing_endpoints",
        "hold_total_endpoints",
        "pulse_width_failing_endpoints",
        "pulse_width_total_endpoints",
    }
    return {
        name: int(value) if name in integer_names else float(value)
        for name, value in zip(names, match.groups())
    }


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
        ("part", "part"),
        ("top", "top"),
        ("configuration", "configuration"),
        ("vivado_version", "Vivado version"),
    ):
        old_identity = get_path(base, dotted)
        new_identity = get_path(new, dotted)
        if old_identity != new_identity:
            print(f"  WARNING {label} differs: {old_identity!r} -> {new_identity!r}")
    print(
        "  strategies: "
        f"{fmt(base.get('synth_strategy'))} / {fmt(base.get('impl_strategy'))} -> "
        f"{fmt(new.get('synth_strategy'))} / {fmt(new.get('impl_strategy'))}"
    )
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
    old_path = get_path(base, "timing.worst_setup_path", {})
    new_path_data = get_path(new, "timing.worst_setup_path", {})
    if isinstance(old_path, dict) and isinstance(new_path_data, dict):
        old_pair = (old_path.get("startpoint_pin"), old_path.get("endpoint_pin"))
        new_pair = (new_path_data.get("startpoint_pin"), new_path_data.get("endpoint_pin"))
        if old_pair != new_pair:
            print("  critical setup path changed")
        print(
            "  setup datapath/levels: "
            f"{fmt(old_path.get('datapath_delay'), ' ns')}/{fmt(old_path.get('logic_levels'))} -> "
            f"{fmt(new_path_data.get('datapath_delay'), ' ns')}/{fmt(new_path_data.get('logic_levels'))}"
        )


def report_text(report_dir: Path, name: str) -> str:
    path = report_dir / name
    return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""


def path_recommendations(path: TimingPath) -> list[str]:
    recommendations: list[str] = []
    hard_types = {"RAMB18E1", "RAMB36E1", "DSP48E1"}
    if path.logic_levels >= 12 or path.logic_pct >= 55.0:
        recommendations.append("split dependent decode/arithmetic with a registered protocol boundary")
    if path.route_pct >= 60.0:
        recommendations.append("inspect fanout and placement locality before adding more logic optimization")
    if path.source_type in hard_types or path.destination_type in hard_types:
        recommendations.append("review the register boundary adjacent to the RAM/DSP hard block")
    if path.clock_skew_ns is not None and abs(path.clock_skew_ns) >= 0.250:
        recommendations.append("review clock skew and clock-region placement")
    return recommendations


def build_analysis(report_dir: Path, summary: dict[str, Any], margin_ns: float) -> dict[str, Any]:
    setup_text = report_text(report_dir, "post_route_setup_paths.rpt")
    hold_text = report_text(report_dir, "post_route_hold_paths.rpt")
    check_timing_text = report_text(report_dir, "post_route_check_timing.rpt")
    methodology_text = report_text(report_dir, "post_route_methodology.rpt")
    timing_summary_text = report_text(report_dir, "post_route_timing.rpt")
    setup_paths = parse_timing_paths(setup_text)
    hold_paths = parse_timing_paths(hold_text)
    check_timing = parse_check_timing(check_timing_text)
    io_delay_coverage = parse_io_delay_coverage(check_timing_text)
    methodology = parse_rule_summary(methodology_text)
    design_timing = parse_design_timing_summary(timing_summary_text)
    congestion_text = report_text(report_dir, "post_route_congestion.rpt")

    failures: list[str] = []
    reviews: list[str] = []
    recommendations: list[str] = []
    wns = numeric(summary, "timing.wns_ns")
    whs = numeric(summary, "timing.whs_ns")
    if wns is not None and wns < 0:
        failures.append(f"setup timing fails: WNS {wns:g} ns")
    elif wns is not None and wns < margin_ns:
        reviews.append(f"setup margin is below {margin_ns:g} ns: WNS {wns:g} ns")
    if whs is not None and whs < 0:
        failures.append(f"hold timing fails: WHS {whs:g} ns")
    elif whs is not None and whs < margin_ns:
        reviews.append(f"hold margin is below {margin_ns:g} ns: WHS {whs:g} ns")

    for dotted, label in (
        ("timing.tns_failing_endpoints", "setup failing endpoints"),
        ("timing.ths_failing_endpoints", "hold failing endpoints"),
        ("route_status.routing_errors", "routing errors"),
        ("drc.error_count", "DRC errors"),
        ("drc.critical_warning_count", "DRC critical warnings"),
    ):
        value = numeric(summary, dotted)
        if value is not None and value > 0:
            failures.append(f"{label}: {value:g}")

    if design_timing.get("pulse_width_failing_endpoints", 0) > 0:
        failures.append(
            "pulse-width failing endpoints: "
            f"{design_timing['pulse_width_failing_endpoints']}"
        )

    routed = numeric(summary, "route_status.fully_routed_nets")
    routable = numeric(summary, "route_status.routable_nets")
    if routed is not None and routable is not None and routed != routable:
        failures.append(f"fully routed nets do not match: {routed:g} / {routable:g}")

    for key, label in (("slice_luts", "LUT"), ("block_ram_tiles", "BRAM")):
        pct = numeric(summary, f"utilization.{key}.util_pct")
        if pct is not None and pct >= 70.0:
            reviews.append(f"{label} utilization is high: {pct:g}%")

    for name, count in check_timing.items():
        if count <= 0:
            continue
        message = f"check_timing {name}: {count}"
        if name in {"no_clock", "constant_clock", "unconstrained_internal_endpoints", "loops"}:
            failures.append(message)
        else:
            reviews.append(message)

    drc_warnings = numeric(summary, "drc.warning_count")
    if drc_warnings:
        reviews.append(f"DRC warnings require classification: {drc_warnings:g}")
    if methodology:
        reviews.append(
            "methodology findings: " + ", ".join(f"{item['rule']}={item['count']}" for item in methodology)
        )
    congestion_clear = "No congestion windows are found above level 5" in congestion_text
    if congestion_text and not congestion_clear:
        reviews.append("congestion report contains windows that require inspection")
    for available, message in (
        (bool(setup_paths), "setup path report unavailable or unparseable"),
        (bool(hold_paths), "hold path report unavailable or unparseable"),
        (bool(design_timing), "design timing summary unavailable or unparseable"),
        (bool(check_timing), "check_timing report unavailable or unparseable"),
        (bool(methodology_text), "methodology report unavailable"),
        (bool(congestion_text), "congestion report unavailable"),
    ):
        if not available:
            reviews.append(message)

    if setup_paths:
        recommendations.extend(path_recommendations(min(setup_paths, key=lambda item: item.slack_ns)))
    if check_timing.get("no_input_delay", 0) or check_timing.get("no_output_delay", 0):
        recommendations.append("derive board I/O delays from external-device and PCB timing contracts")
    lut_pct = numeric(summary, "utilization.slice_luts.util_pct")
    if lut_pct is not None and lut_pct >= 70.0:
        recommendations.append("track LUT growth by hierarchy before adding replicated control logic")

    recommendations = list(dict.fromkeys(recommendations))
    return {
        "status": "FAIL" if failures else ("REVIEW" if reviews else "PASS"),
        "failures": failures,
        "reviews": reviews,
        "setup_path_count": len(setup_paths),
        "hold_path_count": len(hold_paths),
        "worst_setup_path": asdict(min(setup_paths, key=lambda item: item.slack_ns)) if setup_paths else None,
        "worst_hold_path": asdict(min(hold_paths, key=lambda item: item.slack_ns)) if hold_paths else None,
        "setup_clusters": cluster_timing_paths(setup_paths),
        "hold_clusters": cluster_timing_paths(hold_paths),
        "setup_path_groups": dict(Counter(path.path_group for path in setup_paths)),
        "hold_path_groups": dict(Counter(path.path_group for path in hold_paths)),
        "design_timing_summary": design_timing,
        "check_timing": check_timing,
        "io_delay_coverage": io_delay_coverage,
        "methodology": methodology,
        "congestion_above_level_5": (
            False if congestion_clear else (True if congestion_text else None)
        ),
        "recommendations": recommendations,
    }


def print_path(label: str, path: dict[str, Any] | None) -> None:
    if not path:
        print(f"  {label}: report unavailable")
        return
    print(
        f"  {label}: slack {path['slack_ns']:g} ns, delay {path['datapath_delay_ns']:g} ns, "
        f"levels {path['logic_levels']}, logic/route {path['logic_pct']:g}%/{path['route_pct']:g}%"
    )
    print(
        f"    {compact_cell(path['source'])} ({path['source_type']}) -> "
        f"{compact_cell(path['destination'])} ({path['destination_type']})"
    )


def print_analysis(analysis: dict[str, Any], top_clusters: int) -> None:
    print(f"analysis status: {analysis['status']}")
    print_path("worst setup", analysis["worst_setup_path"])
    print_path("worst hold", analysis["worst_hold_path"])
    print(f"  parsed paths: setup {analysis['setup_path_count']}, hold {analysis['hold_path_count']}")
    for label, key in (("setup groups", "setup_path_groups"), ("hold groups", "hold_path_groups")):
        groups = analysis[key]
        if groups:
            print(f"  {label}: " + ", ".join(f"{name}={count}" for name, count in groups.items()))
    io_delays = analysis["io_delay_coverage"]
    if any(io_delays.values()):
        print(
            "  I/O delay coverage gaps: "
            f"inputs {len(io_delays['inputs_without_delay'])}, "
            f"false-pathed inputs {len(io_delays['inputs_without_delay_false_pathed'])}, "
            f"outputs {len(io_delays['outputs_without_delay'])}"
        )
    print("  setup clusters:")
    for cluster in analysis["setup_clusters"][:top_clusters]:
        print(
            f"    slack {cluster['worst_slack_ns']:g} ns, count {cluster['count']}, "
            f"levels {cluster['max_logic_levels']}, route <= {cluster['max_route_pct']:g}%"
        )
        print(
            f"      {compact_cell(cluster['source'])} -> {compact_cell(cluster['destination'])}"
        )
    for heading, key in (("failures", "failures"), ("review", "reviews"), ("next actions", "recommendations")):
        values = analysis[key]
        if values:
            print(f"  {heading}:")
            for value in values:
                print(f"    - {value}")


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

    analyze_parser = subparsers.add_parser(
        "analyze", help="analyze routed timing paths, constraints, methodology, and congestion"
    )
    analyze_parser.add_argument("--report-dir", type=Path, default=DEFAULT_REPORT_DIR)
    analyze_parser.add_argument("--summary", type=Path)
    analyze_parser.add_argument("--margin-ns", type=float, default=0.200)
    analyze_parser.add_argument("--top-clusters", type=int, default=8)
    analyze_parser.add_argument("--output-json", type=Path)

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
    if args.command == "analyze":
        if args.margin_ns < 0:
            parser.error("--margin-ns must be nonnegative")
        if args.top_clusters < 1:
            parser.error("--top-clusters must be positive")
        summary_path = args.summary or args.report_dir / "post_route_summary.json"
        analysis = build_analysis(args.report_dir, load_json(summary_path), args.margin_ns)
        print_analysis(analysis, args.top_clusters)
        if args.output_json:
            args.output_json.parent.mkdir(parents=True, exist_ok=True)
            args.output_json.write_text(
                json.dumps(analysis, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            print(f"wrote analysis JSON: {args.output_json}")
        return 1 if analysis["status"] == "FAIL" else 0
    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
