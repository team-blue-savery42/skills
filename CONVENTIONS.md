> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# How the skills are written

One directory per skill under `skills/`, named in lower case with
hyphens, holding a `SKILL.md` and, when needed, small helper files that
the `SKILL.md` refers to.

## SKILL.md layout

```markdown
---
name: <directory name>
description: <one or two sentences: what the skill does and when to use it, with the words a task would contain>
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# <Title>

<When to use it; what it assumes.>

## <Steps or sections>

## Pitfalls

## References
```

The front matter comes first because agent runtimes parse it; the note
follows it directly. Agents that do not read front matter can still use
the body as plain Markdown.

## Content rules

- Commands are copy-pasteable and use paths relative to the repository
  they run in (`plugins/intel/utils/check`, `./bazelw`), or placeholders
  in angle brackets (`<fork>`, `<outdir>`, `<model-dir>`).
- No host names, IP addresses, user names, home directory paths, local
  network details or machine-specific locations. The audience is any
  contributor.
- Every version, flag and result is one a contributor can check: name
  the file, tag or commit it comes from. Say "not measured" or "not
  verified" where that is the case.
- Prefer pointing at the file that holds the details
  (`plugins/intel/docs/intel-tools-issues.md`) over copying it.
- Plain, matter-of-fact technical language; no filler.

## Further reading side-notes

Skills on general topics (kernels, quantization, benchmarking methods)
end a section, or the skill, with links to free external references:

```markdown
> [!TIP]
> Further reading (free, external; not maintained here):
> - [Title](https://...): one line on what it covers and why it helps here.
```

Each link was opened when it was added, its line matches the page,
primary sources (specs, papers, official docs, project repositories) come
first, and nothing is paywalled or private. External pages move: an agent
that finds a dead link reports it rather than guessing a replacement.
