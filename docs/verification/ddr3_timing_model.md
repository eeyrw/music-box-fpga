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
- row/bank/column decoding with an open-page policy;
- row-hit-first read scheduling;
- activate, precharge, CAS/read and read-to-read spacing;
- x16 BL8 transfer occupancy: eight DQ beats on both CK edges occupy four DDR
  clocks, and a 128-bit line is published only after all beats arrive;
- `tRCD`, `tRP`, `tCL`, `tRAS`, `tRC`, `tCCD`, and `tRTP` constraints;
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
values round the MIG nanosecond constraints upward.

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
Address mapping is:

```text
line   = word_addr / LINE_WORDS
column = line[COLUMN_BITS-1:0]
bank   = line[COLUMN_BITS +: log2(BANK_COUNT)]
row    = line >> (COLUMN_BITS + log2(BANK_COUNT))
```

This mapping is configurable because the final mapping depends on the board,
MIG configuration, and any cache/controller address transform.

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
in 2148 core cycles, accepts and returns 2 lines, and includes periodic refresh.
The retained cache and MSHRs merge the other voice requests. The
ideal-memory result remains a separate test; the two measurements must not be
compared without preserving their clocks, timing parameters, and address trace.

## Renderer Cache Boundary

The production renderer requests only lines containing required interpolation
endpoints. `rtl/memory/ordered_line_cache.sv` provides a 16 KiB two-way retained
cache and eight MSHRs. Work IDs are tags only on the internal renderer/cache
boundary; the external DDR boundary remains ordered and untagged. The real
render harness reports client requests, hits, MSHR merges, external misses,
evictions, miss-allocation stalls, row behavior, refreshes, and worst render
deadline utilization. It also reports render block/frame counts and total render
cycles, allowing pure renderer average cycles per block or frame to be computed
without including control writes and block readout. A miss-allocation stall is
one 100 MHz core cycle where a
presented request is neither a cache hit nor an existing-MSHR merge, but cannot
be accepted because no MSHR/issue slot is available or downstream request
`ready` is low. It does not include the latency after an accepted miss while its
DDR data is in flight.

The 2026-07-28 ten-second real trace using SGM v2.01 and `我的舞台.mid` from
10 seconds compared otherwise identical 2 KiB and 16 KiB caches. Both produced
bit-identical WAV output and 2,761,938 cache requests. Increasing the cache from
64 to 512 sets reduced external 128-bit reads from 1,387,110 to 1,141,075
(17.74%), evictions from 1,386,982 to 1,140,051, and miss-allocation stalls from
337 to 4 cycles. Renderer cycles fell from 21,162,164 to 20,851,713 (1.47%), and
the worst render block fell from 548 to 521 cycles with no deadline miss. The
16 KiB configuration is therefore the production default; the render Make
target retains `RENDER_RTL_CACHE_SET_COUNT` for reproducible size sweeps.

The comparison can be reproduced with identical audio windows by changing only
the cache set count and output directory:

```bash
make render-rtl-ddr3 SF2=/path/to/bank.sf2 MIDI=/path/to/song.mid \
  START_SECONDS=10 SECONDS=10 RENDER_RTL_CACHE_SET_COUNT=64 \
  RENDER_RTL_OUT_DIR=build/render_cache2k
make render-rtl-ddr3 SF2=/path/to/bank.sf2 MIDI=/path/to/song.mid \
  START_SECONDS=10 SECONDS=10 RENDER_RTL_CACHE_SET_COUNT=512 \
  RENDER_RTL_OUT_DIR=build/render_cache16k
```

Object directories include the cache and MSHR parameters, so separate size
sweeps cannot accidentally reuse a Verilated binary built for another size.

## Primary References

- [AMD UG586, user-interface read buffer](https://docs.amd.com/r/en-US/ug586_7Series_MIS/user_design/rtl/ui?contentId=GJ80cJgh8U5JMmw9EWs~LQ):
  the UI read buffer reorders controller data back to request order.
- [AMD UG586, BL8 application/DRAM data mapping](https://docs.amd.com/r/en-US/ug586_7Series_MIS/Write-Path?contentId=O_cGzzSgL4oEC9hbz06eSQ):
  UI width is derived from physical width, controller clocks per DRAM clock,
  and double data rate.
- [AMD UG586, configurable memory address mapping](https://docs.amd.com/r/en-US/ug586_7Series_MIS/User-Interface):
  bank/row/column ordering is a controller configuration choice.
