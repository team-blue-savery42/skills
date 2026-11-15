> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Skills for agents working on Intel GPU support in Mojo and MAX

Instructions for coding agents that help contributors with Intel GPU
support in Modular's Mojo and MAX
([team-blue-savery42/modular](https://github.com/team-blue-savery42/modular),
branch `intel/bringup`) and with
[xe-bug-report](https://github.com/team-blue-savery42/xe-bug-report).

Start with [AGENTS.md](AGENTS.md): the ground rules for every agent,
including the note an agent puts on every issue or pull request it opens.
[CONVENTIONS.md](CONVENTIONS.md) describes how a skill is written.

## Skills

| Skill | Use it to |
|---|---|
| [intel-gpu-environment](skills/intel-gpu-environment/SKILL.md) | check and identify a machine's Intel GPU stack: driver, compute-runtime, IGC, Level Zero, permissions, targets |
| [mojo-max-intel-build](skills/mojo-max-intel-build/SKILL.md) | build the fork and run Mojo programs and MAX models on an Intel GPU |
| [intel-plugin-checks](skills/intel-plugin-checks/SKILL.md) | run the plugins' checks and MAX's GPU test gate, and read or update the expected results |
| [intel-gpu-fault-recovery](skills/intel-gpu-fault-recovery/SKILL.md) | recognise a GPU page fault, recover the GPU for the next process, and collect what a report needs |
| [intel-compiler-plugin](skills/intel-compiler-plugin/SKILL.md) | work on the codegen plugin that lowers Mojo kernels to SPIR-V for IGC |
| [intel-driver-plugin](skills/intel-driver-plugin/SKILL.md) | work on the Level Zero HAL driver plugin |
| [intel-kernels](skills/intel-kernels/SKILL.md) | write or port MAX kernels for Intel GPUs (DPAS, 2D block I/O, sub-groups) |
| [intel-performance](skills/intel-performance/SKILL.md) | profile, read IGC's ISA, and benchmark MAX on Intel GPUs |
| [intel-quantization](skills/intel-quantization/SKILL.md) | run, add or check quantized weight formats (FP8 today; 4-bit and others missing) for MAX on Intel GPUs |
| [intel-tool-bugs](skills/intel-tool-bugs/SKILL.md) | find whether IGC, compute-runtime or Level Zero is at fault, reduce it to a reproduction without Mojo, and write it up |
| [intel-stack-from-source](skills/intel-stack-from-source/SKILL.md) | build IGC, compute-runtime, gmmlib and the Level Zero loader from source and run against them |
| [igc-bisect](skills/igc-bisect/SKILL.md) | bisect IGC for the commit that introduced or fixed a behaviour |
| [xe-bug-report-collect](skills/xe-bug-report-collect/SKILL.md) | collect a redacted diagnostic bundle for a GPU, driver or runtime problem |
| [xe-bug-report-develop](skills/xe-bug-report-develop/SKILL.md) | contribute to xe-bug-report |
| [github-markdown-preview](skills/github-markdown-preview/SKILL.md) | preview Markdown exactly as github.com renders it, also for files on a remote host |
| [agent-issues-and-prs](skills/agent-issues-and-prs/SKILL.md) | open or draft issues, pull requests and upstream bug reports, with the agent disclosure note |

## Using the skills

- **Claude Code**: copy or link each `skills/<name>/` directory into
  `~/.claude/skills/` (all projects) or `<project>/.claude/skills/`.
  Claude reads `CLAUDE.md`, which points to `AGENTS.md`.
- **Other agents**: point the agent at `AGENTS.md` (many read it from a
  repository root automatically) and at the `SKILL.md` files a task
  needs. Each `SKILL.md` is plain Markdown after its front matter.

## Status

The skills describe the fork as of its `intel/bringup` branch and the
tested stack named in `AGENTS.md`. They were checked against those
sources when written; commands that need an Intel GPU were not all run
again for this repository. Corrections are welcome as pull requests.
