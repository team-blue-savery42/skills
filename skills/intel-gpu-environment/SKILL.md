---
name: intel-gpu-environment
description: Check that a Linux machine's Intel GPU stack is usable for Mojo and MAX and identify it - kernel driver (xe or i915), compute-runtime, IGC and Level Zero loader versions, render-node permissions, clinfo, ocloc device names, the matching Mojo target (intel:bmg-g31, intel:bmg-g31-sg32, intel:rpl-p, intel:arl-s), and whether the IGC version is one known to break MAX.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Intel GPU environment

Use this before building or running anything on an Intel GPU, when a
contributor reports a problem (record the stack with the report), and after
any driver or package upgrade. Everything here is read-only and does not
launch GPU work, except `clinfo`, which opens the device.

The reference for what is tested is `plugins/intel/README.md`
("Requirements") and `plugins/intel/docs/intel-tools-issues.md` in the fork.

## The tested stack

| Component         | Tested version                                      | Source                                         |
|-------------------|-----------------------------------------------------|------------------------------------------------|
| GPU               | Intel Arc Pro B70 (Battlemage G31, `bmg-g31`, Xe2)  | `plugins/intel/README.md`                      |
| Kernel driver     | `xe`, Linux 7.2.8, GuC firmware 70.72.1             | `plugins/intel/docs/intel-tools-issues.md`     |
| compute-runtime   | 26.35.39758                                         | `plugins/intel/README.md`                      |
| IGC               | 2.41.5                                              | `plugins/intel/README.md`                      |
| Level Zero loader | 1.32.0 (headers pinned in `plugins/intel/level_zero.MODULE.bazel`) | `plugins/intel/README.md`       |
| Check tools       | `ocloc`, `spirv-val`, `spirv-dis`, clang with the `spirv64` target | `plugins/intel/README.md`       |

These were Arch Linux packages. The integrated GPUs (Raptor Lake-P, Arrow
Lake-S) were tested with the `i915` driver and compute-runtime 26.40.

## Steps

### 1. GPU and kernel driver

```sh
lspci -nnk | grep -A3 -E 'VGA|Display'
readlink /sys/class/drm/card*/device/driver
```

Look for `Kernel driver in use: xe` (or `i915`). The B70 shows as
`Battlemage G31 [Arc Pro B70] [8086:e223]`. The plugins were tested on `xe`
for the B70 and on `i915` for the integrated GPUs; other combinations are
not verified.

### 2. Package versions

On Arch-based systems:

```sh
pacman -Q intel-compute-runtime intel-graphics-compiler level-zero-loader level-zero-headers
```

On other distributions use the package manager's query; package names
differ (not verified). Other ways to read the versions:

- compute-runtime: `ocloc --version` prints it (for example `26.35.39758`).
- Level Zero loader: the file name of `libze_loader.so.1.<minor>.<patch>`
  in the library directory (for example `libze_loader.so.1.32.0`).
- IGC: the library file name shows only major and minor
  (`libigc.so.2.41.0+0` for IGC 2.41.5), so take the patch version from
  the package manager.
- When several stacks are installed (one built from source, see skill
  `intel-stack-from-source`), `LD_DEBUG=libs <program> 2>&1 | grep 'calling init'`
  shows which loader, `libze_intel_gpu`, `libigc` and `libigdgmm` a
  process actually loaded.

### 3. Device node permissions

```sh
ls -l /dev/dri/
id -nG
```

Level Zero opens the render node (`/dev/dri/renderD*`), normally owned by
group `render`. The README expects the user in `render`. If the user is
not in it, the contributor adds it (`usermod -aG render <user>`, then logs
in again); do not change groups or device permissions yourself.

### 4. Does Level Zero / OpenCL see the GPU?

```sh
clinfo -l
```

Lists platforms and devices, for example
`Intel(R) Arc(TM) Pro B70 Graphics`. No device usually means the user lacks
access to the render node or compute-runtime is not installed. A full
Level Zero smoke test is `plugins/intel/utils/l0/fault-absorb` run with
`add` (skill `intel-gpu-fault-recovery` shows how to build it); it
launches a tiny kernel, so do not run it on a GPU someone else is timing.

### 5. ocloc device names and the Mojo target

`ocloc compile --help` lists the `-device` names it knows. `ocloc ids
<name>` prints the IP versions behind a name. The driver plugin maps the
device's IP version to a name (`plugins/intel/driver/Driver.cpp`,
`archName`):

| IP (arch.release) | Name      | GPU                          | Mojo target(s)                          |
|-------------------|-----------|------------------------------|-----------------------------------------|
| 20.2              | `bmg-g31` | Arc Pro B70 (Xe2)            | `intel:bmg-g31`, `intel:bmg-g31-sg32`   |
| 20.1              | `bmg-g21` | Arc B580 (Xe2)               | `intel:bmg-g21`, `intel:bmg-g21-sg32` (defined in `max/mojo/max/_plugin/intel/targets.mojo`; not verified on hardware) |
| 12.3              | `rpl-p`   | Raptor Lake-P iGPU (Xe-LP)   | `intel:rpl-p`                           |
| 12.70             | `arl-s`   | Arrow Lake-S iGPU (Xe-LPG)   | `intel:arl-s`                           |

Any other device gets its dotted IP version as its name, and has no Mojo
target. The README says other Xe2 parts should work with the `bmg-g31`
target but are untested.

- `intel:bmg-g31`: sub-group size 16, DPAS, 2D block I/O. This is the
  default of the check scripts.
- `intel:bmg-g31-sg32`: the same device, kernels at sub-group size 32 and
  `WARP_SIZE` 32. DPAS (`mma`) and 2D block I/O need sub-group size 16 and
  fail to compile for this target.
- `intel:rpl-p`, `intel:arl-s`: see "Integrated GPUs" below.

### 6. Check the IGC version against known breakage

- **IGC 2.42 and 2.43 return NaN from MAX's paged flash attention**;
  Qwen3.5's greedy text turns into `Thinking!!!!...`. Use 2.41.5.
- **IGC 2.43 segfaults** building kernels with two struct arguments passed
  by value: most MAX graphs fail in `zeModuleCreate`.
- IGC 2.41 and 2.42 miscompile some of MAX's math tests; they are marked
  `igc` in `plugins/intel/tests/max-gpu-expected.txt`.
- The packaged Level Zero loader `1.32.0-1` on Arch crashes every program
  when `ZE_ENABLE_VALIDATION_LAYER=1`; a loader built from source works.

Details, affected versions and reproductions:
`plugins/intel/docs/intel-tools-issues.md`. To check attention under the
installed IGC (needs a build, skill `mojo-max-intel-build`), with an empty
compute-runtime cache so every kernel is compiled again:

```sh
NEO_CACHE_DIR=$(mktemp -d) plugins/intel/utils/run-max-py plugins/intel/tests/graph/attention.py
```

It prints `PASS` or `FAIL` and the largest difference from a NumPy
reference per case. Do not upgrade IGC to fix something else without
running it (skill `intel-tool-bugs`).

### 7. Kernel log access

The checks and fault diagnosis read the kernel log with `journalctl -k`.
Confirm it works for the user:

```sh
journalctl -k -n 5 --no-pager
```

Without access, `plugins/intel/utils/check` and `check-max-gpu` cannot see
GPU faults and report none.

## Integrated GPUs

From `plugins/intel/README.md` and `plugins/intel/docs/support.md`:

- IGC rejects the DPAS and 2D block I/O extensions on Xe-LP and Xe-LPG, so
  they run MAX's generic kernels and a shared-memory SIMT GEMM, not the
  Intel DPAS GEMM, flash attention or the FP8 weight-only kernel (FP8
  linear layers take MAX's generic path; skill `intel-quantization`); `mma`
  and block I/O fail to compile.
- Raptor Lake-P (Xe-LP): work-groups of at most 512, no float64.
- With `i915` and compute-runtime 26.40, a single allocation over
  `maxMemAllocSize` (4 GiB) fails although the driver plugin asks for
  relaxed limits. A model run needs no such allocation.
- `tests/max-gpu-expected.txt` describes the B70 only; `utils/check-e2e`
  adjusts its expectations with `E2E_ACCELERATOR=intel:rpl-p` or
  `intel:arl-s`.

## Pitfalls

- A different IGC can still be picked up after an upgrade: compute-runtime
  caches compiled kernels. Use an empty `NEO_CACHE_DIR` when comparing IGC
  versions.
- The IGC library file name does not carry the patch version.
- `clinfo` succeeding does not prove the Level Zero path works; Mojo uses
  Level Zero, not OpenCL.
- Do not install or upgrade system packages, change kernel parameters or
  group membership without the contributor's say-so; the GPU may be shared.
  Some vendor install guides suggest disabling the GPU hang check with a
  kernel boot parameter; that is a system setting and the contributor's
  decision, not something an agent applies.

> [!TIP]
> Further reading (free, external; not maintained here):
> - [drm/xe Intel GFX Driver](https://docs.kernel.org/gpu/xe/index.html): the kernel documentation of the `xe` driver (memory management, execution queues, firmware, debugging).
> - [DRM userspace API: render nodes](https://docs.kernel.org/gpu/drm-uapi.html): what `/dev/dri/renderD*` nodes are, plus device reset and wedging.
> - [Install Intel GPU Drivers (oneAPI installation guide)](https://www.intel.com/content/www/us/en/docs/oneapi-toolkit/installation-guide-linux/latest/install-intel-gpu-drivers.html): Intel's driver install steps and how to check and join the group that owns the render nodes.
> - [intel/compute-runtime](https://github.com/intel/compute-runtime): the Level Zero and OpenCL driver; its README lists supported platforms (Battlemage, Arrow Lake and others).
> - [compute-runtime FAQ](https://github.com/intel/compute-runtime/blob/master/documentation/FAQ.md): OS and platform support, the Resizable BAR requirement with `xe`, debug keys (`NEOReadDebugKeys`).
> - [intel/intel-graphics-compiler](https://github.com/intel/intel-graphics-compiler): IGC sources, build guide and release tags.
> - [oneapi-src/level-zero](https://github.com/oneapi-src/level-zero): the Level Zero loader, validation and tracing layers, and loader logging variables.
> - [journalctl(1)](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html): `-k`, `--since`, and which groups may read the system journal.

## References

- `plugins/intel/README.md`: requirements, targets, known limitations.
- `plugins/intel/docs/intel-tools-issues.md`: known issues per version.
- `plugins/intel/docs/support.md`: integrated GPUs.
- `plugins/intel/driver/Driver.cpp` (`archName`),
  `max/mojo/max/_plugin/intel/targets.mojo`: device names and targets.
- Skills: `mojo-max-intel-build`, `intel-plugin-checks`,
  `intel-gpu-fault-recovery`, `intel-tool-bugs`, `intel-stack-from-source`,
  `xe-bug-report-collect`.
