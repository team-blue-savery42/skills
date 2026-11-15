---
name: xe-bug-report-collect
description: Collect a redacted diagnostic bundle (kernel log, sysfs, debugfs, PCI state, packages, xpu-smi) with xe-bug-report for an Intel GPU, xe driver, compute-runtime or Level Zero problem, read its manifest.json, check it before sharing and attach it to a bug report.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Collect a GPU diagnostic bundle with xe-bug-report

[xe-bug-report](https://github.com/team-blue-savery42/xe-bug-report)
writes one redacted zip with the kernel log, sysfs and debugfs attributes,
PCI state, package lists and `xpu-smi` output of a Linux or Windows machine,
plus a `manifest.json` that says what was collected, what was not, and why.
It does not link Level Zero or any GPU library, and every read and child
process has a time limit, so it also works on a machine whose GPU stack is
hung or does not start.

Use it for any problem below Mojo and MAX: a GPU hang or page fault, a
device that disappears, a driver or firmware error in the kernel log, a
runtime that does not find the GPU. For a wrong result from IGC or
compute-runtime, the bundle records the stack; the reproduction itself
comes from skill `intel-tool-bugs`.

Everything here comes from the xe-bug-report `README.md` (version 0.1.0 in
`Cargo.toml`). Run `xe-bug-report --help` and `--list` on the installed
version: options and source rows may have changed.

## When to run it

- **Right after the problem, before a reboot, a driver reload or a reset.**
  Device coredumps (`dumps/<dev>/`), debugfs state, GuC logs and the
  current-boot kernel log describe the state *now*; a reboot or module
  reload loses most of it. The default profile also keeps the previous
  boot's kernel log (`kernel/kmsg-prev-boot.txt`), so a run after an
  unavoidable reboot still has the log, but not the device state.
- After a GPU page fault, the next process on the GPU may hang (skill
  `intel-gpu-fault-recovery`). Collect first, then recover.
- The GPU may be shared. Running xe-bug-report is read-only (debugfs files
  that change state are never opened; see "Hang safety"), but `sudo` is the
  contributor's decision: ask before running it as root.

## Install

From the [releases page](https://github.com/team-blue-savery42/xe-bug-report/releases)
(each release has `SHA256SUMS`):

| System | File |
|---|---|
| Debian 12 and newer | `xe-bug-report_<version>_deb12_amd64.deb` |
| Ubuntu 24.04 / 26.04 | `xe-bug-report_<version>_ubuntu24.04_amd64.deb` / `..._ubuntu26.04_amd64.deb` |
| RHEL 8 / 9 and rebuilds | `xe-bug-report-<version>-1.el8.x86_64.rpm` / `...-1.el9.x86_64.rpm` |
| Arch Linux | `xe-bug-report-<version>-1-x86_64.pkg.tar.zst`, or the AUR package `xe-bug-report` |
| any Linux with glibc 2.28 or newer | `xe-bug-report-<version>-x86_64-unknown-linux-gnu.tar.gz` |
| Windows x86-64 | `xe-bug-report-<version>-x86_64-pc-windows-msvc.zip` |

Check the download before running it:

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

From crates.io or a clone (Rust 1.99 or newer; `rust-toolchain.toml` pins
1.99.1):

```sh
cargo install --locked xe-bug-report
cargo build --release --locked    # in a clone: target/release/xe-bug-report
```

The Linux binary needs only glibc and runs from wherever it is copied, so it
can be copied onto a machine whose package manager is broken. On Windows
the C runtime is linked in.

Optional tools fill in more of the bundle; a missing one only leaves its
sources `skipped` with `<tool> not installed`. On Linux: `xpu-smi` (Intel
XPU Manager), `iclg` (Intel Crash Log), `lspci`, `journalctl`,
`coredumpctl`, `systemd-detect-virt`, `modinfo`, `dkms`, `ldconfig`,
`dpkg-query`, `rpm`, `clinfo`, `vainfo`, `vulkaninfo`, `eglinfo`,
`sycl-ls`, `icpx`, `intel_gpu_top`. The README "Dependencies" table says
which file each one fills.

## Usage

```text
xe-bug-report [--output <file>] [--device <bdf,...>] [--minimal | --full] [--samples <n>]
              [--since <duration>] [--no-redact] [--list] [--json] [--xpu-smi <path>]
              [--timeout <seconds>] [--verbose]
xe-bug-report --version | -v
xe-bug-report --help | -h
```

| Option | Meaning |
|---|---|
| `--output <file>` | Archive name. Default `xe-bug-report-<YYYYMMDDTHHMMSSZ>.zip` (UTC, no host name) in the current directory. An existing file is never overwritten (exit 1). Written as `<output>.partial`, renamed when complete. |
| `--device <bdf,...>` | PCI addresses `dddd:bb:dd.f`, comma-separated. Default: every Intel GPU. An address that is not an Intel GPU is an error. No device indices. |
| `--minimal` / `--full` | Profile (below). Not combinable. |
| `--samples <n>` | `xpu-smi dump` samples per GPU, 1 s apart. Default 5, `0` disables, at most 3600. `--minimal` forces 0. |
| `--since <duration>` | Window of the kernel log (Linux) and event logs (Windows): `<n>m`, `<n>h`, `<n>d` or a bare integer of hours, 1 minute to 365 days. Linux reads the window from the journal across reboots, so `kernel/kmsg-prev-boot.txt` is not written. Default: current and previous boot (Linux), 72 hours (Windows). |
| `--no-redact` | Keep host names, user names, serial numbers and addresses (see "Privacy"). |
| `--list` | Print the sources the options would collect, then exit. |
| `--json` | Print the result as JSON on stdout instead of the report. |
| `--xpu-smi <path>` | The `xpu-smi` executable. Default: `xpu-smi` on PATH, then next to `xe-bug-report`. |
| `--timeout <seconds>` | Deadline of the whole run. Default 600, `0` disables. |
| `--verbose` | Progress on stderr, and a `Not complete:` list in the report. |

Typical runs:

```sh
# The usual bundle; sudo gives the full one (ask the contributor first).
sudo xe-bug-report

# One GPU, a chosen file name.
xe-bug-report --output gpu_debug.zip --device 0000:03:00.0

# Kernel log of the last 30 minutes, across reboots.
sudo xe-bug-report --since 30m

# See what would be collected, without collecting.
xe-bug-report --list --full

# An xpu-smi outside PATH, machine-readable result.
xe-bug-report --xpu-smi <path-to>/xpu-smi --json
```

Windows, from an elevated prompt:

```text
xe-bug-report.exe --since 24h --output <dir>\gpu_debug.zip
```

On success the report on stdout looks like:

```text
Wrote xe-bug-report-20261110T163000Z.zip (712.8 KiB)
  53 sources: 39 complete, 6 partial, 8 not collected
  needs root: 4 not collected, 2 partial
  needs root or CAP_SYS_ADMIN: 1 not collected, 4 partial
  other reasons: 3 not collected
Re-run with sudo for the full bundle.
Details: unzip -p xe-bug-report-20261110T163000Z.zip manifest.json (or run with --verbose)
```

With `--json`, stdout is one object (`status`, `file`, `collected`,
`truncated`, `skipped`, `timed_out`, `failed`, `bytes`), or on failure
`{"errno": 1, "error": "..."}`.

## Configuration file

Optional, read only when it exists: `~/.config/xe-bug-report/config`
(`$XDG_CONFIG_HOME/xe-bug-report/config` when set;
`%APPDATA%\xe-bug-report\config` on Windows).

```ini
[tools]
xpu-smi = <dir>/xpu-smi
iclg = <dir>/iclg

[search]
# Searched, in order, for every tool without its own line, before PATH.
dir = <dir>
```

- `[tools]` names one executable per tool by command name (`xpu-smi`,
  `iclg`, `lspci`, `clinfo`, `vulkaninfo`, ...). A relative path is taken
  from the file's directory. An entry that is not an executable file is
  warned about and ignored.
- `--xpu-smi` wins over the file.
- The file decides which programs run, so it is refused when others can
  write to it or it belongs to anyone but the running user, root, or (under
  sudo) the user who ran sudo. A broken or untrusted file stops the run with
  exit code 1.
- `sudo` usually switches to root's home, so it reads root's file. To keep
  your own: `sudo --preserve-env=HOME,XDG_CONFIG_HOME xe-bug-report`.
- `system/env.txt` in the bundle records where each tool was found.

## Profiles

| Profile | Selected by | Contents |
|---|---|---|
| `minimal` | `--minimal` | Versions, current-boot kernel log, PCI identity and link state, device sysfs attributes, package list, `xpu-smi` discovery. No samples. |
| `default` | no flag | `minimal` plus host layout, previous-boot log, debugfs, PCI detail, per-device `xpu-smi` queries and samples. |
| `full` | `--full` | `default` plus large or slow sources: the system log, the full `clinfo` dump and memory limits (Linux); `dxdiag` and the raw System event log (Windows). |

Use `default` unless the bundle is too large or the machine too slow; use
`full` when the user-mode stack (OpenCL, Vulkan) is in question.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | The archive was written, whatever was skipped. Also `--list`, `--help`, `--version`. |
| 1 | Invalid arguments, a `--device` not present, an output that exists or cannot be created, a write failure, or a broken or untrusted configuration file. Nothing was written. |
| 124 | The backstop fired: collection did not finish 60 s after the `--timeout` deadline. No archive is left. |

## What is collected

`xe-bug-report --list` (with the options you will use) prints one row per
source: `PROFILE`, `NEEDS` (the access gate), `PATH` and `WHY`. That is the
authoritative list for the installed version; the README "What is
collected" section has the full Linux and Windows tables with notes.
Summary:

- **Linux**: OS release, kernel, command line, modules, taint flags and
  `xe` build (`system/state.txt`), environment variables that change GPU
  runtime behaviour (`system/env.txt`), ICD and driver-config files, DMI
  model and BIOS, current and previous-boot kernel log plus extracts
  (`kernel/kmsg-extract.txt`: firmware lines, first and last 200 error
  lines; read these first), `xe`/`i915` `modinfo`, kernel config symbols,
  modprobe options, firmware files; per GPU: runtime power state read before
  anything wakes it (`devices/<dev>/power.txt`), sysfs attributes, links,
  BARs, IOMMU, display, debugfs, device coredumps and PMT crash logs
  (`dumps/<dev>/`), `drm-ras` counters; PCI link chain to the root port,
  `lspci` output; GPU-related packages and repositories; user-mode tools
  (`clinfo`, `vainfo`, `vulkaninfo`, `eglinfo`, `sycl-ls`,
  `intel_gpu_top`, `icpx`, `coredumpctl`); `xpu-smi` discovery, topology,
  stats, config, health, processes, RAS counters, RAS log, crash log
  (`iclg`), samples.
- **Windows**: OS, `systeminfo`, environment, WMI video controllers and
  display drivers, monitors without serials, power settings, GPU counters,
  VBS state, `bcdedit`, `pnputil`, registry keys for display, DirectX and
  compute-runtime debug keys, TDR and crash-dump settings, System and
  Application events, ETW providers, `setupapi.dev.log`, crash dump and WER
  report listings (dumps never copied), driver and UMD versions, `dxdiag`
  (`--full`), and the same `xpu-smi` views. Health, RAS log, crash log,
  coredumps and `drm-ras` exist on Linux only.

`<dev>` in a path is the PCI address with `-` for `:`, for example
`0000-03-00.0`.

## Access required

An ordinary user collects most of the bundle. Denied sources are not
errors: the archive is still written and the manifest records each as
`skipped` or `truncated` with the gate it needs.

| Gate | Needs | Covers |
|---|---|---|
| `kernel_log` | root, CAP_SYSLOG, the `adm` or `systemd-journal` group, or `sysctl kernel.dmesg_restrict=0` | kernel logs, `system/syslog` |
| `device_access` | the `render` group, or root | `xpu-smi` queries and the user-mode tools |
| `root` | root | debugfs, coredumps, firmware crash logs, `drm-ras` counters, owner-only sysfs, most `xe` module parameters, `drm.debug` mask, DMI serials, `iclg`, detailed `xpu-smi discovery`, other users' DRM clients |
| `sys_admin` | root or CAP_SYS_ADMIN | PCI config space past 64 bytes (`lspci -vvv` link and AER detail, `lspci -xxxx`), `/proc/iomem` addresses |
| `elevated` | an Administrator prompt (Windows) | crash dump listings, WER kernel reports, power requests, `bcdedit` |

Debugfs is root-only by default on Linux, so a hang or fault report needs a
root run to include GuC state, engine state and coredumps. A first run as
an ordinary user is safe: nothing more is requested. If the report says
`denied even with root privileges (kernel lockdown, container or security
policy)`, the cause is outside the tool.

## Privacy

Redaction is on by default. Before anything is written, every text source
and every JSON string value has these replaced:

| Token | Replaces | Manifest rule |
|---|---|---|
| `<serial>`, `<uuid>` | serial numbers and UUIDs | `serials` |
| `<host>` | this machine's names, short and fully qualified (and their non-public domains, and the machine id) | `hostname` |
| `<user>` | invoking and login user names, including in home directory paths | `users` |
| `<ipv4>`, `<ipv6>`, `<mac>` | IP and MAC addresses | `addresses` |

Never collected, even with `--no-redact`: the PCIe Device Serial Number,
monitor and battery serials, repository keys and repository URLs that look
like they carry credentials or tokens, environment variables outside an
allowlist (credential-like names dropped), Windows crash dumps, and the UI
text, module lists, paths and machine name of WER reports.

Opt-in: `system/dmi-serials/` (only with `--no-redact`, as root);
`kernel/System.evtx` (only `--full --no-redact`); `system/syslog` (only
`--full`, redacted).

Do not use `--no-redact` for a bundle that leaves the machine unless the
contributor asks for it.

**Still check before sharing.** Redaction is pattern-based. Review:

- device coredumps (`dumps/<dev>/devcoredump-N.txt`): GPU state, command
  stream snapshots and the faulting process name and pid, as the driver
  wrote them;
- `packages/repositories.txt`: a private host name in a repository URL is
  not recognised;
- any identifier a pattern misses, such as a host name inside a longer
  word, other people's names in process lists, internal project names in
  paths;
- the manifest `identity` key: `partial` means the lookup of this machine's
  names timed out and a fully qualified name may remain.

A quick check before attaching (replace the words with this machine's host
name, user names and domain):

```sh
mkdir <review-dir> && cd <review-dir> && unzip -q ../<bundle>.zip
grep -rniI -e '<hostname>' -e '<username>' -e '<domain>' . | head
```

Text you paste into a report yourself (log excerpts, command output) is
not redacted by the tool; remove host names, IP and MAC addresses, user
names, home directory paths and serial numbers from it.

## Bundle layout and manifest

```text
xe-bug-report-<time>.zip
  manifest.json      last entry
  xpu-smi/           version, discovery, topology, raslog/, <dev>/...
  system/            OS, hardware and process environment
  kernel/            kernel log and extracts, modules, parameters, event logs
  devices/<dev>/     power, sysfs, BARs, IOMMU, display, debugfs, drm-ras (Linux); listings (Windows)
  pci/               lspci per GPU and upstream bridge (Linux)
  dumps/<dev>/       device coredumps and firmware crash logs (Linux); dump listings (Windows)
  packages/          GPU stack packages, or the driver list (Windows)
  tools/             clinfo, vainfo, vulkaninfo, ... (Linux); dxdiag (Windows, --full)
```

`manifest.json` (schema `1`) top-level keys: `schema`, `tool` (version,
commit, build time), `created`, `os`, `profile`, `since_minutes`,
`devices`, `redaction` (active rules; empty with `--no-redact`),
`compression`, `identity` (only when degraded), `xpu_smi`, `sources`.

Each `sources` entry has `path`, `status`, and as applicable `via` (the
command or file), `gate`, `reason`, `exit` (128 + signal when killed),
`bytes`, `files`, `denied`, `ms`.

| `status` | Meaning |
|---|---|
| `collected` | read completely |
| `truncated` | partly in the archive: size cap, some files denied (`reason` says how many, `gate` what would give the rest), or only the tail kept |
| `skipped` | nothing written; `reason` says why: denied (with `gate`), absent, tool not installed, unsupported, withheld by redaction, an earlier read in the group hung, or the deadline was reached |
| `timed_out` | the source missed its time limit, or a file read did not return within 5 s |
| `failed` | ran with no usable result: non-zero exit with no output, a non-denial error, or a signal |

Start triage with the manifest, not the files:

```sh
unzip -p <bundle>.zip manifest.json | jq -r '.sources[] | select(.status != "collected") | [.status, .gate // "-", .path, .reason // ""] | @tsv'
```

Then read `system/id.txt` (which user, groups and capabilities the run had:
many `root` skips from an unprivileged run are expected),
`kernel/kmsg-extract.txt`, `system/state.txt` (taint flags; a `W` means a
warning fired), `devices/<dev>/power.txt` and `pci/<dev>/link-chain.txt`.
A `timed_out` source followed by `an earlier read in this group did not
return within 5 s` means the device or its sysfs/debugfs hung: that is a
finding, not a tool failure.

## Hang safety

- Each file read runs on a helper thread with a 5 s limit; each child
  process has its own limit (10 s by default, longer for slow sources) and
  is killed with its process group (Linux) or job object (Windows).
- Sources are grouped (each GPU; user-mode tools; the DRM client scan; home
  and working directory files; the host). When a read in a group hangs, the
  rest of that group is skipped instead of hanging too.
- `--timeout` bounds the run; at the deadline remaining sources are
  `skipped` (`collector deadline reached`) and the archive is still
  written. A backstop exits with 124 sixty seconds later.
- A child in uninterruptible kernel sleep cannot be killed and may outlive
  the run on Linux.
- No signal handler: Ctrl-C, SIGTERM or SIGHUP leave `<output>.partial`.
  Delete it and run again.
- debugfs files that can change state or write to the kernel log
  (`*force*`, `*reset*`, `*inject*`, `fail_*`, `*dmesg*`, `*lfd*`,
  `forcewake_all`, `wedged_mode`) are never read. Child processes run with
  core dumps disabled.

## Attaching the bundle to a report

1. Check the bundle as in "Privacy". Then show the contributor what will be
   shared; sharing is their decision.
2. Name the bundle in the report and quote the few lines that matter
   (redacted) in the text: the first error in `kernel/kmsg-extract.txt`,
   the versions, the `status` of key sources.
3. Where to attach depends on the tracker:
   - GitHub issues (IGC, compute-runtime, Level Zero, Modular,
     xe-bug-report): attach the zip to the issue.
   - The xe kernel driver tracker: Intel's guide asks for logs attached as
     individual files rather than archives, so attach the relevant files
     from the bundle (kernel log, `system/state.txt`, the coredump) one by
     one.
4. Skill `intel-tool-bugs` covers reducing a problem in IGC, compute-runtime
   or Level Zero to a reproduction; skill `agent-issues-and-prs` covers
   where a report goes, what it contains and the note an agent must put on
   it.

## Pitfalls

- Running after a reboot or `modprobe -r xe`: the coredump and debugfs
  state are gone. Run first.
- A run as an ordinary user that "misses" debugfs is expected; check
  `system/id.txt` before calling a skip a bug.
- `xpu-smi/<dev>/discovery.json` without root can make `xpu-smi` crash
  (`failed`, `killed by signal 11 (SIGSEGV)`); that is recorded, not fatal.
- `--since` with no kernel messages writes "no kernel messages in the last
  <window>" and the source is still `collected`.
- `sudo` reads root's configuration file, not yours.
- `--json` puts the per-gate breakdown only in the manifest.
- A link marked slow in `pci/<dev>/link-chain.txt` at idle is not yet a
  fault: GPUs lower the link at idle; take a loaded sample.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `needs ...` lines in the report | Missing access; the bundle is usable; re-run with sudo if the contributor agrees. |
| every `xpu-smi/*` source `skipped`, `xpu-smi not found` | Install XPU Manager or pass `--xpu-smi <path>`. |
| `<path> already exists` (exit 1) | Choose another `--output` or remove the file. |
| `No Intel GPU with PCI address ... was found` (exit 1) | Check with `lspci -nn`; write `dddd:bb:dd.f`; or drop `--device`. |
| `the collection did not finish in time` (exit 124) | Re-run with `--minimal`, a larger `--timeout`, or `--timeout 0`. |
| a `.partial` file is left | The run was killed. Delete it and run again. |
| `identity: partial` in the manifest | A fully qualified host name may remain; review before sharing. |
| `warn: --xpu-smi <path>: not an existing file` | Fix the path; `xpu-smi` sources are skipped. |

Check an archive with `unzip -t <bundle>.zip`.

## References

- xe-bug-report `README.md`: every table above in full, with notes per
  source.
- xe-bug-report `CONTRIBUTING.md`, and skill `xe-bug-report-develop`, to
  change the tool.
- Skills `intel-gpu-fault-recovery`, `intel-tool-bugs`,
  `agent-issues-and-prs`, `intel-gpu-environment`.

> [!TIP]
> Further reading (free, external; not maintained here):
> - [How to file i915 and Xe bugs](https://drm.pages.freedesktop.org/intel-docs/how-to-file-i915-bugs.html): Intel's guide to the xe and i915 trackers and what a kernel driver report contains.
> - [drm/xe kernel documentation](https://docs.kernel.org/gpu/xe/index.html): the xe driver's docs (coredump, debugging, firmware, wedging, power management).
> - [Xe device coredump](https://docs.kernel.org/gpu/xe/xe_devcoredump.html): where xe writes a coredump after a hang and how it is cleared.
> - [DebugFS](https://docs.kernel.org/filesystems/debugfs.html): why debugfs is root-only by default.
> - [Tainted kernels](https://docs.kernel.org/admin-guide/tainted-kernels.html): how to read the taint flags in `system/state.txt`.
> - [Intel XPU Manager](https://github.com/intel/xpumanager): the project that provides `xpu-smi`.
> - [Intel Crash Log](https://github.com/intel/crashlog): the project that provides `iclg`.
> - [jq manual](https://jqlang.org/manual/): `select()` and `@tsv` as used in the manifest triage command.
