# Legacy Simulation Sources

This directory contains testbenches and C++ harnesses for the superseded
frame-scanning renderer. They are preserved for historical comparison and are
not part of the default simulation targets.

The current RTL render flow is `make render-rtl-ddr3`; shared SF2/MIDI loading,
session setup, reporting, and reference synthesis remain under `sim/harness`.
