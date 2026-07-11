#!/usr/bin/env python3
import argparse
import json
import math
import os
import struct
from dataclasses import dataclass


GEN_KEY_RANGE = 43
GEN_FINE_TUNE = 52
GEN_COARSE_TUNE = 51
GEN_SAMPLE_ID = 53
GEN_OVERRIDING_ROOT_KEY = 58

SAMPLE_MONO = 1
SAMPLE_RIGHT = 2
SAMPLE_LEFT = 4


@dataclass
class Instrument:
    name: str
    bag_index: int


@dataclass
class Bag:
    gen_index: int
    mod_index: int


@dataclass
class Generator:
    oper: int
    amount: int


@dataclass
class SampleHeader:
    name: str
    start: int
    end: int
    start_loop: int
    end_loop: int
    sample_rate: int
    original_pitch: int
    pitch_correction: int
    sample_link: int
    sample_type: int


def clean_name(raw):
    return raw.split(b"\x00", 1)[0].decode("ascii", errors="replace").strip()


def find_chunk(data, wanted):
    if data[0:4] != b"RIFF" or data[8:12] != b"sfbk":
        raise ValueError("not a SoundFont2 RIFF/sfbk file")
    pos = 12
    end = len(data)
    while pos + 8 <= end:
        chunk_id = data[pos:pos + 4]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        payload = pos + 8
        if chunk_id == b"LIST" and data[payload:payload + 4] == wanted:
            return data[payload + 4:payload + size]
        pos = payload + size + (size & 1)
    raise ValueError(f"missing LIST {wanted.decode('ascii')}")


def list_chunks(payload):
    pos = 0
    chunks = {}
    while pos + 8 <= len(payload):
        chunk_id = payload[pos:pos + 4]
        size = struct.unpack_from("<I", payload, pos + 4)[0]
        start = pos + 8
        chunks[chunk_id] = payload[start:start + size]
        pos = start + size + (size & 1)
    return chunks


def parse_instruments(chunk):
    return [Instrument(clean_name(chunk[i:i + 20]), struct.unpack_from("<H", chunk, i + 20)[0])
            for i in range(0, len(chunk), 22)]


def parse_bags(chunk):
    return [Bag(*struct.unpack_from("<HH", chunk, i)) for i in range(0, len(chunk), 4)]


def parse_generators(chunk):
    return [Generator(*struct.unpack_from("<HH", chunk, i)) for i in range(0, len(chunk), 4)]


def parse_samples(chunk):
    samples = []
    for i in range(0, len(chunk), 46):
        pitch_correction = struct.unpack_from("<b", chunk, i + 41)[0]
        samples.append(SampleHeader(
            clean_name(chunk[i:i + 20]),
            *struct.unpack_from("<IIIIIB", chunk, i + 20),
            pitch_correction,
            *struct.unpack_from("<HH", chunk, i + 42),
        ))
    return samples


def signed_amount(amount):
    return struct.unpack("<h", struct.pack("<H", amount))[0]


def generators_for_zone(gens):
    zone = {}
    for gen in gens:
        zone[gen.oper] = gen.amount
    return zone


def key_range(zone):
    amount = zone.get(GEN_KEY_RANGE)
    if amount is None:
        return 0, 127
    return amount & 0xff, (amount >> 8) & 0xff


def select_instrument(instruments, instrument):
    usable = instruments[:-1]
    if instrument is None:
        return 0, usable[0]
    try:
        index = int(instrument, 0)
        return index, usable[index]
    except ValueError:
        needle = instrument.lower()
        for index, inst in enumerate(usable):
            if inst.name.lower() == needle:
                return index, inst
        for index, inst in enumerate(usable):
            if needle in inst.name.lower():
                return index, inst
    raise ValueError(f"instrument not found: {instrument}")


def instrument_zones(instruments, bags, generators, inst_index):
    start = instruments[inst_index].bag_index
    end = instruments[inst_index + 1].bag_index
    zones = []
    global_zone = {}
    for bag_index in range(start, end):
        gen_start = bags[bag_index].gen_index
        gen_end = bags[bag_index + 1].gen_index
        zone = generators_for_zone(generators[gen_start:gen_end])
        if GEN_SAMPLE_ID not in zone:
            global_zone.update(zone)
        else:
            merged = dict(global_zone)
            merged.update(zone)
            zones.append(merged)
    return zones


def select_zone(zones, key):
    for zone in zones:
        low, high = key_range(zone)
        if low <= key <= high:
            return zone
    if zones:
        return zones[0]
    raise ValueError("instrument has no sample zones")


def sanitize_sample_type(sample_type):
    return sample_type & 0x7fff


def sample_pcm(smpl, header):
    raw = smpl[header.start * 2:header.end * 2]
    return list(struct.unpack(f"<{len(raw) // 2}h", raw))


def linked_pair(samples, selected):
    sample_type = sanitize_sample_type(selected.sample_type)
    if sample_type == SAMPLE_LEFT and selected.sample_link < len(samples):
        return selected, samples[selected.sample_link]
    if sample_type == SAMPLE_RIGHT and selected.sample_link < len(samples):
        return samples[selected.sample_link], selected
    return selected, None


def build_wave_words(smpl, samples, selected):
    left, right = linked_pair(samples, selected)
    left_pcm = sample_pcm(smpl, left)
    stereo = right is not None and sanitize_sample_type(right.sample_type) in (SAMPLE_LEFT, SAMPLE_RIGHT)
    if stereo:
        right_pcm = sample_pcm(smpl, right)
        frame_count = min(len(left_pcm), len(right_pcm), 65535)
        words = []
        for i in range(frame_count):
            words.append(left_pcm[i])
            words.append(right_pcm[i])
        loop_start = max(0, min(left.start_loop - left.start, right.start_loop - right.start, frame_count - 1))
        loop_end = max(loop_start + 1, min(left.end_loop - left.start, right.end_loop - right.start, frame_count))
    else:
        frame_count = min(len(left_pcm), 65535)
        words = left_pcm[:frame_count]
        loop_start = max(0, min(left.start_loop - left.start, frame_count - 1))
        loop_end = max(loop_start + 1, min(left.end_loop - left.start, frame_count))
    if loop_start >= loop_end or loop_end > frame_count:
        loop_start = 0
        loop_end = frame_count
    return words, left, right, stereo, frame_count, loop_start, loop_end


def write_memh(path, words):
    with open(path, "w", encoding="ascii") as f:
        for word in words:
            f.write(f"{word & 0xffff:04x}\n")


def write_config(path, cfg):
    with open(path, "w", encoding="ascii") as f:
        f.write("// Generated by tools/sf2_extract.py\n")
        for key, value in cfg.items():
            if isinstance(value, str):
                f.write(f'localparam string {key} = "{value}";\n')
            else:
                f.write(f"localparam int unsigned {key} = {value};\n")


def main():
    parser = argparse.ArgumentParser(description="Extract an SF2 instrument sample for RTL rendering")
    parser.add_argument("--sf2", required=True)
    parser.add_argument("--instrument")
    parser.add_argument("--key", type=int, default=60)
    parser.add_argument("--sample-rate", type=int, default=48000)
    parser.add_argument("--seconds", type=float, default=2.0)
    parser.add_argument("--out-dir", default="build/render")
    parser.add_argument("--list-instruments", action="store_true")
    args = parser.parse_args()

    with open(args.sf2, "rb") as f:
        data = f.read()
    sdta = list_chunks(find_chunk(data, b"sdta"))
    pdta = list_chunks(find_chunk(data, b"pdta"))
    instruments = parse_instruments(pdta[b"inst"])
    bags = parse_bags(pdta[b"ibag"])
    generators = parse_generators(pdta[b"igen"])
    samples = parse_samples(pdta[b"shdr"])

    if args.list_instruments:
        for index, inst in enumerate(instruments[:-1]):
            print(f"{index}: {inst.name}")
        return

    inst_index, inst = select_instrument(instruments, args.instrument)
    zone = select_zone(instrument_zones(instruments, bags, generators, inst_index), args.key)
    sample = samples[zone[GEN_SAMPLE_ID]]
    words, left, right, stereo, length, loop_start, loop_end = build_wave_words(sdta[b"smpl"], samples, sample)

    root_key = zone.get(GEN_OVERRIDING_ROOT_KEY, left.original_pitch)
    if root_key == 255:
        root_key = left.original_pitch
    cents = ((args.key - root_key) * 100 + left.pitch_correction +
             signed_amount(zone.get(GEN_FINE_TUNE, 0)) + signed_amount(zone.get(GEN_COARSE_TUNE, 0)) * 100)
    rate_ratio = (left.sample_rate / args.sample_rate) * math.pow(2.0, cents / 1200.0)
    phase_inc = max(1, min(0xffffffff, int(round(rate_ratio * 65536.0))))
    sample_count = max(1, int(round(args.seconds * args.sample_rate)))

    os.makedirs(args.out_dir, exist_ok=True)
    memh = os.path.join(args.out_dir, "wave.memh")
    config_svh = os.path.join(args.out_dir, "render_config.svh")
    config_json = os.path.join(args.out_dir, "render_config.json")
    write_memh(memh, words)
    cfg = {
        "RENDER_MEMORY_DEPTH": len(words),
        "RENDER_SAMPLE_COUNT": sample_count,
        "RENDER_STEREO": 1 if stereo else 0,
        "RENDER_BASE_ADDR": 0,
        "RENDER_LENGTH": length,
        "RENDER_LOOP_START": loop_start,
        "RENDER_LOOP_END": loop_end,
        "RENDER_PHASE_INC": phase_inc,
        "RENDER_GAIN_L": 0x7fff,
        "RENDER_GAIN_R": 0x7fff,
        "RENDER_MEMH": memh,
        "RENDER_PCM": os.path.join(args.out_dir, "out.pcm"),
    }
    write_config(config_svh, cfg)
    with open(config_json, "w", encoding="utf-8") as f:
        json.dump({
            "instrument_index": inst_index,
            "instrument": inst.name,
            "key": args.key,
            "sample_left": left.name,
            "sample_right": right.name if right else None,
            "stereo": stereo,
            "length": length,
            "loop_start": loop_start,
            "loop_end": loop_end,
            "sample_rate": left.sample_rate,
            "phase_inc": phase_inc,
            "output_sample_rate": args.sample_rate,
            "output_samples": sample_count,
        }, f, indent=2)
        f.write("\n")
    print(f"instrument {inst_index}: {inst.name}")
    print(f"sample L: {left.name}" + (f", R: {right.name}" if right else ", mono"))
    print(f"frames={length} loop=[{loop_start},{loop_end}) phase_inc=0x{phase_inc:08x}")


if __name__ == "__main__":
    main()
