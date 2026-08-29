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
_gwt_wt_path() {   # <name> → echoes <worktrees-dir>/<name>; FAIL-CLOSED when helpers or dir are unavailable.
                   # Real incident 2026-08-16: in a partially-loaded shell _gwt_dir was missing, gwt-rm
                   # continued with wtpath="/<name>" (fs ROOT!) and fed it to `git worktree remove`.
                   # Every path built from _gwt_dir must resolve through this guard.
  emulate -L zsh
  local d=""
  # _gwt_dir has TWO failure modes and they used to share one message, so `gwt-rm foo` in a
  # non-repo directory told people to re-source their shell config. Separate them — the cwd is
  # what is usually wrong, and every other function in this file says "not inside a git repo".
  # Both still fail CLOSED: rc 1, nothing echoed on stdout, no path handed to any caller.
  if (( ! $+functions[_gwt_dir] )) || (( ! $+functions[_gwt_root] )); then
    echo "✗ worktree helpers unavailable — source ~/.config/cc-stack/worktree.zsh first" >&2; return 1
  fi
  d="$(_gwt_dir 2>/dev/null)" || { echo "✗ not inside a git repo" >&2; return 1; }
  [[ -n "$d" ]] || { echo "✗ worktrees dir unresolvable (helper returned empty)" >&2; return 1; }
  echo "$d/$1"
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
      # never overwrite: a REUSED branch/worktree may carry its own .env etc. — cc-dispatch.sh's
      # surface path skips existing files too, and the zsh side silently clobbered them (2026-08-21)
      if [[ -e "$wtpath/$f" ]]; then echo "  ↳ kept worktree's own $f"; continue; fi
      mkdir -p "$wtpath/${f:h}"; cp -p "$root/$f" "$wtpath/$f" && echo "  ↳ copied $f"
    fi
  done
  # if-block, NOT `[[ ... ]] && ...`: that one-liner leaves the function rc=1 whenever
  # CC_WT_SHARE is empty (README:276 supports exported-empty as the off switch), and
  # gwt-new / gwt-adopt bail on it AFTER the worktree is built — no capture, no workspace, no cd.
  if [[ -n "$CC_WT_SHARE" ]]; then
    ~/.config/cc-stack/cc-worktree-shared.sh seed "$root" "$wtpath" ${(s: :)CC_WT_SHARE}
  fi
  return 0   # seeding is best-effort: its rc must not leak out and fail a finished bootstrap
}

# ── State access (state-model Phase A, 2026-08-22) ───────────────────────────
# Every read/write of the four state stores (tasks / status sidecar / archive /
# opened-tabs) goes through the cc-state facade — one lock, one access path
# (docs/state-model.md). worktree.zsh keeps only the zsh interaction layer: the
# gwt-* commands call the verbs, and the two shims below keep the function names
# older callers (and test.sh) invoke directly. No file in this layer is opened by
# name any more; the ONE row stream still parsed here is gwt-tree's branch/ref scan,
# and it comes off `cc-state dump` — still awk -F'\t', never `IFS=$'\t' read`: TAB is
# IFS *whitespace*, one empty field shifts every later field (2026-08-16 audit, F1).
# cc-state sits next to this file when a worktree tests itself, else in the install dir.
_gwt_state() {
  local d="${_gwt_src_dir:-}"
  [[ -n "$d" && -x "$d/cc-state" ]] && { echo "$d/cc-state"; return 0 }
  echo "$HOME/.config/cc-stack/cc-state"
}

# ── Task list maintenance ────────────────────────────────────────────────────
# (there is deliberately no _gwt_tasks_file here any more: which FILE the task list
# lives in is the facade's business, and after the engine swap there is no per-store
# file to name. Everything below asks cc-state a question instead.)

# Drop all records for a given dir (used by gwt-rm): task-drop's dir rule (raw or
# canonical match). Kept as a named shim — gwt-rm and the regression suite call it.
_gwt_tasks_drop_dir() {
  emulate -L zsh
  local target="$1"; [[ -n "$target" ]] || return 0
  "$(_gwt_state)" task-drop "$target"
}

# ── Merged-task archive (worktree-tasks-archive.tsv) ───────────────────────────
# Rows move here when their branch merges: the row verbatim plus an appended merged-at
# unix ts. Rendered by gwt-log (cc-board.sh --archive) with the board's columns and repo filter.

# _gwt_archive_branch <branch> [<repo-root>] [<merged-into>] — move ALL rows whose branch
# matches into the archive (merged-at appended: 8→9 fields, 7→8; then merged-into when given)
# and sweep their status sidecar rows, printing the moved dirs on stdout for this summary.
# With <repo-root> the archive is repo-scoped
# (spec §3.5 defect 2's fix): only rows whose dir lives under that root move, so the same
# branch name in another repo keeps its rows; without it the semantics are today's global
# match. Called by gwt-merge after a successful merge (or a benign skipped-already-merged),
# so the board stops showing merged work while gwt-log keeps the history. Failure is LOUD
# (spec §3.5 defects 4/5, fixed by the facade): rc 1 + stderr, task list left untouched —
# this shim propagates that rc, never eats it. <merged-into> is where the merge actually
# LANDED — gwt-merge passes its resolved $target, which --into and a fast-forwarded sibling
# both make different from the parent recorded at dispatch. Omitted, the archive row keeps
# its pre-D shape (row + merged-at) exactly.
_gwt_archive_branch() {
  emulate -L zsh
  local branch="$1" root="${2:-}" into="${3:-}"
  [[ -n "$branch" ]] || return 0
  local -a ra=()
  [[ -n "$root" ]] && ra=(--repo "$root")
  local out rc
  out="$("$(_gwt_state)" task-archive "$branch" "$into" "${ra[@]}")"; rc=$?
  local -a moved=(${(f)out})
  (( ${#moved} )) && echo "  ↳ archived ${#moved} record(s) for $branch (see gwt-log)"
  return $rc
}

# gwt-new <name> [branch-prefix=feat] [base=HEAD] — create/reuse a worktree and cd into it
gwt-new() {
  emulate -L zsh
  local name="$1" prefix="${2:-feat}" base="${3:-HEAD}"
  [[ -n "$name" ]] || { echo "usage: gwt-new <name> [branch-prefix=feat] [base=HEAD]"; return 1 }
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  local wtpath branch="$prefix/$name"; wtpath="$(_gwt_wt_path "$name")" || return 1
  _gwt_bootstrap_wt "$root" "$wtpath" "$branch" "$base" || return 1
  echo "✔ worktree: $wtpath   branch: $branch"
  # 4th arg: an explicit base branch IS the merge target (cwd is only the fallback — after a
  # fast-forward the campaign branch and a sibling are the same commit, see cmd_capture).
  ~/.config/cc-stack/cc-merge.sh capture "$root" "$branch" "$PWD" "$base" >/dev/null 2>&1
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
  local wtpath; wtpath="$(_gwt_wt_path "$name")" || return 1
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
#   data source 1: the tasks store, appended by cc-dispatch.sh surface whenever it opens a tab
#     fields: time \t branch \t surface \t dir \t caller-tab \t task-summary \t parent-branch \t
#             launch-args (uuid/provider/pm/model — what gwt-resume replays; empty on old rows)
#   data source 2: the agent-state columns (dir \t state \t unix-ts), written by cc-hooks.sh status on
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

# gwt-resume [--all] — bring sub-task tabs back after cmux died/restarted (roadmap 2). Thin
#   wrapper; the engine is cc-dispatch.sh resume:
#   ① cmux native restore-session first (fail-soft), ② board rows matched to the tabs that came
#   back (recorded session uuid → cmux session store → live surface ref; canonical-cwd fallback)
#   get their surface refs refreshed + stale agent-state rows cleared, ③ rows still without a tab
#   are re-opened in the RECORDED dir (verbatim — claude keys project identity on the exact path
#   string) replaying the RECORDED launch args: cld <provider> --resume <uuid> --permission-mode
#   <pm> [--model <m>]; plain rows resume without cld, flags not recorded are omitted. Rows with
#   no recorded session (pre-feature) degrade to an idle ccteam tab — visible, never silent.
#   Lists BRANCH|SUMMARY|DIR|disposition first, then ONE y/N; --all skips the confirm AND shows
#   every repo (default: current repo's rows only, like gwt-status).
_gwt_dispatch_script() {
  local d="${_gwt_src_dir:-}"
  [[ -n "$d" && -f "$d/cc-dispatch.sh" ]] && { echo "$d/cc-dispatch.sh"; return 0 }
  echo "$HOME/.config/cc-stack/cc-dispatch.sh"
}
gwt-resume() {
  emulate -L zsh
  bash "$(_gwt_dispatch_script)" resume "$@"
  return $?
}

# gwt-tabs [--all] — the opened-tabs inventory: every tab this stack opened (worktree sub-task or
#   plain helper tab), joined with live cmux resolution — current short ref, stable surface uuid,
#   alive/dead, the surface that opened it, and its directory. Thin wrapper around
#   `cc-dispatch.sh tabs`; default shows only the rows this session opened, --all shows every row.
gwt-tabs() {
  emulate -L zsh
  bash "$(_gwt_dispatch_script)" tabs "$@"
  return $?
}

# gwt-prune — compact the task list: drop dead-dir records + keep only the newest per dir.
#   One facade call sweeps the pair (tasks dir field + sidecar col 0) and compacts newest-per-dir;
#   the three messages below are the hand-rolled era's, with one recorded exception: a store the
#   facade never wrote — a task file truncated to zero bytes by hand — now reads as "list is
#   empty" (it holds no row) where the file-stat era said "✔ emptied" and unlinked it. The
#   facade deletes every store IT empties, so this state is unreachable from the stack itself.
gwt-prune() {
  emulate -L zsh
  local st; st="$(_gwt_state)"
  # The three messages are "had rows / had rows, none survived / had none", so the question
  # asked before and after the sweep is the same one: does this store hold a row? `exists`
  # answers it without naming a file, and the sweep itself already deletes a store it empties.
  local had=0; "$st" exists tasks && had=1
  local rc=0
  "$st" task-prune --compact || rc=$?
  if (( rc )); then return $rc; fi   # the facade already said "compaction failed — task list left untouched"
  (( had )) || { echo "list is empty"; return 0 }
  "$st" exists tasks || { echo "✔ emptied (no live records)"; return 0 }
  echo "✔ task list compacted"
}

# _gwt_tree_render <node> <prefix> — recursive tree drawer (uses _gt_* globals set by gwt-tree)
_gwt_tree_render() {
  emulate -L zsh
  local node="$1" prefix="$2"
  local kids=(${=_gt_kids[$node]:-})
  # Draw each node ONCE: _gt_seen is both the cycle brake (a ↔ b reachable from the trunk would
  # recurse forever) and the record the orphan block below reads to find what was never drawn.
  local -a fresh=()
  local k=""
  for k in $kids; do [[ -n "${_gt_seen[$k]:-}" ]] || { fresh+=("$k"); _gt_seen[$k]=1 }; done
  kids=($fresh)
  local n=${#kids} i=1 kid conn childprefix
  for kid in $kids; do
    if (( i == n )); then conn="└─ "; childprefix="$prefix   "; else conn="├─ "; childprefix="$prefix│  "; fi
    local ahead="${_gt_ahead[$kid]}" dirty="${_gt_dirty[$kid]}" dn="${_gt_done[$kid]}"
    local doneflag=""; [[ "$dn" == done ]] && doneflag="✓done"
    local rf="${_gt_ref[$kid]:-}" tab=""
    if [[ -z "$_gt_live" ]]; then tab="?"
    # exact-field match on the first column, with the '*' SELECTED marker stripped first
    # (real cmux prefixes the selected row — cc-dispatch.sh:334 does the same sed) — a bare
    # substring grep (surface:3) would also hit surface:30 now that the union probe widens
    # the candidate pool, marking a closed tab live
    elif [[ -n "$rf" ]] && awk -v r="$rf" '{sub(/^\*/,"")} $1==r{f=1} END{exit !f}' <<<"$_gt_live"; then tab="✔live"
    elif [[ -n "$rf" ]] && [[ -n "$_gt_live_partial" ]]; then tab="?"    # probe incomplete — unknown, not dead
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
  # tab liveness (best-effort). `cmux list-pane-surfaces` answers ONE workspace — the caller's —
  # so a single unscoped call (the old code) showed a live sub-task in another workspace as
  # ⌫closed. Probe the UNION over `cmux list-workspaces` (same shape as cc-board.sh / the
  # opened-tabs prune, 2026-08-16): 1+N cmux calls, one per workspace. Empty answer per workspace
  # = a FAILED probe, not an empty workspace (cmux refuses to close a workspace's last surface, so
  # one always exists) — that sets _gt_live_partial, and a miss under partial evidence renders "?"
  # (liveness unknown), never ⌫closed: absence of evidence is not evidence of death.
  typeset -gA _gt_ref _gt_parent _gt_ahead _gt_dirty _gt_done _gt_kids _gt_seen
  _gt_ref=(); _gt_parent=(); _gt_ahead=(); _gt_dirty=(); _gt_done=(); _gt_kids=(); _gt_seen=()
  _gt_live=""; _gt_live_partial=""
  if command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1; then
    # leading ref token only (a `grep -o` would mint a ref out of a workspace NAMED after one)
    local _gt_wsrefs="" _gt_w="" _gt_wl=""
    _gt_wsrefs="$(cmux list-workspaces 2>/dev/null | sed 's/^\*//' | awk '$1 ~ /^workspace:[0-9]+$/{print $1}')"
    if [[ -n "$_gt_wsrefs" ]]; then
      for _gt_w in ${=_gt_wsrefs}; do   # ${= }: zsh does NOT word-split unquoted $var (cc-board.sh is bash and does)
        _gt_wl="$(cmux list-pane-surfaces --workspace "$_gt_w" 2>/dev/null)"
        if [[ -n "$_gt_wl" ]]; then
          _gt_live="$_gt_live$_gt_wl
"
        else
          _gt_live_partial=1
        fi
      done
    else
      # no workspace list at all (older CLI / failed call): the unscoped call still resolves what
      # it can see, but we cannot even count what went unlooked-at — least complete evidence there
      # is, so it counts as partial too (same call the opened-tabs prune falls back to).
      _gt_live="$(cmux list-pane-surfaces 2>/dev/null)"
      [[ -n "$_gt_live" ]] && _gt_live_partial=1
    fi
  fi
  local br="" rf=""
  # branch → surface ref, off the RAW row stream (`dump`, the same shape cc-board.sh's stale-ref
  # probe reads), still awk -F'\t' (see the TSV access discipline): a read loop over the whole
  # row shifts the ref onto whatever follows an empty caller field. An absent store dumps
  # nothing, which is what the `[[ -f ]]` this replaced was for.
  # NOT task-list: it answers the BOARD's question, not the file's — dead-dir rows dropped,
  # newest-per-dir deduped, newest FIRST. Each of those breaks this scan. The dropped rows are
  # exactly the hand-removed worktrees whose tab is still open (⌫closed would render as "-"),
  # and the reversal inverts this loop's last-write-wins, handing a branch recorded in two dirs
  # its OLDEST ref. Measured, not reasoned about: test.sh §37 pins both.
  while IFS=$'\t' read -r br rf; do _gt_ref[$br]="$rf"; done \
    < <("$(_gwt_state)" dump tasks | awk -F'\t' '$2 != "" {print $2 "\t" $3}')
  local branch parent ahead dirty dn
  while IFS=$'\t' read -r branch parent ahead dirty dn; do
    [[ -n "$branch" ]] || continue
    _gt_parent[$branch]="$parent"; _gt_ahead[$branch]="$ahead"
    _gt_dirty[$branch]="$dirty"; _gt_done[$branch]="$dn"
    _gt_kids[$parent]="${_gt_kids[$parent]:-} $branch"
  done <<< "$data"
  echo "$trunk"
  _gt_seen[$trunk]=1
  _gwt_tree_render "$trunk" ""
  # Orphans: the render walks DOWN from the trunk, so a node the walk never reaches used to
  # vanish with no hint at all — and gwt-tree is exactly what the merge gate is read from, where
  # an invisible branch reads as "nothing left to merge". Two routine ways in: its merge target
  # was deleted (the README's own gwt-merge <parent> → gwt-rm <parent> --branch sequence), or two
  # branches point at each other. Print them, with the target that failed to resolve.
  local -a orphans=()
  local b=""
  for b in ${(k)_gt_parent}; do [[ -n "${_gt_seen[$b]:-}" ]] || orphans+=("$b"); done
  if (( ${#orphans} )); then
    echo "⚠ orphaned (parent gone / cycle) — not reachable from $trunk, gwt-merge them explicitly:"
    local pb="" why="" ahead="" dirty="" dn="" doneflag="" rf="" tab="" ready=""
    for b in ${(o)orphans}; do
      pb="${_gt_parent[$b]:-?}"
      if git -C "$root" show-ref --verify --quiet "refs/heads/$pb"; then why="unreachable (cycle)"; else why="branch gone"; fi
      ahead="${_gt_ahead[$b]}"; dirty="${_gt_dirty[$b]}"; dn="${_gt_done[$b]}"
      doneflag=""; [[ "$dn" == done ]] && doneflag="✓done"
      rf="${_gt_ref[$b]:-}"
      if [[ -z "$_gt_live" ]]; then tab="?"
      elif [[ -n "$rf" ]] && awk -v r="$rf" '{sub(/^\*/,"")} $1==r{f=1} END{exit !f}' <<<"$_gt_live"; then tab="✔live"   # exact-field, '*' stripped (see render)
      elif [[ -n "$rf" ]] && [[ -n "$_gt_live_partial" ]]; then tab="?"    # probe incomplete — unknown, not dead
      elif [[ -n "$rf" ]]; then tab="⌫closed"; else tab="-"; fi
      if [[ "$dirty" == clean && "$dn" == done ]]; then ready="ready ✅"; else ready="not ready ⏳"; fi
      printf '   ✗  %-14s ↑%-3s %-5s %-6s [%s]  → %s   (merge target %s: %s)\n' \
        "$b" "$ahead" "$dirty" "$doneflag" "$tab" "$ready" "$pb" "$why"
    done
  fi
  # cc-board.sh's trailing note, same reason here: a "?" tab means this probe could not reach
  # every workspace — unknown, NOT dead.
  [[ -n "$_gt_live_partial" ]] && echo "(note: cmux workspace enumeration was incomplete — liveness partial, so a tab this probe did not reach shows '?' rather than ⌫closed)"
  unset _gt_ref _gt_parent _gt_ahead _gt_dirty _gt_done _gt_kids _gt_seen _gt_live _gt_live_partial
}

# gwt-done / gwt-undone — mark the current worktree's branch ready (harmless annotation, no gate).
#   Both DELEGATE to the standalone `gwt-done` script (one implementation, same output): a zsh
#   function only exists in a shell that sourced this file, and a sub-task's non-interactive Bash
#   never did — `gwt-done` there died with "_gwt_root: command not found" (2026-08-16). Sub-tasks
#   are taught the absolute path (~/.config/cc-stack/gwt-done) by the dispatch working agreement;
#   these wrappers keep the bare name working for interactive users.
_gwt_done_script() {
  local d="${_gwt_src_dir:-}"
  [[ -n "$d" && -x "$d/gwt-done" ]] && { echo "$d/gwt-done"; return 0 }
  echo "$HOME/.config/cc-stack/gwt-done"
}
gwt-done() {
  emulate -L zsh
  bash "$(_gwt_done_script)" "$@"
  return $?
}
gwt-undone() {
  emulate -L zsh
  bash "$(_gwt_done_script)" --undone "$@"
  return $?
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
  # A branch merged into itself passes every preflight check, stages nothing and comes back
  # "skipped: already merged" rc 0 — refused here outright, --force included (do-merge refuses too).
  [[ "$target" == "$child" ]] && { echo "✗ $child's merge target is itself — nothing to merge into. Fix it: cc-merge.sh set-parent \"$root\" $child <parent>"; return 1 }
  # ordering guard: if child itself has not-ready children, warn
  local kids; kids="$(~/.config/cc-stack/cc-merge.sh tree "$root" | awk -F'\t' -v p="$child" '$2==p && !($4=="clean" && $5=="done"){print $1}')"
  [[ -n "$kids" ]] && echo "⚠ $child still has not-ready children: ${kids//$'\n'/, } — consider 'gwt-collect $child' first"
  echo "── preflight: $child → $target ──"
  local pf rc; pf="$(~/.config/cc-stack/cc-merge.sh preflight "$root" "$child" "$target")"; rc=$?
  # `note:` too, not just the checks: it is the line that says the target is another sub-task line
  # rather than the campaign branch — invisible in git itself once a fast-forward equalized the tips.
  echo "$pf" | grep -E '^(check|note):'
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
  # AUTHORIZATION GATE — names where the TARGET goes on, so "into my campaign branch" and "into a
  # sibling that happens to sit on the same commit" stop looking identical at the y/N.
  local tpar; tpar="$(echo "$pf" | sed -n 's/^target-parent: //p')"
  printf "About to merge \033[1m%s\033[0m --%s into \033[1m%s\033[0m%s. Proceed? [y/N] " \
    "$child" "$strategy" "$target" "${tpar:+ → $tpar}"
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
    _gwt_archive_branch "$child" "$root" "$target"   # repo-scoped (defect 2) + records where it landed
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
  gwt-resume [--all]                     after a cmux restart: native restore first, then re-open still-missing sub-task tabs
                                         replaying the RECORDED session uuid + provider + mode (lists first, asks y/N; --all = every repo, no confirm)
  gwt-log                                the merged-task archive, same columns/filter (rows moved there by gwt-merge)
  gwt-tabs [--all]                       opened-tabs inventory: every tab this stack opened — ref, stable uuid,
                                         alive/dead, the surface that opened it, dir (--all = every session's rows)
  gwt-rm <name> [--branch] [--close]     remove worktree (+ clear task record + pre-trust; optionally the branch);
                                         [--force]                            refuses a dirty worktree / an unmerged
                                         branch unless --force (the one destructive switch) is given;
                                         --close also closes its cmux tab through cc-dispatch.sh close (by the
                                         RECORDED stable surface uuid — never a short ref, which drifts)
  gwt-prune                              compact the task list (drop dead records + keep newest per dir)
  gwt-clean                              git worktree prune + show current state
  gwt-provider <name>                    set which AI provider starts NEW sub-tasks: gwt-provider kimi|glm|anthropic (existing sub-tasks unchanged); no arg shows current + available
Note: telling the main Claude to "open a worktree / spin off a sub-task" auto-triggers the hook to open a parallel tab;
      sub-tasks default to auto mode (investigate, then edit — no approval gate; prefix CC_WT_PERMISSION_MODE=plan to
      force the old plan gate); commit/merge/cleanup all require human authorization.
EOF
}

# gwt-rm <name> [--branch] [--close] — remove a worktree, optionally its branch and its cmux tab
gwt-rm() {
  emulate -L zsh
  local name="$1"
  [[ -n "$name" ]] || { echo "usage: gwt-rm <name> [--branch] [--close] [--force]"; return 1 }
  # flags in any order (the legacy `gwt-rm <name> --branch` positional form still works).
  # --force is THE destructive switch, and the only one: without it a dirty worktree is refused
  # (nothing deleted at all) and an unmerged branch survives `--branch`; with it both fall.
  local want_branch="" want_close="" want_force="" _a
  for _a in "${@:2}"; do
    case "$_a" in
      --branch) want_branch=1 ;;
      --close)  want_close=1 ;;
      --force)  want_force=1 ;;
      *) echo "usage: gwt-rm <name> [--branch] [--close] [--force]"; return 1 ;;
    esac
  done
  local wtpath; wtpath="$(_gwt_wt_path "$name")" || return 1
  # A gone DIRECTORY is not a gone worktree: an external `rm -rf`, or a half-finished removal,
  # leaves git's registration (marked prunable) plus a board row, a sidecar row, a pre-trust
  # entry, an orphan cmux tab and the branch. `git worktree remove` returns 0 on exactly that
  # state and prunes the registration, so this IS the reclaim path — bailing on -d alone stranded
  # all of it. Still fail-closed (the 2026-08-16 partial-shell incident): the fallback is git's
  # own registration list, never a blind path, so a typo'd name can never reach `worktree remove`.
  if [[ ! -d "$wtpath" ]]; then
    local _rt; _rt="$(_gwt_root 2>/dev/null)"
    if [[ -z "$_rt" ]] || ! git -C "$_rt" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $wtpath"; then
      echo "✗ no worktree named '$name' under the worktrees dir" >&2; return 1
    fi
    echo "  ↳ directory already gone — reclaiming the stale registration for $wtpath"
  fi
  local wtabs; wtabs="$(cd "$wtpath" 2>/dev/null && pwd -P)"   # canonical path (before removal) for bookkeeping
  local wtbranch; wtbranch="$(git -C "$wtpath" symbolic-ref --short HEAD 2>/dev/null)"   # real branch, any prefix (captured before removal)
  # repo root resolved BEFORE the removal: gwt-rm may run from INSIDE the worktree being
  # removed (gwt-new cd's you there), and once that directory is gone every bare `git` in the
  # dead cwd fails — a fully-merged branch was misreported as "not merged". Every git from
  # here on carries -C "$gwtroot".
  local gwtroot; gwtroot="$(_gwt_root 2>/dev/null)"
  [[ -n "$gwtroot" ]] || { echo "✗ cannot resolve repo root" >&2; return 1; }
  # Refusal pre-flight (2026-08-22 gate) — runs BEFORE the corpus collect so a refused rm
  # leaves the ROOT untouched too. It gates only what remove itself would refuse AFTER the
  # collect had already been paid for: a dirty tree, and a locked one. Submodules are
  # deliberately NOT probed: git 2.55 removes a clean tree carrying an unpopulated gitlink, so
  # judging submodules ourselves was stricter than git and blocked routine rms. remove's own
  # refusal below stays the fail-closed authority; a failed probe here reads as refusal.
  if [[ -z "$want_force" && -d "$wtpath" ]]; then
    local _pd=""
    if ! _pd="$(git -C "$wtpath" status --short 2>/dev/null)"; then
      echo "✗ cannot probe $wtpath (git status failed) — refusing to remove" >&2
      echo "   fix the probe, or re-run as: gwt-rm $name --force" >&2
      return 1
    fi
    if [[ -n "$_pd" ]]; then
      echo "✗ worktree has uncommitted changes — refusing to remove:" >&2
      printf '%s\n' "$_pd" | head -20 >&2
      echo "   commit or stash them first, or re-run as: gwt-rm $name --force" >&2
      return 1
    fi
    # a LOCKED worktree is clean, so the probes above sail past it and remove refuses only
    # AFTER the collect would have touched the root — catch the lock up here instead
    if git -C "$wtpath" worktree list --porcelain 2>/dev/null \
      | awk -v w="$wtpath" '$1=="worktree"{inw=($2==w); next} inw && $1=="locked"{f=1} END{exit !f}'; then
      echo "✗ worktree is locked (git worktree lock) — refusing to remove:" >&2
      echo "   unlock it first (git worktree unlock '$wtpath'), or re-run as: gwt-rm $name --force" >&2
      return 1
    fi
  fi
  # Merge the worktree's shared corpus (new e2e tests) back into the main repo BEFORE removal, so
  # nothing is lost. Same-name-different-content clashes are preserved as <name>.from-<branch>.<ext>.
  if [[ -n "$CC_WT_SHARE" && -d "$wtpath" ]]; then
    local _b _has=""
    for _b in ${(s: :)CC_WT_SHARE}; do [[ -d "$wtpath/${_b%/}" ]] && { _has=1; break }; done
    if [[ -n "$_has" ]]; then
      echo "  ↳ merging shared corpus back into main…"
      ~/.config/cc-stack/cc-worktree-shared.sh collect "$gwtroot" "$wtpath" ${(s: :)CC_WT_SHARE}
    fi
  fi
  # The removal itself (2026-08-21 guard, 2026-08-22 gate rewrite): on refusal print git's OWN
  # stderr and stop (rc 1, NOTHING cleaned) — never second-guess the refusal with a status
  # probe, because "probe reads empty" ≠ clean. --force is the only way past a refusal.
  local _rmerr; _rmerr="$(mktemp)"
  if ! git -C "$gwtroot" worktree remove "$wtpath" 2>"$_rmerr"; then
    if [[ -z "$want_force" ]]; then
      echo "✗ git worktree remove refused $wtpath:" >&2
      head -20 "$_rmerr" >&2
      git -C "$wtpath" status --short 2>/dev/null | head -20 | sed 's/^/     /' >&2   # reference only, never the verdict
      echo "   resolve the above, or re-run as: gwt-rm $name --force" >&2
      rm -f "$_rmerr"; return 1
    fi
    rm -f "$_rmerr"
    git -C "$gwtroot" worktree remove --force "$wtpath" || return 1
  else
    rm -f "$_rmerr"
  fi
  echo "✔ removed worktree: $wtpath"
  # --close: route the tab close through the sanctioned primitive (resolves the dir to a live
  # surface by its RECORDED stable uuid, prints the resolution, enforces the close policy).
  # Runs BEFORE the task row is dropped — that row IS the ledger the primitive reads.
  [[ -n "$want_close" ]] && ~/.config/cc-stack/cc-dispatch.sh close "${wtabs:-$wtpath}"
  _gwt_tasks_drop_dir "${wtabs:-$wtpath}" && echo "  ↳ removed from task list"
  "$(_gwt_state)" task-clear-state "${wtabs:-$wtpath}"   # drop the agent-state row for the same dir — clear-state, not prune: the dir may still exist here
  ~/.config/cc-stack/cc-trust.sh --remove "${wtabs:-$wtpath}" >/dev/null 2>&1   # clear the pre-trust entry (only pure-trust-signature ones)
  if [[ -n "$want_branch" ]]; then
    local br="${wtbranch:-feat/$name}"   # real branch when readable; default prefix as fallback (dir without HEAD)
    if ! git -C "$gwtroot" show-ref --verify --quiet "refs/heads/$br"; then
      # no such branch (reclaim path fell back to feat/$name, or it was deleted out of band):
      # nothing to judge — clear the merge record so it cannot linger as a ghost tree node
      echo "  ↳ branch $br already gone — clearing its merge record"
      git -C "$gwtroot" config --remove-section "branch.$br" 2>/dev/null
    else
      # "Merged" must mean: into the branch's RECORDED merge target, not the caller's HEAD —
      # `git branch -d` only proves the latter, and do-merge squashes in a temp worktree (the
      # caller's HEAD never moves), so -d refuses every properly-merged campaign branch. Evidence
      # instead: ancestry against the target, or the Child-Tip trailer do-merge stamps into the
      # squash commit (a squash carries no ancestry). --force stays the only override.
      # (Child-Tip proves the squash HAPPENED — a later revert of it still reads as merged;
      # accepted, the trailer is do-merge's own receipt.)
      local _tgt="" _tip="" _merged=0 _brgone=""
      _tgt="$(~/.config/cc-stack/cc-merge.sh get-parent "$gwtroot" "$br" 2>/dev/null)"
      if [[ -n "$_tgt" ]] && ! git -C "$gwtroot" show-ref --verify --quiet "refs/heads/$_tgt"; then
        # recorded target was deleted (README's own gwt-merge <parent>; gwt-rm <parent> --branch
        # sequence) — the child's history lives on in the trunk that target merged into
        _tgt="$(~/.config/cc-stack/cc-merge.sh trunk "$gwtroot" 2>/dev/null)"
      fi
      _tip="$(git -C "$gwtroot" rev-parse --quiet --verify "$br" 2>/dev/null)"
      if [[ -n "$_tip" && -n "$_tgt" ]]; then
        if git -C "$gwtroot" merge-base --is-ancestor "$br" "$_tgt" 2>/dev/null; then
          _merged=1
        elif [[ -n "$(git -C "$gwtroot" log --format=%H --fixed-strings --grep="Child-Tip: $_tip" "$_tgt" 2>/dev/null)" ]]; then
          _merged=1
        fi
      fi
      if (( _merged )); then
        if git -C "$gwtroot" branch -D "$br" 2>/dev/null; then echo "✔ deleted branch $br (merged into $_tgt)"; _brgone=1
        else echo "⚠ could not delete branch $br (already gone?)"; fi
      elif [[ -n "$want_force" ]]; then
        if git -C "$gwtroot" branch -D "$br" 2>/dev/null; then echo "✔ force deleted branch $br (unmerged commits dropped)"; _brgone=1
        else echo "⚠ could not delete branch $br (already gone?)"; fi
      else
        echo "⚠ branch $br is not merged into ${_tgt:-its target} — kept. Re-run with --force to drop its commits."
      fi
      # ccMergeInto / ccDone fall only WITH the branch — a KEPT branch still needs its tree row
      # and merge target (a remove-section on the kept branch erased both and hid it from gwt-tree).
      [[ -n "$_brgone" ]] && git -C "$gwtroot" config --remove-section "branch.$br" 2>/dev/null
    fi
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
