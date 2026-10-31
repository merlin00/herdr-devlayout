---
name: devlayout
description: Guide the user to the right pane of a herdr devlayout tab (agent | editor nvim / review). Use when running inside herdr (HERDR_ENV=1) in a devlayout tab and you want the user to read a result or file (show it in a file viewer popup), to edit a long text themselves (open it in the editor pane's nvim), to review your code changes (focus the review pane), or when the layout looks broken. Do not use outside herdr.
---

# devlayout

The user works in a herdr tab with three panes: you (the agent) top left, nvim (editor) bottom left,
and a review pane on the right. `devlayout` moves the user's focus to the pane that fits the next step.

Run `devlayout`. If it is not on PATH, run `sh <this skill's folder>/../../bin/devlayout` instead.
`show`, `edit` and `focus` print one line; `state` prints JSON, `doctor` a report, and `open` several lines
(pass on any `skipped:` line). On error a command exits non-zero with the cause and the next step. If a command
fails because something is missing (a plugin, a program, the layout), run `devlayout doctor` and pass on
its `missing`, `warn` and `optional` lines with their fix commands.

## 1. Check the tab first

```bash
devlayout state
```

It prints JSON:

- `layout`: `devlayout` (3 panes with roles), `single` (1 pane) or `other`.
- `viewing`: whether the user looks at this tab right now.
- `roles.agent|editor|review`: `{pane, state}`. `state` is `running`, `stopped`, `busy <program>` or `missing`.

If `viewing` is false, do not try to move the focus. The commands below show a herdr notification instead.

## 2. Show a result or a file: `show`

Use it for something the user should read but not change much: a plan, a report, a long diff summary,
or the place you found a bug.

1. Write longer output to a Markdown file inside the project, for example `docs/notes/plan.md`. Do not
   put it in a git-ignored folder; the viewer dims those files.
2. Run the command with the file and an optional line or range:

   ```bash
   devlayout show docs/notes/plan.md
   devlayout show src/app.rs:42-58
   ```

   It opens a file viewer popup over the layout at that place. Markdown is rendered and changed files show
   as a diff. The user closes it with `q`. Only one popup can be open; if it says a popup is already open,
   tell the user to close it.
3. End your turn with one line: what you showed and what you want back.

## 3. Let the user edit a long text: `edit`

Use it when the user should write or change a lot themselves: a commit message, a long prompt, a config
file, a draft.

1. Write the starting text to a file in the project.
2. Run the command:

   ```bash
   devlayout edit path/to/file.md 1
   ```

   It opens the file in the editor pane's nvim (and starts nvim there if it was quit), then focuses that pane.
3. End your turn. Tell the user to save (`:w`) and tell you when they are done. You cannot see when they
   finish, so do not wait or poll. Read the file again when they come back.

`edit` refuses when another program runs in the editor pane. Pass on its message; do not retry in a loop.

## 4. Ask for a review of your changes: `focus review`

The review pane runs reviewr. By default it shows the uncommitted changes (git-ignored files never show);
the user comments on lines with `c`, and `s` puts every comment into your input box, where the user sends
them with Enter. Use it when you changed files and the user wants to check them before going on, for
example after a plan step or before a commit.

1. Run `devlayout state` and look at `roles.review.state`:
   - `running`: go on.
   - `stopped`: run `devlayout open` (it restarts the review program), then go on.
   - `busy <program>`: the user runs something else there. Ask them to quit it; do not move the focus.
   - `missing`: the layout lacks a review pane. Handle it as in section 6 (ask before `devlayout reset`).
2. Check that there is something to review: `git status --short` lists the changed files that are not
   git-ignored. If it prints nothing, or the project is not a git repository, skip the review step and
   say why.
3. Run, with the real number of changed files:

   ```bash
   devlayout focus review "Claude changed <N> files; review them in reviewr"
   ```

4. End your turn with one line: which files changed and what to look at first. Tell the user to comment
   with `c`, press `s`, then press Enter in your pane to send. Do not wait or poll; the comments arrive as
   the next message.
5. Treat each comment as a request: fix it, or answer why not.

Do not move the focus to the review pane after every edit. Do it once per step, when the user asked for a
review or a plan step is done.

## 5. Choices and questions

Ask choices in your own pane, not in a file. This plugin's hook moves the focus to your pane right before
every question, so you do not need to. Without the hook (the skill used on its own), run
`devlayout focus agent "Claude has a question"` right before asking.

`devlayout focus editor|review` moves the focus to those panes when you only want the user to look there.

## 6. The layout looks wrong

`layout` is `other`, or a role is `missing`:

- Explain what `state` shows.
- `devlayout open` restarts stopped programs in a correct layout, and builds the layout in a one-pane tab.
- `devlayout reset` **closes every pane of this tab except yours** and rebuilds the layout (nvim saves its
  buffers first). Ask the user before running it, and name the panes that would be closed.
- A role in `busy <program>` state is something the user runs. Never type into it. Ask the user to quit it.

## Rules

- Never type into the editor or review pane yourself (no `herdr pane run` or `send-keys` there). Use these commands.
- Do not move the focus without a reason the user can see in your reply.
- Do not close panes you did not open.
