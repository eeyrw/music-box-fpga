#!/usr/bin/env python3
"""Analyze render WAV transients and nearby MIDI events.

This is a lightweight post-render tool. It does not run simulation. It reads a
render output directory containing out.wav and a render summary JSON, then
reports sample-to-sample discontinuities, second-difference spikes, and whether
they align with the configured ADSR/control tick grid.
"""

import argparse
import json
import math
from pathlib import Path
import statistics
import struct
import wave

from midi_events import parse_midi_events as parse_shared_midi_events


SUMMARY_NAMES = (
    "reference_render_config.json",
    "rtl_core_render_config.json",
    "midi_render_config.json",
    "board_loader_render_config.json",
)


def parse_midi_events(path):
    events = []
    for event in parse_shared_midi_events(path):
        item = {
            "time_seconds": event.time_seconds,
            "type": event.event_type,
            "channel": event.channel,
            "program": event.program,
            "bank": event.bank,
        }
        if event.event_type in ("note_on", "note_off", "key_pressure"):
            item["note"] = event.note
        if event.event_type in ("note_on", "note_off"):
            item["velocity"] = event.velocity
        if event.event_type == "control":
            item["type"] = f"cc{event.controller}"
            item["value"] = event.value
        elif event.event_type == "pitch_bend":
            item["value"] = event.pitch_bend
        elif event.event_type in ("channel_pressure", "key_pressure"):
            item["value"] = event.value
        events.append(item)
    return events


def load_summary(render_dir):
    for name in SUMMARY_NAMES:
        path = render_dir / name
        if path.exists():
            return path, json.loads(path.read_text())
    raise FileNotFoundError(f"no known render summary JSON in {render_dir}")


def read_wav(path):
    with wave.open(str(path), "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frames = wav.getnframes()
        payload = wav.readframes(frames)
    if channels != 2 or sample_width != 2:
        raise ValueError(f"{path} is not signed 16-bit stereo PCM")
    values = struct.unpack("<" + "h" * (len(payload) // 2), payload)
    return sample_rate, values[0::2], values[1::2]


def percentile(sorted_values, fraction):
    if not sorted_values:
        return 0
    index = min(len(sorted_values) - 1, int(fraction * len(sorted_values)))
    return sorted_values[index]


def near_grid(frame, period, radius):
    if period <= 0:
        return False
    phase = frame % period
    return min(phase, period - phase) <= radius


def channel_stats(samples, sample_rate, tick_samples, top_count, thresholds, tick_radius):
    diffs = [samples[i] - samples[i - 1] for i in range(1, len(samples))]
    abs_diffs = [abs(value) for value in diffs]
    sorted_abs_diffs = sorted(abs_diffs)
    second = [
        (samples[i] - samples[i - 1]) - (samples[i - 1] - samples[i - 2])
        for i in range(2, len(samples))
    ]
    abs_second = [abs(value) for value in second]
    sorted_abs_second = sorted(abs_second)

    top_diff_frames = sorted(
        range(1, len(samples)),
        key=lambda frame: abs(samples[frame] - samples[frame - 1]),
        reverse=True,
    )[:top_count]
    top_second_frames = sorted(
        range(2, len(samples)),
        key=lambda frame: abs((samples[frame] - samples[frame - 1]) -
                              (samples[frame - 1] - samples[frame - 2])),
        reverse=True,
    )[:top_count]

    threshold_counts = []
    for threshold in thresholds:
        frames = [index + 1 for index, value in enumerate(abs_diffs) if value >= threshold]
        threshold_counts.append({
            "threshold": threshold,
            "count": len(frames),
            "near_tick": sum(1 for frame in frames if near_grid(frame, tick_samples, tick_radius)),
        })

    return {
        "peak": max(abs(value) for value in samples) if samples else 0,
        "max_diff": max(abs_diffs) if abs_diffs else 0,
        "p99_diff": percentile(sorted_abs_diffs, 0.99),
        "p999_diff": percentile(sorted_abs_diffs, 0.999),
        "p9999_diff": percentile(sorted_abs_diffs, 0.9999),
        "max_second_diff": max(abs_second) if abs_second else 0,
        "p999_second_diff": percentile(sorted_abs_second, 0.999),
        "threshold_counts": threshold_counts,
        "top_diff": [
            {
                "frame": frame,
                "time_seconds": frame / sample_rate,
                "previous": samples[frame - 1],
                "current": samples[frame],
                "diff": samples[frame] - samples[frame - 1],
                "tick_phase": frame % tick_samples if tick_samples > 0 else None,
                "near_tick": near_grid(frame, tick_samples, tick_radius),
            }
            for frame in top_diff_frames
        ],
        "top_second_diff": [
            {
                "frame": frame,
                "time_seconds": frame / sample_rate,
                "previous2": samples[frame - 2],
                "previous": samples[frame - 1],
                "current": samples[frame],
                "previous_diff": samples[frame - 1] - samples[frame - 2],
                "diff": samples[frame] - samples[frame - 1],
                "second_diff": ((samples[frame] - samples[frame - 1]) -
                                (samples[frame - 1] - samples[frame - 2])),
                "tick_phase": frame % tick_samples if tick_samples > 0 else None,
                "near_tick": near_grid(frame, tick_samples, tick_radius),
            }
            for frame in top_second_frames
        ],
    }


def print_transient(label, item):
    print(
        f"  {label} frame={item['frame']} time={item['time_seconds']:.6f}s "
        f"diff={item.get('diff')} tick_phase={item['tick_phase']} "
        f"near_tick={item['near_tick']}"
    )


def describe_event(event):
    pieces = [
        f"{event['time_seconds']:.6f}s",
        f"ch={event.get('channel')}",
        f"type={event.get('type')}",
    ]
    if "note" in event:
        pieces.append(f"note={event['note']}")
    if "velocity" in event:
        pieces.append(f"vel={event['velocity']}")
    if "value" in event:
        pieces.append(f"value={event['value']}")
    pieces.append(f"prog={event.get('program')}")
    pieces.append(f"bank={event.get('bank')}")
    return " ".join(pieces)


def analyze_run(render_dir, args):
    summary_path, summary = load_summary(render_dir)
    wav_path = render_dir / args.wav_name
    if not wav_path.exists():
        raise FileNotFoundError(f"missing {wav_path}")
    sample_rate, left, right = read_wav(wav_path)
    tick_samples = int(summary.get("control_tick_samples") or
                       summary.get("adsr_tick_samples") or
                       round(sample_rate * float(summary.get(
                           "control_tick_ms", summary.get("adsr_tick_ms", 0.0))) / 1000.0))
    if tick_samples <= 0:
        tick_samples = 1

    print(f"\n== {render_dir} ==")
    print(f"summary={summary_path.name} wav={wav_path.name}")
    for key in (
        "render_target",
        "rtl_top",
        "sf2_path",
        "midi_path",
        "requested_seconds",
        "control_tick_ms",
        "control_tick_samples",
        "render_num_voices",
        "rtl_max_enabled_voices",
        "rtl_max_audible_voices",
        "diagnostics_max_runtime_gain_jump_l",
        "diagnostics_max_runtime_gain_jump_r",
        "diagnostics_mix_saturations",
        "diagnostics_max_abs_mix_input_l",
        "diagnostics_max_abs_mix_input_r",
    ):
        if key in summary:
            print(f"{key}: {summary[key]}")
    print(f"wav_sample_rate: {sample_rate}")
    print(f"wav_frames: {len(left)}")

    top_event_times = []
    for name, samples in (("L", left), ("R", right)):
        stats = channel_stats(
            samples,
            sample_rate,
            tick_samples,
            args.top,
            args.threshold,
            args.tick_radius,
        )
        print(
            f"{name}: peak={stats['peak']} maxdiff={stats['max_diff']} "
            f"p99={stats['p99_diff']} p999={stats['p999_diff']} "
            f"p9999={stats['p9999_diff']} max_second_diff={stats['max_second_diff']} "
            f"p999_second_diff={stats['p999_second_diff']}"
        )
        for count in stats["threshold_counts"]:
            print(
                f"  diff>={count['threshold']}: count={count['count']} "
                f"near_tick(+/-{args.tick_radius})={count['near_tick']}"
            )
        print("  top diff:")
        for item in stats["top_diff"]:
            print_transient(name, item)
            top_event_times.append(item["time_seconds"])
        print("  top second diff:")
        for item in stats["top_second_diff"]:
            print(
                f"  {name} frame={item['frame']} time={item['time_seconds']:.6f}s "
                f"dprev={item['previous_diff']} diff={item['diff']} "
                f"d2={item['second_diff']} tick_phase={item['tick_phase']} "
                f"near_tick={item['near_tick']}"
            )
            top_event_times.append(item["time_seconds"])

    midi_path = args.midi or summary.get("midi_path")
    if args.show_midi_events and midi_path:
        try:
            events = parse_midi_events(midi_path)
        except Exception as exc:
            print(f"midi_event_scan_error: {exc}")
        else:
            windows = []
            for time_value in top_event_times[:args.event_windows]:
                start = time_value - args.event_window_seconds
                stop = time_value + args.event_window_seconds
                if not any(abs(start - existing[0]) < args.event_window_seconds for existing in windows):
                    windows.append((start, stop))
            for start, stop in windows:
                nearby = [event for event in events if start <= event["time_seconds"] <= stop]
                print(f"  MIDI events {start:.6f}s..{stop:.6f}s count={len(nearby)}")
                for event in nearby[:args.max_events_per_window]:
                    print(f"    {describe_event(event)}")
                if len(nearby) > args.max_events_per_window:
                    print(f"    ... {len(nearby) - args.max_events_per_window} more")


def main():
    parser = argparse.ArgumentParser(description="Analyze render WAV transients and control-grid alignment")
    parser.add_argument("render_dirs", nargs="+", type=Path, help="render output directories")
    parser.add_argument("--wav-name", default="out.wav")
    parser.add_argument("--top", type=int, default=8, help="number of top diff entries per channel")
    parser.add_argument("--threshold", type=int, action="append", default=[500, 800, 1000, 1200, 1500],
                        help="absolute first-difference threshold; may be repeated")
    parser.add_argument("--tick-radius", type=int, default=2, help="samples around ADSR tick counted as aligned")
    parser.add_argument("--midi", help="override MIDI path for event-window reporting")
    parser.add_argument("--no-midi-events", dest="show_midi_events", action="store_false",
                        help="skip nearby MIDI event reporting")
    parser.add_argument("--event-window-seconds", type=float, default=0.01)
    parser.add_argument("--event-windows", type=int, default=4)
    parser.add_argument("--max-events-per-window", type=int, default=24)
    parser.set_defaults(show_midi_events=True)
    args = parser.parse_args()

    # argparse appends to the default list. De-duplicate while preserving order.
    thresholds = []
    for threshold in args.threshold:
        if threshold not in thresholds:
            thresholds.append(threshold)
    args.threshold = thresholds

    for render_dir in args.render_dirs:
        analyze_run(render_dir, args)


if __name__ == "__main__":
    main()
