#!/usr/bin/env python3
"""Build a raw WTSF SD image for the Smart Artix asset loader."""

import argparse
import os
import struct
import zlib


SECTOR_BYTES = 512
HEADER_BYTES = 0x40
MAGIC = b"WTSF"
VERSION = 1
FLAG_SF2_CRC32 = 1 << 0
FLAG_HEADER_CRC32 = 1 << 1


def align_up(value, alignment):
    return (value + alignment - 1) // alignment * alignment


def parse_lba(value):
    lba = int(value, 0)
    if lba < 1:
        raise argparse.ArgumentTypeError("SF2 start LBA must be at least 1")
    return lba


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def check_sf2(data, path):
    if len(data) < 12 or data[0:4] != b"RIFF" or data[8:12] != b"sfbk":
        raise ValueError(f"{path} does not look like a SoundFont2 RIFF/sfbk file")


def put_u32le(buf, offset, value):
    struct.pack_into("<I", buf, offset, value)


def put_u64le(buf, offset, value):
    struct.pack_into("<Q", buf, offset, value)


def build_header(sf2, sf2_start_lba, ddr_base_byte_addr, metadata_start_lba,
                 metadata_size_bytes, include_crc):
    flags = 0
    sf2_crc32 = 0
    header_crc32 = 0
    if include_crc:
        flags |= FLAG_SF2_CRC32 | FLAG_HEADER_CRC32
        sf2_crc32 = zlib.crc32(sf2) & 0xffffffff

    header = bytearray(SECTOR_BYTES)
    header[0:4] = MAGIC
    put_u32le(header, 0x04, VERSION)
    put_u32le(header, 0x08, HEADER_BYTES)
    put_u32le(header, 0x0c, flags)
    put_u64le(header, 0x10, sf2_start_lba)
    put_u64le(header, 0x18, len(sf2))
    put_u64le(header, 0x20, ddr_base_byte_addr)
    put_u64le(header, 0x28, metadata_start_lba)
    put_u64le(header, 0x30, metadata_size_bytes)
    put_u32le(header, 0x38, sf2_crc32)
    if include_crc:
        header_crc32 = zlib.crc32(header[:0x3c]) & 0xffffffff
        put_u32le(header, 0x3c, header_crc32)
    return header


def write_image(args):
    sf2 = read_file(args.sf2)
    if not args.no_sf2_check:
        check_sf2(sf2, args.sf2)
    if args.ddr_base_byte_addr < 0:
        raise ValueError("DDR base byte address must be non-negative")
    if args.metadata_start_lba < 0 or args.metadata_size_bytes < 0:
        raise ValueError("metadata fields must be non-negative")

    sf2_offset = args.sf2_start_lba * SECTOR_BYTES
    total_size = align_up(sf2_offset + len(sf2), SECTOR_BYTES)
    header = build_header(sf2, args.sf2_start_lba, args.ddr_base_byte_addr,
                          args.metadata_start_lba, args.metadata_size_bytes,
                          args.crc)

    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(header)
        gap = sf2_offset - SECTOR_BYTES
        if gap > 0:
            f.write(bytes(gap))
        f.write(sf2)
        pad = total_size - (sf2_offset + len(sf2))
        if pad > 0:
            f.write(bytes(pad))

    print(f"wrote {args.out}")
    print(f"sf2_size_bytes={len(sf2)}")
    print(f"sf2_start_lba={args.sf2_start_lba}")
    print(f"image_size_bytes={total_size}")


def verify_image(args):
    image = read_file(args.image)
    if len(image) < SECTOR_BYTES:
        raise ValueError("image is shorter than one sector")
    if image[0:4] != MAGIC:
        raise ValueError("bad WTSF magic")
    version, header_size, flags = struct.unpack_from("<III", image, 0x04)
    sf2_start_lba = struct.unpack_from("<Q", image, 0x10)[0]
    sf2_size = struct.unpack_from("<Q", image, 0x18)[0]
    ddr_base = struct.unpack_from("<Q", image, 0x20)[0]
    metadata_start_lba = struct.unpack_from("<Q", image, 0x28)[0]
    metadata_size = struct.unpack_from("<Q", image, 0x30)[0]
    sf2_crc = struct.unpack_from("<I", image, 0x38)[0]
    header_crc = struct.unpack_from("<I", image, 0x3c)[0]

    if version != VERSION:
        raise ValueError(f"unsupported WTSF version {version}")
    if header_size < HEADER_BYTES or header_size > SECTOR_BYTES:
        raise ValueError(f"invalid header size {header_size}")
    sf2_offset = sf2_start_lba * SECTOR_BYTES
    if sf2_start_lba < 1 or sf2_offset + sf2_size > len(image):
        raise ValueError("SF2 payload range is outside the image")
    sf2 = image[sf2_offset:sf2_offset + sf2_size]
    if not args.no_sf2_check:
        check_sf2(sf2, args.image)
    if flags & FLAG_SF2_CRC32:
        actual = zlib.crc32(sf2) & 0xffffffff
        if actual != sf2_crc:
            raise ValueError(f"SF2 CRC mismatch: expected 0x{sf2_crc:08x}, got 0x{actual:08x}")
    if flags & FLAG_HEADER_CRC32:
        header = bytearray(image[:SECTOR_BYTES])
        put_u32le(header, 0x3c, 0)
        actual = zlib.crc32(header[:0x3c]) & 0xffffffff
        if actual != header_crc:
            raise ValueError(f"header CRC mismatch: expected 0x{header_crc:08x}, got 0x{actual:08x}")

    print("WTSF image OK")
    print(f"version={version}")
    print(f"flags=0x{flags:08x}")
    print(f"sf2_start_lba={sf2_start_lba}")
    print(f"sf2_size_bytes={sf2_size}")
    print(f"ddr_base_byte_addr={ddr_base}")
    print(f"metadata_start_lba={metadata_start_lba}")
    print(f"metadata_size_bytes={metadata_size}")


def main():
    parser = argparse.ArgumentParser(description="Generate or verify raw WTSF SD images")
    subparsers = parser.add_subparsers(dest="command", required=True)

    build = subparsers.add_parser("build", help="build a WTSF image from an SF2 file")
    build.add_argument("--sf2", required=True, help="input SoundFont2 file")
    build.add_argument("--out", required=True, help="output raw SD image")
    build.add_argument("--sf2-start-lba", type=parse_lba, default=1)
    build.add_argument("--ddr-base-byte-addr", type=lambda x: int(x, 0), default=0)
    build.add_argument("--metadata-start-lba", type=lambda x: int(x, 0), default=0)
    build.add_argument("--metadata-size-bytes", type=lambda x: int(x, 0), default=0)
    build.add_argument("--crc", action="store_true", help="fill optional SF2 and header CRC32 fields")
    build.add_argument("--no-sf2-check", action="store_true", help="skip RIFF/sfbk input check")
    build.set_defaults(func=write_image)

    verify = subparsers.add_parser("verify", help="verify a WTSF image header and payload")
    verify.add_argument("image", help="raw WTSF SD image")
    verify.add_argument("--no-sf2-check", action="store_true", help="skip RIFF/sfbk payload check")
    verify.set_defaults(func=verify_image)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
