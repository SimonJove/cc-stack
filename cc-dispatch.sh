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
#   input line = queued-message hint    → the target ALREADY holds queued messages, i.e. it IS
#                                         working — same terminal state as the busy fast-path:
#                                         send NOW and report "(queued)", never hold, never verify
#                                         (patterns: CC_SEND_QUEUED_PATTERNS)
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

# Queued-message patterns (hardening layer 6, 2026-08-23) — the OTHER thing a claude input box
# renders instead of a draft. When the target has messages QUEUED, the box holds no text at all;
# it holds a HINT, drawn inside the box with the ordinary prompt prefix:
#
#     ────────────────────────────────────────────
#     ❯ Press up to edit queued messages          ← live probe, byte-exact: ❯ + ASCII space + text
#     ────────────────────────────────────────────
#
# To the bottom-up scan in _ccsend_eval that is indistinguishable from "someone left a draft in
# the box" — which is exactly how it produced the parked FALSE ALARM of 2026-08-22 23:16 (the
# breadcrumb's matched line was this hint verbatim). So the verdict has a THIRD value: the hint is
# matched against the post-prompt REST of the input line (never against the raw line — the input
# patterns above own the prompt end of it, and widening THEM would weaken real parked detection,
# which is the one thing this must not do). Same list contract as the two lists above:
# CC_SEND_QUEUED_PATTERNS (colon-separated ERE list) REPLACES the default, entries auto-anchor to
# the START of the rest, and empty entries are SKIPPED — an empty ERE matches every rest, which
# would classify a genuinely parked draft as "queued" and silence the true positives.
#
# Live probe 2026-08-23 (claude 2.1.233 + cmux, own tab, 45 frames/s across an idle→send→queued
# transition), which is also why this cannot be fixed by widening the busy fast-path instead:
#   frame  state
#   s0001  busyhit MISS, box "❯ " empty              ← the gate reads here: the target IS idle
#   s0003  busyhit MISS, box "❯ Press up …"          ← +45ms: queued ALREADY, and still no hit
#   s0040  busyhit HIT,  box "❯ Press up …"          ← +0.8s: only now does busyhit see anything
# The send ITSELF is what makes the target work (cmux's `send` submits on every embedded newline,
# so a multi-line payload's first line starts a turn and the rest lands in the queue) — a target
# that reads idle at the gate can be queueing 45ms later. And busyhit is blind for that first
# ~1s because a turn OPENS with a duration-less working line, byte-exact from the same probe:
#     "\xe2\x9c\xbd Zesting\xe2\x80\xa6 "   →  ✽ Zesting…      (glyph, gerund, ellipsis, no parens)
# while CCSEND_BUSY_PATTERNS_DEFAULT requires "([0-9]+[smh]" — the duration only appears once the
# turn is ~1s old. Widening THAT list is the wrong lever anyway: busyhit matches ANY line of the
# capture, so a looser "<glyph> <word>…" entry would also fire on transcript prose, and a busyhit
# hit SKIPS the post-send verify entirely — it would buy this window at the cost of every parked
# message elsewhere. The hint is up from the first frame, sits in the input box where only the
# live composer renders, and is the earlier, narrower, harder signal.
CCSEND_QUEUED_PATTERNS_DEFAULT='^Press up to edit queued messages'

_ccsend_eval() {       # stdin: screen text → "empty<TAB>line" | "busy<TAB>line" | "queued<TAB>line"
                       # | "unknown" (the state evaluator; the line text after the tab feeds the
                       # blocked-by preview of the hold notify — read-only reuse of the same
                       # capture, the delivered text never passes through here. "unknown"
                       # deliberately carries NO tab so exact string compares against it keep
                       # working, _ccsend_calibrate)
  awk -v pl="${CC_SEND_INPUT_PATTERNS:-$CCSEND_PATTERNS_DEFAULT}" \
      -v ql="${CC_SEND_QUEUED_PATTERNS:-$CCSEND_QUEUED_PATTERNS_DEFAULT}" '
    BEGIN {
      n = split(pl, P, ":")
      nq = split(ql, Q, ":")
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
            st = (rest ~ /^[ \t\r]*$/) ? "empty" : "busy"
            if (st == "busy")                # a non-empty box is only a DRAFT if it is not the
              for (k = 1; k <= nq; k++) {    # queued-message hint (see the block comment above)
                q = Q[k]; sub(/^\^/, "", q)
                if (q == "") continue        # empty entry: an empty ERE matches EVERY rest → every
                                             # parked draft would read "queued" and the true
                                             # positives would go silent. Skip, exactly like above.
                if (match(rest, "^" q)) { st = "queued"; break }
              }
            print st "\t" rest
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
                       # rc 2 = QUEUED: the box holds the queued-message HINT, not a draft — the
                       # send landed and the target is working through its queue. This is the
                       # empty-path twin of the busy fast-path's legal end state, and it is
                       # reachable on BOTH re-reads: the target goes idle → queued inside the send
                       # itself (probed 2026-08-23, see CCSEND_QUEUED_PATTERNS_DEFAULT), and the
                       # ONE Enter retry can submit a genuinely parked draft into a target that is
                       # working by then. No retry is fired on a queued box — there is nothing in
                       # it to submit, and the queue is not ours to poke.
  local ref verdict w line_text _ccsend_crumb_txt
  ref="$1"
  w="${CC_SEND_VERIFY_SEC:-1}"; case "$w" in ''|*[!0-9.]*|.*|*.|*.*.*) w=1 ;; esac
  sleep "$w"
  verdict="$(cmux read-screen --surface "$ref" --lines "$CCSEND_LINES" 2>/dev/null | _ccsend_eval)"
  line_text="${verdict#*$'\t'}"  # F2 fix: capture the matched line text for the breadcrumb
  case "${verdict%%$'\t'*}" in
    queued) return 2 ;;                                                 # delivered, target working
    busy) cmux send-key --surface "$ref" Enter >/dev/null 2>&1 || true   # the ONE retry
          sleep "$w"
          verdict="$(cmux read-screen --surface "$ref" --lines "$CCSEND_LINES" 2>/dev/null | _ccsend_eval)"
          line_text="${verdict#*$'\t'}"
          case "${verdict%%$'\t'*}" in
            queued) return 2 ;;                                         # the retry submitted it
            busy) # F2 fix: include the matched line text (truncated to 120 chars, TAB/newlines stripped) in the breadcrumb
                  _ccsend_crumb_txt="$(printf '%s' "$line_text" | tr '\t' ' ' | tr '\n' ' ' | cut -c1-120)"
                  echo "✗ cc-send: sent to $ref but the input line still holds text after one Enter retry — the message may be parked in the composer; finish it by hand (see docs/known-issues.md)" >&2
                  _ccsend_crumb "$ref" "cc-send parked after send: input line still non-empty after one Enter retry (matched line: \"$_ccsend_crumb_txt\") — see docs/known-issues.md"
                  return 1 ;;
          esac ;;
  esac
  return 0
}

_ccsend() {            # $1 = surface ref, $2 = text — the gate loop
  local ref text to hb pv start now next_at scr verdict line dur prev vrc
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
      queued) # queued fast-path: the box holds the queued-message hint, so the target is working
              # even though its working indicator has not rendered yet (it lags by ~0.8s — probed
              # 2026-08-23). Same terminal state as the busy fast-path above: send now, no hold
              # (holding for a hint that only clears when the target drains its queue is pointless),
              # no notify, no post-send verify.
              _ccsend_raw "$ref" "$text" && echo "✔ cc-send: delivered to $ref (queued — target working)"
              return $? ;;
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
  # H3: CC_SEND_NOVERIFY=1 skips the post-send verify for callers that knowingly target a SHELL
  # (the two launch sends in `surface`): a ❯-prompt shell (starship / p10k default) echoes the
  # typed launch command, the bottom-up scan reads that echo as a busy composer, and verify would
  # false-alarm + Enter-retry a tab that never had a composer at all. The gate semantics above
  # are untouched — only the empty-path verify is skippable, and only by explicit opt-in.
  # Skipping verify also skips its ONE Enter retry — deliberate (round 2, gate question):
  # _ccsend_raw already sends its own Enter, so parked launch text is submitted by that; and
  # launch sends here were historically plain fail-open (no verify, no retry) with no known
  # parking case the retry ever saved.
  vrc=0; [ "${CC_SEND_NOVERIFY:-0}" = "1" ] || { _ccsend_verify "$ref"; vrc=$?; }
  case "$vrc" in
    0) echo "✔ cc-send: delivered to $ref" ;;
    2) echo "✔ cc-send: delivered to $ref (queued — target working)" ;;   # verify saw the hint
    *) return 1 ;;
  esac
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
#
# STATE ACCESS (state-model Phase A): every read/write of the four TSV stores — this ledger
# included — goes through the cc-state facade; what stays in THIS file is cmux PROBING (the live
# map and its completeness) and the orchestration that decides on top of both. Writes: tab-add;
# reads: tab-list / tab-resolve / tab-owner; the prune: tab-prune (it takes the RAW live map and
# recognizes the !partial sentinel itself, so the invariant below travels with the evidence).
_cctabs_uc(){ printf '%s' "${1:-}" | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'; }
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
  # No "is there a ledger?" precheck: an empty store makes cc-state tab-prune a no-op that
  # creates nothing, so asking the facade first would only spend a python start to save one.
  # (The precheck that used to sit here stat'ed the ledger FILE — the thing this file is no
  # longer allowed to know the name of.)
  _tlm="${1:-$(_cctabs_livemap)}"
  [ -n "$_tlm" ] || return 0                              # no map = no evidence = no pruning
  # INVARIANT (2026-08-16): absence of evidence is NEVER evidence of death, and it only ever gets
  # stronger. An empty map already pruned nothing; a PARTIAL map — one workspace enumerated, another
  # unreachable — prunes nothing either, genuinely dead rows included. Deleting a live row is
  # irreversible (its owner is gone, `close` fail-closes, a human has to clean up in the UI);
  # keeping a dead row costs one stale line that the next COMPLETE read sweeps. Never weaken this
  # into "prune within the workspaces we could see". The guard itself now lives in the facade:
  # cc-state tab-prune recognizes the !partial sentinel in the RAW map handed to it (a caller that
  # pre-extracted a uuid list would have thrown the completeness bit away), and an empty key set
  # prunes nothing there for the same reason it did here.
  # The facade path resolves like CC_SELF does at the top of this script — this function is also
  # lifted out and SOURCED by test.sh (§21), where CC_SELF is unset and $0 is the test runner.
  _tl_c="${CC_SELF:-}"
  [ -n "$_tl_c" ] || _tl_c="$( (CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) 2>/dev/null )"
  [ -n "$_tl_c" ] || _tl_c="$HOME/.config/cc-stack"
  _tl_m="$(mktemp "${TMPDIR:-/tmp}/cctabs-prune.XXXXXXXX")" || return 0
  printf '%s\n' "$_tlm" > "$_tl_m" 2>/dev/null && "$_tl_c/cc-state" tab-prune "$_tl_m" 2>/dev/null
  rm -f "$_tl_m" 2>/dev/null
  return 0
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
  # submodule guard — TWO criteria, OR'd (gate round 4): inside a SUBMODULE, --git-common-dir
  # answers <super>/.git/modules/<name>, whose parent is .git/modules — neither the submodule
  # worktree nor anything a repo filter wants, and every row would filter out ("no records").
  #   (a) --show-superproject-working-tree non-empty — a submodule CHECKOUT (gate-verified
  #       across six shapes: empty for a plain repo, in-repo/out-of-repo worktrees,
  #       --separate-git-dir, and production worktrees);
  #   (b) the computed root does not CONTAIN the target — catches a submodule's LINKED worktree
  #       (/super/sub/.claude/worktrees/x): the superproject check is EMPTY there, yet the
  #       common-dir parent (.git/modules) still isn't a repo root; bec2f41's --show-toplevel
  #       showed that shape its own row, so not falling back there is a regression.
  # Either criterion → fall back to --show-toplevel. --separate-git-dir keeps the resolution
  # above (root contains the target, superproject empty) — bec2f41-identical. The fallback
  # cd's only on a NON-EMPTY toplevel: bash `cd -- ""` succeeds in place, so an empty answer
  # must never reach the subshell or it hands back the CALLER's pwd.
  _ccsup="$(git -C "$1" rev-parse --show-superproject-working-tree 2>/dev/null)"
  _cctgt="$( (CDPATH= cd -- "$1" 2>/dev/null && pwd -P) 2>/dev/null )"
  case "$_cctgt/" in ""|"$_ccgr"/*) _ccin="" ;; *) _ccin=1 ;; esac
  if [ -n "$_ccsup" ] || [ -n "$_ccin" ]; then
    _cctop="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$_cctop" ]; then
      _ccfb="$( (CDPATH= cd -- "$_cctop" 2>/dev/null && pwd -P) 2>/dev/null )"
      [ -n "$_ccfb" ] && _ccgr="$_ccfb"
    fi
  fi
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
# 4th arg = the explicit base: when --base names a branch it IS the recorded merge target (the
# skill's documented contract). The default "HEAD" names no branch, so the caller's cwd stays the
# fallback — see cmd_capture for why cwd alone cannot be trusted after a fast-forward.
# capture-dispatch echoes what got recorded (✔/⚠ + source) and warns when the base was unusable
# (F4); a reused branch keeps its earlier --base target instead of being overwritten (F6).
"$CC_SELF/cc-merge.sh" capture-dispatch "$root" "$branch" "$PWD" "$base"

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
  echo "[$(date '+%F %T')] $abspath — $1" >> "${CC_SEND_FAILLOG:-$HOME/.config/cc-stack/cc-failures.log}" 2>/dev/null || true
  command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 \
    && cmux notify --title "cc-stack: worktree tab failed" --body "$abspath — $1" >/dev/null 2>&1 || true
}

# Must be able to reach cmux; short retry to ride out cmux's transient hiccups/restart window (don't rely on CMUX_SOCKET — often empty in CC's Bash env)
# No cmux binary at all = the remote-SSH no-op case → exit 0 (plain worktree, no tab, nothing failed).
# cmux PRESENT but unreachable after the retries = the tab genuinely failed to open → F6 fix: exit 1,
# the SAME rc as the new-surface failure below. wt-claude exec's into this script, so this rc IS
# gwt-claude's rc — the caller deserves to hear "no tab" instead of success. The hook path swallows
# rc either way (cc-hooks.sh:267 redirects all output), so only the gwt-claude path is affected.
command -v cmux >/dev/null 2>&1 || exit 0
ok=""; for _ in 1 2 3 4 5 6; do cmux ping >/dev/null 2>&1 && { ok=1; break; }; sleep 0.4; done
[ -n "$ok" ] || { _fail "cmux ping unreachable (likely restarting), no tab opened"; exit 1; }

# Dedup (best effort): if a tab was opened for this dir within 120s, don't repeat. Only CHECK here;
# task-mark-opened stamps it after success (failures leave no blocking marker). SKIPPED in resume
# mode: a marker left by the pre-crash dispatch is exactly what must not eat the reopen.
if [ -z "$rsmode" ] && "$CC_SELF/cc-state" task-opened-recently "$abspath" 120; then
  exit 0
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

# Record the merge target — HOOK PATH ONLY (parent = the base named on the `git worktree add`
# line when it names a branch, else the caller's branch; cc-hooks.sh parses the base out of the
# command and hands it over as CC_WT_BASE).
# On the gwt-claude path CC_CALLER_CWD is unset and wt-claude above already
# captured with the real caller cwd; skipping here avoids overwriting it.
if [ -n "${CC_CALLER_CWD:-}" ] && command -v git >/dev/null 2>&1; then
  _root="$(_cc_gitroot "$abspath")" || _root=""     # same caveat as above: resolve against $abspath
  _br="$(git -C "$abspath" symbolic-ref --short HEAD 2>/dev/null)"
  # CC_CAPTURE_CRUMB=1: the hook swallows this stdout, so capture-dispatch leaves a breadcrumb in
  # cc-failures.log (the board surfaces it) when the target did not come from an explicit base
  [ -n "$_root" ] && [ -n "$_br" ] && \
    CC_CAPTURE_CRUMB=1 "$CC_SELF/cc-merge.sh" capture-dispatch "$_root" "$_br" "$CC_CALLER_CWD" "${CC_WT_BASE:-}"
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

# Opened successfully. Register the placeholder board row NOW and stamp the dedup marker.
# state-model §3.1 (window A): the row used to be written at the END of the dispatch — after the
# RDY probe, the launch send, and the trust/TUI loop, up to ~40s later — while the marker was
# stamped HERE, so a crash in between left an open tab with NO board row AND a marker blocking the
# retry for 120s. task-add at tab-open closes that window (a crash now leaves an incomplete but
# VISIBLE row); task-set-launch at the end fills in the two facts only known by then (caller ref,
# launch args). Two verbs on purpose: task-add must NOT stamp the marker — a dispatch that failed
# after this point must leave no marker, or the retry is silently eaten (the retired
# cc-board.sh log's old "Only CHECK here; write the marker after success" rule, now
# structural in the facade).
# The merge target (5th arg) reads the same git config capture-dispatch recorded on BOTH dispatch
# paths before the tab opened — the same single authority the end-of-dispatch log call used.
if [ -z "$rsmode" ]; then
  _mt=""
  _mtb="$(git -C "$abspath" symbolic-ref --short HEAD 2>/dev/null)"
  [ -n "$_mtb" ] && [ -n "${root:-}" ] && _mt="$(git -C "$root" config --get "branch.$_mtb.ccMergeInto" 2>/dev/null)"
  "$CC_SELF/cc-state" task-add "$abspath" "" "$ref" "$prompt" "${_mt:-}"
fi
# WINDOW B (spec §3.1): the stamp belongs to "a tab was opened for this dir", which is
# true on BOTH paths — resume reopens a tab too. It used to live inside the branch above,
# so a resumed tab left no stamp and the very next dispatch for that dir sailed through
# the 120s dedup gate and opened a SECOND one. task-add stays branch-local (resume's row
# already exists); the stamp does not. Still AFTER the tab really opened, never before:
# a dispatch that failed by here must leave nothing that eats the retry.
"$CC_SELF/cc-state" task-mark-opened "$abspath"

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
  full="$full (6) Keep every edit inside THIS worktree (the cwd you started in — for this repo's own sub-tasks that path sits under ~/.config/cc-stack/.claude/worktrees/, so scope by your starting cwd, NEVER by the ~/.config/cc-stack prefix): everything outside it is read-only for a sub-task — the parent's main checkout, the live install dir, sibling worktrees — read freely, never write, even when a brief quotes an absolute path into them (the install dir is the LIVE dispatcher/hooks behind every session on this machine)."
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
  ( export CC_SEND_QUIET=1 CC_SEND_NOVERIFY=1; _ccsend "$ref" "$CC_WT_LAUNCH_CMD" ) >/dev/null 2>&1 || true
else
# Provider for NEW sub-tasks: `gwt-provider` writes a provider name to $CC_LAUNCH_FILE (default anthropic).
# anthropic/default → cmux claude-teams on the official/current-env provider; any other name → `cld <name>`,
# which sources ~/.config/claude/llm-provider/<name>.sh in the new tab (provider env is process-local, so
# existing sub-tasks keep their launch-time provider). Unknown/empty → safe default, never breaks the launch.
_provider="$(cat "${CC_LAUNCH_FILE:-$HOME/.config/cc-stack/launch}" 2>/dev/null)"
prov_rec="anthropic"
case "$_provider" in
  ""|anthropic|default) launch="ccteam" ;;
  # F4 fix (+round 2): the SAME whitelist _ccres_parse applies at resume time — allowed chars
  # A-Za-z0-9._-, no leading dot (a `cld .kimi` launch would record, then be dropped back to
  # ccteam on resume), no traversal. Divergence here = a launch the recorded args can't replay.
  *[!A-Za-z0-9._-]*|.*|*/*|*..*) launch="ccteam" ;;   # invalid/leading-dot/traversal → safe default
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
# Bounded sweep of pf leftovers (gate round 3): the common cause is NOT a failed send but a
# TUI that painted too slowly for the probe — the shell evals $(cat pf) right away, ~6s before
# the 24-round probe gives up — so the file outlives its dispatch as a world-readable copy of
# the full brief. On every dispatch drop any cc-wt-prompt.* older than a day or two (-mtime
# day-granularity rounds up; conservative on the fresh side, since a slow tab's shell may not
# have read its file yet).
find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cc-wt-prompt.*' -mtime +1 -exec rm -f {} + 2>/dev/null || true
pf=""
if [ -n "$full" ]; then
  pf="${TMPDIR:-/tmp}/cc-wt-prompt.$$.txt"
  printf '%s' "$full" > "$pf"
  # Routed through cc-send (the single injection exit point). The tab is still a SHELL here — no
  # claude input box yet — so CC_SEND_QUIET suppresses the fail-open breadcrumb that an
  # unrecognized shell prompt would otherwise write on every dispatch, and CC_SEND_NOVERIFY=1
  # (H3) skips the post-send verify: on a ❯-prompt shell the launch echo would read as a busy
  # composer and false-alarm. Nothing is lost — there is no composer to verify on a shell.
  ( export CC_SEND_QUIET=1 CC_SEND_NOVERIFY=1; _ccsend "$ref" "$launch$sess --permission-mode $pm$mflag \"\$(cat '$pf')\"" ) >/dev/null 2>&1 || true
else
  ( export CC_SEND_QUIET=1 CC_SEND_NOVERIFY=1; _ccsend "$ref" "$launch$sess --permission-mode $pm$mflag" ) >/dev/null 2>&1 || true
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
  # F5 fix (round 2): match over the WHOLE 30-line capture — the trust dialog is a BOX whose
  # question sits ~15-17 lines above the options/footer, so a bottom-15 window can miss it
  # entirely (pre-auth failing → 24 idle spins → a tab stuck on an unanswered dialog, still
  # exit 0). The safety lives in the PHRASES alone: the three REAL dialog wordings, lowercased —
  # brief-echo PROSE ("if you trust that folder…") never matches them; the old loose
  # *trust*folder* matched any prose at all.
  # Gate follow-up (arm ORDER): TUI markers are checked BEFORE the trust phrases — a screen can
  # carry BOTH (a brief or gate report VERBATIM-quoting the dialog in the transcript above a
  # healthy TUI); trusting first would fire up to 24 stray Enters into the live session, which
  # presses the default option if a permission dialog happens to be up. TUI markers up ⇒ claude
  # is running ⇒ no pending trust dialog exists, so they win the race. The order is also what
  # makes the *"do you trust"* catch-all (4th pattern, gate round 3) safe to keep: the F5
  # wording can drift ("…this directory?", a rewrap) and the three exact phrases would miss it
  # — pre-auth silently failing again — so anything asking "do you trust" gets answered, and
  # the TUI-first arm keeps a transcript QUOTE of the question from being answered instead.
  scr="$(cmux read-screen --surface "$ref" --lines 30 2>/dev/null | tr 'A-Z' 'a-z')"
  case "$scr" in
    *"esc to interrupt"*|*"? for shortcuts"*|*"ctrl+c to exit"*|*"-- insert --"*)
      tui=1; break ;;                                       # claude TUI is up → no trust dialog coming
    *"do you trust"*|*"do you trust the files in this folder"*|*"do you trust this folder"*|*"do you trust the files in the parent directory"*)
      cmux send-key --surface "$ref" Enter >/dev/null 2>&1   # keystroke-answering a dialog, NOT text
                                                             # injection — deliberately stays a raw send-key
      sleep 1 ;;                                            # dialog leaves; the loop then sees the TUI
  esac
  sleep 0.25
done

# ── cc-send self-calibration (roadmap 2b, hardening layer 4) ──
# The TUI is up and its input box is KNOWN empty right now: verify a pattern hits it. A miss
# breadcrumbs to cc-failures.log (the board surfaces it) — renderer drift becomes visible the
# same day instead of silently degrading every future send to fail-open.
[ -n "$tui" ] && _ccsend_calibrate "$ref" "$abspath" || true

# claude is up and the prompt is already read into argv by the shell — the temp file can go
# F3 fix: only delete the prompt file when we're sure the TUI is up (tui=1). If the RDY probe timed
# out and we "sent anyway", the shell might not have executed $(cat '$pf') yet — deleting it now means
# claude starts with an empty prompt and no indication of failure. A few KB in TMPDIR is harmless.
[ -n "$pf" ] && [ -n "$tui" ] && rm -f "$pf" 2>/dev/null
# F3 (round 2): when the TUI was never confirmed the file is KEPT — say so, with the path, so a
# tab that idles with an empty prompt is diagnosable instead of mysterious.
if [ -n "$pf" ] && [ -z "$tui" ]; then
  # round 4: also crumb it to cc-failures.log — the hook path discards stdout/stderr, so a
  # stderr-only line never reaches the board; _ccsend_crumb is the channel that does.
  _ccsend_crumb "$ref" "claude TUI never confirmed — prompt kept in $pf; if the tab idles with an empty prompt, submit it by hand"
  echo "⚠ claude TUI never confirmed — prompt kept in $pf" >&2
fi

# ── Register into the task list (so gwt-status can show "which worktree is doing what") ──
# The second half of the task-add written at tab-open: fill the caller ref (5th field) and the
# launch args (8th field, what gwt-resume replays). The merge target (7th field) went in with
# task-add — the same git config capture both dispatch paths recorded before the tab opened (F5's
# single authority), so an empty target still means "board falls back to its trunk heuristic".
# SKIPPED in resume mode: the row already exists; `cc-dispatch.sh resume` refreshes its surface ref.
if [ -z "$rsmode" ]; then
  "$CC_SELF/cc-state" task-set-launch "$abspath" "${caller_surface:-}" "${largs:-}"
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
"$CC_SELF/cc-state" tab-add "$suuid" "$csuuid" "$abspath" "$tabsid"

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
cstore="${CC_CMUX_SESSIONS:-$HOME/.cmuxterm/claude-hook-sessions.json}"
self_uuid="$(_ccuc "${CC_CALLER_SURFACE_UUID:-${CMUX_SURFACE_ID:-}}")"

# ── ① board row (newest for this dir) → recorded identities ──
# task-get answers "the newest row of this dir" under the same raw-or-canonical match the awk
# scan used (the dir may be gone; a legacy logical-path row still finds its canonical caller).
# branch comes off the row itself — it feeds the gwt-done unlock (_cc_rowdone), which must keep
# working even when the row carries no valid surface identity (tab-resolve then emits NO board
# candidate at all, and with it no branch). The identities come off the launch-args STRING
# (_ccpick reads k=v segments, not TSV fields); owner deliberately keeps the raw csuuid —
# validity is only ever enforced on the TAB uuid.
brow="$("$CC_SELF/cc-state" task-get "$cdir" 2>/dev/null)"; bbranch=""; blargs=""
if [ -n "$brow" ]; then
  bbranch="$(printf '%s\n' "$brow" | cut -f2)"
  blargs="$(printf '%s\n' "$brow" | cut -f8)"
fi
tuuid="$(_ccuc "$(_ccpick "$blargs" suuid)")"
owner="$(_ccuc "$(_ccpick "$blargs" csuuid)")"
case "$tuuid" in *[!0-9A-F-]*) tuuid="" ;; esac

live="$(_cctabs_livemap)"
_cctabs_prune "$live"                    # lazy pruning: rows whose surface is gone (live map only)

# ── ①b the two ledgers' candidates, in the order close consults them ──
# tab-resolve hands back EVERY candidate — the board row's identity first, then the opened-tabs
# ledger's — with close's own identity rules already applied (uppercase; a short ref is an
# address, never an identity, and is dropped outright). The facade does NOT choose: which
# candidate is THE tab is a liveness question, liveness is a cmux probe (spec §3.2), so the
# cascade — first candidate whose uuid is alive wins — stays here. The ledgers are never deduped
# against each other; both appear, priority ordered.
tref=""
while IFS=$'\t' read -r _cand_src cand_s _cand_o _cand_b; do
  [ -n "$cand_s" ] || continue
  tref="$(printf '%s\n' "$live" | awk -F'\t' -v u="$cand_s" '$2==u{print $1; exit}')"
  [ -n "$tref" ] && { tuuid="$cand_s"; break; }
done <<< "$("$CC_SELF/cc-state" tab-resolve "$cdir" 2>/dev/null)"
[ -n "$tref" ] || tuuid=""
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
[ -n "$tuuid" ] && tabowner_u="$(_ccuc "$("$CC_SELF/cc-state" tab-owner "$tuuid" 2>/dev/null)")"
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

# The header names where to look, on purpose — the human troubleshoots this ledger by hand.
# That used to be a file path; the ledger is a table in the state library now, so "where to
# look" is a COMMAND. Keeping the old path here would not be conservative, it would be a lie
# printed on every run: the file it named no longer holds anything.
echo "── opened tabs (cc-state dump tabs) ──"
# "no ledger at all" is a different sentence from "a ledger, but no row of yours", and it is the
# one that must be said BEFORE the cmux warnings and the column header — a reader who has never
# opened a tab should not be told their workspace enumeration was incomplete. So this stays a
# PRECHECK (one python start on a command that already forks cmux once per workspace), and it
# buys back the whole liveness probe on the empty path, which today ran before saying this.
"$CC_SELF/cc-state" exists tabs || { echo "  (no tabs recorded)"; exit 0; }
tabs_live="$(_cctabs_livemap)"
tabs_part=""; _cctabs_partial "$tabs_live" && tabs_part=1
_cctabs_prune "$tabs_live"
tabs_self="$(_cctabs_uc "${CC_CALLER_SURFACE_UUID:-${CMUX_SURFACE_ID:-}}")"
[ -n "$tabs_live" ] || echo "  ⚠ cmux unreachable — liveness unknown, nothing pruned"
[ -n "$tabs_part" ] && echo "  ⚠ cmux workspace enumeration incomplete — liveness partial, nothing pruned (rows below print dead? rather than dead)"
printf '%-12s  %-36s  %-6s  %-36s  %s\n' REF UUID STATE OWNER DIR
# Rows come off the facade (tab-list applies the this-session filter unless --all, the same
# owner-rule this loop used to apply inline); what stays here is the liveness JOIN — a cmux
# probe, not state. Field access on the row stream uses the same `read` as before: the facade
# writes "-" placeholders for empty owner/session, so no run-of-TABs collapse can shift fields.
tabs_n=0
while IFS=$'\t' read -r t_u t_o t_d t_s t_ts; do
  [ -n "$t_u" ] || continue
  [ "$t_o" = "-" ] && t_o=""
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
done <<< "$("$CC_SELF/cc-state" tab-list ${tabs_all:+"--all"} 2>/dev/null)"
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
# task-list answers that whole question in one pass (newest-per-dir keyed on the CANONICAL dir,
# dead dirs skipped at read time — gone dirs are prune's business —, repo filter unless --all,
# newest-first output). The row stream is still TSV, so the awk→shell handoff below keeps the
# same US (0x1f) delimiter discipline as cc-board.sh: TAB is IFS whitespace and collapses runs
# of it, breaking empty fields (F7).
repo_root=""
if [ -z "$res_all" ]; then
  # F1 fix: resolve to the main repo root, not the worktree itself (linked worktrees must see
  # sibling lines, not just themselves). Use the same discipline as _cc_gitroot.
  repo_root="$(_cc_gitroot "$PWD" 2>/dev/null || true)"
  if [ -n "$repo_root" ]; then
    repo_root="$(ccb_canon "$repo_root")"
    [ -n "$repo_root" ] || repo_root=""
  fi
fi
# (an unresolvable repo_root reaches the facade as an empty --repo value, which filters nothing —
# the same "everything shows" fallback the inline case-statement had)
if [ -n "$res_all" ]; then
  task_rows="$("$CC_SELF/cc-state" task-list --all 2>/dev/null \
    | awk -F'\t' '$4 != "" { print $4 "\037" $2 "\037" $3 "\037" $6 "\037" $8 }')"
else
  task_rows="$("$CC_SELF/cc-state" task-list --repo "$repo_root" 2>/dev/null \
    | awk -F'\t' '$4 != "" { print $4 "\037" $2 "\037" $3 "\037" $6 "\037" $8 }')"
fi
rows=""
US="$(printf '\037')"
while IFS="$US" read -r r_dir r_br r_ref r_task r_largs; do
  [ -n "$r_dir" ] || continue
  # canonical form for the live-map join and the refresh verbs below; the RECORDED string is
  # what step ③ launches with (the "recorded dir verbatim" invariant) and what stays in the row
  c="$(ccb_canon "$r_dir")"; [ -n "$c" ] || c="$r_dir"
  rows="${rows}${c}${US}${r_dir}${US}${r_br}${US}${r_ref}${US}${r_task}${US}${r_largs}
"
done <<< "$(printf '%s\n' "$task_rows")"

# ── helpers (bash 3.2 safe) ──
# The state rewrites these used to do by hand (field-3/suuid refresh, sidecar sweep) are facade
# verbs now: task-set-ref (same dir rule, same suuid swap, and it does NOT widen a 7-field
# legacy row the way the old awk's $3=r OFS rebuild did) and task-clear-state.
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
# "canon${US}dir${US}branch${US}task${US}action${US}ref-to-apply${US}launch-cmd" — the whole resume
# chain keeps the US delimiter of the task_rows handoff above (F7: TAB collapses empty fields,
# and a row with an empty surface ref would shift task/largs left and misread the uuid).
plan=""; n_rest=0; n_re=0; n_live=0
while IFS="$US" read -r c r_dir r_br r_ref r_task r_largs; do
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
    "$CC_SELF/cc-state" task-set-ref "$c" "$live_ref" "$live_uuid"
    "$CC_SELF/cc-state" task-clear-state "$c"
    plan="${plan}${c}${US}${r_dir}${US}${r_br}${US}${r_task}${US}${act}${US}${live_ref}
"
    n_rest=$((n_rest+1))
    continue
  fi
  if [ -n "$r_ref" ] && printf '%s\n' "$live_pairs" | awk -F'\t' -v r="$r_ref" '$2==r{f=1} END{exit f?0:1}'; then
    plan="${plan}${c}${US}${r_dir}${US}${r_br}${US}${r_task}${US}already-live${US}${r_ref}
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
  plan="${plan}${c}${US}${r_dir}${US}${r_br}${US}${r_task}${US}${act}${US}-${US}${lcmd}
"
  n_re=$((n_re+1))
done <<< "$(printf '%s\n' "$rows")"

# Nothing to resume — but WHY not? "no board at all" and "a board with nothing of this repo's on
# it" send the human to different places (register a sub-task vs. rerun with --all), and telling
# them apart used to mean stat'ing the task file before the rows were even read. Asked here
# instead, the question costs a python start only on the path that already came up empty, and
# nothing is printed between the old call site and this one, so the transcript is unchanged.
if [ -z "$plan" ]; then
  "$CC_SELF/cc-state" exists tasks || { echo "no registered worktree tasks (nothing to resume)"; exit 0; }
  echo "no resumable board rows (current repo; try --all)"; exit 0
fi

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
while IFS="$US" read -r c r_dir r_br r_task r_act r_ref r_cmd; do
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
  while IFS="$US" read -r c r_dir r_br r_task r_act r_ref r_cmd; do
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
      "$CC_SELF/cc-state" task-set-ref "$c" "$newref" "$newuuid"
      "$CC_SELF/cc-state" task-clear-state "$c"
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
"$CC_SELF/cc-state" tab-add "$wsuuid" "${CC_CALLER_SURFACE_UUID:-${CMUX_SURFACE_ID:-}}" "$abspath" ""
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
