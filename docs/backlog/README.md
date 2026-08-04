# Backlogs

These documents track unresolved work. They may describe proposals that are not
implemented and must not be used in place of the stable contracts or current
design documents linked from [`../README.md`](../README.md).

- [`system_architecture.md`](system_architecture.md): system-level limitations,
  redesign candidates, dependency order, and acceptance gates.
- [`envelope.md`](envelope.md): remaining SoundFont envelope compatibility and
  renderer-efficiency work.
- [`effects.md`](effects.md): effects completion status and open qualification.
- [`spi_transport.md`](spi_transport.md): SPI correctness, physical timing, and
  optional future transport work.
- [`ethernet_udp_ddr3.md`](ethernet_udp_ddr3.md): static-IPv4 RGMII/UDP DDR3
  maintenance transport that retains SD loading, with protocol, arbitration,
  resource, verification, and hardware gates.
- [`realtime_midi_host.md`](realtime_midi_host.md): SF2 loading and lookup
  efficiency, bounded host control work, CH347 command scheduling, and the
  future real-time MIDI application.
- [`midi_panic.md`](midi_panic.md): MIDI All Sound Off/All Notes Off parity,
  scheduler cancellation, and a bounded global RTL emergency-silence path.
- [`mcu_sf2_asset_compiler.md`](mcu_sf2_asset_compiler.md): proposed offline
  SoundFont metadata compiler, packed MCU asset format, allocation-free lookup,
  fixed-point modulation execution, and acceptance gates that preserve the
  current RTL and command-stream contracts.
