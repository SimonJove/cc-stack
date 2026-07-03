#!/usr/bin/env sh
# cc-stack · share a gitignored test corpus (e.g. scratchpad/e2e) across worktrees
# via INDEPENDENT COPIES: seed a fresh worktree from the main repo, and merge new
# work back into the main repo when the worktree is cleaned up.
#
#   cc-worktree-shared.sh seed    <root> <worktree> [<relbase>...]
#   cc-worktree-shared.sh collect <root> <worktree> [<relbase>...]
#
# <relbase> is a DIRECTORY relative to the repo root (e.g. scratchpad/e2e).
# With no <relbase> args, $CC_WT_SHARE decides (space-separated; this script is the
# single home of its default). An exported-but-EMPTY CC_WT_SHARE disables (no-op).
# Regenerable outputs (*-shots, reports, output, html) are never copied either way.
#
# Why copies, not a symlink: worktrees legitimately diverge shared files like
# lib/harness.mjs; a single physical copy would let one worktree's in-flight edit
# break another's run. Copies give isolation; collect folds the new work back.
#
# collect NEVER overwrites the main repo. On a same-name-but-different-content
# clash it preserves the worktree's version under `<name>.from-<branch>.<ext>`
# and reports it, so nothing is ever silently lost (you reconcile harness/conditions
# by hand). Identical files are skipped; brand-new files are copied in.
set -u
set -f   # no pathname expansion: a filename like x[1].mjs must never glob-match x1.mjs and silently vanish

# find files under $1, excluding regenerable output dirs
_shared_files() {
  find "$1" -type f \
    ! -path '*/*-shots/*' ! -path '*/reports/*' \
    ! -path '*/output/*'  ! -path '*/html/*' 2>/dev/null
}

# <relpath> <tag> -> relpath with .from-<tag> inserted before the extension
_shared_suffix() {
  rel=$1; tag=$2
  d=$(dirname "$rel"); b=$(basename "$rel")
  case "$b" in
    *.*) nb="${b%.*}.from-$tag.${b##*.}" ;;
    *)   nb="$b.from-$tag" ;;
  esac
  if [ "$d" = "." ]; then echo "$nb"; else echo "$d/$nb"; fi
}

cmd="${1:-}"; shift 2>/dev/null || true
root="${1:-}"; worktree="${2:-}"; shift 2 2>/dev/null || true
[ -n "$root" ] && [ -n "$worktree" ] || { echo "usage: cc-worktree-shared.sh {seed|collect} <root> <worktree> [<relbase>...]" >&2; exit 2; }
# No <relbase> args → resolve from CC_WT_SHARE (empty → zero args → no-op below)
[ $# -gt 0 ] || set -- ${CC_WT_SHARE-scratchpad/e2e}

case "$cmd" in
  seed)
    [ -d "$worktree" ] || { echo "cc-worktree-shared: worktree not found: $worktree" >&2; exit 1; }
    for base in "$@"; do
      base="${base%/}"                      # tolerate a trailing slash in config
      [ -n "$base" ] || continue
      src="$root/$base"; dst="$worktree/$base"
      [ -d "$src" ] || continue
      _shared_files "$src" | while IFS= read -r f; do
        rel=${f#"$src"}; rel=${rel#/}       # prefix-strip tolerant of find's slash handling
        target="$dst/$rel"
        [ -e "$target" ] && continue          # --ignore-existing: never clobber worktree edits
        mkdir -p "$(dirname "$target")" && cp -p "$f" "$target"
      done
      echo "  ↳ seeded $base into worktree"
    done
    ;;
  collect)
    [ -d "$worktree" ] || exit 0
    branch=$(git -C "$worktree" symbolic-ref --short HEAD 2>/dev/null || echo wt)
    tag=$(printf '%s' "$branch" | tr '/ ' '--')
    for base in "$@"; do
      base="${base%/}"                      # tolerate a trailing slash in config
      [ -n "$base" ] || continue
      src="$worktree/$base"; dst="$root/$base"
      [ -d "$src" ] || continue
      added=0; conflict=0; same=0
      # loop in the current shell (no subshell pipe) so counts survive
      tmp_list=$(_shared_files "$src")
      IFS='
'
      for f in $tmp_list; do
        rel=${f#"$src"}; rel=${rel#/}       # prefix-strip tolerant of find's slash handling
        target="$dst/$rel"
        if [ ! -e "$target" ]; then
          mkdir -p "$(dirname "$target")" && cp -p "$f" "$target" && { echo "  + $rel"; added=$((added+1)); }
        elif cmp -s "$f" "$target"; then
          same=$((same+1))
        else
          crel=$(_shared_suffix "$rel" "$tag")
          mkdir -p "$(dirname "$dst/$crel")" && cp -p "$f" "$dst/$crel" \
            && { echo "  ! conflict $rel -> kept as $crel"; conflict=$((conflict+1)); }
        fi
      done
      unset IFS
      echo "  collected $base: $added new, $conflict conflict(s) preserved, $same identical skipped"
    done
    ;;
  *)
    echo "usage: cc-worktree-shared.sh {seed|collect} <root> <worktree> [<relbase>...]" >&2
    exit 2
    ;;
esac
