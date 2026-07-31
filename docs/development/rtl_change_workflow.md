# RTL Change Workflow

This is the required path for changes to synthesizable RTL or a hardware-visible
contract. It defines completion gates; the detailed verification and Vivado
documents explain individual tools and reports.

## 1. Establish The Contract

Before editing, identify the owner in
[`../project_contracts.md`](../project_contracts.md) and the production path in
[`../design/rtl_module_map.md`](../design/rtl_module_map.md).

Write down the invariant the change must preserve or the contract it
intentionally changes. An interface, opcode, field, memory layout, rounding
rule, latency boundary, or ready/valid behavior change requires its contract
document to change in the same commit.

Do not edit generated files first:

- register definitions start in `spec/register_map.json`;
- DSP lookup tables start in `tools/gen_dsp_lut.py`;
- generic production sources are listed in `rtl/filelist.f`;
- board integration sources are listed in `fpga/smart_artix/filelist.f`.

## 2. Add A Focused Regression

Every behavior change needs a self-checking test that fails before the fix and
passes after it. The test must compare exact integers and exit nonzero on
failure. Cover reset and backpressure whenever the changed block owns state or a
ready/valid boundary.

Use the narrowest existing target first:

| Change area | Minimum focused coverage |
| --- | --- |
| Command decode, generation, state commit | `make test-rtl-core`, especially `tb_voice_major_render_core` and `tb_block_voice_state_store` |
| Fixed-point DSP, envelope, filter, effects | Owning block test under `make test-rtl-core` or `make test-rtl-peripheral`; include rounding and signed extremes |
| Sample window or ordered memory | `make test-sample-window` and `make test-ddr3-model` |
| SPI bridge or register fabric | `make test-rtl-peripheral`, especially `tb_spi_register_bridge` |
| FIFO, scheduler, I2S | Owning peripheral test with startup, stall, underrun, and exact bit timing cases |
| Renderer scheduling or throughput | `make test-voice-major-512` plus the applicable `measure-voice-major-throughput-512*` target |
| Board SD/DDR integration | `make smart-artix-test` and the directly affected Smart Artix testbench |
| C++ model or command packing paired with RTL | Matching C++ unit test and exact C++/RTL vectors |

A waveform is diagnostic evidence, not a pass criterion. Do not weaken an
expected value merely to match the changed RTL.

## 3. Run Functional Gates

Run from the repository root, in this order:

```bash
make check-register-map
make check-docs
# Run the focused target(s) selected above.
make lint
make test
git diff --check
```

Use `make generate-register-map` only after intentionally changing a generated
source. Re-run the check target afterward. Generated output under `build/` is
never committed.

For renderer, memory, or scheduling changes, also run a representative timed
DDR render or throughput target. A zero-wait unit test does not establish the
real-time budget. Record maximum render cycles, deadline misses, FIFO minimum,
and memory/window counters relevant to the change.

## 4. Decide The Vivado Gate

Simulation proves behavior; it does not prove RAM inference, utilization,
routing, or timing. Use this fixed rule:

| Changed files or behavior | Required Vivado gate |
| --- | --- |
| Documentation, host-only C++, simulation-only models/tests, or comments | None |
| Production RTL edit that is demonstrably logic-equivalent and does not alter widths, hierarchy, resets, attributes, or filelists | `make vivado-synth` when inference could still change; document why implementation was skipped |
| Any functional production RTL change in `rtl/`, `fpga/common/rtl/`, or the Smart Artix production filelist | Fresh post-route implementation |
| RAM/DSP inference, pipeline stages, state width, fanout, reset, clock/CDC, XDC, MIG, FPGA part, or synthesis strategy | Fresh post-route implementation and focused report inspection |
| Release bitstream or board qualification | Fresh implementation, bitstream, and the applicable hardware checklist |

For the required post-route gate run:

```bash
VIVADO_FORCE_REBUILD=1 make vivado-impl
make vivado-summary
make vivado-analyze
```

`make vivado-synth` is useful during iteration but is not timing signoff. Do not
reuse a stale run after RTL, constraints, parameters, IP configuration, or tool
strategy changes.

## 5. Accept Or Reject The Implementation

A production RTL change is not complete until the required implementation
meets all of these conditions:

- the intended RAM and DSP primitives appear under the expected hierarchy;
- utilization fits the target and is compared with the previous baseline;
- every routable net is routed and route errors are zero;
- setup and hold WNS are nonnegative, TNS/THS are zero, and failing endpoints
  are zero;
- DRC errors are zero;
- methodology, `check_timing`, unconstrained I/O, and CDC warnings are reviewed,
  not hidden by an internal positive WNS;
- the critical path owner and any material movement in LUT/FF/BRAM/DSP use are
  recorded.

The Smart Artix design has limited setup margin, so a small functional edit is
not exempt from post-route validation merely because `make lint` and
`make test` pass.

## 6. Completion Record

The change summary or commit message must state:

```text
Contract changed/preserved:
Focused regression:
make lint:
make test:
Timed render/throughput (when applicable):
Vivado gate and run freshness:
Post-route WNS/WHS, route, DRC, utilization (when applicable):
Open board or external-I/O qualification:
```

If a required gate cannot be run, report it as an explicit unresolved item. Do
not describe the change as complete or timing-clean based on an older build.
