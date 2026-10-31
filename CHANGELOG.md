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
- Projects are keyed by path, so two projects with the same folder name never share state or an editor socket.
- `open-file` opens a file in the layout's nvim, for reviewr's `editor` setting. If that nvim was quit, it is
  started again in the editor pane with the file instead of taking over the reviewr pane.
- A program that quits right after it was started is restarted by the next open (before, it counted as
  running for 15 seconds).
- Optional automatic repair at herdr server start (`DEVLAYOUT_STARTUP=1`).
- Optional layout for new worktree workspaces (`DEVLAYOUT_WORKTREE=1`).
- Errors and skipped roles are shown as a herdr notification when run from a key binding, action or hook.
