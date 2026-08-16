#!/usr/bin/env bash
# cc-dispatch.sh · THE dispatch pipeline — one script, five subcommands.
#   wt-claude <name> <prompt> [--prefix <p>] [--base <b>]   gwt-claude implementation: build/reuse
#                                                             the worktree, then delegate to surface
#                                                             [absorbs cc-worktree-claude.sh]
#   surface   <path> [prompt]                                open tab + copy .env + trust + launch +
#                                                             register — the single source of truth
#                                                             [absorbs cc-cmux-surface-claude.sh]
#   workspace <path> [name] [focus]                          open a cmux workspace (empty shell) for a dir
#                                                             [absorbs cc-cmux-workspace.sh]
#   send      <surface-ref> "<text>"                         cc-send: the collision-safe text+Enter
#                                                             primitive — the ONLY sanctioned injection
#                                                             exit into a running claude tab (both ways)
#   calibrate <surface-ref> [label]                           re-probe the cc-send input-line patterns
#                                                             on a tab whose input box is known empty
set -u

# ─────────────────────────────────────────────────────────────────────────────
# cc-send — the collision-safe send primitive (roadmap 2b, design finalized 2026-08-15).
# `cc-dispatch.sh send <surface-ref> "<text>"` replaces every raw `cmux send` + `send-key Enter`
# pair that injects text into a RUNNING claude tab, both directions (child reports to parent,
# parent instructs child). A raw send races whatever a human is half-typing into that tab's
# composer; this gate removes the race (zero token cost — nothing here passes through a model):
#   working indicator on screen         → busy fast-path: send NOW, no wait — cmux QUEUES sends
#                                         to a working pane and they are consumed (Defect 2 table
#                                         in docs/issues/cc-stack-issues.md); the input line
#                                         legitimately holds QUEUED text in that state, so holding
#                                         for it is pointless (patterns: CC_SEND_BUSY_PATTERNS)
#   input line empty                    → send text + Enter immediately (preempt; nobody typing),
#                                         then POST-SEND VERIFY: re-read the line ~1s later;
#                                         non-empty = the Enter was swallowed and the text PARKED
#                                         → ONE Enter retry, still parked → loud failure — never
#                                         silently pretend success
#   input line has text                 → a human is composing → sleep 0.5, retry (their submit
#                                         empties the line; the next round preempts)
#   timeout (CC_SEND_TIMEOUT, def 60s)  → cmux notify (held duration + a blocked-by preview of
#                                         the blocking line: CC_SEND_PREVIEW_CHARS, def 40, 0=off),
#                                         then RE-NOTIFY every CC_SEND_HEARTBEAT_SEC (def 300,
#                                         0=one-shot); KEEP waiting — never drop, never collide
#   read-screen failure OR unrecognized → fail-open to raw send NOW; NEVER interpret ambiguity
#                                         as "someone is typing" and hold the message forever
#
# Input-line patterns (hardening layer 1+2): a LIST, not one regex, matched bottom-up — the
# input box is the LAST matching line on screen (transcript echoes never render the prompt at
# line start; probed). CC_SEND_INPUT_PATTERNS (colon-separated ERE list) REPLACES the defaults;
# every entry is auto-anchored to line start. Live probe 2026-08-15, claude 2.1.233, BOTH
# renderers (`tui: fullscreen` via live settings, `tui: default` via --settings override) draw
# the input line IDENTICALLY: "❯ " between ── rules when empty, "❯ <draft>" while composing.
# `^❯` is the observed form for both; `^>` is a defensive glyph-variant entry for drift.
# Breadcrumbs go to cc-failures.log (CC_SEND_FAILLOG overrides; the board surfaces the last
# 24h): fail-open and calibration misses append a line, so renderer drift is visible the same
# day. CC_SEND_QUIET=1 suppresses the fail-open breadcrumb for call sites that knowingly target
# a plain shell (nothing to recognize there — e.g. the launch command right after the RDY probe).
CCSEND_PATTERNS_DEFAULT='^❯:^>'
CCSEND_LINES=40        # read-screen window: wide enough that a wrapped draft's prompt line stays in it

# Busy fast-path patterns (hardening layer 5): when the target claude is WORKING, the input box
# legitimately holds QUEUED text and cmux consumes queued sends — so BEFORE the empty/busy verdict
# the capture is scanned for a working-indicator line; a hit sends immediately (no wait, no notify,
# no post-send verify: queued text remaining in the box is a legal end state). Detection is
# ADDITIVE: no match → the empty/busy gate behaves exactly as before. Live probe 2026-08-15
# (claude 2.1.233, own tab mid-turn, 16-frame sample): the working line renders at column 0 as
# "<spinner> <gerund>… (<duration> · <stats>)", e.g. "✻ Befuddling… (10m 12s · ↓ 34.0k tokens)";
# the spinner rotates through exactly 6 frames — · ✢ ✳ ✶ ✻ ✽ (glyph, space, duration-FIRST
# parens; no "esc to interrupt" variant in this build). CC_SEND_BUSY_PATTERNS (colon-separated
# ERE list) REPLACES the defaults; entries auto-anchor to line start, empty entries are skipped
# (an empty ERE matches EVERY line and would fast-path every send). The alternation is LITERAL
# multibyte strings on purpose — never fold these glyphs into a bracket class: BSD awk treats
# [✻✽] as a BYTE set under LC_ALL=C (❯ shares the lead byte e2 there, so the empty input line
# would read busy; UTF-8 locales happen to be safe, C is not — never rely on the locale).
# And never write a backslash escape into an entry: awk -v PROCESSES escapes, so "\(" arrives
# as a bare "(" — an unbalanced group makes awk fail LOUDLY (rc 2, error + non-match), a safe
# miss but not a silent one; a literal paren is [(].
CCSEND_BUSY_PATTERNS_DEFAULT='^(·|✢|✳|✶|✻|✽) .*[(][0-9]+[smh]'

_ccsend_eval() {       # stdin: screen text → prints "empty<TAB>line" | "busy<TAB>line" | "unknown"
                       # (the state evaluator; the line text after the tab feeds the blocked-by
                       # preview of the hold notify — read-only reuse of the same capture, the
                       # delivered text never passes through here. "unknown" deliberately carries
                       # NO tab so exact string compares against it keep working, _ccsend_calibrate)
  awk -v pl="${CC_SEND_INPUT_PATTERNS:-$CCSEND_PATTERNS_DEFAULT}" '
    BEGIN {
      n = split(pl, P, ":")
      nbsp = sprintf("%c", 194) sprintf("%c", 160)   # U+00A0 no-break space, UTF-8 byte pair — the
                                                     # claude TUI renders the empty input line as
                                                     # prompt + NBSP cursor placeholder (probed), so
                                                     # it must count as blank
    }
    { L[NR] = $0 }
    END {
      for (i = NR; i >= 1; i--) {            # bottom-up: the input box is the LAST matching line
        for (j = 1; j <= n; j++) {           # (the transcript also echoes submitted messages with
          p = P[j]; sub(/^\^/, "", p)        # a prompt prefix — always ABOVE the live input box)
          if (p == "") continue              # empty list entry (trailing/double colon in the env
                                             # var): match() with an empty pattern hits ANY line
                                             # with RLENGTH=0 → rest = the whole line → an EMPTY
                                             # input line would read as BUSY and hold forever
          if (match(L[i], "^" p)) {
            rest = substr(L[i], RSTART + RLENGTH)
            gsub(nbsp, " ", rest)
            sub(/[ \t\r]+$/, "", rest)       # read-screen padding; a boxed variant is a pattern-
                                             # list concern, not a tail-stripping concern
            sub(/^[ \t]+/, "", rest)         # NBSP cursor placeholder → space; trimmed so the
                                             # preview shows the draft, not a leading blank
                                             # (all-whitespace still reads empty below)
            print ((rest ~ /^[ \t\r]*$/) ? "empty" : "busy") "\t" rest
            exit
          }
        }
      }
      print "unknown"
    }'
}

_ccsend_busyhit() {    # stdin: screen capture → rc 0 when a working-indicator line is present
                       # (the busy fast-path scan; probed shapes + env override: see
                       # CCSEND_BUSY_PATTERNS_DEFAULT above)
  awk -v pl="${CC_SEND_BUSY_PATTERNS:-$CCSEND_BUSY_PATTERNS_DEFAULT}" '
    BEGIN { n = split(pl, P, ":") }
    { for (j = 1; j <= n; j++) {
        p = P[j]; sub(/^\^/, "", p)
        if (p == "") continue                # same empty-entry guard as _ccsend_eval — an empty
                                             # ERE would match EVERY line and fast-path every send
        if (match($0, "^" p)) { found = 1; exit }
      } }
    END { exit (found ? 0 : 1) }'            # found flag, not exit-in-body: an END exit OVERRIDES
                                             # the status an earlier exit already set
}

_ccsend_crumb() {      # $1 = locator, $2 = message → cc-failures.log (same format as _fail below)
  echo "[$(date '+%F %T')] $1 — $2" >> "${CC_SEND_FAILLOG:-$HOME/.config/cc-stack/cc-failures.log}" 2>/dev/null || true
}

_ccsend_raw() {        # $1 = ref, $2 = text — the raw exit point. The Enter is load-bearing beyond
                       # submission: it also flushes cmux's idle-pane parking (docs/known-issues.md,
                       # "cmux send to an idle pane parks the message").
  cmux send --surface "$1" "$2" || { echo "✗ cc-send: cmux send failed for $1" >&2; return 1; }
  cmux send-key --surface "$1" Enter >/dev/null 2>&1 || true
}

_ccsend_verify() {     # $1 = ref — post-send verification, EMPTY-path deliveries only (the busy
                       # fast-path skips it: queued text legitimately remains in the box). Re-read
                       # the input line ~1s after the send: non-empty means the Enter was swallowed
                       # and the text PARKED in the composer (the [Pasted text #N] incident class —
                       # docs/known-issues.md, "成对不等于必达"). Exactly ONE Enter retry, re-read;
                       # still non-empty → LOUD failure (stderr + breadcrumb + rc 1) — never
                       # silently pretend success. Non-emptiness is the signal: pasted chips fold
                       # the sent text, so matching it against the line is useless. A NEW
                       # placeholder/suggestion rendering can read non-empty on a DELIVERED
                       # message — one retry then error is the accepted worst case (no Enter
                       # storm, never loop). unknown (read-screen hiccup) = inconclusive → pass:
                       # the raw send DID return OK, and a cmux hiccup must not fail an honest
                       # delivery. CC_SEND_VERIFY_SEC (default 1) spaces the re-reads (tests
                       # shrink it).
  local ref verdict w
  ref="$1"
  w="${CC_SEND_VERIFY_SEC:-1}"; case "$w" in ''|*[!0-9.]*|.*|*.|*.*.*) w=1 ;; esac
  sleep "$w"
  verdict="$(cmux read-screen --surface "$ref" --lines "$CCSEND_LINES" 2>/dev/null | _ccsend_eval)"
  case "${verdict%%$'\t'*}" in
    busy) cmux send-key --surface "$ref" Enter >/dev/null 2>&1 || true   # the ONE retry
          sleep "$w"
          verdict="$(cmux read-screen --surface "$ref" --lines "$CCSEND_LINES" 2>/dev/null | _ccsend_eval)"
          case "${verdict%%$'\t'*}" in
            busy) echo "✗ cc-send: sent to $ref but the input line still holds text after one Enter retry — the message may be parked in the composer; finish it by hand (see docs/known-issues.md)" >&2
                  _ccsend_crumb "$ref" "cc-send parked after send: input line still non-empty after one Enter retry (Enter swallowed twice?) — see docs/known-issues.md"
                  return 1 ;;
          esac ;;
  esac
  return 0
}

_ccsend() {            # $1 = surface ref, $2 = text — the gate loop
  local ref text to hb pv start now next_at scr verdict line dur prev
  command -v cmux >/dev/null 2>&1 || { echo "✗ cc-send: cmux not found" >&2; return 1; }
  ref="$1"; text="$2"
  to="${CC_SEND_TIMEOUT:-60}";        case "$to" in ''|*[!0-9]*) to=60 ;; esac
  hb="${CC_SEND_HEARTBEAT_SEC:-300}"; case "$hb" in ''|*[!0-9]*) hb=300 ;; esac   # 0 = one-shot notify
  pv="${CC_SEND_PREVIEW_CHARS:-40}";  case "$pv" in ''|*[!0-9]*) pv=40 ;; esac    # 0 = no preview
  start=$(date +%s); next_at=$((start + to)); line=""
  while :; do
    scr="$(cmux read-screen --surface "$ref" --lines "$CCSEND_LINES" 2>/dev/null)"
    if [ -n "$scr" ] && printf '%s\n' "$scr" | _ccsend_busyhit; then
      # busy fast-path: target is WORKING — cmux queues the send and it is consumed. No wait (the
      # line may hold queued text forever), no notify, and no post-send verify (non-empty after
      # the send is the LEGAL end state here, a re-read would false-alarm).
      _ccsend_raw "$ref" "$text" && echo "✔ cc-send: delivered to $ref (queued — target working)"
      return $?
    fi
    verdict="$(printf '%s\n' "$scr" | _ccsend_eval)"
    case "${verdict%%$'\t'*}" in
      empty) break ;;
      busy)  line="${verdict#*$'\t'}" ;;     # latest blocking line → the notify blocked-by preview
      *)     # read-screen failure OR unrecognized layout → fail-open NOW (worst case = status quo)
             [ "${CC_SEND_QUIET:-0}" = "1" ] || \
               _ccsend_crumb "$ref" "cc-send fail-open: input line unrecognized (raw send, no collision guard) — renderer drift? see docs/known-issues.md"
             _ccsend_raw "$ref" "$text"; return $? ;;
    esac
    now=$(date +%s)
    if [ "$now" -ge "$next_at" ]; then       # first notify at CC_SEND_TIMEOUT, then every heartbeat
      dur=$((now - start)); prev=""
      [ "$pv" -gt 0 ] && [ -n "$line" ] && prev="; blocked by: \"${line:0:$pv}\""
      cmux notify --title "cc-send: message held — input box busy" \
        --body "surface $ref: the input line has held the message for ${dur}s; it sends the moment the line clears (never dropped)$prev" \
        >/dev/null 2>&1 || true
      if [ "$hb" -gt 0 ]; then next_at=$((now + hb)); else next_at=9999999999; fi
    fi
    sleep 0.5
  done
  _ccsend_raw "$ref" "$text" || return 1
  _ccsend_verify "$ref" || return 1
  echo "✔ cc-send: delivered to $ref"
}

_ccsend_calibrate() {  # $1 = ref, $2 = dir — self-calibration (hardening layer 4), called right
                       # after a new tab's TUI is up and its input box is KNOWN empty. A pattern
                       # miss breadcrumbs so renderer drift is visible the same day (gwt-status
                       # surfaces cc-failures.log). A failed read-screen (cmux hiccup) is NOT
                       # drift → skip silently. rc 1 = miss.
  local scr
  scr="$(cmux read-screen --surface "$1" --lines "$CCSEND_LINES" 2>/dev/null)" || return 0
  [ -n "$scr" ] || return 0
  if [ "$(printf '%s\n' "$scr" | _ccsend_eval)" = "unknown" ]; then
    _ccsend_crumb "$2" "cc-send calibration: no input-line pattern matched on $1 (renderer drift? update CC_SEND_INPUT_PATTERNS — see docs/known-issues.md)"
    return 1
  fi
  return 0
}

case "${1:-}" in

# ─────────────────────────────────────────────────────────────────────────────
# wt-claude — gwt-claude: spin a task off the main task into an independent sub-task.
#   This subcommand only handles "build/reuse the worktree + ensure .gitignore", then DELEGATES the
#   whole "open tab + copy .env + start ccteam (plan) + pre-trust + send prompt + register" part to
#   surface (single source of truth, avoids two copies of the logic drifting).
# Usage: cc-dispatch.sh wt-claude <name> <initial-prompt> [--prefix <p>] [--base <b>]
#        (legacy positional form still accepted: <name> <initial-prompt> [branch-prefix=feat] [base=HEAD])
wt-claude)
shift
name="${1:-}"; prompt="${2:-}"
[ -n "$name" ] && [ -n "$prompt" ] || {
  echo "usage: cc-dispatch.sh wt-claude <name> <initial-prompt> [--prefix <p>] [--base <b>]" >&2; exit 2; }
shift 2

# Flag form (what the worktree-subtask skill documents) or legacy positionals — both work.
prefix="feat"; base="HEAD"; posi=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base)   [ -n "${2:-}" ] || { echo "✗ --base needs a value" >&2; exit 2; }; base="$2"; shift 2 ;;
    --prefix) [ -n "${2:-}" ] || { echo "✗ --prefix needs a value" >&2; exit 2; }; prefix="$2"; shift 2 ;;
    *)
      posi=$((posi+1))
      case $posi in 1) prefix="$1" ;; 2) base="$1" ;; *) echo "✗ unexpected argument: $1" >&2; exit 2 ;; esac
      shift ;;
  esac
done

# Must be inside cmux (this whole thing is designed around cmux tabs)
command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 || {
  echo "✗ can't reach cmux, aborting (this command needs cmux)" >&2; exit 1; }

# ── Resolve main repo root + worktree dir (works from the main repo or from any worktree) ──
g="$(git rev-parse --git-common-dir 2>/dev/null)" || { echo "✗ not inside a git repo" >&2; exit 1; }
g="$(cd "$g" && pwd -P)"; root="$(dirname "$g")"
if [ -d "$root/.claude" ]; then rel=".claude/worktrees"; else rel=".worktrees"; fi
wtbase="$root/$rel"; mkdir -p "$wtbase"
gi="$root/.gitignore"
grep -qxF "/$rel/" "$gi" 2>/dev/null || { printf '/%s/\n' "$rel" >> "$gi"; echo "  ↳ .gitignore now ignores /$rel/"; }
wtpath="$wtbase/$name"; branch="$prefix/$name"

# ── Build/reuse the worktree ──
if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$root" worktree add "$wtpath" "$branch" || exit 1
else
  git -C "$root" worktree add "$wtpath" -b "$branch" "$base" || exit 1
fi
echo "✔ worktree : $wtpath"
echo "✔ branch   : $branch"
"$HOME/.config/cc-stack/cc-merge.sh" capture "$root" "$branch" "$PWD" >/dev/null 2>&1

# ── Delegate: open tab + copy .env + start ccteam (plan) + pre-trust + send prompt + register ──
exec "$HOME/.config/cc-stack/cc-dispatch.sh" surface "$wtpath" "$prompt"
;;

# ─────────────────────────────────────────────────────────────────────────────
# surface — open a new surface (tab) in the CURRENT cmux workspace for an existing directory and
#   start a ccteam claude, optionally with an initial prompt. Opens in background, doesn't steal
#   focus. Not in cmux (remote/not installed) = safe no-op.
# Called automatically by cc-hooks.sh worktree, and reused by wt-claude above (gwt-claude).
# Usage: cc-dispatch.sh surface <path> [prompt]
# Related env: CC_WT_PERMISSION_MODE (default auto; set plan for a plan-first sub-task),
#   CC_WT_PRETRUST (default 1), CC_WT_COPY (files to copy into the worktree)
surface)
shift
path="${1:-}"; prompt="${2:-}"
[ -n "$path" ] || { echo "usage: cc-dispatch.sh surface <path> [prompt]" >&2; exit 2; }
[ -d "$path" ] || { echo "directory does not exist: $path" >&2; exit 2; }
abspath="$(cd "$path" 2>/dev/null && pwd -P)" || exit 2

# Failure breadcrumb: log + best-effort cmux desktop notification, so "built a worktree but no tab" is discoverable (gwt-status surfaces it)
_fail() {
  echo "[$(date '+%F %T')] $abspath — $1" >> "$HOME/.config/cc-stack/cc-failures.log" 2>/dev/null || true
  command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 \
    && cmux notify --title "cc-stack: worktree tab failed" --body "$abspath — $1" >/dev/null 2>&1 || true
}

# Must be able to reach cmux; short retry to ride out cmux's transient hiccups/restart window (don't rely on CMUX_SOCKET — often empty in CC's Bash env)
command -v cmux >/dev/null 2>&1 || exit 0
ok=""; for _ in 1 2 3 4 5 6; do cmux ping >/dev/null 2>&1 && { ok=1; break; }; sleep 0.4; done
[ -n "$ok" ] || { _fail "cmux ping unreachable (likely restarting), no tab opened"; exit 0; }

# Dedup (best effort): if a tab was opened for this dir within 120s, don't repeat. Only CHECK here; write the marker after success (failures leave no blocking marker)
marker_dir="${TMPDIR:-/tmp}/cc-cmux-tabs"
mkdir -p "$marker_dir" 2>/dev/null || true
marker="$marker_dir/$(printf '%s' "$abspath" | shasum -a 1 2>/dev/null | cut -d' ' -f1)"
if [ -n "$marker" ] && [ -e "$marker" ]; then
  now=$(date +%s 2>/dev/null || echo 0); mt=$(stat -f %m "$marker" 2>/dev/null || echo 0)
  [ $((now - mt)) -lt 120 ] && exit 0
fi

# Copy gitignored-but-needed files (.env etc.) so hook-path sub-tasks also get their environment (matches gwt-new/gwt-claude)
root="$(git -C "$abspath" rev-parse --git-common-dir 2>/dev/null)" && root="$(cd "$root/.." 2>/dev/null && pwd -P)" || root=""
if [ -n "$root" ] && [ "$root" != "$abspath" ]; then
  for f in ${CC_WT_COPY:-.env .env.local .claude/settings.local.json}; do
    [ -f "$root/$f" ] || continue
    [ -e "$abspath/$f" ] && continue                 # don't overwrite if it already exists
    mkdir -p "$abspath/$(dirname "$f")" 2>/dev/null
    cp -p "$root/$f" "$abspath/$f" 2>/dev/null
  done
  # Seed the shared test corpus (CC_WT_SHARE; default + docs live in cc-worktree-shared.sh;
  # exported-empty disables). Idempotent — never overwrites files already in the worktree.
  "$HOME/.config/cc-stack/cc-worktree-shared.sh" seed "$root" "$abspath" 2>/dev/null
fi

# Record the merge target (parent = caller's branch) — HOOK PATH ONLY.
# On the gwt-claude path CC_CALLER_CWD is unset and wt-claude above already
# captured with the real caller cwd; skipping here avoids overwriting it.
if [ -n "${CC_CALLER_CWD:-}" ] && command -v git >/dev/null 2>&1; then
  _root="$(git -C "$abspath" rev-parse --git-common-dir 2>/dev/null)" && _root="$(cd "$_root/.." && pwd -P)"
  _br="$(git -C "$abspath" symbolic-ref --short HEAD 2>/dev/null)"
  [ -n "$_root" ] && [ -n "$_br" ] && \
    "$HOME/.config/cc-stack/cc-merge.sh" capture "$_root" "$_br" "$CC_CALLER_CWD" >/dev/null 2>&1
fi

# Pre-authorize trust for this worktree, skipping claude's "Do you trust this folder?" prompt (more robust than screen-scraping; CC_WT_PRETRUST=0 disables)
[ "${CC_WT_PRETRUST:-1}" != "0" ] && "$HOME/.config/cc-stack/cc-trust.sh" "$abspath" >/dev/null 2>&1

# Caller (main task) surface / workspace — backchannel + target workspace
ident="$(cmux identify 2>/dev/null)"
caller_surface="$(printf '%s' "$ident" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("caller") or {}).get("surface_ref",""))' 2>/dev/null)"
caller_ws="$(printf '%s' "$ident" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("caller") or {}).get("workspace_ref",""))' 2>/dev/null)"

# Open the new surface (tab): in the caller's workspace, background, no focus steal. Short retry to ride out hiccups.
ref=""
for _ in 1 2 3 4 5; do
  if [ -n "$caller_ws" ]; then
    ref="$(cmux new-surface --type terminal --working-directory "$abspath" --focus false --workspace "$caller_ws" 2>/dev/null | grep -oE 'surface:[0-9]+' | head -1)"
  else
    ref="$(cmux new-surface --type terminal --working-directory "$abspath" --focus false 2>/dev/null | grep -oE 'surface:[0-9]+' | head -1)"
  fi
  [ -n "$ref" ] && break
  sleep 0.4
done
[ -n "$ref" ] || { _fail "cmux new-surface failed to open a tab"; exit 1; }

# Opened successfully; write the dedup marker now
[ -n "$marker" ] && : > "$marker" 2>/dev/null || true

# Wait for the shell to be ready (only counts once the marker command's OUTPUT appears, avoiding the shell-init race)
# RDY stays a RAW send by decision (2026-08-15): the target is the fresh SHELL, not a claude TUI —
# no pattern can recognize a shell prompt, so cc-send would fail-open on every dispatch (one wasted
# read-screen + a misleading "renderer drift" breadcrumb). The tab is milliseconds old and
# unfocused; there is no human typing to collide with.
ready=""
cmux send     --surface "$ref" 'echo RDY$((20+2))' >/dev/null 2>&1
cmux send-key --surface "$ref" Enter               >/dev/null 2>&1
for _ in $(seq 1 40); do
  if cmux read-screen --surface "$ref" --lines 20 2>/dev/null | grep -q 'RDY22'; then ready=1; break; fi
  sleep 0.25
done
[ -n "$ready" ] || echo "⚠ shell-ready probe timed out, sending anyway (may need one manual Enter)" >&2

# Permission mode for the sub-task claude. Default `auto` — it investigates and then implements without an
# approval round-trip, the same mode the main session runs in; `plan` was the old default and cost a human
# round-trip on every single dispatch.
# Per-dispatch override: CC_WT_PERMISSION_MODE=plan (env on the gwt-claude call, or as a prefix token on the
# `git worktree add` command line — cc-hooks.sh worktree parses it out of the command text and passes it through here).
# Whitelisted because the value is interpolated into the launch command below; anything else falls back to auto.
pm="${CC_WT_PERMISSION_MODE:-auto}"
case "$pm" in
  plan|auto|acceptEdits|bypassPermissions|manual|dontAsk) : ;;
  *) pm="auto" ;;
esac

# Assemble the final prompt: user prompt (multi-line preserved) + working agreement + backchannel note.
# Clause (1) MUST track $pm — telling an auto-mode sub-task it is "in plan mode" makes it plan anyway.
if [ "$pm" = "plan" ]; then
  way1="(1) You are in plan mode: present a plan first and wait for human approval before changing code; don't start editing right away."
else
  way1="(1) You are NOT in plan mode — no plan-approval round-trip. Investigate first (read the code and the relevant docs until the logic is actually clear), then implement without waiting for me; do not start typing code off a guess. Do still stop and ask before a structural or destructive decision (schema/migration, cross-module refactor, deleting or rewriting existing behaviour, anything outside this brief)."
fi
full="$prompt"
if [ -n "$prompt" ]; then
  full="$full
——[Working agreement] $way1 (2) Follow this project's own CLAUDE.md and .claude config (harness) throughout; don't drift toward your own defaults. (3) After making changes, commit / rebase / merge / push / removing the worktree or branch ALL require human authorization — even if the finishing-a-development-branch skill prompts you, just stop at 'keep the branch'. (4) When you finish implementing and have reported back, run \`gwt-done\` to mark this branch ready; your merge target is already recorded, so you never choose where to merge, and you never merge without my authorization."
  [ -n "$caller_surface" ] && full="$full (5) To report back / ask the main task: ~/.config/cc-stack/cc-dispatch.sh send $caller_surface \"message\" — cc-send waits out any half-typed line instead of colliding; never use raw cmux send + Enter."
fi

# Start the sub-task claude. Key point: don't type the prompt straight into the terminal (a very long line gets shredded,
# and newlines are treated as Enter). Instead write it to a temp file and type a short command "$(cat file)" — the shell reads
# the file and passes the whole content (newlines and all) to claude as a single argument.
# --permission-mode $pm: resolved above (default auto, CC_WT_PERMISSION_MODE=plan for the plan-first gate).
# Provider for NEW sub-tasks: `gwt-provider` writes a provider name to $CC_LAUNCH_FILE (default anthropic).
# anthropic/default → cmux claude-teams on the official/current-env provider; any other name → `cld <name>`,
# which sources ~/.config/claude/llm-provider/<name>.sh in the new tab (provider env is process-local, so
# existing sub-tasks keep their launch-time provider). Unknown/empty → safe default, never breaks the launch.
_provider="$(cat "${CC_LAUNCH_FILE:-$HOME/.config/cc-stack/launch}" 2>/dev/null)"
case "$_provider" in
  ""|anthropic|default) launch="ccteam" ;;
  */*|*..*)             launch="ccteam" ;;     # path-traversal guard → safe default
  *)                    launch="cld $_provider" ;;
esac
pf=""
if [ -n "$full" ]; then
  pf="${TMPDIR:-/tmp}/cc-wt-prompt.$$.txt"
  printf '%s' "$full" > "$pf"
  # Routed through cc-send (the single injection exit point). The tab is still a SHELL here — no
  # claude input box yet — so CC_SEND_QUIET suppresses the fail-open breadcrumb that an
  # unrecognized shell prompt would otherwise write on every dispatch.
  ( export CC_SEND_QUIET=1; _ccsend "$ref" "$launch --permission-mode $pm \"\$(cat '$pf')\"" ) >/dev/null 2>&1 || true
else
  ( export CC_SEND_QUIET=1; _ccsend "$ref" "$launch --permission-mode $pm" ) >/dev/null 2>&1 || true
fi

# Fallback: in case pre-trust didn't take effect (concurrency / schema change), still screen-scrape to confirm "trust this folder".
# Early exit when the claude TUI is already up (its footer hint is visible) — pre-trust worked, no dialog is coming.
# Without that second exit the loop idles its full 24×0.25s on EVERY dispatch (hook path is synchronous = main-session latency).
# tui=1 records that the TUI was SEEN up (feeds the cc-send calibration below). After answering
# the trust dialog we no longer break blind: sleep and let the loop confirm the TUI, so the
# calibration never reads a pre-TUI screen and cries "renderer drift".
tui=""
for _ in $(seq 1 24); do
  scr="$(cmux read-screen --surface "$ref" --lines 30 2>/dev/null | tr 'A-Z' 'a-z')"
  case "$scr" in
    *trust*folder*|*trust*file*|*trust*director*|*"do you trust"*)
      cmux send-key --surface "$ref" Enter >/dev/null 2>&1   # keystroke-answering a dialog, NOT text
                                                             # injection — deliberately stays a raw send-key
      sleep 1 ;;                                            # dialog leaves; the loop then sees the TUI
    *"esc to interrupt"*|*"? for shortcuts"*|*"ctrl+c to exit"*|*"-- insert --"*)
      tui=1; break ;;                                       # claude TUI is up → no trust dialog coming
  esac
  sleep 0.25
done

# ── cc-send self-calibration (roadmap 2b, hardening layer 4) ──
# The TUI is up and its input box is KNOWN empty right now: verify a pattern hits it. A miss
# breadcrumbs to cc-failures.log (the board surfaces it) — renderer drift becomes visible the
# same day instead of silently degrading every future send to fail-open.
[ -n "$tui" ] && _ccsend_calibrate "$ref" "$abspath" || true

# claude is up and the prompt is already read into argv by the shell — the temp file can go
[ -n "$pf" ] && rm -f "$pf" 2>/dev/null

# ── Register into the task list (so gwt-status can show "which worktree is doing what") ──
# 5th arg = parent branch (the caller's branch at dispatch — CC_CALLER_CWD on the hook path,
# PWD on the gwt-claude path; empty when detached / not a repo): feeds the board's PARENT
# column and outlives the branch.<b>.ccMergeInto git config.
"$HOME/.config/cc-stack/cc-board.sh" log "$abspath" "$ref" "${caller_surface:-}" "$prompt" \
  "$(git -C "${CC_CALLER_CWD:-$PWD}" symbolic-ref --short HEAD 2>/dev/null)"

echo "✔ new tab : $ref  cwd=$abspath  $([ -n "$prompt" ] && echo '(initial prompt sent)' || echo '(idle ccteam)')"
[ -n "$caller_surface" ] && echo "✔ backchannel: the new claude can report back via cc-dispatch.sh send $caller_surface \"<message>\""
exit 0
;;

# ─────────────────────────────────────────────────────────────────────────────
# send — cc-send, the collision-safe send primitive (roadmap 2b). The ONLY sanctioned way to
#   inject text + Enter into a RUNNING claude tab, both directions (child reports to parent,
#   parent instructs child). Reads the target's input line via read-screen, waits out any
#   half-typed draft instead of colliding with it (re-notifying on a heartbeat while held),
#   sends IMMEDIATELY past a working-indicator line (busy fast-path — cmux queues it), verifies
#   the line cleared after an empty-line delivery (one Enter retry, then a loud failure), and
#   fail-opens to raw send when the layout is unrecognized.
#   Gate semantics + pattern lists: see the cc-send block at the top of this file.
# Usage: cc-dispatch.sh send <surface-ref> "<text>"
# Related env: CC_SEND_TIMEOUT (first-notify threshold, default 60s), CC_SEND_HEARTBEAT_SEC
#   (re-notify interval while holding, default 300s, 0 = one-shot), CC_SEND_PREVIEW_CHARS
#   (blocked-by preview length in the notify body, default 40, 0 = off), CC_SEND_INPUT_PATTERNS
#   (colon-separated ERE list, replaces the defaults), CC_SEND_BUSY_PATTERNS (same, for the
#   working-indicator fast-path), CC_SEND_VERIFY_SEC (post-send verify delays, default 1s),
#   CC_SEND_FAILLOG (breadcrumb path), CC_SEND_QUIET=1 (suppress the fail-open breadcrumb —
#   for shell-targeting call sites only)
send)
shift
ref="${1:-}"; text="${2:-}"
[ -n "$ref" ] && [ -n "$text" ] || { echo 'usage: cc-dispatch.sh send <surface-ref> "<text>"' >&2; exit 2; }
_ccsend "$ref" "$text"
exit $?
;;

# ─────────────────────────────────────────────────────────────────────────────
# calibrate — re-run the cc-send self-calibration against any tab whose input box is known
#   empty (an idle claude nobody is typing into). This is the step-3 probe documented in
#   docs/known-issues.md "cc-send 门卫失效": after a TUI upgrade, run this to see whether the
#   current pattern list still hits the live input-line form. rc 1 + breadcrumb on a miss.
# Usage: cc-dispatch.sh calibrate <surface-ref> [label]
calibrate)
shift
ref="${1:-}"; where="${2:-$ref}"
[ -n "$ref" ] || { echo "usage: cc-dispatch.sh calibrate <surface-ref> [label]" >&2; exit 2; }
if _ccsend_calibrate "$ref" "$where"; then
  echo "✔ cc-send calibration: input-line pattern matched on $ref"
else
  echo "✗ cc-send calibration: pattern MISS on $ref (breadcrumb written) — see docs/known-issues.md" >&2
  exit 1
fi
;;

# ─────────────────────────────────────────────────────────────────────────────
# workspace — open a cmux workspace (empty shell) for a directory.
#   - Safe no-op when not inside cmux (no CMUX_SOCKET), so remote/bare-terminal callers have no side effects.
#   - Best-effort dedup: if a workspace already points at the same directory, don't open another.
# Usage: cc-dispatch.sh workspace <path> [name] [focus=false]
workspace)
shift
# Can we talk to cmux? (don't rely on CMUX_SOCKET — it's often empty in CC's Bash env; the cmux CLI uses its default socket)
command -v cmux >/dev/null 2>&1 || exit 0      # cmux not installed (remote): silently skip
cmux ping >/dev/null 2>&1 || exit 0            # can't reach cmux: silently skip

path="${1:-}"
[ -n "$path" ] || { echo "cc-dispatch.sh workspace: need <path>" >&2; exit 2; }
[ -d "$path" ] || { echo "cc-dispatch.sh workspace: directory does not exist: $path" >&2; exit 2; }

abspath="$(cd "$path" 2>/dev/null && pwd -P)" || exit 2
name="${2:-$(basename "$abspath")}"
focus="${3:-false}"

# Dedup (best effort): if this absolute path already shows up in the workspace list, don't open again
if cmux list-workspaces 2>/dev/null | grep -qF "$abspath"; then
  exit 0
fi

exec cmux new-workspace --name "$name" --cwd "$abspath" --focus "$focus"
;;

*)
  echo "usage: cc-dispatch.sh wt-claude <name> <prompt> [--prefix <p>] [--base <b>] | surface <path> [prompt] | send <surface-ref> \"<text>\" | calibrate <surface-ref> [label] | workspace <path> [name] [focus]" >&2; exit 2 ;;
esac
