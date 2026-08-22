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
  # F7: nodes = branches checked out in a worktree ∪ branches with a ccMergeInto config
  # (gwt-rm without --branch leaves unmerged branches with no worktree — they must stay visible:
  # this tree is what the merge gate reads). No-worktree branches report dirty as clean:
  # without a checkout there can BE no uncommitted changes, and every downstream ready
  # test (gwt-merge / gwt-collect / gwt-tree) compares dirty=="clean" — a distinct value
  # here would make such a branch permanently not-ready for a reason that cannot exist.
  local repo="$1" trunk dir="" line b parent ahead dirty done seen=""
  trunk="$(_cm_main_branch "$repo")"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) dir="${line#worktree }" ;;
      "branch refs/heads/"*)
        b="${line#branch refs/heads/}"
        if [ "$b" = "$trunk" ]; then dir=""; continue; fi
        seen="$seen $b"
        parent="$(cmd_get_parent "$repo" "$b")"
        ahead="$(git -C "$repo" rev-list --count "$parent..$b" 2>/dev/null || echo 0)"
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then dirty=dirty; else dirty=clean; fi
        if cmd_is_done "$repo" "$b"; then done=done; else done=-; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$parent" "$ahead" "$dirty" "$done"
        dir="" ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain)
  # F7 second pass: branches known only through their config. get-regexp prints "<key> <value>"
  # SPACE-separated (a branch name can never contain one).
  git -C "$repo" config --get-regexp '^branch\..*\.ccMergeInto$' 2>/dev/null | while IFS=' ' read -r cfg_key cfg_val; do
    # git config lowercases the variable part (branch.<b>.ccMergeInto → …ccmergeinto), so
    # strip by the LAST dot — the key is always the final component, branch names may hold dots
    b="${cfg_key#branch.}"; b="${b%.*}"
    case " $seen " in *" $b "*) continue ;; esac
    [ "$b" = "$trunk" ] && continue
    # a config section can outlive its branch (hand-edited config, a prune race): never list
    # a branch that does not exist — a ghost node would gate its parent ready-check forever
    # on a line that can never be merged at all
    git -C "$repo" show-ref --verify --quiet "refs/heads/$b" || continue
    parent="$(cmd_get_parent "$repo" "$b")"
    ahead="$(git -C "$repo" rev-list --count "$parent..$b" 2>/dev/null || echo 0)"
    if cmd_is_done "$repo" "$b"; then done=done; else done=-; fi
    # dirty=clean: no worktree = no working tree = no possible uncommitted changes
    printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$parent" "$ahead" "clean" "$done"
  done
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
  # target-not-self — a branch merged into itself passes every other check, stages nothing, and
  # returns "skipped: already merged" rc 0, which gwt-merge reads as a landing and archives.
  if [ "$target" = "$child" ]; then echo "check: target-not-self FAIL"; rc=1
  else echo "check: target-not-self ok"; fi
  # conflict (git 2.38+ --write-tree exits nonzero on conflict)
  if git -C "$repo" merge-tree --write-tree "$target" "$child" >/dev/null 2>&1; then
    echo "check: conflict ok"; else echo "check: conflict FAIL"; rc=1; fi
  echo "target: $target"
  # Where the target itself lands, and whether the target is a sub-task line rather than the
  # campaign branch. NOT a check (a nested tree merges into a sub-task line by design) — it is the
  # one thing a human cannot see for themselves after a fast-forward makes two branches identical.
  local tparent tcfg
  tcfg="$(git -C "$repo" config --get "branch.$target.ccMergeInto" 2>/dev/null)"
  tparent="$(cmd_get_parent "$repo" "$target")"
  [ -n "$tparent" ] && echo "target-parent: $tparent"
  [ -n "$tcfg" ] && echo "note: $target is itself a recorded sub-task line (it merges on into $tcfg) — landing here does NOT advance $tcfg"
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
  # Refused BEFORE any git runs (preflight also checks it, but --force can wave preflight through
  # and direct callers skip it entirely): merging a branch into itself stages nothing and would
  # report "skipped: already merged" rc 0 — a no-op dressed up as a landing.
  if [ "$target" = "$child" ]; then
    echo "refused: $child -> $target (a branch cannot be its own merge target)" >&2; return 2
  fi
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

cmd_capture() {       # <repo> <newBranch> <callerCwd> [<base>]
  # An EXPLICIT base branch wins over the caller's cwd, because it is the only signal that
  # survives a fast-forward. Once a sibling line ff-merges into the campaign branch the two tips
  # are IDENTICAL — same commit, same working tree — so "which branch is this checkout on" can no
  # longer tell campaign from sibling, and a caller standing one directory off silently records a
  # SIBLING as the merge target (2026-08-17: a line was one `y` away from being folded into its
  # sibling while the campaign branch stayed put). The graph cannot distinguish them either
  # (merge-base is the same commit for both), so intent is the only usable evidence — record it.
  # A base that does not name a branch (HEAD, a tag, a sha) is not intent: fall back to the cwd.
  # NEW CONTRACT: prints "target=<branch>\tsource=<explicit|cwd|trunk|kept>" to stdout, so the
  # dispatch paths can echo what was recorded (F4). kept = the branch already carries a target
  # and THIS call brings no explicit branch base — a reused branch: wt-claude re-runs capture with
  # its default base=HEAD, which is not intent, and must not overwrite an earlier --base (F6).
  # An explicit branch base still overwrites: that IS intent.
  local repo="$1" branch="$2" cwd="$3" base="${4:-}" parent="" source=""
  local existing
  existing="$(git -C "$repo" config --get "branch.$branch.ccMergeInto" 2>/dev/null)"
  # H2: origin/<b> — the remote-tracking name itself is not a merge target; when a same-named
  # LOCAL branch exists record that, else the base is unusable: warn, then the chain falls back.
  case "$base" in
    origin/*)
      local lb="${base#origin/}"
      if git -C "$repo" show-ref --verify --quiet "refs/heads/$lb" 2>/dev/null; then
        base="$lb"
      else
        echo "warn: base origin/$lb has no local branch refs/heads/$lb; not treated as the merge target" >&2
        base=""
      fi ;;
  esac
  if [ -n "$base" ] && git -C "$repo" show-ref --verify --quiet "refs/heads/$base" 2>/dev/null; then
    parent="$base"; source="explicit"
  else
    # Whatever the base is by now (cleared above, HEAD, a sha, a tag, an unexpanded $VAR), it is
    # not intent — when the caller actually passed one, say so (F2/F4: the fallback must be
    # visible). HEAD stays quiet: it is wt-claude's documented default, not a mistake.
    if [ -n "$base" ] && [ "$base" != HEAD ]; then
      echo "warn: base $base is not a local branch; not treated as the merge target" >&2
    fi
    # kept must never hand back a SELF-target: a section that already says "merge into
    # myself" is dirty data (hand-edited, or left behind by an older bug), not intent —
    # skip kept and let the chain overwrite it; the self-guard below has the last word.
    if [ -n "$existing" ] && [ "$existing" != "$branch" ]; then
      printf 'target=%s\tsource=kept\n' "$existing"
      return 0
    fi
    parent="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)"
    if [ -n "$parent" ]; then
      source="cwd"
    else
      parent="$(_cm_main_branch "$repo")"
      source="trunk"
    fi
  fi
  # Never record a branch as its own merge target: that is the shape a mis-resolved caller cwd
  # leaves behind (the branch's own worktree), and it merges into itself as a silent no-op. With
  # nothing recorded, get-parent answers the trunk — wrong perhaps, but never a fake success.
  [ "$parent" = "$branch" ] && return 0
  cmd_set_parent "$repo" "$branch" "$parent"
  printf 'target=%s\tsource=%s\n' "$parent" "$source"
}

cmd_capture_dispatch() {   # <repo> <branch> <callerCwd> [<base>] — capture + the dispatcher echo
  # The one place the two dispatch paths (wt-claude, surface/hook) learn what capture recorded:
  # echoes "✔/⚠ merge target: X (…)" so the dispatcher sees it, passes capture warnings through,
  # and leaves a cc-failures.log breadcrumb when CC_CAPTURE_CRUMB=1 and the target did not come
  # from an explicit base (the hook path: Claude Code swallows hook stdout, so the board log is
  # the only channel — the rules require a base on every dispatch, a missing one must be seen).
  local repo="$1" branch="$2" cwd="$3" base="${4:-}"
  local capout="" wtmp warn="" tgt="" src=""
  wtmp="$(mktemp 2>/dev/null || echo /dev/null)"
  capout="$(cmd_capture "$repo" "$branch" "$cwd" "$base" 2>"$wtmp")"
  warn="$(cat "$wtmp" 2>/dev/null || true)"
  [ "$wtmp" != /dev/null ] && rm -f "$wtmp" 2>/dev/null
  [ -n "$warn" ] && printf '%s\n' "$warn" >&2
  if [ -n "$capout" ]; then
    tgt="${capout#target=}"; tgt="${tgt%%$'\t'*}"
    src="${capout##*source=}"
    if [ "$src" = explicit ]; then
      echo "✔ merge target: $tgt (explicit --base)"
    else
      echo "⚠ merge target: $tgt (from $src — no explicit base; cc-merge.sh set-parent to change)"
    fi
  fi
  if { [ "${CC_CAPTURE_CRUMB:-0}" = 1 ] && [ "$src" != explicit ]; } || [ -n "$warn" ]; then
    { echo "[$(date '+%F %T')] $repo — merge target for $branch recorded as: ${tgt:-none} (source: ${src:-none}); base arg: ${base:-none}" \
        >> "${CC_SEND_FAILLOG:-$HOME/.config/cc-stack/cc-failures.log}"; } 2>/dev/null || true
  fi
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
  capture-dispatch) shift; cmd_capture_dispatch "$@" ;;
  trunk)      shift; cmd_trunk "$@" ;;
  *) echo "usage: cc-merge.sh {set-parent|get-parent|done|is-done|tree|preflight|do-merge|capture|capture-dispatch|trunk} ..." >&2; exit 2 ;;
esac
