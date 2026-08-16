# cc-stack · git worktree workflow (zsh functions, must be sourced)
# Conventions:
#   worktree dir   prefer <project>/.claude/worktrees/<name> (when the project has .claude),
#                  otherwise <project>/.worktrees/<name>
#   the chosen base dir is auto-added to the project .gitignore
#   branch         <prefix>/<name> (default prefix: feat)
#   files auto-copied into a new worktree (gitignored but needed; space-separated relative paths, no spaces in paths):
: ${CC_WT_COPY:=".env .env.local .claude/settings.local.json"}
#   dir(s) SHARED across worktrees as independent copies: seeded from the main repo on create, and
#   merged back into the main repo on gwt-rm (new files folded in; same-name-different-content clashes
#   preserved as <name>.from-<branch>.<ext>, never overwriting main). Regenerable outputs (*-shots,
#   reports, output, html) are skipped. Space-separated relbase dirs; set EMPTY ("") to disable.
#   EXPORT it when customizing/disabling — the hook & gwt-claude paths run outside this shell and
#   otherwise use the default (which lives in cc-worktree-shared.sh).
: ${CC_WT_SHARE="scratchpad/e2e"}

# Dir this file was sourced from (the install dir, or a checkout/worktree when a worktree
# tests itself): sibling scripts like cc-board.sh resolve from here first, falling back to
# ~/.config/cc-stack, so gwt-status/gwt-log always find a cc-board.sh.
_gwt_src_dir="${${(%):-%x}:A:h}"

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

# _gwt_bootstrap_wt <root> <wtpath> <branch> [base=HEAD] — the shared "stand up a worktree" block:
# gitignore guard → worktree add (reuse the branch if it exists, else create from <base>) →
# copy CC_WT_COPY files → seed the shared corpus. Single home for gwt-new AND gwt-adopt.
_gwt_bootstrap_wt() {
  emulate -L zsh
  local root="$1" wtpath="$2" branch="$3" base="${4:-HEAD}"
  local wtdir="${wtpath:h}" rel="${wtdir#$root/}"                 # .claude/worktrees or .worktrees
  _gwt_ensure_ignore "$root" "/$rel/"
  mkdir -p "$wtdir"
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$root" worktree add "$wtpath" "$branch" || return 1
  else
    git -C "$root" worktree add "$wtpath" -b "$branch" "$base" || return 1
  fi
  local f
  for f in ${(s: :)CC_WT_COPY}; do
    if [[ -f "$root/$f" ]]; then
      mkdir -p "$wtpath/${f:h}"; cp -p "$root/$f" "$wtpath/$f" && echo "  ↳ copied $f"
    fi
  done
  [[ -n "$CC_WT_SHARE" ]] && ~/.config/cc-stack/cc-worktree-shared.sh seed "$root" "$wtpath" ${(s: :)CC_WT_SHARE}
}

# ── Task list (worktree-tasks.tsv) maintenance ───────────────────────────────
_gwt_tasks_file() { echo "${CC_TASKS_FILE:-$HOME/.config/cc-stack/worktree-tasks.tsv}" }

# Rewrite the list by a "keep predicate": keep the line if keep_fn returns 0; delete the file if it ends up empty. The filter receives $dir.
_gwt_tasks_rewrite() {
  emulate -L zsh
  local f; f="$(_gwt_tasks_file)"; [[ -f "$f" ]] || return 0
  local keep_fn="$1" tmp="$f.tmp.$$" lock="$f.lock" got= i
  # Share one mkdir lock with cc-board.sh log's append, to avoid losing a concurrent append during read→mv
  for i in {1..60}; do mkdir "$lock" 2>/dev/null && { got=1; break }; sleep 0.05; done
  local ts branch ref dir caller task parent
  : > "$tmp"
  while IFS=$'\t' read -r ts branch ref dir caller task parent; do
    "$keep_fn" "$dir" && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$branch" "$ref" "$dir" "$caller" "$task" "$parent" >> "$tmp"
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

# ── Merged-task archive (worktree-tasks-archive.tsv) ───────────────────────────
# Rows move here when their branch merges: same 7 fields plus an appended 8th merged-at unix
# ts. Rendered by gwt-log (cc-board.sh --archive) with the board's columns and repo filter.
_gwt_archive_file() { echo "${CC_ARCHIVE_FILE:-$HOME/.config/cc-stack/worktree-tasks-archive.tsv}" }

# _gwt_archive_branch <branch> — under the tasks lock, move ALL rows whose branch matches
# into the archive (appending merged-at) and drop their status sidecar rows. Called by
# gwt-merge after a successful merge (or a benign skipped-already-merged), so the board stops
# showing merged work while gwt-log keeps the history.
_gwt_archive_branch() {
  emulate -L zsh
  local branch="$1"; [[ -n "$branch" ]] || return 0
  local f; f="$(_gwt_tasks_file)"; [[ -f "$f" ]] || return 0
  local arch; arch="$(_gwt_archive_file)"
  local lock="$f.lock" got= i tmp="$f.tmp.$$" now ts bref ref dir caller task parent
  local -a moved=()
  for i in {1..60}; do mkdir "$lock" 2>/dev/null && { got=1; break }; sleep 0.05; done
  now="$(date +%s)"
  : > "$tmp"
  while IFS=$'\t' read -r ts bref ref dir caller task parent; do
    if [[ "$bref" == "$branch" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$bref" "$ref" "$dir" "$caller" "$task" "$parent" "$now" >> "$arch"
      [[ -n "$dir" ]] && moved+=("$dir")
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$bref" "$ref" "$dir" "$caller" "$task" "$parent" >> "$tmp"
    fi
  done < "$f"
  mv "$tmp" "$f"
  [[ -s "$f" ]] || rm -f "$f"
  [[ -n "$got" ]] && rmdir "$lock" 2>/dev/null
  local d
  for d in $moved; do _gwt_status_drop_dir "$d"; done
  (( ${#moved} )) && echo "  ↳ archived ${#moved} record(s) for $branch (see gwt-log)"
  return 0
}

# ── Agent-state sidecar (worktree-status.tsv, written by cc-hooks.sh status) ───
# dir \t state \t unix-ts, one row per dir. States: working / idle / blocked — never "ready":
# readiness stays owned by gwt-done + a clean tree, so the sidecar only describes liveness of the agent.
_gwt_status_file() { echo "${CC_STATUS_FILE:-$HOME/.config/cc-stack/worktree-status.tsv}" }

# Rewrite the sidecar by a "keep predicate" (same contract and lock discipline as _gwt_tasks_rewrite;
# cc-hooks.sh status appends under the same $f.lock, so a rewrite here can't lose its row updates)
_gwt_status_rewrite() {
  emulate -L zsh
  local f; f="$(_gwt_status_file)"; [[ -f "$f" ]] || return 0
  local keep_fn="$1" tmp="$f.tmp.$$" lock="$f.lock" got= i
  for i in {1..60}; do mkdir "$lock" 2>/dev/null && { got=1; break }; sleep 0.05; done
  local d st ts
  : > "$tmp"
  while IFS=$'\t' read -r d st ts; do
    "$keep_fn" "$d" && printf '%s\t%s\t%s\n' "$d" "$st" "$ts" >> "$tmp"
  done < "$f"
  mv "$tmp" "$f"
  [[ -s "$f" ]] || rm -f "$f"
  [[ -n "$got" ]] && rmdir "$lock" 2>/dev/null
  return 0
}

# Drop the state row for a removed dir (gwt-rm) — keep rows whose dir differs
_gwt_status_drop_dir() {
  emulate -L zsh
  local target="$1"; [[ -n "$target" ]] || return 0
  _gwt_status_drop_target="$target"
  _gwt_status_rewrite '_gwt_status_keep_not_target'
  unset _gwt_status_drop_target
}
_gwt_status_keep_not_target() { [[ "$1" != "$_gwt_status_drop_target" ]] }

# Drop state rows whose dir no longer exists (gwt-prune) — reuses the board-side predicate
_gwt_status_prune_dead() { _gwt_status_rewrite '_gwt_keep_dir_exists' }

# gwt-new <name> [branch-prefix=feat] [base=HEAD] — create/reuse a worktree and cd into it
gwt-new() {
  emulate -L zsh
  local name="$1" prefix="${2:-feat}" base="${3:-HEAD}"
  [[ -n "$name" ]] || { echo "usage: gwt-new <name> [branch-prefix=feat] [base=HEAD]"; return 1 }
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  local wtpath="$(_gwt_dir)/$name" branch="$prefix/$name"
  _gwt_bootstrap_wt "$root" "$wtpath" "$branch" "$base" || return 1
  echo "✔ worktree: $wtpath   branch: $branch"
  ~/.config/cc-stack/cc-merge.sh capture "$root" "$branch" "$PWD" >/dev/null 2>&1
  # When inside cmux, open a workspace (empty shell, focus it) for this worktree; no-op when not in cmux
  ~/.config/cc-stack/cc-dispatch.sh workspace "$wtpath" "$name" true >/dev/null 2>&1
  cd "$wtpath"
}

# gwt-adopt <branch> [--into <parent>] [--no-worktree] — enroll an EXISTING branch
# into the tree. Records its merge parent (branch.<b>.ccMergeInto) so it shows up
# in gwt-tree and can be gwt-merge'd/gwt-collect'd along the tree, and — unless
# --no-worktree — gives it a worktree (reusing the branch) + a cmux workspace so an
# agent can start on it. Parent defaults to the trunk; --into hangs it elsewhere.
# Unlike gwt-new it does NOT cd and does NOT steal cmux focus, so an orchestrating
# claude can fold hand-made branches into the workflow without disrupting you.
gwt-adopt() {
  emulate -L zsh
  local branch="" parent="" no_wt=""
  while (( $# )); do
    case "$1" in
      --into) parent="$2"; shift 2 ;;
      --no-worktree) no_wt=1; shift ;;
      -*) echo "gwt-adopt: unknown flag $1"; return 1 ;;
      *) if [[ -z "$branch" ]]; then branch="$1"; shift; else echo "gwt-adopt: unexpected arg $1"; return 1; fi ;;
    esac
  done
  [[ -n "$branch" ]] || { echo "usage: gwt-adopt <branch> [--into <parent>] [--no-worktree]"; return 1 }
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  git -C "$root" show-ref --verify --quiet "refs/heads/$branch" || { echo "✗ no such branch: $branch"; return 1 }
  local trunk; trunk="$(~/.config/cc-stack/cc-merge.sh trunk "$root")"
  [[ "$branch" == "$trunk" ]] && { echo "✗ $branch is the trunk — nothing to adopt"; return 1 }
  [[ -n "$parent" ]] || parent="$trunk"
  [[ "$parent" == "$branch" ]] && { echo "✗ a branch cannot be its own parent"; return 1 }
  git -C "$root" show-ref --verify --quiet "refs/heads/$parent" || { echo "✗ no such parent branch: $parent"; return 1 }

  # Record the merge parent → the branch now participates in the tree/merge.
  ~/.config/cc-stack/cc-merge.sh set-parent "$root" "$branch" "$parent" || return 1
  echo "✔ adopted $branch  → merges into $parent"
  [[ -n "$no_wt" ]] && { echo "  (registered only — run without --no-worktree to add a worktree)"; return 0 }

  # Already checked out somewhere? leave that worktree in place.
  if git -C "$root" worktree list --porcelain | grep -qxF "branch refs/heads/$branch"; then
    echo "  ↳ $branch already has a worktree; leaving it in place"; return 0
  fi
  local name="${branch//\//-}"                 # feature/x → feature-x (collision-free dir)
  local wtpath="$(_gwt_dir)/$name"
  _gwt_bootstrap_wt "$root" "$wtpath" "$branch" || return 1
  echo "  ↳ worktree: $wtpath"
  # focus=false: enrolling a branch must not yank you out of what you're doing.
  ~/.config/cc-stack/cc-dispatch.sh workspace "$wtpath" "$name" false >/dev/null 2>&1
}

# gwt-ls — list all worktrees
gwt-ls() { git worktree list }

# gwt-status — THE board command: list registered worktree sub-tasks. Thin wrapper that runs
#   cc-board.sh in bash so the SAME implementation works from any shell (Claude's non-interactive
#   Bash included — the old zsh-only render silently printed nothing there). Args are forwarded
#   (--all: rows from every repo, not just the current one).
#   data source 1: $CC_TASKS_FILE, appended by cc-dispatch.sh surface whenever it opens a tab
#     fields: time \t branch \t surface \t dir \t caller-tab \t task-summary \t parent-branch
#   data source 2: $CC_STATUS_FILE sidecar (dir \t state \t unix-ts), written by cc-hooks.sh status on
#     UserPromptSubmit/Stop/permission-Notification → STATUS column, joined on dir. idle = not-running,
#     NOT done — "ready" still comes only from gwt-done + a clean tree (gwt-tree), never from here.
#   Output contract (unchanged since the zsh original): header has TAB before STATUS; STATUS
#   cells working(23m)/idle(2h)/blocked(5m), "-" when the hook never fired.
# cc-board.sh sits next to this file when a worktree tests itself, else in the install dir.
_gwt_board_script() {
  local d="${_gwt_src_dir:-}"
  [[ -n "$d" && -f "$d/cc-board.sh" ]] && { echo "$d/cc-board.sh"; return 0 }
  echo "$HOME/.config/cc-stack/cc-board.sh"
}
gwt-status() {
  emulate -L zsh
  bash "$(_gwt_board_script)" "$@"
  return $?
}

# gwt-log — render the merged-task archive (worktree-tasks-archive.tsv): same columns and repo
#   filter as gwt-status, fed by the rows gwt-merge moved out of the live board on merge.
gwt-log() {
  emulate -L zsh
  bash "$(_gwt_board_script)" --archive "$@"
  return $?
}

# gwt-prune — compact the task list: drop dead-dir records + keep only the newest per dir
gwt-prune() {
  emulate -L zsh
  _gwt_status_prune_dead          # sweep the agent-state sidecar too (rows whose dir vanished)
  local f; f="$(_gwt_tasks_file)"; [[ -f "$f" ]] || { echo "list is empty"; return 0 }
  _gwt_tasks_prune_dead
  [[ -f "$f" ]] || { echo "✔ emptied (no live records)"; return 0 }
  typeset -A seen; local tmp="$f.tmp.$$" ts branch ref dir caller task parent
  : > "$tmp"
  while IFS=$'\t' read -r ts branch ref dir caller task parent; do
    [[ -n "$dir" && -z "${seen[$dir]:-}" ]] || continue
    seen[$dir]=1
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$branch" "$ref" "$dir" "$caller" "$task" "$parent"
  done < <(tail -r "$f") | tail -r > "$tmp"
  mv "$tmp" "$f"; [[ -s "$f" ]] || rm -f "$f"
  echo "✔ task list compacted"
}

# _gwt_tree_render <node> <prefix> — recursive tree drawer (uses _gt_* globals set by gwt-tree)
_gwt_tree_render() {
  emulate -L zsh
  local node="$1" prefix="$2"
  local kids=(${=_gt_kids[$node]:-})
  local n=${#kids} i=1 kid conn childprefix
  for kid in $kids; do
    if (( i == n )); then conn="└─ "; childprefix="$prefix   "; else conn="├─ "; childprefix="$prefix│  "; fi
    local ahead="${_gt_ahead[$kid]}" dirty="${_gt_dirty[$kid]}" dn="${_gt_done[$kid]}"
    local doneflag=""; [[ "$dn" == done ]] && doneflag="✓done"
    local rf="${_gt_ref[$kid]:-}" tab=""
    if [[ -z "$_gt_live" ]]; then tab="?"
    elif [[ -n "$rf" ]] && grep -qF "$rf" <<<"$_gt_live"; then tab="✔live"
    elif [[ -n "$rf" ]]; then tab="⌫closed"; else tab="-"; fi
    local ready=""
    # NOTE: tab= and ready= MUST keep initial values — a bare `local x` in this
    # recursive function reprints x (zsh typeset-p behavior) at depth >=2.
    if [[ "$dirty" == clean && "$dn" == done ]]; then ready="ready ✅"; else ready="not ready ⏳"; fi
    local grandkids=(${=_gt_kids[$kid]:-}) summary=""
    if (( ${#grandkids} )); then
      local r=0 gk
      for gk in $grandkids; do [[ "${_gt_dirty[$gk]}" == clean && "${_gt_done[$gk]}" == done ]] && (( r++ )); done
      summary="  children: $r/${#grandkids} ready"
    fi
    printf '%s%s%-14s ↑%-3s %-5s %-6s [%s]  → %s%s\n' \
      "$prefix" "$conn" "$kid" "$ahead" "$dirty" "$doneflag" "$tab" "$ready" "$summary"
    _gwt_tree_render "$kid" "$childprefix"
    (( i++ ))
  done
}

# gwt-tree — hierarchical board: nested branch tree by merge-target, git state, ready flag, tab liveness
gwt-tree() {
  emulate -L zsh
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  local data; data="$(~/.config/cc-stack/cc-merge.sh tree "$root")"
  [[ -n "$data" ]] || { echo "no worktree branches (nothing to show)"; return 0 }
  local trunk; trunk="$(~/.config/cc-stack/cc-merge.sh trunk "$root")"
  # tab liveness (best-effort)
  typeset -gA _gt_ref _gt_parent _gt_ahead _gt_dirty _gt_done _gt_kids
  _gt_ref=(); _gt_parent=(); _gt_ahead=(); _gt_dirty=(); _gt_done=(); _gt_kids=()
  _gt_live=""
  command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 && _gt_live="$(cmux list-pane-surfaces 2>/dev/null)"
  local f; f="$(_gwt_tasks_file)"
  if [[ -f "$f" ]]; then
    local ts br rf dir cl tk pt
    while IFS=$'\t' read -r ts br rf dir cl tk pt; do [[ -n "$br" ]] && _gt_ref[$br]="$rf"; done < "$f"
  fi
  local branch parent ahead dirty dn
  while IFS=$'\t' read -r branch parent ahead dirty dn; do
    [[ -n "$branch" ]] || continue
    _gt_parent[$branch]="$parent"; _gt_ahead[$branch]="$ahead"
    _gt_dirty[$branch]="$dirty"; _gt_done[$branch]="$dn"
    _gt_kids[$parent]="${_gt_kids[$parent]:-} $branch"
  done <<< "$data"
  echo "$trunk"
  _gwt_tree_render "$trunk" ""
  unset _gt_ref _gt_parent _gt_ahead _gt_dirty _gt_done _gt_kids _gt_live
}

# gwt-done / gwt-undone — mark the current worktree's branch ready (harmless annotation, no gate)
gwt-done() {
  emulate -L zsh
  local root b; root="$(_gwt_root)" || return 1
  b="$(git symbolic-ref --short HEAD 2>/dev/null)" || { echo "✗ detached HEAD"; return 1 }
  ~/.config/cc-stack/cc-merge.sh done "$root" "$b" true && echo "✔ $b marked ready (gwt-done)"
}
gwt-undone() {
  emulate -L zsh
  local root b; root="$(_gwt_root)" || return 1
  b="$(git symbolic-ref --short HEAD 2>/dev/null)" || { echo "✗ detached HEAD"; return 1 }
  ~/.config/cc-stack/cc-merge.sh done "$root" "$b" false && echo "✔ $b marked not-ready"
}

# gwt-merge <name-or-branch> [--squash|--no-ff|--rebase] [--into <b>] [--message <text>] [--force] — GATED merge
gwt-merge() {
  emulate -L zsh
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  local arg="$1"; shift 2>/dev/null
  [[ -n "$arg" ]] || { echo "usage: gwt-merge <name|branch> [--squash|--no-ff|--rebase] [--into <b>] [--message <text>] [--force]"; return 1 }
  # accept a bare name (feat/<name>) or a full branch
  local child="$arg"
  git -C "$root" show-ref --verify --quiet "refs/heads/$child" || child="feat/$arg"
  git -C "$root" show-ref --verify --quiet "refs/heads/$child" || { echo "✗ no such branch: $arg"; return 1 }
  local strategy="" target="" force="" message=""
  while (( $# )); do
    case "$1" in
      --squash) strategy=squash ;; --no-ff) strategy=no-ff ;; --rebase) strategy=rebase ;;
      --into) shift; target="$1" ;; --message) shift; message="$1" ;; --force) force=1 ;;
      *) echo "unknown flag: $1"; return 1 ;;
    esac; shift
  done
  [[ -n "$target" ]] || target="$(~/.config/cc-stack/cc-merge.sh get-parent "$root" "$child")"
  # ordering guard: if child itself has not-ready children, warn
  local kids; kids="$(~/.config/cc-stack/cc-merge.sh tree "$root" | awk -F'\t' -v p="$child" '$2==p && !($4=="clean" && $5=="done"){print $1}')"
  [[ -n "$kids" ]] && echo "⚠ $child still has not-ready children: ${kids//$'\n'/, } — consider 'gwt-collect $child' first"
  echo "── preflight: $child → $target ──"
  local pf rc; pf="$(~/.config/cc-stack/cc-merge.sh preflight "$root" "$child" "$target")"; rc=$?
  echo "$pf" | grep '^check:'
  if (( rc != 0 )) && [[ -z "$force" ]]; then
    echo "✗ preflight not clean. Re-run with --force to override, or fix the flagged items."; return 1
  fi
  # strategy prompt (default squash). Squash collapses the child's history but stamps a
  # Child-Tip: <sha> trailer so the retired ref stays verifiable; no-ff keeps full history.
  if [[ -z "$strategy" ]]; then
    printf "strategy? [S]quash / [n]o-ff / [r]ebase (default squash): "
    local ans; read -r ans
    case "$ans" in n|N|no-ff) strategy=no-ff ;; r|R|rebase) strategy=rebase ;; *) strategy=squash ;; esac
  fi
  # AUTHORIZATION GATE
  printf "About to merge \033[1m%s\033[0m --%s into \033[1m%s\033[0m. Proceed? [y/N] " "$child" "$strategy" "$target"
  local ok; read -r ok
  [[ "$ok" == y || "$ok" == Y ]] || { echo "aborted."; return 1 }
  # merge message: --message here beats CC_MERGE_MESSAGE beats the conventional default
  if [[ -n "$message" ]]; then
    ~/.config/cc-stack/cc-merge.sh do-merge "$root" "$child" "$strategy" "$target" --message "$message"
  else
    ~/.config/cc-stack/cc-merge.sh do-merge "$root" "$child" "$strategy" "$target"
  fi
  local mrc=$?
  if (( mrc == 0 )); then
    _gwt_archive_branch "$child"     # merged (or skipped-already-merged) → off the live board, into gwt-log
    echo "  (cleanup when ready: gwt-rm ${child#feat/} --branch)"
  fi
  return $mrc
}

# gwt-collect <parent-name-or-branch> — run one GATED gwt-merge per ready child
gwt-collect() {
  emulate -L zsh
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  local p="$1"; [[ -n "$p" ]] || { echo "usage: gwt-collect <parent-name|branch>"; return 1 }
  git -C "$root" show-ref --verify --quiet "refs/heads/$p" || p="feat/$p"
  local ready skipped line branch dirty done
  while IFS=$'\t' read -r branch _ _ dirty done; do
    [[ -n "$branch" ]] || continue
    if [[ "$dirty" == clean && "$done" == done ]]; then ready+=" $branch"; else skipped+=" $branch"; fi
  done < <(~/.config/cc-stack/cc-merge.sh tree "$root" | awk -F'\t' -v p="$p" '$2==p')
  [[ -n "$skipped" ]] && echo "⏭ skipping not-ready:${skipped}"
  [[ -n "$ready" ]] || { echo "no ready children of $p"; return 0 }
  local b
  for b in ${=ready}; do
    echo "════ collect: $b → $p ════"
    gwt-merge "$b" --into "$p" || { echo "  ↳ aborted/failed at $b — nothing further merged; re-run 'gwt-collect $1' to continue"; break }
  done
}

# gwt-help — cc-stack worktree command cheatsheet
gwt-help() {
  cat <<'EOF'
cc-stack · worktree sub-task commands
  gwt-claude <name> "<initial-prompt>"   build worktree + new tab running claude (auto mode) + send prompt
  gwt-new <name>                         build worktree and cd into it (opens an empty workspace, no claude)
  gwt-ls                                 git worktree list
  gwt-tree                               hierarchical board: branch tree, merge target, ready state, tab liveness
  gwt-done / gwt-undone                  (inside a sub-task) mark this branch ready / not-ready for merge
  gwt-merge <name> [--squash|--no-ff|--rebase] [--into <b>] [--message <text>] [--force]
                                         GATED merge into its recorded parent (asks strategy [default: squash] + confirms first);
                                         message defaults to "chore: merge <child> into <target>" (--message / CC_MERGE_MESSAGE override,
                                         e.g. for repos capping the subject at 72 chars); a refused commit leaves the staged merge
                                         in place for a manual finish, reported as commit-rejected — never as a conflict
  gwt-collect <parent>                   run one gated gwt-merge per ready child of <parent>
  gwt-status                             board: TAB liveness + branch + parent + agent state (working/idle/blocked + age) + dir + task
                                         current repo only; --all shows every repo (works from any shell — it wraps cc-board.sh)
  gwt-log                                the merged-task archive, same columns/filter (rows moved there by gwt-merge)
  gwt-rm <name> [--branch]               remove worktree (+ clear task record + pre-trust; optionally the branch)
  gwt-prune                              compact the task list (drop dead records + keep newest per dir)
  gwt-clean                              git worktree prune + show current state
  gwt-provider <name>                    set which AI provider starts NEW sub-tasks: gwt-provider kimi|glm|anthropic (existing sub-tasks unchanged); no arg shows current + available
Note: telling the main Claude to "open a worktree / spin off a sub-task" auto-triggers the hook to open a parallel tab;
      sub-tasks default to auto mode (investigate, then edit — no approval gate; prefix CC_WT_PERMISSION_MODE=plan to
      force the old plan gate); commit/merge/cleanup all require human authorization.
EOF
}

# gwt-rm <name> [--branch] — remove a worktree, optionally its branch too
gwt-rm() {
  emulate -L zsh
  local name="$1"
  [[ -n "$name" ]] || { echo "usage: gwt-rm <name> [--branch]"; return 1 }
  local wtpath="$(_gwt_dir)/$name"
  local wtabs; wtabs="$(cd "$wtpath" 2>/dev/null && pwd -P)"   # canonical path (before removal) for bookkeeping
  local wtbranch; wtbranch="$(git -C "$wtpath" symbolic-ref --short HEAD 2>/dev/null)"   # real branch, any prefix (captured before removal)
  # Merge the worktree's shared corpus (new e2e tests) back into the main repo BEFORE removal, so
  # nothing is lost. Same-name-different-content clashes are preserved as <name>.from-<branch>.<ext>.
  if [[ -n "$CC_WT_SHARE" && -d "$wtpath" ]]; then
    local _root _b _has=""
    _root="$(_gwt_root)"
    for _b in ${(s: :)CC_WT_SHARE}; do [[ -d "$wtpath/${_b%/}" ]] && { _has=1; break }; done
    if [[ -n "$_has" ]]; then
      echo "  ↳ merging shared corpus back into main…"
      ~/.config/cc-stack/cc-worktree-shared.sh collect "$_root" "$wtpath" ${(s: :)CC_WT_SHARE}
    fi
  fi
  git worktree remove "$wtpath" 2>/dev/null || git worktree remove --force "$wtpath" || return 1
  echo "✔ removed worktree: $wtpath"
  _gwt_tasks_drop_dir "${wtabs:-$wtpath}" && echo "  ↳ removed from task list"
  _gwt_status_drop_dir "${wtabs:-$wtpath}"   # drop the agent-state row for the same canonical dir
  ~/.config/cc-stack/cc-trust.sh --remove "${wtabs:-$wtpath}" >/dev/null 2>&1   # clear the pre-trust entry (only pure-trust-signature ones)
  if [[ "$2" == "--branch" ]]; then
    local br="${wtbranch:-feat/$name}"   # real branch when readable; default prefix as fallback (dir without HEAD)
    if git branch -D "$br" 2>/dev/null; then echo "✔ deleted branch $br"
    else echo "⚠ could not delete branch $br (already gone / merged elsewhere?)"; fi
    git config --remove-section "branch.$br" 2>/dev/null   # drop ccMergeInto/ccDone
  fi
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

# gwt-provider [kimi|glm|anthropic|default] — choose which AI provider starts NEW worktree sub-tasks.
#   Provider env is process-local, so this only affects sub-tasks spawned AFTER the change; already-running
#   sub-tasks keep whatever they launched with. No arg → show current + available providers.
#     <provider>   start new sub-tasks on that provider (must exist as $provdir/<provider>.sh)
#     anthropic    default — cmux claude-teams on the official/current-env provider
#     default      alias for anthropic
_gwt_provider_file() { echo "${CC_LAUNCH_FILE:-$HOME/.config/cc-stack/launch}" }
gwt-provider() {
  emulate -L zsh
  local f provdir cur
  f="$(_gwt_provider_file)"
  provdir="${CC_LAUNCH_PROVDIR:-$HOME/.config/claude/llm-provider}"
  cur="$(cat "$f" 2>/dev/null)"; cur="${cur:-anthropic}"
  local -a provs=()
  local p
  if [[ -d "$provdir" ]]; then for p in "$provdir"/*.sh(N); do provs+=("${${p:t}:r}"); done; fi
  if (( $# == 0 )); then
    echo "current provider: $cur"
    (( ${#provs[@]} )) && echo "available:        ${provs[*]} anthropic(default)"
    echo "usage: gwt-provider <provider>   (e.g. kimi, glm, anthropic)"
    return 0
  fi
  local provider="$1"
  if [[ "$provider" == *"/"* || "$provider" == *".."* ]]; then
    echo "✗ invalid provider name: $provider"; return 1; fi
  if [[ "$provider" == "anthropic" || "$provider" == "default" ]]; then
    printf 'anthropic\n' > "$f"
    echo "✔ new sub-tasks will use provider: anthropic (default)"
    return 0; fi
  if [[ ! -f "$provdir/$provider.sh" ]]; then
    echo "✗ no such provider: $provider; available: ${provs[*]:-(none)} anthropic(default)"; return 1; fi
  printf '%s\n' "$provider" > "$f"
  echo "✔ new sub-tasks will use provider: $provider (existing sub-tasks unchanged)"
}
