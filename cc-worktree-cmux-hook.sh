#!/usr/bin/env bash
# cc-stack · Claude Code PostToolUse hook (matcher: Bash|EnterWorktree)
# What it does: after Claude runs `git worktree add` in Bash, automatically open a new surface (tab)
#   in the current cmux workspace and start a ccteam claude there; if CC_WT_PROMPT is set, send it as the first message.
#   - Only handles a Bash `git worktree add` (adjacent tokens); list/remove/prune do NOT trigger.
#     EnterWorktree (which moves the current claude into the worktree) has no `command` field, so it's naturally
#     excluded — avoids two claudes colliding in the same directory.
#   - Parses the target path + `-C <repo>` from the command (pinpoints the just-created worktree, cross-repo aware);
#     if it can't parse (e.g. a $VAR shell variable that wasn't expanded), falls back to "most-recent mtime".
#   - Initial-prompt convention: prefix the command with CC_WT_PROMPT='task description', e.g.:
#       CC_WT_PROMPT='refactor auth token refresh' git worktree add .claude/worktrees/oauth -b feat/oauth
#   - cmux availability via `cmux ping` (not CMUX_SOCKET, which is often empty in CC's Bash env).
#   - Synchronous launch: CC reaps backgrounded children when the hook returns (tested: `&`/nohup/setsid all fail —
#     setsid detaches the session and then cmux gives Broken pipe), so it must be synchronous; the cost is this tool
#     call waits a few extra seconds (< CC's 60s hook timeout).
#   - cc-worktree-claude.sh / cc-cmux-surface-claude.sh open their own tab, so skip when the command references them (avoids double tabs).
#   - Always exits 0; never interrupts Claude.
set -u

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

# Cheap prefilter: if the raw JSON has no "worktree" (any case), bail out
case "$input" in
  *[Ww]orktree*) : ;;
  *) exit 0 ;;
esac

# cmux available? if we can't reach it (remote/Zellij/not installed), silently skip
command -v cmux >/dev/null 2>&1 || exit 0
cmux ping >/dev/null 2>&1 || exit 0

# Parse: the just-created worktree absolute path + CC_WT_PROMPT value, TAB-separated (prompt may be empty)
line="$(
  CC_HOOK_INPUT="$input" python3 - <<'PY' 2>/dev/null || true
import json, os, sys, subprocess, time, shlex
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
# These scripts open their own tab, so do not let the hook open another (double tab). gwt-claude=cc-worktree-claude.sh
if "cc-worktree-claude" in low or "cc-cmux-surface-claude" in low:
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

# Extract the CC_WT_PROMPT value from the command (quote-aware); empty if absent
prompt = ""
for tok in toks:
    if tok.startswith("CC_WT_PROMPT="):
        prompt = tok[len("CC_WT_PROMPT="):]
        break
sys.stdout.write(chosen + "\t" + prompt)
PY
)"

# Split path and prompt (python always writes one TAB, so prompt is everything after it, possibly empty)
newpath="${line%%$'\t'*}"
prompt="${line#*$'\t'}"
[ "$prompt" = "$line" ] && prompt=""    # fallback: in case there was no TAB
[ -n "$newpath" ] || exit 0

# Synchronously open surface + start ccteam (+send prompt). Must be synchronous: see the header notes.
CC_CALLER_CWD="$(printf '%s' "$input" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("cwd",""))' 2>/dev/null || true)" \
  "$HOME/.config/cc-stack/cc-cmux-surface-claude.sh" "$newpath" "$prompt" >/dev/null 2>&1

exit 0
