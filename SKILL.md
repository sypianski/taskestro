---
name: task-orchestrator
description: >
  Orchestrate parallel execution of tasks from a TODO.md (or similar task file) using
  git worktrees and tmux sessions. Use this skill whenever the user says things like
  "run my tasks", "execute TODO", "orchestrate tasks", "dispatch tasks in parallel",
  "work on the TODO list", "spin up tasks from TODO.md", "launch worktrees for tasks",
  or references a TODO/task file they want executed in parallel. Also trigger when the
  user mentions distributing tasks across Claude Code sessions, choosing models per task,
  or using tmux + worktrees for parallel development. This skill handles the full
  lifecycle: parsing tasks, estimating complexity, selecting models, creating worktrees,
  launching tmux sessions, and invoking Claude Code CLI in each.
---

# Task Orchestrator

Dispatch tasks from a TODO file into parallel Claude Code sessions, each in its own
git worktree and tmux window, with the appropriate model selected per task.

## Overview

This skill turns a TODO file into parallel development streams:

```
TODO.md → parse tasks → estimate complexity → create worktrees → launch tmux → claude CLI → monitor → merge
```

## Step 1: Collect Tasks

Tasks can come from two sources. **The user's prompt takes priority** — only
fall back to a TODO file when no tasks are given inline.

### Source A: Tasks from the prompt (preferred)

If the user includes tasks directly in their message (as a list, bullet points,
or prose describing multiple work items), parse those as the task list and skip
the TODO file entirely. Apply the same parsing rules below (model tags, branch
hints, etc.).

### Source B: TODO file (fallback)

Only when the prompt contains **no inline tasks**, look for a task file:
- Path explicitly provided by the user
- `TODO.md` in the project root
- `docs/TODO.md`
- Any file matching `*TODO*` or `*tasks*` in root

**Before dispatching TODO.md tasks, verify they are still relevant.** For each
uncompleted task in the file:
1. Check if the described change already exists in the codebase (grep for key
   identifiers, check if referenced files/functions exist, review recent git log).
2. If the task appears already accomplished, mark it `[x]` in the file and skip it.
3. Only dispatch tasks that are genuinely outstanding.

### Supported Formats

The parser must handle all common markdown task formats:

**Checkbox format:**
```markdown
- [ ] Implement login screen
- [x] Set up project structure  ← skip, already done
- [ ] Add unit tests for API client
```

**Header-based format:**
```markdown
## TODO
### Implement login screen
Description of what needs to be done...

### Add unit tests for API client
Details here...
```

**Tagged format (with priority or model hints):**
```markdown
- [ ] [opus] Redesign authentication architecture
- [ ] [sonnet] Add pagination to user list
- [ ] [haiku] Fix typo in README
```

### Parsing Rules

1. Skip completed tasks (`[x]`, `~~strikethrough~~`, or marked "DONE")
2. Extract task title (first line / checkbox text / header)
3. Extract task description (subsequent lines until next task)
4. Extract explicit model tags if present: `[haiku]`, `[sonnet]`, `[opus]`
5. Extract explicit branch name if present: `[branch:feature/xyz]`

## Step 2: Estimate Complexity and Select Model

For each task WITHOUT an explicit model tag, estimate complexity:

### Haiku Tasks (simple, mechanical, low-risk)
- Typo fixes, README updates, comment improvements
- Simple renaming or moving files
- Adding straightforward boilerplate
- Dependency version bumps
- Linting fixes, formatting

### Sonnet Tasks (moderate complexity, standard development)
- Implementing a well-defined feature
- Writing tests for existing code
- Bug fixes with clear reproduction steps
- Refactoring with clear scope
- Adding a new endpoint or screen with known patterns
- Documentation writing

### Opus Tasks (high complexity, architectural, ambiguous)
- Architectural decisions or redesigns
- Security-sensitive changes
- Complex algorithms or data structures
- Tasks with ambiguous requirements needing interpretation
- Cross-cutting concerns affecting many files
- Performance optimization requiring analysis
- Migration or upgrade strategies

**Present the plan to the user before executing.** Show a table:

```
Task                              │ Model  │ Branch
──────────────────────────────────┼────────┼──────────────────
Redesign auth architecture        │ opus   │ wt/redesign-auth
Add pagination to user list       │ sonnet │ wt/add-pagination
Fix typo in README                │ haiku  │ wt/fix-readme-typo
```

Wait for user confirmation or adjustments before proceeding.

## Step 3: Check for Existing Sessions

**Prefer reusing the current tmux session** over creating a dedicated
`orchestrator-*` session. If the user is already inside tmux (`$TMUX` set),
add windows to `tmux display-message -p '#S'` — that keeps all project work in
one place (e.g. the user's `web-laguna` session already contains the other
project windows). Only fall back to a new `orchestrator-<project>` session if
not running under tmux, or the user explicitly asks for isolation.

```bash
# Detect current session if inside tmux, else create a project-scoped one
if [ -n "$TMUX" ]; then
  SESSION_NAME=$(tmux display-message -p '#S')
else
  SESSION_NAME="orchestrator-$(basename $(pwd))"
  tmux has-session -t "$SESSION_NAME" 2>/dev/null || tmux new-session -d -s "$SESSION_NAME"
fi

# List existing windows to match against task slugs
tmux list-windows -t "$SESSION_NAME" -F "#{window_name} #{window_active}"
```

For each task, match the slug against existing tmux window names. If a window already
exists for a task:

1. **Check if claude is still running** in that window:
   ```bash
   tmux list-panes -t "$SESSION_NAME:<window-name>" -F "#{pane_current_command}"
   ```
2. **If running** → skip the task, report it as "iam in cursu" (already running)
3. **If finished (shell idle)** → ask the user: reuse the window or kill and recreate?

Present the status before proceeding:

```
Task                              │ Status
──────────────────────────────────┼─────────────────
Redesign auth architecture        │ ⏳ already running
Add pagination to user list       │ ✅ finished (window exists)
Fix typo in README                │ 🆕 new
```

Only proceed with tasks that are new or explicitly approved for restart.

## Step 4: Create Git Worktrees

For each task, create a worktree from the current branch:

```bash
# Get current branch as base
BASE_BRANCH=$(git branch --show-current)

# For each task, create a worktree INSIDE the project in .worktrees/
mkdir -p .worktrees
grep -qxF '.worktrees/' .gitignore 2>/dev/null || echo '.worktrees/' >> .gitignore
git worktree add .worktrees/<slug> -b wt/<slug> $BASE_BRANCH
```

### Branch Naming

Generate slug from task title:
- Lowercase, replace spaces with hyphens
- Remove special characters
- Prefix with `wt/`
- Max 50 chars
- Example: "Implement login screen" → `wt/implement-login-screen`

If a branch or worktree already exists, ask the user whether to reuse or recreate.

### Worktree Location

Place worktrees in `.worktrees/` **inside** the project root — keep everything
for one project in a single folder instead of spawning a sibling directory.
Create the directory if it doesn't exist, and add `.worktrees/` to `.gitignore`
so the main repo doesn't try to track nested worktree contents.

Do **not** use `../worktrees/` or `../<project>.worktrees/` — those scatter
project state across sibling directories and clutter the parent folder.

## Step 5: Launch tmux Windows

Use `$SESSION_NAME` from Step 3 (current session if inside tmux, else
project-scoped). Create one window per task with `-c` pointing at the
worktree so the shell starts in the right directory:

```bash
tmux new-window -t "$SESSION_NAME" -n "<short-task-name>" -c "<worktree-path>"
```

### Launching claude inside the window — DO NOT use `claude -p "$(cat ...)"`

`claude -p '<prompt>'` in non-interactive mode is fragile when driven by
`tmux send-keys`: the shell may receive the command before fish is ready,
multi-line prompts interact badly with quoting, and you can't watch progress
or intervene. **Use the interactive flow instead:**

1. **Write the prompt to a file in the worktree** (e.g. `.task-prompt.md`).
2. **Launch the full `claude` command with explicit flags** — do NOT rely on
   personal shell aliases like `cc`, they may not exist on every machine and
   obscure what's happening. Append `; touch .task.done` so the worktree
   gets a completion marker the moment claude exits (the orchestrator polls
   for these in Step 7). Wait a few seconds for the TUI to initialise:
   ```bash
   tmux send-keys -t "$SESSION_NAME:<window>" \
     "claude --dangerously-skip-permissions --model <haiku|sonnet|opus>; touch .task.done" Enter
   sleep 5
   ```
3. **Paste the prompt via the tmux buffer** (plain `paste-buffer` without
   `-p`/bracketed-paste — plain mode worked reliably here; bracketed-paste
   caused duplicate input):
   ```bash
   tmux load-buffer -b "prompt-<window>" "<worktree>/.task-prompt.md"
   tmux paste-buffer -b "prompt-<window>" -t "$SESSION_NAME:<window>" -d
   tmux send-keys -t "$SESSION_NAME:<window>" Enter
   ```

### Verifying it actually started

After pasting, verify the worker is processing, not sitting idle:

```bash
tmux list-panes -t "$SESSION_NAME:<window>" -F '#{pane_current_command}'
# → should be "claude", not "fish"/"bash"
```

`tmux capture-pane -p` against an active claude TUI may return empty because
claude uses the alternate screen buffer. Trust `pane_current_command` first,
then look for `●` / `Bash(` / `Update(` markers in the capture if you need
detail.

### Task Prompt Construction

The prompt file should include:
1. The task title and full description from TODO
2. Context about the project (language, framework, conventions, CLAUDE.md reference)
3. Instruction to commit work when done
4. Instruction to NOT touch files outside the task scope
5. Instruction to write blockers to `BLOCKERS.md` instead of guessing

Template:
```
You are working on a specific task in a git worktree.

PROJECT: <project name/description — reference ./CLAUDE.md for conventions>
TASK: <task title>
DETAILS: <task description from TODO, including file paths and line numbers if known>

Instructions:
- Work only on files relevant to this task
- Follow existing code conventions (see CLAUDE.md)
- Commit your changes with a descriptive message when done
- If you encounter blockers or ambiguity, write them to BLOCKERS.md instead of guessing
```

## Step 6: Launch Monitor Window

Before starting the polling loop, create a dedicated monitor window that runs
`task-monitor -w` — a Fish function that renders a live table of every
dispatched task in the session. This is the **first window created**;
it stays in the foreground so the user sees progress without switching windows.

```bash
tmux new-window -t "$SESSION_NAME" -n "monitor" 'fish -c "task-monitor -w"'
```

That's it. No per-project `.task-monitor.sh` to write — `task-monitor` is
the Fish function bundled with this skill at `scripts/task-monitor.fish`.
Symlink it into your Fish function path (e.g. `~/.config/fish/functions/`)
once; it auto-discovers tasks by scanning tmux panes whose `pane_current_path`
matches `*/.worktrees/*` (or the legacy `*/worktrees/wt-*`).

### What the monitor shows

- States: `awaiting-input` (!), `working` (●), `interrupted` (✗), `idle` (○), `done` (✓)
- Age since last activity (from the `Notification` hook at `hooks/cc-monitor-notify.sh` in this repo — see [Hook installation](#hook-installation) below)
- The prompt question when a task is awaiting input
- Sorted: awaiting-input > working > interrupted > idle > done

### Navigation

The user stays in the monitor window and jumps to task windows using tmux's
standard window switching (prefix + window number, or prefix + s to select
from a list).

## Step 7: Wait for Completion

Parent claude cannot poll forever — once a tool call returns it goes idle until the next user input. Instead, **let the worktrees push completion events to the parent** via inotify + the `Monitor` tool. Each `.task.done` write emits one notification line, which Claude Code delivers to parent claude as a fresh turn.

### Setup

`inotify-tools` must be installed (`sudo apt install inotify-tools` once per host; Linux only — on macOS use `fswatch`). Verify:

```bash
command -v inotifywait || { echo "install inotify-tools"; exit 1; }
```

### Drain pre-existing markers first

Parent may have restarted while children were running. Count markers that already exist before subscribing to new events:

```bash
EXPECTED=${#TASK_WORKTREES[@]}
ALREADY=0
for WT in "${TASK_WORKTREES[@]}"; do
  [ -f "$WT/.task.done" ] && ALREADY=$((ALREADY + 1))
done
REMAINING=$((EXPECTED - ALREADY))
echo "completed: $ALREADY / $EXPECTED"
[ "$REMAINING" -eq 0 ] && exit 0   # nothing to wait for, jump to merge
```

### Subscribe to completion events via the Monitor tool

Run the following as a `Monitor` tool call (NOT plain `Bash`). Each line of stdout is delivered to parent claude as one notification, instantly waking it up:

```bash
inotifywait -m -e close_write,moved_to --format '%w%f' \
    "${TASK_WORKTREES[@]}" 2>/dev/null \
  | awk -F/ '/\.task\.done$/ { print "DONE", $(NF-1); fflush() }'
```

How it works:
- `-m` = monitor mode, never exits.
- `-e close_write,moved_to` = catches both `touch .task.done` and atomic moves.
- `--format '%w%f'` emits the full path of each event.
- `awk` filters for `.task.done`, prints `DONE <slug>` (`<slug>` = parent dir name = worktree slug). `fflush()` defeats stdio buffering so parent sees each line immediately.

### Counting and exiting

Parent claude tracks notifications:

- On each `DONE <slug>` notification, decrement `REMAINING` and dedupe by slug (in case both `close_write` and `moved_to` fire for the same file).
- When `REMAINING == 0` → call `TaskStop` on the Monitor task ID, then `tmux kill-window -t "$SESSION_NAME:monitor"`, then proceed to Step 8 (merge).

### Why this beats the old bash-poll loop

- **Push, not poll.** Zero-latency wake-up: parent reacts within milliseconds of `touch .task.done`, not within the next poll cycle.
- **Parent stays asleep between events.** No 9-minute Bash hostage; the `Monitor` task lives quietly in the harness, waking parent only when something actually happens.
- **Survives parent restart.** Fresh start re-runs the marker drain (above), then re-subscribes — both already-done and not-yet-done are handled correctly.
- **Lower noise.** No timeout-and-rerun loop that the parent might forget to re-invoke.

### Why markers instead of `pane_current_command`

`pane_current_command` worked for the dashboard but is racy for completion detection: between claude exiting and the shell prompt redrawing, the value can briefly read as `bash`/`fish` even while claude is still live. A filesystem marker written after claude exits is atomic, survives parent restart, and is exactly what `inotifywait` is good at observing.

### Backstop

If the `Monitor` task dies (rare: kernel watch limit hit, `inotifywait` killed by oomkiller, etc.), parent has no way to know without help. Set a `ScheduleWakeup` for ~10 minutes when subscribing — on wake, re-run the marker drain. If `REMAINING` dropped without notifications arriving, the Monitor died; restart it and reschedule.

### Detecting success vs failure

After all markers are present, check each worktree for results:

```bash
cd <worktree-path>
NEW_COMMITS=$(git log "$BASE_BRANCH"..HEAD --oneline)
HAS_BLOCKERS=$(test -f BLOCKERS.md && echo yes || echo no)
```

- **New commits + no BLOCKERS.md** → task succeeded, proceed to merge automatically
- **New commits + BLOCKERS.md** → partial success, note in final report but still merge
- **No new commits** → task failed or produced no changes, skip and note in report

### Soft warnings

If a single task takes >30 minutes (no `.task.done` yet), warn the user but keep waiting. Only ask about killing if it exceeds 60 minutes. Do not auto-kill.

## Step 8: Merge Results

Once **all** tasks are done (or the user decides to proceed with completed ones),
merge each successful branch back into the base branch.

### Merge order

1. Sort tasks by number of files changed (fewest first) to minimize conflict surface
2. Merge one at a time, checking for conflicts after each

### Merge procedure

```bash
# Return to the main project directory (not a worktree)
cd <project-root>
git checkout "$BASE_BRANCH"

for slug in "${COMPLETED_SLUGS[@]}"; do
  echo "Merging wt/$slug..."
  if git merge "wt/$slug" --no-edit; then
    echo "✅ wt/$slug merged"
    git worktree remove ".worktrees/$slug"
    git branch -d "wt/$slug"
  else
    echo "⚠️  Conflict merging wt/$slug — stopping for user review"
    # Show conflicted files
    git diff --name-only --diff-filter=U
    # Ask user to resolve, then continue
    break
  fi
done
```

### Conflict handling

**Simple conflicts** (e.g. adjacent import lines, whitespace, non-overlapping changes
in the same file): resolve automatically, commit, and continue. No need to ask.

**Complex conflicts** (semantic overlap, same function modified differently, architectural
disagreements between branches): stop the merge loop, show the conflicted files and
diff hunks, and ask the user how to proceed.

### Post-merge summary

After all merges, print a final report:

```
Merge complete:
  ✅ wt/fix-readme-typo     — merged (1 file changed)
  ✅ wt/add-pagination       — merged (4 files changed)
  ⚠️  wt/redesign-auth       — conflicts resolved manually
  ❌ wt/add-caching          — no changes produced, skipped

Remaining worktrees: none
```

## Step 9: Report

Provide the user with:

1. **Summary** of what was merged and any issues encountered
2. **How to review** the combined result: `git log --oneline -10`
3. **Cleanup confirmation** — all worktrees and branches removed for merged tasks

## Edge Cases

- **No git repo**: Warn the user. Worktrees require git. Offer to initialize.
- **Uncommitted changes**: Warn before creating worktrees. Suggest stashing.
- **tmux not available**: Fall back to printing the claude commands for manual execution.
- **claude CLI not installed**: Explain how to install (`npm install -g @anthropic-ai/claude-code`).
- **Too many tasks (>10)**: Warn about resource usage. Suggest batching.
- **Conflicting worktrees**: If a worktree path exists, ask before overwriting.

## Cleanup Command

When the user says "clean up worktrees" or "finish orchestration":

```bash
# List all orchestrator worktrees
git worktree list | grep "wt-"

# For each, check if merged, then remove
git worktree remove <path>
git branch -d wt/<slug>
```

## Hook installation

The `task-monitor` window relies on a Claude Code `Notification` hook that timestamps each "awaiting input" prompt to `~/.cache/cc-monitor/<pane>.json`. The hook script ships in this repo at `hooks/cc-monitor-notify.sh`.

Wire it up in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /path/to/taskestro/hooks/cc-monitor-notify.sh"
          }
        ]
      }
    ]
  }
}
```

Replace `/path/to/taskestro` with the directory you cloned this repo into. Restart Claude Code for the hook to take effect.

Without this hook the monitor still shows tasks (it discovers them by tmux pane path) — but the `awaiting-input` state and elapsed-time-since-prompt columns will be empty.
