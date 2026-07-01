# cc-stack · git worktree workflow (zsh functions, must be sourced)
# Conventions:
#   worktree dir   prefer <project>/.claude/worktrees/<name> (when the project has .claude),
#                  otherwise <project>/.worktrees/<name>
#   the chosen base dir is auto-added to the project .gitignore
#   branch         <prefix>/<name> (default prefix: feat)
#   files auto-copied into a new worktree (gitignored but needed; space-separated relative paths, no spaces in paths):
: ${CC_WT_COPY:=".env .env.local .claude/settings.local.json"}

# Main repo root: returns the main repo root whether you're in the main repo or in some worktree
_gwt_root() {
  local g; g="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  g="${g:A}"; echo "${g:h}"
}
_gwt_repo() { basename "$(_gwt_root)" }

# worktree base dir: prefer .claude/worktrees, otherwise .worktrees
_gwt_dir() {
  local root; root="$(_gwt_root)" || return 1
  if [[ -d "$root/.claude" ]]; then echo "$root/.claude/worktrees"; else echo "$root/.worktrees"; fi
}

# Ensure a path is ignored by the project .gitignore (idempotent)
_gwt_ensure_ignore() {
  local root="$1" entry="$2" gi="$1/.gitignore"
  [[ -f "$gi" ]] && grep -qxF "$entry" "$gi" 2>/dev/null && return 0
  printf '%s\n' "$entry" >> "$gi" && echo "  ↳ .gitignore now ignores $entry"
}

# ── Task list (worktree-tasks.tsv) maintenance ───────────────────────────────
_gwt_tasks_file() { echo "${CC_TASKS_FILE:-$HOME/.config/cc-stack/worktree-tasks.tsv}" }

# Rewrite the list by a "keep predicate": keep the line if keep_fn returns 0; delete the file if it ends up empty. The filter receives $dir.
_gwt_tasks_rewrite() {
  emulate -L zsh
  local f; f="$(_gwt_tasks_file)"; [[ -f "$f" ]] || return 0
  local keep_fn="$1" tmp="$f.tmp.$$" lock="$f.lock" got= i
  # Share one mkdir lock with cc-tasks-log.sh's append, to avoid losing a concurrent append during read→mv
  for i in {1..60}; do mkdir "$lock" 2>/dev/null && { got=1; break }; sleep 0.05; done
  local ts branch ref dir caller task
  : > "$tmp"
  while IFS=$'\t' read -r ts branch ref dir caller task; do
    "$keep_fn" "$dir" && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$branch" "$ref" "$dir" "$caller" "$task" >> "$tmp"
  done < "$f"
  mv "$tmp" "$f"
  [[ -s "$f" ]] || rm -f "$f"
  [[ -n "$got" ]] && rmdir "$lock" 2>/dev/null
  return 0
}

# Drop all records for a given dir (used by gwt-rm): keep lines where dir != target
_gwt_tasks_drop_dir() {
  emulate -L zsh
  local target="$1"; [[ -n "$target" ]] || return 0
  _gwt_drop_target="$target"
  _gwt_tasks_rewrite '_gwt_keep_not_target'
  unset _gwt_drop_target
}
_gwt_keep_not_target() { [[ "$1" != "$_gwt_drop_target" ]] }

# Drop records whose dir no longer exists (used by gwt-status): keep lines whose dir still exists (even if the tab is closed)
_gwt_tasks_prune_dead() { _gwt_tasks_rewrite '_gwt_keep_dir_exists' }
_gwt_keep_dir_exists() { [[ -n "$1" && -d "$1" ]] }

# gwt-new <name> [branch-prefix=feat] [base=HEAD] — create/reuse a worktree and cd into it
gwt-new() {
  emulate -L zsh
  local name="$1" prefix="${2:-feat}" base="${3:-HEAD}"
  [[ -n "$name" ]] || { echo "usage: gwt-new <name> [branch-prefix=feat] [base=HEAD]"; return 1 }
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  local wtdir; wtdir="$(_gwt_dir)"
  local rel="${wtdir#$root/}"                 # .claude/worktrees or .worktrees
  _gwt_ensure_ignore "$root" "/$rel/"
  local wtpath="$wtdir/$name" branch="$prefix/$name"
  mkdir -p "$wtdir"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add "$wtpath" "$branch" || return 1
  else
    git worktree add "$wtpath" -b "$branch" "$base" || return 1
  fi
  local f
  for f in ${(s: :)CC_WT_COPY}; do
    if [[ -f "$root/$f" ]]; then
      mkdir -p "$wtpath/${f:h}"; cp -p "$root/$f" "$wtpath/$f" && echo "  ↳ copied $f"
    fi
  done
  echo "✔ worktree: $wtpath   branch: $branch"
  # When inside cmux, open a workspace (empty shell, focus it) for this worktree; no-op when not in cmux
  ~/.config/cc-stack/cc-cmux-workspace.sh "$wtpath" "$name" true >/dev/null 2>&1
  cd "$wtpath"
}

# gwt-ls — list all worktrees
gwt-ls() { git worktree list }

# gwt-status — list registered worktree sub-tasks, flag whether each is alive + what it's doing
#   data source: $CC_TASKS_FILE, appended by cc-cmux-surface-claude.sh whenever it opens a tab
#   fields: time \t branch \t surface \t dir \t caller-tab \t task-summary
gwt-status() {
  emulate -L zsh
  local f; f="$(_gwt_tasks_file)"
  _gwt_tasks_prune_dead          # auto-clean: records whose dir was deleted (keep ones that are merely tab-closed)
  [[ -f "$f" ]] || { echo "no registered worktree tasks"; return 0 }
  # Live surface list (to tell if a tab still exists); if we can't reach cmux, don't judge tab state
  local live=""
  if command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1; then
    live="$(cmux list-pane-surfaces 2>/dev/null)"
  fi
  # (C) surface refs are session-scoped; after a cmux restart they all become stale. First check "is any registered ref still alive":
  #     yes → same cmux session as when registered, so a missing ref means genuinely closed; no → likely restarted, refs stale rather than tabs closed.
  local some_live="" r
  if [[ -n "$live" ]]; then
    while IFS=$'\t' read -r _ _ r _ _ _; do
      [[ -n "$r" ]] && grep -qF "$r" <<<"$live" && { some_live=1; break }
    done < "$f"
  fi
  typeset -A seen
  local -a rows
  local ts branch ref dir caller task st
  # Read in reverse: the first time a dir appears is its newest record (after prune all dirs exist)
  while IFS=$'\t' read -r ts branch ref dir caller task; do
    [[ -n "$dir" ]] || continue
    [[ -n "${seen[$dir]:-}" ]] && continue
    seen[$dir]=1
    if [[ -z "$live" ]]; then          st="?no-cmux"    # can't reach cmux, can't tell
    elif grep -qF "$ref" <<<"$live"; then st="✔live"
    elif [[ -z "$some_live" ]]; then    st="?old-session"  # no ref alive at all → likely a cmux restart, refs stale
    else                                 st="⌫closed"     # this ref is gone within the same session → the tab really closed
    fi
    rows+=("$st|${branch:-?}|${ref:-?}|$dir|$task")
  done < <(tail -r "$f")
  (( ${#rows} )) || { echo "no records"; return 0 }
  { echo "STATUS|BRANCH|SURFACE|DIR|TASK"; printf '%s\n' "${rows[@]}"; } | column -t -s '|'
  [[ -n "$live" && -z "$some_live" ]] && echo "(note: all registered surface refs are stale — cmux was probably restarted → status shows '?old-session'; dirs still exist, cleanup unaffected)"
  # Failure breadcrumb: if there were "built a worktree but no tab" failures in the last 24h, warn
  local flog="$HOME/.config/cc-stack/cc-failures.log"
  if [[ -f "$flog" ]]; then
    local recent; recent=$(awk -v cut="$(date -v-1d '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 0)" '$0 >= "["cut' "$flog" 2>/dev/null | tail -3)
    [[ -n "$recent" ]] && { echo "⚠ recent worktrees that failed to open a tab (fix with gwt-claude):"; echo "$recent" | sed 's/^/   /'; }
  fi
  return 0
}

# gwt-prune — compact the task list: drop dead-dir records + keep only the newest per dir
gwt-prune() {
  emulate -L zsh
  local f; f="$(_gwt_tasks_file)"; [[ -f "$f" ]] || { echo "list is empty"; return 0 }
  _gwt_tasks_prune_dead
  [[ -f "$f" ]] || { echo "✔ emptied (no live records)"; return 0 }
  typeset -A seen; local tmp="$f.tmp.$$" ts branch ref dir caller task
  : > "$tmp"
  while IFS=$'\t' read -r ts branch ref dir caller task; do
    [[ -n "$dir" && -z "${seen[$dir]:-}" ]] || continue
    seen[$dir]=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$branch" "$ref" "$dir" "$caller" "$task"
  done < <(tail -r "$f") | tail -r > "$tmp"
  mv "$tmp" "$f"; [[ -s "$f" ]] || rm -f "$f"
  echo "✔ task list compacted"
}

# gwt-help — cc-stack worktree command cheatsheet
gwt-help() {
  cat <<'EOF'
cc-stack · worktree sub-task commands
  gwt-claude <name> "<initial-prompt>"   build worktree + new tab running claude (plan mode) + send prompt
  gwt-new <name>                         build worktree and cd into it (opens an empty workspace, no claude)
  gwt-ls                                 git worktree list
  gwt-status                             list sub-tasks: status/branch/surface/dir/what-it's-doing (auto-cleans deleted dirs)
  gwt-rm <name> [--branch]               remove worktree (+ clear task record + pre-trust; optionally the branch)
  gwt-prune                              compact the task list (drop dead records + keep newest per dir)
  gwt-clean                              git worktree prune + show current state
  gwt-fan                                (zellij only) fan each worktree into its own pane running claude
Note: telling the main Claude to "open a worktree / spin off a sub-task" auto-triggers the hook to open a parallel tab;
      sub-tasks default to plan mode (plan first, then edit); commit/merge/cleanup all require human authorization.
EOF
}

# gwt-rm <name> [--branch] — remove a worktree, optionally its branch too
gwt-rm() {
  emulate -L zsh
  local name="$1"
  [[ -n "$name" ]] || { echo "usage: gwt-rm <name> [--branch]"; return 1 }
  local wtpath="$(_gwt_dir)/$name"
  local wtabs; wtabs="$(cd "$wtpath" 2>/dev/null && pwd -P)"   # canonical path (before removal) for bookkeeping
  git worktree remove "$wtpath" 2>/dev/null || git worktree remove --force "$wtpath" || return 1
  echo "✔ removed worktree: $wtpath"
  _gwt_tasks_drop_dir "${wtabs:-$wtpath}" && echo "  ↳ removed from task list"
  ~/.config/cc-stack/cc-trust.sh --remove "${wtabs:-$wtpath}" >/dev/null 2>&1   # clear the pre-trust entry (only pure-trust-signature ones)
  [[ "$2" == "--branch" ]] && { git branch -D "feat/$name" 2>/dev/null && echo "✔ deleted branch feat/$name" }
  return 0
}

# gwt-clean — safe cleanup: prune stale entries and list current state (doesn't auto-delete; use gwt-rm to delete)
gwt-clean() {
  emulate -L zsh
  _gwt_root >/dev/null || { echo "✗ not inside a git repo"; return 1 }
  git worktree prune
  echo "✔ pruned stale entries. Current worktrees:"
  git worktree list
  echo "  (delete one with: gwt-rm <name> [--branch])"
}

# gwt-fan — fan each worktree of the current repo into a zellij pane running claude (zellij fallback channel only)
gwt-fan() {
  if [[ -n "${ZELLIJ:-}" ]]; then
    ~/.config/cc-stack/cc-zellij-fan.sh
  else
    echo "gwt-fan is only for the zellij fallback channel. Locally use ccteam (cmux native teams, better notifications)."
    return 1
  fi
}
