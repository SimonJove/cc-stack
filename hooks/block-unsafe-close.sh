#!/usr/bin/env bash
# cc-stack hook (repo-owned; distributed + registered by install.sh).
# PreToolUse (Bash) · THE tab-close permission gate.
#
# Policy (human-set, 2026-08-16):
#   • a CHILD tab (worktree sub-task) may be closed by ITS OWN PARENT session and by nobody else;
#   • a PARENT / primary-checkout tab is closed by the HUMAN in the cmux UI only — the UI path never
#     reaches this hook, so the rule reduces to: BLOCK every automated (Bash-driven) close of any
#     tab that is not a registered worktree child of the caller;
#   • the ledger is the board (worktree-tasks.tsv): cc-dispatch.sh surface records, at dispatch
#     time, BOTH stable surface UUIDs in the row launch-args field —
#       suuid=<the child tab surface uuid>   csuuid=<the dispatching parent surface uuid>
#     Everything here keys on those UUIDs; short refs (surface:283) are NEVER trusted.
#
# WHY (incident 2026-08-16 02:19, full record in docs/known-issues.md): a campaign parent finished
# authorized cleanup and ran `for s in 283 284 285; do cmux close-surface surface:$s; done`. cmux
# short refs DRIFT as panes open and close, bare numbers are INDEX semantics, and — probed live
# 2026-08-16 — `cmux close-surface <positional>` IGNORES the positional argument and closes the
# CALLER own surface. The parent killed itself mid-turn.
#
# Rules, evaluated in this order; the first that fires blocks (exit 2, message names the rule);
# a silent exit 0 allows. EVERY target in the command must pass.
#   a. CC_ALLOW_SELF_CLOSE=1 (hook env or as a prefix assignment on the command) -> allow, no checks
#   b. bare numeric target (--surface 283) -> BLOCK: that is a cmux INDEX, not an identity
#   c. no parseable explicit target (positional form, pipes, xargs, $VAR, command substitution,
#      or a bare `cmux close-surface`) -> BLOCK: cmux would fall back to the caller own surface
#   d. a resolved target equal to the caller own $CMUX_SURFACE_ID -> BLOCK: no automated self-close
#   e. a resolved target that is not a registered worktree tab (cwd not under */.claude/worktrees/*,
#      unknown surface, or a whole window) -> BLOCK: human-UI-only
#   f. a worktree tab whose board row records a DIFFERENT parent (or no row at all) -> BLOCK:
#      not your child
#
# Resolution is read-only: `cmux list-pane-surfaces --id-format both` (short ref <-> stable uuid)
# joined with the board; the cmux agent session store (~/.cmuxterm/claude-hook-sessions.json,
# CC_CMUX_SESSIONS) is a secondary source for a surface cwd. NOTE: that store only holds sessions
# started by the plain `claude` launcher — `ccteam` (cmux claude-teams) sub-tasks never appear in
# it, which is exactly why the board carries suuid itself.
#
# Env: CC_TASKS_FILE (board), CC_CMUX_SESSIONS (session store), CC_CALLER_SURFACE_UUID (test
# override for $CMUX_SURFACE_ID), CC_ALLOW_SELF_CLOSE (escape hatch).
set -u

TASKS="${CC_TASKS_FILE:-$HOME/.config/cc-stack/worktree-tasks.tsv}"
STORE="${CC_CMUX_SESSIONS:-$HOME/.cmuxterm/claude-hook-sessions.json}"
uc(){ printf '%s' "${1:-}" | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'; }
SELF_UUID="$(uc "${CC_CALLER_SURFACE_UUID:-${CMUX_SURFACE_ID:-}}")"

input="$(cat)"
# Cheapest possible prefilter, on the RAW payload: this hook fires on every single Bash call, and
# the overwhelming majority never mention a close verb — skip the json parse for those. The gap
# between "close" and the noun is deliberately loose: json escaping and shell quoting both push
# characters in there (close\-surface arrives as close\\-surface, "close"-"surface" likewise), and
# an anchored `close-surface` match let exactly those forms through the gate (gate review
# 2026-08-16). Cost of the looseness is a json parse on a command that merely says "closed window".
CLOSE_VERB_RE='close[^[:space:]]{0,6}(surface|window)'
printf '%s' "$input" | grep -qE "$CLOSE_VERB_RE" || exit 0
cmd="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("tool_input",{}).get("command",""))
except Exception:
    pass' 2>/dev/null)"
[ -n "$cmd" ] || exit 0

# Same prefilter on the decoded command (json unescaping can only shorten the gap, never widen it).
printf '%s' "$cmd" | grep -qE "$CLOSE_VERB_RE" || exit 0

# ── rule a: escape hatch ─────────────────────────────────────────────────────────────────────
case "${CC_ALLOW_SELF_CLOSE:-}" in 1|true|yes|TRUE|YES) exit 0 ;; esac
printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|()])CC_ALLOW_SELF_CLOSE=(1|true|yes)([[:space:]]|$)' && exit 0

deny(){ # $1 = "rule x — headline", $2 = detail block (may be empty)
  {
    echo "✗ tab close BLOCKED — $1"
    [ -n "${2:-}" ] && printf '%s\n' "$2"
    echo "  The sanctioned path (the ONLY automated way to close a sub-task tab):"
    echo "    ~/.config/cc-stack/cc-dispatch.sh close <worktree-dir>   # resolves by STABLE surface uuid"
    echo "    gwt-rm <name> --close                                    # remove the worktree AND close its tab"
    echo "  Parent / primary-checkout tabs: the human closes them in the cmux UI. Never hardcode a"
    echo "  surface short id or a bare index into cmux close-* — short refs DRIFT, bare numbers are"
    echo "  INDEXES, and a positional target is silently ignored (cmux then closes YOUR own tab)."
    echo "  If you really mean this exact call: CC_ALLOW_SELF_CLOSE=1 <command>"
  } >&2
  exit 2
}

# ── parse: collect the explicit targets of every close-surface / close-window in the command ──
# Separators are padded into standalone tokens so a statement boundary is visible to the scan
# (`for s in 1 2; do cmux close-surface ...; done` and `a && b` both parse).
#
# EVASION NOTE (gate review 2026-08-16, every form below was live-verified to close a real tab
# while passing an earlier version of this parser): the shell hands cmux the same argv whether
# the words are written bare, quoted or backslash-escaped, and the command word itself can hide
# behind a wrapper or a variable. So:
#   • every token is NORMALIZED (quotes and backslashes stripped) before it is classified —
#     `cmux 'close-surface'`, `cmux "close-surface"` and `cmux close\-surface` all read as the
#     verb they really are;
#   • wrapper words (xargs / sh -c / env -u X / sudo / timeout …) put the statement in runner
#     mode, so the real command word is recognized however deep it sits behind their flags;
#   • a close verb whose runner CANNOT be proven to be cmux — `$CMD close-surface`, or a bare
#     verb at command position — is intercepted anyway and refused as rule c (unresolvable);
#   • after a bare `--` everything is a positional, including a later `--surface`, so such a
#     command carries no parseable explicit target either (rule c). Conservative by construction:
#     we do not depend on what cmux does with post-`--` words.
# The one thing that must NOT happen is intercepting prose: a report message quoting the command
# text is not a close. That is why a verb only counts when its runner is cmux, is unresolvable,
# or the verb itself stands at command position.
toks="$(printf '%s' "$cmd" | tr '\n' ' ' | sed 's/[;&|()<>]/ & /g')"
set -f                                  # no globbing while word-splitting the command text
prev=""; incmux=0; state=0; pend=""; nclose=0; ncur=0; notarget=0; runner=0; unkcmd=0; dd=0; gflag=0
targets=""                              # lines: "<kind>|<raw token>"
for tok in $toks; do
  case "$tok" in
    ';'|'&'|'|'|'('|')'|'<'|'>')
      [ "$state" != 0 ] && [ "$ncur" -eq 0 ] && notarget=1
      state=0; pend=""; incmux=0; runner=0; unkcmd=0; dd=0; gflag=0; prev="$tok"; continue ;;
  esac
  # normalized view: quotes and backslash escapes are shell syntax, not part of the word cmux sees.
  # A leading $' is ANSI-C quoting ($'close-surface' IS the literal verb), so it comes off first.
  ntok="${tok/#\$\'/}"
  ntok="${ntok//\\/}"; ntok="${ntok//\"/}"; ntok="${ntok//\'/}"
  # splice view: a parameter expansion INSIDE a word can carry part of the verb
  # (IFS=-; cmux close${IFS}surface really invokes close-surface). Nothing is evaluated — each
  # expansion run is replaced by a `*` SENTINEL and the token is then used as a glob PATTERN
  # against the two literal verbs, so any short run the expansion could supply matches. Guarded on
  # the token literally containing close/surface/window, which keeps a bare `$X` (pattern `*`,
  # matches everything) out of the splice path.
  vtok="$ntok"
  case "$ntok" in
    *'$'*) case "$ntok" in
      *close*|*surface*|*window*)
        while :; do case "$vtok" in
          *'${'*'}'*) vtok="${vtok%%\$\{*}*${vtok#*\}}" ;;        # ${...} → *
          *) break ;;
        esac; done
        while :; do case "$vtok" in
          *'$'*) _vp="${vtok%%\$*}"; _vr="${vtok#*\$}"            # $NAME → *
                 while :; do case "$_vr" in [A-Za-z0-9_]*) _vr="${_vr#?}" ;; *) break ;; esac; done
                 vtok="$_vp*$_vr" ;;
          *) break ;;
        esac; done ;;
    esac ;;
  esac
  # which close verb (if any) this token is: 1 = close-surface, 2 = close-window.
  # NOTE the reversed case: the TOKEN is the pattern and the verb is the subject.
  verb=0
  case "$ntok" in
    close-surface) verb=1 ;;
    close-window)  verb=2 ;;
    *) if [ "$vtok" != "$ntok" ]; then
         case close-surface in $vtok) verb=1 ;; esac
         [ "$verb" = 0 ] && case close-window in $vtok) verb=2 ;; esac
       fi ;;
  esac
  # command position = right after a separator / keyword / VAR=value prefix
  cmdpos=0
  case "$prev" in
    ''|';'|'&'|'|'|'('|')'|'{'|'}'|'!'|do|then|else|elif|time) cmdpos=1 ;;
    *=*) cmdpos=1 ;;
  esac
  if [ "$state" = 0 ]; then
    # (1) the subcommand after an established cmux. cmux's own grammar is
    #     `cmux [global-options] <command>`, so the verb is NOT necessarily adjacent:
    #     `cmux --json close-surface …` and `cmux --password pw close-surface …` are documented
    #     legal syntax. We therefore keep scanning past leading flags and their values — and any
    #     ambiguity between "flag value" and "verb" resolves IN FAVOUR OF THE VERB (the verb test
    #     runs first), because guessing wrong in the other direction lets a real close through.
    if [ "$incmux" = 1 ]; then
      if [ "$verb" != 0 ]; then
        state="$verb"; nclose=$((nclose+1)); ncur=0; dd=0
        incmux=0; gflag=0; unkcmd=0; prev="$tok"; continue
      fi
      case "$ntok" in
        -*) gflag=1; prev="$tok"; continue ;;         # a global flag: keep looking for the verb
        *'$'*|*'`'*)                                  # an UNRESOLVABLE subcommand (cmux $verb …):
            nclose=$((nclose+1)); notarget=1          # we cannot know it is not a close → rule c
            incmux=0; gflag=0; unkcmd=0; prev="$tok"; continue ;;
        *)  if [ "$gflag" = 1 ]; then                 # the value of the flag we just saw
              gflag=0; prev="$tok"; continue
            fi
            incmux=0 ;;                               # some other subcommand: stop scanning
      esac
      unkcmd=0; prev="$tok"; continue
    fi
    # (2) a close verb with NO provable cmux runner: an unresolvable command word ($CMD / `…`)
    #     or the verb standing at command position (alias/function). Intercept and refuse — we
    #     cannot resolve what it would close. Prose never reaches here: there the verb sits as a
    #     plain argument behind an ordinary word.
    if [ "$verb" != 0 ]; then
      if [ "$unkcmd" = 1 ] || [ "$cmdpos" = 1 ]; then nclose=$((nclose+1)); notarget=1; fi
      unkcmd=0; prev="$tok"; continue
    fi
    # (3) wrapper words — only when they themselves stand at command position (or chain behind
    #     another wrapper), so the mere word "env" inside prose changes nothing
    if [ "$cmdpos" = 1 ] || [ "$runner" = 1 ]; then
      case "$ntok" in
        xargs|*/xargs|sh|bash|zsh|dash|*/sh|*/bash|*/zsh|*/dash|eval|parallel|*/parallel \
        |watch|*/watch|timeout|*/timeout|env|*/env|nohup|*/nohup|sudo|*/sudo|exec|command|time) runner=1 ;;
      esac
    fi
    # (4) the command word itself. unkcmd is STICKY until a separator or a verb consumes it: in
    #     `\`which cmux\` close-surface` the unresolvable part and the verb are not adjacent, and
    #     resetting per token let that form through (gate review 2026-08-16). Backticks are checked
    #     on the token as written — normalizing them away would turn `\`which cmux\`` into a
    #     perfectly resolvable-looking pair of words.
    case "$ntok" in
      cmux|*/cmux) if [ "$cmdpos" = 1 ] || [ "$runner" = 1 ]; then incmux=1; gflag=0; unkcmd=0; fi ;;
      *) if [ "$cmdpos" = 1 ] || [ "$runner" = 1 ]; then
           case "$ntok" in *'$'*|*'`'*) unkcmd=1 ;; esac        # cannot prove this is not cmux
         fi ;;
    esac
    prev="$tok"; continue
  fi
  # inside a close-surface / close-window argument list
  if [ "$dd" = 1 ]; then notarget=1; prev="$tok"; continue; fi   # past a bare --: all positional
  if [ "$pend" = target ]; then
    targets="${targets}$([ "$state" = 2 ] && echo window || echo surface)|$ntok
"
    ncur=$((ncur+1)); pend=""; prev="$tok"; continue
  fi
  if [ "$pend" = skip ]; then pend=""; prev="$tok"; continue; fi
  case "$ntok" in
    --)                dd=1 ;;                                # end of flags
    --surface|--panel) if [ "$state" = 1 ]; then pend=target; else pend=skip; fi ;;
    --window)          if [ "$state" = 2 ]; then pend=target; else pend=skip; fi ;;
    --workspace)       pend=skip ;;
    --surface=*|--panel=*)
      if [ "$state" = 1 ]; then targets="${targets}surface|${ntok#*=}
"; ncur=$((ncur+1)); fi ;;
    --window=*)
      if [ "$state" = 2 ]; then targets="${targets}window|${ntok#*=}
"; ncur=$((ncur+1)); fi ;;
    -*) : ;;                                                  # any other flag: not a target
    *)  notarget=1 ;;                                         # POSITIONAL: cmux ignores it (rule c)
  esac
  prev="$tok"
done
[ "$state" != 0 ] && [ "$ncur" -eq 0 ] && notarget=1
set +f

# The prefilter matched but nothing runs a close at command position (quoted text, a comment,
# our own primitive) — not our business.
[ "$nclose" -gt 0 ] || exit 0

# ── rule b: a bare number is a cmux INDEX ────────────────────────────────────────────────────
while IFS='|' read -r kind t; do
  [ -n "$kind" ] || continue
  t="${t//\"/}"; t="${t//\'/}"
  case "$t" in
    ''|*[!0-9]*) ;;
    *) deny "rule b: bare numeric target \"$t\" is a cmux INDEX, not an identity" \
            "  Indexes renumber whenever a pane opens or closes — the 2026-08-16 incident started here." ;;
  esac
done <<EOF
$targets
EOF

# ── rule c: no parseable explicit target ─────────────────────────────────────────────────────
[ "$notarget" -eq 0 ] || deny "rule c: no parseable explicit target" \
  "  cmux close-surface IGNORES a positional target and falls back to \$CMUX_SURFACE_ID — the
  CALLER own tab (probed live 2026-08-16). Pipes / xargs / \$VAR / \$( ) forms are unresolvable
  the same way, so they are refused rather than guessed at."
while IFS='|' read -r kind t; do
  [ -n "$kind" ] || continue
  t="${t//\"/}"; t="${t//\'/}"
  case "$t" in
    surface:[0-9]*|panel:[0-9]*|tab:[0-9]*|window:[0-9]*) ;;
    *[!0-9A-Fa-f-]*|'') deny "rule c: target \"$t\" is not a resolvable surface identity" \
        "  Only surface:<n> / a surface UUID can be resolved; \$VAR and \$( ) forms cannot." ;;
    *) case "$t" in
         ????????-????-????-????-????????????) ;;
         *) deny "rule c: target \"$t\" is not a resolvable surface identity" "" ;;
       esac ;;
  esac
done <<EOF
$targets
EOF

# ── live surface map (stable uuid <-> current short ref), read-only ──────────────────────────
LIVE=""
if command -v cmux >/dev/null 2>&1; then
  LIVE="$(cmux list-pane-surfaces --id-format both 2>/dev/null | sed 's/^\*//' \
          | awk 'NF>=2{print $1 "\t" toupper($2)}')"
fi

canon(){ CDPATH= cd -- "${1:-}" >/dev/null 2>&1 && pwd -P; }

board_by_suuid(){ # $1 = UPPERCASE surface uuid -> "dir<TAB>csuuid" of the NEWEST matching row
  [ -f "$TASKS" ] || return 0
  awk -F'\t' -v u="$1" '
    { la=$8; if (la=="" || $4=="") next
      s=""; c=""; n=split(la, seg, ":")
      for (i=1; i<=n; i++) {
        if (seg[i] ~ /^model=/) break                 # model is composed LAST and may hold colons
        if (seg[i] ~ /^suuid=/)  s=substr(seg[i], 7)
        if (seg[i] ~ /^csuuid=/) c=substr(seg[i], 8)
      }
      if (s != "" && toupper(s) == u) { d=$4; cc=c }
    } END { if (d != "") print d "\t" toupper(cc) }' "$TASKS"
}
board_owner_of_dir(){ # $1 = canonical dir -> csuuid (UPPERCASE) of the newest row for that dir
  [ -f "$TASKS" ] || return 0
  awk -F'\t' '{print $4 "\t" $8}' "$TASKS" 2>/dev/null | while IFS=$'\t' read -r bd la; do
    [ -n "$bd" ] || continue
    bc="$(canon "$bd")"; [ -n "$bc" ] || bc="$bd"
    [ "$bc" = "$1" ] || continue
    printf '%s\n' "$la" | awk '{ n=split($0, seg, ":")
      for (i=1; i<=n; i++) { if (seg[i] ~ /^model=/) break
                             if (seg[i] ~ /^csuuid=/) print toupper(substr(seg[i], 8)) }}'
  done | tail -1
}
store_cwd(){ # $1 = UPPERCASE surface uuid -> cwd of the newest session record on that surface
  [ -f "$STORE" ] || return 0
  python3 - "$STORE" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
d = d.get("sessions") if isinstance(d, dict) else None
if not isinstance(d, dict):
    sys.exit(0)
want = sys.argv[2].upper()
best = None
for v in d.values():
    if not isinstance(v, dict):
        continue
    if (v.get("surfaceId") or "").upper() != want:
        continue
    if best is None or (v.get("updatedAt") or 0) > (best.get("updatedAt") or 0):
        best = v
if best and best.get("cwd"):
    sys.stdout.write(best["cwd"])
PY
}

# ── rules d / e / f, per target ──────────────────────────────────────────────────────────────
while IFS='|' read -r kind t; do
  [ -n "$kind" ] || continue
  t="${t//\"/}"; t="${t//\'/}"

  if [ "$kind" = window ]; then
    deny "rule e: \"$t\" is a WINDOW, never a single sub-task tab" \
      "  A window holds whole workspaces — closing it takes primary-checkout and parent tabs with
  it. Windows are human-UI-only, always."
  fi

  # target -> stable uuid (short refs are resolved through the live map, never trusted as identity)
  case "$t" in
    surface:*|panel:*|tab:*)
      u="$(printf '%s\n' "$LIVE" | awk -F'\t' -v r="$t" '$1==r{print $2; exit}')" ;;
    *)
      u="$(uc "$t")"
      printf '%s\n' "$LIVE" | awk -F'\t' -v u="$u" '$2==u{f=1} END{exit f?0:1}' || u="" ;;
  esac
  [ -n "$u" ] || deny "rule e: \"$t\" does not resolve to a live cmux surface" \
    "  Nothing verifiable to close. Short refs drift; re-read the board (bash ~/.config/cc-stack/cc-board.sh)
  and close by directory through the sanctioned primitive."

  # d) never close the caller own tab from automation
  [ -n "$SELF_UUID" ] && [ "$u" = "$SELF_UUID" ] && \
    deny "rule d: \"$t\" resolves to the CALLER own surface ($u)" \
      "  This is exactly how the 2026-08-16 incident killed the parent session mid-turn."

  # e) must be a REGISTERED worktree child: board first (the only source that covers ccteam
  #    sub-tasks), cmux session store second
  dir=""; owner=""
  row="$(board_by_suuid "$u")"
  if [ -n "$row" ]; then
    dir="${row%%$'\t'*}"; owner="${row#*$'\t'}"
  else
    dir="$(store_cwd "$u")"
    if [ -n "$dir" ]; then
      c="$(canon "$dir")"; [ -n "$c" ] && dir="$c"
      owner="$(board_owner_of_dir "$dir")"
    fi
  fi
  [ -n "$dir" ] || deny "rule e: \"$t\" ($u) is not a registered worktree sub-task tab" \
    "  No board row and no session record — by policy that means a human opened it, and only the
  human closes it (cmux UI)."
  case "$dir" in
    */.claude/worktrees/*|*/.worktrees/*) ;;
    *) deny "rule e: \"$t\" ($u) runs in $dir — not a worktree checkout" \
         "  Primary-checkout / parent / main sessions are closed by the human in the cmux UI only." ;;
  esac

  # f) ownership: only the dispatching parent may close its own child
  [ -n "$owner" ] || deny "rule f: no dispatching parent recorded for $dir" \
    "  The board row carries no csuuid (row predates the ledger, or the tab was not opened by a
  dispatch) — treat it as human-opened."
  [ "$owner" = "$SELF_UUID" ] || deny "rule f: $dir belongs to another parent session" \
    "  recorded parent: $owner
  this session : ${SELF_UUID:-<no CMUX_SURFACE_ID>}
  A sub-task tab is closable by ITS OWN parent only."
done <<EOF
$targets
EOF

exit 0
