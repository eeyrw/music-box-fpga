# Global Sample Cache Evaluation

This note records the completed global line-cache experiment. The experiment
was rejected and removed from the production source set; the renderer uses
`voice_sample_window` exclusively. The final RTL and focused testbench are
preserved in the
[`global_sample_cache_experiment`](../../archive/global_sample_cache_experiment/README.md)
archive for reproducibility.

## Implemented Policies

The archived `global_sample_line_cache.sv` has the same client and
ordered-memory ports as `voice_sample_window`. It provides:

- 32 KiB total sample data at the 512-voice default;
- two-way set association with LRU replacement;
- 512 two-way 32-word/64-byte macro-lines at the 512-voice default;
- four independently valid eight-word/16-byte sectors per macro-line;
- four adjacent response beats for refill misses and one requested sector for
  fallback misses;
- physical-address tags shared by every voice;
- one outstanding miss context and held ready/valid responses.

The first experiment used 2,048 eight-word lines and one backend read per miss.
It is retained below as `global-8` because it establishes why merely increasing
the number of globally shared tags is not useful. The second, `global-32`, used
512 macro-lines and unconditionally filled all four sectors. The final
`global-adaptive` implementation kept that geometry, but refill requests fetch
four sectors while fallback requests fetch only the requested sector. A later
miss to another sector of the same macro-line preserves the sectors already
present.

The former `SAMPLE_CACHE=global` build selection has been removed. The archive
README gives the standalone focused-test command; restoring it to production
would require an intentional new integration change.

## One-Second SGM Stress Test

The representative input was:

```text
SF2: SGM-v2.01-NicePianosGuitarsBass-V1.2.sf2
MIDI: build/polyphony_stress_512.mid
duration: 1 second at 48 kHz
control tick: 1 ms
regions selected: 907
peak active voices: 512
render blocks: 3039
```

The DDR3 and 100 MHz QSPI timing models used the same RTL, MIDI, SF2, and
48,000 output frames. The focused cache regression proves exact returned line
data and held-response behavior. A shorter 0.1-second DDR A/B render was also
byte-identical. The one-second WAV files are not byte-identical because the
different service times change long-running control-command admission at render
boundaries; the QSPI cases additionally miss nearly every render deadline.
These one-second runs are therefore performance/feasibility tests, not
bit-exact cross-timing output comparisons.

| DDR3 metric | Window | Global-8 | Global-32 | Global-adaptive |
| --- | ---: | ---: | ---: | ---: |
| Client requests | 6,280,984 | 6,280,984 | 6,280,984 | 6,280,984 |
| Cache/window hits | 4,231,467 | 3,101,704 | 4,610,422 | 3,655,938 |
| External 8-word beats | 3,864,271 | 3,179,280 | 6,682,248 | 5,661,013 |
| Evictions | 604,406 | 3,177,232 | 1,670,050 | 1,669,951 |
| Total render cycles | 85,158,385 | 85,632,647 | 84,906,671 | 86,328,408 |
| Maximum render cycles | 31,876 | 32,437 | 31,321 | 32,296 |
| Render deadline misses | 0 | 0 | 0 | 0 |
| DDR row hits | 2,458,666 | 1,408,890 | 5,410,730 | 3,938,207 |
| DDR row misses | 1,405,605 | 1,770,390 | 1,271,518 | 1,722,806 |

| QSPI metric | Window | Global-8 | Global-32 | Global-adaptive |
| --- | ---: | ---: | ---: | ---: |
| Client requests | 6,280,984 | 6,280,984 | 6,280,984 | 6,280,984 |
| Cache/window hits | 4,231,467 | 3,105,356 | 4,612,751 | 3,657,766 |
| External 8-word beats | 3,864,271 | 3,175,628 | 6,672,932 | 5,653,536 |
| Evictions | 604,406 | 3,173,580 | 1,667,721 | 1,667,696 |
| Total render cycles | 229,687,494 | 235,078,016 | 305,277,188 | 298,298,476 |
| Maximum render cycles | 95,551 | 100,769 | 123,126 | 121,184 |
| Render deadline misses | 3,036 | 3,036 | 3,037 | 3,037 |
| QSPI transactions | 2,049,517 | 3,175,628 | 1,668,233 | 2,623,218 |
| QSPI continuous beats | 1,814,754 | 0 | 5,004,699 | 3,030,318 |

## Interpretation

The global-8 cache reduced external line reads by about 17.7 percent, but its
unpartitioned working set evicted nearly every filled line. On DDR3 it also
destroyed row locality: row misses increased by about 26 percent, total render
cycles increased by about 0.56 percent, and the worst block reached 99.456
percent of its deadline. The lower read count did not improve real-time margin.

Global-32 raised the hit count and reduced DDR row misses by 9.5 percent versus
the window baseline. Total DDR render cycles improved by 0.30 percent and the
worst block by 1.74 percent. However, unconditional macro-line fills increased
external beat traffic by 72.9 percent. The small latency gain does not justify
that bandwidth increase by itself.

On QSPI, the persistent window's four adjacent refill lines retained some
continuous-read benefit. The global-8 cache issued every miss as a
new transaction. Command/address/mode/dummy overhead therefore outweighed its
lower line count: total cycles increased about 2.35 percent and maximum block
cycles increased about 5.46 percent. Both policies missed almost every block in
this full-polyphony workload, so neither establishes single-QSPI feasibility.

Global-32 proves that an eight-word response beat does not prevent continuous
QSPI reads. Every one of its 1,668,233 transactions carried one initial beat
and exactly three continuous beats. Transactions fell 18.6 percent versus the
window, but external beat traffic rose 72.7 percent; data transfer time then
dominated the saved command overhead. Total cycles increased 32.9 percent and
the worst block increased 28.9 percent versus the window policy.

Global-adaptive reduced transferred beats by 15.3 percent and total cycles by
2.3 percent relative to unconditional global-32 on QSPI. This confirms that
sector validity avoids some harmful overfetch. It did not recover the window
baseline: compared with the window it transferred 46.3 percent more beats,
opened 28.0 percent more QSPI transactions, and took 29.9 percent more total
cycles. On DDR3 it was also 1.4 percent slower than the window and lost most of
global-32's row-locality gain. Classifying the fill length only from the
renderer refill/fallback request is therefore not a sufficient adaptive policy.

## Why The Interface Uses Eight Words

The eight-word width comes from the Smart Artix DDR geometry, not from the
renderer. The board uses x16 DDR3 with BL8, and its generated MIG exposes a
128-bit `app_rd_data` port. One application beat is therefore eight 16-bit PCM
words. QSPI has no corresponding eight-word transaction limit; it reuses the
same response width and can stream multiple adjacent beats under one CS-low
transaction.

The present ordered request has only an address. It expresses a 32-word burst
implicitly by queueing four adjacent addresses. A future backend-neutral
contract should add a beat count to the request and a final-beat indication to
the response. It should retain the 128-bit data width rather than creating a
512-bit cross-module bus.

## FPGA Resource And Timing Results

A fresh 512-voice `xc7a50tfgg484-2` post-route implementation was run for each
global geometry. All use block RAM for the 128-bit data ways and physical-tag
ways. Valid and LRU arrays remain in distributed RAM.

| Metric | Window baseline | Global-8 | Global-32 | Global-adaptive |
| --- | ---: | ---: | ---: | ---: |
| Slice LUTs | 24,933 | 25,002 | 24,758 | 26,408 |
| Block RAM tiles | 46.5 | 48.5 | 47.5 | 47.5 |
| DSP48E1 | 39 | 39 | 39 | 39 |
| Post-route WNS | +0.165 ns | +0.014 ns | +0.133 ns | -0.312 ns |
| Post-route WHS | +0.025 ns | +0.021 ns | +0.036 ns | +0.058 ns |

Global-8 maps its 32 KiB sample data to eight `RAMB36E1` blocks and its two
19-bit-by-1024 tag ways to two more `RAMB36E1` blocks. Global-32 keeps the same
eight data blocks, but its two 19-bit-by-256 tag ways need only one `RAMB18E1`
each. Its two valid arrays and LRU array use 12 `RAM128X1D` primitives. The
macro-line design therefore saves one block-RAM tile and 244 LUTs versus
global-8. It fully routed with no routing or DRC errors and restored useful
timing margin. Resource cost is not the reason to reject it; unconditional
QSPI overfetch is.

Global-adaptive retained the eight data `RAMB36E1` blocks and two tag
`RAMB18E1` blocks. Its two 256-by-4 sector-valid arrays mapped to 32 `RAM64M`
primitives, so they consumed distributed RAM rather than another BRAM tile.
However, LUT use rose by 1,650 versus global-32 and by 1,475 versus the window.
The forced-fresh post-route run completed every one of 47,427 routable nets and
reported zero DRC errors, but failed setup timing with WNS -0.312 ns, TNS
-3.137 ns, and 17 failing endpoints. Its worst path was in the global compressor,
not in the cache hierarchy; this still means the complete adaptive build did
not pass the required implementation signoff.

The global policy can still help a small, highly shared sample working set; a
short MT6276 stress run showed that behavior. That result is not representative
of the SGM full-polyphony acceptance workload and does not override this test.

## Decision And Next Experiment

Keep the per-voice window as the only production policy. None of the three
global policies is a production replacement. Global-8 loses transaction
locality, unconditional global-32 overfetches, and global-adaptive still couples
a four-sector fill to a request classification that does not predict reuse well
enough. The adaptive build also failed post-route setup timing.

The next experiment should retain the window as L1 and evaluate a small shared,
eviction-fed victim L2. Insertion must consume no additional backend reads. An
L2 hit can then exploit cross-voice sharing without discarding the per-voice
sequential state that currently performs best. Separately, any future global
prefetch policy should use observed sequential accesses or a per-macro reuse
confidence counter, not the refill/fallback bit alone. The backend-neutral burst
contract can still add request beat count and response last while preserving the
128-bit response beat.

The experiment is closed. Its build switch, production instantiation, source
filelist entry, Vivado define, and default regression target were removed. The
archived RTL and testbench are evidence, not a supported alternative cache.
