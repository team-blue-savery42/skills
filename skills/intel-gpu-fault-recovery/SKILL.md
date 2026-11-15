---
name: intel-gpu-fault-recovery
description: Recognise and recover from a GPU page fault on an Intel GPU with the xe driver - kernel log lines such as "Engine memory CAT error" and engine resets, "the GPU was lost" errors from the Level Zero driver plugin, the next process hanging at its first wait, the throwaway process utils/l0/fault-absorb and how check-max-gpu uses it, what to collect for a report, and how not to disturb other GPU users.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# GPU fault recovery on Intel GPUs

Use this when a Mojo program, MAX model or test hangs, times out, fails
with "the GPU was lost", or when the checks report GPU fault lines. It
describes the behaviour measured on an Arc Pro B70 with the `xe` driver
(Linux 7.2.8, GuC firmware 70.72.1) and compute-runtime 26.35.39758,
26.40.40196.15 and master `ee495cce`
(`plugins/intel/docs/intel-tools-issues.md`, "After a GPU page fault, the
next process hangs"). Other drivers and GPUs are not verified.

## What happens

1. A kernel touches unmapped memory. The `xe` driver logs the fault and
   resets the engine. The reset affects every process using that engine.
2. In the faulting process, Level Zero may report the interrupted work as
   complete: `zeCommandListHostSynchronize` and `zeDeviceGetStatus` return
   success right after the faulting kernel.
3. The **first process to use the GPU afterwards** never sees its first
   command complete: its wait returns `ZE_RESULT_NOT_READY` until it gives
   up, and the kernel log shows nothing for it. A pause in between does
   not help.
4. The process after that one runs normally.

So a hang right after a fault is usually this, not a new bug in the
hanging program. The cause is in compute-runtime, the `xe` driver or the
GuC firmware; IGC has no part in it. Not every fault does this: a store
just past the end of a small allocation was reported as
`ZE_RESULT_ERROR_DEVICE_LOST` and the next process did not hang.

## Recognise it

### Kernel log

```sh
journalctl -k --since "-10min" --no-pager |
  grep -E "CAT error|Faulted Address|Timedout|reset|ban"
```

From the reproduction in
`plugins/intel/tests/intel-tools/gpu-fault-next-process-hangs/README.md`:

```text
Faulted Address: 0x0000100000000000  FaultType: 0  AccessType: 1
Engine memory CAT error [18]: class=ccs, logical_mask: 0x1, guc_id=3
Timedout job: seqno=..., lrc_seqno=..., guc_id=3, flags=0x20 in repro
exec queue reset detected
```

- `Engine memory CAT error` is the page fault; `class=ccs` is a compute
  engine, `bcs` a copy engine.
- `Faulted Address` is the GPU virtual address. In that reproduction a
  store gave `AccessType: 1`; reading `0` as a read is the usual
  interpretation (not verified against the driver source).
- `Timedout job ... in <process name>` names the process whose job was
  reset. Match it to a test by time.
- Many repeated `exec queue reset detected` lines suggest a process still
  submitting to a queue the driver has banned (not verified).

`journalctl -k` needs read access to the system journal. Without it the
checks see no faults.

### From the driver plugin

`plugins/intel/driver/Context.cpp` (`waited`): after a wait, the plugin
calls `zeDeviceGetStatus` when the wait failed and otherwise at most once a
millisecond. When the status is not success, it marks the device lost and
**every later wait fails** with:

```text
the GPU was lost: a kernel faulted or the GPU was reset (`journalctl -k` shows why)
```

So a fault is reported by a later synchronize, not at the launch, as CUDA
reports an illegal address. The process cannot recover the device; restart
it. The unit test of this behaviour,
`//plugins/intel/driver:LevelZeroFaultTest`, is tagged `manual` and
`exclusive` because it faults the GPU and makes the next process hang;
run it only on purpose, on a GPU nobody else uses.

### A hung process

A hung Mojo process sits in `zeEventHostSynchronize` or
`zeCommandListHostSynchronize` (an `ioctl`), or in a copy waiting for a
kernel that will never finish (seen with gdb on the tested stack; not
documented in the fork). `gdb -p <pid> -batch -ex 'thread apply all bt 20'`
shows where; most threads are idle runtime workers.

## Recover: the throwaway process

Run one small GPU process after the fault so that it, not the next real
job, takes the hang. `plugins/intel/utils/l0/fault-absorb/` holds a plain
Level Zero program (`repro.cpp`) and its kernels (`kernels.cl`). Build and
run it as `utils/check-max-gpu` does:

```sh
work=$(mktemp -d)
clang -target spirv64 -cl-std=CL2.0 -O2 -c plugins/intel/utils/l0/fault-absorb/kernels.cl -o "$work/k.spv"
clang++ -O1 -std=c++17 plugins/intel/utils/l0/fault-absorb/repro.cpp -o "$work/repro" -lze_loader
"$work/repro" add "$work/k.spv"; echo "exit $?"
```

- `repro add` adds two 1024-float vectors, waits at most 10 s per wait and
  checks the result.
- Exit 0: the GPU works (`add: 0 of 1024 wrong`).
- Exit 2 with `HANG: ... not done after 10 s`: this run took the hang. Run
  it again; it should now exit 0.
- Exit 1: a Level Zero call failed or the result is wrong; the problem is
  not this one.
- Never run `repro fault`: it page-faults the GPU on purpose.

It needs clang with the `spirv64` target, a C++ compiler and the Level Zero
loader's development files.

### How `check-max-gpu` uses it

From `plugins/intel/utils/check-max-gpu`:

- Tests known to fault (`FAULTING` in the script) run alone after the
  others, each followed by `absorb_fault()`, which builds and runs
  `repro add` with a 30 s limit.
- After the run it reads `journalctl -k` for `Engine memory CAT error`
  lines since the start and prints `GPU fault at <time> during: <tests>`.
- If there were faults, every test that timed out while or after the first
  fault happened is rerun alone after a throwaway process; a different
  result replaces the first and is noted `stranded: <first>, then <second>
  alone`.

`plugins/intel/utils/check` counts fault lines over its whole run in
`result.txt` (`GPU fault lines: N`). With N > 0, treat timeouts and
failures of tests that ran after the fault as unconfirmed; rerun them
after a throwaway process (skill `intel-plugin-checks`).

## Find the faulting access

- Rerun the faulting program alone, then the throwaway process.
- `MOJO_INTEL_DEBUG_MEMLOG=<file>` logs every allocation and free
  (`+`/`-`, address, bytes, host or device); match the `Faulted Address`
  against it to see whether the address was freed, never allocated, or
  just past a buffer.
- `MOJO_INTEL_DEBUG_DRAIN_FREES=1` and `MOJO_INTEL_DEBUG_NO_FREE_REUSE=1`
  rule out frees racing with running kernels.
- `MOJO_INTEL_IGC_OPTIONS=-cl-opt-disable`: if the fault goes away, suspect
  IGC's optimizer (skill `intel-tool-bugs`;
  `plugins/intel/docs/intel-tools-issues.md` lists IGC bugs that showed up
  as page faults).
- `MOJO_INTEL_COPY_OFFLOAD=1` moves queue copies to the copy engine; with
  compute-runtime 26.35 the copy engine page-faulted when device memory ran
  out, so it is off by default.

## What to collect

For a bug report against the driver stack, use skill
`xe-bug-report-collect` (a redacted diagnostic bundle). Include at least:

- The kernel log lines around the fault (`Faulted Address`, `CAT error`,
  `Timedout job`, resets), with times.
- The stack: kernel and `xe`/`i915`, GuC firmware, compute-runtime, IGC,
  Level Zero loader (skill `intel-gpu-environment`).
- The faulting program's output and the plugin's error, and the commit of
  the fork.
- A reproduction without Mojo if possible (skill `intel-tool-bugs`;
  `tests/intel-tools/gpu-fault-next-process-hangs/` is the model).

Remove host names, user names and home paths from anything you paste.

## Do not disturb other GPU users

- A fault resets the engine for **every** process using it, and the next
  process to start may hang. On a shared GPU, a faulting test costs other
  users work.
- Run known-faulting programs and the reproduction
  `plugins/intel/tests/intel-tools/gpu-fault-next-process-hangs/run.sh`
  only on a GPU nothing else is using, and only when the contributor asks.
- Do not kill other users' processes, stop services, unbind or reset the
  device, or change kernel or driver settings (hang check, wedged mode)
  without the contributor's say-so.
- If someone else's job may have taken the hang, tell the contributor
  when the fault happened.
- A throwaway `repro add` is short (one tiny kernel); run it right after
  your own fault, before anything else of yours.

## Pitfalls

- Blaming the program that hung: check the kernel log for a fault just
  before it started.
- Trusting a timeout in a run with fault lines.
- The faulting process may print success for the faulting launch; the
  error appears at a later synchronize.
- No fault lines without kernel log access does not mean no faults.

> [!TIP]
> Further reading (free, external; not maintained here):
> - [DRM userspace API: Device reset and Device Wedging](https://docs.kernel.org/gpu/drm-uapi.html): how kernel and user-mode drivers handle GPU resets, robustness, and devices the driver declares wedged.
> - [Xe Device Wedging](https://docs.kernel.org/gpu/xe/xe_device.html): when `xe` declares a device wedged, its uevent, recovery by rebind or bus reset, and the `gpu_health` sysfs attribute.
> - [Reading an Xe Device Coredump via sysfs](https://docs.kernel.org/gpu/xe/xe_devcoredump.html): where `xe` puts the hardware and driver snapshot taken at a hang, and how it is released.
> - [drm/xe Intel GFX Driver](https://docs.kernel.org/gpu/xe/index.html): the driver's documentation index (execution queues, command submission, firmware, debugging).
> - [Level Zero Specification](https://oneapi-src.github.io/level-zero-spec/level-zero/latest/index.html): `zeDeviceGetStatus`, `zeCommandListHostSynchronize` and the result codes the plugin checks.
> - [compute-runtime Issue Submission Guide](https://github.com/intel/compute-runtime/blob/master/documentation/ISSUE_SUBMISSION_GUIDE.md): what Intel asks for in a Linux driver bug (packages, kernel, dmesg, reproducer).
> - [journalctl(1)](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html): `-k`, `--since`, and the groups that may read the system journal.

## References

- `plugins/intel/docs/intel-tools-issues.md`: "After a GPU page fault, the
  next process hangs" and the IGC bugs that page-faulted.
- `plugins/intel/tests/intel-tools/gpu-fault-next-process-hangs/`.
- `plugins/intel/utils/l0/fault-absorb/repro.cpp`, `kernels.cl`.
- `plugins/intel/utils/check-max-gpu` (`absorb_fault`, `kernel_faults`,
  `FAULTING`), `plugins/intel/utils/check`.
- `plugins/intel/driver/Context.cpp` (`waited`),
  `plugins/intel/driver/test/LevelZeroFaultTest.cpp`.
- Skills: `xe-bug-report-collect`, `intel-plugin-checks`,
  `intel-gpu-environment`, `intel-tool-bugs`, `intel-driver-plugin`.
