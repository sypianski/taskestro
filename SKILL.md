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

## Step 1: Locate and Parse the Task File

Look for a task file in the current project. Check these paths in order:
- Path explicitly provided by the user
- `TODO.md` in the project root
- `docs/TODO.md`
- Any file matching `*TODO*` or `*tasks*` in root

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

# For each task, create a worktree
git worktree add ../worktrees/wt-<slug> -b wt/<slug> $BASE_BRANCH
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

Place worktrees in `../worktrees/` relative to the project root, keeping the main
working directory clean. Create the directory if it doesn't exist.

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
   obscure what's happening. Wait a few seconds for the TUI to initialise:
   ```bash
   tmux send-keys -t "$SESSION_NAME:<window>" \
     "claude --dangerously-skip-permissions --model <haiku|sonnet|opus>" Enter
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

Before starting the polling loop, create a dedicated monitor window that gives the
user a live dashboard of all tasks. This is the **first window created** — it stays
in the foreground so the user sees progress without switching between task windows.

```bash
tmux new-window -t "$SESSION_NAME" -n "monitor"
```

### Monitor script

Write a bash script to the project root (`.task-monitor.sh`) and run it in the
monitor window. The script loops every 10 seconds and redraws the dashboard.

```bash
#!/usr/bin/env bash
SESSION="$1"
BASE_BRANCH="$2"
shift 2
# Remaining args: pairs of "window_name:model:worktree_path"
TASKS=("$@")

while true; do
  clear
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  TASK ORCHESTRATOR MONITOR                    $(date +%H:%M:%S)        ║"
  echo "╠══════════════════════════════════════════════════════════════════╣"
  printf "║  %-3s  %-28s %-8s %-18s ║\n" "#" "TASK" "MODEL" "STATUS"
  echo "╠══════════════════════════════════════════════════════════════════╣"

  ALL_DONE=true
  IDX=1

  for entry in "${TASKS[@]}"; do
    IFS=':' read -r WINDOW MODEL WTPATH <<< "$entry"

    # Check if claude is still running
    CMD=$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_current_command}' 2>/dev/null)

    if [ "$CMD" = "claude" ]; then
      # Try to detect if waiting for user input
      CAPTURE=$(tmux capture-pane -t "$SESSION:$WINDOW" -p 2>/dev/null | tail -5)
      if echo "$CAPTURE" | grep -qiE '(Y/n|y/N|\? |permission|allow|approve|deny)'; then
        STATUS="!! NEEDS INPUT"
      else
        STATUS=".. working"
      fi
      ALL_DONE=false
    elif [ -z "$CMD" ]; then
      STATUS="?? window gone"
    else
      # Claude exited — check result
      if [ -d "$WTPATH" ]; then
        COMMITS=$(git -C "$WTPATH" log "$BASE_BRANCH"..HEAD --oneline 2>/dev/null | wc -l)
        if [ "$COMMITS" -gt 0 ]; then
          if [ -f "$WTPATH/BLOCKERS.md" ]; then
            STATUS="~~ done (blockers)"
          else
            STATUS="OK done ($COMMITS commits)"
          fi
        else
          STATUS="-- no changes"
        fi
      else
        STATUS="OK merged"
      fi
    fi

    printf "║  %-3s  %-28s %-8s %-18s ║\n" "$IDX" "$WINDOW" "$MODEL" "$STATUS"
    IDX=$((IDX + 1))
  done

  echo "╠══════════════════════════════════════════════════════════════════╣"
  echo "║  Jump to task: press prefix then <number>                      ║"
  echo "║  !! = needs your input — switch to that window                 ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"

  if $ALL_DONE; then
    echo ""
    echo "All tasks finished. Returning to orchestrator..."
    exit 0
  fi

  sleep 10
done
```

### Launching the monitor

```bash
chmod +x .task-monitor.sh

# Build the task entries as "window:model:worktree_path" pairs
TASK_ARGS=()
for i in "${!TASK_WINDOWS[@]}"; do
  TASK_ARGS+=("${TASK_WINDOWS[$i]}:${TASK_MODELS[$i]}:${TASK_WORKTREES[$i]}")
done

tmux send-keys -t "$SESSION_NAME:monitor" \
  "bash .task-monitor.sh '$SESSION_NAME' '$BASE_BRANCH' ${TASK_ARGS[*]}" Enter
```

### Detecting "needs input"

The monitor captures the last 5 lines of each task pane and looks for input
prompts (`Y/n`, `permission`, `allow`, `approve`). This catches Claude Code's
permission dialogs. When detected, the status shows `!! NEEDS INPUT` to alert
the user to switch to that window.

Since Claude Code uses the alternate screen buffer, `capture-pane -p` may
return partial or empty content. The monitor uses it as a best-effort heuristic:
- If capture works and matches input patterns → `!! NEEDS INPUT`
- If capture is empty but `pane_current_command` is `claude` → `.. working`
- Trust `pane_current_command` over capture content for running/finished state

### Navigation

The user stays in the monitor window and can jump to any task window using
tmux's standard window switching (prefix + window number, or prefix + n/p).
The monitor shows the task number corresponding to the tmux window index.

After switching to a task window to provide input, the user returns to the
monitor with prefix + selecting the monitor window.

## Step 7: Wait for Completion

The orchestrator polls alongside the monitor (or relies on the monitor script's
exit as the signal). **The monitor script exits with 0 when all tasks finish.**

### Orchestrator polling

The orchestrator's own polling loop checks the monitor process:

```bash
# Wait for monitor to exit (= all tasks done)
MONITOR_PID=$(tmux list-panes -t "$SESSION_NAME:monitor" -F '#{pane_pid}')
while kill -0 "$MONITOR_PID" 2>/dev/null; do
  sleep 15
done
```

Alternatively, the orchestrator can poll independently using the same
`pane_current_command` check as before — the monitor is a convenience for
the user, not a dependency for the orchestrator logic.

### Detecting success vs failure

After all tasks finish, check each worktree for results:

```bash
cd <worktree-path>
NEW_COMMITS=$(git log "$BASE_BRANCH"..HEAD --oneline)
HAS_BLOCKERS=$(test -f BLOCKERS.md && echo yes || echo no)
```

- **New commits + no BLOCKERS.md** → task succeeded, proceed to merge automatically
- **New commits + BLOCKERS.md** → partial success, note in final report but still merge
- **No new commits** → task failed or produced no changes, skip and note in report

### Timeout

If a task runs longer than **30 minutes**, warn the user but keep waiting.
Only ask about killing if it exceeds **60 minutes**. Do not kill automatically.

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
    git worktree remove "../worktrees/wt-$slug"
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
