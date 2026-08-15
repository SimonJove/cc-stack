# Worktree sub-task context — cc-stack

## Coordinates
- trunk `main`; a campaign runs on a campaign branch that is every child's `--base` AND merge target (never dispatch off a trunk checkout)
- branches `feat/<slug>` / `issue/<slug>`; working language Chinese, code/comments/commits English

## Lifecycle
- dispatch + gate via the global worktree-subtask skill (`gwt-claude` / `gwt-tree` / `gwt-done` / `gwt-merge`)
- land ONLY after the parent's independent gate AND explicit human authorization — default is keep the branch; no commit/rebase/merge/push from a sub-task

## Verification
- one command: `bash test.sh` (smoke test; runs the copy it lives in — a worktree tests itself); `0 failed` required
- bash 3.2 safe everywhere (no assoc arrays, no `${var,,}`); zsh stays confined to worktree.zsh
- no literal apostrophe inside cc-hooks.sh's `<<'PY'` python heredoc (bash 3.2 mis-parses one in `$( )`); test.sh extracts that heredoc, so it must remain the file's only one
- install / hook-registration tests use the HOME-override pattern — never touch the live `~/.claude/settings.json`

## Script map (post-consolidation, 10 → 6 .sh)
- cc-hooks.sh — ALL hook entries: `worktree` (PostToolUse tab opener) | `status` (agent-state sidecar)
- cc-dispatch.sh — dispatch pipeline: `wt-claude` (gwt-claude) | `surface` (single tab-opening source of truth) | `workspace`
- cc-board.sh — board render (`--all`/`--archive`) + `log` subcommand (the single task-registration write point)
- unchanged: cc-merge.sh, cc-trust.sh, cc-worktree-shared.sh (+ the cc-claude router); install.sh registers the hooks and strips stale pre-consolidation registrations

## Environment traps
- tests never write the live TSVs — always via CC_TASKS_FILE / CC_STATUS_FILE / CC_ARCHIVE_FILE overrides
- runtime config (~/.claude/*, the live install dir) migrates only when the human re-runs install.sh after landing

## Doc ownership
- README (file list / architecture) + docs/consolidation-map.md are parent-owned unless the brief assigns them
