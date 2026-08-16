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
#   TAB     cmux surface liveness (one list-pane-surfaces call when ping succeeds; "?" when
#           cmux is unreachable; "?old-session" when no registered ref is alive → restart)
#   PARENT  recorded merge target (branch.<b>.ccMergeInto via the row's own repo), falling
#           back to the 7th TSV field once that config is gone (branch deleted after merge),
#           then cc-merge.sh get-parent's trunk heuristic; "-" when nothing resolves
#   STATUS  sidecar join on dir: working(23m) / idle(2h) / blocked(5m) / "-" ("?" age on a
#           malformed ts) — never "ready": readiness stays owned by gwt-done + a clean tree
# Row rules: rows whose dir no longer exists are pruned on read (locked rewrite under the
#   same mkdir lock the log subcommand appends with); the NEWEST row per dir wins (the archive
#   keeps every row — it's a log, and its dirs are often gone by design).
# Repo filter: only rows under the caller's git root (git rev-parse --show-toplevel from
#   PWD), BOTH sides canonicalized with pwd -P — git reports the physical /private/var/...
#   form on macOS while a stored row can carry the logical /var/... form; outside any repo
#   (or with --all) everything shows.
set -u

# ── log subcommand: append one worktree sub-task record (absorbs cc-tasks-log.sh) ─────────
# The single write point, keeping the TSV format consistent with the render below.
# Called by cc-dispatch.sh surface (hook path and gwt-claude path both land there).
# Fields (TAB-separated): time \t branch \t surface \t dir \t caller-tab \t task-summary \t parent-branch \t launch-args
#   (parent = the caller's branch at dispatch; the board's PARENT column falls back to it
#    once the branch's branch.<b>.ccMergeInto git config is gone, e.g. deleted after merge)
#   launch-args (8th field, roadmap 2 gwt-resume) = compact k=v:... record of the dispatch-time
#   launch: uuid=<claude session id> provider=<cld name|anthropic> pm=<permission-mode> model=<id>,
#   empty parts omitted (model is composed LAST so a model id may itself contain colons).
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

ccb_canon(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }

# repo-filter root: the caller's git top-level from PWD, canonicalized ("" → no filter)
root=""
if [ -z "$all" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$root" ]; then
    root="$(ccb_canon "$root" || true)"
    [ -n "$root" ] || root=""
  fi
fi

# ── prune-on-read (live board only): drop rows whose dir no longer exists ──────────────
# Same rewrite discipline as worktree.zsh's _gwt_tasks_rewrite: read→rewrite under the mkdir
# lock shared with the log subcommand's append, so a concurrent append can't be lost.
if [ -z "$archive" ] && [ -f "$tasks" ]; then
  lock="$tasks.lock" got=""
  i=0; while [ "$i" -lt 60 ]; do mkdir "$lock" 2>/dev/null && { got=1; break; }; sleep 0.05; i=$((i+1)); done
  tmp="$tasks.tmp.$$"
  : > "$tmp"
  while IFS=$'\t' read -r ts br ref dir caller task parent; do
    [ -n "$dir" ] && [ -d "$dir" ] && \
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$br" "$ref" "$dir" "$caller" "$task" "${parent:-}" >> "$tmp"
  done < "$tasks"
  mv "$tmp" "$tasks"
  [ -s "$tasks" ] || rm -f "$tasks"
  [ -n "$got" ] && rmdir "$lock" 2>/dev/null
fi

if [ ! -f "$f" ]; then
  if [ -n "$archive" ]; then echo "no archived tasks"; else echo "no registered worktree tasks"; fi
  exit 0
fi

# ── tab liveness: one cmux call (live board only) ─────────────────────────────────────
live=""
if [ -z "$archive" ] && command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1; then
  live="$(cmux list-pane-surfaces 2>/dev/null)"
fi
# (C) surface refs are session-scoped; after a cmux restart they all become stale. If NO
# registered ref is alive, refs are stale rather than tabs closed → "?old-session".
some_live=""
if [ -n "$live" ]; then
  while IFS=$'\t' read -r _ _ r _ _ _ _; do
    if [ -n "$r" ] && printf '%s\n' "$live" | grep -qF -- "$r"; then some_live=1; break; fi
  done < "$f"
fi

# ── cell helpers ───────────────────────────────────────────────────────────────────────
ccb_now="$(date +%s)"
ccb_age(){   # <unix-ts> → 23m / 2h / 5d; "?" on a malformed ts
  local ts="$1" age
  case "$ts" in ''|*[!0-9]*) echo "?"; return 0 ;; esac
  age=$(( ccb_now - ts ))
  [ "$age" -lt 0 ] && age=0
  if   [ "$age" -lt 3600   ]; then echo "$(( age / 60 ))m"
  elif [ "$age" -lt 86400 ]; then echo "$(( age / 3600 ))h"
  else echo "$(( age / 86400 ))d"; fi
}
ccb_state(){ # <dir> → "working(23m)"-style cell from the sidecar (newest row), "-" without one
  local s
  s="$(awk -F'\t' -v d="$1" '$1==d{v=$2 "\t" $3} END{if(v!="")print v}' "$status" 2>/dev/null)"
  [ -n "$s" ] || { echo "-"; return 0; }
  echo "${s%%$'\t'*}($(ccb_age "${s#*$'\t'}"))"
}
ccb_parent(){ # <dir> <branch> <7th-field> → merge target (see header for the fallback chain)
  local cfg repo
  cfg="$(git -C "$1" config --get "branch.$2.ccMergeInto" 2>/dev/null)"
  [ -n "$cfg" ] && { echo "$cfg"; return 0; }
  [ -n "$3" ] && { echo "$3"; return 0; }
  repo="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$repo" ] && "$MERGE" get-parent "$repo" "$2" 2>/dev/null
}

# ── render ─────────────────────────────────────────────────────────────────────────────
# Live board reads the file bottom-up so the FIRST time a dir appears is its newest record;
# the archive keeps every row in file order (it's a history). `merged` consumes the archive's
# trailing field(s) (merged-at, not displayed; launch-args rides in front of it on 9-field rows)
# — without that last variable the trailing fields would be absorbed into `parent` and shift
# the PARENT column.
seen=""; n=0; out=""
while IFS=$'\t' read -r ts br ref dir caller task parent merged; do
  [ -n "$dir" ] || continue
  cdir="$(ccb_canon "$dir")"; [ -n "$cdir" ] || cdir="$dir"
  if [ -n "$root" ]; then
    case "$cdir" in "$root"|"$root"/*) ;; *) continue ;; esac
  fi
  if [ -z "$archive" ]; then
    printf '%s\n' "$seen" | grep -qxF -- "$cdir" && continue
    seen="$seen$cdir
"
  fi
  if [ -n "$archive" ]; then
    tab="-"; cell="-"
  else
    if   [ -z "$live" ]; then tab="?"
    elif [ -n "$ref" ] && printf '%s\n' "$live" | grep -qF -- "$ref"; then tab="✔live"
    elif [ -z "$some_live" ]; then tab="?old-session"
    else tab="⌫closed"; fi
    cell="$(ccb_state "$cdir")"
  fi
  par="$(ccb_parent "$cdir" "$br" "${parent:-}")"
  [ -n "$par" ] || par="-"
  out="$out$tab|$br|$par|$cell|$cdir|$task
"
  n=$((n+1))
done < <([ -z "$archive" ] && tail -r "$f" || cat "$f")

[ "$n" -gt 0 ] || { echo "no records"; exit 0; }
{ echo "TAB|BRANCH|PARENT|STATUS|DIR|TASK"; printf '%s' "$out"; } | column -t -s '|'

# ── trailing notes (live board only) ───────────────────────────────────────────────────
if [ -z "$archive" ]; then
  if [ -n "$live" ] && [ -z "$some_live" ]; then
    echo "(note: all registered surface refs are stale — cmux was probably restarted → status shows '?old-session'; dirs still exist, cleanup unaffected)"
  fi
  # failure breadcrumb: "built a worktree but no tab" + cc-send fail-open/calibration lines, last 24h
  flog="$HOME/.config/cc-stack/cc-failures.log"
  if [ -f "$flog" ]; then
    recent="$(awk -v cut="$(date -v-1d '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 0)" '$0 >= "["cut' "$flog" 2>/dev/null | tail -3)"
    if [ -n "$recent" ]; then
      echo "⚠ recent dispatch/cc-send failures (see cc-failures.log):"
      printf '%s\n' "$recent" | sed 's/^/   /'
    fi
  fi
fi
exit 0
