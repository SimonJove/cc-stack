# Consolidation map — cc-* scripts 10 → 6 (campaign feat/consolidation)

Goal: merge the cc-* scripts into fewer verb-named multi-subcommand scripts.
ZERO behavior change except the hook-filter fix noted below. The existing suite
(171 assertions at campaign start) must stay green; only the invocation paths
inside tests may change, never the asserted behavior.

## New layout

1. **cc-hooks.sh** — all Claude Code hook entries (one script, one subcommand per event):
   - `cc-hooks.sh worktree` ← absorbs `cc-worktree-cmux-hook.sh` (the PostToolUse
     `Bash|EnterWorktree` tab opener; reads hook JSON on stdin, everything else identical)
   - `cc-hooks.sh status` ← absorbs `cc-status-hook.sh` (the
     UserPromptSubmit/Stop/Notification agent-state writer; stdin JSON, same hard rules:
     zero output, exit 0, never writes ready)
2. **cc-dispatch.sh** — the dispatch pipeline:
   - `cc-dispatch.sh wt-claude <name> <prompt> [--prefix <p>] [--base <b>]` ← absorbs
     `cc-worktree-claude.sh` (the gwt-claude implementation)
   - `cc-dispatch.sh surface <path> [prompt]` ← absorbs `cc-cmux-surface-claude.sh`
     (open tab + copy + trust + launch + register — stays the single source of truth)
   - `cc-dispatch.sh workspace <path> [name] [focus]` ← absorbs `cc-cmux-workspace.sh`
3. **cc-board.sh** — gains a `log` subcommand absorbing `cc-tasks-log.sh`:
   `cc-board.sh log <dir> <surface> <caller> <prompt> <parent>` appends the 7-field row
   under the same mkdir lock. No-subcommand / render flags keep today's CLI unchanged.
4. **Unchanged**: `cc-claude`, `cc-merge.sh`, `cc-trust.sh`, `cc-worktree-shared.sh`.

Delete the four absorbed scripts after their logic moves.

## Hook-filter fix (folds in the recorded bug: brief text false-positive)

In the absorbed tab-opener python (now inside `cc-hooks.sh worktree`), the
anti-double-tab skip test greps the WHOLE command including the CC_WT_PROMPT
payload, so any brief that merely mentions a script name silently kills the
dispatch. Change it to:

- strip the single-quoted `CC_WT_PROMPT='...'` span BEFORE substring testing
  (only the real command is inspected), and
- update the trigger names to the new world: skip when the remaining command
  references `cc-dispatch.sh` (its wt-claude/surface paths open their own tab),
  while ALSO still skipping the two legacy script names (pre-refactor installs
  may still run them).

Regression tests: (a) a brief whose PROMPT TEXT mentions cc-dispatch.sh and the
legacy names still dispatches; (b) a command that actually invokes
`cc-dispatch.sh wt-claude ...` is skipped (no double tab).

## Call-site updates (grep every old path)

- `worktree.zsh`: the workspace opener calls in gwt-new/gwt-adopt →
  `cc-dispatch.sh workspace`; any surface-script references likewise.
- `aliases.zsh`: the gwt-claude alias target → `cc-dispatch.sh wt-claude`.
- The absorbed surface logic calls cc-tasks-log.sh → now `cc-board.sh log`
  (same args incl. the parent field). cc-merge / cc-trust / cc-worktree-shared
  calls are unchanged.
- `test.sh`: every test that invokes, extracts, or greps the old script paths
  (hook-parser section, status-hook section, board section, install tests,
  surface-script greps) moves to the new paths/subcommands. Assertion strings
  about behavior stay identical.
- `README.md`: file list, architecture/data-flow, any old names.
- `claude-rules.md`: verify it names none of the renamed scripts (it should
  only reference cc-board.sh and gwt-claude); leave it alone if so.
- `docs/known-issues.md`: update any old-name references.

## install.sh migration (critical)

- Step 4 registers the NEW hook commands: PostToolUse (`Bash|EnterWorktree`) →
  `~/.config/cc-stack/cc-hooks.sh worktree`; UserPromptSubmit / Stop /
  Notification → `~/.config/cc-stack/cc-hooks.sh status` (same idempotent
  `has()` pattern).
- Strip stale registrations: extend the existing cc-notify strip logic into a
  general stale-command list — remove any hook command whose text contains
  `cc-worktree-cmux-hook.sh` or `cc-status-hook.sh`. Idempotent; test it.
- The sub-task must NOT touch runtime `~/.claude/settings.json` directly —
  install.sh (run by the human after landing) does the migration; tests use the
  HOME-override pattern the install tests already use.

## New: .claude/worktree-context.md (project appendix)

The global rules reference this appendix; this repo never had one (noted twice
by gatekeepers). Create it, ≤30 lines: campaign workflow for this repo (trunk
rule, campaign branch, gate-then-authorize landing), the 6-script map, how to
run tests (`bash test.sh`), the no-landing-without-authorization rule.

## Constraints

- Zero behavior change beyond the filter fix; bash 3.2 safe in all scripts;
  zsh stays confined to worktree.zsh.
- New tests: filter fix (2), install migration strip (2–3), cc-board.sh log
  round-trip (the absorbed cc-tasks-log tests carry over to the new path).
- No git commit / merge / push / worktree removal. Report back with what
  changed, test counts, branch name; then run gwt-done.
