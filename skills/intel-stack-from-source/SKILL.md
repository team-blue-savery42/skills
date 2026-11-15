---
name: intel-stack-from-source
description: Build Intel's GPU compute stack (IGC, compute-runtime/NEO, gmmlib, Level Zero loader) from source at matching versions into a private prefix, run a program on it without touching the system packages, mix one stack's IGC with another's compute-runtime, and check which libraries a process really loaded.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Intel's GPU stack from source

Use this when you need an IGC or compute-runtime other than the installed
one: to see whether a bug is fixed in a newer release, to read IGC's
assertions, to test a patch to IGC, or to tell an IGC change from a
compute-runtime one. The system packages stay the reference: the plugins'
expected results (`plugins/intel/tests/max-gpu-expected.txt`) are those of
the tested stack in `plugins/intel/README.md`. A result on another stack is
a finding, not a regression.

Nothing here needs root. Everything is built into `<prefix>` and selected
per process through environment variables. Placeholders: `<src>` (source
checkouts), `<build-dir>` (build trees), `<prefix>` (install), `<cache>`
(compute-runtime binary caches).

## 1. Pick matching versions

Start from compute-runtime and let it name the rest.

1. **compute-runtime.** List tags with
   `git ls-remote --tags https://github.com/intel/compute-runtime`. A tag
   may exist weeks before its GitHub release page.
2. **IGC, gmmlib, Level Zero loader.** The compute-runtime tag's
   `manifests/manifest.yml` names them (`igc`, `gmmlib`, `level_zero`
   entries, each with `branch` and `revision`). Its
   `documentation/BUILD.md` says the same. Example from tag 26.44.40734.8:
   IGC `v2.43.9` (branch `releases/2.43.x`), gmmlib `intel-gmmlib-22.10.2`,
   level_zero `v1.34.0`.
3. **IGC's dependencies.** Read them from the IGC commit itself:
   - LLVM: `external/llvm/llvm_preferred_version.cmake`
     (`DEFAULT_IGC_LLVM_VERSION`, e.g. `22.1.8` for v2.42.14 and v2.43.9),
     tag `llvmorg-<version>`.
   - opencl-clang, SPIRV-LLVM-Translator, vc-intrinsics, SPIRV-Tools,
     SPIRV-Headers: the "Revision table" in `documentation/build_ubuntu.md`.
     For LLVM 22: opencl-clang `ocl-open-220`, translator
     `llvm_release_220`, the others `master`/`main`.
   - A published IGC release's notes have a "Dependencies revisions"
     table with exact commits; use it when it exists. For tags without
     release notes, take each branch's last commit before the IGC tag's
     commit date (what Intel's CI built it with; `.github/workflows/build-IGC.yml`
     shows which branches CI uses).
4. Write the result down as a table: component, repository, ref, commit.
   Check out commits, not branch names, so the stack can be rebuilt.

Pairing IGC master with compute-runtime master worked for the stacks built
so far; if it does not, use the IGC commit that compute-runtime's manifest
names.

## 2. Build

Order: loader, gmmlib, IGC, compute-runtime. Common CMake options for all
four:

```sh
common="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH=<prefix>"
```

**Level Zero loader and gmmlib:** plain CMake builds.

```sh
cmake -S <src>/level-zero -B <build-dir>/level-zero $common
cmake --build <build-dir>/level-zero -j <jobs> && cmake --install <build-dir>/level-zero
cmake -S <src>/gmmlib -B <build-dir>/gmmlib $common
cmake --build <build-dir>/gmmlib -j <jobs> && cmake --install <build-dir>/gmmlib
```

Skip gmmlib when the system's is the version the manifest names.

**IGC.** Lay out the workspace as `documentation/build_ubuntu.md` does:

```text
<ws>/igc                                   intel-graphics-compiler
<ws>/vc-intrinsics
<ws>/SPIRV-Tools
<ws>/SPIRV-Headers
<ws>/llvm-project                          tag llvmorg-<llvm>
<ws>/llvm-project/llvm/projects/opencl-clang
<ws>/llvm-project/llvm/projects/llvm-spirv  SPIRV-LLVM-Translator
```

```sh
# IGC adds -Werror with no option to turn it off; newer GCC warns more.
sed -i 's/ALIAS TreatWarnAsErrorEnabled    "-Werror"/ALIAS TreatWarnAsErrorEnabled/' \
  <ws>/igc/IGC/CMakeLists.txt
CFLAGS=-fno-semantic-interposition CXXFLAGS=-fno-semantic-interposition \
LDFLAGS=-Wl,-Bsymbolic \
cmake -S <ws>/igc -B <build-dir>/igc $common \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DIGC_OPTION__LLVM_MODE=Source -DIGC_OPTION__LLVM_PREFERRED_VERSION=<llvm> \
  -DIGC_OPTION__CLANG_MODE=Source -DIGC_OPTION__LLD_MODE=Source \
  -DIGC_OPTION__SPIRV_TOOLS_MODE=Source \
  -DIGC_OPTION__USE_PREINSTALLED_SPIRV_HEADERS=OFF \
  -DIGC_OPTION__VC_INTRINSICS_MODE=Source \
  -DIGC_OPTION__LINK_KHRONOS_SPIRV_TRANSLATOR=ON -DCCLANG_FROM_SYSTEM=OFF
cmake --build <build-dir>/igc -j <jobs> && cmake --install <build-dir>/igc
```

- IGC builds its own patched copy of LLVM inside its build tree and links
  it statically.
- `-fno-semantic-interposition` and `-Wl,-Bsymbolic` keep `libigc`'s LLVM
  symbols bound inside it. A Mojo or MAX process carries its own LLVM;
  without them the two can resolve to each other's symbols.
- Check that the `sed` matched (`grep TreatWarnAsErrorEnabled
  <ws>/igc/IGC/CMakeLists.txt`); the whitespace in the pattern is the
  file's at the IGC versions above.

**IGC with assertions** (release optimization, LLVM's and IGC's asserts,
and IGC's `DEBUG_ONLY` settings honoured): add

```sh
  -DLLVM_ENABLE_ASSERTIONS=ON \
  "-DCMAKE_C_FLAGS_RELEASE=-O3 -UNDEBUG -D_INTERNAL" \
  "-DCMAKE_CXX_FLAGS_RELEASE=-O3 -UNDEBUG -D_INTERNAL"
```

`IGC_ASSERT` is `assert` (`IGC/Probe/Assertion.h`); `-UNDEBUG` comes after
IGC's own `-DNDEBUG` on each command line. `_INTERNAL` enables settings IGC
guards with `defined(_DEBUG) || defined(_INTERNAL)`. An assertion build can
stop at an assertion that a release build passes and computes correctly, so
compare results with a release build, as the packages are.
`nm -D --undefined-only <prefix>/lib/libigc.so.2 | grep -c __assert_fail`
is 1 on an assertion build and 0 on a release build.

**compute-runtime (NEO)** against the prefix (its `documentation/BUILD.md`,
"Building without root access"):

```sh
cmake -S <src>/compute-runtime -B <build-dir>/compute-runtime $common \
  -DNEO_SKIP_UNIT_TESTS=1 -DIGC_DIR=<prefix> -DGMM_DIR=<prefix> \
  -DOCL_ICD_VENDORDIR=<prefix>/etc/OpenCL/vendors \
  -DLEVEL_ZERO_ROOT=<prefix> -DLevelZero_INCLUDE_DIR=<prefix>/include
LD_LIBRARY_PATH=<prefix>/lib cmake --build <build-dir>/compute-runtime -j <jobs>
cmake --install <build-dir>/compute-runtime
(cd <prefix>/bin && ln -sfn "$(ls ocloc-* | sort -V | tail -1)" ocloc)
```

- Drop `-DGMM_DIR` when gmmlib comes from the system.
- The build runs `ocloc` on the built-in kernels and `ocloc` opens
  `libigc.so.2` by name, hence `LD_LIBRARY_PATH` during the build.
- Without `-DOCL_ICD_VENDORDIR` the install writes
  `/etc/OpenCL/vendors/intel.icd`.
- The install creates `ocloc-<version>`; the link gives the `ocloc` name
  the package provides.

### Applying local patches

Apply patches to the IGC checkout before configuring, and undo them before
checking out another commit:

```sh
git -C <ws>/igc checkout -q -- .          # drop earlier edits (and the -Werror sed)
git -C <ws>/igc apply <patch>             # each patch, in order
```

Patches from `plugins/intel/tests/intel-tools/*/fix.patch` are diffs
against IGC's tree (each README names the IGC commit it applies to). Keep a
patched build in its own build tree and prefix, or record that the prefix
is patched; a patched and an unpatched IGC give different results.

### Install only into the prefix

Before `cmake --install`, list destinations outside the prefix:

```sh
grep -rhoE 'file\(INSTALL DESTINATION "[^"]*"' --include=cmake_install.cmake <build-dir>/<component> |
  sed 's/.*DESTINATION "//; s/"$//' | grep -v '^${CMAKE_INSTALL_PREFIX}' | grep -v '^<prefix>' | sort -u
```

Empty output means everything goes under `<prefix>`. IGC's install
destinations are absolute, so `cmake --install --prefix <other>` does not
move them: reconfigure with another `CMAKE_INSTALL_PREFIX`, or install with
`DESTDIR`.

### Build times observed

On a 12-core x86-64 host with `-j 10` under `nice -n 19`, GCC 16.2.1,
CMake 4.4.4, Ninja 1.13.2, clean trees:

| Step | Time |
|---|---|
| Level Zero loader | 28 s |
| gmmlib | 11-12 s |
| IGC v2.42.14, release (LLVM, Clang, opencl-clang, translator, IGC; about 4,900 Ninja steps) | 1,876 s |
| IGC master, with assertions | 2,017 s |
| compute-runtime 26.40 / master | about 430 s / 333 s |
| Whole stack | about 40 minutes |

Disk for one stack: sources about 3 GB, build trees 13-14 GB, install
1.5-1.6 GB (`libigc.so` alone is about 1.2 GB with debug info).

## 3. Run a program on the stack

The prefix is selected per process:

| Variable | Value | Effect |
|---|---|---|
| `LD_LIBRARY_PATH` | `<prefix>/lib` first | the stack's `libze_loader.so.1`, and the `libigc.so.2`, `libigdfcl.so.2`, `libiga64.so.2`, `libopencl-clang.so.*` and `libigdgmm.so.12` compute-runtime opens by soname |
| `ZE_ENABLE_ALT_DRIVERS` | `<prefix>/lib/libze_intel_gpu.so.1` | the loader opens only this driver |
| `PATH` | `<prefix>/bin` first | the stack's `ocloc` |
| `OCL_ICD_VENDORS` | `<prefix>/etc/OpenCL/vendors` | OpenCL programs use the stack too |
| `NEO_CACHE_DIR` | `<cache>/<stack>` | each stack its own binary cache, so no stack runs another's cached kernels |

[`run-on-stack.sh`](run-on-stack.sh) sets these:

```sh
sh run-on-stack.sh full <prefix> <cache>/<stack> <command> [args...]
```

The installed libraries have no RPATH: without these variables, the
stack's `libze_intel_gpu.so.1` picks up the system's `libigdgmm`.

- **Bazel tests** do not see the client's environment. Pass each variable
  with `--test_env=VAR` (for example
  `./bazelw test //plugins/intel/driver:LevelZeroPluginTest --test_env=LD_LIBRARY_PATH --test_env=ZE_ENABLE_ALT_DRIVERS --test_env=NEO_CACHE_DIR`).
- **IGC settings and dumps** only act when IGC compiles. A kernel found in
  compute-runtime's cache is not compiled again, so add
  `NEO_CACHE_PERSISTENT=0` (or point `NEO_CACHE_DIR` at an empty
  directory). For MAX, also give `MODULAR_CACHE_DIR` an empty directory.

## 4. Mix one stack's IGC with another's compute-runtime

This tells which of the two a change comes from (skill `intel-tool-bugs`).

- **IGC of stack A, everything else from the system:** a directory with
  links to A's `libigc.so.2`, `libigdfcl.so.2`, `libiga64.so.2` and
  `libopencl-clang.so.*`, first on `LD_LIBRARY_PATH`; no
  `ZE_ENABLE_ALT_DRIVERS`; the system's `ocloc`.
- **compute-runtime of stack A with the system's IGC:** a directory with
  links to A's `libze_loader.so.1`, `libze_intel_gpu.so.1`,
  `libigdgmm.so.12`, `libocloc.so` and the loader's layers, first on
  `LD_LIBRARY_PATH`; `ZE_ENABLE_ALT_DRIVERS` at A's driver; A's `bin`
  first on `PATH`. `<prefix>/lib` itself must not be on the path, or A's IGC
  comes along.
- Give each mix its own `NEO_CACHE_DIR`.

```sh
sh run-on-stack.sh igc <prefix-A> <cache>/A-igc <command> [args...]
sh run-on-stack.sh neo <prefix-A> <cache>/A-neo <command> [args...]
```

Between IGC 2.41 to 2.43 and compute-runtime 26.35 to 26.44, every pairing
tried in either direction worked. Other pairings: not verified.

## 5. Check what a process really loaded

Do this once per new stack or mix, and whenever a result surprises you.

- **Every library, by path:** `LD_DEBUG=libs <command> 2>&1 | grep 'calling init'`
  lists each library as it is initialised, `dlopen`ed ones included
  (loader, driver, `libigc.so.2`, `libigdfcl.so.2`, `libigdgmm.so.12`,
  `libopencl-clang`). On a full stack all of them are under `<prefix>/lib`.
- **A running process:** `grep -E 'libigc|libze_|libigdgmm|libigdfcl' /proc/<pid>/maps`.
- **Loader and driver:** `ZE_ENABLE_LOADER_DEBUG_TRACE=1` prints
  `ZE_LOADER_DEBUG_TRACE:` lines on stderr, including the path of the
  driver it loaded (seen with loaders 1.32 to 1.35). The loader's README
  marks it deprecated in favour of `ZEL_LOADER_LOG_CONSOLE=1
  ZEL_LOADER_LOGGING_LEVEL=trace`; that replacement was not tried here.
- **IGC commit:** dump a compile (`NEO_CACHE_PERSISTENT=0
  IGC_ShaderDumpEnable=1 IGC_DumpToCustomDir=<dump-dir>`) and read the
  `//.git-hash` line of a `*.asm` file. A distribution package may show a
  hash that is not a public IGC commit (built from a tarball); the 2.41.5
  package shows `5b6be42f...` while the `v2.41.5` tag is `f05f218e`.
- **compute-runtime version:** `ocloc --version`, run with the stack's
  environment (`ocloc` loads `libocloc.so` by name).

> [!TIP]
> Further reading (free, external; not maintained here):
> - [IGC: build instructions](https://github.com/intel/intel-graphics-compiler/blob/master/documentation/build_ubuntu.md): the workspace layout, CMake options and the revision table for IGC's dependencies.
> - [IGC releases](https://github.com/intel/intel-graphics-compiler/releases): release notes with the "Dependencies revisions" of each published release.
> - [compute-runtime: BUILD.md](https://github.com/intel/compute-runtime/blob/master/documentation/BUILD.md) and [manifests/manifest.yml](https://github.com/intel/compute-runtime/blob/master/manifests/manifest.yml): building NEO, including without root, and the IGC, gmmlib and Level Zero versions a commit is built with.
> - [compute-runtime: Compiler Cache](https://github.com/intel/compute-runtime/blob/master/programmers-guide/COMPILER_CACHE.md): `NEO_CACHE_DIR`, `NEO_CACHE_PERSISTENT` and the cache's other keys.
> - [Level Zero loader README](https://github.com/oneapi-src/level-zero/blob/master/README.md): building the loader, its layers, and its logging variables.
> - [Level Zero loader driver discovery (Linux)](https://github.com/oneapi-src/level-zero/blob/master/source/loader/linux/driver_discovery_lin.cpp): where `ZE_ENABLE_ALT_DRIVERS` is read; the source is its only documentation found.
> - [Level Zero specification](https://oneapi-src.github.io/level-zero-spec/level-zero/latest/index.html): the API the runtime implements.
> - [ld.so(8)](https://man7.org/linux/man-pages/man8/ld.so.8.html): library search order, `LD_LIBRARY_PATH` and `LD_DEBUG`.

## Pitfalls

- Two gmmlib builds can share a soname version (gmmlib 22.10.2 installs
  `libigdgmm.so.12.10.0`, as 22.10.0 does): only the path tells them apart.
- A stack that shares the system's `NEO_CACHE_DIR` can run binaries the
  system's IGC compiled; results then follow the cache, not the stack.
- `cmake --install --prefix` is ignored by IGC's absolute destinations; a
  "patched" install can silently overwrite an unpatched one. Keep one
  prefix per build and record checksums when in doubt.
- Do not install into `/usr` or `/etc`, do not change `/etc/ld.so.conf`,
  and do not replace the system packages: other users of the GPU host get
  the change too (`AGENTS.md`, ground rule 6).
- Release notes may not exist for the newest tags; the manifest and the
  files at the commit are then the only sources.

## References

- compute-runtime: `manifests/manifest.yml`, `documentation/BUILD.md`
  (https://github.com/intel/compute-runtime)
- IGC: `documentation/build_ubuntu.md`,
  `external/llvm/llvm_preferred_version.cmake`, `IGC/CMakeLists.txt`,
  `.github/workflows/build-IGC.yml`
  (https://github.com/intel/intel-graphics-compiler)
- Level Zero loader: https://github.com/oneapi-src/level-zero
- gmmlib: https://github.com/intel/gmmlib
- `plugins/intel/docs/intel-tools-issues.md` in the fork: the stacks the
  reproductions were run on.
- Skills `intel-tool-bugs` (what to run on a stack), `igc-bisect`
  (building many IGC commits), `intel-gpu-environment` (the installed stack).
