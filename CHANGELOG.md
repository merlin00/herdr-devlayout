# Changelog

## 0.1.0 — unreleased

First release. Requires herdr 0.9.5 or later (macOS, Linux).

- `open`: build the agent | editor / review layout in a one-pane tab, or, in a tab that already has it, restart
  only the programs that are not running (after a herdr server restart, panes come back as plain shells).
- `open <DIR>`: focus or create the workspace for a project directory.
- `reset`: keep the agent pane, close the other panes in the current tab and rebuild the layout.
- `status`, `repair-all`, `open-file`, `editor-socket` helper commands.
- Never types into a pane where something other than the shell is in front (checked with
  `herdr pane process-info` right before typing); such roles are skipped and named.
- Works on the current tab only; other tabs are never counted or closed.
- Agent resume with `claude --continue`, falling back to a new session when there is nothing to resume.
  Leaves the agent pane alone while herdr resumes the agent itself after a server restart.
- Every tab has its own state and editor socket (keyed by project path, herdr session and tab), so the same
  folder in two tabs or two herdr sessions works, and same-named folders never collide. An nvim that already
  answers on the tab's socket counts as running.
- `open-file` opens a file in the layout's nvim, for reviewr's `editor` setting. If that nvim was quit, it is
  started again in the editor pane with the file instead of taking over the reviewr pane.
- A program that quits right after it was started is restarted by the next open (before, it counted as
  running for 15 seconds).
- Optional automatic repair at herdr server start (`DEVLAYOUT_STARTUP=1`).
- Optional layout for new worktree workspaces (`DEVLAYOUT_WORKTREE=1`).
- Errors and skipped roles are shown as a herdr notification when run from a key binding, action or hook.
- For agents: `state` (the tab as JSON), `focus agent|editor|review`, `show FILE[:LINE[-END]]` (a
  herdr-file-viewer popup) and `edit FILE [LINE]` (the editor pane's nvim). They move the focus only while
  you look at the layout tab, otherwise they show a notification (`DEVLAYOUT_FOCUS`).
- The repository is also a Claude Code plugin (`claude plugin install devlayout --marketplace
  merlin00/herdr-devlayout`): a skill that tells Claude when to use these commands, and a hook that focuses
  Claude's pane before every question.
- `doctor`: checks the required and optional parts and prints how to fix each.
- Run from a pane shell, devlayout uses the same settings and state folders as the plugin action.
