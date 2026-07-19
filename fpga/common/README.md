# Common FPGA Adapter RTL

This directory holds reusable board-facing RTL that is synthesizable but is not
part of the generic wavetable synthesizer core.

Use this layer for adapters that bind the core's abstract contracts to physical
or system-integration details:

- register transports such as SPI, UART, or soft-core buses,
- board/system debug register windows,
- sample or serial-clock tick generation,
- audio serializers such as I2S,
- reusable wrappers that compose those adapters around `rtl/top` core blocks.

Do not put voice allocation, MIDI/SF2 policy, DSP algorithms, wave-memory format
logic, vendor IP, board pin constraints, or simulation-only models here. Vendor
IP and concrete board tops belong under `fpga/<board>/`; behavioral models belong
under `sim/` or `fpga/<board>/sim/`.

The common register-transport boundary is the core bus:

```text
bus_valid, bus_write, bus_address, bus_wdata
bus_ready, bus_error, bus_rdata
```

New transports should adapt to that bus instead of changing
`wavetable_render_core` or `wavetable_cached_render_core`.
