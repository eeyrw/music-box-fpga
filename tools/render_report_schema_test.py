#!/usr/bin/env python3
"""Validate the normalized render report schema and all catalog references."""

import json
import sys


def require_index(value, catalog, context):
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{context} must be an integer catalog index")
    if value < 0 or value >= len(catalog):
        raise ValueError(f"{context} index {value} is out of range")


def validate(path):
    with open(path, "r", encoding="utf-8") as report_file:
        report = json.load(report_file)
    if report.get("report_schema_version") != 2:
        raise ValueError("report_schema_version must be 2")
    catalogs = report["catalogs"]
    required = (
        "presets", "instruments", "samples", "sample_windows",
        "volume_envelopes", "modulator_sources", "generator_destinations",
        "modulator_transforms", "modulator_sets", "modulation_profiles",
    )
    for name in required:
        if not isinstance(catalogs.get(name), list):
            raise ValueError(f"catalogs.{name} must be an array")

    source_ids = {entry["raw"] for entry in catalogs["modulator_sources"]}
    destination_ids = {entry["raw"] for entry in catalogs["generator_destinations"]}
    transform_ids = {entry["raw"] for entry in catalogs["modulator_transforms"]}
    for index, window in enumerate(catalogs["sample_windows"]):
        require_index(window["sample"], catalogs["samples"],
                      f"sample_windows[{index}].sample")
    for set_index, modulator_set in enumerate(catalogs["modulator_sets"]):
        for mod_index, modulator in enumerate(modulator_set):
            context = f"modulator_sets[{set_index}][{mod_index}]"
            if modulator["src"] not in source_ids or modulator["amount_src"] not in source_ids:
                raise ValueError(f"{context} references an undescribed source")
            if modulator["dest"] not in destination_ids:
                raise ValueError(f"{context} references an undescribed destination")
            if modulator["transform"] not in transform_ids:
                raise ValueError(f"{context} references an undescribed transform")
    for index, profile in enumerate(catalogs["modulation_profiles"]):
        require_index(profile["modulator_set"], catalogs["modulator_sets"],
                      f"modulation_profiles[{index}].modulator_set")

    forbidden = {"sample_left", "sample_right", "modulators", "modulation_generators"}
    for index, region in enumerate(report["regions"]):
        require_index(region["preset"], catalogs["presets"], f"regions[{index}].preset")
        require_index(region["instrument"], catalogs["instruments"],
                      f"regions[{index}].instrument")
        require_index(region["sample_window"], catalogs["sample_windows"],
                      f"regions[{index}].sample_window")
        require_index(region["volume_envelope"], catalogs["volume_envelopes"],
                      f"regions[{index}].volume_envelope")
        require_index(region["modulation"], catalogs["modulation_profiles"],
                      f"regions[{index}].modulation")
        legacy = forbidden.intersection(region)
        if legacy:
            raise ValueError(f"regions[{index}] contains legacy inline fields: {sorted(legacy)}")


def main():
    if len(sys.argv) != 2:
        print("usage: render_report_schema_test.py report.json", file=sys.stderr)
        return 2
    try:
        validate(sys.argv[1])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"render report schema validation failed: {error}", file=sys.stderr)
        return 1
    print("PASS: normalized render report schema and catalog references")
    return 0


if __name__ == "__main__":
    sys.exit(main())
