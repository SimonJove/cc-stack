#!/usr/bin/env bash
# cc-stack · the worktree sub-task board — ONE implementation, callable from ANY shell.
#   gwt-status (worktree.zsh) is a thin wrapper around this script; Claude's non-interactive
#   Bash tool invokes it directly (`bash ~/.config/cc-stack/cc-board.sh [--all]`) because the
#   old zsh-only render silently printed nothing there (the cmux tree + capture-pane
#   workaround is retired).
# Usage: cc-board.sh [--all] [--archive]
#   (the `log` subcommand — the pre-facade single write point for task rows — was retired
#    with Task 9: cc-state task-add / task-set-launch own the row now, and its recorded
#    bytes live on as test.sh §32's frozen oracle)
#   (default)  live board: the task list (via cc-state) joined with the status sidecar
#   --all      disable the repo filter (rows from every repo)
#   --archive  render the task archive (merged tasks; what gwt-log shows)
# Columns (TAB before STATUS keeps the historical header contract): TAB | BRANCH | PARENT |
#   STATUS | DIR | TASK.
#   TAB     cmux surface liveness (one list-pane-surfaces call PER WORKSPACE when ping succeeds —
#           the CLI has no all-workspaces flag; "?" when cmux is unreachable or a workspace could
#           not be enumerated; "?old-session" when no registered ref is alive → restart)
#   PARENT  recorded merge target (branch.<b>.ccMergeInto via the row's own repo), falling
#           back to the 7th TSV field once that config is gone (branch deleted after merge),
#           then cc-merge.sh get-parent's trunk heuristic; "-" when nothing resolves
#   STATUS  sidecar join on dir: working(23m) / idle(2h) / blocked(5m) / "-" ("?" age on a
#           malformed ts) — never "ready": readiness stays owned by gwt-done + a clean tree
# Row rules: the render owns no state access anymore — cc-state task-list answers "which rows
#   does this board show" (newest-per-dir, dead dirs skipped at read, repo filter inside the
#   facade); cc-state task-prune (live board only) is the locked sweep of the pair (tasks list
#   AND status sidecar) that a read used to do inline; the archive keeps every row in file
#   order (it's a log, its dirs are often gone by design, and rendering it rewrites nothing).
# Reading rows: awk -F'\t' only, over the facade's TSV output — see the discipline note below;
#   a `read` loop collapses runs of TAB and would shift every field after an empty one.
# Repo filter: only rows under the caller's MAIN repo root — the root is computed HERE (the
#   _cc_gitroot discipline, see the F1 note below — git-common-dir resolved INSIDE the target
#   dir, so a linked worktree maps to its parent repo; --show-toplevel would answer the
#   worktree itself) and handed to `cc-state task-list --repo`, which canonicalizes both sides
#   (realpath) so the physical /private/var/... form on macOS still meets a stored /var/... row;
#   outside any repo (or with --all) everything shows.
# Dir form: rows are trusted as written — production writes pwd -P paths and cc-state task-add
#   canonicalizes on write. The render's old read-side re-canonicalization (the CANON join
#   table) is gone with the facade swap: a hand-written logical-form row renders with its
#   recorded string (the honest record of how it was logged — gate-ruled INTENTIONAL), while
#   its STATUS still joins, because the sidecar join lives in the facade's --with-state and
#   keys on the dir rule that knows both the /var and the /private/var form.
set -u

all=""; archive=""
while [ $# -gt 0 ]; do
  case "$1" in
    --all)     all=1 ;;
    --archive) archive=1 ;;
    *) echo "usage: cc-board.sh [--all] [--archive]" >&2; exit 2 ;;
  esac
  shift
done

SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)"
MERGE="$SELF/cc-merge.sh"
[ -f "$MERGE" ] || MERGE="$HOME/.config/cc-stack/cc-merge.sh"
STATE="$SELF/cc-state"
[ -f "$STATE" ] || STATE="$HOME/.config/cc-stack/cc-state"

ccb_canon1(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }   # one-shot (forks); the repo-root block below

# ── TSV access discipline (2026-08-16 audit, F1) ───────────────────────────────────────
# NEVER `while IFS=$'\t' read -r a b c …` over TSV rows. TAB is IFS *whitespace*, so bash AND
# zsh collapse RUNS of it: one empty field (parent on a detached HEAD — cc-dispatch.sh's
# `git symbolic-ref --short HEAD` is empty there — or caller on a hand-written row) shifts every
# later field left. Displaying a shifted row is cosmetic; a REWRITER that re-printf's the shifted
# variables writes the shift back and makes it permanent (launch-args lands in the PARENT column,
# after which gwt-resume finds no uuid= and `cc-dispatch.sh close` fail-closes). The board no
# longer rewrites anything — cc-state owns every write now — but the reading rule stands:
# field access goes through awk -F'\t', selecting by NUMBER so 7-field legacy rows, 8-field live
# rows and 9-field archive rows all pass through byte-identically.
US="$(printf '\037')"   # record delimiter for awk→shell handoffs: NOT IFS whitespace, so `read`
                        # preserves empty fields between two of them (a TAB would collapse them)
NL='
'
ccb_has(){ case "$1" in *"$2"*) return 0 ;; esac; return 1; }   # substring test, fork-free

# repo-filter root: the caller's git top-level from PWD, canonicalized ("" → no filter)
# F1 fix: use the same discipline as _cc_gitroot in cc-dispatch.sh — a linked worktree must resolve
# to the MAIN repo root, not to the worktree itself (git rev-parse --show-toplevel returns the
# worktree directory in a linked worktree, which breaks the "from any shell" contract).
root=""
if [ -z "$all" ]; then
  # Resolve the git common dir, then its parent — this works for both main checkouts and
  # linked worktrees, and the relative path (when git-common-dir is ".git") resolves against
  # the target directory, not the caller's pwd.
  _cc_board_root="$( (CDPATH= cd -- "$PWD" 2>/dev/null || exit 1
                      _ccg="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 1
                      [ -n "$_ccg" ] || exit 1
                      CDPATH= cd -- "$_ccg/.." 2>/dev/null || exit 1
                      pwd -P) 2>/dev/null )" || true
  if [ -n "$_cc_board_root" ]; then
    # submodule guard (same TWO criteria as _cc_gitroot, OR'd): (a) superproject non-empty —
    # a submodule CHECKOUT; (b) the computed root doesn't CONTAIN this dir — a submodule's
    # LINKED worktree, where the superproject check is empty but .git/modules still isn't a
    # repo root and bec2f41's --show-toplevel showed that shape its own row. Either →
    # --show-toplevel; --separate-git-dir keeps the resolution above (root contains the dir).
    # The fallback cd's only on a NON-EMPTY toplevel: bash `cd -- ""` succeeds in place, so an
    # empty answer must never reach the subshell or it hands back the CALLER's pwd.
    _cbsup="$(git -C "$PWD" rev-parse --show-superproject-working-tree 2>/dev/null)"
    _cbtgt="$(ccb_canon1 "$PWD" 2>/dev/null || true)"
    case "$_cbtgt/" in ""|"$_cc_board_root"/*) _cbin="" ;; *) _cbin=1 ;; esac
    if [ -n "$_cbsup" ] || [ -n "$_cbin" ]; then
      _cbtop="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"
      if [ -n "$_cbtop" ]; then
        _cbfb="$( (CDPATH= cd -- "$_cbtop" 2>/dev/null && pwd -P) 2>/dev/null )"
        [ -n "$_cbfb" ] && _cc_board_root="$_cbfb"
      fi
    fi
    root="$(ccb_canon1 "$_cc_board_root" || true)"
    [ -n "$root" ] || root=""
  fi
fi

# ── prune-on-read (live board only) ────────────────────────────────────────────────────
# ONE facade call replaces the two inline locked sweeps this render used to run. cc-state
# task-prune always sweeps the pair — the tasks list AND the status sidecar (which used to be
# swept by nothing but gwt-prune/gwt-rm and grew forever) — under the single lock the facade
# owns, with the same keep rule: dir field non-empty and still a directory. Live board only:
# the archive is history and its dirs are gone by design, and the SIDECAR must not be swept as
# a side effect of reading history either.
if [ -z "$archive" ]; then
  "$STATE" task-prune
fi

# ── the rows: one facade call ──────────────────────────────────────────────────────────
# task-list = newest-per-dir + repo filter + dead-dir skip in one pass, newest-first — exactly
# what the render's old inline pipeline (tail -r + the awk SEEN dedup + the shell case filter)
# produced. --repo gets the root computed above; --all, or an empty root (outside any repo),
# means no filter. --archive reads the history store instead: every row, file order, same
# repo filter. --with-state (live board only) appends the sidecar's state + epoch per row and
# joins on the facade's dir rule — a legacy logical /var row still finds the canonical
# /private/var key the hook writes, which a caller-side join on the raw string cannot
# (gate round 2). The archive never displays state, so it skips the decoration.
if [ -n "$archive" ]; then
  wstate=""
else
  wstate="--with-state"
fi
if [ -n "$all" ] || [ -z "$root" ]; then
  rows_src="$("$STATE" task-list ${archive:+--archive} $wstate)"
else
  rows_src="$("$STATE" task-list ${archive:+--archive} $wstate --repo "$root")"
fi

# Nothing to render. The two messages below are a SPLIT, not a fallback: "there is no store"
# and "the store is there and none of it matched" are different answers to the human, and the
# render used to tell them apart by stat'ing the file it no longer knows the name of. `exists`
# asks the facade the same question in the only form that survives the engine swap (rows, not
# files) — and it is asked HERE, on a path that has already come up empty, so the live board's
# three facade calls stay three. Never hoist it above the task-list call.
if [ -z "$rows_src" ]; then
  if [ -n "$archive" ]; then
    "$STATE" exists archive || { echo "no archived tasks"; exit 0; }
    echo "no records"; exit 0    # the store exists but nothing renders (e.g. all rows foreign)
  fi
  "$STATE" exists tasks || { echo "no registered worktree tasks"; exit 0; }
  echo "no records"; exit 0      # same split the old render kept: store gone ≠ nothing matched
fi

# ── tab liveness: one cmux probe per WORKSPACE (live board only) ──────────────────────
# `cmux list-pane-surfaces` lists the CALLER's workspace ($CMUX_WORKSPACE_ID) and the CLI has no
# "every workspace" flag (live-probed 2026-08-16: 8 surfaces unscoped, 13 enumerated one workspace
# at a time). The single unscoped call this used to make therefore answered "is this tab in MY
# workspace?", so three sub-task tabs sitting in another workspace rendered ?old-session while
# their own STATUS cell said working(11m) — the row contradicted itself. The probe is the UNION
# over `cmux list-workspaces`, taken ONCE per render (1+N cmux calls, N = workspaces).
# live_partial = the enumeration was incomplete: a workspace that could not be listed, or no
# workspace list at all (then we cannot even count what we missed). Absence of evidence is not
# evidence of death (the invariant cc-dispatch.sh's opened-tabs prune spells out, where getting it
# wrong DELETES rows): a row we could not look for stays "?" — liveness unknown — and is never
# reported as ⌫closed or ?old-session. The four TAB values keep their meanings; what changed is
# only how much of cmux the probe covers.
live=""; live_partial=""
if [ -z "$archive" ] && command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1; then
  # leading ref token only (a `grep -o` would mint a ref out of a workspace NAMED after one)
  ccb_wsrefs="$(cmux list-workspaces 2>/dev/null | sed 's/^\*//' | awk '$1 ~ /^workspace:[0-9]+$/{print $1}')"
  if [ -n "$ccb_wsrefs" ]; then
    for ccb_w in $ccb_wsrefs; do
      # empty = a failed probe, not an empty workspace (cmux refuses to close a workspace's last
      # surface, so one always exists); an unknown ref still exits 0, so rc cannot carry this
      ccb_wl="$(cmux list-pane-surfaces --workspace "$ccb_w" 2>/dev/null)"
      if [ -n "$ccb_wl" ]; then live="$live$ccb_wl$NL"; else live_partial=1; fi
    done
  else
    # No workspace list (older CLI, or the call failed): the unscoped call still resolves the tabs
    # it can see, but without the list we cannot even know how many workspaces went unlooked-at —
    # the least complete evidence there is, so it counts as partial too (same call the opened-tabs
    # prune makes, where the equivalent fallback was deleting live rows).
    live="$(cmux list-pane-surfaces 2>/dev/null)"
    [ -n "$live" ] && live_partial=1
  fi
fi
# (C) surface refs are session-scoped; after a cmux restart they all become stale. If NO
# registered ref is alive, refs are stale rather than tabs closed → "?old-session".
some_live=""
if [ -n "$live" ]; then
  while IFS= read -r r; do
    if ccb_has "$live" "$r"; then some_live=1; break; fi
  done < <("$STATE" dump tasks | awk -F'\t' '$3 != "" {print $3}')
fi

# ── batched joins (F13) ────────────────────────────────────────────────────────────────
# The board is the most-run command in this stack and used to fork 4-5 times PER ROW. The state
# joins (newest-per-dir, dir canonicalization, the dead-dir question) now all happen inside
# cc-state task-list; the two GIT joins below stay here — branch → merge target and the
# registered-worktree list — read ONCE PER REPO instead of once per row, and joined in the single
# awk pass that builds the render stream (awk hashes; the bash 3.2 alternative — string tables
# scanned with ## / case — measured 4x SLOWER than forking at 40 rows). The shell loop below then
# only formats: no forks, no scans. Fallbacks that cannot be batched (a row that is not a
# registered worktree of any repo) keep the original per-row git calls.
ccb_now="$(date +%s)"
ccb_age_v=""
ccb_age(){   # <unix-ts> → ccb_age_v = 23m / 2h / 5d; "?" on a malformed ts
  local ts="$1" age
  case "$ts" in ''|*[!0-9]*) ccb_age_v="?"; return 0 ;; esac
  age=$(( ccb_now - ts ))
  [ "$age" -lt 0 ] && age=0
  if   [ "$age" -lt 3600   ]; then ccb_age_v="$(( age / 60 ))m"
  elif [ "$age" -lt 86400 ]; then ccb_age_v="$(( age / 3600 ))h"
  else ccb_age_v="$(( age / 86400 ))d"; fi
}

# TABLE 2/3 — branch → merge target, plus the repo's registered-worktree list, one read per
# repo. A worktree shares its repo's config, so the candidate root derived from the row dir's
# layout (<root>/.claude/worktrees/<n> or <root>/.worktrees/<n>) is only TRUSTED for a dir git
# itself lists as a worktree of it. Anything else — a hand-written row, a nested repo, an exotic
# layout — falls back to the original per-row `git -C <dir> config`, so a branch name that
# exists in two repos can never put the wrong merge target in the column.
ccb_pmap=""; ccb_pwt=""; ccb_roots="$NL"
while IFS= read -r _c; do
  [ -n "$_c" ] || continue
  case "$_c" in
    */.claude/worktrees/*) _r="${_c%/.claude/worktrees/*}" ;;
    */.worktrees/*)        _r="${_c%/.worktrees/*}" ;;
    *) continue ;;
  esac
  ccb_has "$ccb_roots" "$NL$_r$NL" && continue
  ccb_roots="$ccb_roots$_r$NL"
  # `<key> <value>` per line; the key is one token (branch names hold no spaces) and the value is
  # the rest. git normalizes the NAME part of a config key to lowercase in --get-regexp OUTPUT
  # (branch.feat/x.ccMergeInto answers `branch.feat/x.ccmergeinto` — live-probed 2026-08-21), so
  # the suffix strip must be case-insensitive; and since a branch name may itself hold dots, strip
  # at the LAST dot-segment rather than at the literal suffix.
  ccb_pmap="$ccb_pmap$(git -C "$_r" config --get-regexp '^branch\..*\.ccMergeInto$' 2>/dev/null \
      | awk -v r="$_r" '{k=$1; v=substr($0,length(k)+2); sub(/^branch\./,"",k)
                         if (tolower(k) ~ /\.ccmergeinto$/) sub(/\.[^.]*$/,"",k)
                         if (k != "" && v != "") print r "\t" k "\t" v}')
"
  ccb_pwt="$ccb_pwt$(git -C "$_r" worktree list --porcelain 2>/dev/null \
      | awk -v r="$_r" '/^worktree /{print r "\t" substr($0,10)}')
"
done <<< "$(printf '%s\n' "$rows_src" | awk -F'\t' '$4 != "" {print $4}' | sort -u)"

# ── render ─────────────────────────────────────────────────────────────────────────────
# Input is the facade's row list — newest-first, deduped, repo-filtered for the live board,
# and state-decorated (--with-state appends state \t epoch; '-' + '' when the sidecar has no
# row); every row in file order for the archive, undecorated. One awk pass picks the displayed
# fields BY NUMBER — which is what makes the trailing fields a non-issue: the archive's
# merged-at (8th on a legacy row, 9th behind launch-args) is simply not selected and can no
# longer be absorbed into PARENT — and joins the tables above, emitting a US-delimited stream
# the shell only has to format. US, not TAB: it is not IFS whitespace, so `read` keeps a row's
# empty fields instead of collapsing them.
# Tables travel in the ENVIRONMENT rather than -v: awk expands escape sequences in a -v value,
# which would corrupt any path holding a backslash.
rows="$(printf '%s\n' "$rows_src" | \
  CCB_PMAP="$ccb_pmap" CCB_PWT="$ccb_pwt" CCB_LIVE="$live" \
  awk -F'\t' -v OFS="$US" '
  function lastidx(s, t,   p, off, at) {           # last occurrence of t in s (0 = none)
    off = 0; at = 0
    while ((p = index(substr(s, off + 1), t)) > 0) { at = off + p; off = at }
    return at
  }
  BEGIN {
    n = split(ENVIRON["CCB_PMAP"], L, "\n")                       # root, branch → merge target
    for (i = 1; i <= n; i++) { if (split(L[i], F, "\t") == 3) PP[F[1], F[2]] = F[3] }
    n = split(ENVIRON["CCB_PWT"], L, "\n")                        # root, dir → registered worktree
    for (i = 1; i <= n; i++) { if (split(L[i], F, "\t") == 2) WT[F[1], F[2]] = 1 }
    LIVE = ENVIRON["CCB_LIVE"]
  }
  $4 != "" {
    c = $4
    st = ($(NF-1) == "-" ? "" : $(NF-1)); ts = $NF                  # facade-joined sidecar columns
                                                                    # (last two: the pair appends after
                                                                    #  launch-args on 8-field rows, after
                                                                    #  parent on 7-field legacy rows)
    rt = ""
    p = lastidx(c, "/.claude/worktrees/"); if (p > 0) rt = substr(c, 1, p-1)
    else { p = lastidx(c, "/.worktrees/"); if (p > 0) rt = substr(c, 1, p-1) }
    auth = (rt != "" && ((rt, c) in WT)) ? 1 : 0                  # only then is PP authoritative
    pc = (auth && ((rt, $2) in PP)) ? PP[rt, $2] : ""
    lh = (LIVE != "" && $3 != "" && index(LIVE, $3) > 0) ? 1 : 0
    print c, $2, $3, $6, $7, st, ts, pc, auth, lh, (auth ? rt : "")
  }')"
n=0; out=""
while IFS="$US" read -r cdir br ref task parent state sts parcfg auth livehit candroot; do
  [ -n "$cdir" ] || continue
  if [ -n "$archive" ]; then
    tab="-"; cell="-"
  else
    if   [ -z "$live" ]; then tab="?"
    elif [ "$livehit" = 1 ]; then tab="✔live"           # a HIT is solid however partial the probe
    elif [ -n "$live_partial" ]; then tab="?"           # a MISS on partial evidence proves nothing
    elif [ -z "$some_live" ]; then tab="?old-session"
    else tab="⌫closed"; fi
    if [ -n "$state" ]; then ccb_age "$sts"; cell="$state($ccb_age_v)"; else cell="-"; fi
  fi
  if [ "$auth" = 1 ]; then                       # merge target: config → 7th field → trunk heuristic
    par="$parcfg"
    [ -n "$par" ] || par="$parent"
    [ -n "$par" ] || par="$("$MERGE" get-parent "$candroot" "$br" 2>/dev/null)"
  else                                           # unbatchable row: the original per-row chain
    par="$(git -C "$cdir" config --get "branch.$br.ccMergeInto" 2>/dev/null)"
    [ -n "$par" ] || par="$parent"
    if [ -z "$par" ]; then
      # F1-class fix (round 2): same discipline as the repo-filter root above — resolve
      # git-common-dir INSIDE the row dir so a linked-worktree row maps to its MAIN repo root
      # (--show-toplevel would answer the worktree itself and get-parent would then miss).
      repo="$( (CDPATH= cd -- "$cdir" 2>/dev/null || exit 1
                _ccg="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 1
                [ -n "$_ccg" ] || exit 1
                CDPATH= cd -- "$_ccg/.." 2>/dev/null || exit 1
                pwd -P) 2>/dev/null )"
      # submodule guard, same TWO OR'd criteria as the repo-filter root above: (a) superproject
      # non-empty — a submodule checkout; (b) the computed root doesn't CONTAIN $cdir — a
      # submodule's LINKED worktree (superproject empty there, .git/modules still not a repo
      # root). Either → --show-toplevel; --separate-git-dir keeps the resolution above. The
      # fallback cd's only on a NON-EMPTY toplevel (`cd -- ""` succeeds in place and would
      # hand back the caller's pwd).
      _cnsup="$(git -C "$cdir" rev-parse --show-superproject-working-tree 2>/dev/null)"
      _cntgt="$( (CDPATH= cd -- "$cdir" 2>/dev/null && pwd -P) 2>/dev/null )"
      case "$_cntgt/" in ""|"$repo"/*) _cnin="" ;; *) _cnin=1 ;; esac
      if [ -n "$_cnsup" ] || [ -n "$_cnin" ]; then
        _cntop="$(git -C "$cdir" rev-parse --show-toplevel 2>/dev/null)"
        if [ -n "$_cntop" ]; then
          _cnfb="$( (CDPATH= cd -- "$_cntop" 2>/dev/null && pwd -P) 2>/dev/null )"
          [ -n "$_cnfb" ] && repo="$_cnfb"
        fi
      fi
      [ -n "$repo" ] && par="$("$MERGE" get-parent "$repo" "$br" 2>/dev/null)"
    fi
  fi
  [ -n "$par" ] || par="-"
  out="$out$tab|$br|$par|$cell|$cdir|$task
"
  n=$((n+1))
done <<< "$rows"   # a here-STRING, not a heredoc: no $ / backtick expansion over task summaries

[ "$n" -gt 0 ] || { echo "no records"; exit 0; }
{ echo "TAB|BRANCH|PARENT|STATUS|DIR|TASK"; printf '%s' "$out"; } | column -t -s '|'

# ── trailing notes (live board only) ───────────────────────────────────────────────────
if [ -z "$archive" ]; then
  if [ -n "$live_partial" ]; then
    echo "(note: cmux workspace enumeration was incomplete — liveness partial, so a tab this probe did not reach shows '?' rather than ⌫closed)"
  elif [ -n "$live" ] && [ -z "$some_live" ]; then
    echo "(note: all registered surface refs are stale — cmux was probably restarted → status shows '?old-session'; dirs still exist, cleanup unaffected)"
  fi
  # failure breadcrumb: "built a worktree but no tab" + cc-send fail-open/calibration lines, last 24h.
  # H2: consecutive IDENTICAL messages (timestamp stripped) fold into ONE line + (×N) — a verify
  # false-alarm firing on every child report otherwise floods this tail with a dozen copies of
  # itself (16-in-a-row on 2026-08-21) and drowns the line that mattered. Fold the WHOLE
  # time-filtered stream, THEN narrow to the display tail: round 2 killed tail-8-then-fold
  # (a 16-run capped at (×8)); round 4 killed its successor tail -60 for the same reason —
  # ANY window cap re-buries the old distinct line once the flood exceeds it. Display-side
  # only; the log stays the
  # append-only truth. CC_SEND_FAILLOG overrides the path (tests, log aggregation) — the same
  # name _ccsend_crumb and cc-hooks.sh use, so all three readers agree.
  flog="${CC_SEND_FAILLOG:-$HOME/.config/cc-stack/cc-failures.log}"
  if [ -f "$flog" ]; then
    recent="$(awk -v cut="$(date -v-1d '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 0)" \
      '$0 >= "["cut { print }' "$flog" 2>/dev/null | awk '
      { raw = $0; msg = raw; sub(/^\[[^]]*\] /, "", msg)
        if (n > 0 && msg == m[n]) { cnt[n]++; line[n] = raw }   # same as previous: bump, keep LATEST ts
        else { n++; m[n] = msg; line[n] = raw; cnt[n] = 1 } }
      END { for (i = 1; i <= n; i++) print line[i] (cnt[i] > 1 ? " (×" cnt[i] ")" : "") }' | tail -3)"
    if [ -n "$recent" ]; then
      echo "⚠ recent dispatch/cc-send failures (see cc-failures.log):"
      printf '%s\n' "$recent" | sed 's/^/   /'
    fi
  fi
fi
exit 0
