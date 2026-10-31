---
name: devlayout
description: Guide the user to the right pane of a herdr devlayout tab (agent | editor nvim / review). Use when running inside herdr (HERDR_ENV=1) in a devlayout tab and you want the user to read a result or file (show it in a file viewer popup), to edit a long text themselves (open it in the editor pane's nvim), or when the layout looks broken. Do not use outside herdr.
---

# devlayout

The user works in a herdr tab with three panes: you (the agent) top left, nvim (editor) bottom left,
and a review pane on the right. `devlayout` moves the user's focus to the pane that fits the next step.

Run `devlayout`. If it is not on PATH, run `sh <this skill's folder>/../../bin/devlayout` instead.
Every command prints one line. On error it exits non-zero with the cause and the next step.

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

## 4. Choices and questions

Ask choices in your own pane, not in a file. If the user is elsewhere in this tab, run
`devlayout focus agent "Claude has a question"` right before asking. A Claude Code hook can also do this
for every question (see the devlayout guide).

`devlayout focus editor|review` moves the focus to those panes when you only want the user to look there.

## 5. The layout looks wrong

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
