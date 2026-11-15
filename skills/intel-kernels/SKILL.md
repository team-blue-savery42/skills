---
name: intel-kernels
description: Write, port or tune Mojo/MAX GPU kernels for Intel GPUs (Xe2 Battlemage and the integrated Xe-LP/Xe-LPG GPUs) - DPAS matrix multiply, 2D block loads/stores/prefetch, sub-group sizes, and how MAX dispatch picks the Intel GEMM, flash attention, Gated DeltaNet and FP8 kernels. Use when a MAX op is slow, wrong or fails to compile on Intel, or when adding an Intel path to a kernel.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Intel kernels for Mojo and MAX

How Intel-specific kernels are written, where they live in the fork, how
MAX selects them, and how to test them. Paths are relative to the fork's
root. It assumes working plugins (skills `intel-compiler-plugin`,
`intel-driver-plugin`) and a build (skill `mojo-max-intel-build`).
Measuring speed is skill `intel-performance`.

## Targets and sub-groups

Defined in `max/mojo/max/_plugin/intel/targets.mojo` (read its docstring):

| `--target-accelerator` | GPU | `version` | Sub-group (`WARP_SIZE`) | DPAS, 2D block I/O |
|------------------------|-----|-----------|-------------------------|--------------------|
| `intel:bmg-g31` | Arc Pro B70 (Xe2) | `xe2` | 16 | yes |
| `intel:bmg-g21` | Arc B580 / Pro B60 (Xe2) | `xe2` | 16 | yes (defined in `targets.mojo`; not tested: the B70 is the tested part) |
| `intel:bmg-g31-sg32`, `intel:bmg-g21-sg32` | same, every kernel at 32 | `xe2` | 32 | no: rejected at compile time |
| `intel:rpl-p` | Raptor Lake-P iGPU (Xe-LP) | `xe-lp` | 16 | no; no float64; work-groups up to 512 |
| `intel:arl-s` | Arrow Lake-S iGPU (Xe-LPG) | `xe-lpg` | 16 | no |

- A warp is an OpenCL sub-group. The compiler plugin fixes every kernel's
  sub-group size (`plugins/intel/compiler/SubgroupSize.h`), so `WARP_SIZE`
  is a compile-time constant. Code that assumes 32-lane warps fails on Intel;
  such MAX tests are marked `warp32` in `plugins/intel/tests/max-gpu-expected.txt`.
- No lane masks: `syncwarp` and shuffles ignore the mask, as on AMD
  (`max/mojo/max/_plugin/intel/__init__.mojo`).
- One `compile_info[kernel, target=ArcProB70SG32.target]` (or the `-sg32`
  accelerator) builds one kernel at 32. `docs/performance.md` ("Sub-group
  size") lists what 32 measured faster or slower.
- Run-time device facts (sub-group sizes, DPAS, DP4A, 2D block I/O, machine
  sizes) are available through MAX's Intel HAL extension
  (`max/mojo/max/_driver/max_license/hal/extensions/intel.mojo`); the
  current kernels choose at compile time from the target instead.

## Building blocks

- **DPAS**: `max/mojo/max/gpu/compute/arch/mma_intel.mojo`, reached through
  `mma()` (`max.gpu.compute.mma`) via the MAX plugin's `mma_fn` hook. One
  call is one `OpSubgroupMatrixMultiplyAccumulateINTEL`:
  D (M x 16) = A (M x 16) * B (16 x 16) + C with M = 1, 2, 4 or 8, float16
  or bfloat16 inputs, float32 or input-type accumulators. The docstring gives
  each lane's fragment layout; B is the packed (VNNI) form. Other shapes,
  including NVIDIA's 16x8x16, fail at compile time, as does sub-group 32
  (`ocloc` crashed). DPAS has no 8-bit float type.
- **2D block I/O**: `max/mojo/max/gpu/memory/block_io_intel.mojo`:
  `block_load`, `block_load_transform` (VNNI, DPAS's B),
  `block_load_transpose`, `block_store`, `block_prefetch`
  (`SPV_INTEL_2d_block_io`). One instruction moves a block for the whole
  sub-group; out-of-bounds elements read as zero or are skipped, so edges
  need no code. Shapes are checked at compile time against the
  `cl_intel_subgroup_2d_block_io` tables (listed in the docstring). Run-time
  rules, unchecked unless built with `-D ASSERT=all`: base 64-byte aligned,
  width at least 64 bytes, pitch a multiple of 16 bytes and at least the
  width, x a multiple of 4 (8-bit) or 2 (16-bit), global memory, uniform
  arguments, a full sub-group of 16. The 32-row transpose layout was
  measured on the B70 and differs from the extension's general rule (see
  the docstring).
- **Split barrier**: `_barrier_arrive`/wait in
  `max/kernels/src/linalg/matmul/gpu/intel/matmul.mojo`
  (`SPV_INTEL_split_barrier`), used by the GEMM to keep sub-groups within
  one iteration of each other.
- **Barriers, shuffles, ballots** call OpenCL built-ins by mangled name
  (`max/mojo/max/_plugin/intel/__init__.mojo`); `shuffle_xor` maps to
  `sub_group_shuffle_xor` because the generic path cost an indirect
  register move per word.
- **Register file**: the driver builds every module with IGC's auto
  large-GRF mode (256 registers per thread, half the threads), so a kernel
  with high register pressure gets it. Watch spills in the ISA (skill
  `intel-performance`).

> [!TIP]
> Further reading (free, external; not maintained here):
> - [SPV_INTEL_subgroup_matrix_multiply_accumulate](https://github.khronos.org/SPIRV-Registry/extensions/INTEL/SPV_INTEL_subgroup_matrix_multiply_accumulate.html): the SPIR-V instruction behind `mma()` on Intel and its packed float16/bfloat16 operand flags.
> - [SPV_INTEL_2d_block_io](https://github.khronos.org/SPIRV-Registry/extensions/INTEL/SPV_INTEL_2d_block_io.html): the five 2D block load, transform, transpose, prefetch and store instructions and their capabilities.
> - [cl_intel_subgroup_2d_block_io](https://registry.khronos.org/OpenCL/extensions/intel/cl_intel_subgroup_2d_block_io.html): the OpenCL form, with the block shape tables and the alignment, pitch and width restrictions `block_io_intel.mojo` follows.
> - [cl_intel_subgroup_matrix_multiply_accumulate](https://registry.khronos.org/OpenCL/extensions/intel/cl_intel_subgroup_matrix_multiply_accumulate.html): the OpenCL DPAS built-ins (`intel_sub_group_bf16_bf16_matrix_mad_k16` and others) for sub-group size 16, K = 16, M = 1 to 8.
> - [oneAPI GPU Optimization Guide](https://www.intel.com/content/www/us/en/docs/oneapi/optimization-guide-gpu/2025-0/overview.html): Intel's guide to the Xe architecture, sub-groups, large/small register modes, register spills and XMX.
> - [Chips and Cheese: Intel's Battlemage Architecture](https://chipsandcheese.com/p/intels-battlemage-architecture): independent microbenchmarks of the Xe2 core, XMX units, caches, local memory and bandwidth on the Arc B580.
> - [Triton tutorial: matrix multiplication](https://triton-lang.org/main/getting-started/tutorials/03-matrix-multiplication.html): block tiling and the grouped ordering for L2 reuse that the Intel GEMM uses.
> - [intel-xpu-backend-for-triton](https://github.com/intel/intel-xpu-backend-for-triton): Intel's Triton backend for its GPUs, including Arc B-series; its compiled kernels are a reference for Xe2 GEMM shapes.

## Where the Intel kernels live

| Kernel | Source | Selected by |
|--------|--------|-------------|
| Dense GEMM (DPAS, 2D block I/O, prefetch, skinny-M decode kernel) | `max/kernels/src/linalg/matmul/gpu/intel/matmul.mojo` | `matmul_dispatch_intel` (`intel/dispatch.mojo`), called from `_matmul_gpu_impl` in `linalg/matmul/gpu/__init__.mojo` under `comptime if ctx.default_device_info.api == "level_zero"` |
| Shared-memory SIMT GEMM (GPUs without DPAS) | `intel/simt.mojo` | same dispatch, `version` not `xe2` |
| FP8 weight-only GEMM (bf16 A, e4m3 B^T, per-tensor scale) | `intel/matmul.mojo` (`skinny_kernel_f8`, `f8_widen_kernel`, `gemm_kernel_f8_widened`) | `matmul_f8_dispatch_intel`, op `mo.matmul.weight.only.scaled.float8.intel` (`graph_compiler/builtin_kernels/linalg.mojo`), routed from `max/python/max/nn/_graph_ops/quant.py` (skill `intel-quantization`) |
| Ragged paged flash attention (prefill; split-K decode + stitch) | `max/kernels/src/nn/attention/gpu/intel/flash_attention.mojo` | `flash_attention_dispatch` in `nn/attention/gpu/mha.mojo`: `level_zero`, `xe2`, ragged, no sink, no KV quantization, `intel_fa_supported`; `MODULAR_ENABLE_INTEL_FA=0` turns it off |
| Gated DeltaNet recurrence | `max/kernels/src/state_space/gated_delta.mojo` (`gated_delta_recurrence_fwd_intel_gpu`) | the op's Intel branch in that file |
| Row-wise reductions (RMSNorm, softmax tiers) | `max/kernels/src/algorithm/gpu/rowwise.mojo` (`_INTEL_WARP_TIER_MIN_ROWS`) | `level_zero` branch in the tier choice |

Each file's docstring states the shapes, types and layouts it takes and the
tuning defaults (comptime `-D` defines such as `intel_fa_rows`,
`gated_delta_intel_sgs`, `intel_warp_min_rows`) with the measurement behind
them. Dispatch functions return `False` when they decline, and the caller
carries on to MAX's generic path (GEMV, naive matmul, naive attention).
The GEMM's docstring names `plugins/intel/utils/bench-gemm` for its tile
sweep; that script is not in `plugins/intel/utils/` (not verified where it
went).

> [!TIP]
> Further reading (free, external; not maintained here):
> - [FlashAttention](https://arxiv.org/abs/2205.14135) and [FlashAttention-2](https://arxiv.org/abs/2307.08691): the tiled, online-softmax attention the Intel kernel implements, and its work partitioning.
> - [PagedAttention (vLLM)](https://arxiv.org/abs/2309.06180): the paged KV cache layout the Intel flash attention reads.
> - [Gated Delta Networks](https://arxiv.org/abs/2412.06464): the gated delta rule behind Qwen3.5's linear-attention layers and the Intel recurrence kernel.

## Integrated GPUs

Their IGC rejects DPAS and 2D block I/O, so a kernel that uses either does
not compile for `rpl-p` or `arl-s`. They take: the SIMT GEMM for matmuls
(float16, bfloat16 or float32, M > 1, K a multiple of 4), MAX's generic
attention and FP8 paths, and the generic kernels elsewhere.
`docs/performance.md` ("Integrated GPUs") has the measured split. Xe-LP has
no float64.

## Gating rules

From `Mojo/docs/contributing/stdlib/stdlib-code-style.md` and
`plugins/intel/CONTRIBUTING.md`:

- Gate Intel code on an explicit check: `ctx.default_device_info.api ==
  "level_zero"` (host side), plus `version == "xe2"` for DPAS and block I/O.
  Never put Intel code in an `else` that falls through from another vendor,
  and never let another vendor's path fall through to Intel. Use
  `CompilationTarget.unsupported_target_error()` when no generic fallback
  exists; an unguarded `else` is fine only for a generic fallback.
- Keep Intel branches additive: other targets must compile and behave the
  same (the Python routing in `quant.py` says "Gated on the Level Zero API:
  no other target changes").
- Paths that cannot compile for Intel must exclude it explicitly (see the
  `api != "level_zero"` term on the tensor-core path in
  `linalg/matmul/gpu/__init__.mojo`).
- New Mojo files follow the stdlib style (naming, sorted imports,
  docstrings, license header for the directory; `max_license/` directories
  carry the MAX License).

## Porting or writing a kernel

1. Find the generic path's shape: what MAX calls, with which layouts and
   types, and what it already does on Intel (it may compile and just be
   slow). `MOJO_INTEL_PROFILE` (skill `intel-performance`) names the kernels
   a model step launches.
2. Write the Intel kernel beside the others (`.../gpu/intel/`), at sub-group
   size 16, with a docstring that states the supported shapes and the
   measurements behind its defaults.
3. Add a `*_supported` predicate and a dispatch that declines everything
   else; wire it in with the gating above.
4. Prefer 2D block loads with prefetch to shared memory for matrix tiles;
   keep accumulators in registers and check the ISA for spills
   (`flash_attention.mojo`'s docstring: 8 rows per sub-group spilled and
   ran 1.5-2x slower).
5. Test (below) for correctness first, then measure.

## Testing kernels

- End-to-end probes through the HAL client, checked on the CPU:
  `plugins/intel/tests/e2e/` (`gemm.mojo`, `mma.mojo`, `mma_sg32.mojo`,
  `block_io.mojo`, `block_io_reject.mojo`, `fp8_matmul.mojo`,
  `matmul_sram.mojo`, `attention_bench.mojo`, ...):
  `plugins/intel/utils/run-e2e <name> [-D ...]`. A line
  `# run-e2e: packages //max/kernels/src/linalg:linalg` adds kernel
  packages to the import path. `E2E_ACCELERATOR=intel:bmg-g31-sg32` runs at
  32.
- MAX graph tests against NumPy, at real model shapes:
  `plugins/intel/tests/graph/` (`attention.py`, `gated_delta.py`,
  `norms.py`, `rope_store.py`, `elementwise.py`, `sampling.py`,
  `fp8_linear.py`, `graph_smoke.py`):
  `plugins/intel/utils/run-max-py plugins/intel/tests/graph/attention.py`.
- MAX's own GPU tests (`max/kernels/test/gpu/...`) on Intel:
  `plugins/intel/utils/check-max-gpu -k <substring>`; compare with
  `plugins/intel/tests/max-gpu-expected.txt`, and update that file, with the
  cause, when a change moves a result.
- Model-level: the greedy-text regression in `utils/check` (skill
  `intel-plugin-checks`).
- Use `-D ASSERT=all` while developing: it turns on the block I/O run-time
  checks.

## Pitfalls

- DPAS and block I/O need a full sub-group of 16 and uniform arguments; a
  work-group size that is not a multiple of 16 breaks them.
- Base pointers must be 64-byte aligned for block I/O; device allocations
  are, sub-views may not be (the GEMM dispatch checks `% 64`).
- IGC 2.42 and 2.43 return NaN from MAX's paged flash attention; use the
  tested IGC (`AGENTS.md`, skill `intel-tool-bugs`). Other IGC bugs with
  workarounds are in `plugins/intel/docs/intel-tools-issues.md`.
- A kernel that page-faults can hang the next process on the GPU (skill
  `intel-gpu-fault-recovery`). Test new index arithmetic with
  `-D ASSERT=all` first.
- Attention with sinks, quantized KV caches and non-ragged layouts fall back
  to MAX's naive kernels on Intel.

## References

- `plugins/intel/README.md` (targets, what is tuned), `docs/performance.md`,
  `docs/support.md`
- Docstrings of `mma_intel.mojo`, `block_io_intel.mojo`,
  `linalg/matmul/gpu/intel/*.mojo`, `nn/attention/gpu/intel/flash_attention.mojo`
- `Mojo/docs/contributing/stdlib/stdlib-code-style.md`
- Skills: `intel-performance`, `intel-quantization`, `intel-plugin-checks`,
  `intel-compiler-plugin`, `intel-tool-bugs`
