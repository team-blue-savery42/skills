---
name: intel-tool-bugs
description: Handle a bug in Intel's GPU tools (IGC, compute-runtime, Level Zero loader, kernel driver) that shows up in Mojo or MAX on an Intel GPU, such as a wrong result, an IGC crash in ocloc or zeModuleCreate, or a fault, by checking the known issues, telling IGC from compute-runtime, reducing to a Mojo-free reproduction, writing it up under tests/intel-tools, and choosing between a plugin workaround and waiting for a fix.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Bugs in Intel's GPU tools

Use this when a Mojo program or MAX test on an Intel GPU gives a wrong
result, crashes in module creation, or hangs, and the Mojo side (the
compiler plugin's SPIR-V, the driver plugin, the kernel) looks right.
Commands run in the fork's checkout (`<fork>`) unless they say otherwise.
The tested stack is in `plugins/intel/README.md`; results on other stacks
are findings, not regressions.

## 1. Check the known issues first

Read `plugins/intel/docs/intel-tools-issues.md`. Its index has four
tables: open on the tested stack and the newest releases, fixed in newer
releases, regressions in newer IGC, resolved. Each row names the
component, symptom, affected versions, the fixing commit, what the plugins
do, and a reproduction. Match on the symptom, not only the kernel: one IGC
bug shows up in many MAX tests (`tests/max-gpu-expected.txt` marks those
`igc`).

Then run the matching reproduction, on the stack in question:

```sh
sh plugins/intel/tests/intel-tools/<slug>/run.sh
```

Each `run.sh` states what it needs (`clang` with `spirv64`, `spirv-val`,
`spirv-as`, `ocloc`, `clang++`, a GPU) and works in a temporary directory.
Those that need no GPU build with `ocloc` only. **Do not run
`gpu-fault-next-process-hangs` on a GPU anyone else uses**: it faults the
GPU on purpose (skill `intel-gpu-fault-recovery`).

If the reproduction gives the "affected" result, the issue is known: use
its workaround or knob and stop. If your symptom matches none, go on.

## 2. First knobs: is it IGC's optimizer?

Every knob below acts only when IGC really compiles the kernel.
compute-runtime caches built binaries; a cached kernel skips IGC, so
settings and dumps do nothing. Always add `NEO_CACHE_PERSISTENT=0`, or
point `NEO_CACHE_DIR` at an empty directory (and, for MAX,
`MODULAR_CACHE_DIR` too).

| Knob | What it does |
|---|---|
| `MOJO_INTEL_IGC_OPTIONS=-cl-opt-disable` | the driver plugin appends this to its IGC options (`driver/Module.cpp`, `buildFlags`): no IGC optimization. Its comment also names `-ze-opt-level=1`. |
| `IGC_EnableVectorizer=0` | turns IGC's vectorizer off; an `ALWAYS` setting in `IGC/common/igc_flags.h`, so release builds read it |
| `IGC_ShaderDumpEnable=1 IGC_DumpToCustomDir=<dump-dir>` | writes, per module: `.spv` (the SPIR-V IGC got), `_options.txt` and `_internal_options.txt` (the options it really got), LLVM IR stages (`_beforeUnification.ll` ... `_optimized.ll`, `_codegen.ll`), `.zeinfo`, `.visaasm` and `.asm` (ISA, with `//.git-hash` naming the IGC commit) |
| `IGC_ShaderDumpEnableAll=1` | the IR after every pass (also an `ALWAYS` setting); many files |

The driver plugin's own options are
`-ze-intel-enable-auto-large-GRF-mode -cl-fp32-correctly-rounded-divide-sqrt`
(`kBuildFlags` in `plugins/intel/driver/Module.cpp`); use them in every
offline build so IGC compiles what MAX compiles.

A result that is right with `-cl-opt-disable` and wrong without points at
IGC's optimizer, not at the kernel. `-cl-opt-disable` is a diagnosis, not a
workaround: it disables every optimization.

An IGC built with assertions (skill `intel-stack-from-source`) stops at the
first broken invariant, where a release IGC may go on and miscompile. A
crash or wrong result is worth one run on such a build; remember that it
can also stop at assertions a release build passes harmlessly.

## 3. Get the exact SPIR-V MAX feeds IGC

Dump the failing run with the variables above. Each module's `.spv` is the
SPIR-V IGC received, and `_options.txt` the options. Find the kernel by
name in the `.spvasm` or `.zeinfo`, then check and build it alone:

```sh
spirv-val <dump-dir>/<module>.spv
plugins/intel/utils/check-spirv <dump-dir>/<module>.spv     # spirv-val, entry points, ocloc
ocloc compile -spirv_input -file <module>.spv -device bmg-g31 \
  -options "-ze-intel-enable-auto-large-GRF-mode -cl-fp32-correctly-rounded-divide-sqrt" \
  -output <name>
```

`check-spirv` passes only `-ze-intel-enable-auto-large-GRF-mode`; use the
`ocloc` line for the plugin's full option set. `ocloc` needs no GPU and no
Mojo, and loads the same IGC as compute-runtime. An IGC crash usually
reproduces this way: `ocloc` exits 245 for a floating point exception and
139 for a segfault, and prints "Internal Compiler Error". A miscompile
needs the kernel to run.

`plugins/intel/utils/run-max-py` also takes `RUN_MAX_PY_ENV` (its header
gives `MODULAR_DEBUG=ir-output-dir=<dir>` as an example); what that writes
for the Intel target was not verified here. The IGC dump is enough.

## 4. IGC or compute-runtime?

Run the reproduction with one stack's IGC and the other stack's
compute-runtime, both ways (skill `intel-stack-from-source`, "Mix one
stack's IGC with another's compute-runtime"). The result follows the
component that changed it. For every IGC issue in the known-issues file
the result followed the IGC; for the hang after a page fault it followed
neither, which pointed to compute-runtime, the `xe` driver or the GuC
firmware. Kernel driver and firmware problems go to skill
`xe-bug-report-collect`.

Clues without a mix: an `ocloc` crash is IGC (or the SPIR-V); a host
segfault inside `zeCommandListHostSynchronize` or a wrong printf is
compute-runtime territory (see "compute-runtime reads a printf `%s`
argument as a host address"); a crash only with
`ZE_ENABLE_VALIDATION_LAYER=1` is the loader's layer (see "Level Zero: the
packaged validation layer crashes at load").

## 5. Reduce to a reproduction without Mojo

The goal is a few files anyone can run with public tools.

1. **Shrink the SPIR-V.** `spirv-dis` the dumped module, keep one kernel,
   and cut it down while `ocloc` (crash) or the runner (wrong result) still
   shows the bug. Reassemble with `spirv-as` and check with `spirv-val`
   after every step. The vector compare crash's reproduction is a whole
   17 KB module from the plugin; a smaller one is better.
2. **Or write it again, small.** Hand-written LLVM IR is usually clearest:

   ```sh
   clang -target spirv64 -Wno-override-module -c <kernel>.ll -o <kernel>.spv
   clang -target spirv64 -Wno-override-module -mllvm --spirv-ext=+SPV_KHR_abort -c trap.ll -o trap.spv  # extensions
   clang -target spirv64 -cl-std=CL2.0 -O2 -c <kernel>.cl -o <kernel>.spv               # OpenCL C
   spirv-as <kernel>.spvasm -o <kernel>.spv                                             # SPIR-V assembly
   spirv-val <kernel>.spv
   ```

   Use the IR shape the plugin emits (from the dump's `_beforeUnification.ll`
   or the plugin's output), since IGC bugs often depend on it: vector width,
   uniform versus per-lane values, struct arguments by value, a leading
   `extractvalue`. SPIR-V assembly is the way to use types or extensions
   clang does not produce (for example `SPV_KHR_bfloat16`).
3. **A small Level Zero host program** for wrong results. Either
   `plugins/intel/utils/l0/run.sh <module.spv> <kernel-name-substring> [<global> <local> [<count>]]`
   (one argument: a zeroed buffer of 1024 `int32` whose first word is 7;
   prints the first `count` words and the kernel's printf output), or a
   runner of your own like `tests/intel-tools/*/run-*.cpp`: load the module
   with the plugin's options and again with `-cl-opt-disable` appended,
   compute the right answer on the host, and print wrong lanes with counts.
   Build: `clang++ -O1 -std=c++17 run-<name>.cpp -o run-<name> -lze_loader`.
4. **Make hidden state visible.** Some wrong results depend on what ran
   before: run a kernel that fills registers first (the leftover vector
   `fabs` reproduction runs `alone`, `after-fill` and `after-idle`), and put
   guard zones around buffers to catch stray stores.
5. **Record the matrix**: default build, `-cl-opt-disable`, any IGC knob
   that changes it, and every IGC version you can run (tested stack and
   source-built ones, skill `intel-stack-from-source`). Run with
   `NEO_CACHE_PERSISTENT=0`.

Automatic reducers can do step 1 or 2 for you, given a script that
exits 0 while the bug is still there (`ocloc` exits 245, or the runner
prints a wrong lane): `llvm-reduce --test=<script> <kernel>.ll` for LLVM
IR, `spirv-reduce` from SPIRV-Tools for SPIR-V binaries. The existing
reproductions were reduced by hand; these tools were not tried on them.

If no small kernel reproduces it (as for "IGC: float64 to float32 on
4-wide vectors page-faults"), say so in the write-up and keep the Mojo
reproduction.

> [!TIP]
> Further reading (free, external; not maintained here):
> - [IGC: Producing shader dumps](https://github.com/intel/intel-graphics-compiler/blob/master/documentation/shader_dumps_instruction.md): what `IGC_ShaderDumpEnable` writes and in which order, including the `.spv` IGC received.
> - [IGC: Configuration flags for Linux Release](https://github.com/intel/intel-graphics-compiler/blob/master/documentation/configuration_flags.md): every `IGC_*` setting a release build reads, generated from `igc_flags.h`.
> - [compute-runtime: Compiler Cache](https://github.com/intel/compute-runtime/blob/master/programmers-guide/COMPILER_CACHE.md): `NEO_CACHE_PERSISTENT`, `NEO_CACHE_DIR` and the other cache keys, and why a cached kernel skips IGC.
> - [SPIR-V specification](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html): the instructions and validity rules to check a reduced module against.
> - [Khronos SPIR-V Registry](https://registry.khronos.org/SPIR-V/): the extension specifications (`SPV_KHR_*`, `SPV_INTEL_*`) a module declares.
> - [LLVM: User guide for the SPIR-V target](https://llvm.org/docs/SPIRVUsage.html): `clang -target spirv64`, `--spirv-ext` and the extensions LLVM's backend emits.
> - [llvm-reduce](https://llvm.org/docs/CommandGuide/llvm-reduce.html) and [SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools) (`spirv-as`, `spirv-val`, `spirv-reduce`): automatic reduction of LLVM IR and SPIR-V test cases.
> - [LLVM: How to submit a bug report](https://llvm.org/docs/HowToSubmitABug.html): reducing a compiler bug to a small test case; the method carries over to IGC.

## 6. Write it up in `tests/intel-tools/<slug>/`

- **Slug:** component prefix and the symptom: `igc-...`,
  `compute-runtime-...`, `level-zero-...`, `llvm-spirv-...`.
- **README.md:** start from [`README-template.md`](README-template.md). What
  the files are and what they show; how to run (`sh run.sh`) and what it
  needs; "Expected and actual" with trimmed output and a versions table;
  then "Fixed in" (commit, subject, date, first tag) or "Cause and patch"
  (function and file in IGC, what the patch changes, which IGC it is
  against). State what was not measured.
- **run.sh:** POSIX `sh`, `set -u`, `here=$(cd "$(dirname "$0")" && pwd)`,
  a `mktemp -d` work directory removed by `trap`, a header comment with what
  it does and what it needs ("no GPU" when true), `NEO_CACHE_PERSISTENT=0`
  on every GPU run, and exit statuses and wrong counts printed rather than
  hidden.
- **License headers:** every new source file (`run.sh`, `.ll`, `.spvasm`,
  `.cl`, `.cpp`) carries the Apache-2.0 with LLVM exceptions header in the
  comment syntax of the file, copy it from a neighbour, with a copyright
  line naming the file's author (`plugins/intel/CONTRIBUTING.md`).
  `fix.patch` is a diff against IGC's tree and, like IGC, under the MIT
  license; it gets no header. Binary `.spv` files and the README have none.
- **The known-issues file:** add a row to the right table in
  `plugins/intel/docs/intel-tools-issues.md` and a section with the same
  title as the README: what goes wrong, how it shows in Mojo, the versions
  table, the workaround (or "none"), and a link to the reproduction.
- **Expected test results:** a MAX test that fails because of it is marked
  `igc` in `plugins/intel/tests/max-gpu-expected.txt`, with the cause (skill
  `intel-plugin-checks`).
- **Commit:** one commit, module `intel/tests` (or `intel/docs` for the
  known-issues text alone), signed off (`plugins/intel/CONTRIBUTING.md`).

## 7. Workaround in the plugins, or wait?

Work around it in a plugin when the tested IGC is affected, real Mojo or
MAX code hits it, and there is a rewrite that avoids the pattern without
large cost. The existing ones show the range: splitting aggregate phis,
flattening nested struct arguments, moving bfloat16 as `i16`, splitting
128-bit integers, and reporting `abort` through a host flag
(`intel-tools-issues.md`, "What the plugins do"; skill
`intel-compiler-plugin`).

- A workaround stays while the tested IGC needs it, even when newer IGC is
  fixed. Check each newer IGC with the reproduction, not by removing the
  workaround, and record which versions still need it.
- Keep it in the Intel plugin and specific to Intel; pan-hardware logic
  belongs above the HAL (`AGENTS.md`).
- Do not upgrade IGC to avoid one bug without running the rest:
  IGC 2.42 and 2.43 fix several miscompiles and break MAX's paged flash
  attention ("IGC 2.42 and 2.43: NaN in paged FA").
- When no cheap rewrite exists, leave the plugins alone, mark the affected
  tests, document the bug, and say whether a newer IGC fixes it.
- A candidate patch to IGC is welcome as `fix.patch`, tested on a source
  build (skill `intel-stack-from-source`), with IGC's lit tests run if you
  can.

To find which IGC commit fixed or caused it, use skill `igc-bisect`.

## 8. Draft the upstream report

Only when the contributor asks; never submit it yourself. Follow skill
`agent-issues-and-prs`: the draft starts with the mandatory agent note
from `AGENTS.md`, verbatim, and only a human removes it.

Where: IGC at https://github.com/intel/intel-graphics-compiler/issues,
compute-runtime at https://github.com/intel/compute-runtime/issues, the
loader at https://github.com/oneapi-src/level-zero/issues; kernel driver
problems through skill `xe-bug-report-collect`.

What it contains, short and checkable:

- Title: component and symptom, as in the known-issues file.
- Environment: GPU and `ocloc` device, kernel and driver, IGC,
  compute-runtime and loader versions (and the IGC commit from the dump's
  `//.git-hash` for source builds).
- The Mojo-free reproduction attached or inlined (the `.ll`/`.spvasm` and
  the runner), the exact commands, expected and actual output.
- The versions table and the IGC/compute-runtime mix result.
- If bisected: the commit, its parent's result, and the range.
- A candidate patch, if any, with what it was tested on.
- No Mojo or MAX build needed to reproduce; mention Mojo only as where it
  was found.

Redact host names, user names, home paths and serial numbers from any
pasted output (`AGENTS.md`, ground rule 5).

> [!TIP]
> Further reading (free, external; not maintained here):
> - [IGC issues](https://github.com/intel/intel-graphics-compiler/issues), [compute-runtime issues](https://github.com/intel/compute-runtime/issues), [Level Zero loader issues](https://github.com/oneapi-src/level-zero/issues): search for an existing report before drafting one.
> - [C-Reduce](https://github.com/csmith-project/creduce): a test-case reducer for C and C++ sources (its README says it often works on other languages too), for OpenCL C kernels when a hand reduction stalls; not tried here.

## Pitfalls

- A warm compute-runtime cache hides IGC changes and makes settings and
  dumps do nothing; it also changes timing, which once decided whether
  uninitialised registers held right values.
- compute-runtime rewrites some options before IGC sees them; trust the
  dump's `_options.txt`, not the command line.
- `ocloc` loads `libigc.so.2` by name: under a mixed or source-built
  stack, check which one it loaded (skill `intel-stack-from-source`).
- A page fault can make the next process on the GPU hang; run a throwaway
  process after a faulting reproduction (skill `intel-gpu-fault-recovery`).
- A result on an assertion build that differs from a release build may be
  the assertion, not the bug.
- Do not report performance or correctness you did not run on the GPU
  (`AGENTS.md`, ground rule 2).

## References

- In the fork: `plugins/intel/docs/intel-tools-issues.md`,
  `plugins/intel/tests/intel-tools/*/`, `plugins/intel/utils/l0/`,
  `plugins/intel/utils/check-spirv`, `plugins/intel/driver/Module.cpp`,
  `plugins/intel/README.md`, `plugins/intel/CONTRIBUTING.md`.
- Skills: `intel-stack-from-source`, `igc-bisect`, `intel-compiler-plugin`,
  `intel-plugin-checks`, `intel-gpu-fault-recovery`,
  `xe-bug-report-collect`, `agent-issues-and-prs`.
