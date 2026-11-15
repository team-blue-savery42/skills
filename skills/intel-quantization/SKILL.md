---
name: intel-quantization
description: Run, check or add quantized models in MAX on Intel GPUs - the FP8 e4m3 weight-only path with per-tensor scales, which architectures and checkpoints it covers, what is missing (4-bit NVFP4/MXFP4, grouped expert GEMMs, GGUF on GPU, FP8 block scales, FP8 KV cache), how to add a weight-only kernel, and how to check accuracy and memory fit. Use for any quantization, FP8, FP4 or GGUF task on Intel.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Quantization on Intel GPUs

What quantized formats MAX runs on Intel GPUs in the fork, how they are
wired, and how to extend and check them. Paths are relative to the fork's
root. The status tables are in `plugins/intel/docs/support.md` ("What fits
in the B70's 32 GB", "Weight formats", "KV cache and context", "Missing
functionality"); read them rather than this summary when they disagree.
Kernel mechanics are in skill `intel-kernels`.

## What runs: FP8 e4m3, weight-only, per-tensor scales

- **Format.** float8_e4m3fn weights with one float32 scale per tensor, as
  modelopt's "FP8" checkpoints store them (`weight` and `weight_scale` per
  quantized module, layers listed in `hf_quant_config.json`; see
  `fake_fp8` in `plugins/intel/tests/graph/hf_match.py`). Static
  per-tensor input scales are accepted and ignored: the activation stays
  bfloat16, where the input scale cancels.
- **Why weight-only.** Xe2's DPAS has no 8-bit float type, so the kernel
  widens the weights to bfloat16 for DPAS and multiplies the float32
  accumulators by the scale (docstrings of
  `Struct_matmul_weight_only_scaled_float8_intel` in
  `max/kernels/src/graph_compiler/builtin_kernels/linalg.mojo` and of
  `max/kernels/src/linalg/matmul/gpu/intel/matmul.mojo`).
- **Kernels** (`linalg/matmul/gpu/intel/`, dispatch
  `matmul_f8_dispatch_intel`): M <= `SKINNY_MAX_M` (decode) runs
  `skinny_kernel_f8`, which reads the FP8 bytes with 2D block loads and
  widens them in registers; larger M widens the weights once into a
  bfloat16 scratch copy (`f8_widen_kernel`) and runs the bfloat16 GEMM
  (`gemm_kernel_f8_widened`). The docstring explains why: widening inside
  the GEMM repeated the work per sub-group row and measured slower on the
  B70. Shapes: N, K multiples of 8 and 16, N >= 32, K >= 64, row-major.
- **Routing.** `max/python/max/nn/_graph_ops/quant.py` sends a quantized
  matmul to `mo.matmul.weight.only.scaled.float8.intel` when the device is
  an Intel Xe2 GPU (`_is_intel_xe2_gpu()`: architecture name starting
  `bmg-`), the activation is bfloat16, the weight float8_e4m3fn, there are
  no dynamic activation scales, and the weight scale is one per tensor.
  Anything else takes MAX's generic FP8 path.
- **Architectures** (`support.md`): MAX wires FP8 for `qwen3_5` (attention
  and Gated DeltaNet projections only; its MLPs are wired for NVFP4 only),
  `qwen3` and `llama3`. Only `qwen3_5` was measured on Intel, single
  stream, with a Qwen3.5-0.8B checkpoint quantized locally because no
  public one in this format exists. The tool used to make it is not in the
  fork (not verified which).
- **Integrated GPUs.** No DPAS, so the Intel FP8 op is not used; MAX's
  generic FP8 path runs, with errors of 5.0e-3 to 9.4e-3 in
  `tests/graph/fp8_linear.py` against its 7.8e-3 tolerance
  (`docs/performance.md`, "Integrated GPUs").

Running a model in FP8: pass the encoding to MAX, for example
`--quantization-encoding float8_e4m3fn` to `pipelines generate`/`serve`
(the option `tests/graph/gen_repeat.py` passes for `GEN_ENCODING`), or
`--encoding float8_e4m3fn` to `tests/graph/bench_model.py`.
`docs/benchmarks.md` has no FP8 throughput figures; any you report are new
measurements and need the hygiene in skill `intel-performance`.

## What is missing

From `support.md`; check it for the current state:

- 4-bit dense weights (NVFP4: an fp8 scale per 16 values; MXFP4: an e8m0
  scale per 32): no Intel kernel. NVFP4 layers on Intel reach the path
  written for NVIDIA SM100 (not run).
- 4-bit mixture-of-experts weights: no grouped expert GEMM for Intel;
  gpt-oss-20b does not load (MAX's MXFP4 MoE path dequantizes every expert
  behind a fixed 15 GiB reservation outside SM100). Generic top-k routing
  and token permutation have not been run on Intel.
- GGUF (`q4_0`, `q4_k`, `q6_k`): CPU kernels only in MAX, read for `llama3`
  only; not run on Intel.
- FP8 with block or channel scales: the Intel kernel takes one scale per
  tensor; not run.
- FP8 KV cache (`kv_cache_format`): in MAX, not run on Intel.
- GPTQ: read for `llama3` only; not run.
- Without 4-bit, 27-32 B dense models do not fit a 32 GB card (estimates in
  `support.md`, not measured).

## Adding a weight-only format

The approach `support.md` names for 4-bit is the FP8 kernel's:

1. Keep activations bfloat16. Load packed weights with 2D block loads,
   unpack and apply the block scales in registers, and feed bfloat16
   fragments to DPAS (`mma()`, fragment layouts in
   `max/mojo/max/gpu/compute/arch/mma_intel.mojo`); accumulate in float32
   and apply per-tensor scales once before the store.
2. Decode (small M) is bound by reading weights: read the packed bytes
   once, as `skinny_kernel_f8` does. For large M, measure widening once
   into a bfloat16 scratch buffer against widening per tile, as the FP8
   kernel's docstring did.
3. Block I/O rules apply to the packed tensor: 64-byte aligned base, pitch a
   multiple of 16 bytes, width at least 64 bytes (`block_io_intel.mojo`).
   Scale tensors have their own layout per format; read MAX's loader for
   the format before designing the kernel.
4. Register a graph op beside `Struct_matmul_weight_only_scaled_float8_intel`
   and route to it from Python with an explicit Intel check, leaving every
   other target unchanged (gating rules in skill `intel-kernels`).
5. Check memory: the dequantized weights must never be materialized for the
   whole model.

## Checking accuracy

- **Kernel against exact values**: `plugins/intel/tests/e2e/fp8_matmul.mojo`
  (`plugins/intel/utils/run-e2e fp8_matmul`) checks every e4m3 code exactly
  with one-hot activations, then random inputs within
  `tol * sum|a b| * scale` of a float64 reference (tol 2^-10 for float32
  output, 2^-7 for bfloat16), at the model's projection shapes and edge
  shapes. Copy that structure for a new format.
- **Graph op**: `plugins/intel/tests/graph/fp8_linear.py` (through
  `utils/run-max-py`) builds MAX's quantized linear layer, checks that the
  graph holds the Intel op and no activation quantization, and compares
  with NumPy.
- **Model**: greedy text and token ids.
  - `tests/graph/gen_repeat.py <model-dir>` with `GEN_ENCODING` and
    `GEN_JSON` records MAX's greedy ids for fixed prompts; compare the
    quantized run with the bfloat16 run of the same model.
  - `tests/graph/hf_match.py` (a separate venv with torch and transformers,
    CPU) compares MAX's ids with transformers'. With `HF_FAKE_FP8=<fp8-dir>`
    transformers gets the FP8 checkpoint's weights dequantized exactly, so
    the reference has the same quantization error and differences point at
    the kernels; it also prints the mean negative log-likelihood of MAX's
    tokens.
  - Expect quantized greedy text to diverge from bfloat16 at some point;
    judge by where and by the logit gap `hf_match.py` reports, not by
    identity.

## Checking memory fit

- `support.md` "What fits in the B70's 32 GB" estimates weights per size and
  format; the KV cache comes on top (Qwen3-8B's bfloat16 KV cache is 144 KiB
  per token, from the same section).
- Measure: `plugins/intel/utils/bench/sysman_mem.py` samples device memory
  through Sysman; `serve.sh` and `soak.sh` record it during runs.
- On integrated GPUs a single allocation over 4 GiB fails (`README.md`).

## Pitfalls

- A layer the routing does not match silently takes MAX's generic FP8 path,
  which quantizes activations; `fp8_linear.py` checks the graph for that.
- `qwen3_5` quantizes only attention and Gated DeltaNet projections in FP8;
  whole-model FP8 needs MLP wiring in MAX first (`support.md`).
- Compare vLLM-XPU only at the same precision: `vllm_steps.py`'s
  `STEPS_QUANT=fp8` quantizes online from the bfloat16 checkpoint, which is
  not the same as a static modelopt checkpoint.

## References

- `plugins/intel/docs/support.md`, `docs/performance.md`, `docs/benchmarks.md`
- `max/kernels/src/linalg/matmul/gpu/intel/{matmul,dispatch}.mojo`
- `max/kernels/src/graph_compiler/builtin_kernels/linalg.mojo`
  (`Struct_matmul_weight_only_scaled_float8_intel`)
- `max/python/max/nn/_graph_ops/quant.py`
- `plugins/intel/tests/e2e/fp8_matmul.mojo`, `tests/graph/fp8_linear.py`,
  `tests/graph/hf_match.py`, `tests/graph/gen_repeat.py`
- Skills: `intel-kernels`, `intel-performance`, `intel-plugin-checks`

> [!TIP]
> Further reading (free, external; not maintained here):
> - [FP8 Formats for Deep Learning](https://arxiv.org/abs/2209.05433): the E4M3 and E5M2 encodings that `float8_e4m3fn` follows.
> - [OCP Microscaling Formats (MX) v1.0](https://www.opencompute.org/documents/ocp-microscaling-formats-mx-v1-0-spec-final-pdf): the specification of block-scaled FP8, FP6, FP4 and INT8 elements with E8M0 shared scales (MXFP4).
> - [Microscaling Data Formats for Deep Learning](https://arxiv.org/abs/2310.10537): the paper behind the MX formats, with accuracy results.
> - [Introducing NVFP4](https://developer.nvidia.com/blog/introducing-nvfp4-for-efficient-and-accurate-low-precision-inference/): NVFP4's 16-value blocks with FP8 E4M3 scales plus a per-tensor FP32 scale, compared with MXFP4.
> - [GGUF](https://github.com/ggml-org/ggml/blob/master/docs/gguf.md): the GGUF file format and the `ggml_type` list (`Q4_0`, `Q4_K`, `Q6_K`, ...).

> [!TIP]
> Further reading (free, external; not maintained here):
> - [GPTQ](https://arxiv.org/abs/2210.17323) and [AWQ](https://arxiv.org/abs/2306.00978): the two common post-training 4-bit weight quantization methods.
> - [NVIDIA Model Optimizer](https://github.com/NVIDIA/Model-Optimizer): post-training FP8 and NVFP4 quantization with Hugging Face checkpoint export (the "modelopt" format).
> - [LLM Compressor](https://github.com/vllm-project/llm-compressor): vLLM's quantization library (FP8, W4A16, NVFP4, GPTQ, AWQ) writing compressed-tensors checkpoints.
> - [vLLM on Intel Arc Pro B-Series](https://vllm.ai/blog/2025-11-11-intel-arc-pro-b): how vLLM-XPU handles MXFP4 experts on these GPUs (conversion to bfloat16 with prepacking) and its MoE kernels.
