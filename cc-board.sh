#!/usr/bin/env bash
# cc-stack · the worktree sub-task board — ONE implementation, callable from ANY shell.
#   gwt-status (worktree.zsh) is a thin wrapper around this script; Claude's non-interactive
#   Bash tool invokes it directly (`bash ~/.config/cc-stack/cc-board.sh [--all]`) because the
#   old zsh-only render silently printed nothing there (the cmux tree + capture-pane
#   workaround is retired).
# Usage: cc-board.sh log <worktree-dir> <surface_ref> <caller_surface> <initial-prompt> [parent-branch] [launch-args]
#          append one worktree sub-task record (the single write point; absorbs cc-tasks-log.sh)
# Usage: cc-board.sh [--all] [--archive]
#   (default)  live board: worktree-tasks.tsv joined with the worktree-status.tsv sidecar
#   --all      disable the repo filter (rows from every repo)
#   --archive  render worktree-tasks-archive.tsv (merged tasks; what gwt-log shows)
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
# Row rules: rows whose dir no longer exists are pruned on read (locked rewrite under the
#   same mkdir lock the log subcommand appends with) — from the tasks list AND from the status
#   sidecar, which nothing but gwt-prune/gwt-rm used to sweep; the NEWEST row per dir wins (the
#   archive keeps every row — it's a log, and its dirs are often gone by design, and rendering
#   it never rewrites either live file).
# Reading the TSVs: awk -F'\t' only, and rewrites re-emit whole rows — see the discipline note
#   below; a `read` loop collapses runs of TAB and fossilizes the shift on the next rewrite.
# Repo filter: only rows under the caller's MAIN repo root (the _cc_gitroot discipline, see the
#   F1 note below — git-common-dir resolved INSIDE the target dir, so a linked worktree maps to
#   its parent repo; --show-toplevel would answer the worktree itself), BOTH sides canonicalized
#   with pwd -P — git reports the physical /private/var/... form on macOS while a stored row can
#   carry the logical /var/... form; outside any repo (or with --all) everything shows.
set -u

# ── log subcommand: append one worktree sub-task record (absorbs cc-tasks-log.sh) ─────────
# The single write point, keeping the TSV format consistent with the render below.
# Called by cc-dispatch.sh surface (hook path and gwt-claude path both land there).
# Fields (TAB-separated): time \t branch \t surface \t dir \t caller-tab \t task-summary \t parent-branch \t launch-args
#   (parent = the caller's branch at dispatch; the board's PARENT column falls back to it
#    once the branch's branch.<b>.ccMergeInto git config is gone, e.g. deleted after merge)
#   launch-args (8th field, roadmap 2 gwt-resume) = compact k=v:... record of the dispatch-time
#   launch, colon-separated, empty parts omitted, written in this order:
#     uuid=<claude session id>:provider=<cld name|anthropic>:pm=<permission-mode>
#     :csuuid=<CALLER surface uuid>:suuid=<CHILD tab surface uuid>:model=<id>
#   model stays LAST (a model id may itself contain colons — every parser stops there).
#   csuuid/suuid (2026-08-16, tab-close permission model) are cmux SURFACE UUIDs, the only stable
#   tab identities there are: short refs (surface:283) drift as panes open and close, so the 3rd
#   field is an address, never an identity. csuuid = the session that dispatched this sub-task
#   (the one allowed to close its tab while it is still running), suuid = the sub-task tab itself.
#   Read by `cc-dispatch.sh close`; kept fresh across a cmux restart by gwt-resume. Rows without
#   them (pre-feature) have no recorded owner here — the close primitive then falls back to the
#   opened-tabs ledger (opened-tabs.tsv), and refuses when neither ledger names an owner.
#   POSITION: appended AFTER parent-branch, i.e. the LAST live-board field — every positional
#   reader keys on fields 1-7 (cc-hooks.sh status matches $4 = dir; the PARENT fallback reads the
#   7th), and the archive appends merged-at after it (live 8 fields → archive 9). Old 7-field rows
#   stay valid: bash/zsh `read` gives the LAST variable the remainder WITH its TABs, so the rewriters
#   below and in worktree.zsh round-trip the extra field untouched. Rows before this feature carry
#   no uuid → gwt-resume degrades them to an idle ccteam tab (visible, never silent).
if [ "${1:-}" = "log" ]; then
  shift
  dir="${1:-}"; ref="${2:-?}"; caller="${3:-}"; prompt="${4:-}"; parent="${5:-}"; largs="${6:-}"
  [ -n "$dir" ] || exit 0
  f="${CC_TASKS_FILE:-$HOME/.config/cc-stack/worktree-tasks.tsv}"

  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  # Task summary: collapse to one line, strip TAB/pipe, truncate — keeps TSV and `column` display intact
  summary="$(printf '%s' "$prompt" | tr '\t\n' '  ' | tr '|' '/' | cut -c1-140)"
  [ -n "$summary" ] || summary='(idle ccteam, no initial prompt)'
  # launch-args: composed by cc-dispatch.sh surface; sanitize the same way (one line, no TAB)
  largs="$(printf '%s' "$largs" | tr '\t\n' '  ' | cut -c1-200)"

  # Locked append (avoid losing lines racing with the prune rewrite below). mkdir is atomic; macOS lacks flock.
  lock="$f.lock"
  for _ in $(seq 1 60); do
    if mkdir "$lock" 2>/dev/null; then trap 'rmdir "$lock" 2>/dev/null' EXIT; break; fi
    sleep 0.05
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$branch" "$ref" "$dir" "$caller" "$summary" "$parent" "$largs" \
    >> "$f" 2>/dev/null || true
  exit 0
fi

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

tasks="${CC_TASKS_FILE:-$HOME/.config/cc-stack/worktree-tasks.tsv}"
status="${CC_STATUS_FILE:-$HOME/.config/cc-stack/worktree-status.tsv}"
arch="${CC_ARCHIVE_FILE:-$HOME/.config/cc-stack/worktree-tasks-archive.tsv}"
if [ -n "$archive" ]; then f="$arch"; else f="$tasks"; fi

ccb_canon1(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }   # one-shot (forks); the render uses the batched map below

# ── TSV access discipline (2026-08-16 audit, F1) ───────────────────────────────────────
# NEVER `while IFS=$'\t' read -r a b c …` over these files. TAB is IFS *whitespace*, so bash
# AND zsh collapse RUNS of it: one empty field (parent on a detached HEAD — cc-dispatch.sh's
# `git symbolic-ref --short HEAD` is empty there — or caller on a hand-written row) shifts every
# later field left. Displaying a shifted row is cosmetic; a rewriter that re-printf's the shifted
# VARIABLES writes the shift back and makes it permanent — launch-args lands in the PARENT column,
# after which gwt-resume finds no uuid= (degrades the tab to idle) and `cc-dispatch.sh close`
# finds no csuuid/suuid (fail-closed: refuses to close the tab; the "three tabs only a human
# could close" incident). So: field access goes through awk -F'\t' (the idiom cc-dispatch.sh's
# resume block already documents), and every rewrite re-emits $0 VERBATIM, selecting rows by line
# number. That is also what keeps 7-field legacy rows, 8-field live rows and 9-field archive rows
# byte-identical across a rewrite — no format migration, no placeholder backfill.
US="$(printf '\037')"   # record delimiter for awk→shell handoffs: NOT IFS whitespace, so `read`
                        # preserves empty fields between two of them (a TAB would collapse them)
NL='
'
ccb_has(){ case "$1" in *"$2"*) return 0 ;; esac; return 1; }   # substring test, fork-free
ccb_dead_lines(){  # <file> <dir-field-no> → line numbers whose dir field is empty or gone
  local _l="" _d="" _out=""
  while IFS=$'\t' read -r _l _d; do
    [ -n "$_d" ] && [ -d "$_d" ] || _out="$_out $_l"
  done < <(awk -F'\t' -v c="$2" '{print NR "\t" $(c)}' "$1")
  printf '%s' "$_out"
}
ccb_drop_lines(){  # <file> <line numbers> → rewrite <file> without them, every kept row verbatim
  local _tmp="$1.tmp.$$"
  awk -v drop="$2" 'BEGIN{n=split(drop,a," "); for(i=1;i<=n;i++) D[a[i]]=1} !(FNR in D)' "$1" > "$_tmp" || return 1
  mv "$_tmp" "$1"
  [ -s "$1" ] || rm -f "$1"
  return 0
}
ccb_lock(){    # <file> → take the shared mkdir lock (atomic; macOS lacks flock), "1" when acquired
  local _i=0
  while [ "$_i" -lt 60 ]; do mkdir "$1.lock" 2>/dev/null && { printf '1'; return 0; }; sleep 0.05; _i=$((_i+1)); done
  return 0
}

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

# ── prune-on-read (live board only): drop rows whose dir no longer exists ──────────────
# Same rewrite discipline as worktree.zsh's _gwt_tasks_rewrite: read→rewrite under the mkdir
# lock shared with the log subcommand's append, so a concurrent append can't be lost. Rows are
# selected by LINE NUMBER and re-emitted verbatim — see the TSV access discipline above.
if [ -z "$archive" ] && [ -f "$tasks" ]; then
  got="$(ccb_lock "$tasks")"
  ccb_drop_lines "$tasks" "$(ccb_dead_lines "$tasks" 4)"
  [ -n "$got" ] && rmdir "$tasks.lock" 2>/dev/null
fi

# ── sidecar prune-on-read (live board only) ────────────────────────────────────────────
# worktree-status.tsv used to be swept only by gwt-prune / gwt-rm, so it grew forever (9 rows of
# long-dead test dirs on the author's machine, the oldest three days old). The board already asks
# "does this dir still exist?" once per row, so sweeping the sidecar here is free. Its own mkdir
# lock — the one cc-hooks.sh status appends under — not the tasks lock. Live board only: the
# archive is history and its dirs are gone by design, but the SIDECAR is live state either way,
# so `--archive` must leave it alone rather than sweep it as a side effect of reading history.
if [ -z "$archive" ] && [ -f "$status" ]; then
  sgot="$(ccb_lock "$status")"
  ccb_drop_lines "$status" "$(ccb_dead_lines "$status" 1)"
  [ -n "$sgot" ] && rmdir "$status.lock" 2>/dev/null
fi

if [ ! -f "$f" ]; then
  if [ -n "$archive" ]; then echo "no archived tasks"; else echo "no registered worktree tasks"; fi
  exit 0
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
  done < <(awk -F'\t' '$3 != "" {print $3}' "$f")
fi

# ── batched joins (F13) ────────────────────────────────────────────────────────────────
# The board is the most-run command in this stack and it used to fork 4-5 times PER ROW — a
# `pwd -P` subshell, a `grep` for the newest-per-dir dedup, a `grep` for tab liveness, an `awk`
# over the sidecar, a `git config` for the merge target — plus the `x="$(helper)"` capture
# itself, which is another fork each. 40 rows cost 421ms here.
# Every one of those is a JOIN, so each source is now read ONCE into a table and all the joins
# happen in the single awk pass that builds the render stream (awk hashes; the bash 3.2
# alternative — string tables scanned with ## / case — measured 4x SLOWER than forking at 40
# rows, because a leading-`*` glob over a growing string is quadratic). The shell loop below
# then only formats: no forks, no scans. Fallbacks that cannot be batched (a row that is not a
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

# TABLE 1 — dir → physical dir. One subshell for ALL of them: cd and pwd are builtins, so the
# cost was never the resolution, it was the `$( )` around each one. Relative rows keep resolving
# against the board's own cwd (we cd back every iteration).
ccb_pwd0="$PWD"
ccb_dirs="$(awk -F'\t' '$4 != "" {print $4}' "$f" | sort -u)"
ccb_cmap="$(printf '%s\n' "$ccb_dirs" | while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    CDPATH= cd -P -- "$_d" 2>/dev/null && printf '%s\t%s\n' "$_d" "$PWD"   # -P: $PWD is LOGICAL without it
    cd -- "$ccb_pwd0" 2>/dev/null || :
  done)"

# TABLE 2/3 — branch → merge target, read once PER REPO instead of once per row, plus the repo's
# registered-worktree list. A worktree shares its repo's config, so the candidate root derived
# from the layout (<root>/.claude/worktrees/<n> or <root>/.worktrees/<n>) is only TRUSTED for a
# dir git itself lists as a worktree of it. Anything else — a hand-written row, a nested repo, an
# exotic layout — falls back to the original per-row `git -C <dir> config`, so a branch name that
# exists in two repos can never put the wrong merge target in the column.
ccb_pmap=""; ccb_pwt=""; ccb_roots="$NL"
while IFS=$'\t' read -r _raw _c; do
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
done <<< "$ccb_cmap"

# ── render ─────────────────────────────────────────────────────────────────────────────
# Live board reads the file bottom-up so the FIRST time a dir appears is its newest record (and
# every later row for that dir is dropped); the archive keeps every row in file order (it's a
# history). One awk pass picks the displayed fields BY NUMBER — which is what makes the trailing
# fields a non-issue: the archive's merged-at (8th on a legacy row, 9th behind launch-args) is
# simply not selected and can no longer be absorbed into PARENT — and joins every table above,
# emitting a US-delimited stream the shell only has to format. US, not TAB: it is not IFS
# whitespace, so `read` keeps a row's empty fields instead of collapsing them.
# Tables travel in the ENVIRONMENT rather than -v: awk expands escape sequences in a -v value,
# which would corrupt any path holding a backslash.
rows="$({ [ -z "$archive" ] && tail -r "$f" || cat "$f"; } | \
  CCB_CMAP="$ccb_cmap" CCB_SMAP="$([ -f "$status" ] && cat "$status" 2>/dev/null)" \
  CCB_PMAP="$ccb_pmap" CCB_PWT="$ccb_pwt" CCB_LIVE="$live" CCB_ARCH="$archive" \
  awk -F'\t' -v OFS="$US" '
  function lastidx(s, t,   p, off, at) {           # last occurrence of t in s (0 = none)
    off = 0; at = 0
    while ((p = index(substr(s, off + 1), t)) > 0) { at = off + p; off = at }
    return at
  }
  BEGIN {
    n = split(ENVIRON["CCB_CMAP"], L, "\n")                       # raw dir → physical dir
    for (i = 1; i <= n; i++) { p = index(L[i], "\t"); if (p) CANON[substr(L[i], 1, p-1)] = substr(L[i], p+1) }
    n = split(ENVIRON["CCB_SMAP"], L, "\n")                       # dir → state \t ts (last row wins)
    for (i = 1; i <= n; i++) { p = index(L[i], "\t"); if (p) ST[substr(L[i], 1, p-1)] = substr(L[i], p+1) }
    n = split(ENVIRON["CCB_PMAP"], L, "\n")                       # root, branch → merge target
    for (i = 1; i <= n; i++) { if (split(L[i], F, "\t") == 3) PP[F[1], F[2]] = F[3] }
    n = split(ENVIRON["CCB_PWT"], L, "\n")                        # root, dir → registered worktree
    for (i = 1; i <= n; i++) { if (split(L[i], F, "\t") == 2) WT[F[1], F[2]] = 1 }
    LIVE = ENVIRON["CCB_LIVE"]; ARCH = ENVIRON["CCB_ARCH"]
  }
  $4 != "" {
    c = ($4 in CANON) ? CANON[$4] : $4
    if (ARCH == "") { if (c in SEEN) next; SEEN[c] = 1 }
    st = ""; ts = ""
    if (c in ST) { s = ST[c]; p = index(s, "\t"); if (p) { st = substr(s, 1, p-1); ts = substr(s, p+1) } else st = s }
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
  if [ -n "$root" ]; then
    case "$cdir" in "$root"|"$root"/*) ;; *) continue ;; esac
  fi
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
