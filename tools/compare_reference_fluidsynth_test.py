#!/usr/bin/env python3
"""Unit tests for the reference/FluidSynth comparison report parser."""

import unittest

import compare_reference_fluidsynth as compare


LEFT_PEAK_DB = -1.25
LEFT_RMS_DB = -10.5
RIGHT_PEAK_DB = -2.5
RIGHT_RMS_DB = -13.0
SAMPLE_COUNT = 48000
ASTATS_FIXTURE = f"""
[Parsed_astats_0] Channel: 1
[Parsed_astats_0] Peak level dB: {LEFT_PEAK_DB}
[Parsed_astats_0] RMS level dB: {LEFT_RMS_DB}
[Parsed_astats_0] Channel: 2
[Parsed_astats_0] Peak level dB: {RIGHT_PEAK_DB}
[Parsed_astats_0] RMS level dB: {RIGHT_RMS_DB}
[Parsed_astats_0] Overall
[Parsed_astats_0] RMS level dB: {(LEFT_RMS_DB + RIGHT_RMS_DB) / 2.0}
[Parsed_astats_0] Number of samples: {SAMPLE_COUNT}
"""


class AstatsTest(unittest.TestCase):
    def test_parse_stereo_and_balance_sign(self):
        result = compare.parse_astats(ASTATS_FIXTURE)
        self.assertEqual(result["left"]["peak_db"], LEFT_PEAK_DB)
        self.assertEqual(result["right"]["rms_db"], RIGHT_RMS_DB)
        self.assertEqual(
            result["left_minus_right_rms_db"],
            LEFT_RMS_DB - RIGHT_RMS_DB,
        )
        self.assertEqual(result["number_of_samples"], SAMPLE_COUNT)

    def test_comparison_uses_balance_not_absolute_level(self):
        reference = compare.parse_astats(ASTATS_FIXTURE)
        fluid = dict(reference)
        fluid_balance_db = 0.25
        fluid["left_minus_right_rms_db"] = fluid_balance_db
        result = compare.comparison(reference, fluid)
        self.assertTrue(result["sample_count_match"])
        self.assertEqual(
            result["reference_minus_fluidsynth_balance_db"],
            LEFT_RMS_DB - RIGHT_RMS_DB - fluid_balance_db,
        )


if __name__ == "__main__":
    unittest.main()
