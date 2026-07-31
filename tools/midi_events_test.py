#!/usr/bin/env python3

import struct
import tempfile
import unittest
from pathlib import Path

from midi_events import parse_midi_events


def varlen(value):
    out = [value & 0x7F]
    value >>= 7
    while value:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    return bytes(reversed(out))


def midi_file(midi_format, tracks):
    data = bytearray(b"MThd" + struct.pack(">IHHH", 6, midi_format, len(tracks), 480))
    for track in tracks:
        data.extend(b"MTrk" + struct.pack(">I", len(track)) + track)
    return bytes(data)


class MidiEventsTest(unittest.TestCase):
    def parse(self, payload):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test.mid"
            path.write_bytes(payload)
            return parse_midi_events(path)

    def test_channel_state_is_merged_across_format_one_tracks(self):
        state = (varlen(0) + bytes([0xB0, 0, 2]) +
                 varlen(0) + bytes([0xB0, 32, 3]) +
                 varlen(0) + bytes([0xC0, 5]) +
                 varlen(0) + b"\xff\x2f\x00")
        notes = (varlen(0) + bytes([0x90, 64, 100]) +
                 varlen(120) + bytes([0x80, 64, 0]) +
                 varlen(0) + b"\xff\x2f\x00")

        events = self.parse(midi_file(1, [state, notes]))
        note_events = [event for event in events if event.event_type.startswith("note_")]
        self.assertEqual([(event.program, event.bank) for event in note_events],
                         [(5, 259), (5, 259)])
        self.assertAlmostEqual(note_events[1].time_seconds, 0.125)

    def test_meta_event_cancels_running_status(self):
        track = (varlen(0) + bytes([0x90, 60, 100]) +
                 varlen(0) + b"\xff\x01\x00" +
                 varlen(0) + bytes([62, 100]) +
                 varlen(0) + b"\xff\x2f\x00")
        with self.assertRaisesRegex(ValueError, "running status"):
            self.parse(midi_file(0, [track]))


if __name__ == "__main__":
    unittest.main()
