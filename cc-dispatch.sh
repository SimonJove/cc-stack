#!/usr/bin/env bash
# cc-dispatch.sh · THE dispatch pipeline — one script, nine subcommands.
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
#   close     <worktree-dir>                                 THE sanctioned tab close: resolve the dir
#                                                             to a live surface by its RECORDED stable
#                                                             uuid (board first, opened-tabs ledger
#                                                             second), print the resolution, enforce
#                                                             the close policy, then close
#   tabs      [--all]                                        the opened-tabs inventory: every tab this
#                                                             stack opened, joined with live cmux
#                                                             resolution (ref, uuid, alive/dead, owner, dir)
#   resume    [--all]                                        gwt-resume engine (roadmap 2): cmux native
#                                                             restore-session first, then reopen board
#                                                             rows whose tab is still gone, replaying
#                                                             the RECORDED launch args (uuid/provider/
#                                                             pm/model) in the RECORDED dir verbatim
#   commit-gate mount|unmount <dir>                          THE commit gate: install/remove git's own
#                                                             pre-commit hook on the repo that contains
#                                                             <dir> (once per repo — .git/hooks is shared
#                                                             by every linked worktree). Called from
#                                                             surface/workspace on every worktree open
set -u

# This script's own directory. The hook body the commit gate installs is read from here, so a
# worktree checkout mounts ITS OWN copy (the same "a worktree tests itself" contract test.sh has).
CC_SELF="$( (CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) 2>/dev/null )"
[ -n "$CC_SELF" ] || CC_SELF="$HOME/.config/cc-stack"

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

# ─────────────────────────────────────────────────────────────────────────────
# opened-tabs ledger (2026-08-16) — ~/.config/cc-stack/opened-tabs.tsv, CC_TABS_FILE overrides.
# EVERY tab this stack opens is recorded here, keyed by the only stable identity a cmux tab has:
# its surface UUID (short refs like surface:283 DRIFT as panes open and close — they are addresses,
# never identities).
#   surface-uuid <TAB> owner-surface-uuid <TAB> dir <TAB> session-uuid <TAB> ts
# Empty owner / session fields are written as "-" ON PURPOSE: `read` collapses runs of TABs
# (whitespace IFS), so an empty middle field would shift every later field for the reader
# (docs/known-issues.md, "cc-board 读循环对空 caller 字段的 TAB 塌缩").
#
# WHY a SECOND ledger next to the board (worktree-tasks.tsv): the board only knows WORKTREE
# sub-tasks. A leader that opens a helper tab — a runner in the primary checkout, a scratch-dir
# tab — has no board row for it and therefore no recorded owner, so it could not even name, let
# alone close, a tab it opened itself. The two ledgers answer different questions and are NEVER
# deduped against each other: the board answers "whose SUB-TASK is this" (+ what to replay on
# resume), opened-tabs answers "who OPENED this tab". Both are consulted, in that order, by
# `cc-dispatch.sh close`.
# Rows are pruned LAZILY on read: a row whose surface uuid no longer appears in the live cmux
# surface map is dropped. Never prune off an INCOMPLETE map — neither an empty one (cmux
# unreachable) nor a partial one (a workspace that could not be enumerated); not having looked
# there is not evidence that the tab died. See the workspace-scope block below.
_cctabs_file(){ printf '%s' "${CC_TABS_FILE:-$HOME/.config/cc-stack/opened-tabs.tsv}"; }
_cctabs_uc(){ printf '%s' "${1:-}" | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'; }
_cctabs_lock(){ # $1 = file — same atomic-mkdir discipline as the board's append (macOS lacks flock)
  _tl="$1.lock"; _ti=0
  while [ "$_ti" -lt 60 ]; do mkdir "$_tl" 2>/dev/null && return 0; sleep 0.05; _ti=$((_ti+1)); done
  return 1
}
_cctabs_log(){ # $1 = surface uuid, $2 = owner surface uuid, $3 = dir, $4 = claude session uuid
  _tu="$(_cctabs_uc "${1:-}")"; _to="$(_cctabs_uc "${2:-}")"
  case "$_tu" in ''|*[!0-9A-F-]*) return 0 ;; esac        # only ever a plain uuid, never a ref
  case "$_to" in *[!0-9A-F-]*) _to="" ;; esac
  _tf="$(_cctabs_file)"
  _td="$(printf '%s' "${3:-}" | tr '\t\n' '  ')"
  _tsid="$(printf '%s' "${4:-}" | tr '\t\n' '  ')"
  _tgot=""; _cctabs_lock "$_tf" && _tgot=1
  printf '%s\t%s\t%s\t%s\t%s\n' "$_tu" "${_to:--}" "${_td:--}" "${_tsid:--}" "$(date '+%Y-%m-%d %H:%M:%S')" \
    >> "$_tf" 2>/dev/null || true
  [ -n "$_tgot" ] && rmdir "$_tf.lock" 2>/dev/null
  return 0
}
# ── workspace scope (2026-08-16) ────────────────────────────────────────────────────────────
# `cmux list-pane-surfaces` lists ONE workspace — the caller's ($CMUX_WORKSPACE_ID) — and the CLI
# has NO "every workspace" flag (live-probed 2026-08-16: 8 surfaces from the default call, 13 when
# the two workspaces are enumerated one by one). A single unscoped call therefore does not answer
# "is this tab still alive?", it answers "is this tab alive IN MY WORKSPACE?" — and every tab living
# anywhere else reads as dead. For the lazy prune below that is DESTRUCTIVE: it deleted the owner
# rows of four live sub-task tabs that sat in another workspace, and a tab with no recorded owner
# is one `close` fail-closes on forever (only the human can finish it in the cmux UI).
# The map is now the UNION over `cmux list-workspaces`, and it carries its own completeness:
#   · one "<short-ref> TAB <UPPERCASE-uuid> TAB <workspace-ref>" line per live surface
#   · a final "!partial" line whenever the enumeration was INCOMPLETE — one workspace unreachable,
#     or the workspace LIST itself unavailable (then there is no way to know how many workspaces
#     were missed, which is the least complete evidence of all, not the most)
#   · nothing at all when cmux is unreachable (the pre-existing "no evidence" signal, unchanged)
# WHY the completeness flag travels INSIDE the output instead of in a shell variable: every caller
# captures the map through `$( )`, and a variable set in that subshell never comes back — the
# warning would be lost at exactly the call sites that prune. Consumers that only ask "is THIS uuid
# alive?" ($2 == u) skip the sentinel for free; the consumer that infers DEATH from absence must
# look at it. Short refs stay ADDRESSES and uuids stay IDENTITIES — the extra column is context for
# resolving an address, never a second identity (refs do not repeat across workspaces here, but
# nothing in this stack may start relying on that).
_cc_ws_refs(){ # every workspace ref cmux knows, one per line ("" = cannot enumerate)
  # `list-workspaces` prints "<*| > workspace:N  <name> [selected]" (the legacy-alias notice goes to
  # stderr). Only the LEADING ref token counts — a `grep -o` over the whole line would mint a
  # workspace ref out of a workspace NAMED after one.
  cmux list-workspaces 2>/dev/null | sed 's/^\*//' | awk '$1 ~ /^workspace:[0-9]+$/{print $1}'
}
_cctabs_livemap(){ # live surface map; see the block comment above for the format and the sentinel
  command -v cmux >/dev/null 2>&1 || return 0
  _tws="$(_cc_ws_refs)"
  if [ -z "$_tws" ]; then
    # No workspace list (older CLI, or the call failed). The unscoped call is still the best
    # ADDRESS book we can get — resolution keeps working — but it is NOT complete evidence: without
    # the list we cannot even know how many workspaces we failed to look in, so this is the LEAST
    # complete case, not a special safe one. It therefore carries the same "!partial" sentinel and
    # prunes nothing. (Gate call, 2026-08-16: the earlier "this is exactly the pre-fix behaviour"
    # fallback still deleted live rows whenever the list call failed — the very shape this line was
    # opened to remove, only with a different trigger. Cost accepted: on such a build the ledger
    # only grows. A stale row is harmless — its uuid resolves to nothing, `close` says "no live tab"
    # and exits 0 — while a deleted row is unrecoverable.)
    _tmap="$(cmux list-pane-surfaces --id-format both 2>/dev/null | sed 's/^\*//' \
      | awk 'NF>=2{print $1 "\t" toupper($2)}')"
    [ -n "$_tmap" ] || return 0          # nothing at all = cmux unreachable = no evidence, no map
    printf '%s\n!partial\n' "$_tmap"
    return 0
  fi
  _tmap=""; _tpart=""
  for _tw in $_tws; do
    _tout="$(cmux list-pane-surfaces --workspace "$_tw" --id-format both 2>/dev/null | sed 's/^\*//' \
      | awk -v w="$_tw" 'NF>=2{print $1 "\t" toupper($2) "\t" w}')"
    # An EMPTY answer is a failed probe, not an empty workspace: a workspace always holds at least
    # one surface (cmux refuses to close the last one — docs/known-issues.md). rc alone cannot carry
    # this — an unknown --workspace ref still exits 0, it just answers about a different workspace.
    if [ -n "$_tout" ]; then
      _tmap="$_tmap$_tout
"
    else
      _tpart=1
    fi
  done
  [ -n "$_tmap" ] || return 0            # nothing anywhere = cmux unreachable = no evidence at all
  printf '%s' "$_tmap"
  [ -n "$_tpart" ] && printf '!partial\n'
  return 0
}
_cctabs_partial(){ # rc 0 when a map carries the incomplete-evidence sentinel
  _tpnl='
'
  case "$_tpnl${1:-}$_tpnl" in *"$_tpnl!partial$_tpnl"*) return 0 ;; esac
  return 1
}
_cctabs_where(){ # $1 = live map, $2 = surface uuid → the workspace ref it was seen in ("" = unknown)
  printf '%s\n' "${1:-}" | awk -F'\t' -v u="${2:-}" '$2==u{print $3; exit}'
}
_cctabs_prune(){ # $1 = live map (optional; probed when omitted) — drop rows whose surface is gone
  _tf="$(_cctabs_file)"; [ -f "$_tf" ] || return 0
  _tlm="${1:-$(_cctabs_livemap)}"
  [ -n "$_tlm" ] || return 0                              # no map = no evidence = no pruning
  # INVARIANT (2026-08-16): absence of evidence is NEVER evidence of death, and it only ever gets
  # stronger. An empty map already pruned nothing; a PARTIAL map — one workspace enumerated, another
  # unreachable — prunes nothing either, genuinely dead rows included. Deleting a live row is
  # irreversible (its owner is gone, `close` fail-closes, a human has to clean up in the UI);
  # keeping a dead row costs one stale line that the next COMPLETE read sweeps. Never weaken this
  # into "prune within the workspaces we could see".
  _cctabs_partial "$_tlm" && return 0
  _tgot=""; _cctabs_lock "$_tf" && _tgot=1
  _ttmp="$_tf.tmp.$$"
  printf '%s\n' "$_tlm" | awk -F'\t' 'NF>=2{print toupper($2)}' > "$_ttmp.live" 2>/dev/null
  # NB: the live keys are read via getline-in-BEGIN, NOT the usual NR==FNR idiom — same reason
  # _ccres_setref/_ccres_dropstatus do (see the note there). With an EMPTY key file NR==FNR never
  # flips (on the first line of the SECOND file NR is still == FNR), so awk would swallow the whole
  # ledger as keys, print nothing, and the mv + `[ -s ]` below would DELETE opened-tabs.tsv —
  # losing every helper tab's recorded owner, after which `close` fail-closes on all of them and
  # the human has to go close tabs in the UI. An empty key set is "no evidence": prune NOTHING,
  # matching the guard above. (A failed mv needs no rollback: rename is atomic, so the ledger keeps
  # its old content and the tmp is swept on the next line.)
  if awk -F'\t' -v mf="$_ttmp.live" '
        BEGIN{ n=0; while ((getline l < mf) > 0) if (l != "") { k[l]=1; n++ } close(mf) }
        n==0{ print; next }
        $1!="" && ($1 in k)' "$_tf" > "$_ttmp" 2>/dev/null; then
    mv "$_ttmp" "$_tf" 2>/dev/null
  fi
  rm -f "$_ttmp" "$_ttmp.live" 2>/dev/null
  [ -s "$_tf" ] || rm -f "$_tf" 2>/dev/null
  [ -n "$_tgot" ] && rmdir "$_tf.lock" 2>/dev/null
  return 0
}
_cctabs_owner(){ # $1 = surface uuid → the owner recorded for it (newest row; "" when none)
  _tf="$(_cctabs_file)"; [ -f "$_tf" ] || return 0
  awk -F'\t' -v u="$(_cctabs_uc "${1:-}")" \
    '$1==u && $2!="" && $2!="-"{o=$2} END{if(o!="")print o}' "$_tf" 2>/dev/null
}
_cctabs_by_dir(){ # $1 = canonical dir, $2 = dir as given → "suuid<TAB>owner" of the newest row
  _tf="$(_cctabs_file)"; [ -f "$_tf" ] || return 0
  awk -F'\t' -v a="${1:-}" -v b="${2:-}" \
    '($3==a || $3==b) && $1!=""{u=$1; o=$2} END{if(u!="") print u "\t" ((o=="-")?"":o)}' "$_tf" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# _cc_gitroot — a DIRECTORY → the main repo root that contains it, always ABSOLUTE. rc 1 (and no
# output) when the directory is gone or is not inside a repo.
# WHY this is not the obvious one-liner (live-probed 2026-08-16, git 2.55.0/darwin):
#   git -C <linked worktree> rev-parse --git-common-dir  →  /abs/path/to/main/.git
#   git -C <MAIN checkout>   rev-parse --git-common-dir  →  .git            ← RELATIVE
# and a relative answer resolves against the CALLER's pwd, never against the target. So
# `cd "$(git -C "$d" rev-parse --git-common-dir)/.."` silently computes the CALLER's repo root
# whenever $d is a main checkout — which on the `surface` path means copying the CALLER repo's
# .env / .claude/settings.local.json and seeding its shared corpus into someone else's checkout,
# plus recording the merge target in the wrong repo. Production only ever hands `surface` a linked
# worktree (hook / wt-claude / resume alike), but `cc-dispatch.sh surface <any-dir>` is a public
# subcommand, so the main-checkout case is reachable — a cross-repo file leak.
# The fix: run BOTH cds inside the target, so a relative `.git` resolves against it and an absolute
# one is unaffected. (git 2.31+ could say `--path-format=absolute` instead; doing it with cd keeps
# this stack's git-version floor where the rest of it already is.)
_cc_gitroot(){ # $1 = a directory
  [ -n "${1:-}" ] || return 1
  _ccgr="$( (CDPATH= cd -- "$1" 2>/dev/null || exit 1
             _ccg="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 1
             [ -n "$_ccg" ] || exit 1          # an empty answer must never become `cd /..` → /
             CDPATH= cd -- "$_ccg/.." 2>/dev/null || exit 1
             pwd -P) 2>/dev/null )"
  [ -n "$_ccgr" ] || return 1
  printf '%s' "$_ccgr"
}

# _cc_gitcommon — a DIRECTORY → the repo's COMMON git dir, always ABSOLUTE. Same cd-inside-the-target
# discipline as _cc_gitroot above, and for the same reason (a main checkout answers `.git`, relative).
# The common dir is what every linked worktree SHARES — which is why the commit gate mounts once per
# repo and not once per worktree (live-probed 2026-08-16: a hook in <main>/.git/hooks fires for
# commits made inside a linked worktree).
_cc_gitcommon(){ # $1 = a directory
  [ -n "${1:-}" ] || return 1
  _ccgc="$( (CDPATH= cd -- "$1" 2>/dev/null || exit 1
             _ccg="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 1
             [ -n "$_ccg" ] || exit 1
             CDPATH= cd -- "$_ccg" 2>/dev/null || exit 1
             pwd -P) 2>/dev/null )"
  [ -n "$_ccgc" ] || return 1
  printf '%s' "$_ccgc"
}

# ─────────────────────────────────────────────────────────────────────────────
# THE COMMIT GATE (2026-08-16, feat/commit-gate-git) — mount/unmount hooks/git-pre-commit.sh as
# <repo-common-git-dir>/hooks/pre-commit. See that file's header for WHY it is a git hook and not a
# PreToolUse text parser, and for the deliberately accepted `--no-verify` bypass.
#
# COEXISTENCE (the hard red line: a downstream project's own hooks must not stop working).
#   • core.hooksPath configured → REFUSE, loudly, and change nothing. Setting it ourselves would
#     silently disable the project's entire hook set (probed: its commit-msg stopped running); and
#     writing into the path it names is no better — git resolves a RELATIVE core.hooksPath against
#     each working tree separately, so the file would land in the main checkout's WORKING TREE and
#     be invisible to the very worktrees we mean to gate. Rare enough to hand to a human.
#   • a foreign pre-commit already there → PRESERVED as pre-commit.cc-stack-orig (git only ever
#     runs the exact name `pre-commit`, so the saved copy is inert) and exec'd by our hook once the
#     gate passes. Nothing is ever overwritten, and commit-msg / every other hook is untouched.
#   • already ours → replaced only when the body actually differs (upgrade), so re-mounting is
#     silent and can never nest a second copy of the logic.
#   • ours displaced by a stranger while a saved original is still on disk → ambiguous, REFUSE.
# Output discipline: silent + rc 0 when already in place (this runs on every dispatch), one line
# when something changes, a loud stderr refusal + rc 3 when it will not touch the repo.
_ccgate_marker='cc-stack:commit-gate'
_ccgate_hooksdir(){ # $1 = a directory inside the repo → the hooks dir to mount into (rc!=0 = don't)
  _cgcommon="$(_cc_gitcommon "${1:-}")" || return 1
  _cghp="$(git -C "$1" config --get core.hooksPath 2>/dev/null)"
  [ -z "$_cghp" ] || return 2
  # The working tree we resolved must be one this repo actually KNOWS. A stray or copied `.git`
  # pointer file makes an arbitrary directory answer `rev-parse` with somebody else's git dir — and
  # then a hook meant for that directory lands in a repo nobody named. (Not hypothetical: install.sh
  # used to copy a worktree's `.git` file into the install dir, and that is exactly how this
  # migration's own test run wrote a hook into the live cc-stack checkout.) `git worktree list` is
  # the repo's own answer to "is this really mine", so ask it and fail closed.
  _cgtop="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 4
  [ -n "$_cgtop" ] || return 4
  git -C "$1" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $_cgtop" || return 4
  printf '%s' "$_cgcommon/hooks"
}
_ccgate_install(){ # $1 = src, $2 = dest — write then rename, so a half-copied hook is never runnable
  _cgtmp="$2.cc-stack.$$"
  cp -- "$1" "$_cgtmp" 2>/dev/null || return 1
  chmod +x "$_cgtmp" 2>/dev/null
  mv -f -- "$_cgtmp" "$2" 2>/dev/null || { rm -f "$_cgtmp" 2>/dev/null; return 1; }
}
_cc_commit_gate(){ # $1 = mount|unmount, $2 = a directory inside the target repo
  _cgact="${1:-}"; _cgdir="${2:-}"
  [ -d "$_cgdir" ] || { echo "✗ commit gate: not a directory: $_cgdir" >&2; return 1; }
  _cghd="$(_ccgate_hooksdir "$_cgdir")"; _cgrc=$?
  if [ "$_cgrc" = 2 ]; then
    echo "✗ commit gate: $_cgdir routes hooks through core.hooksPath — refusing to touch it." >&2
    echo "  cc-stack never overrides core.hooksPath (it silently disables the project's own hooks)." >&2
    echo "  Mount by hand if you want the gate here: copy $CC_SELF/hooks/git-pre-commit.sh into that dir as pre-commit." >&2
    return 3
  fi
  if [ "$_cgrc" = 4 ]; then
    echo "✗ commit gate: $_cgdir resolves to a git dir that does not list it as a worktree — refusing." >&2
    echo "  A stray or copied .git pointer file does this; mounting would put a hook in a repo nobody named." >&2
    return 3
  fi
  [ "$_cgrc" = 0 ] && [ -n "$_cghd" ] || { echo "✗ commit gate: not inside a git repo: $_cgdir" >&2; return 1; }
  _cgtgt="$_cghd/pre-commit"; _cgorig="$_cghd/pre-commit.cc-stack-orig"
  _cgmine=""; [ -f "$_cgtgt" ] && grep -q "$_ccgate_marker" "$_cgtgt" 2>/dev/null && _cgmine=1

  case "$_cgact" in
    unmount)
      if [ ! -e "$_cgtgt" ]; then echo "  ↳ commit gate: not mounted on $_cghd"; return 0; fi
      if [ -z "$_cgmine" ]; then
        echo "✗ commit gate: $_cgtgt is not ours — left untouched." >&2; return 3
      fi
      if [ -e "$_cgorig" ]; then
        mv -f -- "$_cgorig" "$_cgtgt" 2>/dev/null || { echo "✗ commit gate: could not restore $_cgorig" >&2; return 1; }
        echo "  ↳ commit gate: removed, restored the project's original pre-commit"
      else
        rm -f -- "$_cgtgt" 2>/dev/null || { echo "✗ commit gate: could not remove $_cgtgt" >&2; return 1; }
        echo "  ↳ commit gate: removed from $_cghd"
      fi
      return 0 ;;
    mount) : ;;
    *) echo "usage: cc-dispatch.sh commit-gate mount|unmount <dir>" >&2; return 2 ;;
  esac

  _cgsrc="$CC_SELF/hooks/git-pre-commit.sh"
  [ -r "$_cgsrc" ] || { echo "✗ commit gate: hook body missing: $_cgsrc" >&2; return 1; }
  mkdir -p "$_cghd" 2>/dev/null || { echo "✗ commit gate: cannot create $_cghd" >&2; return 1; }

  if [ -n "$_cgmine" ]; then
    cmp -s "$_cgsrc" "$_cgtgt" 2>/dev/null && { chmod +x "$_cgtgt" 2>/dev/null; return 0; }   # already in place
    _ccgate_install "$_cgsrc" "$_cgtgt" || { echo "✗ commit gate: cannot update $_cgtgt" >&2; return 1; }
    echo "  ↳ commit gate: updated $_cgtgt"
    return 0
  fi
  if [ -e "$_cgtgt" ]; then
    if [ -e "$_cgorig" ]; then
      echo "✗ commit gate: $_cgtgt is a foreign hook but $_cgorig already exists — refusing to guess." >&2
      echo "  Resolve by hand: keep the one you want as pre-commit, delete or rename the other." >&2
      return 3
    fi
    mv -f -- "$_cgtgt" "$_cgorig" 2>/dev/null || { echo "✗ commit gate: cannot preserve $_cgtgt" >&2; return 1; }
    _ccgate_install "$_cgsrc" "$_cgtgt" || { mv -f -- "$_cgorig" "$_cgtgt" 2>/dev/null; echo "✗ commit gate: cannot write $_cgtgt" >&2; return 1; }
    echo "  ↳ commit gate: mounted on $_cghd (kept the project's pre-commit as pre-commit.cc-stack-orig; it still runs)"
    return 0
  fi
  _ccgate_install "$_cgsrc" "$_cgtgt" || { echo "✗ commit gate: cannot write $_cgtgt" >&2; return 1; }
  echo "  ↳ commit gate: mounted on $_cghd"
  return 0
}
# Dispatch-path entry: gate the repo behind a worktree we are about to open a tab for. Deliberately
# scoped to the gated LAYOUT — `surface <dir>` is a public subcommand and may be handed a plain main
# checkout, which has no sub-task to gate and no business receiving a hook it never asked for.
_cc_commit_gate_auto(){ # $1 = the directory a tab is being opened for
  case "${1:-}" in
    */.claude/worktrees/*|*/.worktrees/*) _cc_commit_gate mount "$1" || true ;;
  esac
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
#   CC_WT_PRETRUST (default 1), CC_WT_COPY (files to copy into the worktree),
#   CC_WT_MODEL (optional --model pin, recorded for gwt-resume), CC_WT_SESSION_ID (pre-minted
#   claude session id — the resume path replays the RECORDED uuid instead of minting),
#   CC_WT_LAUNCH_CMD (resume mode: open the tab but launch THIS command verbatim; skips prompt
#   assembly, session-id minting, the 120s dedup marker and the board log — the resume caller
#   owns the bookkeeping and refreshes the row's surface ref itself)
surface)
shift
path="${1:-}"; prompt="${2:-}"
[ -n "$path" ] || { echo "usage: cc-dispatch.sh surface <path> [prompt]" >&2; exit 2; }
[ -d "$path" ] || { echo "directory does not exist: $path" >&2; exit 2; }
abspath="$(cd "$path" 2>/dev/null && pwd -P)" || exit 2
# Resume mode (gwt-resume reopen): CC_WT_LAUNCH_CMD carries the fully composed replay command.
rsmode="${CC_WT_LAUNCH_CMD:+1}"

# ── Commit gate ── mount git's own pre-commit on this worktree's repo. Deliberately BEFORE the cmux
# checks below: the worktree already exists by now, and a cmux hiccup that costs us the tab must not
# also cost us the gate. Idempotent and silent once mounted (once per repo — .git/hooks is shared).
_cc_commit_gate_auto "$abspath"

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

# Dedup (best effort): if a tab was opened for this dir within 120s, don't repeat. Only CHECK here;
# write the marker after success (failures leave no blocking marker). SKIPPED in resume mode: a
# marker left by the pre-crash dispatch is exactly what must not eat the reopen.
marker=""
if [ -z "$rsmode" ]; then
  marker_dir="${TMPDIR:-/tmp}/cc-cmux-tabs"
  mkdir -p "$marker_dir" 2>/dev/null || true
  marker="$marker_dir/$(printf '%s' "$abspath" | shasum -a 1 2>/dev/null | cut -d' ' -f1)"
fi
if [ -n "$marker" ] && [ -e "$marker" ]; then
  now=$(date +%s 2>/dev/null || echo 0); mt=$(stat -f %m "$marker" 2>/dev/null || echo 0)
  [ $((now - mt)) -lt 120 ] && exit 0
fi

# Copy gitignored-but-needed files (.env etc.) so hook-path sub-tasks also get their environment (matches gwt-new/gwt-claude)
# The root MUST be resolved relative to $abspath, not to this process's pwd — see _cc_gitroot:
# when $abspath is a main checkout the naive form names the CALLER's repo and this loop then
# copies the caller's .env into a foreign checkout.
root="$(_cc_gitroot "$abspath")" || root=""
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
  _root="$(_cc_gitroot "$abspath")" || _root=""     # same caveat as above: resolve against $abspath
  _br="$(git -C "$abspath" symbolic-ref --short HEAD 2>/dev/null)"
  [ -n "$_root" ] && [ -n "$_br" ] && \
    "$HOME/.config/cc-stack/cc-merge.sh" capture "$_root" "$_br" "$CC_CALLER_CWD" >/dev/null 2>&1
fi

# Pre-authorize trust for this worktree, skipping claude's "Do you trust this folder?" prompt (more robust than screen-scraping; CC_WT_PRETRUST=0 disables)
[ "${CC_WT_PRETRUST:-1}" != "0" ] && "$HOME/.config/cc-stack/cc-trust.sh" "$abspath" >/dev/null 2>&1

# Caller (main task) surface / workspace — backchannel + target workspace.
# csuuid: the caller's STABLE surface uuid. This process runs INSIDE the dispatching parent
# session (hook path and gwt-claude path alike), so $CMUX_SURFACE_ID is that parent's surface —
# the identity the close policy (`cc-dispatch.sh close`) compares against, on the board row and
# on the opened-tabs ledger row alike. The short
# caller_surface ref below stays what it always was: a backchannel address, not an identity.
# CC_CALLER_SURFACE_UUID overrides it (tests; a caller that knows better).
csuuid="${CC_CALLER_SURFACE_UUID:-${CMUX_SURFACE_ID:-}}"
case "$csuuid" in *[!0-9A-Fa-f-]*) csuuid="" ;; esac
ident="$(cmux identify 2>/dev/null)"
caller_surface="$(printf '%s' "$ident" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("caller") or {}).get("surface_ref",""))' 2>/dev/null)"
caller_ws="$(printf '%s' "$ident" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("caller") or {}).get("workspace_ref",""))' 2>/dev/null)"

# Open the new surface (tab): in the caller's workspace, background, no focus steal. Short retry to ride out hiccups.
# --id-format both makes new-surface print the STABLE surface uuid next to the short ref
#   ("OK surface:291 (2FBF1942-…) pane:108 (…) workspace:108 (…)"), which is what the board records
#   as suuid — short refs DRIFT (probed live 2026-08-16: a tab opened as surface:291 reported its
#   own close as surface:292), so they can never be an identity. Older cmux builds that ignore the
#   flag simply print the ref; the list-pane-surfaces join below fills the uuid in.
ref=""; nsout=""
for _ in 1 2 3 4 5; do
  if [ -n "$caller_ws" ]; then
    nsout="$(cmux new-surface --type terminal --working-directory "$abspath" --focus false --workspace "$caller_ws" --id-format both 2>/dev/null)"
  else
    nsout="$(cmux new-surface --type terminal --working-directory "$abspath" --focus false --id-format both 2>/dev/null)"
  fi
  ref="$(printf '%s\n' "$nsout" | grep -oE 'surface:[0-9]+' | head -1)"
  [ -n "$ref" ] && break
  sleep 0.4
done
[ -n "$ref" ] || { _fail "cmux new-surface failed to open a tab"; exit 1; }

# The child tab's own STABLE surface uuid (board field suuid; see cc-board.sh). Parsed off the
# new-surface line by FIELD position (never a sed pattern mixing literal parens with wildcards —
# see docs/known-issues.md, BSD sed), with a list-pane-surfaces join as the fallback.
suuid="$(printf '%s\n' "$nsout" | awk '{for(i=1;i<NF;i++) if ($i ~ /^surface:[0-9]+$/) {u=$(i+1); gsub(/[()]/,"",u); if (u ~ /^[0-9A-Fa-f-]+$/ && length(u) >= 30) {print u; exit}}}')"
[ -n "$suuid" ] || suuid="$(cmux list-pane-surfaces --id-format both 2>/dev/null | sed 's/^\*//' \
  | awk -v r="$ref" 'NF>=2 && $1==r{print $2; exit}')"
case "$suuid" in *[!0-9A-Fa-f-]*) suuid="" ;; esac    # never record anything but a plain uuid

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
——[Working agreement] $way1 (2) Follow this project's own CLAUDE.md and .claude config (harness) throughout; don't drift toward your own defaults. (3) After making changes, commit / rebase / merge / push / removing the worktree or branch ALL require human authorization — even if the finishing-a-development-branch skill prompts you, just stop at 'keep the branch'. (4) When you finish implementing and have reported back, run \`~/.config/cc-stack/gwt-done\` (the absolute path — \`gwt-done\` alone is a zsh function that does NOT exist in your non-interactive shell) to mark this branch ready; your merge target is already recorded, so you never choose where to merge, and you never merge without my authorization."
  [ -n "$caller_surface" ] && full="$full (5) To report back / ask the main task: ~/.config/cc-stack/cc-dispatch.sh send $caller_surface \"message\" — cc-send waits out any half-typed line instead of colliding; never use raw cmux send + Enter."
fi

# Start the sub-task claude. Key point: don't type the prompt straight into the terminal (a very long line gets shredded,
# and newlines are treated as Enter). Instead write it to a temp file and type a short command "$(cat file)" — the shell reads
# the file and passes the whole content (newlines and all) to claude as a single argument.
# --permission-mode $pm: resolved above (default auto, CC_WT_PERMISSION_MODE=plan for the plan-first gate).
# --session-id <uuid> (roadmap 2, gwt-resume): mint a caller-chosen UUID so the board can later resume
# THIS exact session (verified: the session file lands under the minted id). CC_WT_SESSION_ID lets a
# caller pass a pre-minted one. No uuidgen → no flag and the row records no uuid (gwt-resume then
# degrades that row to an idle tab, visibly). Lowercased to match cmux session-store keys as written.
sid="$(printf '%s' "${CC_WT_SESSION_ID:-$(uuidgen 2>/dev/null)}" | tr '[:upper:]' '[:lower:]')"
case "$sid" in
  *[!0-9a-f-]*) sid="" ;;    # defensive: anything but a plain uuid → drop, never a broken launch
esac
sess=""; [ -n "$sid" ] && sess=" --session-id $sid"

# Optional model pin (roadmap 2): CC_WT_MODEL → --model on the launch AND a model= entry in the
# row's launch-args, so gwt-resume replays it. Charset-whitelisted for the same reason $pm is:
# the value is interpolated into the typed launch command.
mdl="${CC_WT_MODEL:-}"
case "$mdl" in
  *[!A-Za-z0-9._\[\]-]*) mdl="" ;;
esac
mflag=""; [ -n "$mdl" ] && mflag=" --model $mdl"

if [ -n "$rsmode" ]; then
  # Resume mode: CC_WT_LAUNCH_CMD arrives fully composed from the recorded args (uuid/provider/
  # pm/model) — no prompt to send (the session IS the context), nothing to mint, no board row;
  # the resume caller refreshes the existing row's surface ref itself.
  pf=""
  ( export CC_SEND_QUIET=1; _ccsend "$ref" "$CC_WT_LAUNCH_CMD" ) >/dev/null 2>&1 || true
else
# Provider for NEW sub-tasks: `gwt-provider` writes a provider name to $CC_LAUNCH_FILE (default anthropic).
# anthropic/default → cmux claude-teams on the official/current-env provider; any other name → `cld <name>`,
# which sources ~/.config/claude/llm-provider/<name>.sh in the new tab (provider env is process-local, so
# existing sub-tasks keep their launch-time provider). Unknown/empty → safe default, never breaks the launch.
_provider="$(cat "${CC_LAUNCH_FILE:-$HOME/.config/cc-stack/launch}" 2>/dev/null)"
prov_rec="anthropic"
case "$_provider" in
  ""|anthropic|default) launch="ccteam" ;;
  */*|*..*)             launch="ccteam" ;;     # path-traversal guard → safe default
  *)                    launch="cld $_provider"; prov_rec="$_provider" ;;
esac
# launch-args for the board's 8th TSV field — exactly what gwt-resume replays later, plus the two
# STABLE surface identities the tab-close gate keys on. uuid omitted when minting failed;
# csuuid = the DISPATCHING PARENT's surface (this process runs inside it), suuid = the child tab's
# own surface; model stays composed LAST (a model id may itself contain colons).
largs=""; [ -n "$sid" ] && largs="uuid=$sid"
largs="${largs:+$largs:}provider=$prov_rec:pm=$pm"
[ -n "$csuuid" ] && largs="$largs:csuuid=$csuuid"
[ -n "$suuid" ]  && largs="$largs:suuid=$suuid"
[ -n "$mdl" ] && largs="$largs:model=$mdl"
pf=""
if [ -n "$full" ]; then
  pf="${TMPDIR:-/tmp}/cc-wt-prompt.$$.txt"
  printf '%s' "$full" > "$pf"
  # Routed through cc-send (the single injection exit point). The tab is still a SHELL here — no
  # claude input box yet — so CC_SEND_QUIET suppresses the fail-open breadcrumb that an
  # unrecognized shell prompt would otherwise write on every dispatch.
  ( export CC_SEND_QUIET=1; _ccsend "$ref" "$launch$sess --permission-mode $pm$mflag \"\$(cat '$pf')\"" ) >/dev/null 2>&1 || true
else
  ( export CC_SEND_QUIET=1; _ccsend "$ref" "$launch$sess --permission-mode $pm$mflag" ) >/dev/null 2>&1 || true
fi
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
# 6th arg = launch-args (8th TSV field, what gwt-resume replays). SKIPPED in resume mode: the
# row already exists with its recorded args; `cc-dispatch.sh resume` refreshes its surface ref.
if [ -z "$rsmode" ]; then
  "$HOME/.config/cc-stack/cc-board.sh" log "$abspath" "$ref" "${caller_surface:-}" "$prompt" \
    "$(git -C "${CC_CALLER_CWD:-$PWD}" symbolic-ref --short HEAD 2>/dev/null)" "${largs:-}"
fi

# ── Register into the opened-tabs ledger (who opened which tab) ──
# Written on EVERY open, worktree sub-task or not, resume included (a reopened tab is a NEW
# surface uuid). This is the ledger that lets a leader name — and close — a helper tab it opened
# in a non-worktree directory; the board row above stays the sub-task record. Deliberately NOT
# deduped against the board: different questions, different lifetimes (see the helper block at
# the top of this file).
# In resume mode nothing was minted — the session being resumed is the one inside the replayed
# launch command, so read it back off `--resume <uuid>` rather than record the unused fresh id.
tabsid="$sid"
[ -n "$rsmode" ] && tabsid="$(printf '%s' "$CC_WT_LAUNCH_CMD" \
  | awk '{for(i=1;i<NF;i++) if ($i=="--resume") {print $(i+1); exit}}')"
_cctabs_log "$suuid" "$csuuid" "$abspath" "$tabsid"

echo "✔ new tab : $ref  ${suuid:+uuid=$suuid  }cwd=$abspath  $(if [ -n "$rsmode" ]; then echo '(resume launch sent)'; elif [ -n "$prompt" ]; then echo '(initial prompt sent)'; else echo '(idle ccteam)'; fi)"
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
# close — THE sanctioned way to close a sub-task tab from automation. Takes a DIRECTORY, never a
#   surface ref: the ledgers are keyed by directory, and the only stable identities in them are
#   the surface UUIDs recorded at open time (short refs DRIFT — that is how the 2026-08-16
#   incident closed the parent session itself).
#     ① resolve dir → live surface, in ledger order:
#          1. the board row's suuid (worktree-tasks.tsv — the sub-task record, the only source
#             that covers ccteam sub-tasks: the cmux agent session store never sees them),
#          2. the opened-tabs ledger by dir (opened-tabs.tsv — every tab this stack opened).
#             This one survives `gwt-rm`, which DROPS the board row: a leader that removed a
#             worktree first and only then went to close its tab used to be told "no live tab
#             resolves to this directory" and had to close it by hand (live incident). The
#             opened-tabs row is only ever dropped by the lazy prune, i.e. once the surface
#             itself is gone,
#          3. the cmux agent session store's newest session in that cwd.
#        A recorded SHORT ref is never a fallback — an address is not an identity.
#     ② PRINT the resolution (short ref + stable uuid + cwd) before touching anything
#     ③ policy: never the caller's own surface; a non-worktree directory only when the
#        opened-tabs ledger records THIS session as the tab's opener (one may close what one
#        opened); and — for AUTOMATED callers — only a child whose recorded csuuid is this very
#        session OR whose branch is marked ready (gwt-done: a finished sub-task's tab is
#        collectible by any automated caller). "Automated" is decided by PROCESS ANCESTRY (a
#        claude binary in the PPID chain), never by an env var a caller could strip; a human
#        shell is the UI path in shell form, so there the ownership check reports instead of
#        refusing.
#     ④ close by the STABLE uuid
#   No live tab for that dir = nothing to do (rc 0): gwt-rm --close must stay idempotent.
# Usage: cc-dispatch.sh close <worktree-dir>
# Related env: CC_TASKS_FILE (board), CC_TABS_FILE (opened-tabs ledger), CC_CMUX_SESSIONS
#   (session store), CC_CALLER_SURFACE_UUID (override for $CMUX_SURFACE_ID)
close)
shift
cdir="${1:-}"
[ -n "$cdir" ] && [ $# -le 1 ] || { echo "usage: cc-dispatch.sh close <worktree-dir>" >&2; exit 2; }
command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 || {
  echo "✗ can't reach cmux, aborting (nothing closed)" >&2; exit 1; }

ccb_canon(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
_ccuc(){ printf '%s' "${1:-}" | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'; }
_cc_automated(){ # rc 0 = an AGENT is driving this call, rc 1 = a human shell is
  # WHY ANCESTRY AND NOT AN ENV VAR (gate review 2026-08-16): the check gates who may close
  # someone else's sub-task tab, and any env-based discriminator is strip-able from the very
  # command line being gated — `env -u CLAUDECODE cc-dispatch.sh close <other-childs-dir>` was
  # live-verified to demote enforcement to a printed note and really close the tab. The PPID
  # chain is not writable from the command line. $CLAUDECODE stays a FAST-PATH HINT only: set =>
  # certainly an agent; unset decides nothing and we walk.
  case "${CLAUDECODE:-}" in "") ;; *) return 0 ;; esac
  _p=$$; _d=0
  while [ "$_d" -lt 12 ]; do
    _pp="$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d '[:space:]')"
    case "$_pp" in ''|*[!0-9]*) return 1 ;; esac      # chain broken/unreadable → treat as human
    [ "$_pp" -le 1 ] && return 1                      # reached init: a login shell, no agent
    _cm="$(ps -o comm= -p "$_pp" 2>/dev/null)"        # full executable path on darwin
    case "${_cm##*/}" in claude|claude-*|claude.*) return 0 ;; esac
    _p="$_pp"; _d=$((_d+1))
  done
  return 1
}
_cc_repo_of(){ # $1 = a worktree dir (which may already be GONE) → its MAIN repo root
  # _cc_gitroot, not `git -C … --git-common-dir` + cd: for a MAIN checkout git answers with a
  # RELATIVE `.git` that would resolve against THIS process's pwd, i.e. name the caller's repo —
  # here that would ask cc-merge.sh whether the wrong repo has the branch marked ready.
  _r="$(_cc_gitroot "${1:-}")" && [ -n "$_r" ] && { printf '%s' "$_r"; return 0; }
  case "${1:-}" in                                  # dir removed: the layout convention still holds
    */.claude/worktrees/*) printf '%s' "${1%%/.claude/worktrees/*}"; return 0 ;;
    */.worktrees/*)        printf '%s' "${1%%/.worktrees/*}"; return 0 ;;
  esac
  _cc_gitroot "$PWD"                                # last resort: the caller's repo (see known-issues)
}
_cc_rowdone(){ # rc 0 = this row's branch is marked ready (gwt-done → branch.<b>.ccDone)
  [ -n "${bbranch:-}" ] || return 1
  _rp="$(_cc_repo_of "$ccan")"; [ -n "$_rp" ] || return 1
  _mg="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/cc-merge.sh"
  [ -f "$_mg" ] || _mg="$HOME/.config/cc-stack/cc-merge.sh"
  [ -f "$_mg" ] || return 1
  bash "$_mg" is-done "$_rp" "$bbranch" >/dev/null 2>&1
}
_ccpick(){ # $1 = launch-args field, $2 = key → value ("" when absent); model is composed LAST
  _v=""; _pre="$1"
  case "$1" in *model=*) _pre="${1%%model=*}" ;; esac
  _oifs="$IFS"; IFS=':'
  for _seg in $_pre; do case "$_seg" in "$2"=*) _v="${_seg#$2=}" ;; esac; done
  IFS="$_oifs"; printf '%s' "$_v"
}
# The dir may already be GONE (gwt-rm --close removes the worktree first) — canonicalize when we
# still can, otherwise keep the string as given and compare both forms against the board.
ccan="$(ccb_canon "$cdir")"; [ -n "$ccan" ] || ccan="$cdir"
tasks="${CC_TASKS_FILE:-$HOME/.config/cc-stack/worktree-tasks.tsv}"
cstore="${CC_CMUX_SESSIONS:-$HOME/.cmuxterm/claude-hook-sessions.json}"
self_uuid="$(_ccuc "${CC_CALLER_SURFACE_UUID:-${CMUX_SURFACE_ID:-}}")"

# ── ① board row (newest for this dir) → recorded identities ──
# The pair is emitted as "branch<TAB>launch-args" with a "-" placeholder for an empty branch:
# `read` collapses runs of TABs, so an empty leading field would shift the launch-args field
# (docs/known-issues.md, the TAB-collapse entry).
brow=""; bbranch=""
if [ -f "$tasks" ]; then
  brow="$(awk -F'\t' '$4!=""{print ($2==""?"-":$2) "\t" $4 "\t" $8}' "$tasks" 2>/dev/null \
    | while IFS=$'\t' read -r _bb _bd _la; do
      [ -n "$_bd" ] || continue
      _bc="$(ccb_canon "$_bd")"; [ -n "$_bc" ] || _bc="$_bd"
      { [ "$_bc" = "$ccan" ] || [ "$_bd" = "$cdir" ]; } || continue
      printf '%s\t%s\n' "$_bb" "$_la"
    done | tail -1)"
  if [ -n "$brow" ]; then
    bbranch="${brow%%$'\t'*}"; [ "$bbranch" = "-" ] && bbranch=""
    brow="${brow#*$'\t'}"
  fi
fi
tuuid="$(_ccuc "$(_ccpick "$brow" suuid)")"
owner="$(_ccuc "$(_ccpick "$brow" csuuid)")"
case "$tuuid" in *[!0-9A-F-]*) tuuid="" ;; esac

live="$(_cctabs_livemap)"
_cctabs_prune "$live"                    # lazy pruning: rows whose surface is gone (live map only)
tref=""
[ -n "$tuuid" ] && tref="$(printf '%s\n' "$live" | awk -F'\t' -v u="$tuuid" '$2==u{print $1; exit}')"

# ── ①b opened-tabs ledger — the SECOND ledger, consulted whenever the board comes up short ──
# Transition case hit in the first live use of this primitive: a child dispatched BEFORE the
# board carried suuid has a task row with no recorded surface identity at all, so the board
# resolution above yields nothing. The opened-tabs ledger records every tab this stack opened
# (worktree or not) keyed by dir, and carries the owner too — so it fills in BOTH gaps. Both
# ledgers are consulted, board first; they are never deduped against each other.
tabrow="$(_cctabs_by_dir "$ccan" "$cdir")"
tabuuid="$(_cctabs_uc "${tabrow%%$'\t'*}")"; tabowner=""
[ -n "$tabrow" ] && tabowner="$(_cctabs_uc "${tabrow#*$'\t'}")"
case "$tabuuid" in *[!0-9A-F-]*) tabuuid=""; tabowner="" ;; esac
if [ -z "$tref" ] && [ -n "$tabuuid" ]; then
  tref="$(printf '%s\n' "$live" | awk -F'\t' -v u="$tabuuid" '$2==u{print $1; exit}')"
  [ -n "$tref" ] && tuuid="$tabuuid"
fi
if [ -z "$tref" ]; then
  # fallback: cmux agent session store — newest session whose cwd IS this dir (covers tabs the
  # board predates, i.e. rows written before suuid existed)
  suuid_fb="$(python3 - "$cstore" "$ccan" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
d = d.get("sessions") if isinstance(d, dict) else None
if not isinstance(d, dict):
    sys.exit(0)
import os
want = os.path.realpath(sys.argv[2])          # the store may hold the LOGICAL /var form
best = None
for v in d.values():
    if not isinstance(v, dict) or not v.get("cwd"):
        continue
    if os.path.realpath(v["cwd"]) != want:
        continue
    if best is None or (v.get("updatedAt") or 0) > (best.get("updatedAt") or 0):
        best = v
if best and best.get("surfaceId"):
    sys.stdout.write(best["surfaceId"])
PY
)"
  suuid_fb="$(_ccuc "$suuid_fb")"
  if [ -n "$suuid_fb" ]; then
    tref="$(printf '%s\n' "$live" | awk -F'\t' -v u="$suuid_fb" '$2==u{print $1; exit}')"
    [ -n "$tref" ] && tuuid="$suuid_fb"
  fi
fi

# Owner: the board's csuuid is the sub-task record; when it has none (pre-ledger row, or a tab
# that is not a sub-task at all) the opened-tabs ledger's owner for THIS surface stands in.
tabowner_u=""
[ -n "$tuuid" ] && tabowner_u="$(_cctabs_uc "$(_cctabs_owner "$tuuid")")"
[ -n "$owner" ] || owner="$tabowner_u"

# ── ② print the resolution BEFORE acting (never close something you did not name out loud) ──
echo "── close: $cdir ──"
if [ -z "$tuuid" ] || [ -z "$tref" ]; then
  echo "· no live tab resolves to this directory (already closed, or never recorded) — nothing to do"
  # rc stays 0 (the idempotence `gwt-rm --close` relies on), but do not let an INCOMPLETE probe
  # masquerade as "it is gone": say which claim we are actually entitled to make.
  _cctabs_partial "$live" && \
    echo "  (cmux workspace enumeration was incomplete — the tab may be alive in a workspace unseen by this probe)"
  exit 0
fi
echo "  resolved : $tref  uuid=$tuuid  cwd=$ccan"
echo "  recorded : parent=${owner:-<none>}  this-session=${self_uuid:-<no CMUX_SURFACE_ID>}"

# ── ③ policy ──
# A non-worktree directory is a parent / primary-checkout / helper tab. Default: the human's, in
# the cmux UI. ONE exception, and it is the whole point of the opened-tabs ledger: a tab THIS
# session opened itself (a runner in the primary checkout, a scratch-dir tab) is closable by the
# session that opened it — one may close what one opened, worktree or not. Anything without a
# ledger row from this very session keeps the old refusal.
case "$ccan" in
  */.claude/worktrees/*|*/.worktrees/*) ;;
  *) if [ -n "$self_uuid" ] && [ -n "$tabowner_u" ] && [ "$tabowner_u" = "$self_uuid" ]; then
       echo "  (helper tab: not a worktree checkout, but the opened-tabs ledger records THIS session as its opener)"
     else
       echo "✗ refusing: $ccan is not a worktree checkout — parent / primary-checkout tabs are closed by the human in the cmux UI" >&2; exit 1
     fi ;;
esac
if [ -n "$self_uuid" ] && [ "$tuuid" = "$self_uuid" ]; then
  echo "✗ refusing: that surface is THIS session — no automated self-close (2026-08-16 incident)" >&2; exit 1
fi
if _cc_automated; then
  # automated caller (decided by process ancestry, not by an env var). Ownership is the point of
  # the ledger — with ONE unlock: a sub-task whose branch is marked ready (gwt-done) is FINISHED,
  # and a finished sub-task's tab is collectible by any automated caller, not only the session
  # that dispatched it (campaign cleanup routinely outlives the dispatching parent).
  if _cc_rowdone; then
    echo "  (branch $bbranch is marked ready (gwt-done) — a finished sub-task's tab is collectible by any automated caller)"
  else
    [ -n "$owner" ] || { echo "✗ refusing: no dispatching parent recorded for this dir and the branch is not marked ready — treat it as human-opened" >&2; exit 1; }
    [ "$owner" = "$self_uuid" ] || {
      echo "✗ refusing: this tab was dispatched by $owner, not by this session, and its branch is not marked ready (gwt-done) — a live sub-task tab is closable by ITS OWN parent only" >&2; exit 1; }
  fi
else
  [ -n "$owner" ] && [ "$owner" != "$self_uuid" ] && \
    echo "  (human shell: closing a tab dispatched by $owner — ownership check reported, not enforced)"
fi

# ── ④ close by the STABLE uuid ──
# A uuid is resolved inside the caller's WORKSPACE CONTEXT: a target in another workspace used to
# answer "Error: not_found: Surface not found: <uuid>" unless --workspace came along
# (docs/known-issues.md; this build's read-screen does resolve cross-workspace, so the need is
# version-dependent). The bare call stays FIRST — it is the shape every caller and test knows, and
# it is the only one used when the tab is in this workspace — and the workspace the live map just
# told us about is used only to RETRY what would otherwise be a loud failure.
tws="$(_cctabs_where "$live" "$tuuid")"
if cmux close-surface --surface "$tuuid" >/dev/null 2>&1; then
  echo "✔ closed $tref (uuid $tuuid)"
  exit 0
fi
if [ -n "$tws" ] && cmux close-surface --surface "$tuuid" --workspace "$tws" >/dev/null 2>&1; then
  echo "✔ closed $tref (uuid $tuuid, workspace $tws)"
  exit 0
fi
echo "✗ cmux close-surface failed for uuid $tuuid${tws:+ (also retried in $tws)}" >&2
exit 1
;;

# ─────────────────────────────────────────────────────────────────────────────
# tabs — the opened-tabs inventory: every tab this stack opened, joined with live cmux
#   resolution. Answers the question a leader could not answer before ("which tabs did I open,
#   and are they still there?") in the only identity that survives a pane opening or closing.
#   Columns: REF (current short ref, "-" when the tab is gone) | UUID (the stable identity) |
#   STATE (alive/dead) | OWNER (the surface uuid that opened it, "self" marked) | DIR.
#   Reading prunes: rows whose surface no longer resolves are dropped — unless the liveness probe
#   was INCOMPLETE (cmux unreachable, or any workspace that could not be enumerated), in which case
#   nothing is pruned and every unresolved row prints as "dead?" instead of "dead".
# Usage: cc-dispatch.sh tabs [--all]
#   (default) only rows this session opened;  --all  every row in the ledger
# Related env: CC_TABS_FILE (ledger), CC_CALLER_SURFACE_UUID (override for $CMUX_SURFACE_ID)
tabs)
shift
tabs_all=""
if [ "${1:-}" = "--all" ]; then tabs_all=1; shift; fi
[ $# -eq 0 ] || { echo "usage: cc-dispatch.sh tabs [--all]" >&2; exit 2; }

tabs_f="$(_cctabs_file)"
tabs_live="$(_cctabs_livemap)"
tabs_part=""; _cctabs_partial "$tabs_live" && tabs_part=1
_cctabs_prune "$tabs_live"
tabs_self="$(_cctabs_uc "${CC_CALLER_SURFACE_UUID:-${CMUX_SURFACE_ID:-}}")"
echo "── opened tabs ($tabs_f) ──"
[ -f "$tabs_f" ] || { echo "  (no tabs recorded)"; exit 0; }
[ -n "$tabs_live" ] || echo "  ⚠ cmux unreachable — liveness unknown, nothing pruned"
[ -n "$tabs_part" ] && echo "  ⚠ cmux workspace enumeration incomplete — liveness partial, nothing pruned (rows below print dead? rather than dead)"
printf '%-12s  %-36s  %-6s  %-36s  %s\n' REF UUID STATE OWNER DIR
tabs_n=0
while IFS=$'\t' read -r t_u t_o t_d t_s t_ts; do
  [ -n "$t_u" ] || continue
  [ "$t_o" = "-" ] && t_o=""
  if [ -z "$tabs_all" ] && [ -n "$tabs_self" ] && [ "$t_o" != "$tabs_self" ]; then continue; fi
  t_ref="$(printf '%s\n' "$tabs_live" | awk -F'\t' -v u="$t_u" '$2==u{print $1; exit}')"
  if [ -n "$t_ref" ]; then
    t_state="alive"                     # a HIT is solid evidence however partial the probe was
  else
    t_ref="-"; t_state="dead"
    # a MISS is only a claim when the evidence is complete: an unreachable cmux (empty map) and an
    # unreachable workspace (partial map) are both "we could not look there" → dead?, never dead
    { [ -n "$tabs_live" ] && [ -z "$tabs_part" ]; } || t_state="dead?"
  fi
  t_own="${t_o:--}"
  [ -n "$tabs_self" ] && [ "$t_o" = "$tabs_self" ] && t_own="$t_o (self)"
  printf '%-12s  %-36s  %-6s  %-36s  %s\n' "$t_ref" "$t_u" "$t_state" "$t_own" "$t_d"
  tabs_n=$((tabs_n+1))
done < "$tabs_f"
if [ "$tabs_n" -eq 0 ]; then
  if [ -n "$tabs_all" ]; then echo "  (no tabs recorded)"
  else echo "  (no tabs opened by this session — cc-dispatch.sh tabs --all shows every row)"; fi
fi
exit 0
;;

# ─────────────────────────────────────────────────────────────────────────────
# resume — gwt-resume engine (roadmap 2): recorded-args session resume after cmux died/restarted.
#   ① cmux native restore first (cmux restore-session; output opaque, fail-soft — nothing to
#      restore must not abort the run)
#   ② board rows whose tab is back: surface ref refreshed. Matching is uuid-first against the
#      cmux agent session store (~/.cmuxterm/claude-hook-sessions.json: session id → surfaceId
#      UUID + cwd, read via CC_CMUX_SESSIONS override) joined with cmux list-pane-surfaces
#      --id-format both (surface UUID → live short ref), then canonical-cwd fallback
#   ③ rows still without a tab: reopened through surface (single tab-opening source of truth,
#      CC_WT_LAUNCH_CMD) with the RECORDED args replayed as
#      `cld <provider> --resume <uuid> --permission-mode <pm> [--model <m>]` — plain-claude rows
#      resume without cld; flags not recorded are omitted; rows with NO recorded uuid (pre-feature)
#      degrade to an idle ccteam tab, visibly listed as such
#   ④ stale agent-state rows (worktree-status.tsv) cleared for dirs whose tab came back THIS run
#   ⑤ lists BRANCH | summary | dir | disposition first, then ONE y/N (rows to re-open only);
#      --all skips the confirm AND the repo filter
#   HARD INVARIANT: step ③ launches in the board's RECORDED dir string verbatim (surface's
#   --working-directory) — claude keys project identity/trust/CLAUDE.md on the exact path string,
#   so /Users vs /private is a different project; NEVER re-resolve from repo/branch. The cd+pwd -P
#   inside surface is idempotent on the already-canonical recorded form.
# Usage: cc-dispatch.sh resume [--all]
# Related env: CC_RESUME_SETTLE (seconds to wait after native restore for surfaces to register,
#   default 2, 0 in tests), CC_CMUX_SESSIONS (agent session store path)
resume)
shift
res_all=""
if [ "${1:-}" = "--all" ]; then res_all=1; shift; fi
[ $# -eq 0 ] || { echo "usage: cc-dispatch.sh resume [--all]" >&2; exit 2; }
command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 || {
  echo "✗ can't reach cmux, aborting (gwt-resume reopens tabs — it needs cmux)" >&2; exit 1; }

tasks="${CC_TASKS_FILE:-$HOME/.config/cc-stack/worktree-tasks.tsv}"
statusf="${CC_STATUS_FILE:-$HOME/.config/cc-stack/worktree-status.tsv}"
ccb_canon(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }   # same canonicalization as the board

# ── ① native restore (fail-soft) ──
echo "── ① cmux native restore (restore-session) ──"
res_out="$(cmux restore-session 2>&1)"; res_rc=$?
if [ "$res_rc" -eq 0 ]; then
  [ -n "$res_out" ] && printf '%s\n' "$res_out" | sed 's/^/   /'
  echo "✔ restore-session ran"
else
  echo "· nothing restored natively (rc $res_rc) — continuing with the board-driven reopen"
fi
sw="${CC_RESUME_SETTLE:-2}"; case "$sw" in ''|*[!0-9]*) sw=2 ;; esac
[ "$sw" -gt 0 ] && sleep "$sw"

# ── ② live-surface map + agent session store ──
# "UUID<TAB>ref" pairs keyed by the STABLE uuid (short refs are session-scoped), via the SAME
# workspace-union probe the opened-tabs prune uses — a bare list-pane-surfaces sees the caller's
# workspace only, so a tab cmux restored into another workspace looked absent and this step
# reopened a DUPLICATE of a tab that was already back. The "!partial" sentinel line has one field
# and is dropped by NF>=2; a partial map only costs a duplicate tab here (visible, not destructive),
# which is why resume does not refuse on it the way the prune does.
live_pairs="$(_cctabs_livemap | awk -F'\t' 'NF>=2{print $2 "\t" $1}')"
# session store: claude session id (key) → surfaceId UUID + cwd (+ updatedAt for newest-wins).
# Absent/unreadable → no native matching at all; every unrestored row simply goes to reopen.
store="${CC_CMUX_SESSIONS:-$HOME/.cmuxterm/claude-hook-sessions.json}"
store_rows=""
if [ -f "$store" ]; then
  store_rows="$(python3 - "$store" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
# The store is NESTED: top level holds activeSessionsBySurface / activeSessionsByWorkspace /
# sessions / version(int); the per-session records (surfaceId, cwd, updatedAt, keyed by the
# claude session uuid) live ONE LEVEL DOWN, under d["sessions"]. Descend or bail — iterating
# the top level would crash on the int version key (AttributeError) and never see a record.
d = d.get("sessions")
if not isinstance(d, dict):
    sys.exit(0)
for k, v in sorted(d.items(), key=lambda kv: kv[1].get("updatedAt") or 0):
    if not isinstance(v, dict):
        continue
    sid = v.get("surfaceId") or ""
    cwd = v.get("cwd") or ""
    if sid and cwd:
        sys.stdout.write("%s\t%s\t%s\t%s\n" % (sid, k, cwd, v.get("updatedAt") or 0))
PY
)"
fi
# canonicalize each store cwd once, then join with live pairs → "canon-cwd<TAB>live-ref<TAB>session-id"
store_map=""
if [ -n "$store_rows" ]; then
  while IFS=$'\t' read -r sm_surf sm_sess sm_cwd sm_upd; do
    [ -n "$sm_surf" ] || continue
    sm_can="$(ccb_canon "$sm_cwd")"; [ -n "$sm_can" ] || sm_can="$sm_cwd"
    store_map="${store_map}${sm_can}	${sm_surf}	${sm_sess}	${sm_upd}
"
  done <<< "$(printf '%s\n' "$store_rows")"
fi
cand=""
if [ -n "$store_map" ] && [ -n "$live_pairs" ]; then
  _t1="${TMPDIR:-/tmp}/ccres.lp.$$"; _t2="${TMPDIR:-/tmp}/ccres.sm.$$"
  printf '%s\n' "$live_pairs" > "$_t1"; printf '%s\n' "$store_map" > "$_t2"
  cand="$(awk -F'\t' 'NR==FNR{lp[$1]=$2; next} ($2 in lp){print $1 "\t" lp[$2] "\t" $3}' "$_t1" "$_t2")"
  rm -f "$_t1" "$_t2"
fi

# ── board rows: newest per canonical dir, dir exists, repo filter (off with --all) ──
[ -f "$tasks" ] || { echo "no registered worktree tasks (nothing to resume)"; exit 0; }
repo_root=""
if [ -z "$res_all" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$repo_root" ]; then
    repo_root="$(ccb_canon "$repo_root")"
    [ -n "$repo_root" ] || repo_root=""
  fi
fi
# Field extraction via awk, NOT a bash read loop: bash (and zsh) collapse consecutive TAB
# delimiters, so a row with an empty caller field would shift every later field.
task_rows="$(tail -r "$tasks" | awk -F'\t' '$4 != "" { print $4 "\t" $2 "\t" $3 "\t" $6 "\t" $8 }')"
rows=""; seen_dirs=""
while IFS=$'\t' read -r r_dir r_br r_ref r_task r_largs; do
  [ -n "$r_dir" ] || continue
  c="$(ccb_canon "$r_dir")"; [ -n "$c" ] || c="$r_dir"
  printf '%s\n' "$seen_dirs" | grep -qxF -- "$c" && continue     # newest row per dir wins
  seen_dirs="$seen_dirs$c
"
  [ -d "$r_dir" ] || continue                                    # gone dirs: prune's business
  if [ -n "$repo_root" ]; then
    case "$c" in "$repo_root"|"$repo_root"/*) ;; *) continue ;; esac
  fi
  rows="${rows}${c}	${r_dir}	${r_br}	${r_ref}	${r_task}	${r_largs}
"
done <<< "$(printf '%s\n' "$task_rows")"

# ── helpers (bash 3.2 safe; awk-keyed rewrites under the shared mkdir lock) ──
_ccres_keys(){ # $1 = file, $2 = field no, $3 = canon dir → prints the RAW values whose field
               # canonicalizes to $3 (exact-string keyed downstream; survives empty fields)
  awk -F'\t' -v fn="$2" '{ print $(fn) }' "$1" 2>/dev/null | sort -u | while IFS= read -r _k; do
    [ -n "$_k" ] || continue
    _kc="$(ccb_canon "$_k")"; [ -n "$_kc" ] || _kc="$_k"
    [ "$_kc" = "$3" ] && printf '%s\n' "$_k"
  done
  return 0
}
_ccres_setref(){ # $1 = canon dir, $2 = new ref, $3 = new surface uuid ("" = leave suuid alone) —
                 # rewrite field 3 (surface) and refresh the launch-args suuid on EVERY row of that
                 # dir. Surface UUIDs are minted per surface, so a cmux restart invalidates the
                 # recorded one; leaving it stale would make the tab-close gate refuse a legitimate
                 # parent close (fail-closed, but wrong) — the ledger must track the new tab.
  f="$tasks"; [ -f "$f" ] || return 0
  lock="$f.lock"; got=""
  i=0; while [ "$i" -lt 60 ]; do mkdir "$lock" 2>/dev/null && { got=1; break; }; sleep 0.05; i=$((i+1)); done
  match="$f.match.$$"; _ccres_keys "$f" 4 "$1" > "$match"
  tmp="$f.tmp.$$"
  # NB: the match keys are read via getline-in-BEGIN, NOT the usual NR==FNR idiom — with an
  # EMPTY match file that idiom never flips and would rewrite/drop EVERY row (a dir with no
  # row in this file must leave it untouched).
  awk -v r="$2" -v su="${3:-}" -v mf="$match" -F'\t' -v OFS='\t' '
    function setsuuid(la, u,   i, n, seg, pre, mod, out) {
      mod = ""; pre = la
      i = index(la, "model=")                       # model is composed LAST and may hold colons
      if (i > 0) { mod = substr(la, i); pre = substr(la, 1, i-1); sub(/:$/, "", pre) }
      out = ""; n = split(pre, seg, ":")
      for (i = 1; i <= n; i++) {
        if (seg[i] == "" || seg[i] ~ /^suuid=/) continue
        out = (out == "" ? seg[i] : out ":" seg[i])
      }
      out = (out == "" ? "suuid=" u : out ":suuid=" u)
      return (mod == "" ? out : out ":" mod)
    }
    BEGIN{while((getline l < mf) > 0) m[l]=1; close(mf)}
    m[$4]{ $3=r; if (su != "") $8 = setsuuid($8, su) } {print}' "$f" > "$tmp"
  mv "$tmp" "$f"; [ -s "$f" ] || rm -f "$f"
  rm -f "$match"
  [ -n "$got" ] && rmdir "$lock" 2>/dev/null
  return 0
}
_ccres_dropstatus(){ # $1 = canon dir — drop the agent-state sidecar rows of that dir
  f="$statusf"; [ -f "$f" ] || return 0
  lock="$f.lock"; got=""
  i=0; while [ "$i" -lt 60 ]; do mkdir "$lock" 2>/dev/null && { got=1; break; }; sleep 0.05; i=$((i+1)); done
  match="$f.match.$$"; _ccres_keys "$f" 1 "$1" > "$match"
  tmp="$f.tmp.$$"
  awk -v mf="$match" 'BEGIN{while((getline l < mf) > 0) m[l]=1; close(mf)} !m[$1]' "$f" > "$tmp"
  mv "$tmp" "$f"; [ -s "$f" ] || rm -f "$f"
  rm -f "$match"
  [ -n "$got" ] && rmdir "$lock" 2>/dev/null
  return 0
}
_ccres_parse(){ # $1 = launch-args field → _u/_p/_pm/_m globals; empty when absent/invalid.
                # model is composed LAST by the writer, so it may itself contain colons.
  _u=""; _p=""; _pm=""; _m=""
  [ -n "$1" ] || return 0
  _pre="$1"
  case "$1" in
    *model=*) _m="${1#*model=}"; _pre="${1%%model=*}" ;;
  esac
  _oifs="$IFS"; IFS=':'
  for _seg in $_pre; do
    case "$_seg" in
      uuid=*)     _u="${_seg#uuid=}" ;;
      provider=*) _p="${_seg#provider=}" ;;
      pm=*)       _pm="${_seg#pm=}" ;;
    esac
  done
  IFS="$_oifs"
  # replay-safe or dropped — a dropped value degrades visibly (listing shows the real command)
  case "$_u"  in *[!0-9a-fA-F-]*|"") _u="" ;; esac
  case "$_p"  in ""|.*|*..*|*[!A-Za-z0-9._-]*) _p="" ;; esac
  case "$_pm" in plan|auto|acceptEdits|bypassPermissions|manual|dontAsk) ;; *) _pm="" ;; esac
  case "$_m"  in *[!A-Za-z0-9._\[\]-]*) _m="" ;; esac
  return 0
}

# ── disposition per row ──
# "canon<TAB>dir<TAB>branch<TAB>task<TAB>action<TAB>ref-to-apply<TAB>launch-cmd"
plan=""; n_rest=0; n_re=0; n_live=0
while IFS=$'\t' read -r c r_dir r_br r_ref r_task r_largs; do
  [ -n "$c" ] || continue
  _ccres_parse "$r_largs"
  live_ref=""
  if [ -n "$_u" ] && [ -n "$cand" ]; then      # (a) recorded uuid == store key (strongest match)
    live_ref="$(printf '%s\n' "$cand" | awk -F'\t' -v s="$_u" '$3==s{r=$2} END{print r}')"
  fi
  if [ -z "$live_ref" ] && [ -n "$cand" ]; then # (b) newest live session in that canonical dir
    live_ref="$(printf '%s\n' "$cand" | awk -F'\t' -v d="$c" '$1==d{r=$2} END{print r}')"
  fi
  if [ -n "$live_ref" ]; then
    act="restored"
    [ "$_p" != "" ] && [ "$_p" != "anthropic" ] && act="restored-warn"
    # refresh BOTH the short ref and the recorded surface uuid — a restored tab is a NEW surface
    live_uuid="$(printf '%s\n' "$live_pairs" | awk -F'\t' -v r="$live_ref" '$2==r{print $1; exit}')"
    _ccres_setref "$c" "$live_ref" "$live_uuid"
    _ccres_dropstatus "$c"
    plan="${plan}${c}	${r_dir}	${r_br}	${r_task}	${act}	${live_ref}
"
    n_rest=$((n_rest+1))
    continue
  fi
  if [ -n "$r_ref" ] && printf '%s\n' "$live_pairs" | awk -F'\t' -v r="$r_ref" '$2==r{f=1} END{exit f?0:1}'; then
    plan="${plan}${c}	${r_dir}	${r_br}	${r_task}	already-live	${r_ref}
"
    n_live=$((n_live+1))
    continue
  fi
  # (c) no tab anywhere → reopen with the recorded args (degrade to idle when no uuid)
  if [ -n "$_u" ]; then
    case "$_p" in
      ""|anthropic|default) lcmd="ccteam" ;;
      *)                    lcmd="cld $_p" ;;
    esac
    lcmd="$lcmd --resume $_u"
    [ -n "$_pm" ] && lcmd="$lcmd --permission-mode $_pm"
    [ -n "$_m" ] && lcmd="$lcmd --model $_m"
    act="reopen"
  else
    lcmd="ccteam"
    act="reopen-idle"
  fi
  plan="${plan}${c}	${r_dir}	${r_br}	${r_task}	${act}	-	${lcmd}
"
  n_re=$((n_re+1))
done <<< "$(printf '%s\n' "$rows")"

[ -n "$plan" ] || { echo "no resumable board rows (current repo; try --all)"; exit 0; }

# ── ⑤ list, then ONE confirm for the re-opens (--all skips both repo filter and confirm) ──
echo "── ② board rows ──"
disp(){ case "$1" in
    restored)      echo "$2" ;;
    restored-warn) echo "$2 (⚠ native restore is provider-blind — if env was lost, close the tab and rerun gwt-resume)" ;;
    reopen)        echo "↻ re-open: $3" ;;
    reopen-idle)   echo "⚠ no recorded session → idle ccteam (row predates gwt-resume recording)" ;;
    already-live)  echo "✔ already live: $2" ;;
  esac; }
res_list=""
while IFS=$'\t' read -r c r_dir r_br r_task r_act r_ref r_cmd; do
  [ -n "$c" ] || continue
  res_list="${res_list}$(printf '%s|%s|%s|%s' "$r_br" "$r_task" "$r_dir" "$(disp "$r_act" "$r_ref" "$r_cmd")")"$'\n'
done <<< "$(printf '%s\n' "$plan")"
printf 'BRANCH|SUMMARY|DIR|DISPOSITION\n%s' "$res_list" | column -t -s '|'

if [ "$n_re" -gt 0 ]; then
  if [ -z "$res_all" ]; then
    printf "Re-open %d tab(s) as listed? [y/N] " "$n_re"
    IFS= read -r ans
    case "$ans" in y|Y) ;; *) echo "aborted — nothing re-opened (native restores above stand)"; exit 1 ;; esac
  fi
  echo "── ③ re-open with recorded args ──"
  while IFS=$'\t' read -r c r_dir r_br r_task r_act r_ref r_cmd; do
    [ -n "$c" ] || continue
    [ "$r_act" = "reopen" ] || [ "$r_act" = "reopen-idle" ] || continue
    # HARD INVARIANT: $r_dir is the board's RECORDED dir string, passed VERBATIM to surface
    # (--working-directory); never re-resolved from repo/branch — claude keys project identity
    # on the exact path string.
    out="$(CC_WT_LAUNCH_CMD="$r_cmd" "$HOME/.config/cc-stack/cc-dispatch.sh" surface "$r_dir" "")"
    newref="$(printf '%s\n' "$out" | grep -oE 'surface:[0-9]+' | head -1)"
    # the reopened tab's STABLE uuid (surface prints it; a fresh join covers older output forms)
    newuuid="$(printf '%s\n' "$out" | awk 'match($0,/uuid=[0-9A-Fa-f-]+/){print substr($0,RSTART+5,RLENGTH-5); exit}')"
    [ -n "$newuuid" ] || newuuid="$(cmux list-pane-surfaces --id-format both 2>/dev/null | sed 's/^\*//' \
      | awk -v r="$newref" 'NF>=2 && $1==r{print $2; exit}')"
    if [ -n "$newref" ]; then
      _ccres_setref "$c" "$newref" "$newuuid"
      _ccres_dropstatus "$c"
      echo "✔ $r_br → $newref  ($([ "$r_act" = "reopen-idle" ] && echo "idle ccteam — no session recorded" || echo "resumed: $r_cmd"))"
    else
      echo "⚠ $r_br: surface failed to open a tab for $r_dir (see cc-failures.log)"
    fi
  done <<< "$(printf '%s\n' "$plan")"
fi
echo "✔ resume done: $n_rest restored natively, $n_live already live, $n_re re-opened by us"
exit 0
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

# ── Commit gate ── same as the surface path: gwt-new / gwt-adopt reach a brand-new worktree through
# here, so this is the second (and last) place a cc-stack worktree gets created. Before the dedup
# below, so a re-run on an already-open workspace still repairs a missing gate.
_cc_commit_gate_auto "$abspath"

# Dedup (best effort): if this absolute path already shows up in the workspace list, don't open again
if cmux list-workspaces 2>/dev/null | grep -qF "$abspath"; then
  exit 0
fi

# --id-format both makes the receipt carry the STABLE surface uuid of the workspace's first tab
# next to its short ref, which is what the opened-tabs ledger records (a workspace opened for a
# directory IS a tab this stack opened, so it belongs in the ledger exactly like a `surface` open).
# Older cmux builds that reject the flag simply get the call again without it; a receipt we cannot
# parse means no ledger row and NO behaviour change — the workspace still opens.
# (No `exec` any more: the receipt has to be read before this process may leave.)
wsout="$(cmux new-workspace --name "$name" --cwd "$abspath" --focus "$focus" --id-format both 2>/dev/null)"
wsrc=$?
if [ "$wsrc" != 0 ] || [ -z "$wsout" ]; then
  wsout="$(cmux new-workspace --name "$name" --cwd "$abspath" --focus "$focus" 2>&1)"; wsrc=$?
fi
[ -n "$wsout" ] && printf '%s\n' "$wsout"
[ "$wsrc" = 0 ] || exit "$wsrc"

# Same FIELD-position parse as the surface path (never a sed pattern mixing literal parens with
# wildcards — docs/known-issues.md, BSD sed), with a list-pane-surfaces join as the fallback.
wsuuid="$(printf '%s\n' "$wsout" | awk '{for(i=1;i<NF;i++) if ($i ~ /^surface:[0-9]+$/) {u=$(i+1); gsub(/[()]/,"",u); if (u ~ /^[0-9A-Fa-f-]+$/ && length(u) >= 30) {print u; exit}}}')"
if [ -z "$wsuuid" ]; then
  wsref="$(printf '%s\n' "$wsout" | grep -oE 'surface:[0-9]+' | head -1)"
  [ -n "$wsref" ] && wsuuid="$(_cctabs_livemap | awk -F'\t' -v r="$wsref" '$1==r{print $2; exit}')"
fi
_cctabs_log "$wsuuid" "${CC_CALLER_SURFACE_UUID:-${CMUX_SURFACE_ID:-}}" "$abspath" ""
exit 0
;;

# ─────────────────────────────────────────────────────────────────────────────
# commit-gate — mount/unmount THE commit gate on the repo that contains <dir>. The dispatch paths
#   call the same code automatically; this subcommand is the human's handle on it (install.sh uses
#   it too, and `unmount` makes the whole mechanism reversible without hand-editing .git/hooks).
# Usage: cc-dispatch.sh commit-gate mount|unmount <dir>
commit-gate)
shift
[ $# -ge 2 ] || { echo "usage: cc-dispatch.sh commit-gate mount|unmount <dir>" >&2; exit 2; }
_cc_commit_gate "$1" "$2"; exit $?
;;

*)
  echo "usage: cc-dispatch.sh wt-claude <name> <prompt> [--prefix <p>] [--base <b>] | surface <path> [prompt] | send <surface-ref> \"<text>\" | calibrate <surface-ref> [label] | close <worktree-dir> | tabs [--all] | resume [--all] | workspace <path> [name] [focus] | commit-gate mount|unmount <dir>" >&2; exit 2 ;;
esac
