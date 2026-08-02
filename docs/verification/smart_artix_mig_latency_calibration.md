# Smart Artix MIG Latency Calibration

This document records the 2026-08-02 investigation into the discrepancy between
PC timed-DDR3 render results and Smart Artix hardware underruns. It defines the
current simulation calibration, its evidence, and the remaining optimization
work. The practical board commands remain in
[`../board/smart_artix_bringup.md`](../board/smart_artix_bringup.md).

## Question And Result

The original timed-DDR3 model passed a short 512-voice render while the board
reported severe deadline misses and I2S underruns under the same SF2/MIDI
workload. The discrepancy was not caused by SF2 contents, DDR addressing,
command corruption, or a different cache access pattern.

The model included DDR3 device timing but omitted the completion pipeline of the
MIG UI, memory controller, and PHY. Adding 80 cycles at the model's 400 MHz DDR
clock, equivalent to 20 cycles of the 100 MHz MIG UI clock, reproduced both the
static 465-voice board maximum and the 512-voice overload direction.

This 80-cycle value is an empirical equivalent delay for the current MIG
configuration and workload. It is not an AMD-guaranteed constant latency.

## Configuration Under Test

The local MIG project `fpga/smart_artix/vivado/ip/smart_artix_ddr3_mig/mig_b.prj`
specifies:

| Field | Value |
| --- | --- |
| Memory part | `MT41K256M16XX-107` |
| DDR clock period | 2,500 ps, 400 MHz |
| PHY ratio | 4:1 |
| MIG UI clock | 100 MHz |
| External data width | 16 bits |
| Application data width | 128 bits per BL8 command |
| Address map | bank-row-column |
| Bank machines | 4 |
| UI extra clocks | 0 |

`UIExtraClocks=0` does not mean zero UI/controller/PHY latency. It only says the
optional MIG configuration extension is zero.

The hardware measurements used interface version 14 and volatile bitstream
SHA-256
`fed441cc14e63d01d7e522ef2b99d1f37a41731ed0e46e7b7af031a9b43e5b5f`.
The host link was CH347 SPI mode 0 at 30 MHz. The SoundFont was
`SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2`; sampled DDR ranges matched the source
bytes exactly. The default generated MIDI had SHA-256
`1136cfb87a71d1bd1d859efb8c55fab6f1290675f22327ebfb55c38324ab1135`.
The current configuration Flash contains an earlier image and was not used for
this investigation.

AMD UG586 documents the relevant interface behavior:

- [`app_en`/`app_rdy` command path](https://docs.amd.com/r/en-US/ug586_7Series_MIS/Command-Path):
  a handshake accepts a command into the UI; it does not say that DRAM service
  or read completion occurred.
- [Memory controller](https://docs.amd.com/r/en-US/ug586_7Series_MIS/Memory-Controller):
  the controller queues requests and uses bank machines, a column machine, and
  arbitration; requests may be reordered for throughput and latency.
- [Read path](https://docs.amd.com/r/en-US/ug586_7Series_MIS/Read-Path): read data
  is returned when `app_rd_data_valid` is asserted and remains ordered by the
  original requests.
- [Bank machines](https://docs.amd.com/r/en-US/ug586_7Series_MIS/Bank-Machines):
  a request occupies a dynamically assigned bank machine while its row and
  column commands are completed.

Those contracts explain why raw `tRCD`/`tCL` timing alone is insufficient, but
they do not specify one fixed application read latency for every traffic shape.

## Measurement Boundaries

Hardware `PIPELINE_LATENCY_MAX` measures an accepted render-block request until
`block_complete_valid` is first observed. The C++ RTL render report's
`rtl_renderer_max_cycles` uses the same accepted-request-to-publication
boundary.

`MEM_RESPONSE_COUNT` counts accepted external line responses.
`PIPELINE_LATENCY_MAX[31:16]` records only the maximum request-to-response
latency. It does not provide total or average latency, and it does not include a
sample-window memory request waiting before the external request handshake.
The observed hardware maximum was 59 UI clocks. That upper bound is compatible
with an approximately 20-clock completion pipeline, but it cannot reveal how
often each latency occurred.

`SAMPLE_WINDOW_STALL_CYCLE_COUNT` is therefore the more useful aggregate
indicator. It counts cycles in which the renderer has a client request but the
single sample-window transaction state machine cannot accept it. It includes
window lookup/refill serialization and memory-response wait.

## Evidence That Workloads Match

The board's three-second static workload and the PC 20 ms initial interval both
used 320 simultaneous MIDI notes expanding to 465 mono hardware voices. Their
cache traffic proportions were close:

| Metric | Board static interval | PC device-only model |
| --- | ---: | ---: |
| Client requests | 15,212,453 | 100,856 |
| Window hits | 10,760,291 | 72,028 |
| Refill misses | 1,505,533 | 9,992 |
| Fallback misses | 2,946,629 | 18,836 |
| Memory reads | 8,968,761 | 58,804 |
| Stall cycles/request | 10.36 | 1.71 |
| Maximum render clocks | 31,516 | 25,781 |

Both identities closed exactly:

```text
client_requests = hits + refills + fallbacks
memory_reads = 4 * refills + fallbacks
```

The similar hit/refill/fallback mix rules out a materially different SF2 access
stream or window-cache policy. The large stall difference localizes the missing
cost to memory completion and serialization.

## Calibration Sweep

The simulation model gained `DDR3_EXTRA_READ_CYCLES`, applied to read completion
after device `tCL` and burst aggregation. It does not extend physical data-bus
occupancy, so independent queued reads can still overlap. The first 20 ms of
`polyphony_stress_512.mid` produced:

```bash
make render-rtl-ddr3 \
  SF2='/path/to/SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2' \
  MIDI=build/polyphony_stress_512.mid \
  SECONDS=0.02 CONTROL_TICK_MS=1 DETAILED_DIAGNOSTICS=0 \
  DDR3_EXTRA_READ_CYCLES=80
```

| Extra 400 MHz cycles | Equivalent UI cycles | Max render clocks | Deadline misses | Window stall cycles | Stall/request |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 0 | 25,781 | 0 | 172,621 | 1.71 |
| 32 | 8 | 26,553 | 0 | 460,692 | 4.57 |
| 64 | 16 | 29,757 | 0 | 854,619 | 8.47 |
| 80 | 20 | 31,585 | 0 | 1,028,654 | 10.20 |
| 96 | 24 | 34,027 | 3 | 1,180,603 | 11.71 |
| 128 | 32 | 38,871 | 49 | 1,447,261 | 14.35 |

The 80-cycle point matches the hardware static maximum of 31,516 clocks within
69 clocks, or 0.22%. Its stall/request ratio is also close to the hardware
ratio. This agreement uses two independent outputs rather than fitting only one
maximum.

## 512-Voice Confirmation

The first 200 ms of the default stress MIDI reaches 512 voices while remaining
short enough for practical cycle-accurate simulation:

```bash
make render-rtl-ddr3 \
  SF2='/path/to/SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2' \
  MIDI=build/polyphony_stress_512.mid \
  SECONDS=0.2 CONTROL_TICK_MS=1 DETAILED_DIAGNOSTICS=0 \
  DDR3_EXTRA_READ_CYCLES=80
```

| Metric | Device-only model | Calibrated model | Board full workload |
| --- | ---: | ---: | ---: |
| Extra DDR cycles | 0 | 80 | physical MIG |
| Rendered blocks | 600 | 600 | continuous hardware playback |
| Peak voices | 512 | 512 | 512 |
| Maximum render clocks | 29,966 | 43,633 | 43,040 |
| Deadline misses | 0 | 525 | 6,874 |
| Window stall cycles | 3,253,993 | 15,468,763 | 625,946,375 |

The calibrated 200 ms model reproduces the maximum-latency scale and converts
the old false pass into the same overload classification as hardware. Exact miss
counts are not expected to match because the board result covers the complete
10-second MIDI plus its tail, real-time command arrival, and a longer cache
history.

## Root Cause

The system is latency-bound rather than DDR-bandwidth-bound.

The full board interval returned 33,985,123 lines of 16 bytes. Over roughly 11
seconds this is about 49 MB/s (47 MiB/s), far below the 1.6 GB/s raw transfer
rate of a 400 MHz DDR x16 interface. More raw bandwidth therefore does not by
itself remove the deadline misses.

The current `voice_sample_window` owns one global transaction FSM. A refill can
queue four adjacent line reads, and the Smart Artix line reader can retain eight
transactions, but the window cannot begin another voice's hit or miss until the
current client transaction completes. Hundreds of misses per block repeatedly
expose the MIG completion pipeline instead of overlapping it across voices.

The original PC model hid this because its device-only response was much faster.
The renderer, window identities, DDR contents, and command transport can all be
correct while the block still misses its real-time deadline.

## Current Model Contract

`make render-rtl-ddr3` now defaults to:

```text
DDR3_EXTRA_READ_CYCLES=80
```

Override it only for an explicit sensitivity or historical comparison:

```bash
make render-rtl-ddr3 DDR3_EXTRA_READ_CYCLES=0 \
  SF2='/path/to/input.sf2' MIDI=build/polyphony_stress_512.mid \
  SECONDS=0.02 CONTROL_TICK_MS=1 DETAILED_DIAGNOSTICS=0
```

The `ddr3_timing_model` module parameter itself defaults to zero so focused
device-timing tests can select a known completion delay independently. Its
self-checking test instantiates a five-cycle delay and requires exact
cold/hit/conflict latencies of 35/15/37 cycles.

The 80-cycle calibration must be rechecked after changing MIG frequency, PHY
ratio, bank-machine count, ordering mode, application width, line-reader depth,
or sample-window concurrency. It is a calibrated board profile, not a portable
DDR3 device property.

## Optimization Priorities

1. Allow multiple voice misses to remain in flight with ordered descriptors, so
   the existing MIG and line-reader queues can hide completion latency across
   voices.
2. Evaluate sector-valid/on-demand window fill with at most measured lookahead.
   This can avoid four-line cold fills when a job uses only one or two lines.
3. A/B a 64-word window only with the calibrated model. It costs about eight
   additional RAMB36 blocks and can double cold refill traffic, so static
   coverage alone is not an acceptance criterion.
4. Record total memory latency and external-request backpressure in future
   hardware diagnostics; a maximum without a sum or histogram cannot determine
   average service cost.
5. Do not treat a deeper audio FIFO as a throughput fix. It can absorb isolated
   long blocks but cannot recover from sustained render time above the audio
   production budget.

Any production window or scheduler change requires focused memory tests, a
calibrated timed render, and a fresh post-route Smart Artix implementation under
[`../development/rtl_change_workflow.md`](../development/rtl_change_workflow.md).
