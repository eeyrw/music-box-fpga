#!/usr/bin/env python3
"""Render and compare the reference synth with a dry FluidSynth baseline."""

from __future__ import annotations

import argparse
import json
import math
import re
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
CHANNEL_RE = re.compile(r"Channel:\s+(\d+)$")
DB_RE = re.compile(r"(Peak|RMS) level dB:\s+([^ ]+)$")


def run(command: list[str], cwd: Path = REPO_ROOT, capture: bool = False) -> str:
    print(f"+ {shlex.join(command)}")
    result = subprocess.run(
        command,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    return result.stdout or ""


def finite_db(text: str) -> float | None:
    value = float(text)
    return value if math.isfinite(value) else None


def parse_astats(output: str) -> dict[str, Any]:
    channels: dict[int, dict[str, float | None]] = {}
    current_channel: int | None = None
    samples: int | None = None
    for line in output.splitlines():
        if "] Overall" in line:
            current_channel = None
            continue
        channel_match = CHANNEL_RE.search(line)
        if channel_match:
            current_channel = int(channel_match.group(1))
            channels.setdefault(current_channel, {})
            continue
        db_match = DB_RE.search(line)
        if db_match and current_channel is not None:
            key = "peak_db" if db_match.group(1) == "Peak" else "rms_db"
            channels[current_channel][key] = finite_db(db_match.group(2))
        if "Number of samples:" in line:
            samples = int(float(line.rsplit(":", 1)[1].strip()))

    if sorted(channels)[:2] != [1, 2]:
        raise RuntimeError("FFmpeg astats did not report two audio channels")
    for channel in (1, 2):
        if "peak_db" not in channels[channel] or "rms_db" not in channels[channel]:
            raise RuntimeError(f"FFmpeg astats omitted peak/RMS data for channel {channel}")

    left = channels[1]
    right = channels[2]
    left_rms = left["rms_db"]
    right_rms = right["rms_db"]
    balance = None
    if left_rms is not None and right_rms is not None:
        balance = left_rms - right_rms
    return {
        "left": left,
        "right": right,
        "left_minus_right_rms_db": balance,
        "number_of_samples": samples,
    }


def analyze_wav(ffmpeg: str, path: Path) -> dict[str, Any]:
    output = run(
        [ffmpeg, "-nostats", "-hide_banner", "-i", str(path),
         "-af", "astats=metadata=1:reset=0", "-f", "null", "-"],
        capture=True,
    )
    result = parse_astats(output)
    result["path"] = str(path)
    return result


def render_reference(args: argparse.Namespace, out_dir: Path) -> Path:
    command = [
        args.make,
        "render-reference",
        f"SF2={args.sf2}",
        f"MIDI={args.midi}",
        f"START_SECONDS={args.start_seconds}",
        f"SECONDS={args.seconds}",
        f"SAMPLE_RATE={args.sample_rate}",
        f"CONTROL_TICK_MS={args.control_tick_ms}",
        f"SAMPLE_ACCURATE_CONTROL={int(args.sample_accurate_control)}",
        f"DETAILED_DIAGNOSTICS={int(args.detailed_diagnostics)}",
        f"RENDER_REFERENCE_OUT_DIR={out_dir}",
    ]
    run(command)
    wav = out_dir / "out.wav"
    if not wav.is_file():
        raise RuntimeError(f"reference render did not create {wav}")
    return wav


def render_fluidsynth(args: argparse.Namespace, out_dir: Path, ffmpeg: str) -> Path:
    full_wav = out_dir / "fluidsynth_full.wav"
    window_wav = out_dir / "fluidsynth_window.wav"
    run([
        args.fluidsynth,
        "-ni",
        "-R", "0",
        "-C", "0",
        "-r", str(args.sample_rate),
        "-g", str(args.fluidsynth_gain),
        "-F", str(full_wav),
        "-T", "wav",
        str(args.sf2),
        str(args.midi),
    ])
    run([
        ffmpeg,
        "-nostats",
        "-hide_banner",
        "-y",
        "-i", str(full_wav),
        "-ss", str(args.start_seconds),
        "-t", str(args.seconds),
        "-map", "0:a:0",
        "-c:a", "pcm_s16le",
        str(window_wav),
    ])
    if not args.keep_fluid_full:
        full_wav.unlink()
    return window_wav


def require_program(program: str) -> str:
    resolved = shutil.which(program)
    if not resolved:
        raise SystemExit(f"required program not found: {program}")
    return resolved


def comparison(reference: dict[str, Any], fluid: dict[str, Any]) -> dict[str, Any]:
    reference_balance = reference["left_minus_right_rms_db"]
    fluid_balance = fluid["left_minus_right_rms_db"]
    balance_delta = None
    if reference_balance is not None and fluid_balance is not None:
        balance_delta = reference_balance - fluid_balance
    reference_samples = reference["number_of_samples"]
    fluid_samples = fluid["number_of_samples"]
    return {
        "reference": reference,
        "fluidsynth": fluid,
        "sample_count_match": (
            reference_samples is not None
            and reference_samples == fluid_samples
        ),
        "reference_minus_fluidsynth_balance_db": balance_delta,
        "note": "Positive balance means the left channel is louder; compare balance, not absolute RMS, because master gains differ.",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sf2", type=Path)
    parser.add_argument("--midi", type=Path)
    parser.add_argument("--reference-wav", type=Path,
                        help="analyze an existing reference WAV instead of rendering")
    parser.add_argument("--fluid-wav", type=Path,
                        help="analyze an existing FluidSynth WAV instead of rendering")
    parser.add_argument("--out-dir", type=Path, default=Path("build/reference_fluidsynth_compare"))
    parser.add_argument("--start-seconds", type=float, default=0.0)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--sample-rate", type=int, default=48000)
    parser.add_argument("--control-tick-ms", type=float, default=1.0)
    parser.add_argument("--sample-accurate-control", action="store_true")
    parser.add_argument("--detailed-diagnostics", action="store_true")
    parser.add_argument("--fluidsynth-gain", type=float, default=0.2)
    parser.add_argument("--keep-fluid-full", action="store_true")
    parser.add_argument("--make", default="make")
    parser.add_argument("--fluidsynth", default="fluidsynth")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    args = parser.parse_args()
    if args.start_seconds < 0 or args.seconds <= 0:
        parser.error("start-seconds must be nonnegative and seconds must be positive")
    if args.sample_rate <= 0 or args.control_tick_ms <= 0:
        parser.error("sample-rate and control-tick-ms must be positive")
    if (args.reference_wav is None or args.fluid_wav is None) and (args.sf2 is None or args.midi is None):
        parser.error("--sf2 and --midi are required when either WAV must be rendered")
    return args


def main() -> int:
    args = parse_args()
    ffmpeg = require_program(args.ffmpeg)
    if args.reference_wav is None:
        require_program(args.make)
    if args.fluid_wav is None:
        require_program(args.fluidsynth)

    out_dir = args.out_dir.resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    reference_wav = args.reference_wav.resolve() if args.reference_wav else render_reference(args, out_dir / "reference")
    fluid_wav = args.fluid_wav.resolve() if args.fluid_wav else render_fluidsynth(args, out_dir, ffmpeg)
    report = comparison(analyze_wav(ffmpeg, reference_wav), analyze_wav(ffmpeg, fluid_wav))
    report["inputs"] = {
        "sf2": str(args.sf2) if args.sf2 else None,
        "midi": str(args.midi) if args.midi else None,
        "start_seconds": args.start_seconds,
        "seconds": args.seconds,
        "sample_rate": args.sample_rate,
        "control_tick_ms": args.control_tick_ms,
        "sample_accurate_control": args.sample_accurate_control,
        "fluidsynth_reverb": False,
        "fluidsynth_chorus": False,
        "fluidsynth_gain": args.fluidsynth_gain,
    }
    report_path = out_dir / "comparison.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, ensure_ascii=True))
    print(f"wrote {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
