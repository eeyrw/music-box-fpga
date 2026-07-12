#!/usr/bin/env python3
"""Report SF2 filter-generator use and optionally emit a probe MIDI file."""

import argparse
import json
import struct

from sf2_extract import (
    GEN_INSTRUMENT,
    GEN_KEY_RANGE,
    GEN_SAMPLE_ID,
    GEN_VEL_RANGE,
    find_chunk,
    instrument_zones,
    key_range,
    list_chunks,
    parse_bags,
    parse_generators,
    parse_instruments,
    parse_presets,
    parse_samples,
    preset_zones,
    signed_amount,
    vel_range,
)


GEN_INITIAL_FILTER_FC = 8
GEN_INITIAL_FILTER_Q = 9
GEN_MOD_LFO_TO_FILTER_FC = 10
GEN_MOD_ENV_TO_FILTER_FC = 11
GEN_FILTER_NAMES = {
    GEN_INITIAL_FILTER_FC: "initialFilterFc",
    GEN_INITIAL_FILTER_Q: "initialFilterQ",
    GEN_MOD_LFO_TO_FILTER_FC: "modLfoToFilterFc",
    GEN_MOD_ENV_TO_FILTER_FC: "modEnvToFilterFc",
}


def merge_region(pzone, izone):
    merged = dict(pzone)
    merged.update(izone)
    return merged


def amount_value(oper, amount):
    if oper in (GEN_KEY_RANGE, GEN_VEL_RANGE):
        return {"low": amount & 0xFF, "high": (amount >> 8) & 0xFF}
    return signed_amount(amount)


def zone_filter_values(zone):
    return {GEN_FILTER_NAMES[oper]: amount_value(oper, amount)
            for oper, amount in zone.items() if oper in GEN_FILTER_NAMES}


def zone_center(zone, range_fn):
    low, high = range_fn(zone)
    return max(0, min(127, (low + high) // 2))


def load_tables(path):
    with open(path, "rb") as f:
        data = f.read()
    pdta = list_chunks(find_chunk(data, b"pdta"))
    return {
        "presets": parse_presets(pdta[b"phdr"]),
        "preset_bags": parse_bags(pdta[b"pbag"]),
        "preset_generators": parse_generators(pdta[b"pgen"]),
        "instruments": parse_instruments(pdta[b"inst"]),
        "instrument_bags": parse_bags(pdta[b"ibag"]),
        "instrument_generators": parse_generators(pdta[b"igen"]),
        "samples": parse_samples(pdta[b"shdr"]),
    }


def raw_generator_counts(generators):
    counts = {name: 0 for name in GEN_FILTER_NAMES.values()}
    for gen in generators:
        if gen.oper in GEN_FILTER_NAMES:
            counts[GEN_FILTER_NAMES[gen.oper]] += 1
    return counts


def matching_regions(tables):
    presets = tables["presets"]
    instruments = tables["instruments"]
    samples = tables["samples"]
    out = []
    for preset_index, preset in enumerate(presets[:-1]):
        for pzone in preset_zones(presets, tables["preset_bags"], tables["preset_generators"], preset_index):
            if GEN_INSTRUMENT not in pzone:
                continue
            inst_index = pzone[GEN_INSTRUMENT]
            if inst_index >= len(instruments) - 1:
                continue
            for izone in instrument_zones(instruments, tables["instrument_bags"],
                                          tables["instrument_generators"], inst_index):
                if GEN_SAMPLE_ID not in izone:
                    continue
                merged = merge_region(pzone, izone)
                filters = zone_filter_values(merged)
                if not filters:
                    continue
                sample_id = merged[GEN_SAMPLE_ID]
                sample_name = samples[sample_id].name if sample_id < len(samples) else "<bad sampleID>"
                out.append({
                    "preset_index": preset_index,
                    "preset": preset.name,
                    "program": preset.preset,
                    "bank": preset.bank,
                    "instrument_index": inst_index,
                    "instrument": instruments[inst_index].name,
                    "sample_id": sample_id,
                    "sample": sample_name,
                    "key_range": list(key_range(merged)),
                    "vel_range": list(vel_range(merged)),
                    "probe_key": zone_center(merged, key_range),
                    "probe_velocity": max(1, zone_center(merged, vel_range)),
                    "filters": filters,
                })
    return out


def vlq(value):
    bytes_out = [value & 0x7F]
    value >>= 7
    while value:
        bytes_out.append((value & 0x7F) | 0x80)
        value >>= 7
    return bytes(reversed(bytes_out))


def write_u16be(out, value):
    out.extend(struct.pack(">H", value))


def write_u32be(out, value):
    out.extend(struct.pack(">I", value))


def write_probe_midi(path, regions):
    if not regions:
        raise ValueError("no filter regions found; not writing MIDI")
    # Keep the probe short but cover distinct program/bank/key pairs.
    selected = []
    seen = set()
    for region in regions:
        key = (region["bank"], region["program"], region["probe_key"], region["probe_velocity"])
        if key in seen:
            continue
        seen.add(key)
        selected.append(region)
        if len(selected) >= 16:
            break

    track = bytearray()
    track.extend(vlq(0) + b"\xff\x51\x03\x07\xa1\x20")  # 120 BPM.
    last_bank_msb = last_bank_lsb = last_program = None
    for idx, region in enumerate(selected):
        bank = int(region["bank"])
        program = int(region["program"])
        key = int(region["probe_key"])
        vel = int(region["probe_velocity"])
        bank_msb = (bank >> 7) & 0x7F
        bank_lsb = bank & 0x7F
        delta = 0 if idx == 0 else 120
        if bank_msb != last_bank_msb:
            track.extend(vlq(delta) + bytes([0xB0, 0, bank_msb]))
            delta = 0
            last_bank_msb = bank_msb
        if bank_lsb != last_bank_lsb:
            track.extend(vlq(delta) + bytes([0xB0, 32, bank_lsb]))
            delta = 0
            last_bank_lsb = bank_lsb
        if program != last_program:
            track.extend(vlq(delta) + bytes([0xC0, program]))
            delta = 0
            last_program = program
        track.extend(vlq(delta) + bytes([0x90, key, vel]))
        track.extend(vlq(360) + bytes([0x80, key, 0]))
    track.extend(vlq(0) + b"\xff\x2f\x00")

    midi = bytearray(b"MThd")
    write_u32be(midi, 6)
    write_u16be(midi, 0)
    write_u16be(midi, 1)
    write_u16be(midi, 480)
    midi.extend(b"MTrk")
    write_u32be(midi, len(track))
    midi.extend(track)
    with open(path, "wb") as f:
        f.write(midi)
    return selected


def main():
    parser = argparse.ArgumentParser(description="Report SoundFont filter generator usage")
    parser.add_argument("--sf2", default="assets/soundfonts/MT6276.sf2")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--write-midi")
    args = parser.parse_args()

    tables = load_tables(args.sf2)
    regions = matching_regions(tables)
    report = {
        "sf2": args.sf2,
        "raw_pgen_filter_counts": raw_generator_counts(tables["preset_generators"]),
        "raw_igen_filter_counts": raw_generator_counts(tables["instrument_generators"]),
        "filtered_region_count": len(regions),
        "regions": regions[:args.limit],
    }
    if args.write_midi:
        selected = write_probe_midi(args.write_midi, regions)
        report["probe_midi"] = args.write_midi
        report["probe_region_count"] = len(selected)
        report["probe_regions"] = selected

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"SF2: {args.sf2}")
        print(f"raw pgen filter counts: {report['raw_pgen_filter_counts']}")
        print(f"raw igen filter counts: {report['raw_igen_filter_counts']}")
        print(f"playable merged regions with filter generators: {len(regions)}")
        for region in regions[:args.limit]:
            print(f"program={region['program']} bank={region['bank']} preset={region['preset']} "
                  f"instrument={region['instrument']} key={region['probe_key']} vel={region['probe_velocity']} "
                  f"sample={region['sample']} filters={region['filters']}")
        if args.write_midi:
            print(f"wrote probe MIDI: {args.write_midi}")


if __name__ == "__main__":
    main()
