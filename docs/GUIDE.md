# devlayout guide

A step-by-step walkthrough: install, first run, everyday use, settings, troubleshooting and removal.
For a short overview see the [README](../README.md).

## Before you start

**Start herdr first.** Every `herdr …` command talks to a running herdr server. With no server you get
`no herdr server is running … run herdr to start or attach it`. Open a terminal, run `herdr`, and type the
commands below in any pane inside it.

Check that the tools are there:

```sh
herdr --version                          # 0.9.5 or later
which jq nvim claude herdr-reviewr       # each line should print a path
```

`jq` is required. `nvim`, `claude` and `herdr-reviewr` are the default programs of the layout; you can
replace them (see [Settings](#settings)).

## 1. Install

```sh
herdr plugin install merlin00/herdr-devlayout
herdr plugin list                        # merlin00.devlayout should be listed
```

To try a local checkout instead (for development):

```sh
git clone https://github.com/merlin00/herdr-devlayout ~/src/herdr-devlayout
herdr plugin link ~/src/herdr-devlayout
```

## 2. Add key bindings

herdr plugins do not bind keys themselves. Open `~/.config/herdr/config.toml` and add at the end:

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

Then reload the configuration:

```sh
herdr server reload-config
```

`prefix+shift+o` means: press the prefix key (`Ctrl+B` by default), release it, then press `Shift+O`.
If these keys are already taken in your setup, pick others; `herdr --default-config` lists the defaults.

## 3. (Optional) Put `devlayout` on your PATH

Needed for opening files from reviewr (step 6) and handy for running commands by hand:

```sh
mkdir -p ~/.local/bin
ln -s "$(herdr plugin list --json | jq -r '.result.plugins[] | select(.plugin_id == "merlin00.devlayout") | .plugin_root')/bin/devlayout" ~/.local/bin/devlayout
devlayout version                        # prints the version if ~/.local/bin is on your PATH
```

## 4. First run

1. Create a workspace for your project (from a pane inside herdr):

   ```sh
   herdr workspace create --cwd ~/projects/my-app --focus
   ```

2. In the new tab (one pane), press `prefix` → `Shift+O`.
3. You get Claude Code top left, nvim bottom left and reviewr on the right.

## 5. Everyday use

| Situation | What to do | What happens |
|---|---|---|
| A program was closed (e.g. you quit nvim) | `prefix` → `Shift+O` | Only the stopped program starts again; running ones are left alone |
| The layout got messed up (extra or missing panes) | `prefix` → `Shift+L` | The agent pane stays; the other panes in this tab are closed (nvim saves first) and rebuilt |
| After a reboot or `herdr server stop` | run `herdr`, then `prefix` → `Shift+O` in each layout tab | Panes come back as shells; editor and review are started again |
| Another project | `devlayout open ~/projects/other-app` | Focuses or creates that project's workspace and builds the layout |
| Something went wrong | look at the notification | Errors and skipped programs are shown as a herdr notification |

**About Claude after a restart.** With herdr's Claude integration, herdr resumes the conversation itself and
devlayout leaves the agent pane alone. If you never sent the new Claude session a message before the restart,
herdr's resume fails with "No conversation found" (Claude saves a conversation only after the first message)
and the pane is left as a shell. Press `prefix` → `Shift+O`: devlayout resumes the folder's latest
conversation with `claude --continue`, or starts a new one.

**devlayout never types into a busy pane.** If something other than the shell is running in a pane
(for example a program you started yourself), that role is skipped and named in the message.
Quit the program and press `prefix` → `Shift+O` again.

## 6. Open files from reviewr in the editor pane

Requires step 3. Edit `~/.config/herdr/plugins/config/persiyanov.reviewr/config.toml`:

```toml
editor = "devlayout open-file {file} {line}"
```

Now pressing `e` on a file in reviewr opens it at that line in the layout's nvim (bottom left), and reviewr
keeps the focus. If the editor pane's nvim is not running, the file opens in nvim inside the reviewr pane.

If you start nvim yourself and want it to receive these files, start it with
`nvim --listen "$(devlayout editor-socket)"`.

## Settings

There is no settings file until you create one:

```sh
dir=$(herdr plugin config-dir merlin00.devlayout)
mkdir -p "$dir"
cp "$(herdr plugin list --json | jq -r '.result.plugins[] | select(.plugin_id == "merlin00.devlayout") | .plugin_root')/config.example.env" "$dir/config.env"
```

Remove the `#` in front of a line and change the value. Changes apply on the next run.

| Setting | Default | Meaning |
|---|---|---|
| `DEVLAYOUT_STARTUP` | `0` | `1`: when the herdr server starts, restart editor and review in every layout tab automatically |
| `DEVLAYOUT_WORKTREE` | `0` | `1`: build the layout in workspaces created by `herdr worktree create`. Also set `auto_open = false` in reviewr's `config.toml`, or reviewr opens its own pane there |
| `DEVLAYOUT_NOTIFY` | `auto` | herdr notifications for errors and skipped programs: `auto`, `on` or `off` |
| `DEVLAYOUT_AGENT_CMD` | `claude` | program in the top-left pane |
| `DEVLAYOUT_EDITOR` | `nvim` | editor in the bottom-left pane |
| `DEVLAYOUT_REVIEW_CMD` | `herdr-reviewr` | program in the right pane |

`config.example.env` describes every setting. Programs are started with `sh -c`, so shell aliases and
functions are not available there; use command names on your PATH or absolute paths.

## Troubleshooting

- **A key binding does nothing and no notification appears.** Check the log:
  `herdr plugin log list --plugin merlin00.devlayout --limit 20`.
- **"the current tab has N panes … Run reset"**: devlayout only builds in a one-pane tab and only repairs
  a three-pane layout tab. Use `prefix` → `Shift+L`, or open a new tab.
- **"skipped: editor(nvim)"** (or another role): a program is already running in that pane. Quit it and
  run open again.
- **reviewr's `e` opens nvim in the reviewr pane** instead of the editor pane: the editor pane's nvim was not
  started by devlayout. Restart it with `prefix` → `Shift+O` after quitting it, or use
  `nvim --listen "$(devlayout editor-socket)"`.

## Uninstall

```sh
herdr plugin uninstall merlin00.devlayout     # or: herdr plugin unlink merlin00.devlayout
rm -rf "$(herdr plugin config-dir merlin00.devlayout)" ~/.local/state/herdr/plugins/merlin00.devlayout \
       ~/.local/state/devlayout ~/.local/bin/devlayout
```

Then remove the two `[[keys.command]]` blocks from `~/.config/herdr/config.toml`, run
`herdr server reload-config`, and set reviewr's `editor` back if you changed it.
