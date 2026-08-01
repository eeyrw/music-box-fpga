#!/usr/bin/env python3
"""Validate MCU asset profiles and their stable-contract dependencies."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROFILE_PATH = ROOT / "spec" / "mcu_asset_profiles.json"
REGISTER_PATH = ROOT / "spec" / "register_map.json"
GENERATED_HEADER_PATH = ROOT / "sim" / "harness" / "generated" / "mcu_asset_profile.h"
REFERENCE_ID = "generic-le32-48k-tick48-v13"


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as source:
        return json.load(source)


def register_interface_version(register_spec: dict) -> int:
    for peripheral in register_spec["device"]["peripherals"]:
        for register in peripheral["registers"]:
            if register["name"] == "VERSION":
                return int(register["resetValue"], 0)
    raise ValueError("register map has no VERSION register")


def render_header(reference: dict) -> str:
    command_version = int(reference["commandInterfaceVersion"], 0)
    return f"""// Generated from spec/mcu_asset_profiles.json. Do not edit by hand.
#pragma once

#include <cstdint>

namespace render::mcu_asset_profile {{
inline constexpr char kId[] = \"{reference['id']}\";
constexpr uint32_t kCommandInterfaceVersion = 0x{command_version:08x}u;
constexpr uint32_t kOutputSampleRate = {reference['outputSampleRate']}u;
constexpr uint32_t kControlTickSamples = {reference['controlTickSamples']}u;
}}  // namespace render::mcu_asset_profile
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--generate", action="store_true")
    args = parser.parse_args()
    spec = load_json(PROFILE_PATH)
    if spec.get("schema") != "wavetable-mcu-asset-profiles-v1":
        raise ValueError("unsupported MCU asset profile schema")
    profiles = spec.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        raise ValueError("MCU asset profile list must be nonempty")

    by_id: dict[str, dict] = {}
    for profile in profiles:
        profile_id = profile.get("id")
        if not isinstance(profile_id, str) or not profile_id:
            raise ValueError("MCU asset profile id must be a nonempty string")
        if profile_id in by_id:
            raise ValueError(f"duplicate MCU asset profile id: {profile_id}")
        by_id[profile_id] = profile

        if profile.get("byteOrder") not in {"little", "big"}:
            raise ValueError(f"{profile_id}: unsupported byteOrder")
        for field in ("wordBits", "outputSampleRate", "controlTickSamples"):
            if not isinstance(profile.get(field), int) or profile[field] <= 0:
                raise ValueError(f"{profile_id}: {field} must be a positive integer")
        try:
            int(profile["commandInterfaceVersion"], 0)
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(
                f"{profile_id}: commandInterfaceVersion must be an integer string"
            ) from error

    reference = by_id.get(REFERENCE_ID)
    if reference is None:
        raise ValueError(f"missing reference profile: {REFERENCE_ID}")
    expected = {
        "status": "reference",
        "targetMcu": None,
        "byteOrder": "little",
        "wordBits": 32,
        "outputSampleRate": 48000,
        "controlTickSamples": 48,
        "metadataStorage": "unspecified",
    }
    for field, value in expected.items():
        if reference.get(field) != value:
            raise ValueError(
                f"{REFERENCE_ID}: expected {field}={value!r}, got {reference.get(field)!r}"
            )

    profile_version = int(reference["commandInterfaceVersion"], 0)
    register_version = register_interface_version(load_json(REGISTER_PATH))
    if profile_version != register_version:
        raise ValueError(
            f"{REFERENCE_ID}: command interface 0x{profile_version:08x} does not match "
            f"register map 0x{register_version:08x}"
        )

    expected_header = render_header(reference)
    if args.generate:
        GENERATED_HEADER_PATH.write_text(expected_header, encoding="utf-8")
    elif not GENERATED_HEADER_PATH.exists() or GENERATED_HEADER_PATH.read_text(
        encoding="utf-8"
    ) != expected_header:
        raise ValueError(
            "generated MCU asset profile header is stale; run "
            "make generate-mcu-asset-profile"
        )

    print(
        f"PASS: {len(profiles)} MCU asset profile(s); reference {REFERENCE_ID} "
        f"matches interface 0x{register_version:08x}; generated header is current"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
