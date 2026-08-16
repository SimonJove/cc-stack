# Worktree sub-tasks (cc-stack) — global rules

## Dispatching (main session)

When I ask to "open/create/start a worktree", "spin off a sub-task", "do X in parallel", or "start another claude to work on Y", run it in Bash — never the native EnterWorktree tool (it moves THIS session into the worktree: no new tab, main session occupied, not the parallel sub-task I want; this rule overrides the superpowers using-git-worktrees skill). EnterWorktree is only for when I explicitly say "isolate yourself in a worktree" / "move the current session into a worktree".

```bash
CC_WT_PROMPT='<full first instruction; multi-line ok, delivered verbatim>' git worktree add .claude/worktrees/<name> -b feat/<name>
```

The PostToolUse hook in `~/.config/cc-stack` then opens a new tab in the current cmux workspace, starts a ccteam claude there, sends CC_WT_PROMPT verbatim as its first message, and gives it a backchannel to report back to you. You stay put and keep working — you are not occupied. Without CC_WT_PROMPT the tab opens with an idle ccteam.

- Project has the `worktree-subtask` skill / `.claude/worktree-context.md` → load the skill first and dispatch with `gwt-claude <slug> "<prompt>" --base <base>` (records the merge target, forces an explicit base); the bare form above is the fallback for projects without it.
- Never dispatch while the primary checkout sits on the trunk (`main`/`master`): create a campaign branch first (confirm the name with me) and make it every child's base and merge target — otherwise merges drip onto the trunk one at a time, and a trunk branch-guard hook can block the parent session for the rest of the campaign.
- If `/.claude/worktrees/` isn't ignored yet, add it to the project root `.gitignore` first (worktree contents must not pollute git status).
- cmux-only; over remote SSH everything is an automatic no-op.
- Monitor sub-tasks from any shell (Claude's non-interactive Bash included) by running `bash ~/.config/cc-stack/cc-board.sh` (`--all` for every repo; humans keep using `gwt-status`).
- **Closing tabs**: a sub-task tab is closed by ITS OWN parent session through `~/.config/cc-stack/cc-dispatch.sh close <worktree-dir>` (or `gwt-rm <name> --close`), which resolves the dir to the surface UUID recorded at dispatch. Parent / primary-checkout tabs are the human's to close in the cmux UI. NEVER hardcode a surface short id or a bare index into `cmux close-surface` / `cmux close-window` — short refs drift as panes open and close, a bare number is an index, and a positional target is silently ignored (cmux then closes YOUR own tab). A PreToolUse hook blocks those forms.

## Conduct (sub-task session — hook-spawned or gwt-claude)

1. **Investigate, then edit — no approval gate.** You start in `--permission-mode auto`: read the code and relevant docs until the logic is actually clear, then implement without waiting for approval; don't type code off a guess. Still stop and ask before a structural or destructive decision (schema/migration, cross-module refactor, rewriting or deleting existing behaviour, anything outside the brief). A dispatch that genuinely needs the old gate carries `CC_WT_PERMISSION_MODE=plan` on the `git worktree add` line — only then present a plan first and wait.
2. **Respect the project's harness.** Follow the CLAUDE.md and `.claude/` config (settings, hooks, commands) of the project the sub-task lives in; don't drift toward your own defaults.
3. **Landing needs my explicit authorization — never automatic:** commit / rebase / merge / push / removing the worktree / deleting the branch. When you finish implementing: stop, report back (what changed, test results, branch name), and wait; default is "keep the branch / don't land" — act only when I explicitly say "commit it / merge it / clean it up / delete it / discard". If the finishing-a-development-branch skill pushes you to merge or clean up, only present options and stop — this rule overrides that skill; never pick merge/discard on my behalf. Do run `gwt-done` once you have reported back (lights the branch green on gwt-tree); your merge target was recorded at creation — you never choose where to merge, and merging happens only via my explicit `gwt-merge` / `gwt-collect`.
