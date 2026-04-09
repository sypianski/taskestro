# Task Orchestrator

A [Claude Code](https://claude.ai/code) skill that dispatches tasks from a TODO file into parallel development streams, each running in its own git worktree and tmux window.

## What it does

```
TODO.md → parse tasks → estimate complexity → select model → create worktrees → launch tmux → claude CLI
```

1. **Parses** your TODO.md (checkbox, header-based, or tagged formats)
2. **Estimates complexity** of each task and picks the right Claude model (Haiku / Sonnet / Opus)
3. **Creates git worktrees** so each task works on an isolated branch
4. **Launches tmux windows** with Claude Code sessions, one per task
5. **Monitors** progress and helps you merge results back

## Installation

Copy `SKILL.md` into your Claude Code skills directory:

```bash
mkdir -p ~/.claude/skills/task-orchestrator
cp SKILL.md ~/.claude/skills/task-orchestrator/
```

## Usage

With the skill installed, tell Claude Code things like:

- "run my tasks"
- "orchestrate tasks from TODO.md"
- "dispatch tasks in parallel"
- "spin up worktrees for my TODO list"

Claude will parse your TODO file, present a plan with model assignments, and launch everything after your confirmation.

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

## License

MIT
