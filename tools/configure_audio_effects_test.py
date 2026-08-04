#!/usr/bin/env python3

import unittest

from configure_audio_effects import (
    compressor_command,
    format_compressor_status,
    format_effect_status,
    master_volume_command,
    reverb_command,
)
from ch347_transport import encode_command_transaction


class ConfigureAudioEffectsTest(unittest.TestCase):
    def test_default_compressor_encoding(self) -> None:
        self.assertEqual(
            compressor_command(True, 20.0, 4.0, 0.0, 5000.0),
            [0x20000004, 0x00018001, 0x01400000, 0x00000000, 0x00001112],
        )

    def test_documented_reverb_presets(self) -> None:
        studio = reverb_command("studio")
        hall = reverb_command("hall")
        self.assertEqual(studio[1:6], [0x00000301, 0x2666, 0x170A, 0x4666, 0])
        self.assertEqual(studio[6:], [0x242924BA, 0x230B239F, 0x21F12288, 0x202C214D])
        self.assertEqual(hall[1:6], [0x00000D21, 0x6000, 0x4666, 0x4A3D, 0])
        self.assertEqual(hall[6:], [0x2B0E2B34, 0x2AC12AE9, 0x2A742A9E, 0x29F32A46])

    def test_master_volume_encoding(self) -> None:
        self.assertEqual(master_volume_command(0.0), [0x21000001, 0x00007FFF])
        self.assertEqual(master_volume_command(-6.0), [0x21000001, 0x00004026])
        with self.assertRaises(ValueError):
            master_volume_command(0.1)

    def test_complete_transaction_is_valid(self) -> None:
        words = (
            compressor_command(True, 20.0, 4.0, 0.0, 5000.0)
            + master_volume_command(0.0)
            + reverb_command("hall")
        )
        encoded = encode_command_transaction(words)
        self.assertEqual(encoded[:2], bytes((0xA5, 17)))

    def test_compressor_status_has_semantic_readback(self) -> None:
        self.assertEqual(
            format_compressor_status(0x00012307),
            "COMPRESSOR_STATUS=0x00012307 [enabled=on, primed=yes, "
            "gain_reduction=active, delay_level_frames=291]",
        )

    def test_effect_status_has_semantic_readback(self) -> None:
        self.assertEqual(
            format_effect_status(0x00005A5E),
            "EFFECT_STATUS=0x00005a5e [chorus=off, reverb=on, busy=yes, "
            "chorus_history=valid, reverb_valid_lines=0xa5 (4/8), "
            "clamped=chorus,return_mixer]",
        )

    def test_effect_status_reports_empty_flags(self) -> None:
        self.assertEqual(
            format_effect_status(0),
            "EFFECT_STATUS=0x00000000 [chorus=off, reverb=off, busy=no, "
            "chorus_history=empty, reverb_valid_lines=0x00 (0/8), clamped=none]",
        )


if __name__ == "__main__":
    unittest.main()
