---
name: intel-plugin-checks
description: Run and read the Intel plugins' checks in Modular's fork - plugins/intel/utils/check and the individual check-* scripts (codegen, device, e2e, spirv, targets, MAX GPU test gate), the expected MAX results in tests/max-gpu-expected.txt with their result categories and causes (igc, compat, vendor...), when and how to update them, the Qwen3.5-0.8B greedy-text regression, and running checks on a shared GPU.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Intel plugin checks

Use this before sending a change to `plugins/intel/` or to code the Intel
plugins depend on, after an upgrade of the GPU stack, and to find out what
a change moved. `plugins/intel/CONTRIBUTING.md` asks for
`plugins/intel/utils/check` on a host with an Intel GPU before sending a
series. All paths are relative to the fork's root. The expectations
describe an Arc Pro B70 (`bmg-g31`) with the tested stack (skill
`intel-gpu-environment`); on other GPUs or IGC versions results differ.

Read each script's header before running it: usage, arguments and
environment are documented there.

## The full run: `utils/check`

```sh
plugins/intel/utils/check <outdir> [<qwen3.5-0.8b-dir>]
```

It builds, then runs these steps in order; each step's output goes to
`<outdir>/<step>.log`:

| Step            | What it runs                                                                                     | Needs GPU |
|-----------------|--------------------------------------------------------------------------------------------------|-----------|
| `build`         | `./bazelw build //plugins/intel/... //max/mojo/max:max //Mojo:mojo`, the HAL pipelines build, `make-mojo-launcher` | no |
| `unit`          | `./bazelw test //plugins/intel/...` (compiler and driver plugin unit tests)                      | yes (driver tests) |
| `codegen`       | `utils/check-codegen`: `tests/codegen/kernels.mojo` through the compiler plugin; checks each kernel's SPIR-V and runs `utils/check-spirv` | no (needs `ocloc`) |
| `e2e`           | `utils/check-e2e`: the Mojo programs in `tests/e2e` on the GPU through `utils/run-e2e`           | yes |
| `graph-<name>`  | `utils/run-max-py tests/graph/<name>.py` for `graph_smoke norms rope_store elementwise gated_delta attention sampling fp8_linear` | yes |
| `gate`          | `utils/check-max-gpu` against `tests/max-gpu-expected.txt`; table in `gate-table.md`, failure logs in `gate-logs/` | yes |
| `text`          | Qwen3.5-0.8B greedy text against `tests/regression/qwen3.5-0.8b-greedy.txt` (opt build)          | yes |

`//plugins/intel/driver:LevelZeroFaultTest` is tagged `manual`, so the
`unit` step does not run it; it faults the GPU (skill
`intel-gpu-fault-recovery`).

The model directory defaults to `$HOME/models/Qwen3.5-0.8B` (a Hugging
Face snapshot of `Qwen/Qwen3.5-0.8B`); without it the text step is
skipped. The script also writes `<outdir>/commit.txt` (the commit and
`git status --short`).

### Reading `<outdir>/result.txt`

```text
build rc=0 <seconds>s
unit rc=0 ...
...
text identical to tests/regression/qwen3.5-0.8b-greedy.txt
GPU fault lines: 0
DONE
```

- `rc` is each step's exit status; non-zero means look at `<step>.log`.
- For the gate, `rc=1` means at least one test got *worse* than expected;
  other changes do not fail it (below).
- `TEXT DIFFERS (text.diff)` or `text skipped: no <dir>` replace the
  `identical` line.
- `GPU fault lines` counts kernel-log lines matching `xe.*fault`,
  `CAT error` or `Engine reset` (case-insensitive) since the run started.
  Non-zero: read skill `intel-gpu-fault-recovery` before trusting any
  timeout or failure in the run. Zero is only meaningful when the user can
  read `journalctl -k`.

The README's "Checks" section states the result at the branch's commit
(for example: 73 unit tests, 23 codegen kernels, 43 end-to-end probes, 8
graph tests, 204 MAX tests with 136 pass, 25 fail, 41 don't compile, 1
n/a, 1 timeout, all as expected). Compare with that.

## The individual scripts

Run them after a build (`utils/check`'s build step, or the commands in
skill `mojo-max-intel-build`) and after `make-mojo-launcher`, since most
use the launcher at `$INTEL_PLUGIN_BIN/mojo`. `MODULAR_DIR` overrides the
checkout. Each prints `ok`/`FAIL` lines and exits non-zero on a failure.

- `utils/check-spirv <file.spv> [device]`: `spirv-val --target-env
  spv1.4`, requires a kernel entry point, then compiles with `ocloc` for
  `device` (default `bmg-g31`) with the driver plugin's build option
  `-ze-intel-enable-auto-large-GRF-mode`. Needs no GPU.
- `utils/check-codegen`: the codegen corpus. Each kernel must be a SPIR-V
  kernel with `CrossWorkgroup` pointers, sub-group size 16 and the SPIR-V
  instruction it exists to exercise (DPAS, 2D block I/O, split barriers,
  atomics, the heap...), plus a sub-group size 32 variant of `warp_sum`.
  Needs no GPU.
- `utils/check-targets`: `tests/codegen/targets.mojo`; the Intel targets
  select the Intel stdlib plugin (`is_gpu()` true) and give a valid SPIR-V
  kernel. Not part of `utils/check`.
- `utils/check-device`: compiles `tests/device/*.mojo`, runs each kernel
  with `utils/l0/run.sh` (a plain Level Zero runner) and compares the
  output (printf, atomics and math, timers, warp primitives, wide
  vectors). Not part of `utils/check`.
- `utils/check-e2e`: about 55 `expect` lines over `tests/e2e`, each with
  an expected exit code and counted output patterns, some run again with
  `MOJO_INTEL_IGC_OPTIONS=-cl-opt-disable`. `E2E_ACCELERATOR`
  (`intel:bmg-g31` default, `intel:rpl-p`, `intel:arl-s`) switches the
  expectations where the devices differ. Some probes need extra Bazel
  builds first; the comments above each `expect` say which.
- `utils/run-e2e <name> [options]`: one probe, for iterating.
- `utils/check-max-gpu`: the MAX gate, below.

## The MAX GPU test gate: `utils/check-max-gpu`

```sh
plugins/intel/utils/check-max-gpu [-j JOBS] [-k SUBSTRING ...] [-o TABLE.md] \
  [--logs DIR] [--logs-all] [--limit SECONDS] [--accelerator TARGET] \
  [--expect plugins/intel/tests/max-gpu-expected.txt]
plugins/intel/utils/check-max-gpu --self-test
```

It builds what the tests import with `--//:hal_device_context=true`, then
runs MAX's GPU tests (the directories and lists at the top of the script)
with `mojo run -D ASSERT=all --target-accelerator=intel:bmg-g31`, through
the compiler plugin and the Level Zero driver plugin. Tests with `CHECK`
lines go through `FileCheck` (must be on `PATH`). Defaults: 4 jobs, 1200 s
per test. `-k` (repeatable) selects tests by path substring; `--logs`
keeps the output of failures (`--logs-all` of every test). `--self-test`
checks the judging logic without Mojo or a GPU.

### Results

| Result    | Meaning                                                                  |
|-----------|--------------------------------------------------------------------------|
| `pass`    | exited 0 and passed FileCheck (or failed as its lit RUN line expects)    |
| `fail`    | compiled and ran, but failed; the first error is shown                   |
| `compile` | did not compile                                                          |
| `timeout` | ran longer than `--limit`                                                |
| `n/a`     | did not pass, and every lit RUN line builds for another vendor's target  |

The script's docstring has the exact rules (expected crashes, expected
compile errors, RUN-line parsing).

### `tests/max-gpu-expected.txt`

One line per test: `<test path> <result> <cause>`; `#` lines are comments.
Tests built several times with different defines appear as
`<source>@<variant>` (the paged flash-attention test per head size). The
causes are defined in the file's header:

| Cause                 | Meaning                                                                         |
|-----------------------|---------------------------------------------------------------------------------|
| `-`                   | passes                                                                          |
| `vendor`              | targets another vendor's GPU or API                                             |
| `compat`              | needs a `DeviceContext` API the HAL build lacks                                 |
| `expect`              | checks for a failure its RUN line expects                                       |
| `warp32`              | assumes 32-lane warps; Intel kernels run at 16                                  |
| `igc`                 | IGC 2.41 miscompiles it (fixed in IGC master); the Bessel tests fail intermittently |
| `ring-offset`         | `test_gated_delta_spec_ring`: two cases need a built binary or 64-bit offsets   |
| `spirv-16bit-atomics` | needs `SPV_INTEL_16bit_atomics` in the `spirv64` extension list                 |
| `shmem-scope`         | `ep_comm.mojo` has no `spirv64` memory scopes                                   |

With `--expect`, each result is compared with the file:

- `BETTER`: now passes. `WORSE`: passed, now does not (exit code 1).
  `CHANGED`: another non-pass result. `NEW`: not in the file.
- The last line is `against <file>: ...` or `all the same`.
- `stranded` notes: after a GPU fault, tests that timed out while or after
  it ran are rerun alone after a throwaway process; a different result is
  reported as `stranded: <first>, then <second> alone`. See skill
  `intel-gpu-fault-recovery`.
- `GPU fault at HH:MM:SS during: <tests>` lines name the tests running
  when the kernel log showed `Engine memory CAT error`.

### When and how to update the expectations

`plugins/intel/CONTRIBUTING.md`: "A change that moves a gate result updates
`tests/max-gpu-expected.txt` with the cause."

- Update the line of each test your change moves, in the same commit as
  the change, and state why in the commit message.
- A test that now passes: result `pass`, cause `-`. A test that now fails
  for a new reason: the result and a cause from the header, or a new cause
  added to the header with a one-line definition.
- Do not update the file for a result that comes from a different
  environment: another GPU, another IGC (the `igc` tests pass with newer
  IGC), a run with GPU faults, or an intermittent test. The Bessel tests
  (`test_j1_y1_gpu`, `test_bessel_huge_args_gpu`) can report `better`
  without a change.
- A `worse` result is a regression to fix, not to record, unless the cause
  is outside the plugins and documented (for example an upstream MAX
  change); then say so in the commit.
- Confirm a move with a second run of the affected tests (`-k <name>`)
  before editing the file.

## The greedy-text regression

The `text` step runs, with an opt build:

```sh
GEN_FIRST_ONLY=1 RUN_MAX_PY_OPT=1 plugins/intel/utils/run-max-py \
  plugins/intel/tests/graph/gen_repeat.py <qwen3.5-0.8b-dir> 1 64
```

and compares its `prompt <i>: 64 tokens: '<text>'` lines (four prompts)
with `plugins/intel/tests/regression/qwen3.5-0.8b-greedy.txt`; the diff
goes to `<outdir>/text.diff`.

- Identical text is the expected result on the B70 with the tested stack.
- Text turning into `Thinking!!!!...` is the IGC 2.42/2.43 attention NaN
  (`plugins/intel/docs/intel-tools-issues.md`); check the IGC version.
- A difference after a change that alters numerics (a kernel's reduction
  order, a different GEMM path) may be legitimate; it is still a
  regression until shown otherwise, for example with
  `tests/graph/hf_match.py` or by comparing against a reference
  implementation (not verified which tool the project uses for that).
- The fork does not document how to regenerate the reference. From
  `utils/check`, a new reference would be the `grep "^prompt "` lines of
  the command above; replace the file only with the contributor's
  agreement and the reason in the commit (not verified as project
  practice).

## Running checks on a shared GPU

- The gate runs 4 tests at once by default; other GPU users share the
  device with them and change timings. Use `-j 1` and `-k` to keep the
  load small, and say in any report that the GPU was shared.
- A fault in any process resets the engine for every process using it
  and makes the next process hang at its first wait (skill
  `intel-gpu-fault-recovery`). Other users' faults show up in `utils/check`'s
  fault count and in the gate's fault matching, and the gate's throwaway
  process runs on the GPU too.
- Never run `plugins/intel/tests/intel-tools/gpu-fault-next-process-hangs`
  on a shared GPU: it faults the GPU on purpose.
- Do not stop other users' processes or services to get a clean run;
  ask the contributor.
- `utils/check-spirv`, `check-codegen` and the build use no GPU and are
  safe anywhere.

## Pitfalls

- The check scripts use the launcher in `$INTEL_PLUGIN_BIN`; after a build
  in another configuration, rerun `make-mojo-launcher` or the scripts run a
  stale mojo.
- Without `journalctl -k` access, faults go unseen and stranded tests look
  like real timeouts.
- `check-max-gpu` and `check-e2e` expectations are for `intel:bmg-g31`.
  With `--accelerator` or on an integrated GPU, compare against a baseline
  run of the unchanged tree instead of the file.
- The compute-runtime kernel cache can change what you test when IGC
  changes; use an empty `NEO_CACHE_DIR` for IGC comparisons.

> [!TIP]
> Further reading (free, external; not maintained here):
> - [FileCheck](https://llvm.org/docs/CommandGuide/FileCheck.html): the `CHECK` pattern syntax and `--check-prefix`, as the gate applies them to MAX's tests.
> - [lit - LLVM Integrated Tester](https://llvm.org/docs/CommandGuide/lit.html): `RUN:` lines and the `%s`/`%t` substitutions the gate reads from MAX's lit tests.
> - [KhronosGroup/SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools): `spirv-val` and `spirv-dis`, used by `check-spirv` and `check-codegen`.
> - [SPIR-V Specification](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html): the instructions, capabilities and execution modes `check-codegen` looks for.
> - [journalctl(1)](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html): `-k` and `--since`, which the checks use to count GPU faults, and who may read the journal.

## References

- `plugins/intel/utils/check`, `check-max-gpu`, `check-e2e`,
  `check-codegen`, `check-device`, `check-targets`, `check-spirv`,
  `run-e2e`: headers and docstrings.
- `plugins/intel/tests/max-gpu-expected.txt`, `tests/regression/`.
- `plugins/intel/README.md` ("Checks"), `plugins/intel/CONTRIBUTING.md`
  ("Checks").
- Skills: `mojo-max-intel-build`, `intel-gpu-environment`,
  `intel-gpu-fault-recovery`, `intel-tool-bugs`.
