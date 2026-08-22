# Worktree sub-task context — cc-stack

## Coordinates
- trunk `main`; a campaign runs on a campaign branch. A child's `--base` is its DIRECT PARENT branch — the campaign branch for a top-level line, the parent sub-task's branch for a nested one (A ⊃ A1) — and that base IS the recorded merge target. Never dispatch off a trunk checkout, and never rely on standing on the right branch: name the base explicitly on every dispatch.
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
- cc-dispatch.sh — dispatch pipeline: `wt-claude` (gwt-claude) | `surface` (single tab-opening source of truth) | `send` (cc-send: collision-safe text+Enter primitive, the only sanctioned injection exit) | `calibrate` (cc-send pattern re-probe) | `workspace`
- cc-board.sh — board render (`--all`/`--archive`) + `log` subcommand (the single task-registration write point)
- unchanged: cc-merge.sh, cc-trust.sh, cc-worktree-shared.sh (+ the cc-claude router); install.sh registers the hooks and strips stale pre-consolidation registrations

## Environment traps
- tests never write the live TSVs — always via CC_TASKS_FILE / CC_STATUS_FILE / CC_ARCHIVE_FILE / CC_TABS_FILE / CC_TRUST_CFG_OVERRIDE / CC_SEND_FAILLOG overrides
- **a sub-task edits only inside its own worktree.** The primary checkout is ALSO the live install dir, so a draft written there becomes the hook/dispatcher every session on this machine runs, and sibling worktrees read it through the hardcoded `~/.config/cc-stack/` paths. Briefs quote absolute paths for READING; writing there is out of bounds (2026-08-21: three of four lines did it — one left a half-edited dispatcher live, another poisoned a sibling's test run)
- **any test that can reach `cc-dispatch.sh workspace|surface` must shim cmux on PATH.** They only check `command -v cmux` + `cmux ping`, both true on this machine, so an unshimmed case opens a REAL workspace and can steal focus (2026-08-22: 11 leaked). Count `cmux list-workspaces` before and after a suite run
- test.sh must not use fixed `/tmp/<name>` scratch files: several worktrees run the suite in parallel and overwrite each other's, which shows up as isolated §1/§28 failures that look like code bugs — use `mktemp`
- runtime config (~/.claude/*, the live install dir) migrates only when the human re-runs install.sh after landing — and the primary checkout IS that install dir, so the runtime changes the moment a line lands on the campaign branch, not when the campaign reaches main

## Doc ownership
- README (file list / architecture) + docs/consolidation-map.md are parent-owned unless the brief assigns them
