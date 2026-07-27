# Vivado Synthesis, RAM Inference, And Timing Closure

> Historical results (2026-07-27): measurements below apply to the deleted
> renderer and Smart Artix top. They are useful optimization case studies, but
> they do not sign off `voice_major_render_core`. The new eight-slot pipeline has
> not yet been synthesized or routed.

This note records the Smart Artix synthesis lessons that are specific enough to
be actionable in this repository. The target used for the measurements is
xc7a50tfgg484-2, with the generic core clocked by the MIG `ui_clk` at 100 MHz.
Vivado reports this generated clock as `clk_pll_i` in the current timing paths.

## Source-List Ownership

The synthesis flow has two ordered source lists:

- rtl/filelist.f is the single source of truth for generic synthesizable RTL.
  The root Makefile derives RTL_SOURCES from this file.
- fpga/smart_artix/filelist.f contains only common peripheral and Smart Artix
  integration RTL.

fpga/smart_artix/vivado/scripts/project.tcl reads the generic list first and the
board list second. A new generic module therefore belongs only in
rtl/filelist.f; a new board module belongs only in the Smart Artix list.

## Measurement Scope And Signoff

The Smart Artix implementation target uses a 100 MHz system clock, so an
internal register-to-register setup path has a nominal 10 ns period before clock
uncertainty and implementation effects. Timing is considered closed only after
routing, not after RTL elaboration or synthesis.

For every forced implementation, check all of these together:

- post-route setup WNS, TNS, and failing endpoints;
- post-route hold WHS, THS, and failing endpoints;
- routing completion and route errors;
- DRC errors and critical warnings;
- LUT, FF, DSP, and BRAM utilization.

A positive WNS alone is not signoff. Hold failures, unrouted nets, or an
over-utilized device make it meaningless. A post-synthesis negative slack is
useful for locating probable logic problems, but placement and routing can
change both the delay and the identity of the worst path.

The reports cover clocks and exceptions created by the current board project.
Some board-level input/output delay constraints remain roadmap work. This note
therefore establishes closure for the currently constrained internal design; it
does not claim closure for every future external I/O interface.

The current `check_timing` section reports zero unconstrained internal endpoints,
but also reports 9 input ports without input delay and 12 output ports without
output delay. Those I/O warnings must be resolved against external device and
board timing before claiming complete board-interface signoff.

### Current Methodology Warnings

The current post-route timing report carries these methodology results:

| Rule | Count | Meaning for this project |
| --- | ---: | --- |
| `LUTAR-1` | 1 warning | A LUT participates in an asynchronous-reset path; inspect reset safety and recovery/removal timing |
| `PDRC-190` | 12 warnings | Synchronizer registers are not placed optimally; identify each CDC chain before applying placement attributes |
| `SYNTH-6` | 39 warnings | Some RAM timing structures may be suboptimal; inspect output-register and surrounding mux paths, but do not infer that BRAM mapping failed from this warning alone |
| `XDCB-5` | 1 warning | A constraint query is runtime-inefficient; this affects Tcl execution, not circuit timing directly |
| `REQP-1959` | 16 advisories | SERDES reset-driver structure should be reviewed in the board/IP hierarchy |

The report itself says its methodology section may not be up to date. Rerun
`report_methodology` on the current routed design before assigning or waiving a
specific warning. Do not combine these counts with the 134 DRC warnings in the
JSON summary; they are different report sets.

Zero unconstrained internal endpoints is the important internal coverage result,
but it does not cancel the missing I/O delays. Likewise, positive setup/hold
slack does not waive reset, CDC, or RAM methodology warnings.

## Resource Failure Signature

The first effects-enabled synthesis had the following result:

| Resource | Failed inference | Timing-closed implementation |
| --- | ---: | ---: |
| LUT | 112,573 / 32,600 | 19,306 / 32,600 (59.22%) |
| FF | 215,876 / 65,200 | 20,750 / 65,200 (31.83%) |
| DSP48E1 | 48 / 120 | 47 / 120 (39.17%) |
| BRAM tiles | 17.5 / 75 | 39.5 / 75 (52.67%) |

The failed build used 195,126 more FFs than the current implementation. The
hierarchical report showed that chorus history and reverb pre-delay arrays were
the dominant owners; FDN history also became thousands of LUTRAM primitives.
This is the characteristic signature of memories that Vivado could not map to
block RAM: FF or LUT use grows roughly with depth times width, while BRAM use is
unexpectedly low.

The storage size gives a useful sanity check. A stereo history with 2048 entries
by 24 bits contains 98,304 bits. If its description prevents block-RAM
inference, that one logical buffer can consume roughly one hundred thousand FFs
before control logic is counted. This explains why the failed build exceeded
three times the device FF capacity.

Always inspect both reports:

    post_synth_utilization.rpt
    post_synth_utilization_hier_depth4.rpt

The flat report proves whether the device fits. The hierarchical report locates
the owning instance. Search the synthesis log for "implemented as a Block RAM"
and for messages explaining why a candidate was not mapped.

## RAM Coding Rules

Use one unpacked array per independently accessed channel. A packed stereo
structure as the array element may prevent the intended RAM decomposition.

    (* ram_style = "block" *) mix_t history_l [0:DEPTH-1];
    (* ram_style = "block" *) mix_t history_r [0:DEPTH-1];

    always_ff @(posedge clk) begin
      if (read_enable)
        read_data <= history_l[read_address];
      if (write_enable)
        history_l[write_address] <= write_data;
    end

The production pattern must also satisfy these rules:

- use a synchronous registered read;
- do not reset or clear every RAM element;
- track valid age or occupancy instead of initializing the physical array;
- expose no more read/write ports than the selected BRAM primitive supports;
- keep read and write behavior in a canonical, small always_ff block;
- treat ram_style as a hint, not proof that inference succeeded.

The repairs in this design were concrete rather than attribute-only:

- split chorus and pre-delay packed stereo histories into left/right memories;
- reorganize FDN storage into block-RAM-compatible physical memories;
- remove loops that reset every sample location;
- use age or validity state so unread history still contributes zero;
- register read data and represent synchronous RAM latency in the owning FSM.

`ram_style = "block"` cannot turn an illegal access pattern into a supported
BRAM. Whole-array reset, asynchronous reads, too many ports, mixed-width access,
or complicated packed-element updates can all defeat inference.

Large arrays under rtl/ still need deterministic simulation behavior. This
project uses validity tracking so unread or cleared locations contribute zero
without synthesizing a bulk memory reset.

After a memory edit, verify the inferred primitive report and compare the
utilization delta with the logical storage size. In this repair, a moderate BRAM
increase and a very large FF/LUT decrease was the expected result.

## Repeatable Timing Workflow

Do not treat every negative-slack path as the same problem. Timing closure here
was a sequence of forced implementations, each aimed at one repeated structural
cluster.

### 1. Run The Repository Flow From The Correct Directory

Use the existing Tcl entry point, including implementation. From
`build/fpga/smart_artix/vivado`:

```sh
VIVADO_FORCE_REBUILD=1 vivado -mode batch \
  -source ../../../../fpga/smart_artix/vivado/scripts/impl.tcl
```

`impl.tcl` runs or reuses the named synthesis and implementation runs, opens the
routed design, and writes:

- `reports/post_route_summary.json`;
- `reports/post_route_timing.rpt`;
- `reports/post_route_setup_paths.rpt` with 100 setup paths and up to 10 worst
  paths per endpoint;
- `reports/post_route_utilization.rpt`;
- `checkpoints/post_route.dcp`.

Use `synth.tcl` for resource-inference investigation, but do not call a design
timing-closed until `impl.tcl` finishes with a fully routed result.

### 2. Reject An Invalid Implementation Before Optimizing Timing

Check utilization, route status, DRC, and clock constraints before looking at a
critical path. Stop and repair feasibility when any of these is true:

- the design exceeds LUT, FF, DSP, or BRAM capacity;
- routable nets and fully routed nets differ;
- route errors or DRC errors are nonzero;
- a large inferred memory unexpectedly appears as FFs or distributed RAM;
- the expected system clock is missing or unconstrained paths exist.

Placement directives cannot repair a design that does not fit. A timing number
from an incomplete route is not comparable with a signed-off routed result.

### 3. Record The Complete Timing Shape

For every run, record more than WNS:

| Field | Question answered |
| --- | --- |
| WNS | How late is the single worst setup path? |
| TNS | How much aggregate setup debt remains? |
| Failing setup endpoints | Is this isolated or architectural? |
| WHS and THS | Did new stages create hold failures? |
| Startpoint and endpoint hierarchy | Which RTL boundary owns the cluster? |
| Logic levels | Is the dependency chain computationally deep? |
| Logic-delay/route-delay split | Is the main cost logic or physical distance/fanout? |
| Endpoint primitive | Does the path end at BRAM, DSP, or a slice register? |

WNS can get slightly worse while TNS improves because placement changes and the
next cluster becomes visible. Success for one iteration means the targeted
cluster disappears or shrinks substantially; it does not require every headline
number to improve monotonically.

### 4. Group The Top Paths

A single worst path is insufficient for architectural work. Group the top 100
paths by source hierarchy, destination hierarchy, and endpoint type. Ask:

- Do many paths launch from the same state, configuration, or FIFO register?
- Do they end at the same DSP input, BRAM address, BRAM write enable, or wide
  result register?
- Is one mathematical chain replicated across channels or voices?
- After the edit, did the entire old cluster disappear?
- Is the next path a new structure or only another placed copy of the old one?

Map generated endpoint names back to the owning RTL expression. Vivado may show
an internal pin or synthesized hierarchy name that is less intuitive than the
actual register-to-register dependency.

From the repository root, these commands provide a quick first pass:

```sh
python3 tools/vivado_report_summary.py show \
  build/fpga/smart_artix/vivado/reports/post_route_summary.json

rg "^  (Source|Destination):|Data Path Delay:|Logic Levels:" \
  build/fpga/smart_artix/vivado/reports/post_route_setup_paths.rpt

rg "unconstrained_internal_endpoints|no_input_delay|no_output_delay" \
  build/fpga/smart_artix/vivado/reports/post_route_timing.rpt

rg "Synth Design complete \\| Checksum" \
  build/fpga/smart_artix/vivado/smart_artix.runs/synth_smart_artix_top/runme.log
```

The summary script is useful for pass/fail and utilization. The expanded path
report is still required to see cell types, fanout, individual net delays, hard
block pins, and the logic/route percentage. For the current worst path, logic is
2.314 ns (25.04%) and routing is 6.927 ns (74.96%); that is why future work on
this path should consider a local registered DEFINE write command rather than
only simplifying one comparison.

### 5. Classify The Path Before Editing RTL

| Report signature | Likely cause | First response |
| --- | --- | --- |
| Many logic levels, logic-delay dominated | Too much arithmetic/decode in one cycle | Register between dependent operations |
| Few levels, route-delay dominated | Fanout or distant hard blocks | Create a local registered handoff; reduce fanout |
| BRAM address or WE endpoint | Decode/validation reaches memory directly | Latch the transaction, then form address/WE |
| BRAM/DSP to another hard block | Cascaded macro operations | Register the intermediate result |
| Priority encoder plus LUT address | Normalize and index in one cycle | Split magnitude, exponent, index, lookup, use |
| Reset reaches every array element | RAM inference and reset fanout problem | Replace clearing with validity/age state |
| Valid data can change while stalled | Incorrect streaming pipeline | Add elastic storage and hold data until ready |

In this implementation, paths with about a dozen or more meaningful logic
levels usually needed an RTL arithmetic boundary. Route fractions around 60 to
80 percent with modest logic depth often indicated a hard-block boundary,
fanout, or missing local handoff. These observations are guidance, not universal
thresholds; inspect the cells in the actual path.

## Verified Closure Progression

The old version of this table mixed final `report_timing` values with route-log
estimates and assigned some clusters to the wrong row. The table below uses the
final routed estimate printed by each named implementation log, so its rows are
directly reproducible from the files currently under `build/`. These logs are
generated artifacts, not repository history or signoff artifacts.

| Saved implementation log | WNS | TNS | What changed or remained |
| --- | ---: | ---: | --- |
| `impl_control_snapshot_pipe.log` | -1.590 ns | -131.863 ns | Snapshot/control conversion was staged; failures were still broad |
| `impl_action_read_pipe.log` | -1.082 ns | -125.749 ns | Prepared/active memory reads were registered |
| `impl_effect_pipeline.log` | -0.243 ns | -4.572 ns | Mixer elastic stage and effect arithmetic staging removed most debt |
| `impl_config_pipeline_final.log` | -0.528 ns | -18.557 ns | Registering pending chorus config did not split the clamp chain |
| `impl_config_split_final.log` | -0.268 ns | -7.762 ns | `PREP_BASE`/`PREP_CONFIG` split removed that clamp chain |
| `impl_route_control_pipeline.log` | -0.058 ns | -0.058 ns | Mixer-to-reverb handoff and DEFINE transaction staging left one small failure |
| `impl_timing_signoff.log` | -0.061 ns | -0.191 ns | Compressor magnitude/index split exposed executor release conversion |
| `impl_envelope_pipeline_signoff.log` | +0.236 ns | 0 ns | Release conversion split; route estimate closed |

The current signoff report was regenerated after that saved log and is the
authoritative present-state result: WNS `+0.226 ns`, TNS `0 ns`, WHS
`+0.036 ns`, THS `0 ns`, and zero setup/hold failing endpoints. Its worst setup path is
still a real near-critical path: `control_action_executor` current-action opcode
to prepared-RAM write enable, with a 9.241 ns data-path delay and 12 logic levels.
It is passing, not absent. This path should be watched when DEFINE decode changes.

The current top 100 report contains only two source clusters, but both have
little margin:

| Source cluster | Slack range in top 100 | Current physical signature | Next action if margin is needed |
| --- | ---: | --- | --- |
| Executor action opcode to prepared-RAM WE | +0.226 to +0.290 ns | 12 levels; about 75% route delay; RAMB36E1 endpoint | Register validated DEFINE/write command immediately beside the RAM |
| Compressor gain mantissa to sample-scale DSP | +0.263 to +0.333 ns | 11 levels; two DSPs visible in the path; about 58% logic delay | Make the coefficient boundary survive synthesis or reformulate to avoid the cascade |

Thus the design meets 100 MHz but has only about 0.23 ns worst-case setup
headroom in this implementation. Any meaningful change to DEFINE validation or
compressor gain conversion requires another forced route, even if simulation and
post-synthesis timing remain clean.

The earliest effects-enabled measurement (`-10.770 ns` WNS and grossly excessive
FF/LUT use) is retained only as the resource-failure baseline above. It is not in
the verified progression table because there is no matching named routed log in
the current build tree.

## RTL Optimization Cases

### Chorus: Put Registers Inside The Dependency Chain

The chorus combines configuration clamping, LFO lookup, modulation scaling,
history addressing, four memory reads, interpolation, feedback, and saturation.
The current state sequence makes each expensive boundary visible:

```text
IDLE
  -> PREP_BASE
  -> PREP_CONFIG
  -> CALC_LFO
  -> CALC_DELAY
  -> PREPARE_READ
  -> READ_L0 -> READ_L1 -> READ_R0 -> READ_R1
  -> INTERPOLATE
  -> INTERPOLATE_SUM
  -> CALCULATE
  -> COMMIT -> HOLD
```

`PREP_BASE` clamps base delay, input send, and feedback and registers those
values. `PREP_CONFIG` calculates depth after the registered base-delay result is
available. This distinction matters. The unsuccessful
`impl_config_pipeline_final.log` version registered the incoming configuration
but still evaluated base clamp, available headroom, depth clamp, and modulation
preparation after one boundary. It added a state without cutting the long
expression. Moving the boundary between base clamp and dependent depth clamp is
what removed that path cluster.

`CALC_LFO` registers the sine results before `CALC_DELAY` performs the modulation
calculation. `INTERPOLATE` registers interpolation products, and
`INTERPOLATE_SUM` performs the following add/scale step. This avoids a lookup,
multiply, wide add, and saturation chain in one cycle.

The four read states are not cosmetic latency. `history_l` and `history_r` are
synchronous block-RAM-compatible arrays, and the FSM owns their read latency.
`history_age` ensures that unwritten locations read as logical silence without
resetting the physical memories.

General method: write the expression as a dependency graph. A new state helps
only when an intermediate needed by the rest of the expression is assigned to a
register in that state and the next state consumes that registered value.

### Reverb: Serialize RAM And Recursive DSP Work

The reverb uses separate left/right pre-delay memories and block-RAM-compatible
FDN storage. `PRE_DELAY_CAPTURE` absorbs the synchronous pre-delay read, while
`READ_LINES` plus `READ_LINES_DRAIN` serialize and drain the FDN read pipeline.
Age counters and `valid_line_mask` replace physical memory clearing.

The feedback path is divided as follows:

```text
PREP_DAMP -> SCALE_DAMP -> DAMP_LINES -> TRANSFORM
          -> PREP_WRITE -> SCALE_FEEDBACK
          -> CALCULATE_WRITE -> WRITE_LINES
```

For each line, `PREP_DAMP` registers the damping product and `SCALE_DAMP`
registers its scaled form before the damping-state update. The Hadamard transform
is registered in `TRANSFORM`. Feedback multiplication, feedback scaling, final
write-value calculation, and BRAM write occur in distinct states.

This is more than arbitrary multi-level decomposition: one input frame remains
owned by the FSM until all eight FDN line transactions complete, so the recursive
state corresponds to the same audio sample. When pipelining feedback algorithms,
verify sample identity as well as arithmetic identity.

### Effect Return Mixer: Use An Elastic Stage

The return mixer has two independently timed operations:

- dry and chorus route gains feeding the reverb input;
- dry, chorus return, and reverb return feeding the final effect mix.

On `reverb_input_commit_i`, the four route products are captured in
`reverb_dry_scaled_*_q` and `chorus_route_scaled_*_q`. The following combinational
step adds and saturates the registered products. Because that handoff became one
cycle later, `global_effects_chain` added `WAIT_REVERB_INPUT`; otherwise reverb
would have sampled the preceding frame's route value.

The final return mix is captured in `effect_mix_wide_*_q` before output
saturation. It is an elastic ready/valid stage, not an unconditional delay:

```text
output_slot_ready = !out_valid || out_ready
in_ready          = !effect_stage_valid || output_slot_ready
```

When downstream is stalled, `out_valid` and output data stay stable. A new input
is accepted only when the internal effect slot can retain it. This is the safe
pattern when a timing boundary is inserted on a backpressured stream.

Every cross-module register addition requires two audits: confirm the producer
holds data correctly, and confirm the consumer samples the new cycle. Local RTL
simulation of only one side is not enough.

### Compressor: Separate Normalize, Lookup, And Scaling

The compressor detector-to-gain path is now explicit:

```text
DETECT -> DETECT_INDEX -> CALC_LEVEL -> CALC_TARGET -> CALC_GAIN
       -> CALC_GAIN_OCTAVE -> CALC_GAIN_INDEX -> LOOKUP_GAIN
       -> PREP_SCALE -> SCALE -> COMMIT -> HOLD
```

Magnitude/exponent calculation and mantissa-index calculation are in different
states. This fixed the late path from peak magnitude through normalization logic
to the mantissa LUT address. The gain-reduction conversion likewise separates
octave selection, mantissa index, LUT consumption, and sample scaling.

At RTL level, `PREP_SCALE` assigns `combined_gain_q`, which combines compressor
gain and master volume, and `SCALE` consumes it on the following state. However,
the current routed report still shows a path from `gain_mantissa_q`, through the
combined-gain DSP, to the sample-scale DSP input. Vivado legally optimized the
state-separated expression into a visible DSP cascade because the upstream data
remains stable across those states. Therefore the old claim that this RTL state
split removed the cascade was incorrect.

The cascade currently passes with +0.263 ns or more slack. If more margin is
needed, verify the synthesized cells after each of these options:

- make the coefficient a true transaction-stage output whose valid/data storage
  is consumed independently by the sample-scaling stage;
- precompute and store the compressor coefficient before master-volume scaling,
  so each multiplier has an unavoidable registered consumer/producer boundary;
- reformulate the fixed-point calculation to use one multiplier only if exact
  rounding and saturation tests prove equivalence;
- use synthesis-preservation attributes only as a last resort, after confirming
  that the preserved register improves route timing rather than blocking useful
  optimization.

The full-scale master-volume bypass remains explicit in the RTL, and exact
fixed-point tests guard the intended rounding and saturation behavior.

For paths ending at a BRAM/ROM address, split address generation earlier than
you might for an ordinary slice register. Priority encode, normalization, and
fixed hard-block placement consume much of the cycle even when the source
transaction rate is low.

### Action Executor: Low-Rate Logic Still Runs At 100 MHz

An action that arrives once per audio frame still has a 10 ns
register-to-register requirement. Transaction frequency does not create a
multicycle path.

The current executor latches DEFINE actions in `EXEC_IDLE`, then performs DEFINE
validation and prepared-RAM update in `EXEC_DEFINE`. Other voice actions pass
through synchronous memory read/capture before they are applied. Prepared and
active records are consumed from `prepared_action_data_q` and
`active_action_data_q`, rather than extending decode directly from RAM outputs.

Release conversion is deliberately split:

```text
EXEC_READ
  -> EXEC_RELEASE_INDEX
  -> EXEC_RELEASE_VALUE
  -> EXEC_APPLY
  -> EXEC_COMMIT
```

`EXEC_RELEASE_INDEX` registers leading-zero and mantissa-index information.
`EXEC_RELEASE_VALUE` registers the LUT/offset-derived attenuation.
`EXEC_APPLY` builds the active update, and `EXEC_COMMIT` reports completion after
the registered RAM write has been launched. This was the final structural change
that moved setup slack positive.

The present worst passing setup path still ends at prepared RAM write enable.
Therefore future DEFINE opcode/validation changes should be implemented as a
registered decode or precomputed write command if they consume the remaining
0.226 ns margin; adding logic directly to `prepared_write` is high risk.

The extra cycles are legal because the action interface is transactional and
already exposes completion. They must not change shadow/active atomicity, action
sequence checks, or the meaning of commit.

### Snapshot Conversion

The executor snapshot path also demonstrates correct lookup staging. Active RAM
data is first captured, attenuation-to-Q15 conversion then advances through
octave selection, residual/mantissa-index generation, LUT consumption, and final
scale. The valid bit and all associated voice/configuration fields advance with
the data. Pipelining only the numeric value without its transaction metadata
would mix voices or frames even if timing improved.

### Diagnostics Must Not Extend Functional Paths

Saturation detection and a 32-bit saturating diagnostic counter should not share
the audio result's critical cycle. The mixer records pending events and updates
the diagnostic counter from registered stage values. Diagnostic visibility may
move by one clock, but audio valid/data and memory enables do not depend on the
counter arithmetic.

Use this rule for future instrumentation: consume registered state or a
registered event pulse. Never insert diagnostic compare/select logic into a
functional ready, result, address, or write-enable cone.

### Routing And Fanout

When logic depth is small but route delay dominates, inspect whether a state,
enable, or wide mux crosses between distant DSP/BRAM regions. A local handoff
register can improve placement locality and reduce fanout at the same time.

Only after the RTL dependency is already short should implementation techniques
such as register duplication, `phys_opt_design`, hierarchy-aware placement, or a
carefully justified Pblock be considered. They cannot compensate for a deep
arithmetic chain or illegal RAM inference, and premature floorplanning can make
the next cluster harder to place.

### Multicycle Constraints

No multicycle exception was needed for this closure. A multicycle constraint is
valid only when launch/capture enables prove that the destination cannot sample
on intervening edges, and the matching hold adjustment is applied. An FSM taking
several clocks overall or an action arriving infrequently is not sufficient
proof. Prefer an explicit transaction register unless that proof is documented
and verified.

## Alternatives To Adding More Pipeline States

Pipelining was necessary for several arithmetic cones, but it is not the only
timing tool and is not always the first one to use.

### Fix The Physical Storage Architecture

Correct BRAM inference removed more resource and placement pressure than any
small arithmetic optimization. Separate memories by real port/channel, use
synchronous reads, remove bulk reset, and serialize accesses when the physical
primitive does not support the apparent RTL port count. This simultaneously
reduces FF/LUT use, reset fanout, congestion, and long routes.

### Serialize Work Within The Audio-Frame Budget

The audio sample rate is much lower than 100 MHz, so chorus reads and eight FDN
line operations can be serialized while still meeting the frame deadline. This
reuses arithmetic and RAM ports and gives the placer fewer parallel long cones.
The constraint is functional throughput: compute the worst-case cycles per
frame, include backpressure, and verify it remains below the available clock
cycles at the highest supported sample rate.

Serialization is different from declaring a multicycle path. The FSM performs
real registered transactions on each clock; static timing still checks every
individual cycle at 10 ns.

### Reduce Width Before Expensive Operations

Carry chains, comparators, multipliers, and routing all scale with width. Apply
the documented fixed-point range as early as numerically legal:

- sign-extend once at a clear boundary rather than repeatedly through muxes;
- clamp configuration fields before wide multiplication;
- keep addresses and loop counters at physical depth width;
- discard fractional bits only at the documented rounding point;
- avoid converting a narrow control value to a wide type before decode.

Width reduction must be justified from `docs/fixed_point.md` and exact extreme
tests. Truncating an intermediate simply to improve timing is not acceptable.

### Change Lookup Organization

Priority encoding, normalization, and a distributed LUT can be slower than a
synchronous ROM, while a ROM can consume additional BRAM and add one cycle.
Choose based on the current resource balance and endpoint path:

- register exponent and mantissa index separately when address generation is the
  problem;
- use a synchronous ROM when BRAM is available and distributed decode dominates;
- use symmetry or a smaller table only when the reconstruction arithmetic is
  cheaper than the saved memory and still closes timing.

The current design has 52.67% BRAM use, so an extra lookup BRAM is possible in
principle, but it must be evaluated against placement near existing DSP/BRAM
clusters rather than from capacity alone.

### Eliminate Or Reorder Expensive Arithmetic

Combining coefficients, replacing a divide with a lookup/shift, sharing a
serialized multiplier, or precomputing configuration-dependent values can
remove logic instead of merely spreading it over cycles. Fixed-point operation
order matters: `(sample * gain_a) * gain_b` is not automatically bit-exact with
`sample * (gain_a * gain_b)` after intermediate shifts and rounding.

Use an independent exact-integer test for zero, unity, maximum positive, maximum
negative, saturation, and values around every rounding boundary before accepting
such a reformulation.

### Reduce Fanout And Improve Locality

For a route-dominated path, duplicate or locally register control signals near
their consumers, split a wide global mux into registered module handoffs, or
bank a memory so its decode and writer are physically local. The current DEFINE
path is the main candidate: about 75% of its 9.241 ns data delay is routing to a
RAM write-enable pin.

Do not duplicate an entire wide transaction by default. Register the smallest
stable command/data bundle that defines the local operation, then let the local
block generate its short enable.

### Use Tool Optimization After RTL Structure Is Sound

Vivado retiming, register duplication, `phys_opt_design`, alternative placement
directives, and focused floorplanning can recover route margin. Use them only
after checking that:

- the design fits and memories infer correctly;
- the critical cone has reasonable logic depth;
- the intended RTL register boundary survived synthesis;
- the path is repeatably route/fanout dominated across forced runs.

Compare multiple implementation seeds or directives with the same synthesized
checkpoint when evaluating a physical-only change. Do not attribute a placement
win to RTL if both changed at once. Preserve a directive only when it improves
WNS/TNS without creating hold, congestion, or another worse cluster.

### Use Constraints Only To Describe Real Timing

Clock definitions, generated-clock relationships, false paths, and I/O delays
must describe hardware behavior. They are not optimization knobs. A false or
multicycle path can make the report green while leaving the circuit incorrect.
The outstanding 9 input and 12 output delay warnings require board/peripheral
timing information, not guessed values chosen to pass timing.

## Preserving Function While Pipelining

Timing edits must preserve these contracts:

- **Widths and signedness:** register the explicitly extended value, not a
  narrower convenient temporary.
- **Rounding and saturation:** keep the shift, rounding addition, comparison, and
  saturation in the documented order. Fixed-point algebra is not freely
  reassociative.
- **Transaction identity:** pipeline valid plus every sample, configuration,
  voice, and sequence field needed later.
- **Backpressure:** hold valid data stable until ready; never overwrite a full
  stage.
- **Synchronous RAM latency:** add capture/drain states instead of recreating an
  asynchronous shadow read.
- **Reset semantics:** when physical RAM is not cleared, gate all reads with
  validity, occupancy, or age state.
- **Commit atomicity:** internal latency must not expose a partly updated active
  configuration.
- **Tests:** wait for protocol completion with bounded timeouts when fixed latency
  is not an interface contract, while still checking exact integer results.

Run focused self-checking tests after each structural edit. Then run the full
suite to catch cross-module cycle alignment, especially around the mixer/reverb
handoff and control snapshot pipeline.

## Changes That Do Not Fix The Root Cause

- Registering only the input of a large expression while all dependent work
  remains after that register. The first chorus config attempt proved this.
- Adding `ram_style` without fixing reset, read latency, or port structure.
- Watching only WNS and ignoring TNS, endpoint count, and cluster identity.
- Treating low transaction rate as an implicit multicycle exception.
- Adding a streaming register without storage for downstream backpressure.
- Reassociating fixed-point operations without rechecking exact rounding.
- Starting with Pblocks or aggressive directives while RTL logic depth is high.
- Trusting a reused checkpoint without checking freshness.
- Stopping at post-synthesis timing instead of post-route setup and hold.

## Run Freshness

Vivado can reuse a completed run even after an external edit if the project does
not mark the run stale. Confirm that a meaningful RTL edit changes the synthesis
checksum or utilization. For timing work, force the complete implementation,
not only synthesis:

```sh
VIVADO_FORCE_REBUILD=1 vivado -mode batch \
  -source ../../../../fpga/smart_artix/vivado/scripts/impl.tcl
```

Do not accept an implementation result when the expected FF/LUT change or
`Synth Design complete | Checksum` change is absent. Also confirm report
timestamps, routed-design state, and the startpoint/endpoint hierarchy. A stable
checksum can be correct for a documentation-only or optimization-equivalent
change, but it is suspicious after an intended RTL structural change.

## Timing Closure Decision Procedure

1. Force a fresh implementation through `impl.tcl`.
2. Reject the result if capacity, routing, DRC, clocking, or internal constraint
   coverage is invalid.
3. Confirm RAM/DSP inference and compare resource use with expected storage and
   arithmetic sizes.
4. Record setup, hold, endpoint counts, and the repeated top-path clusters.
5. Map the dominant cluster to an RTL dependency chain.
6. Classify it as memory coding, logic depth, hard-block boundary,
   routing/fanout, or protocol alignment.
7. Insert the smallest meaningful registered boundary, including valid/data
   storage or FSM wait states required by the interface.
8. Run the focused self-checking test, `make lint`, and `make test`.
9. Force implementation again and verify that the targeted cluster disappeared,
   not merely that one generated path name changed.
10. Repeat until setup and hold are both clean, then retain the summary and top
    paths as the comparison baseline for the next feature.

## When Full Implementation Is Mandatory

With only +0.226 ns worst setup slack, synthesis-only checks are insufficient for
changes that can affect placement or either residual critical cluster. Force a
new `impl.tcl` run after any of the following:

- changing `rtl/filelist.f`, the board file list, top hierarchy, or source order;
- changing RAM depth, width, packing, ports, reset behavior, or read/write
  sequencing;
- changing DEFINE validation, action payload packing, prepared/active RAM data,
  or executor state decode;
- changing compressor lookup tables, gain widths, master-volume behavior, or
  multiply/round/saturate ordering;
- changing chorus, reverb, mixer, or compressor latency and ready/valid behavior;
- changing clock generation, MIG configuration, XDC constraints, FPGA part,
  Vivado version, synthesis strategy, placement directive, or route directive;
- adding enough logic or replicated voices/effects to move utilization or
  congestion materially, even outside the current top hierarchy.

A small unrelated RTL edit can still perturb placement and consume 0.226 ns, so
the list is intentionally broad. `make lint` and `make test` establish functional
and RTL-quality confidence; they cannot substitute for routed timing.

For release confidence beyond a single implementation, preserve the synthesized
checkpoint and compare more than one placement/route seed or strategy. Use the
same RTL, constraints, tool version, and checkpoint for that experiment. A path
that only passes with one favorable placement should be treated as a margin risk,
not as evidence that the architectural cone is robust.

## Closure Checklist

1. Run `make lint`, the focused self-checking RTL test, and `make test`.
2. Run the project `synth.tcl`/`impl.tcl` flow, not an ad hoc source command.
3. Confirm inferred RAM primitive ownership in the hierarchy report.
4. Confirm run freshness after RTL edits.
5. Inspect the worst setup paths by source, destination, logic levels, and route
   percentage.
6. Run `impl.tcl`; post-synthesis estimates are not timing closure.
7. Require a fully routed design, zero route errors, zero DRC errors, nonnegative
   setup and hold slack, and zero failing setup/hold endpoints.
8. Review methodology warnings and `check_timing`, including board I/O delay
   coverage; do not hide these behind internal closure.
9. Record final utilization, timing, checksum, and critical-path identity beside
   the board flow.

The signed-off Smart Artix implementation used synthesis checksum `d17fba4` and
closed the constrained MIG `ui_clk` (`clk_pll_i`) domain at 100 MHz with WNS
`+0.226 ns`, TNS `0 ns`, WHS `+0.036 ns`, THS `0 ns`, zero setup/hold failing
endpoints, all 39,892 nets routed, and zero DRC errors. Utilization is 19,306 LUTs
(59.22%), 20,750 registers (31.83%), 47 DSPs (39.17%), and 39.5 BRAM tiles
(52.67%). The JSON summary also records 134 DRC warnings. Separately, the timing
report flags the incomplete board I/O delay coverage described above; internal
timing closure is not a waiver for either warning set.
