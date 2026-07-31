"""Shared Standard MIDI File event parsing for Python analysis tools."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass
class MidiEvent:
    time_seconds: float
    order: int
    event_type: str
    channel: int
    note: int = 0
    velocity: int = 0
    program: int = 0
    bank: int = 0
    controller: int = 0
    value: int = 0
    pitch_bend: int = 0


def _read_u16be(data: bytes, pos: int) -> int:
    return (data[pos] << 8) | data[pos + 1]


def _read_u32be(data: bytes, pos: int) -> int:
    return ((data[pos] << 24) | (data[pos + 1] << 16) |
            (data[pos + 2] << 8) | data[pos + 3])


def _read_varlen(data: bytes, pos: int, end: int) -> tuple[int, int]:
    value = 0
    for _ in range(4):
        if pos >= end:
            raise ValueError("truncated MIDI varlen")
        byte = data[pos]
        pos += 1
        value = (value << 7) | (byte & 0x7F)
        if (byte & 0x80) == 0:
            return value, pos
    raise ValueError("MIDI varlen exceeds four bytes")


def _read_data_bytes(data: bytes, pos: int, end: int, count: int) -> tuple[list[int], int]:
    if pos + count > end:
        raise ValueError("truncated MIDI channel event")
    values = list(data[pos:pos + count])
    if any(value & 0x80 for value in values):
        raise ValueError("invalid MIDI data byte in channel event")
    return values, pos + count


def parse_midi_events(path: str | Path) -> list[MidiEvent]:
    """Parse format 0/1 PPQ MIDI and merge channel state across tracks."""
    data = Path(path).read_bytes()
    if len(data) < 14 or data[:4] != b"MThd":
        raise ValueError("not a standard MIDI file")
    header_len = _read_u32be(data, 4)
    if header_len < 6 or 8 + header_len > len(data):
        raise ValueError("truncated MIDI header")
    midi_format = _read_u16be(data, 8)
    track_count = _read_u16be(data, 10)
    division = _read_u16be(data, 12)
    if midi_format > 2:
        raise ValueError("unsupported MIDI file format")
    if midi_format == 0 and track_count != 1:
        raise ValueError("format 0 MIDI must contain one track")
    if midi_format == 2:
        raise ValueError("format 2 MIDI is not supported")
    if track_count == 0:
        raise ValueError("MIDI file contains no tracks")
    if division & 0x8000:
        raise ValueError("SMPTE MIDI timing is not supported")
    if division == 0:
        raise ValueError("MIDI PPQ division must be nonzero")

    pos = 8 + header_len
    raw_events = []
    tempos = [(0, 500000, 0)]
    order = 1
    for _track in range(track_count):
        if pos + 8 > len(data) or data[pos:pos + 4] != b"MTrk":
            raise ValueError("missing MTrk chunk")
        size = _read_u32be(data, pos + 4)
        pos += 8
        end = pos + size
        if end > len(data):
            raise ValueError("truncated MIDI track")

        tick = 0
        running_status = None
        saw_end_of_track = False
        while pos < end:
            delta, pos = _read_varlen(data, pos, end)
            tick += delta
            if tick > 0xFFFFFFFF:
                raise ValueError("MIDI tick overflow")
            if pos >= end:
                raise ValueError("truncated MIDI event")

            status = data[pos]
            if status & 0x80:
                pos += 1
                running_status = status if 0x80 <= status <= 0xEF else None
            elif running_status is not None:
                status = running_status
            else:
                raise ValueError("MIDI running status without previous status")

            if status == 0xFF:
                if pos >= end:
                    raise ValueError("truncated MIDI meta event")
                meta = data[pos]
                pos += 1
                length, pos = _read_varlen(data, pos, end)
                if pos + length > end:
                    raise ValueError("truncated MIDI meta payload")
                if meta == 0x2F:
                    if length != 0:
                        raise ValueError("MIDI End of Track must have zero length")
                    if pos != end:
                        raise ValueError("MIDI End of Track must be the final track event")
                    saw_end_of_track = True
                elif meta == 0x51 and length == 3:
                    tempo = (data[pos] << 16) | (data[pos + 1] << 8) | data[pos + 2]
                    tempos.append((tick, tempo, order))
                order += 1
                pos += length
                continue

            if status in (0xF0, 0xF7):
                length, pos = _read_varlen(data, pos, end)
                if pos + length > end:
                    raise ValueError("truncated MIDI sysex payload")
                pos += length
                order += 1
                continue

            kind = status & 0xF0
            channel = status & 0x0F
            if kind in (0x80, 0x90, 0xA0, 0xB0, 0xE0):
                values, pos = _read_data_bytes(data, pos, end, 2)
                a, b = values
            elif kind in (0xC0, 0xD0):
                values, pos = _read_data_bytes(data, pos, end, 1)
                a, b = values[0], 0
            else:
                raise ValueError(f"unsupported MIDI status 0x{status:02x}")
            raw_events.append((tick, order, kind, channel, a, b))
            order += 1

        if not saw_end_of_track:
            raise ValueError("MIDI track is missing End of Track")
        pos = end

    tempos.sort(key=lambda item: (item[0], item[2]))
    raw_events.sort(key=lambda item: (item[0], item[1]))
    program = [0] * 16
    bank_msb = [0] * 16
    bank_lsb = [0] * 16
    tick_events = []
    for tick, event_order, kind, channel, a, b in raw_events:
        bank = (bank_msb[channel] << 7) | bank_lsb[channel]
        event = {
            "tick": tick,
            "order": event_order,
            "channel": channel,
            "program": program[channel],
            "bank": bank,
        }
        if kind in (0x80, 0x90):
            event.update(event_type="note_on" if kind == 0x90 and b != 0 else "note_off",
                         note=a, velocity=b)
        elif kind == 0xB0:
            if a == 0:
                bank_msb[channel] = b
            elif a == 32:
                bank_lsb[channel] = b
            event.update(event_type="control", controller=a, value=b,
                         bank=(bank_msb[channel] << 7) | bank_lsb[channel])
        elif kind == 0xC0:
            program[channel] = a
            event.update(event_type="program", program=a)
        elif kind == 0xE0:
            event.update(event_type="pitch_bend", pitch_bend=((b << 7) | a) - 8192)
        elif kind == 0xD0:
            event.update(event_type="channel_pressure", value=a)
        elif kind == 0xA0:
            event.update(event_type="key_pressure", note=a, value=b)
        tick_events.append(event)

    tempo_index = 0
    last_tick = 0
    last_seconds = 0.0
    tempo = tempos[0][1]
    events = []
    for event in tick_events:
        tick = event["tick"]
        while tempo_index + 1 < len(tempos) and tempos[tempo_index + 1][0] <= tick:
            next_tick, next_tempo, _ = tempos[tempo_index + 1]
            last_seconds += (next_tick - last_tick) * tempo / division / 1000000.0
            last_tick = next_tick
            tempo = next_tempo
            tempo_index += 1
        seconds = last_seconds + (tick - last_tick) * tempo / division / 1000000.0
        fields = {key: value for key, value in event.items() if key not in ("tick", "order")}
        events.append(MidiEvent(time_seconds=seconds, order=event["order"], **fields))
    return events
