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
  local repo="$1" child="$2" target="${3:-}" rc=0 cdir=""
  [ -n "$target" ] || target="$(cmd_get_parent "$repo" "$child")"
  # locate child worktree dir for the dirty check
  local br="" dir=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) dir="${line#worktree }" ;;
      "branch refs/heads/"*) [ "${line#branch refs/heads/}" = "$child" ] && cdir="$dir" ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain)
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

cmd_do_merge() {      # <repo> <child> <strategy> [<target>]
  local repo="$1" child="$2" strategy="$3" target="${4:-}"
  [ -n "$target" ] || target="$(cmd_get_parent "$repo" "$child")"
  local tdir tmp="" tmpparent="" rc=0 skipped=""
  # rebase cannot operate on a child that is checked out in its own worktree
  if [ "$strategy" = rebase ] && [ -n "$(_cm_worktree_of "$repo" "$child")" ]; then
    echo "rebase-unsupported: $child is checked out in a worktree; use --squash or --no-ff" >&2
    return 4
  fi
  tdir="$(_cm_worktree_of "$repo" "$target")"
  if [ -z "$tdir" ]; then
    tmpparent="$(mktemp -d)"; tmp="$tmpparent/t"
    git -C "$repo" worktree add -q "$tmp" "$target" || { rm -rf "$tmpparent"; return 1; }
    tdir="$tmp"
  fi
  case "$strategy" in
    squash)
      # NOTE: merge --squash sets no MERGE_HEAD, so reset --hard is the correct undo.
      if git -C "$tdir" merge --squash "$child" >/dev/null 2>&1; then
        if git -C "$tdir" diff --cached --quiet; then
          skipped=1                       # already merged: squash staged nothing new
        else
          git -C "$tdir" commit -q -m "merge $child into $target (squash)" || { git -C "$tdir" reset --hard HEAD >/dev/null 2>&1; rc=1; }
        fi
      else git -C "$tdir" reset --hard HEAD >/dev/null 2>&1; rc=1; fi ;;
    no-ff)
      git -C "$tdir" merge --no-ff -m "merge $child into $target" "$child" >/dev/null 2>&1 \
        || { git -C "$tdir" merge --abort 2>/dev/null; rc=1; } ;;
    rebase)
      if git -C "$repo" rebase "$target" "$child" >/dev/null 2>&1; then
        git -C "$tdir" merge --ff-only "$child" >/dev/null 2>&1 || rc=1
      else git -C "$repo" rebase --abort 2>/dev/null; rc=1; fi ;;
    *) echo "unknown strategy: $strategy" >&2; rc=2 ;;
  esac
  [ -n "$tmp" ] && git -C "$repo" worktree remove --force "$tmp" 2>/dev/null
  [ -n "$tmpparent" ] && rm -rf "$tmpparent"
  if [ -n "$skipped" ]; then echo "skipped: $child already merged into $target";
  elif [ "$rc" = 0 ]; then echo "merged: $child -> $target ($strategy)";
  elif [ "$rc" = 2 ]; then :   # usage error already on stderr
  elif [ "$rc" = 4 ]; then :   # rebase-unsupported already on stderr
  else echo "conflict: $child -> $target"; fi
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
