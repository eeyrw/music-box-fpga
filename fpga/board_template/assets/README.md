# Board Asset Flow

Runtime SF2 and MIDI parsing belongs in simulation or host-side software, not in
the FPGA fabric. A board project should generate deterministic artifacts that can
be loaded into the selected wave memory before playback.

Expected artifacts may include:

- Raw signed 16-bit PCM wave-memory image, interleaved left/right for stereo.
- Metadata tables for sample base address, length, loop range, channel mode, and
  default gain/filter parameters.
- Optional firmware tables for MIDI program/bank/preset lookup.
- A checksum or manifest for host-side validation after programming memory.

Possible output formats:

- `.bin` for external Flash/SDRAM preload tools.
- `.mem` or `.hex` for simulation and simple BRAM initialization.
- `.mif` for Intel/Altera memory initialization.
- `.coe` for Xilinx block-memory generator flows.

Keep generated assets out of Git unless they are intentionally small regression
fixtures.
