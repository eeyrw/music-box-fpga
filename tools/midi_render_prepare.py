#!/usr/bin/env python3
"""Prepare a simple MIDI/note-list render for the RTL multi-voice testbench.

This is a simulation-control helper, not a synthesizer. It selects one SF2
instrument sample, writes the wave memory image, and converts note events into a
SystemVerilog include consumed by tb_render_midi_core.sv. Preset lookup,
velocity curves, modulators, and envelopes remain outside RTL.
"""

import argparse
import json
import math
import os
import struct
from dataclasses import dataclass

import sf2_extract


@dataclass
class NoteEvent:
    time_seconds: float
    note: int
    on: bool
    velocity: int = 100


def read_varlen(data, pos):
    value = 0
    while True:
        byte = data[pos]
        pos += 1
        value = (value << 7) | (byte & 0x7f)
        if (byte & 0x80) == 0:
            return value, pos


def parse_midi(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"MThd":
        raise ValueError("not a standard MIDI file")
    header_len, fmt, track_count, division = struct.unpack_from(">IHHH", data, 4)
    if division & 0x8000:
        raise ValueError("SMPTE time division is not supported")
    ticks_per_quarter = division
    pos = 8 + header_len
    tick_events = []
    tempo_events = [(0, 500000)]

    for _ in range(track_count):
        if data[pos:pos + 4] != b"MTrk":
            raise ValueError("missing MTrk chunk")
        size = struct.unpack_from(">I", data, pos + 4)[0]
        pos += 8
        end = pos + size
        tick = 0
        running_status = None
        while pos < end:
            delta, pos = read_varlen(data, pos)
            tick += delta
            status = data[pos]
            if status & 0x80:
                pos += 1
                running_status = status
            elif running_status is not None:
                status = running_status
            else:
                raise ValueError("MIDI running status without previous status")

            if status == 0xff:
                meta_type = data[pos]
                pos += 1
                length, pos = read_varlen(data, pos)
                payload = data[pos:pos + length]
                pos += length
                if meta_type == 0x51 and length == 3:
                    tempo_events.append((tick, int.from_bytes(payload, "big")))
                continue
            if status in (0xf0, 0xf7):
                length, pos = read_varlen(data, pos)
                pos += length
                continue

            event_type = status & 0xf0
            if event_type in (0x80, 0x90):
                note = data[pos]
                velocity = data[pos + 1]
                pos += 2
                tick_events.append((tick, note, event_type == 0x90 and velocity != 0, velocity))
            elif event_type in (0xa0, 0xb0, 0xe0):
                pos += 2
            elif event_type in (0xc0, 0xd0):
                pos += 1
            else:
                raise ValueError(f"unsupported MIDI status 0x{status:02x}")

    tempo_events.sort()
    tick_events.sort()
    tempo_index = 0
    last_tempo_tick = 0
    last_tempo_seconds = 0.0
    current_tempo = tempo_events[0][1]
    events = []
    for tick, note, on, velocity in tick_events:
        while tempo_index + 1 < len(tempo_events) and tempo_events[tempo_index + 1][0] <= tick:
            next_tick, next_tempo = tempo_events[tempo_index + 1]
            last_tempo_seconds += ((next_tick - last_tempo_tick) * current_tempo /
                                   ticks_per_quarter / 1_000_000.0)
            last_tempo_tick = next_tick
            current_tempo = next_tempo
            tempo_index += 1
        seconds = last_tempo_seconds + ((tick - last_tempo_tick) * current_tempo /
                                        ticks_per_quarter / 1_000_000.0)
        events.append(NoteEvent(seconds, note, on, velocity))
    return events


def parse_note_json(path):
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    notes = doc.get("notes", doc if isinstance(doc, list) else [])
    events = []
    for note in notes:
        key = int(note["note"])
        start = float(note["start"])
        duration = float(note["duration"])
        velocity = int(note.get("velocity", 100))
        events.append(NoteEvent(start, key, True, velocity))
        events.append(NoteEvent(start + duration, key, False, 0))
    events.sort(key=lambda e: (e.time_seconds, 0 if not e.on else 1, e.note))
    return events


def default_melody():
    notes = [60, 64, 67, 72, 67, 64, 60]
    events = []
    for i, note in enumerate(notes):
        start = i * 0.24
        events.append(NoteEvent(start, note, True, 110))
        events.append(NoteEvent(start + 0.20, note, False, 0))
    return events


def phase_inc_for_key(key, zone, sample_header, output_sample_rate):
    root_key = zone.get(sf2_extract.GEN_OVERRIDING_ROOT_KEY, sample_header.original_pitch)
    if root_key == 255:
        root_key = sample_header.original_pitch
    cents = ((key - root_key) * 100 + sample_header.pitch_correction +
             sf2_extract.signed_amount(zone.get(sf2_extract.GEN_FINE_TUNE, 0)) +
             sf2_extract.signed_amount(zone.get(sf2_extract.GEN_COARSE_TUNE, 0)) * 100)
    rate_ratio = (sample_header.sample_rate / output_sample_rate) * math.pow(2.0, cents / 1200.0)
    return max(1, min(0xffffffff, int(round(rate_ratio * 65536.0))))


def write_config(path, cfg, arrays):
    with open(path, "w", encoding="ascii") as f:
        f.write("// Generated by tools/midi_render_prepare.py\n")
        for key, value in cfg.items():
            if isinstance(value, str):
                f.write(f'localparam string {key} = "{value}";\n')
            else:
                f.write(f"localparam int unsigned {key} = {value};\n")
        for key, values in arrays.items():
            joined = ", ".join(str(v) for v in values)
            f.write(f"localparam int unsigned {key} [0:MIDI_EVENT_COUNT-1] = '{{{joined}}};\n")


def main():
    parser = argparse.ArgumentParser(description="Prepare a simple MIDI/note-list RTL render")
    parser.add_argument("--sf2", required=True)
    parser.add_argument("--instrument")
    parser.add_argument("--key", type=int, default=60, help="sample-selection key")
    parser.add_argument("--midi")
    parser.add_argument("--notes-json")
    parser.add_argument("--seconds", type=float, default=2.0)
    parser.add_argument("--sample-rate", type=int, default=48000)
    parser.add_argument("--attack-ms", type=float, default=100.0)
    parser.add_argument("--decay-ms", type=float, default=200.0)
    parser.add_argument("--release-ms", type=float, default=240.0)
    parser.add_argument("--adsr-tick-ms", type=float, default=5.0)
    parser.add_argument("--out-dir", default="build/render_midi")
    args = parser.parse_args()

    if args.midi and args.notes_json:
        raise ValueError("provide at most one of --midi or --notes-json")

    if args.midi:
        events = parse_midi(args.midi)
    elif args.notes_json:
        events = parse_note_json(args.notes_json)
    else:
        events = default_melody()
    if not events:
        raise ValueError("no note events found")

    with open(args.sf2, "rb") as f:
        data = f.read()
    sdta = sf2_extract.list_chunks(sf2_extract.find_chunk(data, b"sdta"))
    pdta = sf2_extract.list_chunks(sf2_extract.find_chunk(data, b"pdta"))
    instruments = sf2_extract.parse_instruments(pdta[b"inst"])
    bags = sf2_extract.parse_bags(pdta[b"ibag"])
    generators = sf2_extract.parse_generators(pdta[b"igen"])
    samples = sf2_extract.parse_samples(pdta[b"shdr"])
    inst_index, inst = sf2_extract.select_instrument(instruments, args.instrument)
    zone = sf2_extract.select_zone(sf2_extract.instrument_zones(instruments, bags, generators, inst_index), args.key)
    sample = samples[zone[sf2_extract.GEN_SAMPLE_ID]]
    words, left, right, stereo, length, loop_start, loop_end = sf2_extract.build_wave_words(sdta[b"smpl"], samples, sample)

    sample_count = max(1, int(round(args.seconds * args.sample_rate)))
    event_samples = [max(0, min(sample_count, int(round(e.time_seconds * args.sample_rate)))) for e in events]
    event_on = [1 if e.on else 0 for e in events]
    event_key = [max(0, min(127, e.note)) for e in events]
    event_velocity = [max(0, min(127, e.velocity)) for e in events]
    event_phase_inc = [phase_inc_for_key(e.note, zone, left, args.sample_rate) for e in events]

    os.makedirs(args.out_dir, exist_ok=True)
    memh = os.path.join(args.out_dir, "wave.memh")
    config_svh = os.path.join(args.out_dir, "midi_render_config.svh")
    config_json = os.path.join(args.out_dir, "midi_render_config.json")
    sf2_extract.write_memh(memh, words)
    cfg = {
        "MIDI_MEMORY_DEPTH": len(words),
        "MIDI_SAMPLE_COUNT": sample_count,
        "MIDI_STEREO": 1 if stereo else 0,
        "MIDI_BASE_ADDR": 0,
        "MIDI_LENGTH": length,
        "MIDI_LOOP_START": loop_start,
        "MIDI_LOOP_END": loop_end,
        "MIDI_GAIN_L": 0x4000,
        "MIDI_GAIN_R": 0x4000,
        "MIDI_ADSR_TICK_SAMPLES": max(1, int(round(args.adsr_tick_ms * args.sample_rate / 1000.0))),
        "MIDI_ADSR_ATTACK_STEP": max(1, int(round(0x7fff / max(1, args.attack_ms / args.adsr_tick_ms)))),
        "MIDI_ADSR_DECAY_STEP": max(1, int(round(0x7fff / max(1, args.decay_ms / args.adsr_tick_ms)))),
        "MIDI_ADSR_RELEASE_STEP": max(1, int(round(0x7fff / max(1, args.release_ms / args.adsr_tick_ms)))),
        "MIDI_EVENT_COUNT": len(events),
        "MIDI_MEMH": memh,
        "MIDI_PCM": os.path.join(args.out_dir, "out.pcm"),
    }
    arrays = {
        "MIDI_EVENT_SAMPLE": event_samples,
        "MIDI_EVENT_ON": event_on,
        "MIDI_EVENT_KEY": event_key,
        "MIDI_EVENT_VELOCITY": event_velocity,
        "MIDI_EVENT_PHASE_INC": event_phase_inc,
    }
    write_config(config_svh, cfg, arrays)
    with open(config_json, "w", encoding="utf-8") as f:
        json.dump({
            "instrument_index": inst_index,
            "instrument": inst.name,
            "sample_left": left.name,
            "sample_right": right.name if right else None,
            "stereo": stereo,
            "length": length,
            "loop_start": loop_start,
            "loop_end": loop_end,
            "sample_rate": left.sample_rate,
            "output_sample_rate": args.sample_rate,
            "output_samples": sample_count,
            "events": [e.__dict__ for e in events],
        }, f, indent=2)
        f.write("\n")
    print(f"prepared {len(events)} MIDI events for {sample_count} samples")
    print(f"instrument {inst_index}: {inst.name}, sample L: {left.name}" + (f", R: {right.name}" if right else ", mono"))


if __name__ == "__main__":
    main()
