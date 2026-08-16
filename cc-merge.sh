#!/usr/bin/env bash
# cc-stack · merge mechanics for hierarchical worktrees.
# Stores each worktree branch's merge target + ready flag in git config
# (branch.<b>.ccMergeInto / branch.<b>.ccDone), derives the parent tree,
# runs merge preflight, and performs the gated merge. The interactive
# authorization gate lives in worktree.zsh (gwt-merge), never here.
set -u

_cm_main_branch() {   # <repo> → trunk branch name
  local repo="$1" h b
  h="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" \
    && { echo "${h#origin/}"; return; }
  for b in main master; do
    git -C "$repo" show-ref --verify --quiet "refs/heads/$b" && { echo "$b"; return; }
  done
  echo main
}

cmd_set_parent() {    # <repo> <branch> <parent>
  local repo="$1" branch="$2" parent="$3"
  git -C "$repo" config "branch.$branch.ccMergeInto" "$parent"
}

cmd_get_parent() {    # <repo> <branch> → parent (trunk fallback; empty if branch==trunk)
  local repo="$1" branch="$2" p trunk
  p="$(git -C "$repo" config --get "branch.$branch.ccMergeInto" 2>/dev/null)"
  if [ -n "$p" ]; then echo "$p"; return; fi
  trunk="$(_cm_main_branch "$repo")"
  [ "$branch" = "$trunk" ] && return 0
  echo "$trunk"
}

cmd_done() {          # <repo> <branch> [true|false]
  local repo="$1" branch="$2" val="${3:-true}"
  git -C "$repo" config "branch.$branch.ccDone" "$val"
}

cmd_is_done() {       # <repo> <branch> → exit 0 if done
  local repo="$1" branch="$2"
  [ "$(git -C "$repo" config --get "branch.$branch.ccDone" 2>/dev/null)" = "true" ]
}

cmd_tree() {          # <repo> → TSV: branch \t parent \t ahead \t dirty \t done
  # bash 3.2 safe: no associative array — emit each row inline as we read the
  # porcelain stream (a `branch` line always follows its `worktree` line).
  local repo="$1" trunk dir="" line b parent ahead dirty done
  trunk="$(_cm_main_branch "$repo")"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) dir="${line#worktree }" ;;
      "branch refs/heads/"*)
        b="${line#branch refs/heads/}"
        if [ "$b" = "$trunk" ]; then dir=""; continue; fi
        parent="$(cmd_get_parent "$repo" "$b")"
        ahead="$(git -C "$repo" rev-list --count "$parent..$b" 2>/dev/null || echo 0)"
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then dirty=dirty; else dirty=clean; fi
        if cmd_is_done "$repo" "$b"; then done=done; else done=-; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$parent" "$ahead" "$dirty" "$done"
        dir="" ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain)
}

cmd_preflight() {     # <repo> <child> [<target>] → prints checks; exit 1 if any not ok
  local repo="$1" child="$2" target="${3:-}" rc=0
  [ -n "$target" ] || target="$(cmd_get_parent "$repo" "$child")"
  # locate child worktree dir for the dirty check
  local cdir; cdir="$(_cm_worktree_of "$repo" "$child")"
  # clean
  if [ -n "$cdir" ] && [ -n "$(git -C "$cdir" status --porcelain 2>/dev/null)" ]; then
    echo "check: clean WARN"; rc=1; else echo "check: clean ok"; fi
  # done
  if cmd_is_done "$repo" "$child"; then echo "check: done ok"; else echo "check: done WARN"; rc=1; fi
  # target-exists
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$target"; then
    echo "check: target-exists ok"; else echo "check: target-exists FAIL"; rc=1; fi
  # conflict (git 2.38+ --write-tree exits nonzero on conflict)
  if git -C "$repo" merge-tree --write-tree "$target" "$child" >/dev/null 2>&1; then
    echo "check: conflict ok"; else echo "check: conflict FAIL"; rc=1; fi
  echo "target: $target"
  return $rc
}

# locate the worktree dir a branch is checked out in (empty if none)
_cm_worktree_of() {   # <repo> <branch>
  local repo="$1" want="$2" dir=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) dir="${line#worktree }" ;;
      "branch refs/heads/"*) [ "${line#branch refs/heads/}" = "$want" ] && { echo "$dir"; return; } ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain)
}

# print a failed command's captured output (prefixed, head-trimmed) so the real cause is visible
_cm_print_captured() {   # <capture-file>
  local f="$1" n
  [ -s "$f" ] || return 0
  n="$(wc -l < "$f" | tr -d ' ')"
  head -n 25 "$f" | cut -c 1-300 | sed 's/^/  │ /' >&2
  if [ "$n" -gt 25 ]; then echo "  │ … ($((n - 25)) more line(s) trimmed)" >&2; fi
  return 0
}

# do-merge failure triage: rc 1 conflict (content) / rc 3 commit-rejected (staged merge
# PRESERVED for a manual finish) / rc 5 rebase-dirty / rc 2 usage. git output is captured to a
# temp file and printed on every failure — never swallowed, never mislabelled "conflict".
cmd_do_merge() {      # <repo> <child> <strategy> [<target>] [--message <text>]
  local repo="$1" child="$2" strategy="$3"; shift 3
  local target="" message=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --message) [ $# -ge 2 ] || { echo "do-merge: --message needs a value" >&2; return 2; }
                 message="$2"; shift 2 ;;
      --message=*) message="${1#--message=}"; shift ;;
      *) [ -z "$target" ] && target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || target="$(cmd_get_parent "$repo" "$child")"
  local tdir tmp="" tmpparent="" rc=0 skipped="" label="" childdir tip cap mdefault=""
  cap="$(mktemp)"                                        # scratch capture for git output
  tip="$(git -C "$repo" rev-parse "$child" 2>/dev/null)"  # child tip BEFORE anything moves it
  # merge message: --message > CC_MERGE_MESSAGE > conventional default. Some repos cap the
  # subject at 72 chars — pass an override there.
  [ -n "$message" ] || message="${CC_MERGE_MESSAGE:-}"
  [ -n "$message" ] || { message="chore: merge $child into $target"; mdefault=1; }
  # rebase runs inside the child's own worktree when one holds it (git refuses to rebase a
  # branch from elsewhere) — but never over a dirty tree
  childdir="$(_cm_worktree_of "$repo" "$child")"
  if [ "$strategy" = rebase ] && [ -n "$childdir" ] \
     && [ -n "$(git -C "$childdir" status --porcelain 2>/dev/null)" ]; then
    echo "rebase-dirty: $child is checked out in $childdir with uncommitted changes; commit or stash them first" >&2
    rm -f "$cap"; return 5
  fi
  tdir="$(_cm_worktree_of "$repo" "$target")"
  if [ -z "$tdir" ]; then
    tmpparent="$(mktemp -d)"; tmp="$tmpparent/t"
    if ! git -C "$repo" worktree add -q "$tmp" "$target" >"$cap" 2>&1; then
      _cm_print_captured "$cap"
      echo "failed: cannot check out $target into a worktree for the merge" >&2
      rm -rf "$tmpparent"; rm -f "$cap"; return 1
    fi
    tdir="$tmp"
  fi
  case "$strategy" in
    squash)
      # NOTE: merge --squash sets no MERGE_HEAD, so reset --hard is the correct undo.
      local sqmsg="$message"
      [ -n "$mdefault" ] && sqmsg="$message (squash)"
      # Child-Tip trailer keeps the retired child SHA verifiable after the squash
      if [ -n "$tip" ] && ! printf '%s\n' "$sqmsg" | grep -q '^Child-Tip: '; then
        sqmsg="$sqmsg

Child-Tip: $tip"
      fi
      if git -C "$tdir" merge --squash "$child" >"$cap" 2>&1; then
        if git -C "$tdir" diff --cached --quiet; then
          skipped=1                       # already merged: squash staged nothing new
        elif ! git -C "$tdir" commit -q -m "$sqmsg" >"$cap" 2>&1; then
          rc=3                            # commit refused (e.g. commit-msg hook): staged squash PRESERVED
        fi
      else git -C "$tdir" reset --hard HEAD >/dev/null 2>&1; rc=1; fi ;;
    no-ff)
      if git -C "$tdir" merge --no-ff -m "$message" "$child" >"$cap" 2>&1; then
        :
      elif [ -n "$(git -C "$tdir" ls-files -u)" ]; then
        git -C "$tdir" merge --abort >/dev/null 2>&1; rc=1   # real content conflict
      elif git -C "$tdir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        rc=3                              # trees merged, commit refused: staged merge PRESERVED
      else
        rc=1; label="failed"              # merge refused before starting (see output)
      fi ;;
    rebase)
      local rbf=0
      if [ -n "$childdir" ]; then
        git -C "$childdir" rebase "$target" >"$cap" 2>&1 || rbf=1
      else
        git -C "$repo" rebase "$target" "$child" >"$cap" 2>&1 || rbf=1
      fi
      if [ "$rbf" = 0 ]; then
        git -C "$tdir" merge --ff-only "$child" >"$cap" 2>&1 || { rc=1; label="failed"; }
      else
        if [ -n "$childdir" ]; then git -C "$childdir" rebase --abort >/dev/null 2>&1
        else git -C "$repo" rebase --abort >/dev/null 2>&1; fi
        rc=1
      fi ;;
    *) echo "unknown strategy: $strategy" >&2; rc=2 ;;
  esac
  if [ "$rc" != 3 ]; then    # rc 3 keeps the staged merge for a manual finish (even the temp worktree)
    [ -n "$tmp" ] && git -C "$repo" worktree remove --force "$tmp" 2>/dev/null
    [ -n "$tmpparent" ] && rm -rf "$tmpparent"
  fi
  if [ -n "$skipped" ]; then echo "skipped: $child already merged into $target";
  elif [ "$rc" = 0 ]; then echo "merged: $child -> $target ($strategy)";
  elif [ "$rc" = 2 ]; then :   # usage error already on stderr
  elif [ "$rc" = 3 ]; then
    echo "commit-rejected: $child -> $target"
    echo "  staged merge PRESERVED in: $tdir (branch $target) — finish it by hand, e.g.:" >&2
    echo "    git -C '$tdir' commit -m 'chore: merge $child into $target'" >&2
    [ -n "$tmp" ] && echo "    ($tdir is a temporary worktree: git -C '$repo' worktree remove '$tdir' when done)" >&2
    _cm_print_captured "$cap"
  else
    if [ -n "$label" ]; then echo "$label: $child -> $target"; else echo "conflict: $child -> $target"; fi
    _cm_print_captured "$cap"
  fi
  rm -f "$cap"
  return $rc
}

cmd_capture() {       # <repo> <newBranch> <callerCwd>
  local repo="$1" branch="$2" cwd="$3" parent
  parent="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)"
  [ -n "$parent" ] || parent="$(_cm_main_branch "$repo")"
  cmd_set_parent "$repo" "$branch" "$parent"
}

cmd_trunk() {         # <repo> → trunk branch name
  _cm_main_branch "$1"
}

case "${1:-}" in
  set-parent) shift; cmd_set_parent "$@" ;;
  get-parent) shift; cmd_get_parent "$@" ;;
  done)       shift; cmd_done "$@" ;;
  is-done)    shift; cmd_is_done "$@" ;;
  tree)       shift; cmd_tree "$@" ;;
  preflight)  shift; cmd_preflight "$@" ;;
  do-merge)   shift; cmd_do_merge "$@" ;;
  capture)    shift; cmd_capture "$@" ;;
  trunk)      shift; cmd_trunk "$@" ;;
  *) echo "usage: cc-merge.sh {set-parent|get-parent|done|is-done|tree|preflight|do-merge|capture|trunk} ..." >&2; exit 2 ;;
esac
