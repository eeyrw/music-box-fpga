#!/usr/bin/env python3

import unittest

from analyze_sf2_access_span import (
    SampleStream,
    analyze_for_line_words,
    resolve_job_count,
    summarize_midi_events,
    summarize_workload,
)
from midi_events import MidiEvent


def make_stream(stream_id, sample_id, phase_inc, note, loop_mode=0):
    return SampleStream(
        stream_id=stream_id,
        note_index=stream_id,
        channel=stream_id % 2,
        note=note,
        velocity=100,
        start_frame=0,
        end_frame=100,
        release_frame=100,
        program=0,
        bank=0,
        preset="Preset",
        instrument="Instrument",
        sample_id=sample_id,
        sample_name=f"Sample {sample_id}",
        sample_type=1,
        base_addr=1000,
        length=400,
        loop_start=20,
        loop_end=120,
        loop_mode=loop_mode,
        phase_inc=phase_inc,
        sample_rate=48000,
        original_pitch=60,
    )


class AnalyzeSf2AccessSpanTest(unittest.TestCase):
    def test_line_analysis_counts_exact_endpoint_lines(self):
        stream = make_stream(0, 7, 256, 60)
        stream.end_frame = 4
        stream.length = 10

        result = analyze_for_line_words(
            [stream], total_frames=4, sample_rate=48000, line_words=2,
            lookahead_ms_values=[1.0], top_count=1)

        self.assertEqual(result["endpoint_reads"], 8)
        self.assertEqual(result["stream_line_fills"], 3)
        self.assertEqual(result["physical_unique_lines"], 3)
        self.assertEqual(result["new_stream_lines_per_frame"]["max"], 1)
        self.assertEqual(result["active_streams_per_frame"]["max"], 1)

    def test_workload_summary_records_phase_and_unique_loop_regions(self):
        streams = [
            make_stream(0, 7, 256, 60, loop_mode=1),
            make_stream(1, 7, 512, 72, loop_mode=1),
            make_stream(2, 9, 2048, 84),
        ]

        summary = summarize_workload(streams, top_count=2)

        self.assertEqual(summary["unique_sample_count"], 2)
        self.assertEqual(summary["phase_step_source_frames_per_output"]["max"], 8.0)
        self.assertEqual([item["stream_count"] for item in summary["phase_step_thresholds"]],
                         [3, 2, 1, 1])
        self.assertEqual(summary["top_phase_step_streams"][0]["sample_id"], 9)
        self.assertEqual(summary["unique_loop_region_count"], 1)
        loop = summary["top_loop_wrap_regions"][0]
        self.assertEqual(loop["trigger_count"], 2)
        self.assertEqual(loop["loop_span_words"], 100)
        self.assertEqual(loop["loop_span_bytes"], 200)
        self.assertEqual((loop["minimum_note"], loop["maximum_note"]), (60, 72))

    def test_midi_summary_exposes_unmodeled_controller_workload(self):
        events = [
            MidiEvent(0.0, 0, "note_on", 0),
            MidiEvent(0.0, 1, "control", 0, controller=64, value=127),
            MidiEvent(0.0, 2, "control", 0, controller=101, value=0),
            MidiEvent(0.1, 3, "pitch_bend", 0, pitch_bend=4096),
        ]

        summary = summarize_midi_events(events)

        self.assertEqual(summary["pitch_bend_events"], 1)
        self.assertEqual(summary["pitch_bend_channels"], [0])
        self.assertEqual(summary["sustain_events"], 1)
        self.assertEqual(summary["sustain_on_events"], 1)
        self.assertEqual(summary["rpn_control_events"], 1)

    def test_job_count_is_bounded_by_task_count(self):
        self.assertEqual(resolve_job_count(1, 4), 1)
        self.assertEqual(resolve_job_count(8, 4), 4)
        self.assertGreaterEqual(resolve_job_count(0, 4), 1)
        self.assertLessEqual(resolve_job_count(0, 4), 4)


if __name__ == "__main__":
    unittest.main()
