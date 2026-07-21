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


SUMMARY_NAMES = (
    "quick_render_config.json",
    "midi_render_config.json",
    "full_system_render_config.json",
    "board_loader_render_config.json",
)


def read_u16be(data, pos):
    return (data[pos] << 8) | data[pos + 1]


def read_u32be(data, pos):
    return (data[pos] << 24) | (data[pos + 1] << 16) | (data[pos + 2] << 8) | data[pos + 3]


def read_varlen(data, pos, end):
    value = 0
    while True:
        if pos >= end:
            raise ValueError("truncated MIDI varlen")
        byte = data[pos]
        pos += 1
        value = (value << 7) | (byte & 0x7F)
        if (byte & 0x80) == 0:
            return value, pos


def parse_midi_events(path):
    data = Path(path).read_bytes()
    if len(data) < 14 or data[:4] != b"MThd":
        raise ValueError("not a standard MIDI file")
    header_len = read_u32be(data, 4)
    track_count = read_u16be(data, 10)
    division = read_u16be(data, 12)
    if division & 0x8000:
        raise ValueError("SMPTE MIDI timing is not supported")

    pos = 8 + header_len
    tick_events = []
    tempos = [(0, 500000, 0)]
    tempo_order = 1

    for _ in range(track_count):
        if pos + 8 > len(data) or data[pos:pos + 4] != b"MTrk":
            raise ValueError("missing MTrk chunk")
        size = read_u32be(data, pos + 4)
        pos += 8
        end = pos + size
        tick = 0
        running_status = None
        program = [0] * 16
        bank_msb = [0] * 16
        bank_lsb = [0] * 16

        while pos < end:
            delta, pos = read_varlen(data, pos, end)
            tick += delta
            if pos >= end:
                break
            status = data[pos]
            if status & 0x80:
                pos += 1
                running_status = status
            elif running_status is not None:
                status = running_status
            else:
                raise ValueError("MIDI running status without previous status")

            if status == 0xFF:
                meta = data[pos]
                pos += 1
                length, pos = read_varlen(data, pos, end)
                if meta == 0x51 and length == 3:
                    tempo = (data[pos] << 16) | (data[pos + 1] << 8) | data[pos + 2]
                    tempos.append((tick, tempo, tempo_order))
                    tempo_order += 1
                pos += length
                continue
            if status in (0xF0, 0xF7):
                length, pos = read_varlen(data, pos, end)
                pos += length
                continue

            kind = status & 0xF0
            channel = status & 0x0F
            if kind in (0x80, 0x90):
                note = data[pos]
                velocity = data[pos + 1]
                pos += 2
                on = kind == 0x90 and velocity != 0
                tick_events.append({
                    "tick": tick,
                    "type": "note_on" if on else "note_off",
                    "channel": channel,
                    "note": note & 0x7F,
                    "velocity": velocity & 0x7F,
                    "program": program[channel],
                    "bank": (bank_msb[channel] << 7) | bank_lsb[channel],
                })
            elif kind == 0xB0:
                controller = data[pos] & 0x7F
                value = data[pos + 1] & 0x7F
                pos += 2
                if controller == 0:
                    bank_msb[channel] = value
                elif controller == 32:
                    bank_lsb[channel] = value
                tick_events.append({
                    "tick": tick,
                    "type": f"cc{controller}",
                    "channel": channel,
                    "value": value,
                    "program": program[channel],
                    "bank": (bank_msb[channel] << 7) | bank_lsb[channel],
                })
            elif kind == 0xC0:
                program[channel] = data[pos] & 0x7F
                pos += 1
                tick_events.append({
                    "tick": tick,
                    "type": "program",
                    "channel": channel,
                    "program": program[channel],
                    "bank": (bank_msb[channel] << 7) | bank_lsb[channel],
                })
            elif kind == 0xE0:
                lsb = data[pos] & 0x7F
                msb = data[pos + 1] & 0x7F
                pos += 2
                tick_events.append({
                    "tick": tick,
                    "type": "pitch_bend",
                    "channel": channel,
                    "value": ((msb << 7) | lsb) - 8192,
                    "program": program[channel],
                    "bank": (bank_msb[channel] << 7) | bank_lsb[channel],
                })
            elif kind == 0xD0:
                value = data[pos] & 0x7F
                pos += 1
                tick_events.append({
                    "tick": tick,
                    "type": "channel_pressure",
                    "channel": channel,
                    "value": value,
                    "program": program[channel],
                    "bank": (bank_msb[channel] << 7) | bank_lsb[channel],
                })
            elif kind == 0xA0:
                note = data[pos] & 0x7F
                value = data[pos + 1] & 0x7F
                pos += 2
                tick_events.append({
                    "tick": tick,
                    "type": "key_pressure",
                    "channel": channel,
                    "note": note,
                    "value": value,
                    "program": program[channel],
                    "bank": (bank_msb[channel] << 7) | bank_lsb[channel],
                })
            else:
                raise ValueError(f"unsupported MIDI status 0x{status:02x}")
        pos = end

    tempos.sort(key=lambda item: (item[0], item[2]))
    tick_events.sort(key=lambda event: event["tick"])
    tempo_index = 0
    last_tick = 0
    last_seconds = 0.0
    tempo = tempos[0][1]
    events = []
    for event in tick_events:
        tick = event["tick"]
        while tempo_index + 1 < len(tempos) and tempos[tempo_index + 1][0] <= tick:
            next_tick, next_tempo, _ = tempos[tempo_index + 1]
            last_seconds += (next_tick - last_tick) * tempo / division / 1000000.0
            last_tick = next_tick
            tempo = next_tempo
            tempo_index += 1
        event = dict(event)
        event["time_seconds"] = last_seconds + (tick - last_tick) * tempo / division / 1000000.0
        events.append(event)
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
    tick_samples = int(summary.get("adsr_tick_samples") or
                       round(sample_rate * float(summary.get("adsr_tick_ms", 0.0)) / 1000.0))
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
        "adsr_tick_ms",
        "adsr_tick_samples",
        "render_num_voices",
        "rtl_max_enabled_voices",
        "rtl_max_audible_voices",
        "diagnostics_runtime_envelope_updates",
        "diagnostics_max_runtime_envelope_jump",
        "diagnostics_max_runtime_envelope_jump_voice",
        "diagnostics_max_runtime_envelope_jump_tick",
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
