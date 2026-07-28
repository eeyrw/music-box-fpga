# Legacy RTL

This directory preserves the superseded frame-scanning stereo renderer and its
transactional action-control path. It is excluded from `rtl/filelist.f`, the
default lint/test flow, and current FPGA builds.

Current production RTL uses `voice_major_render_core`, the compact command
plane, mono voice state, and `voice_sample_window`. Files here are retained only
for history and targeted comparison; they are not a compatibility contract.
