#!/usr/bin/env bash
# cc-stack · Claude Code sub-task status hook — ONE script registered for THREE events
#   (UserPromptSubmit / Stop / Notification). Keeps a per-sub-task agent-state sidecar
#   (worktree-status.tsv, read by gwt-status's STATUS column) with ZERO model cooperation and
#   ZERO token cost: Claude Code fires these hooks on its own lifecycle, the hook just records them.
#   - Board membership is the filter: only dirs already registered in worktree-tasks.tsv (written when
#     the tab was opened) get a row — the MAIN session and unrelated projects never write here,
#     even though the hook is registered globally.
#   - States: UserPromptSubmit → working; Stop → idle; Notification → blocked ONLY when the message
#     text mentions "permission" (other notifications are noise). There is deliberately NO ready
#     state: readiness stays owned by gwt-done + a clean tree (see README).
#   - The board's dir column is `cd <dir> && pwd -P` output (cc-cmux-surface-claude.sh), so the
#     hook's cwd is canonicalized the exact same way before matching.
#   - Read-modify-write (one row per dir, newest wins) under cc-tasks-log.sh's mkdir-lock pattern
#     (macOS has no flock); the same lock discipline in worktree.zsh keeps gwt-rm/gwt-prune rewrites
#     from losing a concurrent hook update.
#   - HARD RULES: never write to stdout/stderr (UserPromptSubmit stdout gets injected into the
#     model's context — zero token cost means zero output); ALWAYS exit 0 (exit 2 would block the
#     user's prompt); any failure (no python3, malformed JSON, unreadable board) degrades to a
#     silent no-op. cmux-independent by design — pure file bookkeeping, no surfaces touched.
set -u

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

# Parse the three fields we need from the hook payload: event \t cwd \t notification-message
# (TAB-separated, message last). python reads real stdin via -c (no heredoc here); any parse
# failure prints nothing → the event match below exits 0.
parsed="$(printf '%s' "$input" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
if not isinstance(d, dict): sys.exit(0)
sys.stdout.write("%s\t%s\t%s" % (d.get("hook_event_name") or "", d.get("cwd") or "", d.get("message") or ""))' 2>/dev/null || true)"
ev="${parsed%%$'\t'*}"; rest="${parsed#*$'\t'}"
cwd="${rest%%$'\t'*}"; msg="${rest#*$'\t'}"

# Event → state. Notification only counts when the message mentions permission (that is the
# "sub-task is stuck waiting for a human" signal); everything else is ignored, never written.
case "$ev" in
  UserPromptSubmit) state="working" ;;
  Stop)             state="idle" ;;
  Notification)
    case "$msg" in
      *[Pp]ermission*) state="blocked" ;;
      *)               exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac

# Canonical dir, same form the board stores. CDPATH= so a stray CDPATH can neither redirect the cd
# nor echo into $canon; an un-enterable cwd can never match the board anyway.
[ -n "$cwd" ] || exit 0
canon="$(CDPATH= cd -- "$cwd" 2>/dev/null && pwd -P)" || exit 0

tasks="${CC_TASKS_FILE:-$HOME/.config/cc-stack/worktree-tasks.tsv}"
[ -f "$tasks" ] || exit 0
awk -F'\t' -v d="$canon" '$4==d{found=1} END{exit found?0:1}' "$tasks" 2>/dev/null || exit 0

f="${CC_STATUS_FILE:-$HOME/.config/cc-stack/worktree-status.tsv}"
# Locked read-modify-write: drop any previous row for this dir, append the fresh one (cc-tasks-log.sh
# pattern — mkdir is atomic; if the lock never frees we still write, matching its append behavior).
lock="$f.lock"
for _ in $(seq 1 60); do
  if mkdir "$lock" 2>/dev/null; then trap 'rmdir "$lock" 2>/dev/null' EXIT; break; fi
  sleep 0.05
done
tmp="$f.tmp.$$"
awk -F'\t' -v OFS='\t' -v d="$canon" '$1!=d' "$f" 2>/dev/null > "$tmp" || : > "$tmp"
printf '%s\t%s\t%s\n' "$canon" "$state" "$(date +%s)" >> "$tmp"
mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null

exit 0
