---
name: igc-bisect
description: Bisect Intel's graphics compiler (IGC) for the commit that introduced or fixed a miscompile, crash or wrong result seen from Mojo or MAX, with release builds in one incremental build tree, a cached per-commit probe for git bisect run, and a check of the answer.
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Bisecting IGC

Use this when a result differs between two IGC versions (a bug fixed in a
newer release, or a regression) and you want the IGC commit responsible.
It assumes you can build IGC from source (skill `intel-stack-from-source`)
and have a reproduction that runs unattended: a Mojo-free one from
`plugins/intel/tests/intel-tools/` or one you wrote (skill
`intel-tool-bugs`), or a MAX test such as
`plugins/intel/utils/run-max-py plugins/intel/tests/graph/attention.py`.

Budget: the first IGC build takes about 30 minutes, each later commit
2 to 10 minutes, and a bisect over about 650 commits needs about 10 builds
per question. One series of bisects behind
`plugins/intel/docs/intel-tools-issues.md` took 43 builds and about 5 hours
for ten answers, the builds shared between them.

## 1. Confirm the change is IGC's

Run the reproduction with each IGC under the same compute-runtime, and
each compute-runtime with the same IGC (skill `intel-stack-from-source`,
"Mix one stack's IGC with another's compute-runtime"). Bisect IGC only when
the result follows the IGC. If it follows neither, the cause is the kernel
driver, the firmware or the environment; bisecting IGC will not find it.

Use an empty `NEO_CACHE_DIR` (or `NEO_CACHE_PERSISTENT=0`) for every run,
and an empty `MODULAR_CACHE_DIR` for MAX: a cached kernel is not compiled,
so the IGC under test never sees it.

## 2. Pick the ends

IGC's release branches (`releases/2.42.x`, ...) fork from master and then
take a few commits of their own, including cherry-picks with new ids.
Bisect master's linear history between:

- **Old end:** where the older release's branch forks from master:

  ```sh
  git -C <igc-src> merge-base v2.41.5 origin/master   # b50679576d for 2.41.5
  ```

  Build it first and check that it gives the older release's result on
  every case. The 2.41.5 package is that fork point plus five commits; the
  fork point gave the package's results on every reproduction.
- **New end:** a master commit that gives the new result, for example the
  head of master, or the merge base of the newer release tag with master.

If the change is only on a release branch (not on master), bisect that
branch's commits after the fork point instead.

Count the range: `git -C <igc-src> rev-list --count <old>..<new>`.

## 3. Hold everything but IGC fixed

- One workspace with IGC's dependencies at fixed commits (LLVM,
  opencl-clang, SPIRV-LLVM-Translator, vc-intrinsics, SPIRV-Tools,
  SPIRV-Headers), chosen for the new end (skill `intel-stack-from-source`,
  "Pick matching versions"). The 43 commits built in the IGC 2.42/2.43
  master range built with LLVM 22.1.8 and that set, except one that failed
  and was skipped; for other commits and ranges, not verified.
- **Release builds**, like the packages. An assertion build can stop at an
  assertion where a release build computes the right result, which hides
  the answer.
- The installed compute-runtime and loader, with the bisect IGC mixed in
  (the `igc` mode of the stack wrapper). One compute-runtime for all
  commits.

## 4. Build each commit incrementally

[`build-igc.sh`](build-igc.sh) checks out a commit, applies optional
patches, configures and builds IGC in one build tree, and installs it
into a prefix. It follows a method that has bisected IGC's 2.42/2.43
master range, but this script itself passes shellcheck and has not been
run against a real IGC tree: read it before the first build.

```sh
WS=<ws> BUILD=<build-dir> PREFIX=<prefix> LLVM_VERSION=22.1.8 \
  sh build-igc.sh <commit> [patch...]
```

`<ws>/igc` must be a checkout used for nothing else: the script runs
`git checkout -f` and `git clean -fdq` there. Run builds under `nice` and
log them; a full build is about 4,900 Ninja steps.

Build pitfalls the script handles (each seen on the 2.42/2.43 master range):

- **C++ standard on reconfigure.** IGC sets `CMAKE_CXX_STANDARD 20` as a
  normal variable, and LLVM caches 17. A configure of an existing tree then
  builds LLVM as C++20 (GCC 16 rejects LLVM's `Dominators.cpp`) and
  rebuilds all of it. Configure with `-UCMAKE_CXX_STANDARD` every time.
- **`AdaptorCommon` on every include path.** From commit `ae45cdd5e` on,
  IGC adds its build's `AdaptorCommon` directory to every target's include
  path, LLVM's too, so crossing that commit rebuilds LLVM. The script
  generates `DriverBuildId.h` beside its one user and drops the include
  directory.
- **Missing generated-header dependency.** Commits around `f3f3dc640`
  (September 2026) lack the dependency of `BiFManager` on its generated
  `OCLBiFImpl.h`, so an incremental build can fail. The script builds
  everything else with `ninja -k 0` and retries once.
- **`-Werror`.** IGC adds it with no option to turn it off; the script
  removes it from `IGC/CMakeLists.txt` after each checkout.

One pitfall the script does not handle:

- **IGC's LLVM patch set changes.** IGC patches its copy of LLVM from
  `external/llvm/releases` in its build tree (under
  `<build-dir>/IGC/llvm-deps-<llvm>/` in the builds observed). Seven commits
  in the 2.42/2.43 range changed that directory, three of them the LLVM 22
  patches. Newer IGC re-copies all of
  LLVM when the set changes (a full LLVM rebuild); older IGC never
  re-patches, so its build would use stale LLVM sources. Check whether a
  range touches it: `git -C <igc-src> log --oneline <old>..<new> -- external/llvm/releases`.
  If it does, either accept full rebuilds at those commits, or, when the
  tree at `HEAD:external/llvm/releases` differs from the last build, patch
  a fresh copy of LLVM with that commit's `external/llvm/apply_patches.py`
  and copy only the files that differ into the build tree's copy
  (`rsync -r --checksum`), so that unchanged files keep their timestamps.
  Read `python3 external/llvm/apply_patches.py --help` at your commits for
  its options; they changed in the range.

## 5. A cached probe for `git bisect run`

`git bisect run` reads the script's exit code: 0 means good (or the old
term), 1 to 127 except 125 bad (or the new term), 125 skip this commit,
and anything else stops the bisect.

[`bisect-probe.sh`](bisect-probe.sh) builds the commit once, runs a probe
that reports every failing case, and stores that list, the commit's
signature, in `<out>/cache.tsv`. Every later question about the same commit
reads the cache, so one set of builds answers several bisects. The probe is
yours to write (`<run-on-stack.sh>` is the wrapper in skill
`intel-stack-from-source`): given a directory, it prints the names of the failing
cases one per line and exits 0 when it got results.

```sh
cat > <out>/probe.sh <<'EOF'
#!/bin/sh
# Prints the failing cases; exit non-zero when there is no result.
d=$1
mkdir -p "$d/neo"
sh <run-on-stack.sh> igc <prefix> "$d/neo" \
  sh <fork>/plugins/intel/tests/intel-tools/<slug>/run.sh >"$d/run.log" 2>&1
grep -q '<line that shows the run completed>' "$d/run.log" || exit 1
grep -q '<pattern of case A failing>' "$d/run.log" && echo caseA
grep -q '<pattern of case B failing>' "$d/run.log" && echo caseB
exit 0
EOF

cd <ws>/igc
export OUT=<out> BUILD_CMD="sh <path>/build-igc.sh" PROBE_CMD="sh <out>/probe.sh"
export WS=<ws> BUILD=<build-dir> PREFIX=<prefix> LLVM_VERSION=22.1.8
git bisect start <new> <old>                 # a regression: <new> bad, <old> good
git bisect run sh <path>/bisect-probe.sh caseA
git bisect log > <out>/bisect-caseA.log
git bisect reset
```

For a fix, name the terms so the answer reads right:

```sh
git bisect start --term-old=broken --term-new=fixed
git bisect fixed <new>
git bisect broken <old>
MODE=fix git bisect run sh <path>/bisect-probe.sh caseA
```

- Probe both ends first (`sh bisect-probe.sh --probe-only` at each) and
  check that every case you bisect differs between them.
- Before each later bisect, mark the commits already in the cache as good
  or bad for that case (`git bisect good <commit>` / `bad`, or `broken` /
  `fixed`) so it starts from what is known.
- Keep the signature, not one bit. Two changes can overlap in time: in the
  attention bisect the probed commits showed the prefill cases going wrong
  and right again within master while the decode case went wrong later.
  A per-case signature shows that; a single pass/fail would mix them.
- Include a throwaway GPU process after a probe that may fault the GPU
  (skill `intel-gpu-fault-recovery`), or the next commit's probe can hang
  and be blamed.

Probe time is usually small next to build time (about 1 minute for the
Mojo-free reproductions; up to 15 minutes allowed for MAX's attention test).

## 6. Confirm the answer

- **Parent and commit, same tree.** Build `<answer>^` and `<answer>` in
  the same build tree with the same dependencies; the parent must give the
  old result and the commit the new one, for every case it answers.
- **Consistency of every probed commit.** Every probed ancestor of the
  answer must show the old result and every probed descendant the new one:

  ```sh
  while IFS='	' read -r c st fails; do
    [ "$st" = ok ] || continue
    case ";$fails;" in *";caseA;"*) r=fail ;; *) r=pass ;; esac
    if git merge-base --is-ancestor "$c" <answer>^; then side=before; else side=after; fi
    echo "$side $r"
  done < <out>/cache.tsv | sort | uniq -c
  ```

  Each side must show one result only. A mixed side means flakiness, a
  second change, or a dependency that moved.
- **First tag:** `git -C <igc-src> tag --contains <answer> | sort -V | head -1`.
  For a release branch, look for a cherry-pick by subject:
  `git -C <igc-src> log --oneline --grep='<subject>' origin/releases/<x>`.
  For example, IGC `8fa5a563d7f8` reached `releases/2.42.x` as `2be8e223e`.

Record the range, the dependency set, the number of builds and their
times, the answer with its subject and date, the first tag, and the
confirmation in the reproduction's README (skill `intel-tool-bugs`).

## 7. When a revert does not apply

Reverting the answer on a newer IGC is the next test (does the newer
release work without it?), and it may not apply:

- Try `git revert --no-commit <answer>` (or `git show <answer> | git apply -R -3`)
  on the newer commit and resolve conflicts by hand where the change is
  mechanical. Example: reverting `0221e64d2` on v2.43.9 needed one hunk of
  `TypesLegalizationPass.cpp` by hand (`uint64_t` where the commit had
  `unsigned`). Keep the result as a patch and say it was hand-resolved.
- When later commits rewrote the same code (reverting `e88560098464` on
  master `bd0ad0a5` failed: later commits regenerated the same emulation
  libraries), do not force it. The parent-and-commit pair in one tree is
  the evidence; state that the revert on newer IGC was not possible and
  why.
- A revert that applies but builds a different program than the parent
  (because the files moved on) answers a different question; say so.

> [!TIP]
> Further reading (free, external; not maintained here):
> - [git-bisect(1)](https://git-scm.com/docs/git-bisect): `bisect run` and its exit codes (125 skips a commit), and custom terms with `--term-old`/`--term-new`.
> - [git-merge-base(1)](https://git-scm.com/docs/git-merge-base): the fork point of a release branch, and `--is-ancestor` for the consistency check.
> - [git-revert(1)](https://git-scm.com/docs/git-revert): reverting without committing (`--no-commit`) to test a newer IGC without one change.
> - [IGC: build instructions](https://github.com/intel/intel-graphics-compiler/blob/master/documentation/build_ubuntu.md): the build the bisect repeats per commit.
> - [IGC releases](https://github.com/intel/intel-graphics-compiler/releases): which tags exist and what each release lists as its dependencies.
> - [CMake: CMAKE_CXX_STANDARD](https://cmake.org/cmake/help/latest/variable/CMAKE_CXX_STANDARD.html) and [policy CMP0126](https://cmake.org/cmake/help/latest/policy/CMP0126.html): how a normal variable and a cache entry of the same name interact, behind the C++20 reconfigure pitfall.
> - [CMake: DESTDIR](https://cmake.org/cmake/help/latest/envvar/DESTDIR.html): installing a build somewhere other than its configured prefix.

## Pitfalls

- Results from a warm `NEO_CACHE_DIR` belong to whatever IGC filled it.
- Do not bisect with an assertion build unless the question is the
  assertion.
- `git clean -fdq` in the IGC checkout deletes untracked files there; keep
  patches and probe scripts outside it.
- `git bisect run` stops on exit codes above 127 (a probe killed by a
  signal); make the probe catch crashes and report them as a case or as
  "no result".
- A build failure must exit 125 (skip), never 1; the probe script does
  this, a hand-written one may not.
- Commit ids here are from `plugins/intel/docs/intel-tools-issues.md` and
  the IGC repository; check them with `git -C <igc-src> show --stat <id>`.

## References

- `plugins/intel/docs/intel-tools-issues.md` in the fork: the ranges and
  answers of earlier bisects ("Fixed in", "IGC 2.42 and 2.43: NaN in paged
  flash attention").
- Skills `intel-stack-from-source`, `intel-tool-bugs`,
  `intel-gpu-fault-recovery`.
- IGC: https://github.com/intel/intel-graphics-compiler
  (`documentation/build_ubuntu.md`, `external/llvm/`).
