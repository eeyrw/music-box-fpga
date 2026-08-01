# NOR Flash Feasibility Models

This note compares the simulation-only QSPI and x16 asynchronous parallel NOR
backends against the same renderer, 32-word per-voice window, ordered 8-word
line interface, and real SF2/MIDI workloads. Both models preserve the current
RTL cache policy; only external-memory service timing changes.

The full-polyphony result is decisive: parallel NOR improves substantially on
QSPI, but neither modeled NOR backend meets the current 512-voice deadline.
Timed DDR3 remains the supported memory backend.

## QSPI NOR

### Purpose And Boundary

`qspi_nor_timing_model` is a simulation-only transaction model for evaluating a
read-only wavetable image behind the renderer's ordered 8-word line interface.
It models command, address, mode, dummy, data, chip-select recovery, request
queueing, continuous sequential reads, response ordering, and response
backpressure. It reads the same sparse binary image format as the DDR3 model.

It is not a QSPI controller, pin-level flash model, configuration-flash sharing
implementation, timing constraint, or board qualification. A passing render
establishes a bandwidth/latency data point only.

### Datasheet Baseline

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

### Read Granularity And Continuous Reads

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

### Running The Model

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
`rtl_renderer_max_cycles`, `rtl_renderer_max_utilization_ppm`,
`rtl_renderer_deadline_misses`, `qspi_lines`,
`qspi_sequential_lines`, `qspi_random_lines`, `qspi_transactions`,
`qspi_overhead_cycles`, `qspi_data_cycles`, and
`qspi_bus_utilization_ppm`. Feasibility requires zero deadline misses on the
intended workload with margin; average raw bandwidth alone is insufficient.

### Initial A/B Result

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

### Capacity And Board Limits

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

## Parallel x16 NOR

### Purpose And Boundary

`parallel_nor_timing_model` models a read-only x16 asynchronous NOR array
behind the same ordered 8-word line interface. It covers random access, page
access, page boundaries, queueing, capacity across devices, ordered responses,
and response backpressure. It reads the same sparse binary image as the DDR3
and QSPI models.

It is not a synthesizable controller, pin-level flash model, write/erase model,
board timing constraint, or signal-integrity qualification. A passing render
would establish only an optimistic latency/bandwidth data point.

### Datasheet Baseline

The integrated profile is based on Infineon's
[`S29GL01GS10DHI013`](https://www.infineon.com/part/S29GL01GS10DHI013), a
1-Gbit x16 asynchronous parallel NOR part advertised with 100 ns random access
and 15 ns page access. The family
[`S29GL-S data sheet`](https://www.infineon.com/dgdl/Infineon-S29GL01GS_S29GL512S_S29GL256S_S29GL128S_128_Mb_256_Mb_512_Mb_1_Gb_GL-S_MIRRORBIT_TM_Flash_Parallel_3-DataSheet-v22_00-EN.pdf?fileId=8ac78c8c7d0d8da4017d0ed07ac14bd5)
defines a 16-word/32-byte page. With CE# and OE# asserted and the upper address
stable, changing A3:A0 selects words at page-access timing.

At the 100 MHz core clock the model rounds timing upward to whole clocks:

```text
random word           = ceil(100 ns / 10 ns) = 10 clocks
following page word   = ceil(15 ns / 10 ns) = 2 clocks
random 8-word line    = 10 + 7 * 2 = 24 clocks
same-page 8-word line = 8 * 2 = 16 clocks
```

This is deliberately optimistic. Order code, temperature, VIO, PCB delay,
FPGA input timing, and controller turnaround can require a slower profile. All
timing, page, and capacity values are model parameters.

### Window And Page Interaction

The 16-word device page holds two external 8-word beats. A page-aligned 32-word
window refill costs:

```text
24 + 16 + 24 + 16 = 80 core clocks
```

Page mode is retained only when the next request is already queued in the same
page. Queue drain, page change, or device change starts a random access. Thus
the current four-request refill uses the device's batch-read behavior without
pretending unrelated fallback reads are continuous.

The 1-Gbit x16 part stores 64M words, or 128 MiB. The SGM test image contains
162,400,335 words (324,800,670 bytes, about 310 MiB), so two devices are too
small. The integrated profile uses three devices for 384 MiB. They share the
address/data bus and use separate chip selects: this expands capacity only and
does not multiply bandwidth.

### Running The Model

Focused timing and backpressure test:

```bash
make test-parallel-nor-model
```

Real SF2/MIDI render:

```bash
make render-rtl-parallel-nor \
  SF2='/path/to/input.sf2' \
  MIDI='/path/to/input.mid' \
  SECONDS=1 CONTROL_TICK_MS=1
```

The report is `rtl_parallel_nor_render_config.json`. Key fields are
`rtl_renderer_max_cycles`, `rtl_renderer_max_utilization_ppm`,
`rtl_renderer_deadline_misses`, `parallel_nor_lines`,
`parallel_nor_page_lines`, `parallel_nor_random_lines`,
`parallel_nor_transactions`, and `parallel_nor_bus_utilization_ppm`.

### One-Second SGM Comparison

The 2026-07-31 comparison used SGM v2.01, the generated 512-voice stress MIDI,
48 kHz, one second, a 1 ms control tick, the 32-word window, a 100 MHz core, 907
selected regions, and 512 peak active voices.

| Metric | Timed DDR3 | x16 parallel NOR | x4 QSPI NOR |
| --- | ---: | ---: | ---: |
| Output frames | 48,000 | 48,000 | 48,000 |
| Render blocks | 3,039 | 3,039 | 3,039 |
| External 8-word lines | 3,864,271 | 3,864,271 | 3,864,271 |
| Window stall cycles | 13,633,306 | 102,201,473 | 198,718,696 |
| Total render cycles | 85,158,385 | 137,621,024 | 229,687,494 |
| Maximum render cycles | 31,876 | 55,019 | 95,551 |
| Maximum deadline utilization | 96.954% | 213.528% | 357.084% |
| Deadline misses | 0 | 3,035 | 3,036 |
| NOR fast/continuous lines | N/A | 910,592 | 1,814,754 |
| NOR random transactions | N/A | 2,953,679 | 2,049,517 |
| Reported NOR bus utilization | N/A | 61.822% | 77.723% |
| Bus time required per 1 s audio | N/A | 85.458% | 178.994% |

#### Profile Metric Definitions

`Output frames` is the requested audio duration after conversion to samples:
one second at 48 kHz is 48,000 stereo output frames. It is not the count of
render requests or memory lines.

`Render blocks` counts accepted renderer work blocks. MIDI events, 1 ms control
updates, and the configured maximum of 16 frames split 48,000 frames into 3,039
variable-size blocks. Each block has its own real-time budget:

```text
block_deadline_cycles = block_frame_count * 100,000,000 / 48,000
```

`External 8-word lines` is `rtl_window_memory_reads`. Every line is eight
16-bit PCM words, or 16 bytes. The identical count across all three backends is
expected because the production 32-word window and request sequence are
unchanged. It follows the exact accounting identity:

```text
604,918 refills * 4 lines + 1,444,599 fallback lines = 3,864,271 lines
3,864,271 lines * 16 bytes = 61,828,336 payload bytes
```

`Window stall cycles` is the sum, over accepted sample requests, of core clocks
spent waiting while the per-voice window cannot return the requested word. It
includes refill and fallback memory wait, and the same stalled clock can delay
the renderer pipeline. It is a diagnostic accumulation, not a disjoint wall
clock duration, so it must not be added to `Total render cycles`.

`rtl_renderer_total_cycles` is the sum from each accepted block request to that
block's renderer completion. It measures how much renderer service the complete
one-second workload consumed. When it exceeds the one-second real-time supply
of approximately 100 million core clocks, the run cannot keep pace on average;
a lower total still does not prove that every individual block met its deadline.

`rtl_renderer_max_cycles` is the raw latency of the single slowest block. Blocks
have different frame counts, so this number cannot be compared with one fixed
deadline. `rtl_renderer_max_utilization_ppm` performs the correct per-block
normalization and reports the largest
`render_cycles / block_deadline_cycles`. Values above 100% are deadline
violations; a value below 100% gives the remaining worst-case margin.

`rtl_renderer_deadline_misses` counts blocks whose normalized utilization
exceeded 100%.
Thus Parallel NOR's 3,035 misses mean that all but four of the 3,039 blocks were
late. It is not a count of dropped audio samples; the offline harness still
finishes all 48,000 frames so that timing and output can be inspected.

`NOR fast/continuous lines` has backend-specific meaning. For parallel NOR it
is `parallel_nor_page_lines`: an 8-word line whose words use page timing because
the preceding queued line selected the same 16-word page. For QSPI it is
`qspi_sequential_lines`: a following adjacent line transferred without another
command/address/mode/dummy sequence. These counts show batch-read reuse but are
not directly comparable cache hit rates.

`NOR random transactions` counts lines that start the expensive portion of a
device access. Parallel NOR pays the random first-word time for every
`parallel_nor_random_lines` entry, and that count equals its transactions. A
QSPI transaction pays command/address/mode/dummy overhead once and may then
carry several continuous lines, so its transaction count can be smaller even
though its serialized data time is larger.

`Reported NOR bus utilization` is the JSON field
`*_bus_active_cycles / rtl_core_cycles`. Its denominator expands when a slow
memory stretches the offline render: 85,457,768 active parallel-NOR clocks over
138,231,498 simulated core clocks produce 61.822%. It describes contention
inside that completed simulation, not the fraction of a fixed one-second
real-time budget.

`Bus time required per 1 s audio` uses the fixed 100,000,000 clocks available
at 100 MHz during one second. Parallel NOR requires 85,457,768 active clocks, or
85.458%; QSPI requires 178,993,631 clocks, or 178.994%. This is the appropriate
average-bandwidth feasibility measure. Parallel NOR passes that average test
with little practical margin but fails burst deadlines; QSPI fails both average
bandwidth and burst deadlines.

Parallel NOR is substantially faster than QSPI, but it still misses nearly
every block deadline. Of 3,864,271 line reads, 2,953,679 pay random latency.
The 16-word page boundary and 1,444,599 one-line fallback reads dominate. The
eight-word interface already exploits page mode for adjacent queued requests;
widening only the response beat would not remove this access pattern.

The result rejects this three-device shared-bus profile for the current
512-voice acceptance workload. Lower polyphony, an extracted sample set, or a
more local workload requires its own complete render before being called viable.

### Polyphony Estimate

Here, one voice means one active RTL voice slot, not one played MIDI note. A
layered SoundFont note can allocate several voice slots, so a product's musical
note polyphony is lower than this number.

The one-second 512-voice workload transfers 3,864,271 lines of 16 bytes, or
61.83 MB of payload. The model charges 178,993,631 QSPI bus clocks and
85,457,768 parallel-NOR bus clocks for that fixed workload. At 100 MHz, the
same access pattern therefore has these average-bandwidth limits:

| Average-bandwidth estimate | x4 QSPI | x16 parallel NOR |
| --- | ---: | ---: |
| Effective payload rate at 100% bus duty | 34.54 MB/s | 72.35 MB/s |
| Linear voice limit at 100% bus duty | 286 | 599 |
| Linear voice limit at 80% bus duty | 229 | 479 |

The calculation is:

```text
voice_limit = 512 * allowed_bus_clocks / measured_bus_clocks
allowed_bus_clocks = 100,000,000 * target_bus_duty
```

Those numbers answer only the average-bandwidth question. They are not safe
real-time voice counts. At 512 voices, the measured worst-block deadline ratios
are 3.57084 for QSPI and 2.13528 for parallel NOR. If worst-block cost scaled
linearly with active voices, an optimistic 100% deadline estimate would be
about 143 QSPI voices and 240 parallel-NOR voices. Limiting worst-block use to
80% for timing margin gives about 115 and 192 voices respectively:

| Deadline-oriented planning estimate | x4 QSPI | x16 parallel NOR |
| --- | ---: | ---: |
| Linear limit at 100% of block deadline | 143 | 240 |
| Linear limit at 80% of block deadline | 115 | 192 |
| Reasonable first validation range | 100-120 | 180-200 |

The deadline-oriented range is the appropriate initial product estimate for
this SGM access pattern. It is intentionally below the average-bandwidth limit
because bursts of random/fallback reads, not the one-second average, caused the
misses. The scaling is still an estimate: fixed per-block compute cost, voice
stealing, SoundFont layering, stereo regions, pitch, and loop locality are not
linear. Before setting a supported polyphony specification, generate stress
MIDI capped at several points around these ranges and require zero deadline
misses with the intended margin.

### Board Cost

A 1-Gbit x16 device needs 26 word-address and 16 data signals, plus control and
per-device chip selects. Three shared-bus devices therefore consume on the
order of the mid-40s FPGA I/O pins before optional status signals, while still
providing one x16 read at a time. Voltage-bank compatibility, asynchronous
input timing, pin availability, PCB loading, and simultaneous switching must be
checked for the exact board and order code.

Because this optimistic model already fails the target workload, implementing
a synthesizable controller and board pin assignment is not justified for the
current architecture. The model remains a reproducible lower-load comparison.
