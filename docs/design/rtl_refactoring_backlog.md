# RTL Refactoring Backlog

This document records structural cleanup that should improve RTL ownership and
readability without changing the synthesizer's external contracts, numeric
behavior, or cycle-level handshakes. Each item should be implemented as a small,
independently reviewable change rather than as one repository-wide rewrite.

## Invariants

- Preserve the public ports of the generic render tops and board wrappers unless
  a separate interface change is explicitly approved and documented.
- Preserve command formats, register behavior, memory ordering, ready/valid
  semantics, renderer frame boundaries, and fixed-point results.
- Keep ready/valid control signals explicit. Bundle only the payload that moves
  under that handshake.
- Do not convert physical phase, filter, cache, chorus, reverb, or pre-delay
  memories into arrays of packed stereo or state structures. Keep independently
  accessed channels in separate unpacked arrays so RAM decomposition, write
  enables, and inference remain visible.
- Do not add combinational decode or validation to the prepared/active RAM write
  path. The routed Smart Artix build currently has little setup margin on the
  executor-to-prepared-RAM write-enable path.
- Preserve synchronous RAM and lookup-table latency explicitly. Valid bits and
  transaction metadata must advance with their corresponding data.

## P0: Executor Ownership

- [ ] Extract the attenuation-to-Q1.15 conversion stages from
  `control_action_executor` into a focused streaming module such as
  `envelope_gain_converter`.
- [ ] Define a narrow conversion request payload for zero, direct-gain, and
  centibel conversion modes; keep conversion `valid` control explicit.
- [ ] Keep voice metadata, active-RAM writeback, action sequencing, and renderer
  snapshot ownership in the executor while the converter owns only numeric
  conversion and its fixed pipeline latency.
- [ ] Add a focused self-checking converter test covering zero, unity, direct
  attack values, LUT boundaries, representative attenuation values, rounding,
  and maximum attenuation.
- [ ] Confirm the existing transactional-control tests still cover envelope
  advancement, release, stale sequences, runtime updates, and snapshot timing.
- [ ] Re-run forced Smart Artix implementation after the extraction and compare
  WNS/TNS, LUT/FF/DSP/BRAM use, and the executor-to-prepared-RAM path against the
  recorded timing baseline.

## P0: Renderer Working Context

- [ ] Add an internal packed `voice_render_work_t`-style record in
  `multi_voice_pipeline` for one snapshotted voice's configuration, runtime
  controls, phase, filter state, validity, and activation state.
- [ ] Replace the duplicated `cfg_*` aliases and `current_*` scalar register bank
  with named fields in the working record.
- [ ] Form the complete working record at `START_VOICE` without changing the
  synchronous control/phase/filter read latency or prefetch cancellation rules.
- [ ] Keep the physical phase and filter-state arrays separate and assemble only
  their registered read results into the working record.
- [ ] Verify exact mono/stereo output, loop boundaries, fractional phase,
  activation reload, runtime updates without phase reload, silent Delay, filter
  history, multi-voice drain, and memory backpressure behavior.

## P1: Typed Voice-Layer Boundaries

- [ ] Define narrow `voice_phase_request_t` and `voice_phase_result_t` payloads
  for the `multi_voice_pipeline` to `voice_phase_frame` boundary.
- [ ] Define a `voice_endpoint_issue_t` payload containing stereo mode, base
  addresses, four endpoint frame indices, and the partial DSP context passed to
  `voice_endpoint_fetch`.
- [ ] Place cross-module voice-only payloads in a small package with an explicit
  dependency on `synth_pkg`; do not add unrelated audio, control, or board types.
- [ ] Keep issue/context/memory valid and ready controls separate from the new
  payload structures.
- [ ] Update focused phase and full render tests without weakening their exact
  integer comparisons or timeout checks.

## P1: Debug Snapshot Isolation

- [ ] Extract the 24-word voice debug capture FSM, serialization function,
  snapshot storage, and status metadata from `synth_control_plane` into a
  `voice_debug_snapshot` module.
- [ ] Leave register-address decoding and arbitration with renderer/action access
  in `synth_control_plane` unless a narrower ownership boundary is demonstrated.
- [ ] Preserve capture coherency, busy behavior, distributed-RAM storage, word
  order, and all documented register values.
- [ ] Extend the focused control/render tests to cover capture while control or
  rendering is busy and stability of a completed snapshot until the next
  capture.

## P2: Cache State Cleanup

- [ ] Group the scalar demand-miss state in `voice_line_cache` into a local
  pending-request record.
- [ ] Group queued/inflight prefetch metadata into a local prefetch record while
  keeping state bits explicit where simultaneous demand and response handling
  requires independent updates.
- [ ] Do not combine cache valid, tag, prefetched, replacement, and line-data
  arrays into one packed cache-line memory without fresh synthesis evidence.
- [ ] Preserve demand priority, same-cycle prefetch completion, ordered response
  timing, replacement behavior, diagnostic pulses, and reset invalidation.

## Deferred Or Rejected Broad Cleanup

- Do not bundle every stereo left/right port solely to reduce port count. Use the
  existing `stereo_pcm_t` and `stereo_mix_t` only where a complete stereo sample
  is the actual payload crossing a stable internal boundary.
- Do not introduce a SystemVerilog interface for a handshake used by only one
  producer and consumer.
- Do not split `multi_voice_pipeline` scanning and prefetch into separate modules
  until their shared synchronous-read and cancellation protocol has a simpler
  explicit contract.
- Do not split `voice_endpoint_fetch` merely because of file length. Its fetch
  slots, request queue, ordered response metadata, and context assembly form one
  ownership unit; first reduce its duplicated issue/enqueue fields with typed
  payloads.
- Keep `voice_dsp_pipeline` stage-local structures and current module boundary.
  Keep `stereo_chorus`, `fdn_reverb`, and `lookahead_compressor` intact unless a
  future behavioral or timing requirement identifies a real independent state
  owner.
- Do not split `synth_pkg` globally as part of this work. Introduce only the
  smallest additional package needed by cross-module voice-layer payloads.

## Completion Gates

Every refactoring change must satisfy the following before it is marked done:

1. No intentional behavioral, numeric, register, command, or public-interface
   change is included in the same patch.
2. The changed boundary has a focused self-checking test, and existing exact
   integer comparisons remain intact.
3. `make lint` and `make test` pass.
4. Changes touching RAM descriptions, executor decode/write paths, or DSP
   pipeline boundaries are checked with Smart Artix synthesis and forced
   implementation. RAM inference, utilization, setup/hold timing, and critical
   path ownership are compared with the current documented baseline.
5. `docs/design/rtl_module_map.md`, `docs/design/voice_pipeline.md`, and any
   affected stable contract are updated in the same change.
