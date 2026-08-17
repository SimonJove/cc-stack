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
#
# v2.1 — parsing hardening (test.sh §23). Three holes let the walk name a directory the command
# never contained: pathname expansion against the hook's own cwd, a leading quote that was never
# stripped, and an uninitialised `top` inherited from the caller's environment. Two of the three
# were fail-OPEN. The invariant they all restore: when the command text cannot be resolved, the
# session cwd decides — that is the conservative answer, never a silent allow.

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
top=""                                    # the fallback below READS this — never inherit it from the env
case "$cmd" in
  *--git-dir=*) ;;                        # exotic form: keep the session-cwd check
  *)
    # `set -f` is load-bearing. The split below is an unquoted expansion, so without it the shell
    # also does PATHNAME expansion against the HOOK's cwd: whatever files happen to sit there get
    # spliced into the token stream and can forge a `cd`/`-C` the command never contained (and the
    # mirror case — a glob the real shell keeps quoted gets expanded here). The verdict must depend
    # on the command text alone, never on a directory listing.
    case "$-" in *f*) had_f=1 ;; *) had_f="" ;; esac
    set -f
    want=0
    for tok in $cmd; do
      if [ "$want" != 0 ]; then
        # Strip ONE matching quote pair. A token carrying an UNBALANCED quote is a fragment (the
        # word split cut `cd '/a b'` in half) — it names no directory we can trust, so blank it
        # and let the session cwd decide. Stripping only the tail used to leave a leading quote
        # in place, which silently disabled `cd '<dir>'` in both directions.
        case "$tok" in
          \"*\"|\'*\') target="${tok#?}"; target="${target%?}" ;;
          *\"*|*\'*)   target="" ;;
          *)           target="$tok" ;;
        esac
        want=0
      fi
      case "$tok" in
        cd|-C) want=1 ;;
        commit) break ;;
      esac
    done
    [ -n "$had_f" ] || set +f
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
