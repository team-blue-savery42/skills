---
name: intel-performance
description: Measure and tune Mojo/MAX performance on Intel GPUs - launch profiles (MOJO_INTEL_PROFILE, utils/bench/steps.py), IGC ISA dumps for SIMD width, register mode and spills, IGC options, the utils/bench single-stream, serving and long-prompt scripts, and comparisons with vLLM-XPU and llama.cpp. Use when a kernel or model is slow on Intel, before claiming a speed-up, or when reproducing docs/benchmarks.md.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Performance on Intel GPUs

How to find where the time goes and how to produce numbers others can
trust. Paths are relative to the fork's root; the scripts are under
`plugins/intel/utils/`. `plugins/intel/docs/performance.md` is the current
analysis ("How to measure", then bottlenecks per GPU, ordered by measured
payoff); `plugins/intel/docs/benchmarks.md` holds the engine comparisons.
Read both before starting.

Every performance claim names the GPU, the driver stack versions, the
build, the command and its output (`AGENTS.md`). If you could not run it,
say so.

## Measurement hygiene

- **Optimized build.** The default build is debug. Use
  `--compilation_mode=opt` for anything timed; `run-max-py` does this with
  `RUN_MAX_PY_OPT=1` (outputs under `bazel-out/mojo_host_platform-opt`,
  plugins built in the same configuration).
- **Idle GPU.** The bench scripts expect the GPU to themselves ("stop other
  GPU users first"; their `busy()` lists render-node users through
  `/proc`). On a shared machine, ask before stopping anyone's process or
  service (`AGENTS.md`).
- **Warm-up and power.** `docs/performance.md` ("Warm-up"): on the B70 the
  clock ramps for about 100 ms, then the card hits its power limit and
  settles within about 1 s. Time past the first second, or report burst
  and sustained figures separately.
- **Repeat.** Report medians of several repetitions after a warm-up
  (`bench_model.py --reps`, `single.sh` `REPS`, default 3; `llama-bench -r 3`).
- **Caches.** Two compile caches sit between a change and the GPU:
  - Mojo's kernel cache: use a fresh `MODULAR_CACHE_DIR` after changing the
    compiler plugin or kernels, and whenever you want IGC dumps (a cached
    kernel is not recompiled and dumps nothing).
  - compute-runtime's binary cache (IGC output): an empty `NEO_CACHE_DIR`
    or `NEO_CACHE_PERSISTENT=0` when you change IGC, its options, or
    measure load/compile time (`docs/intel-tools-issues.md` uses an empty
    `NEO_CACHE_DIR` to reproduce IGC bugs; several reproductions under
    `tests/intel-tools/` set `NEO_CACHE_PERSISTENT=0`).
  Steady-state step timings do not include compilation, so warm caches are
  fine there once you know they hold the current code.
- **Record versions**, as `docs/benchmarks.md` "Setup" does: GPU, kernel
  driver and Linux version, compute-runtime, IGC, Level Zero loader, the
  fork commit (and whether the tree is clean), build mode, model revision,
  dtype, engine versions and settings, device graphs on or off.
- **Same state for every engine.** `single.sh` runs every engine in the same
  machine state; compare engines only within one such run.

## Where the time goes: launch profiles

The driver plugin records every kernel launch, copy, fill, synchronize,
allocation and device-graph launch with host times and device timestamps:

```sh
RUN_MAX_PY_OPT=1 RUN_MAX_PY_ENV="MOJO_INTEL_PROFILE=<outdir>/prof" \
  plugins/intel/utils/run-max-py plugins/intel/tests/graph/bench_model.py <model-dir> \
  --prompt 4096 --decode 64 --max-length 4256 --reps 3 --no-overlap \
  --marks <outdir>/marks
python3 plugins/intel/utils/bench/steps.py <outdir>/prof.<pid> <outdir>/marks \
  --kind prefill --top 40
```

- The profile goes to `<prefix>.<pid>`; its format is in
  `plugins/intel/driver/Profile.h`.
- `bench_model.py --marks` writes each step's start and end on the same
  clock; `steps.py` gives per-step kernel time, host gaps between launches,
  device busy and idle time, and a table of kernels by name (median per
  step). `--detail N`, `--csv OUT` for more.
- Steps during which the plugin harvested timestamps are left out.
  `MOJO_INTEL_PROFILE_DEVICE=0` records host times only, for measuring host
  overhead without per-command timestamp events.
- Kernels inside device graphs are recorded at capture; a graph launch has
  one device time for all its commands.
- Loader-level tracers: `Profile.h` notes that tools tracing the Level Zero
  loader (`unitrace`) do not see the kernels MAX's graph runtime launches
  through the plugin; `run-max-py` can still run under one with
  `RUN_MAX_PY_WRAPPER` (for example `unitrace -d`). EU stall sampling was
  not available on the tested stack (`docs/performance.md`).
- Device memory over time: `utils/bench/sysman_mem.py` samples Sysman on the
  same clock.

The attention kernel in isolation, checked against float64:

```sh
plugins/intel/utils/run-e2e attention_bench -D NQ=32 -D NKV=8 -D HD=128 -D PAGE=128 \
  -D PREFILL="4096 16384" -D DECODE="4096"
```

(`docs/performance.md` gives the shapes for Qwen3-8B and Qwen3.5-0.8B and
`-D BATCH=n`; `tests/e2e/attention_bench.mojo` documents list defines as
`-D PREFILL="512 4096"`, not run here.)

## What IGC made of a kernel

1. Dump the SPIR-V: run the program with `MOJO_INTEL_PLUGIN_DUMP=<dir>` and a
   fresh `MODULAR_CACHE_DIR` (skill `intel-compiler-plugin`).
2. Compile it with IGC's dumps on:

   ```sh
   IGC_ShaderDumpEnable=1 IGC_DumpToCustomDir=<dumpdir> \
     ocloc compile -spirv_input -file <kernel>.spv -device bmg-g31 \
     -options "-ze-intel-enable-auto-large-GRF-mode"
   ```

   The `-options` value matches what the driver plugin passes
   (`plugins/intel/utils/check-spirv`; the driver also adds
   `-cl-fp32-correctly-rounded-divide-sqrt`, `driver/Module.cpp`).
   IGC's `igc_flags.h` says the parent of `<dumpdir>` must exist; create
   `<dumpdir>` itself to be safe.
3. In the ISA, check the SIMD width (16 expected; 32 for `-sg32`), the
   register file mode (128 or 256 GRF) and spill/fill sizes
   (`docs/performance.md`). File names in the dump depend on the IGC
   version; not described here.

Run-time IGC options for a whole program: `MOJO_INTEL_IGC_OPTIONS`, appended
to the driver's build flags at module creation (for example
`-cl-opt-disable`, to tell an IGC optimizer issue from a kernel bug). Do not
time with debugging options.

## Benchmarks against other engines

`docs/benchmarks.md` compares MAX (opt build, HAL runtime) with vLLM-XPU (a
pinned `intel/vllm` container) and llama.cpp (SYCL and Vulkan builds at a
pinned commit) on the same models and dtype, with greedy decoding. It
records setup, engine versions and flags, which development tree each MAX
figure came from, and which cells were not measured. Its "Reproducing"
section has the commands; in short (from `plugins/intel`):

| Script | Measures |
|--------|----------|
| `utils/bench/single.sh OUT MODEL GGUF [MAX_ARGS...]` | prompt processing at 512, 4096 and a long prompt; decode after 512 and 4096 tokens; engines from `ENGINES` |
| `utils/bench/serve.sh OUT ENGINE MODEL GGUF [CONC...]` | OpenAI-compatible server with `vllm bench serve`, random 512/128 and ShareGPT workloads per concurrency |
| `utils/bench/long.sh OUT MODEL` | 8k-32k prompts and prefix-cache follow-ups (`ENGINE=max` or `vllm`) |
| `utils/bench/soak.sh OUT MODEL [MINUTES]` | an hour of mixed serving, greedy text at start and end, GPU faults counted |
| `utils/bench/summary.py DIR...` | tables a serving run: throughput, TTFT, ITL |
| `utils/bench/vllm_steps.py` | vLLM-XPU engine steps timed as `bench_model.py` times MAX's |

Inputs: `MODELS_DIR` (Hugging Face snapshots by name, GGUF files in
`MODELS_DIR/gguf`), `DATASETS_DIR` (ShareGPT V3 JSON); `utils/bench/fetch.sh
REPO REVISION NAME` downloads a public model at a pinned revision. Each
script's header lists its other variables. Notes that matter for a fair
comparison, all from the scripts and `docs/benchmarks.md`:

- MAX prompt steps run with the overlap scheduler off, decode with it on;
  vLLM likewise with async scheduling.
- vLLM-XPU runs eager unless `VLLM_GRAPH=1`; say which.
- Qwen3-8B on MAX needs `--no-prefer-module-v3`.
- A new result for the README or `docs/benchmarks.md` is measured on the
  current tree; if it is not, say which tree it came from.

## Known bottlenecks

Do not restate them; read `docs/performance.md`. It covers, for the B70:
flash attention prefill (issue- and latency-bound, register limits on rows
per sub-group), the Gated DeltaNet recurrence, unfused SwiGLU and RMSNorm,
GEMMs (near their ceiling there), serving time to first token, mixture of
experts, sub-group size 16 versus 32, and device-graph memory; and for the
integrated GPUs: memory-bound decode, the SIMT GEMM, naive attention,
allocation limits and rounding differences. `docs/support.md` tracks MAX
against vLLM-XPU per scenario.

## Pitfalls

- Debug builds and cached kernels are the two most common reasons a change
  "made no difference".
- `bench_model.py` runs without device graphs unless `--graph-capture`;
  `max serve` captures them by default (`docs/performance.md`).
- The first second of a run is faster than the sustained rate (power limit).
- Do not upgrade IGC to chase speed without the attention test: IGC 2.42 and
  2.43 return NaN in MAX's paged flash attention (`AGENTS.md`, skill
  `intel-tool-bugs`).
- A faster kernel must still pass its correctness tests (skill
  `intel-kernels`) and `utils/check` (skill `intel-plugin-checks`).

## References

- `plugins/intel/docs/performance.md`, `docs/benchmarks.md`, `docs/support.md`
- `plugins/intel/driver/Profile.h`, `utils/bench/steps.py`,
  `tests/graph/bench_model.py`, `utils/run-max-py`
- Skills: `intel-kernels`, `intel-driver-plugin`, `intel-compiler-plugin`,
  `intel-gpu-environment`, `intel-tool-bugs`

> [!TIP]
> Further reading (free, external; not maintained here):
> - [vLLM benchmark CLI](https://docs.vllm.ai/en/latest/benchmarking/cli/): `vllm bench serve` with the random and ShareGPT datasets and its TTFT, TPOT and ITL definitions, the client `serve.sh` uses.
> - [NVIDIA NIM LLM benchmarking metrics](https://docs.nvidia.com/nim/benchmarking/llm/metrics): vendor-neutral definitions of time to first token, inter-token latency, end-to-end latency and tokens per second.
> - [MLPerf Inference LoadGen](https://github.com/mlcommons/inference/blob/master/loadgen/README.md): why the load generator is kept separate from the system under test, and the Server and Offline modes.
> - [llama-bench](https://github.com/ggml-org/llama.cpp/tree/master/tools/llama-bench): llama.cpp's `pp`/`tg` tests and repetitions, the llama.cpp side of `single.sh`.
> - [vLLM on Intel Arc Pro B-Series](https://vllm.ai/blog/2025-11-11-intel-arc-pro-b): the vLLM project's post on its Intel kernels, with `vllm serve` and `vllm bench serve` commands for these GPUs.
> - [unitrace](https://github.com/intel/pti-gpu/tree/master/tools/unitrace): Intel's tracer for Level Zero calls and device kernel timing, and the EU stall sampling option.
> - [IGC configuration flags](https://github.com/intel/intel-graphics-compiler/blob/master/documentation/configuration_flags.md): `IGC_ShaderDumpEnable`, `IGC_DumpToCustomDir` and IGC's other debug flags.
> - [compute-runtime compiler cache](https://github.com/intel/compute-runtime/blob/master/programmers-guide/COMPILER_CACHE.md): `NEO_CACHE_PERSISTENT`, `NEO_CACHE_DIR` and the cache's defaults.
