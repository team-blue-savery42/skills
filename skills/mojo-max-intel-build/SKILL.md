---
name: mojo-max-intel-build
description: Build Modular's fork with the Intel plugins (Bazel through ./bazelw, debug or --compilation_mode=opt, the HAL flag --//:hal_device_context=true) and run Mojo programs and MAX models on an Intel GPU with MODULAR_COMPILER_PLUGINS, MODULAR_DRIVER_PLUGINS and --target-accelerator, utils/run-max-py, utils/make-mojo-launcher and the driver plugin's MOJO_INTEL_* switches.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Build the fork and run Mojo and MAX on Intel

Use this to build the Intel plugins, Mojo and MAX from the fork, and to run
a Mojo program or a MAX model on an Intel GPU. It assumes an x86-64 Linux
host with a working Intel GPU stack (skill `intel-gpu-environment`) and a
checkout of the fork on the branch with `plugins/intel/`. All commands run
from the fork's root. `plugins/intel/README.md` ("Build", "Run") is the
reference; the scripts under `plugins/intel/utils/` show the exact
invocations the checks use.

A build needs no GPU. Running needs one.

## Build

```sh
./bazelw build //plugins/intel/... //Mojo:mojo //max/mojo/max:max
# MAX on the HAL runtime (the build Intel GPUs use):
./bazelw build --//:hal_device_context=true //max/python/max/_entrypoints:pipelines
```

- The default configuration is a debug build. Add
  `--compilation_mode=opt` for performance work and for model runs.
- `--//:hal_device_context=true` is a boolean Bazel flag defined in the
  root `BUILD.bazel` (`hal_device_context`). It routes MAX's C++
  `DeviceContext` through the HAL, which the Level Zero driver plugin
  implements. MAX models and MAX's Mojo GPU tests on Intel need it.
- The outputs:
  - `bazel-bin/plugins/intel/compiler/IntelCompilerPlugin.so`: the codegen
    plugin.
  - `bazel-bin/plugins/intel/driver/LevelZeroPlugin.so`: the driver plugin.
  - `bazel-bin/Target/CPUPlugin.so`: MAX's CPU driver plugin, listed after
    the Level Zero one for MAX. Build it explicitly with
    `//Target:CPUPlugin.so`, as `utils/run-max-py` and `utils/make-bundle`
    do; whether the commands above build it as a dependency is not verified.
- `bazel-bin` points at the configuration of the last build. The opt
  outputs' directory is `./bazelw info --compilation_mode=opt bazel-bin`.
  `utils/run-max-py` and `utils/make-bundle` build opt with
  `--symlink_prefix=/dev/null`, so `bazel-bin` stays on the debug build.
- Time: the first full build compiles LLVM, Mojo and MAX and takes on the
  order of an hour on a 12-core machine; incremental builds are much
  shorter (not measured for this skill; depends on the machine and the
  Bazel cache). Run it in the background with its output in a log file.
- Format before committing: `./bazelw run //:format`
  (`plugins/intel/CONTRIBUTING.md`).

## Run a Mojo program

From `plugins/intel/README.md`:

```sh
export MODULAR_COMPILER_PLUGINS=$PWD/bazel-bin/plugins/intel/compiler/IntelCompilerPlugin.so
export MODULAR_DRIVER_PLUGINS="level_zero@$PWD/bazel-bin/plugins/intel/driver/LevelZeroPlugin.so"
./bazelw run //Mojo:mojo -- run --target-accelerator=intel:bmg-g31 <program.mojo>
```

- `MODULAR_COMPILER_PLUGINS`: the codegen plugin that lowers kernels to
  SPIR-V.
- `MODULAR_DRIVER_PLUGINS`: `<api>@<path>`, entries separated by `;`. The
  Level Zero plugin's API name is `level_zero` (`Driver.cpp`); MAX's
  runtime and the HAL-build scripts use that. `utils/run-e2e` registers the
  same plugin as `intel@...` for probes that do not use `DeviceContext`,
  and `utils/make-bundle` calls `intel@` the "legacy form"; which name a
  given program needs outside those scripts is not verified, so start with
  `level_zero`.
- `--target-accelerator`: `intel:bmg-g31` (B70, sub-group size 16),
  `intel:bmg-g31-sg32` (sub-group size 32), `intel:rpl-p`, `intel:arl-s`
  (skill `intel-gpu-environment` for which one matches the GPU).
- Each run compiles into Mojo's cache; the check scripts set
  `MODULAR_CACHE_DIR` to a fresh directory so the compiler plugin always
  runs. Do the same after changing the compiler plugin.

### A mojo launcher that runs in your directory

Bazel's `run` script changes into the runfiles tree, which breaks programs
that open files relative to the working directory.
`plugins/intel/utils/make-mojo-launcher` writes a launcher that keeps the
caller's directory:

```sh
sh plugins/intel/utils/make-mojo-launcher          # debug build
sh plugins/intel/utils/make-mojo-launcher --config=ci   # extra arguments go to bazelw
```

The script's header names `--config=ci` as the way to get an optimized
launcher (not verified). It writes `$INTEL_PLUGIN_BIN/mojo` (default `$HOME/.cache/intel-plugin/bin/mojo`)
and prints the path. Re-run it after every build that changes the
configuration. `utils/check-codegen`, `check-device`, `check-e2e`,
`check-max-gpu`, `check-targets` and `run-e2e` use this launcher, through
the same `INTEL_PLUGIN_BIN`.

`plugins/intel/utils/run-e2e <name> [mojo options]` runs
`plugins/intel/tests/e2e/<name>.mojo` with both plugins set up;
`E2E_ACCELERATOR` picks the target. Read its header for the
`# run-e2e: device-context` and `# run-e2e: packages` lines.

## Run a MAX model

From `plugins/intel/README.md` (opt build, HAL runtime):

```sh
bin=$(./bazelw info --compilation_mode=opt bazel-bin)
export MODULAR_COMPILER_PLUGINS=$bin/plugins/intel/compiler/IntelCompilerPlugin.so
drv=$bin/plugins/intel/driver/LevelZeroPlugin.so
export MODULAR_DRIVER_PLUGINS="level_zero@$drv;CPU@$bin/Target/CPUPlugin.so"
./bazelw run --compilation_mode=opt --//:hal_device_context=true \
  //max/python/max/_entrypoints:pipelines -- \
  serve --model-path <model-dir> --devices gpu
```

Build the plugins in the same configuration first (the README's info
command only prints the directory). Qwen3-8B needs `--no-prefer-module-v3`
(README, "Known limitations"). `plugins/intel/docs/support.md` lists the
models, weight formats and features that run.

### Python scripts against MAX: `utils/run-max-py`

```sh
plugins/intel/utils/run-max-py <script.py> [args...]
RUN_MAX_PY_OPT=1 plugins/intel/utils/run-max-py <script.py> [args...]
```

It builds the plugins and `//max/python/max/_entrypoints:pipelines` with
`--//:hal_device_context=true`, then runs the script with that target's
hermetic Python, import path and environment, with the compiler plugin in
`MODULAR_COMPILER_PLUGINS` and the Level Zero and CPU plugins in
`MODULAR_DRIVER_PLUGINS`. It sets `HF_HUB_OFFLINE=1`, so
models come from local paths. Environment:

| Variable              | Effect                                                          |
|-----------------------|-----------------------------------------------------------------|
| `RUN_MAX_PY_OPT=1`    | build and run with `--compilation_mode=opt` (bazel-bin untouched) |
| `RUN_MAX_PY_ENV`      | extra `NAME=value` assignments for the run                      |
| `RUN_MAX_PY_WRAPPER`  | a command to run it under (the script's example: `unitrace -d`) |
| `MODULAR_DIR`         | the checkout to use (default: the one the script is in)         |

Examples in the tree: `plugins/intel/tests/graph/*.py` (MAX graphs of the
ops Qwen3.5-0.8B uses) and `tests/graph/gen_repeat.py` (greedy generation;
read its docstring for `GEN_*` variables).

### Without Bazel on the target machine: `utils/make-bundle`

`plugins/intel/utils/make-bundle <outdir>` packs an opt MAX build with the
plugins into a directory with `bin/mojo`, `bin/max-python` and
`bin/env.sh`. The target machine needs only the Level Zero loader and
compute-runtime. `run-e2e` accepts such a tree through `INTEL_BUNDLE`.

## Driver plugin switches

Read from the environment by `plugins/intel/driver/` (`Context.cpp`,
`Module.cpp`, `Profile.cpp`); check the sources for the current list.

| Variable                          | Effect                                                                                       |
|-----------------------------------|----------------------------------------------------------------------------------------------|
| `MOJO_INTEL_PROFILE=<prefix>`     | write a launch profile to `<prefix>.<pid>` (kernels, copies, graph launches, host and device times); `plugins/intel/utils/bench/steps.py` reads it |
| `MOJO_INTEL_PROFILE_DEVICE=0`     | profile host times only (no per-command timestamp events)                                    |
| `MOJO_INTEL_COPY_OFFLOAD=1`       | queue copies go to the copy engine (default: compute engine)                                |
| `MOJO_INTEL_HEAP_SIZE=<bytes>`    | size of the device heap for `malloc` in kernels (default 8 MiB; decimal digits only)         |
| `MOJO_INTEL_IGC_OPTIONS=<opts>`   | extra IGC build options, such as `-cl-opt-disable` or `-ze-opt-level=1`                      |
| `MOJO_INTEL_ALLOC_CACHE_MB=<n>`   | allocation cache limit per context (default 4096; 0 turns it off)                           |
| `MOJO_INTEL_DEBUG_ALLOC_FILL=<byte>` | fill each new allocation with that byte (0xff makes float NaNs) to expose reads of unwritten memory |
| `MOJO_INTEL_DEBUG_MEMLOG=<file>`  | log every USM allocation and free, to match a GPU fault address with its buffer              |
| `MOJO_INTEL_DEBUG_DRAIN_FREES=1`  | a synchronous free drains every queue of the context first                                   |
| `MOJO_INTEL_DEBUG_NO_FREE_REUSE=1`| turn off reuse of blocks freed on the queue                                                  |

The compiler plugin reads `MOJO_INTEL_PLUGIN_DUMP=<dir>` (writes each
module as `.bc` before llc and each `.spv`) and `MOJO_INTEL_PLUGIN_TRACE`
(logs its entry points to stderr); skill `intel-compiler-plugin`.

The README describes `MOJO_INTEL_PROFILE` as `=<file>`; the source
(`Profile.cpp`) appends `.<pid>`.

## Pitfalls

- Mixing configurations: a debug `bazel-bin` plugin with an opt MAX, or a
  stale plugin from another configuration, gives confusing results. Build
  the plugins in the configuration you run, as `run-max-py` does.
- MAX on Intel needs the HAL build flag; without it MAX's `DeviceContext`
  does not use the Level Zero plugin.
- `MOJO_INTEL_IGC_OPTIONS=-cl-opt-disable` is a debugging aid: it turns off
  all of IGC's optimization.
- Do not change the IGC version to work around a failure without the
  attention check in skill `intel-gpu-environment`.

> [!TIP]
> Further reading (free, external; not maintained here):
> - [Bazel: Commands and Options](https://bazel.build/docs/user-manual): `--compilation_mode` (`fastbuild`, `dbg`, `opt`) and the other build options `./bazelw` passes through.
> - [modular/modular](https://github.com/modular/modular): upstream repository; its README shows `./bazelw run //Mojo:mojo -- <file>` and links the Mojo and MAX contributor guides.
> - [MAX contributor handbook](https://github.com/modular/modular/blob/main/max/docs/contributing/README.md): upstream's guide to contributing to MAX, pointing to its build and test setup.
> - [Level Zero Specification](https://oneapi-src.github.io/level-zero-spec/level-zero/latest/index.html): the API the driver plugin implements against (programming guides, extensions, API reference).
> - [Compute-Runtime Programmers and Optimization Guide](https://github.com/intel/compute-runtime/blob/master/programmers-guide/PROGRAMMERS_GUIDE.md): immediate command lists, compiler caching, allocations over 4 GB, device memory reservations.
> - [IGC configuration flags](https://github.com/intel/intel-graphics-compiler/blob/master/documentation/configuration_flags.md): `IGC_*` environment variables, which work beside `MOJO_INTEL_IGC_OPTIONS`.

## References

- `plugins/intel/README.md`: build, run, environment switches.
- `plugins/intel/utils/run-max-py`, `make-mojo-launcher`, `make-bundle`,
  `run-e2e`: read their headers for usage.
- `plugins/intel/driver/Context.cpp`, `Module.cpp`, `Profile.h`: switches.
- Skills: `intel-gpu-environment`, `intel-plugin-checks`,
  `intel-performance`, `intel-driver-plugin`, `intel-compiler-plugin`.
