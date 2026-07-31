# Global Sample Cache Experiment Archive

This directory preserves the final RTL and focused testbench from the global
sample-cache experiment. The files are not listed in `rtl/filelist.f`, are not
instantiated by the renderer, and are not part of the default lint, test, or
Vivado flows.

The archived implementation is a 32 KiB, two-way cache with 512 32-word
macro-lines at the 512-voice configuration. Each macro-line has four independent
eight-word sectors. Refill misses fetch all four sectors; fallback misses fetch
only the requested sector.

The representative one-second SGM DDR3/QSPI results and the rejection rationale
are recorded in
[`../../docs/verification/global_sample_cache_evaluation.md`](../../docs/verification/global_sample_cache_evaluation.md).
The production renderer continues to use `rtl/memory/voice_sample_window.sv`.

To rerun the focused archived test manually:

```bash
verilator -DSYNTH_NUM_VOICES=512 \
  -DSYNTH_BLOCK_WORK_ENTRY_COUNT=8 \
  -DSYNTH_BLOCK_JOB_ENTRY_COUNT=8 \
  -DSYNTH_MAX_BLOCK_FRAMES=16 \
  --binary -j 0 --timing --Wall -Wno-fatal \
  --Mdir build/archive_global_sample_cache_obj_dir \
  --top-module tb_global_sample_line_cache \
  rtl/pkg/synth_pkg.sv \
  archive/global_sample_cache_experiment/global_sample_line_cache.sv \
  archive/global_sample_cache_experiment/tb_global_sample_line_cache.sv
build/archive_global_sample_cache_obj_dir/Vtb_global_sample_line_cache
```
