# DDR3 Cycle Model

Updated: 2026-07-28

`sim/models/ddr3_timing_model.sv` is the simulation-only DDR3 timing model for
renderer performance tests. C++ owns image loading and storage; SystemVerilog
owns every request, bank, row, refresh, and response cycle. Neither file is a
synthesis source.

This is a controller-level timing model, not a DDR3 pin/electrical model and not
a replacement for a vendor MIG simulation model. It is intended to expose
renderer stalls, queue pressure, row locality, refresh cost, and deadline risk
without making long audio tests depend on a vendor simulator.

## Boundary

The model uses the production ordered-line protocol:

```text
req_valid / req_ready / req_addr
rsp_valid / rsp_ready / rsp_data
```

`req_addr` is a 16-bit word address and must be aligned to `LINE_WORDS`.
Responses contain `LINE_WORDS` little-endian PCM16 words. Requests may be
scheduled across banks internally, but responses are presented in acceptance
order because the renderer response has no transaction tag. A stalled response
holds both `rsp_valid` and `rsp_data` stable.

## Modeled Timing

The SV model implements:

- configurable initialization delay and request queue capacity;
- MIG-compatible bank/row/column decoding with an open-page policy;
- row-hit-first read scheduling;
- activate, precharge, CAS/read and read-to-read spacing;
- x16 BL8 transfer occupancy: eight DQ beats on both CK edges occupy four DDR
  clocks, and a 128-bit line is published only after all beats arrive;
- `tRCD`, `tRP`, `tCL`, `tRAS`, `tRC`, `tCCD`, and `tRTP` constraints;
- rank-level `tRRD` spacing and the rolling four-ACT `tFAW` window;
- periodic refresh with `tREFI` and `tRFC` request blocking;
- multiple accepted requests and an ordered response reorder boundary;
- counters for requests, responses, per-request row hits/misses, physical
  activate/precharge commands, and refresh operations. A request reactivated
  after refresh remains one row miss while every ACT is counted separately.

The Smart Artix profile is derived from the checked-in MIG project for
`MT41K256M16XX-107`: the external MIG input is 200 MHz, memory `tCK` is 2.5 ns
(400 MHz CK / DDR3-800), the PHY ratio is 4:1, and `ui_clk` is 100 MHz. At the
400 MHz model clock the profile uses `tRCD=6`, `tRP=6`, `tCL=6`, `tRAS=14`,
`tRC=20`, `tCCD=4`, `tRTP=3`, `tRFC=104`, and `tREFI=3120`. Integer cycle
values round the MIG nanosecond constraints upward. The x16 device additionally
uses `tRRD=4` and `tFAW=20` at DDR3-800. Micron specifies the x16 part as eight
banks, 15 row bits, 10 column bits, and a 2 KiB page.

The Smart Artix board routes an MT41K256M16 x16 device. With BL8, one read
command transfers `16 bits * 8 beats = 128 bits`, exactly one renderer line.
Because DDR transfers on both clock edges, the burst occupies four 400 MHz CK
periods. The modeled peak payload bandwidth is therefore 1.6 GB/s. `T_CL`
marks the start of read data; the response line becomes eligible only after the
additional four-clock burst has completed. The current model intentionally
requires one physical burst per line rather than silently treating an x8 device
as x16.

Timing parameters are DDR-model clock cycles, not nanoseconds. The renderer runs
at the MIG 100 MHz UI rate, while the physical timing scheduler advances four
400 MHz CK cycles per renderer cycle. A simulation-only bounded bridge carries
ordered requests and responses between these clock domains. It represents the
controller boundary, not a board-level asynchronous CDC in the real design.
The checked-in MIG project selects `BANK_ROW_COLUMN`. After removing the three
within-BL8 word bits from the physical 10-bit column, address mapping is:

```text
line   = word_addr / LINE_WORDS
column = line[6:0]
row    = line[21:7]
bank   = line[24:22]
```

The generic parameters are `COLUMN_BITS=7`, `ROW_BITS=15`, `BANK_COUNT=8`, and
`BANK_ROW_COLUMN=1`. Clearing `BANK_ROW_COLUMN` retains a configurable
row-bank-column profile for other controllers. The mapping must follow the
board MIG configuration and any adapter-side address transform.

Refresh due times remain anchored to the initialization epoch. If an open bank
or data burst delays a refresh, the following due time is still advanced by one
`tREFI` from the previous due time, rather than from the delayed issue cycle.
This models refresh debt and preserves the required long-term average rate.

## Binary Images

The DPI-C backend is `sim/harness/memory/ddr3_bin_store.cpp`. Pass an image at
runtime:

```bash
+DDR3_IMAGE=/absolute/path/to/image.bin
+DDR3_IMAGE=/absolute/path/to/bin_directory
```

A single file starts at word address zero. A directory supports two exclusive
layouts:

- Addressed: every file is named `<hex_word_address>.bin`, for example
  `00000060.bin`. Gaps read as zero and overlapping ranges are rejected.
- Concatenated: files have non-hex names, are sorted lexicographically, and are
  concatenated from word address zero.

All files must contain an even byte count. Bytes are decoded as PCM16
little-endian words. Mixing addressed and concatenated filenames is rejected so
an accidental rename cannot silently change the memory map.

## Commands

Run the focused timing, data, refresh, and backpressure test:

```bash
make test-ddr3-model
```

Run the existing 256-lane renderer throughput assertions with DDR3 timing:

```bash
make measure-voice-major-throughput-ddr3
make measure-voice-major-throughput-ddr3 DDR3_IMAGE=/absolute/path/to/bin_directory
```

The integration reports the 100 MHz renderer cycles, while all DDR timing
counters advance at 400 MHz. The current shared-wave 256-lane trace completes
in 4532 core cycles, accepts and returns 1024 lines, records 1017 row hits and 7
row misses, and services 6 refreshes. The ideal-memory result remains a separate
test; the two measurements must not be compared without preserving their
clocks, timing parameters, and address trace.

## Renderer Window Boundary

The production renderer requests only lines containing required interpolation
endpoints. `rtl/memory/voice_sample_window.sv` retains one 32-word window per
voice, for 16 KiB of PCM data at 256 voices. Work and voice IDs exist only on
the internal renderer/window boundary; the external DDR boundary remains
ordered and untagged.

The first out-of-window request in a work refills four consecutive 8-word DDR
lines. Later out-of-window requests in the same work perform one-line fallback
reads without replacing the persistent window. This protects sequential
locality across blocks while avoiding a four-line refill for a loop-wrap
endpoint. The window handles one client transaction at a time, but all four
requests in a refill may be queued before their ordered responses return.

The render harness reports client requests, window hits, four-line refills,
fallback reads, external DDR reads, evictions, stall cycles, row behavior,
refreshes, and worst render deadline utilization. The output field names that
still begin with `cache_` are compatibility labels for these window counters;
MSHR merges are always zero. Cache-set and MSHR build parameters were removed
with the unused `ordered_line_cache` experiment. Current window performance and
the retained historical cache comparison are documented in
[`design/voice_major_render_pipeline_detailed.md`](../design/voice_major_render_pipeline_detailed.md).

## Primary References

- [AMD UG586, user-interface read buffer](https://docs.amd.com/r/en-US/ug586_7Series_MIS/user_design/rtl/ui?contentId=GJ80cJgh8U5JMmw9EWs~LQ):
  the UI read buffer reorders controller data back to request order.
- [AMD UG586, BL8 application/DRAM data mapping](https://docs.amd.com/r/en-US/ug586_7Series_MIS/Write-Path?contentId=O_cGzzSgL4oEC9hbz06eSQ):
  UI width is derived from physical width, controller clocks per DRAM clock,
  and double data rate.
- [AMD UG586, configurable memory address mapping](https://docs.amd.com/r/en-US/ug586_7Series_MIS/User-Interface):
  bank/row/column ordering is a controller configuration choice.
- [Micron 4Gb x4/x8/x16 DDR3L SDRAM](https://e2e.ti.com/cfs-file/__key/communityserver-discussions-components-files/791/MT41K256M16-MT41K512M8-MT41K1G4-_2800_4Gb-DDR3L-SDRAM_2900_.pdf):
  x16 geometry, `tRRD`, `tFAW`, refresh, and speed-bin timing constraints.
