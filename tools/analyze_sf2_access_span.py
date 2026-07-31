#!/usr/bin/env python3
"""Analyze SF2/MIDI wavetable address locality for cache and DDR planning.

This tool does not render audio. It expands MIDI Note On events through the SF2
preset/instrument/sample tables, then simulates only the Q24.8 sample-address
walk for each selected sample stream. The output is intended to answer memory
architecture questions: how often endpoints cross cache lines, how long a stream
stays in a line, and how many new lines a prefetch window must cover.
"""

import argparse
from array import array
from concurrent.futures import ProcessPoolExecutor, as_completed
import json
import math
import os
from collections import Counter, defaultdict, deque
from dataclasses import dataclass
from pathlib import Path
import statistics
import struct
import sys
import time

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from sf2_extract import (  # noqa: E402
    GEN_COARSE_TUNE,
    GEN_FINE_TUNE,
    GEN_INSTRUMENT,
    GEN_KEY_RANGE,
    GEN_OVERRIDING_ROOT_KEY,
    GEN_SAMPLE_ID,
    GEN_SAMPLE_MODES,
    GEN_VEL_RANGE,
    find_chunk,
    instrument_zones,
    key_range,
    list_chunks,
    list_chunks_with_offsets,
    parse_bags,
    parse_generators,
    parse_instruments,
    parse_presets,
    parse_samples,
    preset_zones,
    select_preset,
    signed_amount,
    vel_range,
)
from midi_events import MidiEvent, parse_midi_events as parse_shared_midi_events  # noqa: E402


PHASE_FRAC_BITS = 8
PHASE_FRAC_SCALE = 1 << PHASE_FRAC_BITS
PHASE_FRAME_MASK = (1 << 24) - 1

GEN_START_ADDRS_OFFSET = 0
GEN_END_ADDRS_OFFSET = 1
GEN_STARTLOOP_ADDRS_OFFSET = 2
GEN_ENDLOOP_ADDRS_OFFSET = 3
GEN_START_ADDRS_COARSE_OFFSET = 4
GEN_END_ADDRS_COARSE_OFFSET = 12
GEN_STARTLOOP_ADDRS_COARSE_OFFSET = 45
GEN_KEYNUM = 46
GEN_ENDLOOP_ADDRS_COARSE_OFFSET = 50
GEN_SCALE_TUNING = 56


@dataclass
class SampleStream:
    stream_id: int
    note_index: int
    channel: int
    note: int
    velocity: int
    start_frame: int
    end_frame: int
    release_frame: int
    program: int
    bank: int
    preset: str
    instrument: str
    sample_id: int
    sample_name: str
    sample_type: int
    base_addr: int
    length: int
    loop_start: int
    loop_end: int
    loop_mode: int
    phase_inc: int
    sample_rate: int
    original_pitch: int


def parse_midi_events(path):
    return [event for event in parse_shared_midi_events(path)
            if event.event_type != "program"]


def load_sf2_tables(path):
    data = Path(path).read_bytes()
    sdta_offsets = list_chunks_with_offsets(data, b"sdta")
    pdta = list_chunks(find_chunk(data, b"pdta"))
    if b"smpl" not in sdta_offsets:
        raise ValueError("SF2 sdta LIST has no smpl chunk")
    _smpl_data, smpl_payload = sdta_offsets[b"smpl"]
    if smpl_payload & 1:
        raise ValueError("SF2 smpl payload is not word aligned")
    return {
        "smpl_word_offset": smpl_payload // 2,
        "presets": parse_presets(pdta[b"phdr"]),
        "preset_bags": parse_bags(pdta[b"pbag"]),
        "preset_generators": parse_generators(pdta[b"pgen"]),
        "instruments": parse_instruments(pdta[b"inst"]),
        "instrument_bags": parse_bags(pdta[b"ibag"]),
        "instrument_generators": parse_generators(pdta[b"igen"]),
        "samples": parse_samples(pdta[b"shdr"]),
    }


def zone_matches(zone, key, velocity):
    key_low, key_high = key_range(zone)
    vel_low, vel_high = vel_range(zone)
    return key_low <= key <= key_high and vel_low <= velocity <= vel_high


def matching_regions_for_note(tables, program, bank, key, velocity):
    preset_index, preset = select_preset(tables["presets"], program, bank)
    regions = []
    for pzone in preset_zones(tables["presets"], tables["preset_bags"],
                              tables["preset_generators"], preset_index):
        if GEN_INSTRUMENT not in pzone or not zone_matches(pzone, key, velocity):
            continue
        inst_index = pzone[GEN_INSTRUMENT]
        if inst_index >= len(tables["instruments"]) - 1:
            continue
        instrument = tables["instruments"][inst_index]
        for izone in instrument_zones(tables["instruments"], tables["instrument_bags"],
                                      tables["instrument_generators"], inst_index):
            if GEN_SAMPLE_ID not in izone or not zone_matches(izone, key, velocity):
                continue
            zone = dict(pzone)
            zone.update(izone)
            sample_id = zone[GEN_SAMPLE_ID]
            if 0 <= sample_id < len(tables["samples"]) - 1:
                regions.append((preset, instrument, sample_id, zone))
    return regions


def sample_offset(zone, fine_oper, coarse_oper):
    fine = signed_amount(zone.get(fine_oper, 0))
    coarse = signed_amount(zone.get(coarse_oper, 0)) * 32768
    return fine + coarse


def clamp(value, low, high):
    return max(low, min(high, value))


def sample_window(sample, zone):
    header_start = max(0, sample.start)
    header_end = max(header_start, sample.end)
    start = clamp(sample.start + sample_offset(zone, GEN_START_ADDRS_OFFSET,
                                               GEN_START_ADDRS_COARSE_OFFSET),
                  header_start, header_end)
    end = clamp(sample.end + sample_offset(zone, GEN_END_ADDRS_OFFSET,
                                           GEN_END_ADDRS_COARSE_OFFSET),
                start, header_end)
    start_loop = clamp(sample.start_loop + sample_offset(zone, GEN_STARTLOOP_ADDRS_OFFSET,
                                                        GEN_STARTLOOP_ADDRS_COARSE_OFFSET),
                       start, end)
    end_loop = clamp(sample.end_loop + sample_offset(zone, GEN_ENDLOOP_ADDRS_OFFSET,
                                                    GEN_ENDLOOP_ADDRS_COARSE_OFFSET),
                     start_loop, end)
    length = min(end - start, PHASE_FRAME_MASK)
    if length <= 0:
        return None
    loop_start = min(max(0, start_loop - start), length - 1)
    loop_end = max(loop_start + 1, min(max(0, end_loop - start), length))
    return start, length, loop_start, loop_end


def loop_mode_from_zone(zone):
    sample_modes = zone.get(GEN_SAMPLE_MODES, 0) & 0x3
    if sample_modes == 1:
        return 1
    if sample_modes == 3:
        return 2
    return 0


def phase_inc_for_key(key, zone, sample, output_sample_rate):
    effective_key = key
    if GEN_KEYNUM in zone:
        forced_key = signed_amount(zone[GEN_KEYNUM])
        if 0 <= forced_key <= 127:
            effective_key = forced_key
    sample_root = sample.original_pitch if 0 <= sample.original_pitch <= 127 else 60
    root_key = sample_root
    if GEN_OVERRIDING_ROOT_KEY in zone:
        override_key = signed_amount(zone[GEN_OVERRIDING_ROOT_KEY])
        if 0 <= override_key <= 127:
            root_key = override_key
    scale_tuning = signed_amount(zone.get(GEN_SCALE_TUNING, 100))
    scale_tuning = max(0, min(1200, scale_tuning))
    cents = ((effective_key - root_key) * scale_tuning + sample.pitch_correction +
             signed_amount(zone.get(GEN_FINE_TUNE, 0)) +
             signed_amount(zone.get(GEN_COARSE_TUNE, 0)) * 100)
    rate_ratio = (sample.sample_rate / output_sample_rate) * math.pow(2.0, cents / 1200.0)
    return max(1, min(0xFFFFFFFF, int(round(rate_ratio * PHASE_FRAC_SCALE))))


def build_note_intervals(events, sample_rate, seconds, release_ms, default_note_seconds):
    last_event_seconds = max((e.time_seconds for e in events), default=0.0)
    if seconds is None:
        seconds = max(last_event_seconds, default_note_seconds)
    note_on_count = sum(1 for e in events if e.event_type == "note_on" and e.time_seconds <= seconds)
    total_frames = max(1, int(round(seconds * sample_rate)))
    pending = defaultdict(deque)
    intervals = []
    note_index = 0
    for event in sorted(events, key=lambda e: (e.time_seconds, e.order)):
        if event.time_seconds > seconds:
            break
        key = (event.channel, event.note)
        if event.event_type == "note_on":
            pending[key].append((note_index, event))
            note_index += 1
        elif event.event_type == "note_off" and pending[key]:
            index, on = pending[key].popleft()
            start = int(round(on.time_seconds * sample_rate))
            release = int(round(event.time_seconds * sample_rate))
            end = release + int(round(release_ms * sample_rate / 1000.0))
            intervals.append((index, on, start, min(total_frames, max(start + 1, end)), release))
    for queue in pending.values():
        for index, on in queue:
            start = int(round(on.time_seconds * sample_rate))
            fallback_end = start + int(round(default_note_seconds * sample_rate))
            end = min(total_frames, max(start + 1, fallback_end))
            intervals.append((index, on, start, end, end))
    intervals.sort(key=lambda item: (item[2], item[0]))
    return intervals, total_frames, note_on_count


def build_streams(tables, intervals, sample_rate):
    streams = []
    stream_id = 0
    skipped = Counter()
    for note_index, event, start_frame, end_frame, release_frame in intervals:
        regions = matching_regions_for_note(tables, event.program, event.bank, event.note, event.velocity)
        if not regions:
            skipped["unmapped_note_regions"] += 1
            continue
        for preset, instrument, sample_id, zone in regions:
            sample = tables["samples"][sample_id]
            window = sample_window(sample, zone)
            if window is None:
                skipped["empty_sample_windows"] += 1
                continue
            start, length, loop_start, loop_end = window
            streams.append(SampleStream(
                stream_id=stream_id,
                note_index=note_index,
                channel=event.channel,
                note=event.note,
                velocity=event.velocity,
                start_frame=start_frame,
                end_frame=end_frame,
                release_frame=release_frame,
                program=event.program,
                bank=event.bank,
                preset=preset.name,
                instrument=instrument.name,
                sample_id=sample_id,
                sample_name=sample.name,
                sample_type=sample.sample_type & 0x7FFF,
                base_addr=tables["smpl_word_offset"] + start,
                length=length,
                loop_start=loop_start,
                loop_end=loop_end,
                loop_mode=loop_mode_from_zone(zone),
                phase_inc=phase_inc_for_key(event.note, zone, sample, sample_rate),
                sample_rate=sample.sample_rate,
                original_pitch=sample.original_pitch,
            ))
            stream_id += 1
    return streams, skipped


def percentile(values, fraction):
    if not values:
        return 0
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(math.ceil(fraction * len(ordered))) - 1)
    return ordered[index]


def summarize_values(values):
    if not values:
        return {"min": 0, "avg": 0.0, "p50": 0, "p95": 0, "p99": 0, "max": 0}
    return {
        "min": min(values),
        "avg": statistics.fmean(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "p99": percentile(values, 0.99),
        "max": max(values),
    }


def summarize_midi_events(events):
    event_counts = Counter(event.event_type for event in events)
    controls = [event for event in events if event.event_type == "control"]
    pitch_bends = [event for event in events if event.event_type == "pitch_bend"]
    sustain = [event for event in controls if event.controller == 64]
    rpn_data = [event for event in controls if event.controller in (6, 38, 100, 101)]
    return {
        "event_counts": dict(sorted(event_counts.items())),
        "pitch_bend_events": len(pitch_bends),
        "pitch_bend_channels": sorted({event.channel for event in pitch_bends}),
        "sustain_events": len(sustain),
        "sustain_on_events": sum(event.value >= 64 for event in sustain),
        "rpn_control_events": len(rpn_data),
    }


def stream_identity(stream):
    return {
        "stream_id": stream.stream_id,
        "sample_id": stream.sample_id,
        "sample": stream.sample_name,
        "instrument": stream.instrument,
        "preset": stream.preset,
        "channel": stream.channel,
        "note": stream.note,
        "velocity": stream.velocity,
        "sample_rate": stream.sample_rate,
        "phase_inc": stream.phase_inc,
        "source_frames_per_output": stream.phase_inc / PHASE_FRAC_SCALE,
    }


def summarize_workload(streams, top_count):
    phase_steps = [stream.phase_inc / PHASE_FRAC_SCALE for stream in streams]
    thresholds = []
    for minimum in (1.0, 2.0, 4.0, 8.0):
        count = sum(step >= minimum for step in phase_steps)
        thresholds.append({
            "minimum_source_frames_per_output": minimum,
            "stream_count": count,
            "stream_fraction": count / len(streams) if streams else 0.0,
        })

    top_phase = sorted(streams, key=lambda stream: stream.phase_inc, reverse=True)
    loop_groups = {}
    for stream in streams:
        if stream.loop_mode == 0:
            continue
        key = (stream.sample_id, stream.base_addr, stream.loop_start,
               stream.loop_end, stream.loop_mode)
        if key not in loop_groups:
            loop_groups[key] = {
                "sample_id": stream.sample_id,
                "sample": stream.sample_name,
                "instrument": stream.instrument,
                "preset": stream.preset,
                "base_addr": stream.base_addr,
                "loop_start": stream.loop_start,
                "loop_end": stream.loop_end,
                "loop_mode": stream.loop_mode,
                "loop_span_words": stream.loop_end - stream.loop_start,
                "loop_span_bytes": (stream.loop_end - stream.loop_start) * 2,
                "trigger_count": 0,
                "minimum_note": stream.note,
                "maximum_note": stream.note,
                "maximum_phase_inc": stream.phase_inc,
                "maximum_source_frames_per_output": stream.phase_inc / PHASE_FRAC_SCALE,
            }
        group = loop_groups[key]
        group["trigger_count"] += 1
        group["minimum_note"] = min(group["minimum_note"], stream.note)
        group["maximum_note"] = max(group["maximum_note"], stream.note)
        if stream.phase_inc > group["maximum_phase_inc"]:
            group["maximum_phase_inc"] = stream.phase_inc
            group["maximum_source_frames_per_output"] = stream.phase_inc / PHASE_FRAC_SCALE

    loop_regions = sorted(loop_groups.values(),
                          key=lambda item: item["loop_span_words"], reverse=True)
    return {
        "unique_sample_count": len({stream.sample_id for stream in streams}),
        "phase_step_source_frames_per_output": summarize_values(phase_steps),
        "phase_step_thresholds": thresholds,
        "top_phase_step_streams": [stream_identity(stream)
                                   for stream in top_phase[:top_count]],
        "looping_stream_count": sum(stream.loop_mode != 0 for stream in streams),
        "unique_loop_region_count": len(loop_regions),
        "loop_wrap_span_words": summarize_values(
            [item["loop_span_words"] for item in loop_regions]),
        "top_loop_wrap_regions": loop_regions[:top_count],
    }


def frame_pair(stream, phase, loop_active):
    frame_0 = (phase >> PHASE_FRAC_BITS) & PHASE_FRAME_MASK
    if frame_0 >= stream.length:
        return None
    if loop_active:
        frame_1 = stream.loop_start if frame_0 + 1 >= stream.loop_end else frame_0 + 1
    else:
        frame_1 = frame_0 if frame_0 + 1 >= stream.length else frame_0 + 1
    return frame_0, frame_1


def next_phase(stream, phase, loop_active):
    phase_sum = phase + stream.phase_inc
    if loop_active:
        loop_end_phase = stream.loop_end << PHASE_FRAC_BITS
        loop_length_phase = (stream.loop_end - stream.loop_start) << PHASE_FRAC_BITS
        if phase_sum >= loop_end_phase:
            return phase_sum - loop_length_phase
    return phase_sum & 0xFFFFFFFF


def frames_until_phase_at_least(phase, phase_inc, threshold):
    if threshold <= phase:
        return 1
    return max(1, (threshold - phase + phase_inc - 1) // phase_inc)


def endpoint_lines(stream, phase, loop_active, line_words):
    pair = frame_pair(stream, phase, loop_active)
    if pair is None:
        return None
    frame_0, frame_1 = pair
    line0 = (stream.base_addr + frame_0) // line_words
    line1 = (stream.base_addr + frame_1) // line_words
    return frame_0, frame_1, line0, line1


def segment_length_for_lines(stream, frame, phase, loop_active, line_words, end_limit,
                             info=None):
    if info is None:
        info = endpoint_lines(stream, phase, loop_active, line_words)
    if info is None:
        return 0
    frame_0, _frame_1, line0, _line1 = info
    candidates = [end_limit - frame]

    next_line_start = (line0 + 1) * line_words - stream.base_addr
    if next_line_start > frame_0:
        candidates.append(frames_until_phase_at_least(phase, stream.phase_inc,
                                                      next_line_start << PHASE_FRAC_BITS))
    endpoint_cross_frame = next_line_start - 1
    if endpoint_cross_frame > frame_0:
        candidates.append(frames_until_phase_at_least(phase, stream.phase_inc,
                                                      endpoint_cross_frame << PHASE_FRAC_BITS))

    if loop_active:
        loop_endpoint_frame = stream.loop_end - 1
        if loop_endpoint_frame > frame_0:
            candidates.append(frames_until_phase_at_least(phase, stream.phase_inc,
                                                          loop_endpoint_frame << PHASE_FRAC_BITS))
        candidates.append(frames_until_phase_at_least(phase, stream.phase_inc,
                                                      stream.loop_end << PHASE_FRAC_BITS))
    else:
        if stream.length > frame_0:
            candidates.append(frames_until_phase_at_least(phase, stream.phase_inc,
                                                          stream.length << PHASE_FRAC_BITS))

    return max(1, min(count for count in candidates if count > 0))


def advance_phase_by(stream, phase, frames, loop_active):
    phase_sum = phase + stream.phase_inc * frames
    if loop_active:
        loop_end_phase = stream.loop_end << PHASE_FRAC_BITS
        loop_length_phase = (stream.loop_end - stream.loop_start) << PHASE_FRAC_BITS
        if phase_sum >= loop_end_phase:
            wraps = (phase_sum - loop_end_phase) // loop_length_phase + 1
            phase_sum -= wraps * loop_length_phase
    return phase_sum & 0xFFFFFFFF


def analyze_for_line_words(streams, total_frames, sample_rate, line_words,
                           lookahead_ms_values, top_count):
    endpoint_reads = 0
    stream_line_fills = 0
    maximum_line = max(
        ((stream.base_addr + stream.length) // line_words for stream in streams),
        default=0,
    )
    physical_seen_lines = bytearray(maximum_line + 1)
    stream_line_marks = array("I", [0]) * (maximum_line + 1)
    physical_unique_lines = 0
    per_frame_stream_new = [0] * total_frames
    per_frame_physical_new = [0] * total_frames
    active_deltas = [0] * (total_frames + 1)
    frames_per_output_values = []
    estimated_line_dwell_values = []
    max_line_jump_values = []
    per_sample = {}
    stream_summaries = []

    for stream in streams:
        phase = 0
        previous_line0 = None
        last_line0 = None
        dwell = 0
        dwell_values = []
        stream_unique_lines = 0
        stream_marker = stream.stream_id + 1
        cross_line_frames = 0
        same_line_frames = 0
        frames_with_line_jump = 0
        max_line_jump = 0
        active_frames = 0
        stream_endpoint_reads = 0
        first = None
        last = None
        frames_per_output = stream.phase_inc / PHASE_FRAC_SCALE
        estimated_line_dwell = line_words / frames_per_output if frames_per_output > 0 else 0.0
        frames_per_output_values.append(frames_per_output)
        estimated_line_dwell_values.append(estimated_line_dwell)

        frame = stream.start_frame
        end_frame = min(stream.end_frame, total_frames)
        while frame < end_frame:
            loop_active = stream.loop_mode == 1 or (stream.loop_mode == 2 and frame < stream.release_frame)
            end_limit = min(end_frame, stream.release_frame) if loop_active and stream.loop_mode == 2 else end_frame
            if end_limit <= frame:
                continue
            line_info = endpoint_lines(stream, phase, loop_active, line_words)
            if line_info is None:
                break
            _frame_0, _frame_1, line0, line1 = line_info
            lines = (line0,) if line0 == line1 else (line0, line1)
            frames_this = segment_length_for_lines(
                stream, frame, phase, loop_active, line_words, end_limit, line_info)

            endpoint_reads += 2 * frames_this
            stream_endpoint_reads += 2 * frames_this
            active_frames += frames_this
            first = frame if first is None else first
            last = frame + frames_this - 1
            if line0 == line1:
                same_line_frames += frames_this
            else:
                cross_line_frames += frames_this
            if previous_line0 is not None:
                line_jump = abs(line0 - previous_line0)
                if line_jump:
                    frames_with_line_jump += 1
                    max_line_jump = max(max_line_jump, line_jump)
            previous_line0 = line0

            if last_line0 is None:
                last_line0 = line0
                dwell = frames_this
            elif line0 == last_line0:
                dwell += frames_this
            else:
                dwell_values.append(dwell)
                last_line0 = line0
                dwell = frames_this

            for line in lines:
                if stream_line_marks[line] != stream_marker:
                    stream_line_marks[line] = stream_marker
                    stream_unique_lines += 1
                    stream_line_fills += 1
                    per_frame_stream_new[frame] += 1
                if not physical_seen_lines[line]:
                    physical_seen_lines[line] = 1
                    physical_unique_lines += 1
                    per_frame_physical_new[frame] += 1

            phase = advance_phase_by(stream, phase, frames_this, loop_active)
            frame += frames_this

        if dwell:
            dwell_values.append(dwell)

        info = {
            "stream_id": stream.stream_id,
            "sample_id": stream.sample_id,
            "sample": stream.sample_name,
            "preset": stream.preset,
            "instrument": stream.instrument,
            "channel": stream.channel,
            "note": stream.note,
            "velocity": stream.velocity,
            "start_frame": stream.start_frame,
            "end_frame": last + 1 if last is not None else stream.start_frame,
            "active_frames": active_frames,
            "phase_inc": stream.phase_inc,
            "source_frames_per_output": frames_per_output,
            "estimated_line_dwell_frames": estimated_line_dwell,
            "base_addr": stream.base_addr,
            "length": stream.length,
            "loop_start": stream.loop_start,
            "loop_end": stream.loop_end,
            "loop_mode": stream.loop_mode,
            "endpoint_reads": stream_endpoint_reads,
            "stream_line_fills": stream_unique_lines,
            "same_line_endpoint_frames": same_line_frames,
            "cross_line_endpoint_frames": cross_line_frames,
            "cross_line_endpoint_rate": cross_line_frames / active_frames if active_frames else 0.0,
            "frames_with_line_jump": frames_with_line_jump,
            "line_jump_rate": frames_with_line_jump / active_frames if active_frames else 0.0,
            "max_frame_to_frame_line_jump": max_line_jump,
            "line_dwell_frames": summarize_values(dwell_values),
        }
        stream_summaries.append(info)
        max_line_jump_values.append(max_line_jump)
        if active_frames:
            active_deltas[first] += 1
            active_deltas[last + 1] -= 1

        sample_key = str(stream.sample_id)
        if sample_key not in per_sample:
            per_sample[sample_key] = {
                "sample_id": stream.sample_id,
                "sample": stream.sample_name,
                "sample_rate": stream.sample_rate,
                "trigger_count": 0,
                "active_frames": 0,
                "endpoint_reads": 0,
                "stream_line_fills": 0,
                "cross_line_endpoint_frames": 0,
                "active_frames_with_line_jump": 0,
                "max_frame_to_frame_line_jump": 0,
                "phase_inc_values": [],
                "source_frames_per_output_values": [],
                "estimated_line_dwell_values": [],
                "line_dwell_values": [],
            }
        s = per_sample[sample_key]
        s["trigger_count"] += 1
        s["active_frames"] += active_frames
        s["endpoint_reads"] += stream_endpoint_reads
        s["stream_line_fills"] += stream_unique_lines
        s["cross_line_endpoint_frames"] += cross_line_frames
        s["active_frames_with_line_jump"] += frames_with_line_jump
        s["max_frame_to_frame_line_jump"] = max(s["max_frame_to_frame_line_jump"], max_line_jump)
        s["phase_inc_values"].append(stream.phase_inc)
        s["source_frames_per_output_values"].append(frames_per_output)
        s["estimated_line_dwell_values"].append(estimated_line_dwell)
        s["line_dwell_values"].extend(dwell_values)

    sample_summaries = []
    for item in per_sample.values():
        phase_values = item.pop("phase_inc_values")
        frames_per_output_sample_values = item.pop("source_frames_per_output_values")
        estimated_line_dwell_sample_values = item.pop("estimated_line_dwell_values")
        dwell_values = item.pop("line_dwell_values")
        item["phase_inc"] = summarize_values(phase_values)
        item["source_frames_per_output"] = summarize_values(frames_per_output_sample_values)
        item["estimated_line_dwell_frames"] = summarize_values(estimated_line_dwell_sample_values)
        item["line_dwell_frames"] = summarize_values(dwell_values)
        item["reuse_ratio"] = (item["endpoint_reads"] / item["stream_line_fills"]
                               if item["stream_line_fills"] else 0.0)
        item["cross_line_endpoint_rate"] = (item["cross_line_endpoint_frames"] / item["active_frames"]
                                            if item["active_frames"] else 0.0)
        item["line_jump_rate"] = (item["active_frames_with_line_jump"] / item["active_frames"]
                                  if item["active_frames"] else 0.0)
        sample_summaries.append(item)
    sample_summaries.sort(key=lambda item: (item["stream_line_fills"], item["endpoint_reads"]), reverse=True)
    stream_summaries.sort(key=lambda item: (item["stream_line_fills"], item["endpoint_reads"]), reverse=True)

    active_values = []
    endpoint_read_values = []
    active = 0
    for frame in range(total_frames):
        active += active_deltas[frame]
        active_values.append(active)
        endpoint_read_values.append(active * 2)

    lookahead = {}
    for lookahead_ms in lookahead_ms_values:
        window = max(1, int(round(lookahead_ms * sample_rate / 1000.0)))
        stream_counts = []
        physical_counts = []
        for start in range(0, total_frames, window):
            end = min(total_frames, start + window)
            stream_counts.append(sum(per_frame_stream_new[start:end]))
            physical_counts.append(sum(per_frame_physical_new[start:end]))
        lookahead[str(lookahead_ms)] = {
            "frames": window,
            "stream_line_fills": summarize_values(stream_counts),
            "physical_unique_lines": summarize_values(physical_counts),
        }

    duration = total_frames / sample_rate
    return {
        "line_words": line_words,
        "duration_seconds": duration,
        "endpoint_reads": endpoint_reads,
        "endpoint_reads_per_second": endpoint_reads / duration if duration else 0.0,
        "stream_line_fills": stream_line_fills,
        "stream_line_fills_per_second": stream_line_fills / duration if duration else 0.0,
        "physical_unique_lines": physical_unique_lines,
        "physical_unique_lines_per_second": physical_unique_lines / duration if duration else 0.0,
        "endpoint_to_stream_line_reuse_ratio": endpoint_reads / stream_line_fills if stream_line_fills else 0.0,
        "endpoint_to_physical_line_reuse_ratio": endpoint_reads / physical_unique_lines if physical_unique_lines else 0.0,
        "source_frames_per_output": summarize_values(frames_per_output_values),
        "estimated_line_dwell_frames": summarize_values(estimated_line_dwell_values),
        "max_frame_to_frame_line_jump": summarize_values(max_line_jump_values),
        "active_streams_per_frame": summarize_values(active_values),
        "endpoint_reads_per_frame": summarize_values(endpoint_read_values),
        "new_stream_lines_per_frame": summarize_values(per_frame_stream_new),
        "new_physical_lines_per_frame": summarize_values(per_frame_physical_new),
        "lookahead_windows_ms": lookahead,
        "top_samples_by_stream_line_fills": sample_summaries[:top_count],
        "top_streams_by_stream_line_fills": stream_summaries[:top_count],
    }


def analyze_line_words_task(task):
    return analyze_for_line_words(*task)


def resolve_job_count(requested_jobs, task_count):
    if task_count <= 0:
        return 1
    if requested_jobs < 0:
        raise ValueError("analysis job count must be nonnegative")
    available = os.cpu_count() or 1
    jobs = available if requested_jobs == 0 else requested_jobs
    return max(1, min(jobs, task_count))


def analyze_line_sizes(streams, total_frames, sample_rate, line_words_values,
                       lookahead_ms_values, top_count, requested_jobs):
    tasks = [
        (streams, total_frames, sample_rate, line_words, lookahead_ms_values, top_count)
        for line_words in line_words_values
    ]
    jobs = resolve_job_count(requested_jobs, len(tasks))
    print(f"analysis: line_sizes={line_words_values} jobs={jobs}", file=sys.stderr)
    if jobs == 1:
        results = []
        for task in tasks:
            result = analyze_line_words_task(task)
            results.append(result)
            print(f"analysis: completed LINE_WORDS={result['line_words']}", file=sys.stderr)
        return results, jobs

    indexed_results = {}
    with ProcessPoolExecutor(max_workers=jobs) as executor:
        futures = {executor.submit(analyze_line_words_task, task): task[3]
                   for task in tasks}
        for future in as_completed(futures):
            result = future.result()
            indexed_results[result["line_words"]] = result
            print(f"analysis: completed LINE_WORDS={result['line_words']}", file=sys.stderr)
    return [indexed_results[line_words] for line_words in line_words_values], jobs


def print_text_report(result):
    workload = result["workload_summary"]
    phase = workload["phase_step_source_frames_per_output"]
    print(f"SF2: {result['sf2']}")
    if result.get("midi"):
        print(f"MIDI: {result['midi']}")
    print(f"duration={result['duration_seconds']:.3f}s sample_rate={result['sample_rate']}")
    print(f"analysis_jobs={result['analysis_jobs']} "
          f"elapsed={result['analysis_elapsed_seconds']:.3f}s")
    print(f"note_on_events={result['note_on_events']} streams={result['stream_count']} "
          f"unique_samples={workload['unique_sample_count']}")
    if result["skipped"]:
        print(f"skipped={result['skipped']}")
    if result.get("midi_summary"):
        midi = result["midi_summary"]
        print(f"midi pitch_bends={midi['pitch_bend_events']} "
              f"sustain_events={midi['sustain_events']} "
              f"rpn_controls={midi['rpn_control_events']}")
    print(f"phase_step source_frames/output min={phase['min']:.3f} "
          f"p50={phase['p50']:.3f} p95={phase['p95']:.3f} "
          f"p99={phase['p99']:.3f} max={phase['max']:.3f}")
    print("phase thresholds: " + ", ".join(
        f">={item['minimum_source_frames_per_output']:.0f}: "
        f"{item['stream_count']} ({item['stream_fraction']:.2%})"
        for item in workload["phase_step_thresholds"]))
    print("top phase-step streams:")
    for stream in workload["top_phase_step_streams"][:5]:
        print(f"  sample_id={stream['sample_id']} {stream['sample']!r} "
              f"instrument={stream['instrument']!r} ch={stream['channel']} "
              f"note={stream['note']} phase_inc={stream['phase_inc']} "
              f"step={stream['source_frames_per_output']:.3f}")
    if workload["top_loop_wrap_regions"]:
        loop = workload["top_loop_wrap_regions"][0]
        print(f"largest loop wrap: sample_id={loop['sample_id']} {loop['sample']!r} "
              f"instrument={loop['instrument']!r} span_words={loop['loop_span_words']} "
              f"span_bytes={loop['loop_span_bytes']}")
    for note in result["model_scope"]:
        print(f"scope: {note}")
    print()
    for line in result["line_results"]:
        print(f"LINE_WORDS={line['line_words']}")
        print(f"  endpoint_reads/s={line['endpoint_reads_per_second']:.1f}")
        print(f"  stream_line_fills/s={line['stream_line_fills_per_second']:.1f}")
        print(f"  physical_unique_lines/s={line['physical_unique_lines_per_second']:.1f}")
        print(f"  endpoint/stream-line reuse={line['endpoint_to_stream_line_reuse_ratio']:.2f}")
        print(f"  source frames/output avg={line['source_frames_per_output']['avg']:.3f} "
              f"p95={line['source_frames_per_output']['p95']:.3f} "
              f"max={line['source_frames_per_output']['max']:.3f}")
        print(f"  estimated line dwell frames avg={line['estimated_line_dwell_frames']['avg']:.2f} "
              f"p50={line['estimated_line_dwell_frames']['p50']:.2f} "
              f"min={line['estimated_line_dwell_frames']['min']:.2f}")
        print(f"  active_streams/frame max={line['active_streams_per_frame']['max']} "
              f"p99={line['active_streams_per_frame']['p99']}")
        print(f"  new_stream_lines/frame max={line['new_stream_lines_per_frame']['max']} "
              f"p99={line['new_stream_lines_per_frame']['p99']}")
        print(f"  new_physical_lines/frame max={line['new_physical_lines_per_frame']['max']} "
              f"p99={line['new_physical_lines_per_frame']['p99']}")
        jumps = line["max_frame_to_frame_line_jump"]
        print(f"  max line jump p99={jumps['p99']} max={jumps['max']} "
              f"(sample words p99={jumps['p99'] * line['line_words']} "
              f"max={jumps['max'] * line['line_words']})")
        for ms, stats in line["lookahead_windows_ms"].items():
            fills = stats["stream_line_fills"]
            phys = stats["physical_unique_lines"]
            print(f"  lookahead {ms}ms: stream-line max={fills['max']} p99={fills['p99']} "
                  f"physical max={phys['max']} p99={phys['p99']}")
        print("  top samples:")
        for sample in line["top_samples_by_stream_line_fills"][:5]:
            print(f"    id={sample['sample_id']} {sample['sample']!r} "
                  f"triggers={sample['trigger_count']} fills={sample['stream_line_fills']} "
                  f"src_frames/out_avg={sample['source_frames_per_output']['avg']:.2f} "
                  f"cross_line_rate={sample['cross_line_endpoint_rate']:.3f} "
                  f"dwell_avg={sample['line_dwell_frames']['avg']:.2f} "
                  f"dwell_min={sample['line_dwell_frames']['min']}")
        print()


def write_markdown(path, result):
    workload = result["workload_summary"]
    phase = workload["phase_step_source_frames_per_output"]
    lines = [
        "# SF2 Access Span Report",
        "",
        f"- SF2: `{result['sf2']}`",
        f"- MIDI: `{result.get('midi') or '<none>'}`",
        f"- Duration: `{result['duration_seconds']:.3f}s`",
        f"- Sample rate: `{result['sample_rate']}`",
        f"- Analysis jobs: `{result['analysis_jobs']}`",
        f"- Analysis elapsed time: `{result['analysis_elapsed_seconds']:.3f}s`",
        f"- Note On events: `{result['note_on_events']}`",
        f"- Sample streams: `{result['stream_count']}`",
        f"- Unique samples: `{workload['unique_sample_count']}`",
        f"- Looping streams: `{workload['looping_stream_count']}`",
        "",
        "## Model Scope",
        "",
    ]
    for note in result["model_scope"]:
        lines.append(f"- {note}")
    if result.get("midi_summary"):
        midi = result["midi_summary"]
        lines.extend([
            "",
            "## MIDI Workload",
            "",
            f"- Pitch-bend events present: `{midi['pitch_bend_events']}` on channels "
            f"`{midi['pitch_bend_channels']}`",
            f"- Sustain-controller events present: `{midi['sustain_events']}` "
            f"(`{midi['sustain_on_events']}` engage sustain)",
            f"- RPN/data-entry controller events present: `{midi['rpn_control_events']}`",
        ])
    lines.extend([
        "",
        "## Phase Step Distribution",
        "",
        "Phase step is the static source-sample advance per output frame before runtime pitch controls.",
        "",
        "| Min | P50 | Average | P95 | P99 | Max |",
        "| ---: | ---: | ---: | ---: | ---: | ---: |",
        f"| {phase['min']:.4f} | {phase['p50']:.4f} | {phase['avg']:.4f} | "
        f"{phase['p95']:.4f} | {phase['p99']:.4f} | {phase['max']:.4f} |",
        "",
        "| Minimum source frames/output | Streams | Fraction |",
        "| ---: | ---: | ---: |",
    ])
    for item in workload["phase_step_thresholds"]:
        lines.append(
            f"| {item['minimum_source_frames_per_output']:.0f} | "
            f"{item['stream_count']} | {item['stream_fraction']:.2%} |"
        )
    lines.extend([
        "",
        "### Largest Phase Steps",
        "",
        "| Sample ID | Sample | Instrument | Channel | Note | Phase increment | Source frames/output |",
        "| ---: | --- | --- | ---: | ---: | ---: | ---: |",
    ])
    for stream in workload["top_phase_step_streams"]:
        lines.append(
            f"| {stream['sample_id']} | `{stream['sample']}` | `{stream['instrument']}` | "
            f"{stream['channel']} | {stream['note']} | {stream['phase_inc']} | "
            f"{stream['source_frames_per_output']:.4f} |"
        )
    lines.extend([
        "",
        "## Loop Wrap Potential",
        "",
        "Loop span is the backward sample-address distance when playback wraps from loop end to loop start.",
        "",
        "| Sample ID | Sample | Instrument | Triggers | Notes | Span words | Span bytes | Max source frames/output |",
        "| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |",
    ])
    for loop in workload["top_loop_wrap_regions"]:
        notes = (str(loop["minimum_note"]) if loop["minimum_note"] == loop["maximum_note"]
                 else f"{loop['minimum_note']}..{loop['maximum_note']}")
        lines.append(
            f"| {loop['sample_id']} | `{loop['sample']}` | `{loop['instrument']}` | "
            f"{loop['trigger_count']} | {notes} | {loop['loop_span_words']} | "
            f"{loop['loop_span_bytes']} | {loop['maximum_source_frames_per_output']:.4f} |"
        )
    lines.extend([
        "",
        "## Line Access Summary",
        "",
        "| LINE_WORDS | endpoint reads/s | stream line fills/s | physical lines/s | reuse | max active | new stream lines/frame p99/max | new physical lines/frame p99/max |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ])
    for line in result["line_results"]:
        lines.append(
            f"| {line['line_words']} | {line['endpoint_reads_per_second']:.1f} | "
            f"{line['stream_line_fills_per_second']:.1f} | "
            f"{line['physical_unique_lines_per_second']:.1f} | "
            f"{line['endpoint_to_stream_line_reuse_ratio']:.2f} | "
            f"{line['active_streams_per_frame']['max']} | "
            f"{line['new_stream_lines_per_frame']['p99']}/{line['new_stream_lines_per_frame']['max']} | "
            f"{line['new_physical_lines_per_frame']['p99']}/{line['new_physical_lines_per_frame']['max']} |"
        )
    lines.extend(["", "## Lookahead Windows", ""])
    for line in result["line_results"]:
        lines.append(f"### LINE_WORDS={line['line_words']}")
        lines.append("")
        lines.append("| Lookahead ms | stream-line max | stream-line p99 | physical max | physical p99 |")
        lines.append("| ---: | ---: | ---: | ---: | ---: |")
        for ms, stats in line["lookahead_windows_ms"].items():
            fills = stats["stream_line_fills"]
            phys = stats["physical_unique_lines"]
            lines.append(f"| {ms} | {fills['max']} | {fills['p99']} | {phys['max']} | {phys['p99']} |")
        lines.append("")
    lines.extend(["", "## Line Dwell And Address Jumps", ""])
    lines.append("| LINE_WORDS | estimated dwell avg | estimated dwell min | line jump p99 | line jump max | sample-word jump p99 | sample-word jump max |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for line in result["line_results"]:
        dwell = line["estimated_line_dwell_frames"]
        jumps = line["max_frame_to_frame_line_jump"]
        lines.append(
            f"| {line['line_words']} | {dwell['avg']:.2f} | {dwell['min']:.2f} | "
            f"{jumps['p99']} | {jumps['max']} | "
            f"{jumps['p99'] * line['line_words']} | {jumps['max'] * line['line_words']} |"
        )
    lines.append("")
    lines.extend(["## Top Samples By Stream-Line Fills", ""])
    for line in result["line_results"]:
        lines.append(f"### LINE_WORDS={line['line_words']}")
        lines.append("")
        lines.append("| Sample ID | Sample | Triggers | Fills | src frames/output avg | cross-line rate | dwell avg | dwell min |")
        lines.append("| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
        for sample in line["top_samples_by_stream_line_fills"][:10]:
            lines.append(
                f"| {sample['sample_id']} | `{sample['sample']}` | {sample['trigger_count']} | "
                f"{sample['stream_line_fills']} | {sample['source_frames_per_output']['avg']:.3f} | "
                f"{sample['cross_line_endpoint_rate']:.4f} | "
                f"{sample['line_dwell_frames']['avg']:.2f} | {sample['line_dwell_frames']['min']} |"
            )
        lines.append("")
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_csv_ints(text):
    values = []
    for item in text.split(","):
        item = item.strip()
        if item:
            values.append(int(item, 0))
    if not values:
        raise ValueError("expected at least one integer")
    return values


def parse_csv_floats(text):
    values = []
    for item in text.split(","):
        item = item.strip()
        if item:
            values.append(float(item))
    if not values:
        raise ValueError("expected at least one number")
    return values


def main():
    analysis_started = time.perf_counter()
    parser = argparse.ArgumentParser(description="Analyze SF2/MIDI sample address line locality")
    parser.add_argument("--sf2", required=True, help="SoundFont2 file")
    parser.add_argument("--midi", help="Standard MIDI file. If omitted, analyze one synthetic note.")
    parser.add_argument("--key", type=int, default=60, help="Synthetic note key when --midi is omitted")
    parser.add_argument("--velocity", type=int, default=100, help="Synthetic note velocity when --midi is omitted")
    parser.add_argument("--program", type=int, default=0, help="Synthetic note MIDI program when --midi is omitted")
    parser.add_argument("--bank", type=int, default=0, help="Synthetic note MIDI bank when --midi is omitted")
    parser.add_argument("--sample-rate", type=int, default=48000)
    parser.add_argument("--seconds", type=float, help="Analysis duration. Defaults to MIDI length or synthetic note length.")
    parser.add_argument("--synthetic-note-seconds", type=float, default=2.0)
    parser.add_argument("--release-ms", type=float, default=0.0,
                        help="Extra address-walk time after MIDI Note Off for release-tail pressure.")
    parser.add_argument("--line-words", default="8,16,32,64",
                        help="Comma-separated cache line sizes in 16-bit sample words.")
    parser.add_argument("--lookahead-ms", default="1,2,5,10",
                        help="Comma-separated prefetch/lookahead window sizes.")
    parser.add_argument("--json-out", help="Write full JSON report")
    parser.add_argument("--md-out", help="Write compact Markdown report")
    parser.add_argument("--top-streams", type=int, default=20,
                        help="Maximum stream/sample/loop details retained in JSON and Markdown.")
    parser.add_argument("--jobs", type=int, default=0,
                        help="Parallel line-size workers; 0 selects one worker per line size.")
    args = parser.parse_args()
    if args.top_streams < 0:
        parser.error("--top-streams must be nonnegative")
    if args.jobs < 0:
        parser.error("--jobs must be nonnegative")

    tables = load_sf2_tables(args.sf2)
    events = []
    if args.midi:
        events = parse_midi_events(args.midi)
        intervals, total_frames, note_on_count = build_note_intervals(
            events, args.sample_rate, args.seconds, args.release_ms, args.synthetic_note_seconds)
    else:
        event = MidiEvent(
            time_seconds=0.0,
            order=0,
            event_type="note_on",
            channel=0,
            note=args.key,
            velocity=args.velocity,
            program=args.program,
            bank=args.bank,
        )
        seconds = args.seconds if args.seconds is not None else args.synthetic_note_seconds
        total_frames = max(1, int(round(seconds * args.sample_rate)))
        intervals = [(0, event, 0, total_frames, total_frames)]
        note_on_count = 1

    streams, skipped = build_streams(tables, intervals, args.sample_rate)
    line_words_values = parse_csv_ints(args.line_words)
    lookahead_ms_values = parse_csv_floats(args.lookahead_ms)
    line_results, analysis_jobs = analyze_line_sizes(
        streams, total_frames, args.sample_rate, line_words_values,
        lookahead_ms_values, args.top_streams, args.jobs)
    model_scope = [
        "Phase increment is static per stream; RPN pitch-bend range, pitch-bend events, "
        "and runtime pitch updates are not applied.",
        "Line fills count first touches per stream or physical address; finite cache capacity, "
        "conflicts, eviction, and replacement are not modeled.",
    ]
    if args.midi:
        model_scope.insert(
            0,
            "Stream lifetime follows Note On/Off pairing; sustain-pedal lifetime and allocator "
            "voice stealing are not modeled.",
        )
    result = {
        "sf2": args.sf2,
        "midi": args.midi,
        "sample_rate": args.sample_rate,
        "duration_seconds": total_frames / args.sample_rate,
        "analysis_jobs": analysis_jobs,
        "analysis_elapsed_seconds": time.perf_counter() - analysis_started,
        "total_frames": total_frames,
        "note_on_events": note_on_count,
        "stream_count": len(streams),
        "midi_summary": summarize_midi_events(events) if args.midi else None,
        "workload_summary": summarize_workload(streams, args.top_streams),
        "model_scope": model_scope,
        "skipped": dict(skipped),
        "line_words": line_words_values,
        "lookahead_ms": lookahead_ms_values,
        "line_results": line_results,
    }

    if args.json_out:
        Path(args.json_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json_out).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if args.md_out:
        Path(args.md_out).parent.mkdir(parents=True, exist_ok=True)
        write_markdown(args.md_out, result)
    print_text_report(result)


if __name__ == "__main__":
    main()
