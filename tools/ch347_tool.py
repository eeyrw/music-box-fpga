#!/usr/bin/env python3

"""CH347-backed Smart Artix register and DDR test utility."""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
from pathlib import Path

from ch347_transport import (
    Ch347Error,
    Ch347Transport,
    DEFAULT_LIBRARY,
    DEFAULT_REGISTER_MAP,
    DdrDebugAccess,
    RegisterMap,
)


SNAPSHOT_GROUPS = {
    "core": (
        "VERSION", "SYSTEM_STATUS", "COMMON_EVENT_FLAGS", "PIPELINE_LATENCY_STATUS",
        "UNDERRUN_COUNT", "SAMPLE_DROP_COUNT", "RENDER_DEADLINE_MISS_COUNT",
        "CURRENT_SAMPLE", "CMD_FIFO_STATUS", "MEM_RESPONSE_COUNT", "PIPELINE_LATENCY_MAX",
        "AUDIO_FIFO_DIAGNOSTICS", "AUDIO_LEAD", "COMMAND_ERROR_COUNT",
        "STALE_GENERATION_COUNT", "COMPRESSOR_STATUS", "COMPRESSOR_GAIN_REDUCTION",
        "COMPRESSOR_TARGET_GAIN_REDUCTION", "COMPRESSOR_DETECTOR_PEAK",
        "COMPRESSOR_MAX_GAIN_REDUCTION", "COMPRESSOR_MAX_DETECTOR_PEAK",
        "COMPRESSOR_INPUT_FRAME_COUNT", "COMPRESSOR_OUTPUT_FRAME_COUNT",
        "COMPRESSOR_COMPRESSED_FRAME_COUNT", "COMPRESSOR_SATURATION_COUNT",
    ),
    "effects": (
        "EFFECT_STATUS", "EFFECT_INPUT_FRAME_COUNT", "EFFECT_OUTPUT_FRAME_COUNT",
        "EFFECT_SATURATION_COUNT", "EFFECT_MAX_PROCESSING_CYCLES", "CHORUS_HISTORY_LEVEL",
        "CHORUS_LFO_PHASE", "CHORUS_SATURATION_COUNT", "REVERB_STATUS",
        "REVERB_SATURATION_COUNT", "REVERB_MAX_PROCESSING_CYCLES",
    ),
    "cache": (
        "SAMPLE_WINDOW_REQUEST_COUNT", "SAMPLE_WINDOW_HIT_COUNT",
        "SAMPLE_WINDOW_REFILL_COUNT", "SAMPLE_WINDOW_FALLBACK_READ_COUNT",
        "SAMPLE_WINDOW_MEMORY_READ_COUNT", "SAMPLE_WINDOW_EVICTION_COUNT",
        "SAMPLE_WINDOW_STALL_CYCLE_COUNT",
    ),
    "platform": (
        "PLATFORM_STATUS", "PLATFORM_ERRORS", "PLATFORM_BYTES_LOADED", "PLATFORM_SF2_SIZE",
        "PLATFORM_CURRENT_LBA", "PLATFORM_DDR_STATUS", "DDR_ACCESS_STATUS",
    ),
}


def integer(value: str) -> int:
    try:
        return int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"invalid integer: {value}") from error


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="auto", help="device path, index, or auto")
    parser.add_argument("--lib", type=Path, default=DEFAULT_LIBRARY, help="official libch347.so")
    parser.add_argument("--clock-hz", type=integer, default=30_000_000)
    parser.add_argument("--cs-mask", type=integer, default=0x80)
    parser.add_argument("--register-map", type=Path, default=DEFAULT_REGISTER_MAP)
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("info", help="show CH347 and FPGA interface information")

    read = subparsers.add_parser("read", help="read registers by name or address")
    read.add_argument("register", nargs="+")
    read.add_argument("--json", action="store_true")

    write = subparsers.add_parser("write", help="write one register")
    write.add_argument("register")
    write.add_argument("value", type=integer)

    clear = subparsers.add_parser("clear-diagnostics", help="clear interval diagnostics")
    clear.add_argument("--verify", action="store_true", help="read the interval counters after clear")

    snapshot = subparsers.add_parser("snapshot", help="capture decoded diagnostics")
    snapshot.add_argument("--group", choices=(*SNAPSHOT_GROUPS, "all"), default="all")
    snapshot.add_argument("--json", action="store_true")
    snapshot.add_argument("--output", type=Path)

    ddr_read = subparsers.add_parser("ddr-read", help="read one or more 16-byte DDR beats")
    ddr_read.add_argument("address", type=integer)
    ddr_read.add_argument("--beats", type=integer, default=1)
    ddr_read.add_argument("--timeout-polls", type=integer, default=10_000)
    ddr_read.add_argument("--output", type=Path, help="write raw DDR bytes")

    ddr_verify = subparsers.add_parser("ddr-verify", help="sample DDR beats against a local file")
    ddr_verify.add_argument("file", type=Path)
    ddr_verify.add_argument("--ddr-address", type=integer, default=0)
    ddr_verify.add_argument("--file-offset", type=integer, default=0)
    ddr_verify.add_argument("--length", type=integer, help="comparison span, default file remainder")
    ddr_verify.add_argument("--samples", type=integer, default=64)
    ddr_verify.add_argument("--seed", type=integer, default=1)
    ddr_verify.add_argument("--timeout-polls", type=integer, default=10_000)

    ddr_write = subparsers.add_parser("ddr-write", help="destructively write one 16-byte DDR beat")
    ddr_write.add_argument("address", type=integer)
    ddr_write.add_argument("words", type=integer, nargs=4, metavar="WORD")
    ddr_write.add_argument("--byte-enable", type=integer, default=0xFFFF)
    ddr_write.add_argument("--timeout-polls", type=integer, default=10_000)

    command = subparsers.add_parser("command", help="send complete raw command word transactions")
    command.add_argument("words", type=integer, nargs="+", metavar="WORD")
    subparsers.add_parser("flush", help="discard pending FPGA command-stream work")
    return parser.parse_args()


def read_items(transport: Ch347Transport, register_map: RegisterMap, names: tuple[str, ...]) -> list[dict[str, object]]:
    items = []
    for name in names:
        address = register_map.resolve(name)
        value = transport.read_register(address)
        item: dict[str, object] = {"name": name, "address": address, "value": value}
        fields = register_map.decode_fields(address, value)
        if fields:
            item["fields"] = fields
        items.append(item)
    return items


def print_items(items: list[dict[str, object]]) -> None:
    for item in items:
        print(f"{item['name']:<38} 0x{item['address']:04x} = 0x{item['value']:08x}")
        fields = item.get("fields", {})
        if fields:
            print("  " + " ".join(f"{name}={value}" for name, value in fields.items()))


def main() -> int:
    args = parse_args()
    register_map = RegisterMap(args.register_map)
    with Ch347Transport(
        device=args.device,
        library=args.lib,
        clock_hz=args.clock_hz,
        chip_select_mask=args.cs_mask,
    ) as transport:
        if args.command == "info":
            version = transport.read_register(register_map.resolve("VERSION"))
            print(f"device={transport.device}")
            print(f"library={args.lib}")
            print(f"library-info={transport.library_info}")
            print(f"spi-clock-hz={transport.clock_hz}")
            print(f"version=0x{version:08x}")
        elif args.command == "read":
            names = tuple(register_map.name(register_map.resolve(value)) for value in args.register)
            items = read_items(transport, register_map, names)
            if args.json:
                print(json.dumps(items, indent=2))
            else:
                print_items(items)
        elif args.command == "write":
            address = register_map.resolve(args.register)
            transport.write_register(address, args.value)
            print(f"wrote {register_map.name(address)} 0x{address:04x} = 0x{args.value:08x}")
        elif args.command == "clear-diagnostics":
            transport.write_register(register_map.resolve("DIAGNOSTIC_CONTROL"), 1)
            print("diagnostic interval cleared")
            if args.verify:
                print_items(read_items(transport, register_map, (
                    "UNDERRUN_COUNT", "SAMPLE_DROP_COUNT", "RENDER_DEADLINE_MISS_COUNT",
                    "COMMAND_ERROR_COUNT", "STALE_GENERATION_COUNT", "SAMPLE_WINDOW_REQUEST_COUNT",
                )))
        elif args.command == "snapshot":
            names = tuple(
                name for group in SNAPSHOT_GROUPS.values() for name in group
            ) if args.group == "all" else SNAPSHOT_GROUPS[args.group]
            items = read_items(transport, register_map, names)
            document = {
                "device": transport.device,
                "spi_clock_hz": transport.clock_hz,
                "registers": items,
            }
            output = json.dumps(document, indent=2) + "\n"
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(output, encoding="utf-8")
                print(f"wrote {args.output}")
            elif args.json:
                print(output, end="")
            else:
                print_items(items)
        elif args.command == "ddr-read":
            started = time.perf_counter()
            data = DdrDebugAccess(transport, args.timeout_polls).read(args.address, args.beats)
            elapsed = time.perf_counter() - started
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_bytes(data)
                print(f"wrote {len(data)} bytes to {args.output}")
            else:
                for offset in range(0, len(data), 16):
                    print(f"0x{args.address + offset:08x}: {data[offset:offset + 16].hex(' ')}")
            print(f"read {len(data)} bytes in {elapsed:.6f} s ({len(data) / elapsed / 1024:.2f} KiB/s)")
        elif args.command == "ddr-verify":
            file_size = args.file.stat().st_size
            length = args.length if args.length is not None else file_size - args.file_offset
            if args.ddr_address & 0xF or args.file_offset & 0xF:
                raise ValueError("DDR address and file offset must be 16-byte aligned")
            if length < 16 or args.file_offset < 0 or args.file_offset + length > file_size:
                raise ValueError("comparison span must contain complete in-file data")
            if args.samples <= 0:
                raise ValueError("sample count must be positive")
            beat_count = length // 16
            sample_count = min(args.samples, beat_count)
            indices = {0, beat_count - 1}
            if sample_count > len(indices):
                population = range(1, max(1, beat_count - 1))
                indices.update(random.Random(args.seed).sample(
                    population, min(sample_count - len(indices), len(population))
                ))
            indices = set(sorted(indices)[:sample_count])
            access = DdrDebugAccess(transport, args.timeout_polls)
            mismatches = []
            started = time.perf_counter()
            with args.file.open("rb") as source:
                for index in sorted(indices):
                    source.seek(args.file_offset + index * 16)
                    expected = source.read(16)
                    actual = access.read_beat(args.ddr_address + index * 16)
                    if actual != expected:
                        mismatches.append((index, expected, actual))
            elapsed = time.perf_counter() - started
            for index, expected, actual in mismatches[:8]:
                print(
                    f"mismatch ddr=0x{args.ddr_address + index * 16:08x} "
                    f"file=0x{args.file_offset + index * 16:08x} "
                    f"expected={expected.hex()} actual={actual.hex()}"
                )
            print(
                f"checked {len(indices)} beats across {beat_count * 16} bytes in {elapsed:.6f} s; "
                f"mismatches={len(mismatches)}"
            )
            if mismatches:
                return 2
        elif args.command == "ddr-write":
            DdrDebugAccess(transport, args.timeout_polls).write_beat(
                args.address, args.words, args.byte_enable
            )
            print(f"wrote DDR beat at 0x{args.address:08x}")
        elif args.command == "command":
            transport.write_command_words(args.words)
            print(f"sent {len(args.words)} command words")
        elif args.command == "flush":
            transport.flush_command_stream()
            print("command stream flushed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Ch347Error, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
