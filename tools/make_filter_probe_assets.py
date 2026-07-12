#!/usr/bin/env python3
"""Generate a tiny filtered SF2 and matching MIDI probe for render tests."""

import argparse
import math
import os
import struct


def u16(out, value):
    out.extend(struct.pack("<H", value & 0xFFFF))


def s16bits(value):
    return value & 0xFFFF


def u32(out, value):
    out.extend(struct.pack("<I", value & 0xFFFFFFFF))


def name20(out, name):
    raw = name.encode("ascii")[:20]
    out.extend(raw)
    out.extend(b"\x00" * (20 - len(raw)))


def chunk(chunk_id, payload):
    out = bytearray(chunk_id)
    u32(out, len(payload))
    out.extend(payload)
    if len(payload) & 1:
        out.append(0)
    return out


def list_chunk(kind, chunks):
    payload = bytearray(kind)
    for chunk_id, data in chunks:
        payload.extend(chunk(chunk_id, data))
    return chunk(b"LIST", payload)


def phdr(name, preset, bank, bag_index):
    out = bytearray()
    name20(out, name)
    u16(out, preset)
    u16(out, bank)
    u16(out, bag_index)
    u32(out, 0)
    u32(out, 0)
    u32(out, 0)
    return out


def inst(name, bag_index):
    out = bytearray()
    name20(out, name)
    u16(out, bag_index)
    return out


def bag(gen_index, mod_index=0):
    out = bytearray()
    u16(out, gen_index)
    u16(out, mod_index)
    return out


def gen(oper, amount):
    out = bytearray()
    u16(out, oper)
    u16(out, amount)
    return out


def shdr(name, start, end, start_loop, end_loop, sample_rate, root_key, correction, link, sample_type):
    out = bytearray()
    name20(out, name)
    u32(out, start)
    u32(out, end)
    u32(out, start_loop)
    u32(out, end_loop)
    u32(out, sample_rate)
    out.append(root_key & 0xFF)
    out.extend(struct.pack("<b", correction))
    u16(out, link)
    u16(out, sample_type)
    return out


def info_list():
    ifil = bytearray()
    u16(ifil, 2)
    u16(ifil, 4)
    return list_chunk(b"INFO", [
        (b"ifil", ifil),
        (b"isng", b"EMU8000"),
        (b"INAM", b"Filtered Probe"),
    ])


def write_sf2(path, cutoff_cents, resonance_cb):
    smpl = bytearray()
    # Bright deterministic waveform: a short square-ish wavetable with guard zeros.
    for i in range(128):
        value = 18000 if (i % 16) < 8 else -18000
        u16(smpl, s16bits(value))
    for _ in range(46):
        u16(smpl, 0)

    phdrs = phdr("FilterPreset", 0, 0, 0) + phdr("EOP", 0, 0, 1)
    pbags = bag(0) + bag(1)
    pgens = gen(41, 0) + gen(0, 0)  # instrument, terminal

    insts = inst("FilterInst", 0) + inst("EOI", 1)
    ibags = bag(0) + bag(5)
    igens = bytearray()
    igens.extend(gen(8, cutoff_cents))       # initialFilterFc
    igens.extend(gen(9, resonance_cb))       # initialFilterQ
    igens.extend(gen(54, 0))                 # no loop; note off still ends via envelope
    igens.extend(gen(58, 60))                # overridingRootKey
    igens.extend(gen(53, 0))                 # sampleID terminal for zone
    igens.extend(gen(0, 0))                  # terminal record

    shdrs = shdr("FilterSample", 0, 128, 8, 120, 48000, 60, 0, 0, 1)
    shdrs += shdr("EOS", 0, 0, 0, 0, 0, 0, 0, 0, 0)

    sdta = list_chunk(b"sdta", [(b"smpl", smpl)])
    pdta = list_chunk(b"pdta", [
        (b"phdr", phdrs),
        (b"pbag", pbags),
        (b"pmod", bytes(10)),
        (b"pgen", pgens),
        (b"inst", insts),
        (b"ibag", ibags),
        (b"imod", bytes(10)),
        (b"igen", igens),
        (b"shdr", shdrs),
    ])
    riff_payload = b"sfbk" + info_list() + sdta + pdta
    with open(path, "wb") as f:
        f.write(chunk(b"RIFF", riff_payload))


def be16(out, value):
    out.extend(struct.pack(">H", value & 0xFFFF))


def be32(out, value):
    out.extend(struct.pack(">I", value & 0xFFFFFFFF))


def vlq(value):
    out = [value & 0x7F]
    value >>= 7
    while value:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    return bytes(reversed(out))


def write_midi(path, key, velocity):
    track = bytearray()
    track.extend(vlq(0) + b"\xff\x51\x03\x07\xa1\x20")
    track.extend(vlq(0) + bytes([0xC0, 0]))
    track.extend(vlq(0) + bytes([0x90, key, velocity]))
    track.extend(vlq(720) + bytes([0x80, key, 0]))
    track.extend(vlq(0) + b"\xff\x2f\x00")
    midi = bytearray(b"MThd")
    be32(midi, 6)
    be16(midi, 0)
    be16(midi, 1)
    be16(midi, 480)
    midi.extend(b"MTrk")
    be32(midi, len(track))
    midi.extend(track)
    with open(path, "wb") as f:
        f.write(midi)


def main():
    parser = argparse.ArgumentParser(description="Generate a synthetic filtered SF2 and MIDI probe")
    parser.add_argument("--out-dir", default="build/filter_probe")
    parser.add_argument("--cutoff-cents", type=int, default=6900)
    parser.add_argument("--resonance-cb", type=int, default=120)
    parser.add_argument("--key", type=int, default=60)
    parser.add_argument("--velocity", type=int, default=110)
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    sf2_path = os.path.join(args.out_dir, "filter_probe.sf2")
    midi_path = os.path.join(args.out_dir, "filter_probe.mid")
    write_sf2(sf2_path, args.cutoff_cents, args.resonance_cb)
    write_midi(midi_path, args.key, args.velocity)
    cutoff_hz = 8.176 * math.pow(2.0, args.cutoff_cents / 1200.0)
    print(f"sf2={sf2_path}")
    print(f"midi={midi_path}")
    print(f"initialFilterFc={args.cutoff_cents} cents ~= {cutoff_hz:.2f} Hz")
    print(f"initialFilterQ={args.resonance_cb} centibels")


if __name__ == "__main__":
    main()
