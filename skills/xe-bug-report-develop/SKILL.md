---
name: xe-bug-report-develop
description: Change or extend xe-bug-report, the Rust GPU diagnostic collector - crate layout, code rules (SPDX header, unsafe only in sys/, no unwrap/expect, bounded reads through procio and the Guard), the checks CI runs, unit, end-to-end and golden-file tests, adding a collected source, dependency policy (cargo vet/deny/audit), commits, packaging and releases.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Develop xe-bug-report

For changes to the [xe-bug-report](https://github.com/team-blue-savery42/xe-bug-report)
crate itself. To *use* the tool, see skill `xe-bug-report-collect`.

The rules come from the repository's `CONTRIBUTING.md`, `Cargo.toml`,
`deny.toml`, `rust-toolchain.toml`, `rustfmt.toml`, `scripts/` and
`.github/workflows/`. Read them in the clone you work in; they win over
this file.

Toolchain: `rust-toolchain.toml` pins Rust 1.99.1 with `rustfmt`,
`clippy` and the `x86_64-pc-windows-msvc` target; `rust-version` (MSRV) in
`Cargo.toml` is 1.99; edition 2024. `rustfmt.toml` sets `max_width = 110`.
License: MIT.

## Crate layout

`src/lib.rs` exposes the modules; `src/main.rs` is the binary.

| Path | What it holds |
|---|---|
| `src/sources/` | The source table: `mod.rs` (shared table, `xpu-smi` views and markers), `linux/` (one module per area: `kmsg`, `debugfs`, `pcie`, `pci_config`, `display`, `drm_ras`, `drm_clients`, `pmt`, `coredump`, `state`, `system`, `packages`, `usermode`, `platform`, ...; `linux/mod.rs` builds the Linux table), `windows/` (`host`, `events`, `listings`, `wer`, `gpus`, `scripts`), `debug_keys.txt` (compute-runtime debug-key names). |
| `src/bundle/` | OS-free model: `source.rs` (`Source`, `Spec`, `Profile`, `Gate`, `Status`, `Reader`, `Produced`), `collect.rs` (runs sources under the Guard), `manifest.rs`, `summary.rs` (report and `--list`), `writer.rs`, `identity.rs`. |
| `src/redact/` | Redaction: `rules.rs` (text rules), `json.rs`, `names.rs`, `context.rs`, `bytes.rs`. |
| `src/procio/` | Bounded child processes (`run_child`), bounded file reads, private temp directories, PATH lookup; `unix.rs` and `windows.rs`. |
| `src/guard.rs` | `Guard`: runs a call on a detached thread with a limit; a call that misses it opens its group and later calls of the group return `None` at once. |
| `src/archive/zip.rs` | The zip writer. |
| `src/sys/` | The only `unsafe` code: thin wrappers over `libc` (`unix.rs`) and `windows-sys` (`windows.rs`). |
| `src/cli.rs`, `config.rs`, `pci.rs`, `units.rs`, `timefmt.rs`, `diag.rs`, `error.rs`, `build_info.rs` | Options, configuration file, PCI addresses, sizes, time formats, stderr logging, errors, build provenance. |
| `tests/` | `bundle_linux.rs`, `bundle_windows.rs` (end to end), `common/` (independent zip reader and checks), `golden/`. |
| `scripts/` | `package.sh`, `package-arch.sh`, `ci-supply-chain.sh`. |
| `packaging/` | `deb/control`, `rpm/xe-bug-report.spec`, `arch/PKGBUILD`. |
| `supply-chain/` | `cargo vet` audits, config and imports. |

## Code rules

From `CONTRIBUTING.md` and the lints in `Cargo.toml`:

- Every file starts with `SPDX-License-Identifier: MIT` (`// ` in Rust,
  `# ` in shell and TOML, `<!-- -->` in Markdown).
- `unsafe` is denied crate-wide (`unsafe_code = "deny"`,
  `unsafe_op_in_unsafe_fn = "deny"`). Only `src/sys/unix.rs` and
  `src/sys/windows.rs` allow it, and every block has a `// SAFETY:`
  comment (`clippy::undocumented_unsafe_blocks = "deny"`).
- No `unwrap` or `expect` outside tests (`clippy::unwrap_used` and
  `expect_used` are `deny`). Test modules opt out with
  `#[allow(clippy::unwrap_used, clippy::expect_used)]`. Input from the
  kernel, tools and file names never causes a panic; OS strings are
  converted lossily.
- Every read and every child process goes through the bounded helpers in
  `procio` and the `Guard`. In practice:
  - a `Spec::File`, `Spec::Tree`, `Spec::Command` or `Spec::XpuSmi` source
    is run bounded by the collector;
  - a `Spec::Builtin` gets a `&dyn Reader` for its file reads and runs
    under the Guard with the source's timeout; a builtin that must start a
    process calls `procio::run_child` with a timeout shorter than the
    source's (as `kmsg.rs`, `coredump.rs` and `pci_config.rs` do);
  - never `std::fs::read`, `File::open` or `Command::new` directly in a
    source: a hung sysfs or debugfs file blocks forever.
- Document what is not obvious from the name and signature; do not restate
  it.
- Never open a debugfs or sysfs file that can change state or write to the
  kernel log (see the patterns and the exclusions documented in
  `src/sources/linux/mod.rs` and `debugfs.rs`).

## Checks

Run before every push; CI (`.github/workflows/ci.yml`) runs the same,
except `shellcheck`:

```sh
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
cargo clippy --all-targets --locked --target x86_64-pc-windows-msvc -- -D warnings
cargo test --locked --all-features
cargo package --locked
scripts/ci-supply-chain.sh
shellcheck scripts/*.sh
```

- The Windows clippy runs on Linux (the target is in
  `rust-toolchain.toml`); the Windows tests run only on the
  `windows-latest` CI runner. Code under `#[cfg(windows)]` you cannot run
  must still pass that clippy.
- `scripts/ci-supply-chain.sh` needs `cargo-vet`, `cargo-audit` and
  `cargo-deny` (`cargo install --locked cargo-vet cargo-audit cargo-deny`,
  as CI does). It runs `cargo vet --locked`, `cargo audit --deny warnings`,
  `cargo deny --locked check`, and fails on any `-sys` crate other than
  `libc`, `windows-sys` and `linux-raw-sys`.
- Coverage: `cargo llvm-cov --all-features` (needs `llvm-tools-preview` and
  `cargo-llvm-cov`). CI reports it in `coverage.yml` and on Codecov;
  `quality.yml` runs SonarQube Cloud (`sonar-project.properties`).

## Tests

- **Unit tests** sit next to their module, in `<module>_tests.rs` wired
  with `#[cfg(test)] #[path = "<module>_tests.rs"] mod tests;`, or
  `tests.rs` in a module directory. They must not depend on a GPU,
  `xpu-smi`, root or a particular distribution: build input files in a
  temporary directory (`src/sources/linux/testkit.rs` has `FsReader`, a
  `Reader` over real files that records what was asked, and a tree
  builder).
- **End to end**: `tests/bundle_linux.rs` and `tests/bundle_windows.rs` run
  the binary and read the archive with the independent zip reader in
  `tests/common/`. They need no GPU and no `xpu-smi`; the sources that
  depend on them are expected to be skipped with a reason.
- **Golden files** (`tests/golden/`), updated by hand in the same commit as
  the change that moves them:
  - `linux-sources.txt`: the `--list --full` table (`PROFILE`, `NEEDS`,
    `PATH`, `WHY`) in table order. `summary_tests.rs` rebuilds it from its
    columns (header and padding must match exactly) and
    `bundle_linux.rs` checks that the binary's rows appear in it in order.
  - `windows-sources.txt`: Windows paths in table order (its header says it
    is to be replaced by the first Windows CI run's `--list --full`).
  - `manifest-keys.txt`: manifest keys per scope in emission order (`?` =
    conditional); `manifest-sample.json` and `manifest-default-sample.json`
    must follow it.
  - `linux-default-entries.txt`: a sample entry list of a default bundle
    (no test reads it at the time of writing; not verified whether it is
    meant to be kept in step).
  A change to a source row, profile, gate or `why` text updates the golden
  table in the same commit. Also update the matching table in `README.md`
  ("What is collected"); no test checks the README table, so it drifts
  silently.
- **Redaction timing** runs only in release builds:
  `cargo test --release --locked redact -- --ignored`. Run it after any
  change under `src/redact/`.
- The MSRV badge in `README.md` must match `rust-version`; a test
  (`build_info_tests.rs`) checks it.

## Adding a collected source

1. **Decide the row**: bundle path (`<area>/<name>.txt`, or a directory
   ending in `/`), profile (`Minimal`, `Default`, `Full`: the smallest
   that should include it), gate (`None`, `KernelLog`, `DeviceAccess`,
   `Root`, `SysAdmin`, `Elevated`), and a one-line `why` (it appears in
   `--list` and the golden table). Check that nothing it reads can change
   state, wake a suspended device needlessly, or leak personal data that
   the redaction rules cannot catch.
2. **Pick the spec** (`src/bundle/source.rs`): `Source::file`,
   `Source::tree` (patterns with `*` inside one path segment, symlinks never
   followed), `Source::command` (argv[0] looked up on PATH; `{outdir}` for
   a private temp directory), `Source::xpu_smi`, or `Source::builtin`
   (code over a `&dyn Reader`, returning `Vec<Produced>`). Set modifiers
   as needed: `.gate()`, `.timeout()` (default 10 s), `.cap()` (default
   16 MiB), `.tail()`, `.binary()` (not redacted), `.identifying()`
   (skipped while redacting), `.group()` (default `host`; per GPU
   `device:<bdf>`; user-mode tools `usermode`), `.keep_lines()`,
   `.denied_marker()`, `.unsupported_marker()`, `.available()`.
3. **Write the code** in the area module under `src/sources/linux/` or
   `src/sources/windows/` (a new module gets its own `_tests.rs`), and add
   the row in the table function of `linux/mod.rs` (`system_sources`,
   `kernel_sources`, `device_sources`, `late_host_sources`, `pci_sources`,
   `tool_sources`) or the Windows table, at the position that matches the
   golden order. Binary content needs `.binary()`; if it can hold personal
   data, also `.identifying()`.
4. **Unit-test** the parsing and the skip paths (missing file, denied,
   empty, malformed input, oversize) with temporary files, no GPU.
5. **Update** `tests/golden/linux-sources.txt` (or
   `windows-sources.txt`), the README tables and notes, and, if the
   manifest changes shape, `manifest-keys.txt` and the samples.
6. **Run all checks**, and `--list --full` on a real machine to see the
   row. If you can, run a bundle on a machine with an Intel GPU and check the
   new entry and its manifest row; say so in the commit or PR if you could
   not.

## Dependencies

- Prefer the standard library. A new crate needs a reason, a small
  dependency graph, no C build and no new `-sys` crate.
- Add it to `bans.allow` in `deny.toml` (direct and transitive crates are
  listed there on purpose; `multiple-versions` and `wildcards` are `deny`;
  licenses allowed: MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause,
  Unicode-3.0, Zlib; crates.io only).
- `cargo vet`, `cargo deny check` and `cargo audit` must pass; record new
  audits in `supply-chain/audits.toml`.
- `Cargo.lock` is committed; build with `--locked`. Review Dependabot
  updates with `cargo vet diff`.
- Open item (`CONTRIBUTING.md`): the exemptions in
  `supply-chain/config.toml` still need audits.

## Commits

- Subject `area: imperative summary`, at most 72 characters, for example
  `redact: treat percent-encoded separators as name boundaries`. Areas
  follow the module names; those in the history include `sources`,
  `redact`, `procio`, `bundle`, `archive`, `cli`, `config`, `build`,
  `ci` and `docs` (check `git log --oneline`).
- Body wrapped at 72 columns: the problem, then the change. No list of
  everything touched.
- One logical change per commit; each commit builds and passes the tests.
- End with `Signed-off-by: Name <email>` (`git commit -s`).
- Commit, push or open a pull request only when the contributor asks.
  Anything an agent opens follows skill `agent-issues-and-prs` (the
  disclosure note).

## Packaging and releasing

- `scripts/package.sh` builds the release binary into `dist/`: a
  `.tar.gz` always, a `.deb` when `dpkg-deb` exists, an `.rpm` when
  `rpmbuild` exists. `DEB_DIST=<tag>` (for example `deb12`,
  `ubuntu24.04`) names the `.deb` per distribution (version
  `<version>-1~<tag>`). The `.deb` depends on `libc6 (>= <glibc the binary
  references>)` and `libgcc-s1`.
- `scripts/package-arch.sh` builds the pacman package, its source tarball
  and the AUR `PKGBUILD` and `.SRCINFO`; it runs on Arch as a non-root
  user.
- Release: a version bump in `Cargo.toml` on `main` triggers
  `.github/workflows/release.yml`, which runs the full CI, builds the
  Debian, Ubuntu, RHEL, Arch and Windows packages and publishes GitHub
  release `v<version>`; crates.io and AUR publishing run only when their
  secrets are set. It can be re-run by hand (`workflow_dispatch` on
  `main`) when the version has no tag yet. Releasing is the maintainer's
  call; an agent does not bump the version unless asked.
- `.cargo/config.toml` links the C runtime statically on Windows; Cargo
  ignores it when `RUSTFLAGS` is set, so do not set `RUSTFLAGS` in CI.

## Pitfalls

- A direct `std::fs` read in a source passes every test on a healthy
  machine and hangs on a wedged GPU. Use the `Reader`.
- Forgetting the golden table: `bundle_linux.rs` and `summary_tests.rs`
  fail. Forgetting the README: nothing fails.
- Windows-only code compiles only under `--target x86_64-pc-windows-msvc`;
  run that clippy even for a Linux change that touches shared code.
- Reading a GPU attribute (frequency, residency, temperature) can wake a
  runtime-suspended device; `devices/<dev>/power.txt` is read first for
  that reason. Keep new per-device reads after it.
- A new redaction rule must not hit PCI addresses, versions or times; add
  negative tests and run the release timing test.

## References

- xe-bug-report `CONTRIBUTING.md`, `README.md`, `Cargo.toml`, `deny.toml`,
  `scripts/ci-supply-chain.sh`, `.github/workflows/`.
- `src/bundle/source.rs` for the `Source` builder; `src/guard.rs`;
  `src/procio/mod.rs` (`run_child` contract).
- Skill `xe-bug-report-collect` for the user-facing behaviour.

> [!TIP]
> Further reading (free, external; not maintained here):
> - [Clippy documentation](https://doc.rust-lang.org/clippy/): lint groups and levels, including `unwrap_used` as a restriction lint.
> - [Cargo Vet](https://mozilla.github.io/cargo-vet/): recording and checking audits of third-party crates.
> - [cargo-deny](https://embarkstudios.github.io/cargo-deny/): the advisories, bans, licenses and sources checks configured in `deny.toml`.
> - [cargo-audit](https://github.com/rustsec/rustsec/tree/main/cargo-audit): checks `Cargo.lock` against the RustSec advisory database.
> - [cargo-llvm-cov](https://github.com/taiki-e/cargo-llvm-cov): the coverage tool behind `cargo llvm-cov`.
> - [ShellCheck](https://www.shellcheck.net/): the shell script linter run on `scripts/`.
> - [Developer Certificate of Origin](https://developercertificate.org/): what `Signed-off-by` certifies.
