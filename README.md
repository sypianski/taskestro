# Task Orchestrator

A [Claude Code](https://claude.ai/code) skill that dispatches tasks from a TODO file into parallel development streams, each running in its own git worktree and tmux window.

## The problem

A typical Claude Code workflow looks like this: you write (or dictate) a list of tasks, hand them to Claude, wait for it to finish, run `/clear`, then feed it the next batch. If you want parallelism you open separate tmux windows manually — but then you can't dictate everything in one go, and you lose track of what's running where.

## How this changes things

1. You write a `TASKS.md` (or `TODO.md`) with everything you need done
2. You tell Claude to dispatch — e.g. `/dispatch` or "run my tasks"
3. The orchestrator reads the file, estimates complexity, and presents a plan:

```
Task                              | Model  | Branch
----------------------------------+--------+---------------------
Redesign auth architecture        | opus   | wt/redesign-auth
Add pagination to user list       | sonnet | wt/add-pagination
Fix typo in README                | haiku  | wt/fix-readme-typo
```

4. After your OK, it opens a tmux window for each task, each with its own Claude Code session and git worktree
5. A dedicated **monitor window** (running `expedi-rigardi -w`) gives you a live dashboard of every task — state (`working`, `awaiting-input`, `done`), age since last activity, and the prompt when a task needs your input
6. Each child drops a `.expedi.done` marker on exit so the orchestrator can detect completion without racing on `pane_current_command`
7. Once all markers are present, it merges each branch back, resolves simple conflicts automatically, and updates `TASKS.md` with results

You save time, save tokens (smaller models handle simple tasks), and everything stays visible in one tmux session. No more switching between windows to check progress — the orchestrator tracks it for you.

## What it does under the hood

```
TASKS.md → parse → estimate complexity → select model → create worktrees → launch tmux → claude CLI → monitor → markers → merge → report
```

1. **Parses** your task file (checkbox, header-based, or tagged formats)
2. **Estimates complexity** and picks the right Claude model (Haiku / Sonnet / Opus)
3. **Creates git worktrees** so each task works on an isolated branch
4. **Launches tmux windows** with interactive Claude Code sessions
5. **Opens a monitor window** running `expedi-rigardi -w` — live dashboard of all tasks
6. **Waits on completion markers** — each child writes `.expedi.done` in its worktree when claude exits, so the orchestrator polls the filesystem instead of the (racy) `pane_current_command`
7. **Merges** branches back, handles simple conflicts automatically
8. **Reports** what was merged, what had issues, cleans up worktrees

## The monitor (`expedi-rigardi`)

The orchestrator relies on a separate Fish function, `expedi-rigardi`, to render the live dashboard. It scans every tmux pane in the current session whose `pane_current_path` matches `*/.worktrees/*` and reports:

- **State**: `awaiting-input` (!), `working` (●), `interrupted` (✗), `idle` (○), `done` (✓) — sorted by priority
- **Age** since last Claude activity (from a `Notification` hook that timestamps prompts to `~/.cache/cc-monitor/`)
- **The actual question** when a task is waiting for your input

Modes:
- `expedi-rigardi` — single-shot table
- `expedi-rigardi -w` — refresh every 2s until Ctrl-C (what the orchestrator uses)
- `expedi-rigardi --bar` — one-line summary for tmux status bar

See [`expedi-rigardi.fish`](https://github.com/sypianski/dotfiles/blob/master/fish/functions/expedi-rigardi.fish) and the [`cc-monitor-notify.sh` hook](https://github.com/sypianski/dotfiles/blob/master/hooks/cc-monitor-notify.sh) in `sypianski/dotfiles`.

## Installation

Copy `SKILL.md` into your Claude Code skills directory:

```bash
mkdir -p ~/.claude/skills/task-orchestrator
cp SKILL.md ~/.claude/skills/task-orchestrator/
```

## Task format examples

**Checkbox format:**
```markdown
- [ ] Implement login screen
- [ ] [opus] Redesign authentication architecture
- [ ] [sonnet] Add pagination to user list
- [ ] [haiku] Fix typo in README
```

**Header-based format:**
```markdown
## TODO
### Implement login screen
Description of what needs to be done...
```

Use `[haiku]`, `[sonnet]`, or `[opus]` tags to override automatic model selection.

## Requirements

- Git (for worktrees)
- tmux
- [Claude Code CLI](https://claude.ai/code)
- **Fish shell** + the `expedi-rigardi` function (for the live monitor — see above)
- A `Notification` hook configured in Claude Code settings (optional, enables activity-age in the monitor)

## License

MIT
