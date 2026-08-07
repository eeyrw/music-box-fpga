# Project Contracts

This page is the entry point for project definitions. It identifies the
authoritative document and implementation source for each contract. Design
notes, backlogs, and archived plans may explain decisions but do not override
these sources.

## Contract Index

| Area | Authoritative document | Implementation source |
| --- | --- | --- |
| Numeric formats, rounding, saturation | [`fixed_point.md`](fixed_point.md) | `rtl/pkg/synth_pkg.sv`, `rtl/generated/synth_dsp_lut_pkg.sv` |
| Wave image and ordered memory traffic | [`memory_format.md`](memory_format.md) | `rtl/memory/`, `rtl/bus/` |
| Register addresses and fields | [`register_map.md`](register_map.md) | `spec/register_map.json` |
| Command words and voice lifecycle | [`command_stream.md`](command_stream.md) | `rtl/control/voice_major_command_plane.sv`, `sim/harness/control/command_control.*` |
| Compact MCU SoundFont sidecar | [`host/mcu_sf2_asset_format.md`](host/mcu_sf2_asset_format.md) | `sim/harness/formats/mcu_sf2_asset.*` |
| RP2040 USB MIDI, UAC2 capture, I2S, and board wiring | [`mcu/rp2040_firmware.md`](mcu/rp2040_firmware.md) | `mcu/` |
| SPI command transaction envelope | [`design/transport/spi_command_stream.md`](design/transport/spi_command_stream.md) | `fpga/common/rtl/spi_register_bridge.sv` |
| SPI register mailbox | [`design/transport/spi_register_mailbox.md`](design/transport/spi_register_mailbox.md) | `fpga/common/rtl/spi_register_bridge.sv`, `tools/ch347_transport.py` |
| Current renderer ownership and flow | [`design/renderer/overview.md`](design/renderer/overview.md) | `rtl/top/voice_major_render_core.sv`, `rtl/voice/` |
| Board asset image and loading | [`board/asset_loading.md`](board/asset_loading.md) | `fpga/smart_artix/rtl/` |

Generated register constants are never edited directly. Change
`spec/register_map.json`, run `make generate-register-map`, and commit the
generated SystemVerilog and C++ outputs with the source change. Generated DSP
tables follow the same rule through `tools/gen_dsp_lut.py`.

## Command Quick Reference

Commands are 32-bit words transported by SPI opcode `0xa5`; pending command
recovery uses `0xa6` FLUSH, while whole-session invalidation uses the separate
`0xa7` RENDER_SESSION_RESET transaction. The command header
contains the command opcode, 10-bit voice ID, flags, and payload length. The SPI
transaction header, word byte order, word-count limit, and CRC16 are separate
from command semantics; see the two linked contracts above.

| Opcode | Command | Payload words | Purpose |
| ---: | --- | ---: | --- |
| `0x10` | `VOICE_START_MONO` | 5 to 16 | Atomically install a mono voice and reset its runtime phase/filter state. |
| `0x13` | `VOICE_ENV_UPDATE` | 7 | Replace runtime envelope parameters without restarting the voice. |
| `0x14` | `VOICE_RELEASE` | 2 | Enter release using the matching generation. |
| `0x15` | `VOICE_STOP` | 1 | Stop the matching voice generation immediately. |
| `0x16` | `VOICE_GAIN` | 2 | Update left/right gain. |
| `0x17` | `VOICE_FILTER` | 4 | Replace filter enable and coefficients. |
| `0x18` | `VOICE_PITCH` | 2 | Update phase increment without reloading phase. |
| `0x20` | `COMPRESSOR_CONFIG` | 4 | Atomically replace compressor controls. |
| `0x21` | `MASTER_VOLUME` | 1 | Update post-compressor master gain. |
| `0x22` | `CHORUS_CONFIG` | 6 | Replace global chorus controls. |
| `0x23` | `REVERB_CONFIG` | 9 | Replace global reverb controls. |
| `0x24` | `EFFECT_CLEAR` | 1 | Clear selected global effect state. |

Use [`command_stream.md`](command_stream.md) for exact bit fields, optional
`VOICE_START_MONO` payload sections, generation rules, and render-boundary
visibility. This table is only a navigation aid; it does not duplicate payload
packing.

## Change Rule

When behavior and documentation disagree, stop and resolve the contract in the
same change. Do not silently make the testbench, C++ model, and RTL agree on new
behavior while leaving the authoritative document unchanged. Follow
[`development/rtl_change_workflow.md`](development/rtl_change_workflow.md) for
the required verification and implementation gates.
