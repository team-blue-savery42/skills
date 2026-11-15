---
name: github-markdown-preview
description: Preview Markdown docs exactly as github.com renders repository files before pushing - gh markdown-preview --markdown-mode or grip through GitHub's Markdown API, previews of files on a remote build host over an SSH tunnel without storing a token there, editor integrations (VS Code/VSCodium Remote-SSH, Neovim LazyVim, Emacs grip-mode), and the Modular fork's Markdown style check (rumdl through //:format, 80 columns).
---

> [!NOTE]
> This file was written by an AI agent for AI agents. Check every command,
> path and version in it against the current sources before relying on it.

# Preview Markdown as GitHub renders it

Use this before pushing or proposing a change to a `.md` file (a README, a
doc under `plugins/intel/docs/`, a reproduction's `README.md`), and when the
file lives on a remote build host while the browser is local.

Only GitHub's own Markdown API gives exactly what github.com shows. Two
tools use it: the `gh` extension `gh-markdown-preview` and `grip`. Both
send the file's text to `api.github.com`, so do not preview a file the
contributor has not agreed to send there. Editor previews (VS Code's
markdown-it, markdown-preview.nvim) are close but not identical.

## Render mode: why `--markdown-mode`

GitHub's `POST /markdown` API has two modes:

- `gfm`: GitHub Flavored Markdown as in issues and comments (with a
  repository `context` for `#123` references). It turns every line break
  inside a paragraph into `<br>`, so a file wrapped at 80 columns looks
  broken into short lines.
- `markdown`: plain document mode, which is how github.com renders `.md`
  files in a repository. `POST /markdown/raw` renders in this mode too.

Preview repository files in document mode. `gh-markdown-preview` defaults
to `gfm`; pass `--markdown-mode`. `grip` uses `/markdown/raw` (document
mode) unless `--user-content` is given, which switches it to `gfm`.

A correct document-mode preview has no `<br>` inside wrapped paragraphs and
carries GitHub's heading anchors (`user-content-` ids).

## gh markdown-preview (recommended)

```sh
gh extension install yusukebe/gh-markdown-preview
gh markdown-preview --markdown-mode <file>.md
```

- Serves on `localhost:3333` by default and opens the browser; reloads the
  page on every save.
- Flags: `-p, --port <n>`, `--host <name>` (default `localhost`),
  `--disable-auto-open`, `--disable-reload`, `--light-mode`,
  `--dark-mode`, `--verbose`.
- It calls the API through `gh api`, so it uses `gh`'s login
  (`gh auth login`, or the `GH_TOKEN` environment variable). It needs no
  token of its own.

## grip

```sh
grip <file>.md            # http://localhost:6419/
grip <file>.md 0.0.0.0:6420
grip <file>.md --export <file>.html
```

Without a login grip is held to GitHub's anonymous API rate limit. Never
put a token on the command line (`--pass <token>` lands in shell history
and the process list). Let grip read it from its settings file,
`~/.grip/settings.py` (or `$GRIPHOME/settings.py`), and have that file ask
`gh` each time instead of storing the token:

```python
# ~/.grip/settings.py: grip's GitHub login from the gh CLI; nothing stored.
import subprocess

try:
    PASSWORD = subprocess.run(["gh", "auth", "token"], capture_output=True,
                              text=True, check=True).stdout.strip() or None
    USERNAME = subprocess.run(["gh", "api", "user", "-q", ".login"],
                              capture_output=True, text=True,
                              check=True).stdout.strip() or None
except (OSError, subprocess.CalledProcessError):
    PASSWORD = USERNAME = None
```

- The file must be `settings.py`. Grip 4.6.2 reads `settings_local.py`
  only from its own package directory, not from `~/.grip`, so a
  `~/.grip/settings_local.py` is silently ignored (checked by loading
  grip's app with each file).
- On start, grip prints ` * Using credentials: <user>` or
  ` * Using personal access token` when a login is in effect. No such line
  means it is anonymous.

## Files on a remote build host

The file is edited on a build host (`<build-host>`), the browser runs
locally. Run the preview next to the file, so live reload sees every save,
and tunnel its port:

```sh
ssh -L 3333:localhost:3333 <build-host>
# on the build host, in the file's directory:
gh markdown-preview --markdown-mode --disable-auto-open --host localhost --port 3333 <file>.md
# locally: open http://localhost:3333/
```

The build host needs `gh` and the extension, and a GitHub login. To avoid
storing a login on a shared host, pass the local token over the SSH
connection's stdin into the remote process's environment only (never as an
argument, never to a file):

```sh
token=$(gh auth token)
{ printf '%s\n' "$token"; cat; } | ssh -o ExitOnForwardFailure=yes \
  -L 3333:localhost:3333 <build-host> '
  read -r GH_TOKEN; export GH_TOKEN
  cd <dir-of-file>
  gh markdown-preview --markdown-mode --disable-auto-open --host localhost --port 3333 <file>.md &
  pid=$!
  cat >/dev/null                 # wait until the local side closes stdin
  pkill -f "gh-markdown-preview .*--port 3333"
  kill $pid'
```

Ctrl-C locally closes stdin; the remote side then stops the server. `gh`
runs the extension as a child process, so stop the extension itself
(`pkill -f`), not only `gh`. Pick another port with `-p` on both sides if
3333 is taken.

## Editor integrations

- **VS Code / VSCodium over SSH.** VS Code uses Microsoft's Remote - SSH
  extension; VSCodium uses `jeanp413.open-remote-ssh`. Install
  `bierner.markdown-preview-github-styles` for GitHub's styling, on the
  remote too (list it in `remote.SSH.defaultExtensions`). Ctrl+K V opens
  the side preview. VS Code renders with markdown-it (CommonMark), not
  GitHub's API: close, not exact. For the exact render, run
  `gh markdown-preview` as above. The VSCodium Remote-SSH path is not
  verified.
- **Neovim (LazyVim).** The `lang.markdown` extra brings
  `markdown-preview.nvim`, `render-markdown.nvim` and `marksman`
  (`<leader>cp` toggles the preview). When Neovim runs on the build host
  over SSH, fix the port and print the URL instead of opening a browser
  there:

  ```lua
  -- lua/plugins/markdown.lua
  return {
    {
      "iamcco/markdown-preview.nvim",
      init = function()
        vim.g.mkdp_port = "8090"
        vim.g.mkdp_open_ip = "localhost"
        vim.g.mkdp_echo_preview_url = 1
        vim.cmd([[
          function! MkdpEchoOnly(url)
            echomsg "markdown preview: " . a:url
          endfunction
        ]])
        vim.g.mkdp_browserfunc = "MkdpEchoOnly"
      end,
    },
  }
  ```

  Connect with `ssh -t -L 8090:localhost:8090 <build-host>`, run
  `:MarkdownPreview`, open `http://localhost:8090/page/1` locally. The
  extra also installs `markdownlint-cli2` and `markdown-toc` through mason
  (npm); in the Modular fork rumdl is the linter, so these can be turned
  off. markdown-preview.nvim renders with markdown-it: close, not exact.
- **Emacs.** `grip-mode` runs grip on the buffer (exact, document mode)
  and refreshes on save. Set `grip-command` to `'grip`, leave
  `grip-github-user` and `grip-github-password` empty and keep the login in
  `~/.grip/settings.py` as above. Over TRAMP, older `grip-mode` versions
  handed grip the remote `/ssh:` file name, which grip cannot open; the
  current `grip-mode` README says TRAMP files are previewed from a local
  temporary copy, but relative resources from the remote directory are not
  copied. Check the version you have. Whether grip-mode's empty
  `--user=`/`--pass=` arguments leave the settings-file login in effect is
  not verified; look for grip's ` * Using ...` line.

## What still differs from github.com

- Relative links (`../tests/...`) and links to other files in the
  repository do not resolve in a local preview; they do on github.com.
  Check them in the pushed branch or by reading the paths.
- Relative images may not load, especially from a TRAMP or temporary copy.
- Editor previews (markdown-it) may differ in tables, alerts
  (`> [!NOTE]`) and HTML; trust the API-based preview.

## The Modular fork's Markdown style

The fork checks Markdown with rumdl inside Modular's formatter. Before
committing a `.md` change in the fork:

```sh
./bazelw run //:format        # formats the changed files (also buildifier, mblack, ruff, shellcheck, license headers)
./bazelw run //:format-all    # every file
./bazelw run //:lint-all      # check only, every file
```

(Modular's `CONTRIBUTING.md` writes it `./bazelw run format`; the targets
are defined in `bazel/lint/BUILD.bazel`.) The rumdl configuration is
`bazel/lint/.rumdl.toml`:

- line length 80, not applied to code blocks, headings or tables, and
  **reflow on** (`[MD013] reflow = true`): the formatter rewraps paragraphs
  to 80 columns;
- `-` for bullet lists, `**` for strong emphasis, tables aligned
  (`MD060` `aligned-no-space`).

Pitfall: reflow can move a number followed by a period to the start of a
line. A wrapped line that starts with `1.` interrupts the paragraph and
becomes an ordered list item; a line starting with `0.` was also seen to
need fixing after a reflow. After `//:format`, search the changed files for
lines that begin with a number and a period and reword the sentence (or
put the number elsewhere), then preview again.

Then preview the formatted file as above: the formatter changes line
breaks, tables and lists.

## Pitfalls

- `gh markdown-preview` without `--markdown-mode`: every wrapped line shows
  as a line break. The preview is wrong, not the file.
- A token in `--pass`, in a remote file, or in an environment variable set
  on the SSH command line.
- Previewing private text: both API tools send it to GitHub.
- A preview server left running on the build host after the SSH session
  ends; stop it.

## References

- `gh-markdown-preview` and `grip` READMEs and `--help`.
- The fork: `CONTRIBUTING.md` (formatting), `plugins/intel/CONTRIBUTING.md`
  (code style and `//:format`), `bazel/lint/.rumdl.toml`,
  `bazel/lint/BUILD.bazel`.

> [!TIP]
> Further reading (free, external; not maintained here):
> - [REST API endpoints for Markdown](https://docs.github.com/en/rest/markdown/markdown): the `markdown` and `gfm` modes and `/markdown/raw`.
> - [GitHub Flavored Markdown Spec](https://github.github.com/gfm/): GitHub's dialect, including the rule that an ordered list interrupting a paragraph must start at 1.
> - [Basic writing and formatting syntax](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax): GitHub's alerts (`> [!NOTE]`, `> [!TIP]`, ...).
> - [gh-markdown-preview](https://github.com/yusukebe/gh-markdown-preview): the `gh` extension, its flags and modes.
> - [grip](https://github.com/joeyespo/grip): settings file, port and authentication.
> - [rumdl](https://github.com/rvben/rumdl): the linter and formatter the fork runs; `MD013` reflow.
> - [Remote Development using SSH](https://code.visualstudio.com/docs/remote/ssh): VS Code Remote - SSH and `remote.SSH.defaultExtensions`.
> - Editor extensions: [open-remote-ssh](https://github.com/jeanp413/open-remote-ssh) (VSCodium), [markdown-preview-github-styles](https://github.com/mjbvz/vscode-github-markdown-preview-style), [markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim), [LazyVim markdown extra](https://www.lazyvim.org/extras/lang/markdown), [grip-mode](https://github.com/seagle0128/grip-mode).
