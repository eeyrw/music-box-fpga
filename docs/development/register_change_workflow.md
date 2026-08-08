# Register Change Workflow

This guide is the practical checklist for adding, changing, or removing a
global register. It supplements, rather than replaces,
[`rtl_change_workflow.md`](rtl_change_workflow.md).

## 1. Define The Contract First

Edit `spec/register_map.json`, the source of truth for addresses, reset values,
field names, masks, and generated constants. Before editing RTL, decide:

- the owning block and whether the value is live, sampled, sticky, or counted;
- RO, WO, RW, W1C, pulse-on-write, or another explicit access rule;
- bit widths, units, signedness, saturation or wrap behavior, and reserved bits;
- reset and software-clear behavior, including same-cycle event priority;
- whether a multi-field read must be coherent and at which event it is sampled;
- whether changing or removing the register requires a `VERSION` increment.

Do not allocate an address by searching only the RTL. Check the complete JSON
map and keep related registers together without reusing a retired address in the
same interface version.

## 2. Regenerate Constants

Run:

```bash
make generate-register-map
```

Never hand-edit the generated consumers:

- `rtl/pkg/synth_register_pkg.sv`;
- `sim/harness/generated/register_map.h`;
- `mcu/generated/register_map.h`.

If `VERSION` changes, update every profile or host contract that intentionally
requires an exact version. In this repository that includes
`spec/mcu_asset_profiles.json`; regenerate it with:

```bash
make generate-mcu-asset-profile
```

## 3. Implement At The Owner

The module that owns the underlying state owns its update rule. Export a typed
value or a narrowly named event to the register block; do not reconstruct the
meaning from unrelated internal signals in the fabric.

For a new register:

1. Add the address to the owning decoder's recognized-address set.
2. Add read packing with explicit widths and zeros in reserved bits.
3. Add write side effects in sequential logic when applicable.
4. Route the request to that owner in `wavetable_register_fabric.sv`.
5. Thread new owner inputs or outputs through the smallest necessary hierarchy.

The fabric selects an owner; it must not duplicate counter, clear, or snapshot
state. Unknown addresses must still complete with `bus_error`. Reads during
`core_reset` remain available only where the existing reset-safe contract says
so.

For counters and maxima, define the event exactly. Prefer a one-cycle valid
pulse paired with the sampled value. Test saturation, monotonic maximum behavior,
and clear/event coincidence. A debug clear must reset only documented
diagnostics; it must not accidentally flush FIFOs, invalidate caches, stop
playback, or reset voices.

## 4. Update Every Consumer

Search by both the register name and numeric address:

```bash
rg -n 'REG_NAME|0xaddress' rtl fpga sim host tools docs spec
```

Update current contracts, host reads/writes, JSON or text diagnostics, dry-run
models, and testbench instances. When removing a register, delete its decode and
side-effect path as well as its generated definition. Historical archive
documents may retain the old name when they are clearly recording an old
interface.

## 5. Add Focused Tests

At minimum, a register-focused self-checking test covers:

- reset value and exact bit packing;
- legal read/write response and illegal-access `bus_error` behavior;
- reserved bits reading zero;
- the event or handshake that updates the value;
- saturation, wrap, maximum, sticky, or snapshot semantics as applicable;
- software clear, zero writes, and same-cycle clear/event priority;
- preservation of runtime state that the write must not affect.

Also run the focused test for the underlying owner. A register readback test
alone cannot prove that the counted event is the right event.

## 6. Verification Gates

Run the smallest relevant tests while iterating, then the project gates required
by the RTL workflow. A typical register change uses:

```bash
make check-register-map
make test-rtl-peripheral
make lint
make check-generated
make check-docs
```

Add core, memory, audio, or host tests when the owning state is in those paths.
Functional production RTL changes require a fresh routed Vivado implementation
as specified by `rtl_change_workflow.md`; cached synthesis is not signoff.

On hardware, first verify `VERSION`, then read reset values, create one known
event, confirm exact deltas, exercise clear behavior, and repeat under the real
SPI clock. Record the bitstream identity and distinguish live snapshots from
interval counters when interpreting results.
