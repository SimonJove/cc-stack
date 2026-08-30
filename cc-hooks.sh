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
#   in the current cmux workspace, start a ccteam claude there and send CC_WT_PROMPT as its first message.
#   It dispatches ONLY when both halves are unambiguous (2026-08-16 tightening):
#     * INTENT — the command carries a non-empty CC_WT_PROMPT. Without one there is no first instruction,
#       so the tab could only sit there doing nothing: bisect helpers, hand-made worktrees and test
#       fixtures each used to earn an idle tab. No prompt = silent skip, no breadcrumb (that is the norm).
#     * TARGET — the new worktree path is parsed out of the command AND confirmed to be a linked worktree
#       of that repo. The old "no match, take the newest mtime" guess is gone: it opened tabs on unrelated
#       worktrees, once starting a second claude inside a directory another sub-task was working in.
#       An unpinnable target = no tab + ONE line in cc-failures.log, because a dispatch that was meant to
#       happen and did not must stay visible (the board surfaces that log).
#   This is the HOOK decision only: `cc-dispatch.sh surface <dir>` with no prompt still opens an idle tab
#   on purpose — gwt-resume reopens crashed sub-tasks through exactly that path.
#   - Only handles a Bash `git worktree add` (adjacent tokens); list/remove/prune do NOT trigger.
#     EnterWorktree (which moves the current claude into the worktree) has no `command` field, so it's naturally
#     excluded — avoids two claudes colliding in the same directory.
#   - Parses the target path + `-C <repo>` from the command (pinpoints the just-created worktree, cross-repo aware);
#     what it cannot pin (e.g. a $VAR shell variable that wasn't expanded) it never guesses at.
#   - Also parses the base (`git worktree add <path> <commit-ish>`) and passes it on as CC_WT_BASE:
#     when it names a branch it becomes the recorded merge target, which is the only thing that
#     still separates the campaign branch from a sibling once a fast-forward makes their tips equal.
#   - Initial-prompt convention: prefix the command with CC_WT_PROMPT='task description', e.g.:
#       CC_WT_PROMPT='refactor auth token refresh' git worktree add .claude/worktrees/oauth -b feat/oauth feat/camp
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

# Cheap prefilter (F8): a real dispatch command is `git worktree add …` (or `git -C <repo>
# worktree add …`), so the payload always carries the LITERAL substring "worktree add" — one
# space, lowercase. A sub-task cwd lives under .claude/worktrees/ (matches "worktree", never
# "worktree add"), and the highest-frequency sub-task commands (git add -A, --amend, address)
# carry "add" without "worktree": the two-word test started python3 on every one of those.
# Cost, spelled out: a multi-space spelling (`git worktree  add`) or an odd casing used to
# parse in python (shlex folds whitespace, the scan lowercases) and is now filtered out here
# — a real but practically unreachable narrowing, and the canonical one-space form is what
# the rules doc spells.
case "$input" in
  *"worktree add"*) : ;;
  *) exit 0 ;;
esac

# cmux available? if we can't reach it (remote/not installed), silently skip
command -v cmux >/dev/null 2>&1 || exit 0
cmux ping >/dev/null 2>&1 || exit 0

# Parse: the just-created worktree absolute path + CC_WT_PROMPT value, TAB-separated.
# CONTRACT: non-empty stdout == dispatch. Every "do not dispatch" case prints nothing; the one case
# that deserves a breadcrumb (target not pinnable) says so on stderr, captured here into $diag —
# a temp file, or /dev/null when none can be made (the breadcrumb is best effort, never noise).
diagf="$(mktemp "${TMPDIR:-/tmp}/cc-hooks-wt.XXXXXX" 2>/dev/null || true)"
[ -n "$diagf" ] && [ -w "$diagf" ] || diagf=/dev/null
line="$(
  CC_HOOK_INPUT="$input" python3 - <<'PY' 2>"$diagf" || true
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

# (1) INTENT. Extract the CC_WT_PROMPT / CC_WT_PERMISSION_MODE values from the command (quote-aware).
# The env-prefix form only sets them inside the Bash tool shell — this hook is a separate process and would
# never see them — so they are read out of the command TEXT, same as everything else here.
# No prompt means no first instruction, which means the tab would only sit there idle: skip, silently.
# (No apostrophes in this heredoc: bash 3.2 mis-parses a single quote inside a heredoc nested in $( ).)
prompt = ""
mode = ""
for tok in toks:
    if tok.startswith("CC_WT_PROMPT="):
        prompt = tok[len("CC_WT_PROMPT="):]
    elif tok.startswith("CC_WT_PERMISSION_MODE="):
        mode = tok[len("CC_WT_PERMISSION_MODE="):].strip()
if not prompt.strip():
    sys.exit(0)

# (2) TARGET, repo half. Cross-repo: take the nearest `-C <dir>` before "worktree" as the repo.
# With no -C the hook cwd IS the repo the command ran in — a fact, not a guess. An explicit -C we cannot
# resolve (an unexpanded $VAR) leaves the repo UNKNOWN: falling back to cwd there would resolve the target
# against a repo the command never named, which is the same class of mistake as the old mtime pick.
cdir = None
for i in range(wi):
    if toks[i] == "-C" and i + 1 < wi:
        cdir = toks[i + 1]
repo = None
if cdir is None:
    repo = cwd
else:
    r = cdir if os.path.isabs(cdir) else os.path.join(cwd, cdir)
    if os.path.isdir(r):
        repo = r

# (2) TARGET, path half: the bare positionals after add (skip value-taking options and command
# separators). `git worktree add <path> [<commit-ish>]`: the FIRST is the worktree path, the
# SECOND (when present) is the base — and an explicitly named base branch is the stated merge
# target of the dispatcher, the one signal that still separates the campaign branch from a sibling
# after a fast-forward makes their tips identical. Passed on as CC_WT_BASE; cc-merge.sh capture
# is what decides whether it names a branch.
opts_with_val = {"-b", "-B", "--reason"}
path_arg = None
base_arg = ""
j = wi + 2
stop = False
while j < len(toks) and not stop:
    t = toks[j]
    # (F1) a separator may be glued ANYWHERE in a token — shlex splits none of "camp;",
    # "camp;echo", "camp&&echo", ">/dev/null;". Cut at the FIRST separator char: the part
    # before it still belongs to this add command and must pass the SAME filters below
    # (a glued ">/dev/null;" is a redirection, never a base); everything after it is a new
    # statement — stop there. An all-separator token ("&&") is a bare break.
    sep = -1
    for k in range(len(t)):
        if t[k] in ";|&":
            sep = k
            break
    head = t if sep < 0 else t[:sep]
    stop = sep >= 0
    if head:
        # (F1) a redirection token is not a positional ("2>/dev/null", "2>&1", ">>log",
        # "&>out"). In the spaced form ("2> file") the NEXT token is the redirect target
        # too — but only when this token is a BARE operator, and never past a separator
        # (a glued target swallows nothing: "2>/dev/null camp" keeps camp as the base).
        if re.match(r"^([0-9]*[<>]|&>)", head):
            if not stop and re.match(r"^([0-9]*>|[0-9]*<|&>|>&|>>|<<|>|<)$", head):
                nxt = toks[j + 1] if j + 1 < len(toks) else ""
                if nxt and not nxt.startswith("-") and not re.match(r"^([0-9]*[<>]|&>|[;|&])", nxt):
                    j += 1
        elif head in opts_with_val:
            if not stop:
                j += 1                    # the option value is not a positional either
        # (F1) merged short opts ending in b/B ("-fb feat/x") take the next token as value
        elif re.match(r"^-[a-zA-Z]*[bB]$", head):
            if not stop:
                j += 1
        elif head.startswith("-"):
            pass                          # any other option: not a positional
        elif path_arg is None:
            path_arg = head
        else:
            base_arg = head
    j += 1
cand = None
if path_arg:
    if os.path.isabs(path_arg):
        cand = os.path.realpath(path_arg)
    elif repo:
        cand = os.path.realpath(os.path.join(repo, path_arg))

# Where to list worktrees from: the repo, plus the target itself when it is an absolute path that exists —
# a linked worktree names its own repo, so an unresolvable -C alone does not cost us that case.
anchors = []
if repo:
    anchors.append(repo)
if cand and os.path.isdir(cand) and cand not in anchors:
    anchors.append(cand)

# (3) VERIFY. The parsed path must BE one of that repo linked worktrees: PostToolUse fires for a FAILED
# `git worktree add` too, so a directory existing on disk proves nothing. No match, no dispatch — there is
# deliberately no "most recent mtime" fallback any more.
chosen = None
for a in anchors:
    try:
        out = subprocess.check_output(
            ["git", "-C", a, "worktree", "list", "--porcelain"],
            text=True, stderr=subprocess.DEVNULL,
        )
    except Exception:
        continue
    listed = [l[len("worktree "):] for l in out.splitlines() if l.startswith("worktree ")]
    for p in listed[1:]:                                   # first entry is the main worktree
        if cand and os.path.isdir(p) and os.path.realpath(p) == cand:
            chosen = p
            break
    if chosen is not None:
        break

if chosen is None:
    # The caller MEANT to dispatch (there is a prompt) and gets nothing: hand the shell the pieces of a
    # cc-failures.log line. Marker + TAB-separated fields, ASCII only — the shell formats and writes it.
    sys.stderr.write("CCWT_UNRESOLVED\t" + (repo or cwd) + "\t" + (path_arg or ""))
    sys.exit(0)

# Only handle "just created" (within 120s), avoids opening on odd cases
if time.time() - os.stat(chosen).st_mtime > 120:
    sys.exit(0)

# mode and base go in the middle: the prompt is free text and may itself contain tabs, so it must
# stay last (both middle fields are single shell tokens and can hold neither a tab nor a newline)
sys.stdout.write(chosen + "\t" + mode + "\t" + base_arg + "\t" + prompt)
PY
)"
diag=""
if [ "$diagf" != /dev/null ]; then
  diag="$(cat "$diagf" 2>/dev/null || true)"
  rm -f "$diagf" 2>/dev/null || true
fi

# Split path / permission-mode / base / prompt (python always writes three TABs; the prompt is
# everything after the third). Fewer TABs = an older emitter: degrade field by field rather than
# absorbing a whole prompt into $mode.
newpath="${line%%$'\t'*}"
rest="${line#*$'\t'}"
[ "$rest" = "$line" ] && rest=""                    # no TAB at all → nothing but the path
mode=""; wtbase=""; prompt=""
if [ "$rest" = "${rest#*$'\t'}" ]; then
  prompt="$rest"                                    # only one TAB → the remainder is the prompt
else
  mode="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  if [ "$rest" = "${rest#*$'\t'}" ]; then
    prompt="$rest"                                  # two TABs (legacy) → no base field
  else
    wtbase="${rest%%$'\t'*}"; prompt="${rest#*$'\t'}"
  fi
fi

# No dispatch. Two reasons, only one of them worth recording:
#   * no CC_WT_PROMPT / not a `worktree add` at all → the normal case, stay completely silent;
#   * the target could not be pinned → the caller wanted a sub-task and got none, so leave the same
#     one-line breadcrumb every other dispatch failure leaves (gwt-status surfaces the last ones).
if [ -z "$newpath" ]; then
  case "$diag" in
    *CCWT_UNRESOLVED*)
      d_rest="${diag#*CCWT_UNRESOLVED$'\t'}"
      d_loc="${d_rest%%$'\t'*}"
      d_arg="${d_rest#*$'\t'}"; [ "$d_arg" = "$d_rest" ] && d_arg=""
      [ -n "$d_arg" ] || d_arg="(none)"
      { echo "[$(date '+%F %T')] $d_loc — worktree path unresolved (add target: $d_arg), no tab opened; dispatch it by hand: gwt-claude <name> \"<prompt>\"" \
          >> "${CC_SEND_FAILLOG:-$HOME/.config/cc-stack/cc-failures.log}"; } 2>/dev/null || true
      ;;
  esac
  exit 0
fi

# Per-dispatch permission mode: CC_WT_PERMISSION_MODE=plan on the command line pins THIS sub-task to
# plan-first (default is auto). cc-dispatch.sh surface whitelists the value.
[ -n "$mode" ] && export CC_WT_PERMISSION_MODE="$mode"

# Synchronously open surface + start ccteam (+send prompt). Must be synchronous: see the header notes.
# (Shared-corpus seeding [CC_WT_SHARE] happens inside cc-dispatch.sh surface — the single point
#  both this hook path and gwt-claude go through.)
CC_CALLER_CWD="$(printf '%s' "$input" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("cwd",""))' 2>/dev/null || true)" \
CC_WT_BASE="$wtbase" \
  "$HOME/.config/cc-stack/cc-dispatch.sh" surface "$newpath" "$prompt" >/dev/null 2>&1

exit 0
;;

# ─────────────────────────────────────────────────────────────────────────────
# status — UserPromptSubmit / Stop / Notification agent-state writer
#   Keeps a per-sub-task agent state (the task row's state columns, read by gwt-status's STATUS column)
#   with ZERO model cooperation and ZERO token cost: Claude Code fires these hooks on their own
#   lifecycle, the hook just records them.
#   - States: UserPromptSubmit → working; Stop → idle; Notification → blocked ONLY when the message
#     text mentions "permission" (other notifications are noise). There is deliberately NO ready
#     state: readiness stays owned by gwt-done + a clean tree (see README), and cc-state task-set-state
#     refuses the value outright — the invariant now lives in the one writer, not in this hook.
#   - All state bookkeeping is cc-state's (the single reader/writer): board membership (a dir with
#     no task row is a silent no-op that writes not one byte), the sidecar rewrite, the locking.
#   - The one cheap gate kept IN FRONT of the facade: the no-board fast path. A missing tasks
#     file would cost two python3 startups through the facade for a guaranteed no-op, on every
#     event of every session on the machine — so the [ -f ] check runs first (F8; §33 pins the
#     zero-python-starts contract, because a comment did not survive the last refactor).
#   - The hook still canonicalizes its cwd with cd + pwd -P before handing it over. Not for
#     matching — cc-state's dir rule takes the raw string OR the canonical form, so a legacy
#     logical-path row (/var vs /private/var, spec §3.5 defect 3) joins either way — but as the
#     enterability gate: cd must SUCCEED, which cc-state's best-effort realpath never demands.
#     Drop the cd and a vanished cwd writes a sidecar row the board can never join (verified
#     2026-08-22: raw-string match fires on a dead dir's row).
#   - HARD RULES: never write to stdout/stderr (UserPromptSubmit stdout gets injected into the
#     model's context — zero token cost means zero output); ALWAYS exit 0 (exit 2 would block the
#     user's prompt); any failure (no python3, malformed JSON, cc-state missing or erroring)
#     degrades to a silent no-op. cmux-independent by design — pure file bookkeeping, no surfaces
#     touched.
status)
shift
input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

# F8: with no state at all there is nothing this hook could ever write — and it fires on every
# prompt of every session on the machine, so check BEFORE the python parse. cc-state would make
# the same call a silent no-op; this gate is what saves its TWO python3 startups on a no-board
# machine (the common case — measured 4.3ms vs 45.1ms per event without the gate, round-2 gate
# 2026-08-22). Payload-independent on purpose: it decides on the store, never on the event.
#
# This is the ONE place outside cc-state that still knows where state lives, and it is a
# deliberate exception, not a missed conversion. Since phase D it needs ONE variable to know
# it: CC_TASKS_FILE and friends are retired, and the legacy TSV is by definition beside the
# library (cc-state's _p) — so this duplicates a derivation rule, not a second knob. a facade call costs a python3 startup (~15 ms
# measured) against a `[ -f ]` at 0.019 ms, on the hottest path in the stack. §39 pins the
# zero-python-starts contract; a comment alone did not survive the last refactor.
#
# BOTH legs are required. Library only, and a machine that still has legacy TSVs never triggers
# the migration that would import them — its state silently stops being recorded. TSVs only, and
# the hook goes dark forever the moment the migration renames them away.
db="${CC_STATE_DB:-$HOME/.config/cc-stack/cc-state.db}"
dbdir="${db%/*}"; [ "$dbdir" = "$db" ] && dbdir="."   # a bare filename has no dirname
[ -f "$db" ] || [ -f "$dbdir/worktree-tasks.tsv" ] || exit 0

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
# nor echo into $canon — and the cd itself is the gate: an un-enterable cwd (dir gone, no access)
# must not earn a state row, while cc-state's canonicalization is best-effort and never fails.
[ -n "$cwd" ] || exit 0
canon="$(CDPATH= cd -- "$cwd" 2>/dev/null && pwd -P)" || exit 0

# ONE facade call: membership + rewrite + lock are all cc-state's. The redirects and `|| true`
# are the hook contract, not decoration: task-set-state exits 2 with stderr for a refused state
# (e.g. `ready`), and cc-state's own startup can fail loudly (no python3) — every byte of that
# must stay invisible and the hook must still exit 0.
CC_SELF="$( (CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) 2>/dev/null )"
[ -n "$CC_SELF" ] || CC_SELF="$HOME/.config/cc-stack"
"$CC_SELF/cc-state" task-set-state "$canon" "$state" >/dev/null 2>&1 || true

exit 0
;;

*)
  echo "usage: cc-hooks.sh worktree|status   (Claude Code hook JSON on stdin)" >&2; exit 2 ;;
esac
