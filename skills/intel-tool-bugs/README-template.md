> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

<!-- Copying this template into the fork: drop the note above together with
this comment block; the reproduction README is the author's file. -->

<!--
Template for plugins/intel/tests/intel-tools/<slug>/README.md in the fork.
Slug: <component>-<what-goes-wrong>, component one of igc, compute-runtime,
level-zero, llvm-spirv (for example igc-vector-log2-lanes).
The title is the issue's section title in docs/intel-tools-issues.md.
Delete this comment and every line in angle brackets you do not fill.
-->

# <Component>: <what goes wrong, in one line>

`<file>.ll` (or `.spvasm`, `.cl`, `.spv`) is <what the kernel does, and
which Mojo or MAX code it was reduced from>. `run.sh` <what it does: builds
it with `clang -target spirv64` / `spirv-as`, checks it with `spirv-val`,
builds it for `bmg-g31` with `ocloc` / runs it through Level Zero with
`run-<name>.cpp`, with IGC's default optimization and with
`-cl-opt-disable`>.

```sh
sh run.sh
```

It needs <`clang` with the `spirv64` target, `spirv-val`, `spirv-as`,
`clang++`, `ocloc`> and <a `bmg-g31` GPU on Level Zero | no GPU>.
<`run.sh` uses the `ocloc` on `PATH`, which loads its own IGC.>

## Expected and actual

<What the right result is, and why (host reference, specification).>
With IGC <version> <what happens>:

```text
<run.sh output, trimmed to what shows the bug>
```

| IGC (compute-runtime)     | <Default build> | `-cl-opt-disable` | <`IGC_EnableVectorizer=0`> |
|---------------------------|-----------------|-------------------|----------------------------|
| 2.41.5 (26.35.39758)      |                 |                   |                            |
| <v2.42.x> (<26.40.x>)     |                 |                   |                            |
| <v2.43.x> (<26.44.x>)     |                 |                   |                            |
| <master `<commit>`>       |                 |                   |                            |
| <with `fix.patch`>        |                 |                   | -                          |

<Mix result: "Running each IGC with the other compute-runtime gives the
IGC's result, so the change is IGC's." or what it showed instead.>
<Which nearby variants are right (other widths, types, options), and what
was not measured.>

<In Mojo or MAX: where it appeared and what it broke (test names, files).>

<Use exactly one of the two sections below.>

## Fixed in

IGC commit `<12-char id>`, "<subject>" (<commit date>), first in
<first tag>. <How it was found: bisect range, release builds, dependencies
held fixed; parent right and commit wrong in the same build tree.>

## Cause and patch

<Where the bug is: function, file under IGC's tree, what it does wrong.>
<Commits that changed the symptom without fixing it, with first tags.>

`fix.patch` <what it changes>. It is against IGC <commit or tag> (MIT, like
IGC). With it, <a release build of ...> <result>. <IGC's lit tests
(`check-igc`): new failures or none.> <What was not examined.>
