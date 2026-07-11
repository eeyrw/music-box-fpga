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
    channel: int = 0
    program: int = 0
    bank: int = 0


@dataclass
class RenderRegion:
    key: int
    program: int
    bank: int
    preset: str
    instrument: str
    sample_left: str
    sample_right: str | None
    stereo: bool
    base_addr: int
    length: int
    loop_start: int
    loop_end: int
    phase_inc: int
    gain_l: int
    gain_r: int
    loop_mode: int
    sustain_level: int
    attack_step: int
    decay_step: int
    release_step: int


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
        channel_program = [0] * 16
        channel_bank_msb = [0] * 16
        channel_bank_lsb = [0] * 16
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
            channel = status & 0x0f
            if event_type in (0x80, 0x90):
                note = data[pos]
                velocity = data[pos + 1]
                pos += 2
                bank = (channel_bank_msb[channel] << 7) | channel_bank_lsb[channel]
                tick_events.append((tick, note, event_type == 0x90 and velocity != 0,
                                    velocity, channel, channel_program[channel], bank))
            elif event_type == 0xb0:
                controller = data[pos]
                value = data[pos + 1]
                pos += 2
                if controller == 0:
                    channel_bank_msb[channel] = value
                elif controller == 32:
                    channel_bank_lsb[channel] = value
            elif event_type in (0xa0, 0xe0):
                pos += 2
            elif event_type == 0xc0:
                channel_program[channel] = data[pos]
                pos += 1
            elif event_type == 0xd0:
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
    for tick, note, on, velocity, channel, program, bank in tick_events:
        while tempo_index + 1 < len(tempo_events) and tempo_events[tempo_index + 1][0] <= tick:
            next_tick, next_tempo = tempo_events[tempo_index + 1]
            last_tempo_seconds += ((next_tick - last_tempo_tick) * current_tempo /
                                   ticks_per_quarter / 1_000_000.0)
            last_tempo_tick = next_tick
            current_tempo = next_tempo
            tempo_index += 1
        seconds = last_tempo_seconds + ((tick - last_tempo_tick) * current_tempo /
                                        ticks_per_quarter / 1_000_000.0)
        events.append(NoteEvent(seconds, note, on, velocity, channel, program, bank))
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
        program = int(note.get("program", 0))
        bank = int(note.get("bank", 0))
        channel = int(note.get("channel", 0))
        events.append(NoteEvent(start, key, True, velocity, channel, program, bank))
        events.append(NoteEvent(start + duration, key, False, 0, channel, program, bank))
    events.sort(key=lambda e: (e.time_seconds, 0 if not e.on else 1, e.note))
    return events


def default_melody():
    notes = [60, 64, 67, 72, 67, 64, 60]
    events = []
    for i, note in enumerate(notes):
        start = i * 0.24
        events.append(NoteEvent(start, note, True, 110, 0, 0, 0))
        events.append(NoteEvent(start + 0.20, note, False, 0, 0, 0, 0))
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


def pan_gains(zone):
    pan = sf2_extract.signed_amount(zone.get(sf2_extract.GEN_PAN, 0))
    pan = max(-500, min(500, pan))
    left = int(round(0x4000 * (500 - pan) / 500)) if pan < 0 else 0x4000
    right = int(round(0x4000 * (500 + pan) / 500)) if pan > 0 else 0x4000
    attenuation_cb = zone.get(sf2_extract.GEN_INITIAL_ATTENUATION, 0)
    if attenuation_cb:
        scale = math.pow(10.0, -attenuation_cb / 200.0)
        left = int(round(left * scale))
        right = int(round(right * scale))
    return max(0, min(0x7fff, left)), max(0, min(0x7fff, right))


def timecents_to_seconds(value, default_timecents):
    timecents = sf2_extract.signed_amount(value) if value is not None else default_timecents
    if timecents <= -12000:
        return 0.0
    return min(100.0, math.pow(2.0, timecents / 1200.0))


def centibels_to_level(centibels):
    if centibels <= 0:
        return 0x7fff
    level = int(round(0x7fff * math.pow(10.0, -centibels / 200.0)))
    return max(0, min(0x7fff, level))


def envelope_step(seconds, tick_samples, sample_rate):
    ticks = max(1, int(round(seconds * sample_rate / tick_samples)))
    return max(1, min(0x7fff, int(round(0x7fff / ticks))))


def volume_envelope(zone, tick_samples, sample_rate):
    attack_seconds = timecents_to_seconds(zone.get(sf2_extract.GEN_ATTACK_VOL_ENV), -12000)
    decay_seconds = timecents_to_seconds(zone.get(sf2_extract.GEN_DECAY_VOL_ENV), -12000)
    release_seconds = timecents_to_seconds(zone.get(sf2_extract.GEN_RELEASE_VOL_ENV), -12000)
    sustain_cb = zone.get(sf2_extract.GEN_SUSTAIN_VOL_ENV, 0)
    sustain_level = centibels_to_level(sustain_cb)
    return (sustain_level,
            envelope_step(attack_seconds, tick_samples, sample_rate),
            envelope_step(decay_seconds, tick_samples, sample_rate),
            envelope_step(release_seconds, tick_samples, sample_rate))


def loop_mode_from_zone(zone):
    sample_modes = zone.get(sf2_extract.GEN_SAMPLE_MODES, 0) & 0x3
    if sample_modes == 1:
        return 1
    if sample_modes == 3:
        return 2
    return 0


def build_regions(events, sdta, presets, instruments, preset_bags, preset_generators,
                  instrument_bags, instrument_generators, samples, output_sample_rate,
                  adsr_tick_samples):
    regions = []
    region_by_key = {}
    words = []
    event_region = []
    for event in events:
        key = max(0, min(127, event.note))
        program = max(0, min(127, event.program))
        bank = max(0, min(16383, event.bank))
        # Channel 10 is General MIDI percussion. This first-pass renderer has no
        # drum-note mapping, so it falls back to bank 0 melodic preset 0.
        lookup_bank = 0 if event.channel == 9 else bank
        region_key = (program, lookup_bank, key, max(1, event.velocity) if event.on else 64)
        if region_key not in region_by_key:
            preset_index, preset, inst_index, inst, zone = sf2_extract.select_preset_region(
                presets, instruments, preset_bags, preset_generators,
                instrument_bags, instrument_generators, program, lookup_bank, key,
                max(1, event.velocity))
            sample = samples[zone[sf2_extract.GEN_SAMPLE_ID]]
            region_words, left, right, stereo, length, loop_start, loop_end = sf2_extract.build_wave_words(sdta, samples, sample)
            base_addr = len(words)
            words.extend(region_words)
            gain_l, gain_r = pan_gains(zone)
            sustain_level, attack_step, decay_step, release_step = volume_envelope(
                zone, adsr_tick_samples, output_sample_rate)
            region_by_key[region_key] = len(regions)
            regions.append(RenderRegion(
                key=key,
                program=program,
                bank=lookup_bank,
                preset=preset.name,
                instrument=inst.name,
                sample_left=left.name,
                sample_right=right.name if right else None,
                stereo=stereo,
                base_addr=base_addr,
                length=length,
                loop_start=loop_start,
                loop_end=loop_end,
                phase_inc=phase_inc_for_key(key, zone, left, output_sample_rate),
                gain_l=gain_l,
                gain_r=gain_r,
                loop_mode=loop_mode_from_zone(zone),
                sustain_level=sustain_level,
                attack_step=attack_step,
                decay_step=decay_step,
                release_step=release_step,
            ))
        event_region.append(region_by_key[region_key])
    return words, regions, event_region


def write_config(path, cfg, arrays):
    with open(path, "w", encoding="ascii") as f:
        f.write("// Generated by tools/midi_render_prepare.py\n")
        for key, value in cfg.items():
            if isinstance(value, str):
                f.write(f'localparam string {key} = "{value}";\n')
            else:
                f.write(f"localparam int unsigned {key} = {value};\n")
        for key, values in arrays.items():
            count_name = "MIDI_REGION_COUNT" if key.startswith("MIDI_REGION_") else "MIDI_EVENT_COUNT"
            f.write(f"localparam int unsigned {key} [0:{count_name}-1] = '{{\n")
            for index, value in enumerate(values):
                comma = "," if index + 1 < len(values) else ""
                f.write(f"  {value}{comma}\n")
            f.write("};\n")


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

    sample_count = max(1, int(round(args.seconds * args.sample_rate)))
    render_seconds = sample_count / args.sample_rate
    events = [e for e in events if e.time_seconds <= render_seconds]
    if not events:
        raise ValueError("no MIDI/note events fall inside the requested render window")

    with open(args.sf2, "rb") as f:
        data = f.read()
    sdta = sf2_extract.list_chunks(sf2_extract.find_chunk(data, b"sdta"))
    pdta = sf2_extract.list_chunks(sf2_extract.find_chunk(data, b"pdta"))
    instruments = sf2_extract.parse_instruments(pdta[b"inst"])
    presets = sf2_extract.parse_presets(pdta[b"phdr"])
    preset_bags = sf2_extract.parse_bags(pdta[b"pbag"])
    preset_generators = sf2_extract.parse_generators(pdta[b"pgen"])
    instrument_bags = sf2_extract.parse_bags(pdta[b"ibag"])
    instrument_generators = sf2_extract.parse_generators(pdta[b"igen"])
    samples = sf2_extract.parse_samples(pdta[b"shdr"])
    adsr_tick_samples = max(1, int(round(args.adsr_tick_ms * args.sample_rate / 1000.0)))

    if args.instrument:
        inst_index, inst = sf2_extract.select_instrument(instruments, args.instrument)
        zone = sf2_extract.select_zone(sf2_extract.instrument_zones(instruments, instrument_bags, instrument_generators, inst_index), args.key)
        sample = samples[zone[sf2_extract.GEN_SAMPLE_ID]]
        region_words, left, right, stereo, length, loop_start, loop_end = sf2_extract.build_wave_words(sdta[b"smpl"], samples, sample)
        sustain_level, attack_step, decay_step, release_step = volume_envelope(
            zone, adsr_tick_samples, args.sample_rate)
        words = region_words
        regions = [RenderRegion(args.key, 0, 0, inst.name, inst.name, left.name,
                                right.name if right else None, stereo, 0, length,
                                loop_start, loop_end,
                                phase_inc_for_key(args.key, zone, left, args.sample_rate),
                                0x4000, 0x4000, loop_mode_from_zone(zone),
                                sustain_level, attack_step, decay_step, release_step)]
        event_region = [0 for _ in events]
    else:
        words, regions, event_region = build_regions(
            events, sdta[b"smpl"], presets, instruments, preset_bags, preset_generators,
            instrument_bags, instrument_generators, samples, args.sample_rate,
            adsr_tick_samples)

    event_samples = [max(0, min(sample_count, int(round(e.time_seconds * args.sample_rate)))) for e in events]
    event_on = [1 if e.on else 0 for e in events]
    event_key = [max(0, min(127, e.note)) for e in events]
    event_velocity = [max(0, min(127, e.velocity)) for e in events]
    event_channel = [max(0, min(15, e.channel)) for e in events]
    event_phase_inc = [regions[event_region[i]].phase_inc for i in range(len(events))]

    os.makedirs(args.out_dir, exist_ok=True)
    memh = os.path.join(args.out_dir, "wave.memh")
    config_svh = os.path.join(args.out_dir, "midi_render_config.svh")
    config_json = os.path.join(args.out_dir, "midi_render_config.json")
    sf2_extract.write_memh(memh, words)
    cfg = {
        "MIDI_MEMORY_DEPTH": len(words),
        "MIDI_SAMPLE_COUNT": sample_count,
        "MIDI_REGION_COUNT": len(regions),
        "MIDI_ADSR_TICK_SAMPLES": adsr_tick_samples,
        "MIDI_EVENT_COUNT": len(events),
        "MIDI_MEMH": memh,
        "MIDI_PCM": os.path.join(args.out_dir, "out.pcm"),
    }
    arrays = {
        "MIDI_EVENT_SAMPLE": event_samples,
        "MIDI_EVENT_ON": event_on,
        "MIDI_EVENT_KEY": event_key,
        "MIDI_EVENT_VELOCITY": event_velocity,
        "MIDI_EVENT_CHANNEL": event_channel,
        "MIDI_EVENT_PHASE_INC": event_phase_inc,
        "MIDI_EVENT_REGION": event_region,
        "MIDI_REGION_STEREO": [1 if r.stereo else 0 for r in regions],
        "MIDI_REGION_BASE_ADDR": [r.base_addr for r in regions],
        "MIDI_REGION_LENGTH": [r.length for r in regions],
        "MIDI_REGION_LOOP_START": [r.loop_start for r in regions],
        "MIDI_REGION_LOOP_END": [r.loop_end for r in regions],
        "MIDI_REGION_GAIN_L": [r.gain_l for r in regions],
        "MIDI_REGION_GAIN_R": [r.gain_r for r in regions],
        "MIDI_REGION_LOOP_MODE": [r.loop_mode for r in regions],
        "MIDI_REGION_SUSTAIN_LEVEL": [r.sustain_level for r in regions],
        "MIDI_REGION_ATTACK_STEP": [r.attack_step for r in regions],
        "MIDI_REGION_DECAY_STEP": [r.decay_step for r in regions],
        "MIDI_REGION_RELEASE_STEP": [r.release_step for r in regions],
    }
    write_config(config_svh, cfg, arrays)
    with open(config_json, "w", encoding="utf-8") as f:
        json.dump({
            "regions": [r.__dict__ for r in regions],
            "output_sample_rate": args.sample_rate,
            "output_samples": sample_count,
            "events": [e.__dict__ for e in events],
        }, f, indent=2)
        f.write("\n")
    print(f"prepared {len(events)} MIDI events, {len(regions)} mapped regions for {sample_count} samples")
    for idx, region in enumerate(regions[:16]):
        print(f"region {idx}: program {region.program} bank {region.bank} preset {region.preset}, sample {region.sample_left}")
    if len(regions) > 16:
        print(f"... {len(regions) - 16} more regions")


if __name__ == "__main__":
    main()
