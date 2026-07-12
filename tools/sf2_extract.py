#!/usr/bin/env python3
"""Extract one SoundFont2 instrument zone into files the RTL render TB can use.

This is intentionally a small SF2 reader rather than a complete synthesizer. It
uses only the tables needed for the current single-voice RTL path: instrument
zones, sample headers, raw sample data, loop points, and tuning.
"""

import argparse
import json
import math
import os
import struct
from dataclasses import dataclass


GEN_KEY_RANGE = 43
GEN_VEL_RANGE = 44
GEN_PAN = 17
GEN_DELAY_VOL_ENV = 33
GEN_ATTACK_VOL_ENV = 34
GEN_HOLD_VOL_ENV = 35
GEN_DECAY_VOL_ENV = 36
GEN_SUSTAIN_VOL_ENV = 37
GEN_RELEASE_VOL_ENV = 38
GEN_KEYNUM_TO_VOL_ENV_HOLD = 39
GEN_KEYNUM_TO_VOL_ENV_DECAY = 40
GEN_INSTRUMENT = 41
GEN_INITIAL_ATTENUATION = 48
GEN_FINE_TUNE = 52
GEN_COARSE_TUNE = 51
GEN_SAMPLE_ID = 53
GEN_SAMPLE_MODES = 54
GEN_OVERRIDING_ROOT_KEY = 58

# Low 15 bits of SF2 sampleType identify whether a sample is mono or one half of
# a linked stereo pair. The high ROM bit is ignored by sanitize_sample_type().
SAMPLE_MONO = 1
SAMPLE_RIGHT = 2
SAMPLE_LEFT = 4


@dataclass
class Preset:
    name: str
    preset: int
    bank: int
    bag_index: int


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
    # SF2 names are fixed-width, NUL-padded ASCII strings.
    return raw.split(b"\x00", 1)[0].decode("ascii", errors="replace").strip()


def find_chunk(data, wanted):
    # SF2 is a RIFF file. The top level contains LIST chunks named INFO, sdta,
    # and pdta. This helper returns the payload after the LIST type tag.
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


def list_chunks_with_offsets(data, wanted):
    if data[0:4] != b"RIFF" or data[8:12] != b"sfbk":
        raise ValueError("not a SoundFont2 RIFF/sfbk file")
    pos = 12
    end = len(data)
    while pos + 8 <= end:
        chunk_id = data[pos:pos + 4]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        payload = pos + 8
        if chunk_id == b"LIST" and data[payload:payload + 4] == wanted:
            chunks = {}
            child = payload + 4
            list_end = payload + size
            while child + 8 <= list_end:
                child_id = data[child:child + 4]
                child_size = struct.unpack_from("<I", data, child + 4)[0]
                child_payload = child + 8
                chunks[child_id] = (data[child_payload:child_payload + child_size], child_payload)
                child = child_payload + child_size + (child_size & 1)
            return chunks
        pos = payload + size + (size & 1)
    raise ValueError(f"missing LIST {wanted.decode('ascii')}")


def list_chunks(payload):
    # RIFF chunks are padded to even byte boundaries; size itself excludes the
    # optional pad byte, hence the size & 1 adjustment.
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
    # inst records are 20-byte names plus the first ibag index for that
    # instrument. The final terminal record is kept so ranges are easy to form.
    return [Instrument(clean_name(chunk[i:i + 20]), struct.unpack_from("<H", chunk, i + 20)[0])
            for i in range(0, len(chunk), 22)]


def parse_presets(chunk):
    # phdr records include name, preset/program number, bank, and first pbag index.
    # The terminal EOP preset is kept for range construction.
    return [Preset(clean_name(chunk[i:i + 20]), *struct.unpack_from("<HHH", chunk, i + 20))
            for i in range(0, len(chunk), 38)]


def parse_bags(chunk):
    # A bag points at the first generator/modulator for one instrument zone.
    return [Bag(*struct.unpack_from("<HH", chunk, i)) for i in range(0, len(chunk), 4)]


def parse_generators(chunk):
    # Generators are small parameter records: operator ID plus a 16-bit amount.
    return [Generator(*struct.unpack_from("<HH", chunk, i)) for i in range(0, len(chunk), 4)]


def parse_samples(chunk):
    # shdr records point into sdta/smpl using sample indices, not byte offsets.
    # endLoop in SF2 is the exclusive loop endpoint, matching this RTL project.
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
    # Many generator amounts are stored as unsigned bits but interpreted as a
    # signed 16-bit value, for example fineTune and coarseTune.
    return struct.unpack("<h", struct.pack("<H", amount))[0]


def generators_for_zone(gens):
    # This first version keeps the last generator value for each operator. That
    # is sufficient for simple instruments and the MT6276.sf2 validation file.
    zone = {}
    for gen in gens:
        zone[gen.oper] = gen.amount
    return zone


def key_range(zone):
    # keyRange packs low key in bits [7:0] and high key in bits [15:8]. Missing
    # keyRange means the zone applies to all MIDI keys.
    amount = zone.get(GEN_KEY_RANGE)
    if amount is None:
        return 0, 127
    return amount & 0xff, (amount >> 8) & 0xff


def vel_range(zone):
    amount = zone.get(GEN_VEL_RANGE)
    if amount is None:
        return 0, 127
    return amount & 0xff, (amount >> 8) & 0xff


def zone_matches(zone, key, velocity=100):
    key_low, key_high = key_range(zone)
    vel_low, vel_high = vel_range(zone)
    return key_low <= key <= key_high and vel_low <= velocity <= vel_high


def select_preset(presets, program, bank=0):
    usable = presets[:-1]
    for index, preset in enumerate(usable):
        if preset.preset == program and preset.bank == bank:
            return index, preset
    if bank != 0:
        for index, preset in enumerate(usable):
            if preset.preset == program and preset.bank == 0:
                return index, preset
    for index, preset in enumerate(usable):
        if preset.preset == 0 and preset.bank == 0:
            return index, preset
    if usable:
        return 0, usable[0]
    raise ValueError("soundfont has no presets")


def select_instrument(instruments, instrument):
    # The terminal EOS instrument is excluded from user-visible choices.
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
    # Instrument zones live between this instrument's starting ibag index and the
    # next instrument's starting ibag index. A zone without sampleID is global;
    # its generators are inherited by later sample zones.
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


def preset_zones(presets, bags, generators, preset_index):
    start = presets[preset_index].bag_index
    end = presets[preset_index + 1].bag_index
    zones = []
    global_zone = {}
    for bag_index in range(start, end):
      gen_start = bags[bag_index].gen_index
      gen_end = bags[bag_index + 1].gen_index
      zone = generators_for_zone(generators[gen_start:gen_end])
      if GEN_INSTRUMENT not in zone:
          global_zone.update(zone)
      else:
          merged = dict(global_zone)
          merged.update(zone)
          zones.append(merged)
    return zones


def select_zone(zones, key):
    # Prefer a zone whose keyRange contains the requested key. If the instrument
    # lacks explicit ranges, fall back to its first sample zone.
    for zone in zones:
        low, high = key_range(zone)
        if low <= key <= high:
            return zone
    if zones:
        return zones[0]
    raise ValueError("instrument has no sample zones")


def select_zone_for_velocity(zones, key, velocity):
    for zone in zones:
        if zone_matches(zone, key, velocity):
            return zone
    return select_zone(zones, key)


def select_preset_region(presets, instruments, preset_bags, preset_generators,
                         instrument_bags, instrument_generators, program, bank,
                         key, velocity):
    preset_index, preset = select_preset(presets, program, bank)
    pzones = preset_zones(presets, preset_bags, preset_generators, preset_index)
    pzone = select_zone_for_velocity(pzones, key, velocity)
    inst_index = pzone[GEN_INSTRUMENT]
    izones = instrument_zones(instruments, instrument_bags, instrument_generators, inst_index)
    izone = select_zone_for_velocity(izones, key, velocity)
    merged = dict(pzone)
    merged.update(izone)
    return preset_index, preset, inst_index, instruments[inst_index], merged


def sanitize_sample_type(sample_type):
    # Bit 15 marks ROM samples in the SF2 spec. It is unrelated to channel role.
    return sample_type & 0x7fff


def linked_pair(samples, selected):
    # SF2 stereo samples are represented as two separate mono sample headers
    # linked by sampleLink. The RTL consumes independent absolute left/right
    # base addresses into the complete SF2 file image.
    sample_type = sanitize_sample_type(selected.sample_type)
    if sample_type == SAMPLE_LEFT and selected.sample_link < len(samples):
        return selected, samples[selected.sample_link]
    if sample_type == SAMPLE_RIGHT and selected.sample_link < len(samples):
        return samples[selected.sample_link], selected
    return selected, None


def region_addresses(samples, selected, smpl_word_offset):
    left, right = linked_pair(samples, selected)
    stereo = right is not None and sanitize_sample_type(right.sample_type) in (SAMPLE_LEFT, SAMPLE_RIGHT)
    if stereo:
        frame_count = min(left.end - left.start, right.end - right.start, 65535)
        loop_start = max(0, min(left.start_loop - left.start, right.start_loop - right.start, frame_count - 1))
        loop_end = max(loop_start + 1, min(left.end_loop - left.start, right.end_loop - right.start, frame_count))
        base_addr_r = smpl_word_offset + right.start
    else:
        frame_count = min(left.end - left.start, 65535)
        loop_start = max(0, min(left.start_loop - left.start, frame_count - 1))
        loop_end = max(loop_start + 1, min(left.end_loop - left.start, frame_count))
        base_addr_r = smpl_word_offset + left.start
    if loop_start >= loop_end or loop_end > frame_count:
        # Some soundfonts use degenerate or missing loop points. Use the whole
        # sample as a legal fallback so the RTL configuration remains valid.
        loop_start = 0
        loop_end = frame_count
    return left, right, stereo, smpl_word_offset + left.start, base_addr_r, frame_count, loop_start, loop_end


def file_words(data):
    words = []
    for i in range(0, len(data), 2):
        hi = data[i + 1] if i + 1 < len(data) else 0
        words.append(data[i] | (hi << 8))
    return words


def write_memh(path, words):
    # $readmemh reads one hex word per line. Masking preserves two's-complement
    # representation for negative signed PCM samples.
    with open(path, "w", encoding="ascii") as f:
        for word in words:
            f.write(f"{word & 0xffff:04x}\n")


def write_config(path, cfg):
    # A generated SV include keeps the render testbench simple and avoids adding
    # JSON parsing logic to SystemVerilog.
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

    # sdta holds PCM sample data; pdta holds the instrument/sample metadata used
    # to choose a sample and calculate playback settings.
    sdta = list_chunks(find_chunk(data, b"sdta"))
    sdta_offsets = list_chunks_with_offsets(data, b"sdta")
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
    _, smpl_payload = sdta_offsets[b"smpl"]
    if smpl_payload & 1:
        raise ValueError("smpl payload is not word aligned")
    smpl_word_offset = smpl_payload // 2
    left, right, stereo, base_addr, base_addr_r, length, loop_start, loop_end = region_addresses(
        samples, sample, smpl_word_offset)

    # Convert SF2 pitch metadata to the RTL's Q16.16 phase increment. A value of
    # 0x0001_0000 means advance one source sample frame per output sample.
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
    words = file_words(data)
    write_memh(memh, words)
    # These localparams directly program tb_render_wavetable_core.sv.
    cfg = {
        "RENDER_MEMORY_DEPTH": len(words),
        "RENDER_SAMPLE_COUNT": sample_count,
        "RENDER_STEREO": 1 if stereo else 0,
        "RENDER_BASE_ADDR": base_addr,
        "RENDER_BASE_ADDR_R": base_addr_r,
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

    # JSON is not consumed by Verilator; it is for humans and future scripts to
    # inspect exactly what the SF2 extraction selected.
    with open(config_json, "w", encoding="utf-8") as f:
        json.dump({
            "instrument_index": inst_index,
            "instrument": inst.name,
            "key": args.key,
            "sample_left": left.name,
            "sample_right": right.name if right else None,
            "stereo": stereo,
            "base_addr": base_addr,
            "base_addr_r": base_addr_r,
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
