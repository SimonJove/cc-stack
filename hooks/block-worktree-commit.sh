#!/usr/bin/env bash
# cc-stack hook (repo-owned; distributed by install.sh into <cc-stack>/hooks/ and registered on
# PreToolUse — it used to live UNVERSIONED at ~/.claude/hooks/, which install.sh now de-registers).
# PreToolUse (Bash): block `git commit` from inside a worktree sub-task unless the parent
# has granted it. The authorization red line ("commit needs the human") is otherwise prose
# only — a sub-task in auto mode can commit with no mechanical gate, and cc-stack sub-tasks
# have been observed bypassing the discipline. Scope: only checkouts under .claude/worktrees/;
# the primary checkout is unaffected.
#
# Grant: the parent session (relaying the human's authorization) creates a sentinel at the
# worktree root:
#     touch <worktree>/.commit-authorized
# The sentinel is CONSUMED on each allowed commit — one grant, one commit. If the commit then
# fails (e.g. the commit-msg hook rejects it), the grant is spent; re-touch to retry.
# Exit 2 blocks the call (same convention as the sibling hooks).
#
# v2 — the worktree context is taken from the COMMAND's effective directory (the last `cd X`
# or `git -C X` ahead of the commit subcommand), not the session cwd. The cwd-only check
# mis-blocked parent sessions whose shell was still parked inside a worktree while the
# command itself cd'd out to commit in the primary checkout. Unparseable/exotic commands
# fall back to the session-cwd check (never more permissive than v1).

input=$(cat)

cmd=$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception:
    pass' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# Only commands that actually run `git commit` (allowing -C/-c/--git-dir style flags between).
printf '%s' "$cmd" | grep -qE 'git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+|[[:space:]]+--git-dir=[^[:space:]]+)*[[:space:]]+commit([[:space:]"]|$)' || exit 0

# Effective directory of the commit: walk the words; `cd X` and `-C X` both move it, the
# LAST one before the commit subcommand wins. Best-effort only — unresolvable candidates
# fall through to the session cwd.
target=""
case "$cmd" in
  *--git-dir=*) ;;                        # exotic form: keep the session-cwd check
  *)
    want=0
    for tok in $cmd; do
      if [ "$want" != 0 ]; then
        target="${tok#\"}"; target="${target%\"}"; target="${target%\'}"; target="${target%\'}"
        want=0
      fi
      case "$tok" in
        cd|-C) want=1 ;;
        commit) break ;;
      esac
    done
    ;;
esac

if [ -n "$target" ] && [ -d "$target" ]; then
  top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null) || top=""
fi
if [ -z "$top" ]; then
  top=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
fi
case "$top" in
  */.claude/worktrees/*) : ;;
  *) exit 0 ;;
esac

sentinel="$top/.commit-authorized"
if [[ -f "$sentinel" ]]; then
  rm -f "$sentinel"
  exit 0
fi

echo "git commit inside a worktree sub-task requires the human's authorization — stop and report back instead." >&2
echo "Parent session: grant exactly one commit with: touch $sentinel" >&2
exit 2
