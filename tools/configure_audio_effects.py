#!/usr/bin/env python3

"""Configure the Smart Artix global audio output chain over CH347 SPI."""

from __future__ import annotations

import argparse
import math
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from ch347_transport import (
    Ch347Error,
    Ch347Transport,
    DEFAULT_LIBRARY,
    DEFAULT_REGISTER_MAP,
    RegisterMap,
    encode_command_transaction,
)


SAMPLE_RATE = 48_000
FDN_DELAY_LENGTHS = (1451, 1559, 1663, 1777, 1879, 1999, 2131, 2371)


@dataclass(frozen=True)
class ReverbPreset:
    rt60_seconds: float
    input_send: float
    return_gain: float
    damping: float
    pre_delay_ms: float


REVERB_PRESETS = {
    "studio": ReverbPreset(1.0, 0.30, 0.18, 0.55, 8.0),
    "hall": ReverbPreset(4.5, 0.75, 0.55, 0.58, 35.0),
    "reverb-max": ReverbPreset(8.0, 1.0, 1.0, 0.55, 30.0),
}


def integer(value: str) -> int:
    try:
        return int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"invalid integer: {value}") from error


def round_half_up(value: float) -> int:
    return math.floor(value + 0.5)


def q1_15(value: float) -> int:
    return min(0x7FFF, max(0, round_half_up(value * 32768.0)))


def command(opcode: int, payload: Sequence[int]) -> list[int]:
    return [(opcode << 24) | len(payload), *payload]


def compressor_command(
    enabled: bool,
    threshold_cb: float,
    ratio: float,
    attack_ms: float,
    release_ms: float,
) -> list[int]:
    if not 0.0 <= threshold_cb <= 1000.0:
        raise ValueError("compressor threshold must be in 0..1000 cB")
    if ratio < 1.0 or attack_ms < 0.0 or release_ms < 0.0:
        raise ValueError("compressor ratio must be at least 1; times must be nonnegative")

    def step(milliseconds: float) -> int:
        if milliseconds == 0.0:
            return 0
        frames = max(1, round_half_up(milliseconds * SAMPLE_RATE / 1000.0))
        return ((1000 << 20) + frames - 1) // frames

    slope = min(0xFFFF, round_half_up((1.0 - 1.0 / ratio) * 65536.0))
    payload = (
        (slope << 1) | int(enabled),
        round_half_up(threshold_cb * (1 << 20)),
        step(attack_ms),
        step(release_ms),
    )
    return command(0x20, payload)


def master_volume_command(gain_db: float) -> list[int]:
    if not math.isfinite(gain_db) or not -120.0 <= gain_db <= 0.0:
        raise ValueError("master gain must be finite and in -120..0 dB")
    gain_q1_15 = round_half_up(math.pow(10.0, gain_db / 20.0) * 0x7FFF)
    return command(0x21, (gain_q1_15,))


def reverb_command(preset_name: str) -> list[int]:
    if preset_name == "off":
        return command(0x23, (0,) * 9)
    preset = REVERB_PRESETS[preset_name]
    gains = [
        q1_15(
            math.pow(
                10.0,
                -3.0 * delay / (preset.rt60_seconds * SAMPLE_RATE),
            )
            / math.sqrt(8.0)
        )
        for delay in FDN_DELAY_LENGTHS
    ]
    packed_gains = [gains[index] | (gains[index + 1] << 16) for index in range(0, 8, 2)]
    pre_delay_frames = round_half_up(preset.pre_delay_ms * SAMPLE_RATE / 1000.0)
    payload = (
        (pre_delay_frames << 1) | 1,
        q1_15(preset.input_send),
        q1_15(preset.return_gain),
        q1_15(preset.damping),
        0,
        *packed_gains,
    )
    return command(0x23, payload)


def build_words(args: argparse.Namespace) -> list[int]:
    return compressor_command(
        args.compressor == "on",
        args.threshold_cb,
        args.ratio,
        args.attack_ms,
        args.release_ms,
    ) + master_volume_command(args.master_db) + reverb_command(args.reverb)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="auto", help="device path, index, or auto")
    parser.add_argument("--lib", type=Path, default=DEFAULT_LIBRARY, help="official libch347.so")
    parser.add_argument("--clock-hz", type=integer, default=30_000_000)
    parser.add_argument("--cs-mask", type=integer, default=0x80)
    parser.add_argument("--register-map", type=Path, default=DEFAULT_REGISTER_MAP)
    parser.add_argument("--compressor", choices=("on", "off"), default="on")
    parser.add_argument("--threshold-cb", type=float, default=20.0,
                        help="positive centibels below full scale (default: 20)")
    parser.add_argument("--ratio", type=float, default=4.0)
    parser.add_argument("--attack-ms", type=float, default=0.0)
    parser.add_argument("--release-ms", type=float, default=5000.0)
    parser.add_argument("--master-db", type=float, default=0.0,
                        help="global output gain in dB, -120..0 (default: 0)")
    parser.add_argument("--reverb", choices=("off", *REVERB_PRESETS), default="hall")
    parser.add_argument("--dry-run", action="store_true", help="print command data without CH347 access")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    words = build_words(args)
    transaction = encode_command_transaction(words)
    if args.dry_run:
        print("words=" + " ".join(f"0x{word:08x}" for word in words))
        print(f"transaction={transaction.hex()}")
        return 0

    register_map = RegisterMap(args.register_map)
    with Ch347Transport(
        device=args.device,
        library=args.lib,
        clock_hz=args.clock_hz,
        chip_select_mask=args.cs_mask,
    ) as transport:
        transport.write_command_words(words)
        time.sleep(0.05)
        compressor_status = transport.read_register(register_map.resolve("COMPRESSOR_STATUS"))
        effect_status = transport.read_register(register_map.resolve("EFFECT_STATUS"))

    compressor_enabled = bool(compressor_status & 1)
    reverb_enabled = bool(effect_status & 2)
    expected_compressor = args.compressor == "on"
    expected_reverb = args.reverb != "off"
    if compressor_enabled != expected_compressor or reverb_enabled != expected_reverb:
        raise Ch347Error(
            "configuration readback mismatch: "
            f"COMPRESSOR_STATUS=0x{compressor_status:08x} "
            f"EFFECT_STATUS=0x{effect_status:08x}"
        )
    if effect_status & (1 << 13):
        raise Ch347Error(f"reverb configuration was clamped: EFFECT_STATUS=0x{effect_status:08x}")
    print(
        f"compressor={args.compressor} master_db={args.master_db:g} reverb={args.reverb} "
        f"COMPRESSOR_STATUS=0x{compressor_status:08x} "
        f"EFFECT_STATUS=0x{effect_status:08x}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (Ch347Error, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
