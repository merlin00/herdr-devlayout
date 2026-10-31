# herdr-devlayout

A [herdr](https://herdr.dev) plugin that builds and maintains a 3-pane coding layout:

```
┌──────────────┬──────────────┐
│ agent        │              │
│ (Claude Code)│   review     │
├──────────────┤ (reviewr)    │
│ editor (nvim)│              │
└──────────────┴──────────────┘
```

- **open** — in a fresh tab (one pane), build the layout and start the programs.
  In a tab that already has the layout, start only the programs that are **not running**.
  herdr restores panes and their names after a server restart, but programs come back as plain shells —
  one keypress brings them back (or let it happen automatically, see below). With herdr's Claude integration,
  herdr itself resumes the exact conversation and devlayout leaves the agent pane alone; without it, devlayout
  resumes with `claude --continue` and falls back to a new session if there is nothing to resume.
  devlayout never types into a pane where something other than the shell is running.
- **reset** — keep the agent pane, close the other panes in the current tab, rebuild the layout.
- **status** — print panes and which programs are running (shows up in the plugin log).

Step-by-step walkthrough (install, first run, settings, troubleshooting): [docs/GUIDE.md](docs/GUIDE.md).

> Status: 0.1.0, not yet released. Tested with herdr 0.9.5 on macOS (zsh, bash, fish) and against a fake herdr
> CLI in CI. Linux has not been tried on a real herdr yet.

## Requirements

- herdr ≥ 0.9.5, macOS or Linux
- `jq`
- The programs you put in the layout. Defaults: [Claude Code](https://code.claude.com), `nvim`,
  [herdr-reviewr](https://github.com/persiyanov/herdr-reviewr)
- Optional, for `devlayout show`: [herdr-file-viewer](https://github.com/smarzban/herdr-file-viewer)

## Install

```sh
herdr plugin install merlin00/herdr-devlayout
```

herdr plugins do not bind keys. Add your own to `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+shift+o"
type = "plugin_action"
command = "merlin00.devlayout.open"
description = "dev layout: build / repair"

[[keys.command]]
key = "prefix+shift+l"
type = "plugin_action"
command = "merlin00.devlayout.reset"
description = "dev layout: reset"
```

Then `herdr server reload-config`. Check that the keys don't collide with your other bindings
(`herdr --default-config` prints the defaults).

## Usage

| Do | How |
|---|---|
| Build the layout for this project | open herdr in the project folder, press `prefix+shift+o` |
| After a reboot / herdr server restart | press `prefix+shift+o` in each workspace, or turn on automatic repair (below) |
| Layout got messed up | `prefix+shift+l` (closes other panes in this tab; nvim buffers are saved first) |
| New git worktree | with automatic layout on (below), `herdr worktree create` gives you the layout right away |
| Open another project / worktree | in a herdr pane: `sh <plugin dir>/bin/devlayout open ../other-project` |
| Something didn't happen | errors and skipped programs show up as a herdr notification; the full log is in `herdr plugin log list --plugin merlin00.devlayout` |

Optional: link the script onto your PATH to run it from any herdr pane:

```sh
ln -s "$(herdr plugin list --json | jq -r '.result.plugins[] | select(.plugin_id == "merlin00.devlayout") | .plugin_root')/bin/devlayout" ~/.local/bin/devlayout
```

### Automatic repair after a server restart (optional, off by default)

Add `DEVLAYOUT_STARTUP=1` to `config.env`. When the herdr server starts, devlayout then restarts the editor and
review programs in every tab that already has the layout (3 panes labelled `claude` / `nvim` / `reviewr`).
It never builds, relabels or closes panes, and never touches other tabs.

The agent pane is left to herdr: with an official agent integration installed (`herdr integration install claude`)
and `[session] resume_agents_on_restore = true` (the default), herdr resumes the exact conversation itself.
Without an integration, set `DEVLAYOUT_STARTUP_AGENT=1` so devlayout resumes the agent (`claude --continue`).
You can run the same repair by hand with `devlayout repair-all`.

### Layout for new worktrees (optional, off by default)

Add `DEVLAYOUT_WORKTREE=1` to `config.env`. When herdr creates a workspace for a git worktree
(`herdr worktree create`, `herdr worktree open`, or herdr's worktree menu), devlayout builds the layout there,
with a new agent session. It only acts while the new tab still has a single pane, and never touches a worktree
workspace that was already open.

reviewr opens its own pane on the same events. Turn that off, or the two will fight over the new tab:
add `auto_open = false` to `~/.config/herdr/plugins/config/persiyanov.reviewr/config.toml`.

### Open files from reviewr in the editor pane

The editor pane runs `nvim --listen ~/.cache/nvim/<folder name>-<path hash>.sock`, one socket per project path
(so two projects with the same folder name never share an editor). Print the path with `devlayout editor-socket [DIR]`;
if you start nvim yourself and want it to receive files, use `nvim --listen "$(devlayout editor-socket)"`.
Point reviewr's editor at it (`~/.config/herdr/plugins/config/persiyanov.reviewr/config.toml`):

```toml
editor = "devlayout open-file {file} {line}"
```

reviewr runs this without a shell, so `devlayout` must be on your `PATH` (see Install), or give the full path:
`editor = "sh /path/to/herdr-devlayout/bin/devlayout open-file {file} {line}"`. reviewr passes an absolute path,
and hands its pane to the command until it exits; `open-file` returns at once: it opens the file in the editor pane's nvim,
or starts that nvim with the file if it was quit. Only if the editor pane is busy with another program does
it open nvim right there in the reviewr pane.

### Let Claude guide you to the right pane (optional)

Commands an agent (or a hook) can run from its pane:

| Command | What it does |
|---|---|
| `devlayout state` | print this tab as JSON: role panes, which programs run, whether you look at this tab |
| `devlayout focus agent\|editor\|review [MESSAGE]` | move the focus to that pane |
| `devlayout show FILE[:LINE[-END]]` | open FILE in a herdr-file-viewer popup at that line or range (close with `q`) |
| `devlayout edit FILE [LINE]` | open FILE in the editor pane's nvim (starting it if it was quit) and focus that pane |

They only move the focus while you look at the layout tab; otherwise they show a herdr notification
(`DEVLAYOUT_FOCUS=off` turns focus changes off). `devlayout install-skill` links the bundled Claude Code skill
(`skills/devlayout`) into `~/.claude/skills`, so Claude knows when to use them. See the
[guide](docs/GUIDE.md#7-let-claude-guide-you-to-the-right-pane) for hooks.

## Configuration

Copy `config.example.env` to `$(herdr plugin config-dir merlin00.devlayout)/config.env` and edit.
It is read as POSIX sh. Main settings:

| Setting | Default | Meaning |
|---|---|---|
| `DEVLAYOUT_AGENT_CMD` | `claude` | start a new agent |
| `DEVLAYOUT_AGENT_RESUME_CMD` | `claude --continue` | resume (repair / reset) |
| `DEVLAYOUT_AGENT_NAME` | `claude` | agent name as detected by herdr |
| `DEVLAYOUT_RESUME_GRACE` | `60` | if resume fails within this many seconds, start a new agent |
| `DEVLAYOUT_EDITOR` / `DEVLAYOUT_EDITOR_CMD` | `nvim` / – | editor; `_CMD` replaces the whole command |
| `DEVLAYOUT_REVIEW_CMD` | `herdr-reviewr` | review pane |

Programs are started with `sh -c`, so your shell's aliases and functions are not available there —
use real commands or absolute paths.

## Known limitations

- Run it **inside herdr** only (pane, key binding or plugin action). Outside herdr it refuses, because
  the layout would be built in a detached server you can't see.
- It works on the **current tab** only, with exactly 1 pane (build) or 3 panes (repair). Anything else → use reset.
  Other tabs in the same workspace are never counted or closed.
- Detection of running programs uses pid files written when devlayout starts them. Programs you start
  by hand in those panes are not detected as "running", but devlayout checks the pane's foreground
  process (`herdr pane process-info`) before typing and skips the pane if anything other than the shell
  is in front ("skipped: editor(nvim)"). Quit that program and run open again to start the role.
- Running the layout for the **same project** in two tabs at once shares one set of state and one editor socket.
- Moving or renaming the project folder changes its key: an nvim started before the move keeps the old socket
  and no longer receives files. Quit it and run open.
- If you restart the herdr server before sending the new Claude session a single message, herdr's own resume
  fails ("No conversation found"): Claude saves a conversation only after the first message. The agent pane is
  left as a shell; run open and devlayout resumes the folder's latest conversation with `claude --continue`.
- Windows is not supported.

## Development

```sh
sh tests/run.sh                      # needs python3 and jq; uses a fake herdr (tests/mock-herdr)
shellcheck -s sh bin/devlayout tests/run.sh
herdr plugin link "$PWD"             # try it in real herdr; re-link after editing herdr-plugin.toml
```

## License

MIT
