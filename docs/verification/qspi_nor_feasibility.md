# QSPI NOR Feasibility Model

## Purpose And Boundary

`qspi_nor_timing_model` is a simulation-only transaction model for evaluating a
read-only wavetable image behind the renderer's ordered 8-word line interface.
It models command, address, mode, dummy, data, chip-select recovery, request
queueing, continuous sequential reads, response ordering, and response
backpressure. It reads the same sparse binary image format as the DDR3 model.

It is not a QSPI controller, pin-level flash model, configuration-flash sharing
implementation, timing constraint, or board qualification. A passing render
establishes a bandwidth/latency data point only.

## Datasheet Baseline

The default protocol geometry follows the 4-byte Quad-I/O read sequence of the
Macronix
[`MX66L2G45G`](https://www.macronix.com/Lists/Datasheet/Attachments/8959/MX66L2G45G%2C%203V%2C%202Gb%2C%20v1.1.pdf):

- 2 Gbit / 256 MiB, 3 V, x1/x2/x4 serial NOR;
- one 8-bit command on one lane;
- a 32-bit address in eight quad-lane clocks;
- a two-clock performance-enhance/mode field;
- eight dummy clocks by default;
- four data bits per clock and automatic sequential address increment.

The model adds one CS-high recovery clock, giving 27 overhead clocks for a new
transaction. One 128-bit renderer line then needs 32 data clocks. Adjacent
queued lines can remain in the same continuous read and pay only the 32 data
clocks. All fields are parameters so a different part or SFDP configuration can
be represented without editing model behavior.

The integrated profile clocks the model from the 100 MHz core clock. Its raw
quad-data ceiling is therefore 50 MB/s. A standalone random 16-byte line costs
59 clocks, or 590 ns and approximately 27.1 MB/s before controller CDC or board
margin. A continuous stream costs 320 ns per line and approaches 50 MB/s. These
are protocol calculations, not guaranteed board rates.

## Read Granularity And Continuous Reads

The persistent sample window and the external memory transaction use different
granularities:

```text
external ordered line = 8 PCM words = 16 bytes = 128 bits
per-voice window       = 32 PCM words = four ordered lines
```

The eight-word value is the response-beat width inherited from the Smart Artix
128-bit MIG application port. It is not a QSPI transaction limit. A QSPI read
transaction may stream any number of adjacent beats while CS remains low.

On the first miss for a render work item, `voice_sample_window` refills the
32-word window by issuing four adjacent ordered-line requests before waiting for
all responses. The QSPI model recognizes the queued adjacent addresses, pays the
27-clock command/address/mode/dummy/CS overhead once, and transfers the remaining
three lines as continuous data. A complete 32-word refill therefore costs:

```text
27 overhead clocks + 4 * 32 data clocks = 155 QSPI clocks
```

The current ordered request type has no explicit burst length; the timing model
detects adjacency in its request queue. A synthesizable QSPI reader should
instead accept a base address plus beat count and stream 128-bit responses with
an explicit final-beat indication. That prevents an upstream request bubble from
accidentally terminating continuous read without widening the data path to 512
bits.

Later endpoints in the same work item that fall outside that window use one
8-word fallback read without replacing the persistent window. Each non-adjacent
fallback starts a new QSPI transaction and pays the overhead again. The design
does not unconditionally fetch 32 words for every miss because sparse phase
steps or loop wrapping could then turn one required line into four external
reads. The refill/fallback policy must be evaluated from measured locality.

For comparison, current vendor portfolios include higher clock or different
width options. Micron lists production 2 Gbit x4 parts and identifies MT25Q
densities through 2 Gbit in its
[`serial NOR catalog`](https://www.micron.com/products/storage/nor-flash/serial-nor/part-catalog).
Infineon's
[`S25FL512S`](https://www.infineon.com/dgdl/Infineon-S25FL512S_512_Mb_%2864_MB%29_3.0_V_SPI_Flash_Memory-DataSheet-v19_00-EN.pdf?fileId=8ac78c8c7d0d8da4017d0ed046ae4b53)
documents up to 52 MB/s for 104 MHz Quad SDR and 80 MB/s for 80 MHz Quad DDR,
but its 512 Mbit density is only 64 MiB. Do not combine one device's frequency,
density, dummy-cycle, and voltage figures into a synthetic profile.

## Running The Model

Focused protocol test:

```bash
make test-qspi-nor-model
```

Real SF2/MIDI render:

```bash
make render-rtl-qspi \
  SF2=assets/soundfonts/MT6276.sf2 SECONDS=2
```

Representative polyphony stress:

```bash
make polyphony-stress-midi
make render-rtl-qspi \
  SF2='/path/to/stress.sf2' \
  MIDI=build/polyphony_stress_512.mid \
  SECONDS=3 CONTROL_TICK_MS=1 DETAILED_DIAGNOSTICS=0
```

The render writes `rtl_qspi_render_config.json`. The decisive fields are
`rtl_max_render_cycles`, `rtl_deadline_misses`, `qspi_lines`,
`qspi_sequential_lines`, `qspi_random_lines`, `qspi_transactions`,
`qspi_overhead_cycles`, `qspi_data_cycles`, and
`qspi_bus_utilization_ppm`. Feasibility requires zero deadline misses on the
intended workload with margin; average raw bandwidth alone is insufficient.

## Initial A/B Result

On 2026-07-31, the repository-generated polyphony stress MIDI was rendered for
0.1 seconds against the default 1.5 MB `MT6276.sf2`. Both runs used the same
512-voice build, 100 MHz core, 32-word voice window, 1 ms control tick, and 365
peak active mono voices:

| Metric | Timed DDR3 | 100 MHz x4 QSPI NOR |
| --- | ---: | ---: |
| Rendered blocks | 303 | 303 |
| Maximum render cycles | 23,785 | 73,249 |
| Maximum deadline utilization | 72.942% | 244.350% |
| Deadline misses | 0 | 301 |
| Ordered line reads | 302,570 | 302,570 |
| QSPI sequential lines | N/A | 105,537 |
| QSPI transactions | N/A | 197,033 |
| QSPI bus utilization | N/A | 79.145% |

The QSPI line accounting for this run was:

```text
35,179 window refills * 4 lines = 140,716 lines
161,854 one-line fallback reads = 161,854 lines
total                           = 302,570 lines

continuous lines = 35,179 refills * 3 following lines = 105,537
new transactions = 35,179 refill starts + 161,854 fallbacks = 197,033
```

This rejects a single 100 MHz x4 QSPI device for the current high-polyphony
target and access pattern. Raising only the serial clock to 133 MHz cannot close
a measured 2.44x deadline utilization, and the model does not include extra
board/CDC margin. Lower-polyphony or more local workloads can still pass; the
same run with one active voice had zero misses and only 2.49% QSPI utilization.
Use the intended complete MIDI/SF2 workload before choosing the device.

## Capacity And Board Limits

A single 2 Gbit part holds 256 MiB. The repository's default `MT6276.sf2` is
about 1.5 MB and fits easily, but the documented approximately 310 MB SGM stress
SoundFont does not fit one such device. That workload needs sample extraction,
multiple flash devices, or a denser/different memory technology.

The Smart Artix documentation does not identify the board's configuration-flash
part, wiring, voltage, or whether its data pins are available after
configuration. AMD documents post-configuration access to dedicated 7-series
configuration signals through
[`STARTUPE2`](https://docs.amd.com/r/2025.2-English/ug953-vivado-7series-libraries/STARTUPE2),
but that capability does not prove this board exposes a suitable x4 device or
meets 100 MHz I/O timing. Before production work, obtain the schematic and exact
flash part, then qualify configuration ownership, voltage, signal integrity,
CDC, XDC timing, reset/QE/4-byte-mode setup, and hardware readback.

QSPI NOR is read-only during rendering in this proposal. It does not replace
DDR3 storage needed by writable delay lines, asset loading, or other mutable
state.
