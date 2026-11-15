---
name: intel-compiler-plugin
description: Work on the Intel Mojo codegen plugin (plugins/intel/compiler, IntelCompilerPlugin.so) that lowers kernels to OpenCL SPIR-V for IGC with LLVM's SPIR-V backend. Use when adding or fixing an IR rewrite, debugging a kernel that IGC rejects, miscompiles or hangs on, or reading the SPIR-V the plugin emits.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Intel compiler plugin

The plugin turns the LLVM module Mojo produces for an `intel:` target into
one SPIR-V binary that Level Zero hands to IGC, Intel's driver compiler, at
module load. Most of its code is IR rewrites that work around what LLVM's
SPIR-V backend cannot emit or what IGC gets wrong. Paths are relative to the
fork's root; the plugin lives in `plugins/intel/compiler/`.

It assumes a build of `//plugins/intel/...` and `//Mojo:mojo` (skill
`mojo-max-intel-build`) and, for anything that loads a binary, an Intel GPU
host set up as in skill `intel-gpu-environment`.

## Where it hooks in

- `Plugin.cpp` exports `M_KGEN_getTargetTraits`, `M_KGEN_getTargetLowering`
  and `M_KGEN_getTargetBackend`. The Mojo compiler `dlopen`s the library named
  in `MODULAR_COMPILER_PLUGINS`. The signatures are in
  `Mojo/lib/Target/max_license/Plugin/PluginTraits.cpp`,
  `Mojo/lib/KGENToLLVM/Target/max_license/Plugin/PluginLowering.cpp` and
  `Mojo/lib/Compiler/ObjectCompiler/Target/max_license/Plugin/PluginBackend.cpp`:
  read them, they change.
- `IntelTraits` (`IntelTraits.h`): target `intel`, triple `spirv64`,
  extensions `.spvasm`/`.spv`, stack allocations in Mojo's LOCAL space.
- `IntelLowering` (`IntelLowering.cpp`): marks void exported functions
  `spir_kernel`, passes in-memory struct kernel arguments `byval`, and
  accepts and drops MAX's `pop.intel.max_work_group_size` hint.
- `IntelBackend` (`IntelBackend.cpp`), derived from `HostBackend`:
  - no module splitting (`SplitStrategy::None`): one SPIR-V module holds the
    kernels and everything they call; `createArchive` expects exactly one
    object;
  - drops the accelerator arch (`bmg-g31`) and the plugin's own target
    feature (`+sub-group-size-32`) before LLVM sees them;
  - `finalizeModuleForTarget` (before LLVM's optimizer): sub-group sizes,
    `convergent` marking, address-space renumbering, `__mojo_intel_abort`.
    It cannot return an error, so it records one as `mojo.intel.error`
    named metadata, which the emit hooks turn into an error;
  - `prepareForCodegen` (after the optimizer, before `llc`): the rest of the
    rewrites, in an order the comments in that function explain;
  - `emitObject` runs the host's `llc` (`ctx.runLlc`), checks the SPIR-V
    magic and renames extensions IGC spells differently (`SPIRVBinary.h`).
- The target table is in MAX: `max/mojo/max/_plugin/intel/targets.mojo`
  (`bmg-g31`, `bmg-g21`, their `-sg32` variants, `rpl-p`, `arl-s`; triple,
  data layout, features). The stdlib and MAX hooks the kernels call are in
  `Mojo/stdlib/std/_plugin/intel/` and `max/mojo/max/_plugin/intel/`.
- Patches to LLVM's SPIR-V backend live in
  `bazel/public-patches/llvm-spirv-*.patch`; `test/SPIRVBackendPatchTest.cpp`
  fails (aborts in the debug build) when one is missing.

## The rewrites and why

Each pass has a header that states the IGC or backend failure it exists for;
read it before changing the pass. Summary, in the files' own terms:

| File | What it does | Why |
|------|--------------|-----|
| `SubgroupSize` | `intel_reqd_sub_group_size` 16, or 32 for `+sub-group-size-32` | IGC would pick SIMD8/16/32 per kernel; `WARP_SIZE` is a compile-time constant |
| `Convergent` | marks OpenCL group built-ins and their callers `convergent` | the optimizer duplicated barriers into divergent paths |
| `RemapAddressSpaces` | Mojo address spaces to SPIR-V numbering (`IntelAddressSpace.h`), generic kernel pointers as `CrossWorkgroup`, `llvm.stepvector` expansion, cast and aggregate-pointer fix-ups, zero-length-array GEPs | the backend reads LLVM address spaces as OpenCL storage classes; several constructs fail `spirv-val` |
| `Abort` | defines `__mojo_intel_abort` storing to the exported `__mojo_intel_abort_flag`; `returnAfterAbort` unwinds an aborting work-item to the kernel | IGC has no trap (rejects `SPV_KHR_abort`) |
| `ZeroLengthArrays` (`rewriteArrayParameters`) | kernel parameters holding arrays, nested aggregates, `i1` or bfloat16 become a flat struct of leaves with the same byte layout | IGC rejects array kernel arguments, misreads nested structs, hung on `bool` fields; `[0 x T]` became `OpTypeRuntimeArray` |
| `NestedStructArguments` | nested by-value struct arguments and results of internal functions passed as flat structs | IGC passed fields wrongly between functions |
| `PromoteBFloat16` | bfloat16 math in float32; bfloat16 values moved as `i16`; conversions as integer code | SPIR-V bfloat16 has no arithmetic; IGC got bfloat16 selects, phis and rounding wrong |
| `WideVectors` | scalarizes functions using vectors over 16 elements | OpenCL SPIR-V allows at most 16 |
| `MaskBitcasts` | removes `<N x i1>` to `iN` bitcasts for N not 8/16/32/64; expands `trunc` to `<N x i1>` | `i2`/`i4` made IGC crash or loop; the backend mistyped the truncation |
| `ConstantMemory` | gives host-filled constant-space globals zeros and an export | IGC took them for unresolved imports |
| `Heap` | defines `malloc`/`free`/`realloc` over the exported `__mojo_intel_heap` | IGC links no device heap |
| `Int128` | splits every `i128` into two `i64` halves; refuses what it cannot split | IGC computes 128-bit arithmetic wrongly |
| `AggregatePhis` | one scalar phi per leaf of struct/array phis | IGC lost values merged by aggregate phis |
| `DynamicSharedMemory` | external `Workgroup` globals become a trailing `ptr addrspace(3)` parameter | OpenCL has no `extern __shared__`; the driver sizes it per launch |

The abort flag, heap global, constant imports and the trailing shared-memory
parameter are contracts with the driver plugin (skill `intel-driver-plugin`):
change both sides together. `plugins/intel/docs/intel-tools-issues.md` has a
reproduction of each IGC bug under `plugins/intel/tests/intel-tools/`.

## Invariants: floating-point constants and intrinsics

The pass comments (`PromoteBFloat16.cpp` top, `Int128.cpp`, `WideVectors.h`,
`AggregatePhis.h`, `ConstantMemory.h`, `NestedStructArguments.cpp`,
`IntelBackend.cpp` `dump`) state that the plugin links its own copy of
LLVM, that `APFloat` identifies a float format by the address of its
semantics object, and that a float constant created or folded in the plugin
would trip the host's "unknown format" assertion. The existing passes
therefore:

- build IR with `IRBuilder<NoFolder>` and never fold;
- never create a floating-point constant (zeros included: a float scalar in
  `ConstantMemory` becomes a one-element array; `WideVectors` moves float
  vector constants into private globals before scalarizing); integer
  constants are fine;
- never read a host float constant's value except `PromoteBFloat16`'s
  `bf16Bits`, which turns it into an integer constant;
- never print IR from the plugin (use Mojo's `emission_kind="llvm-opt"`).

Intrinsic declarations: `Int128.h` and `PromoteBFloat16.h` say their
rewrites declare no intrinsic, but `PromoteBFloat16.cpp`'s
`promoteIntrinsic` does call `Intrinsic::getOrInsertDeclaration` for the
float32 form of a math intrinsic. So "no new intrinsic declarations" is a
property of some passes, not a rule the whole plugin keeps.

Check the premise before relying on it: `compiler/BUILD.bazel` now links the
plugin against `mojo`'s shared libLLVM and libMLIR (`dynamic_deps`), and the
commit that did so says the plugin and compiler share one LLVM and one set of
APFloat semantics. The comments above predate that. Until they are updated,
follow the existing rules in new code; they cost little and keep the passes
uniform.

## Adding a rewrite

1. Reproduce: a minimal Mojo kernel, its SPIR-V (below), and the IGC or
   `spirv-val` failure. If IGC is at fault, add a reproduction under
   `plugins/intel/tests/intel-tools/` and an entry in
   `docs/intel-tools-issues.md` (skill `intel-tool-bugs`).
2. New `Foo.h`/`Foo.cpp` in `compiler/`, namespace `M::KGEN::Intel`, with a
   file header that names the failure, the IGC version and the shape of IR
   it fixes. Prefer one exported function per rewrite returning `bool`
   (changed) or `llvm::Expected<bool>` when it can refuse input.
3. Add it to `IntelPasses` in `compiler/BUILD.bazel` and call it from
   `finalizeModuleForTarget` (must run before the optimizer) or
   `prepareForCodegen` (must see optimized IR). Respect the ordering notes
   there: `rewriteArrayParameters` first, `lowerInt128` after every pass
   that adds instructions, `splitAggregatePhis` after every pass that adds
   phis, `addDynamicSharedMemoryParameter` last.
4. Refuse what you cannot rewrite with an error naming the value, rather
   than letting it reach IGC (see `Int128`, `MaskBitcasts`).
5. Unit test `test/FooTest.cpp` plus a `modular_cc_test` in `BUILD.bazel`.
6. If it is visible in SPIR-V, add a kernel to `tests/codegen/kernels.mojo`
   and a check line to `utils/check-codegen`; if it changes behaviour on
   the GPU, an end-to-end probe in `tests/e2e/`.
7. `./bazelw run //:format`; commit as `intel/compiler: ...`
   (`plugins/intel/CONTRIBUTING.md`).

## Tests

Unit tests need no GPU. They parse hand-written IR with
`parseAssemblyString` (triple `spirv64-unknown-unknown`, the target's data
layout), run the pass, verify the module and check the result; some
evaluate the rewritten IR against the original (`MaskBitcastsTest.cpp`) or
run it through the SPIR-V backend in process.

```sh
./bazelw test //plugins/intel/compiler/...
./bazelw test //plugins/intel/compiler:Int128Test
```

The codegen corpus compiles `tests/codegen/kernels.mojo` for `bmg-g31` (and
one kernel for `bmg-g31-sg32`) and checks each binary's disassembly for the
instruction it exists to exercise, then runs `utils/check-spirv` on it. It
needs a built `//max/mojo/max:max` and the launcher from
`utils/make-mojo-launcher` (location `INTEL_PLUGIN_BIN`), and uses a fresh
`MODULAR_CACHE_DIR` so the plugin always runs:

```sh
sh plugins/intel/utils/make-mojo-launcher
plugins/intel/utils/check-codegen
```

`plugins/intel/utils/check` runs these with everything else (skill
`intel-plugin-checks`).

## Inspecting SPIR-V

- Dump what the plugin emits: `MOJO_INTEL_PLUGIN_DUMP=<dir>` writes every
  module as `<name>.<n>.bc` (before `llc`; `llvm-dis` prints it) and
  `<name>.<n>.spv`. `MOJO_INTEL_PLUGIN_TRACE=1` logs the plugin's steps to
  stderr. Use a fresh `MODULAR_CACHE_DIR`, or cached kernels are not
  recompiled.
- One kernel from Mojo: `compile_info[kernel, target=...,
  emission_kind="object"]().asm` gives the binary, the default emission the
  assembly (see `emit` in `tests/codegen/kernels.mojo`). SPIR-V extensions
  can be added per compile with `compile_options="spirv-ext=+SPV_..."`.
- Disassemble and validate: `spirv-dis k.spv -o k.dis`;
  `spirv-val --target-env spv1.4 k.spv`.
- What IGC makes of it: `plugins/intel/utils/check-spirv k.spv [device]`
  runs `spirv-val`, requires a kernel entry point, and compiles with
  `ocloc compile -spirv_input -file k.spv -device bmg-g31` and the driver's
  auto large-GRF option. The driver also passes
  `-cl-fp32-correctly-rounded-divide-sqrt` (`driver/Module.cpp`,
  `kBuildFlags`), which `check-spirv` does not, so a result that depends on
  it can differ.
- IGC's own ISA: skill `intel-performance`.

## Pitfalls

- The plugin returns C++ objects to `mojo`: build it from the same commit
  and configuration as the `mojo` that loads it (`compiler/BUILD.bazel`).
- A pass that runs before the optimizer can be undone by it (constant-expr
  casts fold back; bitcast pairs fold away). Put such rewrites in
  `prepareForCodegen`.
- `dropUnusedAbortFlag` exists because the optimizer can remove every abort:
  an export without its global makes the driver fail to load the module.
- DPAS and 2D block I/O kernels must stay at sub-group size 16: `ocloc`
  crashed on DPAS at 32 (`max/mojo/max/_plugin/intel/targets.mojo`), and
  the block I/O client extension is defined for 16
  (`tests/e2e/block_io_reject.mojo`).
- Integrated-GPU IGC rejects DPAS and 2D block I/O: the corpus `dpas` and
  `block_io` kernels compile only for Xe2.
- IGC 2.42 and 2.43 give NaN in MAX's paged flash attention; do not change
  IGC to fix a codegen issue without running `tests/graph/attention.py`
  (skill `intel-tool-bugs`).

## References

- `plugins/intel/README.md`, `plugins/intel/CONTRIBUTING.md`
- `plugins/intel/compiler/*.h` (one header per rewrite),
  `IntelBackend.cpp` (`prepareForCodegen` order)
- `plugins/intel/docs/intel-tools-issues.md` and `tests/intel-tools/`
- `plugins/intel/utils/check-codegen`, `utils/check-spirv`
- `max/mojo/max/_plugin/intel/targets.mojo`
- `bazel/public-patches/llvm-spirv-*.patch`
- Skills: `intel-driver-plugin`, `intel-plugin-checks`, `intel-tool-bugs`,
  `intel-performance`, `igc-bisect`
