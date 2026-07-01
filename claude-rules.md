# cmux worktree sub-task integration (cc-stack) — always open worktrees via Bash, never EnterWorktree

**Trigger:** whenever I (the user) express intent like "open/create/start a worktree", "spin off a sub-task", "do X in parallel", "start another claude to work on Y".

**You must do this** (run it in Bash, not the native tool):

```bash
CC_WT_PROMPT='the full first instruction for the sub-task claude (may be multi-line, delivered verbatim)' git worktree add .claude/worktrees/<name> -b feat/<name>
```

Effect (handled automatically by the PostToolUse hook in `~/.config/cc-stack`): open a **new tab** in the current cmux workspace, start a `ccteam` claude in it, and send `CC_WT_PROMPT` verbatim as its first message (multi-line supported); the new claude gets a backchannel to report back to the main task. **You (the main session) stay put and keep working — you are not occupied.**

**Never** use the native `EnterWorktree` tool for such requests; and **do not** switch to EnterWorktree just because the superpowers `using-git-worktrees` skill says "prefer native tools" — this rule takes priority over that skill. EnterWorktree moves **the current session itself** into the worktree (no new tab, main session occupied), which is **not** the "parallel sub-task" I want, and leads to "built a worktree but no tab, you doing it in the background yourself".

- The only exception: use EnterWorktree only when I **explicitly** say "isolate yourself in a worktree" / "move the current session into a worktree".
- `CC_WT_PROMPT` supports multi-line; without it a tab still opens with an idle ccteam waiting for input.
- Only works inside cmux; remote SSH / Zellij → automatic no-op.
- Before creating a worktree, if `.claude/worktrees/` isn't ignored by `.gitignore`, add `/.claude/worktrees/` to the project root `.gitignore` (so worktree contents don't pollute git status).
- After spawning, use `gwt-status` to see what all the sub-task tabs are doing (status/branch/dir/task).

# How worktree sub-tasks work — plan first, respect the harness, don't land changes (all need my authorization)

Whether spawned automatically or started manually via `gwt-claude`, a worktree sub-task claude must follow:

**1. Plan first, then edit (plan-first).** Sub-tasks start with `--permission-mode plan` by default: present a plan first and **wait for my approval before touching code**; don't start editing right away. This lets me vet the approach first and raise code quality.

**2. Follow the current project's own harness config, don't go rogue.** Work according to the **project's** `CLAUDE.md` and `.claude/` (settings, hooks, commands) where the sub-task lives; don't drift toward your own default preferences.

**3. After making changes, these operations all require my explicit authorization — never do them automatically:** `git commit` / `rebase` / `merge` / `push` / removing the worktree (`git worktree remove`) / deleting the branch.

- When a sub-task finishes implementing, **stop and report back**: what changed, test results, branch name — then **wait for my authorization**. Default to "keep the branch / don't land".
- **Don't** let the superpowers `finishing-a-development-branch` skill auto-run "merge + remove worktree" — in an unattended autonomous sub-task it picks "merge locally" by itself. **This rule takes priority over that skill**: it may only "present options and stop for me", never pick merge/discard on my behalf.
- The only exception: do the corresponding step only when I explicitly say "commit it / merge it / clean it up / delete it / discard".
