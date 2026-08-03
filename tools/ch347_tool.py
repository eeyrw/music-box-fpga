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
    DDR_ACCESS_STATUS,
    DDR_STATUS_PRESENT,
    DDR_STATUS_READY,
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

PLATFORM_ERROR_PRESENT = 1 << 1
PLATFORM_DDR_CALIBRATED = 1 << 2
PLATFORM_SD_INITIALIZED = 1 << 4
PLATFORM_ASSET_LOADED = 1 << 5
CMD_FIFO_EMPTY = 1 << 0
CMD_PARSER_IDLE = 1 << 16
CMD_ACTION_PENDING = 1 << 17
COMMAND_ERROR_SUMMARY = (1 << 30) | (1 << 31)
COMMON_EVENT_ERROR = (1 << 0) | (1 << 1) | (1 << 2)
COMMON_EVENT_CLEAR = COMMON_EVENT_ERROR | (1 << 3)


def integer(value: str) -> int:
    try:
        return int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"invalid integer: {value}") from error


def voice_start_words(
    voice: int,
    generation: int,
    base: int,
    length: int,
    phase_inc: int,
    gain_l: int,
    gain_r: int,
) -> list[int]:
    if not 0 <= voice < 512:
        raise ValueError("voice must be in 0..511")
    if not 0 < generation <= 0xFFFF:
        raise ValueError("generation must be in 1..65535")
    if not 0 <= base <= 0xFFFFFFFF:
        raise ValueError("voice base address must be 32-bit")
    if not 0 < length <= 0xFFFFFF:
        raise ValueError("voice length must be in 1..0xffffff")
    if not 0 <= phase_inc <= 0xFFFFFFFF:
        raise ValueError("phase increment must be 32-bit")
    if not 0 <= gain_l <= 0x7FFF or not 0 <= gain_r <= 0x7FFF:
        raise ValueError("voice gains must be in 0..0x7fff")
    header = (0x10 << 24) | (voice << 14) | 5
    return [header, generation, base, length, phase_inc, gain_l | (gain_r << 16)]


def voice_stop_words(voice: int, generation: int) -> list[int]:
    if not 0 <= voice < 512 or not 0 < generation <= 0xFFFF:
        raise ValueError("voice or generation is out of range")
    return [(0x15 << 24) | (voice << 14) | 1, generation]


def fnv1a32_update(value: int, data: bytes) -> int:
    for byte in data:
        value = ((value ^ byte) * 0x01000193) & 0xFFFFFFFF
    return value


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

    wait = subparsers.add_parser("wait", help="wait for DDR or the SD asset to become ready")
    wait.add_argument("target", choices=("ddr", "asset"))
    wait.add_argument("--timeout-ms", type=integer, default=10_000)
    wait.add_argument("--poll-ms", type=integer, default=100)

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

    ddr_smoke = subparsers.add_parser("ddr-smoke", help="destructively write and verify one DDR beat")
    ddr_smoke.add_argument("address", type=integer)
    ddr_smoke.add_argument("words", type=integer, nargs="*", metavar="WORD")
    ddr_smoke.add_argument("--timeout-polls", type=integer, default=10_000)

    ddr_benchmark = subparsers.add_parser(
        "ddr-benchmark", help="sequentially read, hash, and optionally verify DDR bytes"
    )
    ddr_benchmark.add_argument("--address", type=integer, default=0)
    ddr_benchmark.add_argument("--bytes", type=integer, default=64 * 1024)
    ddr_benchmark.add_argument("--timeout-polls", type=integer, default=10_000)
    ddr_benchmark.add_argument("--output", type=Path)
    ddr_benchmark.add_argument("--verify", type=Path)
    ddr_benchmark.add_argument("--verify-offset", type=integer)

    voice_smoke = subparsers.add_parser(
        "voice-smoke", help="start, observe, and always stop one mono voice"
    )
    voice_smoke.add_argument("--voice", type=integer, default=0)
    voice_smoke.add_argument("--generation", type=integer, default=1)
    voice_smoke.add_argument("--base", type=integer, required=True)
    voice_smoke.add_argument("--length", type=integer, required=True)
    voice_smoke.add_argument("--phase-inc", type=integer, default=0x100)
    voice_smoke.add_argument("--gain-l", type=integer, default=0x2000)
    voice_smoke.add_argument("--gain-r", type=integer, default=0x2000)
    voice_smoke.add_argument("--duration-ms", type=integer, default=100)
    voice_smoke.add_argument("--timeout-ms", type=integer, default=10_000)
    voice_smoke.add_argument("--poll-ms", type=integer, default=10)

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


def wait_until_ready(
    transport: Ch347Transport,
    register_map: RegisterMap,
    target: str,
    timeout_ms: int,
    poll_ms: int,
) -> tuple[int, int, int, int]:
    if timeout_ms < 0 or poll_ms <= 0:
        raise ValueError("timeout must be nonnegative and poll interval must be positive")
    deadline = time.monotonic() + timeout_ms / 1000.0
    while True:
        platform = transport.read_register(register_map.resolve("PLATFORM_STATUS"))
        errors = transport.read_register(register_map.resolve("PLATFORM_ERRORS"))
        ddr = transport.read_register(DDR_ACCESS_STATUS)
        loaded = transport.read_register(register_map.resolve("PLATFORM_BYTES_LOADED"))
        size = transport.read_register(register_map.resolve("PLATFORM_SF2_SIZE"))
        if target == "asset" and platform & PLATFORM_ERROR_PRESENT:
            raise Ch347Error(f"platform error while waiting for asset: 0x{errors:08x}")
        ddr_ready = bool(
            platform & PLATFORM_DDR_CALIBRATED
            and ddr & DDR_STATUS_PRESENT
            and ddr & DDR_STATUS_READY
        )
        asset_ready = bool(
            ddr_ready
            and platform & PLATFORM_SD_INITIALIZED
            and platform & PLATFORM_ASSET_LOADED
            and size
            and loaded == size
        )
        if ddr_ready and (target == "ddr" or asset_ready):
            return platform, errors, loaded, size
        if time.monotonic() >= deadline:
            raise Ch347Error(
                f"{target} readiness timed out: platform=0x{platform:08x} "
                f"errors=0x{errors:08x} loaded={loaded} size={size}"
            )
        time.sleep(poll_ms / 1000.0)


def wait_command_idle(
    transport: Ch347Transport,
    register_map: RegisterMap,
    timeout_ms: int,
    poll_ms: int,
) -> int:
    if timeout_ms < 0 or poll_ms <= 0:
        raise ValueError("timeout must be nonnegative and poll interval must be positive")
    deadline = time.monotonic() + timeout_ms / 1000.0
    while True:
        status = transport.read_register(register_map.resolve("CMD_FIFO_STATUS"))
        if status & COMMAND_ERROR_SUMMARY:
            raise Ch347Error(f"command parser reports an error: 0x{status:08x}")
        if (
            status & CMD_FIFO_EMPTY
            and status & CMD_PARSER_IDLE
            and not status & CMD_ACTION_PENDING
        ):
            return status
        if time.monotonic() >= deadline:
            raise Ch347Error(f"command drain timed out: 0x{status:08x}")
        time.sleep(poll_ms / 1000.0)


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
        elif args.command == "wait":
            platform, errors, loaded, size = wait_until_ready(
                transport, register_map, args.target, args.timeout_ms, args.poll_ms
            )
            print(
                f"{args.target} ready: PLATFORM_STATUS=0x{platform:08x} "
                f"PLATFORM_ERRORS=0x{errors:08x} loaded={loaded} size={size}"
            )
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
        elif args.command == "ddr-smoke":
            words = args.words or [
                0x01234567, 0x89ABCDEF, 0x76543210, 0xFEDCBA98
            ]
            if args.address < 0 or args.address & 0xF:
                raise ValueError("DDR smoke address must be nonnegative and 16-byte aligned")
            if len(words) != 4:
                raise ValueError("ddr-smoke accepts either zero or four WORD values")
            if any(word < 0 or word > 0xFFFFFFFF for word in words):
                raise ValueError("DDR smoke words must be 32-bit unsigned values")
            wait_until_ready(
                transport, register_map, "ddr", 10_000, 100
            )
            access = DdrDebugAccess(transport, args.timeout_polls)
            access.write_beat(args.address, words)
            actual = access.read_beat(args.address)
            expected = b"".join(word.to_bytes(4, "little") for word in words)
            if actual != expected:
                raise Ch347Error(
                    f"DDR smoke mismatch: expected={expected.hex()} actual={actual.hex()}"
                )
            print(f"DDR smoke passed at 0x{args.address:08x}: {actual.hex(' ')}")
        elif args.command == "ddr-benchmark":
            if args.address < 0 or args.address & 0xF:
                raise ValueError("DDR benchmark address must be nonnegative and 16-byte aligned")
            if args.bytes <= 0 or args.bytes & 0xF:
                raise ValueError("DDR benchmark byte count must be positive and 16-byte aligned")
            if args.address + args.bytes > 512 * 1024 * 1024:
                raise ValueError("DDR benchmark range exceeds 512 MiB")
            verify_offset = args.address if args.verify_offset is None else args.verify_offset
            if verify_offset < 0:
                raise ValueError("verify offset must be nonnegative")
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
            output = args.output.open("wb") if args.output else None
            expected_file = args.verify.open("rb") if args.verify else None
            if expected_file:
                expected_file.seek(verify_offset)
            access = DdrDebugAccess(transport, args.timeout_polls)
            checksum = 0x811C9DC5
            mismatches = 0
            first_mismatch: tuple[int, int, int] | None = None
            started = time.perf_counter()
            try:
                for offset in range(0, args.bytes, 16):
                    actual = access.read_beat(args.address + offset)
                    checksum = fnv1a32_update(checksum, actual)
                    if output:
                        output.write(actual)
                    if expected_file:
                        expected = expected_file.read(16)
                        if len(expected) != 16:
                            raise ValueError("verify file is too short for the selected range")
                        for index, (actual_byte, expected_byte) in enumerate(zip(actual, expected)):
                            if actual_byte != expected_byte:
                                if first_mismatch is None:
                                    first_mismatch = (
                                        args.address + offset + index,
                                        actual_byte,
                                        expected_byte,
                                    )
                                mismatches += 1
            finally:
                if output:
                    output.close()
                if expected_file:
                    expected_file.close()
            elapsed = time.perf_counter() - started
            rate = args.bytes / elapsed
            print(
                f"DDR address=0x{args.address:08x} bytes={args.bytes} "
                f"elapsed={elapsed:.6f} s throughput={rate / 1024.0:.3f} KiB/s "
                f"({rate * 8.0 / 1_000_000.0:.3f} Mbit/s) fnv1a32=0x{checksum:08x}"
            )
            if args.verify:
                print(f"verify={'PASS' if mismatches == 0 else 'FAIL'} mismatches={mismatches}")
            if first_mismatch is not None:
                address, actual_byte, expected_byte = first_mismatch
                print(
                    f"first mismatch at 0x{address:08x}: "
                    f"actual=0x{actual_byte:02x} expected=0x{expected_byte:02x}"
                )
                return 2
        elif args.command == "voice-smoke":
            if args.duration_ms < 0:
                raise ValueError("voice smoke duration must be nonnegative")
            wait_until_ready(
                transport, register_map, "ddr", args.timeout_ms, args.poll_ms
            )
            wait_command_idle(
                transport, register_map, args.timeout_ms, args.poll_ms
            )
            start_words = voice_start_words(
                args.voice, args.generation, args.base, args.length,
                args.phase_inc, args.gain_l, args.gain_r,
            )
            stop_words = voice_stop_words(args.voice, args.generation)
            error_address = register_map.resolve("COMMAND_ERROR_COUNT")
            stale_address = register_map.resolve("STALE_GENERATION_COUNT")
            memory_address = register_map.resolve("MEM_RESPONSE_COUNT")
            event_address = register_map.resolve("COMMON_EVENT_FLAGS")
            errors_before = transport.read_register(error_address)
            stale_before = transport.read_register(stale_address)
            memory_before = transport.read_register(memory_address)
            transport.write_register(event_address, COMMON_EVENT_CLEAR)
            started = False
            try:
                transport.write_command_words(start_words)
                started = True
                wait_command_idle(
                    transport, register_map, args.timeout_ms, args.poll_ms
                )
                time.sleep(args.duration_ms / 1000.0)
            finally:
                if started:
                    transport.write_command_words(stop_words)
                    wait_command_idle(
                        transport, register_map, args.timeout_ms, args.poll_ms
                    )
            errors_after = transport.read_register(error_address)
            stale_after = transport.read_register(stale_address)
            memory_after = transport.read_register(memory_address)
            events_after = transport.read_register(event_address)
            if errors_after != errors_before or stale_after != stale_before:
                raise Ch347Error(
                    f"voice smoke changed command diagnostics: errors "
                    f"{errors_before}->{errors_after}, stale {stale_before}->{stale_after}"
                )
            if events_after & COMMON_EVENT_ERROR:
                raise Ch347Error(
                    f"voice smoke observed an audio error: events=0x{events_after:08x}"
                )
            if memory_after <= memory_before:
                raise Ch347Error("voice smoke observed no new memory response")
            print(
                f"voice smoke passed: voice={args.voice} generation={args.generation} "
                f"memory_responses={memory_before}->{memory_after}"
            )
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
