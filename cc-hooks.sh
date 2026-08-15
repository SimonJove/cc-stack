#!/usr/bin/env bash
# cc-hooks.sh · ALL Claude Code hook entries — one script, one subcommand per event.
#   cc-hooks.sh worktree   PostToolUse hook (matcher: Bash|EnterWorktree): the worktree tab opener
#                           [absorbs cc-worktree-cmux-hook.sh]
#   cc-hooks.sh status     UserPromptSubmit / Stop / Notification hook: the agent-state sidecar writer
#                           [absorbs cc-status-hook.sh]
# Both read the hook JSON on stdin and follow the hook hard rules: zero output, always exit 0,
# any failure degrades to a silent no-op (never interrupts Claude).
set -u

case "${1:-}" in

# ─────────────────────────────────────────────────────────────────────────────
# worktree — PostToolUse (Bash|EnterWorktree) tab opener
# What it does: after Claude runs `git worktree add` in Bash, automatically open a new surface (tab)
#   in the current cmux workspace and start a ccteam claude there; if CC_WT_PROMPT is set, send it as the first message.
#   - Only handles a Bash `git worktree add` (adjacent tokens); list/remove/prune do NOT trigger.
#     EnterWorktree (which moves the current claude into the worktree) has no `command` field, so it's naturally
#     excluded — avoids two claudes colliding in the same directory.
#   - Parses the target path + `-C <repo>` from the command (pinpoints the just-created worktree, cross-repo aware);
#     if it can't parse (e.g. a $VAR shell variable that wasn't expanded), falls back to "most-recent mtime".
#   - Initial-prompt convention: prefix the command with CC_WT_PROMPT='task description', e.g.:
#       CC_WT_PROMPT='refactor auth token refresh' git worktree add .claude/worktrees/oauth -b feat/oauth
#   - Sub-tasks start in `auto` mode. To pin ONE dispatch to the plan-first gate, add the prefix
#     CC_WT_PERMISSION_MODE=plan (parsed out of the command text, like CC_WT_PROMPT).
#   - cmux availability via `cmux ping` (not CMUX_SOCKET, which is often empty in CC's Bash env).
#   - Synchronous launch: CC reaps backgrounded children when the hook returns (tested: `&`/nohup/setsid all fail —
#     setsid detaches the session and then cmux gives Broken pipe), so it must be synchronous; the cost is this tool
#     call waits a few extra seconds (< CC's 60s hook timeout).
#   - cc-dispatch.sh (wt-claude / surface) opens its own tab, so skip when the command references it (avoids
#     double tabs); the legacy cc-worktree-claude / cc-cmux-surface-claude names stay for pre-refactor installs.
#   - Always exits 0; never interrupts Claude.
worktree)
shift
input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

# Cheap prefilter: if the raw JSON has no "worktree" (any case), bail out
case "$input" in
  *[Ww]orktree*) : ;;
  *) exit 0 ;;
esac

# cmux available? if we can't reach it (remote/not installed), silently skip
command -v cmux >/dev/null 2>&1 || exit 0
cmux ping >/dev/null 2>&1 || exit 0

# Parse: the just-created worktree absolute path + CC_WT_PROMPT value, TAB-separated (prompt may be empty)
line="$(
  CC_HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null || true
import json, os, sys, subprocess, time, shlex, re
try:
    d = json.loads(os.environ.get("CC_HOOK_INPUT", ""))   # passed via env: the heredoc occupies stdin, so json.load(stdin) is not usable
except Exception:
    sys.exit(0)
cwd = d.get("cwd") or os.getcwd()
ti  = d.get("tool_input") or {}
cmd = ti.get("command", "") if isinstance(ti, dict) else ""
low = cmd.lower()
# Only handle a Bash `worktree` command; tools without a `command` field (EnterWorktree) are naturally excluded
if "worktree" not in low:
    sys.exit(0)
# These scripts open their own tab, so do not let the hook open another (double tab).
# gwt-claude=cc-dispatch.sh wt-claude. The CC_WT_PROMPT payload is FREE TEXT: strip the
# single-quoted span before substring testing, so a brief that merely MENTIONS a script name
# does not kill the dispatch. The legacy cc-worktree-claude / cc-cmux-surface-claude names stay
# listed — pre-refactor installs may still run those scripts.
# (q = chr(39): a literal apostrophe must not appear in this heredoc — bash 3.2 mis-parses one
#  inside a heredoc nested in $( ).)
q = chr(39)
bare = re.sub("cc_wt_prompt=" + q + "[^" + q + "]*" + q, " ", low)
if "cc-dispatch.sh" in bare or "cc-worktree-claude" in bare or "cc-cmux-surface-claude" in bare:
    sys.exit(0)

try:
    toks = shlex.split(cmd)
except Exception:
    toks = []

# Must be `git worktree add` (adjacent); list/remove/prune etc. never open a tab (kills false triggers)
wi = -1
for i in range(len(toks) - 1):
    if toks[i] == "worktree" and toks[i + 1] == "add":
        wi = i
        break
if wi < 0:
    sys.exit(0)

# (B) Cross-repo: take the nearest `-C <dir>` before "worktree" as the repo.
# If the parsed dir is invalid (e.g. -C $VAR not expanded by the shell), fall back to cwd — combined with the mtime fallback below it still works.
repo = None
for i in range(wi):
    if toks[i] == "-C" and i + 1 < wi:
        repo = toks[i + 1]
if repo:
    if not os.path.isabs(repo):
        repo = os.path.join(cwd, repo)
    if not os.path.isdir(repo):
        repo = None
if not repo:
    repo = cwd

# (A) Parse the add target path directly: first "bare positional" after add (skip value-taking options and command separators)
opts_with_val = {"-b", "-B", "--reason"}
path_arg = None
j = wi + 2
while j < len(toks):
    t = toks[j]
    if t in (";", "&&", "||", "|", "&"):
        break
    if t in opts_with_val:
        j += 2; continue
    if t.startswith("-"):
        j += 1; continue
    path_arg = t
    break

# List worktrees in the correct repo
try:
    out = subprocess.check_output(
        ["git", "-C", repo, "worktree", "list", "--porcelain"],
        text=True, stderr=subprocess.DEVNULL,
    )
except Exception:
    sys.exit(0)
listed = [l[len("worktree "):] for l in out.splitlines() if l.startswith("worktree ")]
linked = [p for p in listed[1:] if os.path.isdir(p)]   # first entry is the main worktree
if not linked:
    sys.exit(0)

# (A) Prefer an exact match on the parsed path (relative paths resolved against the repo dir); fall back to most-recent mtime (covers $VAR etc.)
chosen = None
if path_arg:
    cand = path_arg if os.path.isabs(path_arg) else os.path.join(repo, path_arg)
    cand = os.path.realpath(cand)
    for p in linked:
        if os.path.realpath(p) == cand:
            chosen = p
            break
if chosen is None:
    chosen = max(linked, key=lambda p: os.stat(p).st_mtime)

# Only handle "just created" (within 120s), avoids opening on odd cases
if time.time() - os.stat(chosen).st_mtime > 120:
    sys.exit(0)

# Extract the CC_WT_PROMPT / CC_WT_PERMISSION_MODE values from the command (quote-aware); empty if absent.
# The env-prefix form only sets them inside the Bash tool shell — this hook is a separate process and would
# never see them — so they are read out of the command TEXT, same as everything else here.
# (No apostrophes in this heredoc: bash 3.2 mis-parses a single quote inside a heredoc nested in $( ).)
prompt = ""
mode = ""
for tok in toks:
    if tok.startswith("CC_WT_PROMPT="):
        prompt = tok[len("CC_WT_PROMPT="):]
    elif tok.startswith("CC_WT_PERMISSION_MODE="):
        mode = tok[len("CC_WT_PERMISSION_MODE="):].strip()
# mode goes in the middle: the prompt is free text and may itself contain tabs, so it must stay last
sys.stdout.write(chosen + "\t" + mode + "\t" + prompt)
PY
)"

# Split path / permission-mode / prompt (python always writes two TABs; prompt is everything after the second)
newpath="${line%%$'\t'*}"
rest="${line#*$'\t'}"
[ "$rest" = "$line" ] && rest=""                    # no TAB at all → nothing but the path
if [ "$rest" = "${rest#*$'\t'}" ]; then
  mode=""; prompt="$rest"                           # only one TAB → treat the remainder as the prompt
else
  mode="${rest%%$'\t'*}"; prompt="${rest#*$'\t'}"
fi
[ -n "$newpath" ] || exit 0

# Per-dispatch permission mode: CC_WT_PERMISSION_MODE=plan on the command line pins THIS sub-task to
# plan-first (default is auto). cc-dispatch.sh surface whitelists the value.
[ -n "$mode" ] && export CC_WT_PERMISSION_MODE="$mode"

# Synchronously open surface + start ccteam (+send prompt). Must be synchronous: see the header notes.
# (Shared-corpus seeding [CC_WT_SHARE] happens inside cc-dispatch.sh surface — the single point
#  both this hook path and gwt-claude go through.)
CC_CALLER_CWD="$(printf '%s' "$input" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("cwd",""))' 2>/dev/null || true)" \
  "$HOME/.config/cc-stack/cc-dispatch.sh" surface "$newpath" "$prompt" >/dev/null 2>&1

exit 0
;;

# ─────────────────────────────────────────────────────────────────────────────
# status — UserPromptSubmit / Stop / Notification agent-state writer
#   Keeps a per-sub-task agent-state sidecar (worktree-status.tsv, read by gwt-status's STATUS column)
#   with ZERO model cooperation and ZERO token cost: Claude Code fires these hooks on its own lifecycle,
#   the hook just records them.
#   - Board membership is the filter: only dirs already registered in worktree-tasks.tsv (written when
#     the tab was opened) get a row — the MAIN session and unrelated projects never write here,
#     even though the hook is registered globally.
#   - States: UserPromptSubmit → working; Stop → idle; Notification → blocked ONLY when the message
#     text mentions "permission" (other notifications are noise). There is deliberately NO ready
#     state: readiness stays owned by gwt-done + a clean tree (see README).
#   - The board's dir column is `cd <dir> && pwd -P` output (cc-dispatch.sh surface), so the
#     hook's cwd is canonicalized the exact same way before matching.
#   - Read-modify-write (one row per dir, newest wins) under cc-board.sh log's mkdir-lock pattern
#     (macOS has no flock); the same lock discipline in worktree.zsh keeps gwt-rm/gwt-prune rewrites
#     from losing a concurrent hook update.
#   - HARD RULES: never write to stdout/stderr (UserPromptSubmit stdout gets injected into the
#     model's context — zero token cost means zero output); ALWAYS exit 0 (exit 2 would block the
#     user's prompt); any failure (no python3, malformed JSON, unreadable board) degrades to a
#     silent no-op. cmux-independent by design — pure file bookkeeping, no surfaces touched.
status)
shift
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
# Locked read-modify-write: drop any previous row for this dir, append the fresh one (cc-board.sh log
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
;;

*)
  echo "usage: cc-hooks.sh worktree|status   (Claude Code hook JSON on stdin)" >&2; exit 2 ;;
esac
