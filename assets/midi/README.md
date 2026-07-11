# MIDI Render Samples

These files are a small representative subset copied from a larger local MIDI
collection for the C++ render harness. They are intended as smoke-test inputs,
not as golden audio references.

| File | Why It Is Included |
| --- | --- |
| `simple_single_channel.mid` | Short single-channel melody with one program. |
| `musicbox_two_programs.mid` | Short music-box style file with two program states. |
| `multitrack_16_channel.mid` | Multi-track file using all 16 MIDI channels. |
| `percussion_multichannel.mid` | Multi-channel file with channel-10 percussion events. |
| `dense_many_notes.mid` | Dense arrangement with many simultaneous notes and programs. |
| `long_single_channel.mid` | Longer single-channel piece for duration and event scheduling checks. |
| `hedwigs_theme_finished.mid` | Multi-instrument arrangement that stresses wave-memory locality and cache miss behavior. |
