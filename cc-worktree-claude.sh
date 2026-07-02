#!/usr/bin/env bash
# cc-stack · gwt-claude: spin a task off the main task into an independent sub-task.
#   This script only handles "build/reuse the worktree + ensure .gitignore", then DELEGATES the whole
#   "open tab + copy .env + start ccteam (plan) + pre-trust + send prompt + register" part to
#   cc-cmux-surface-claude.sh (single source of truth, avoids two copies of the logic drifting).
# Usage: cc-worktree-claude.sh <name> <initial-prompt> [branch-prefix=feat] [base=HEAD]
set -u

name="${1:-}"; prompt="${2:-}"; prefix="${3:-feat}"; base="${4:-HEAD}"
[ -n "$name" ] && [ -n "$prompt" ] || {
  echo "usage: cc-worktree-claude.sh <name> <initial-prompt> [branch-prefix=feat] [base=HEAD]" >&2; exit 2; }

# Must be inside cmux (this whole thing is designed around cmux tabs)
command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 || {
  echo "✗ can't reach cmux, aborting (this command needs cmux)" >&2; exit 1; }

# ── Resolve main repo root + worktree dir (works from the main repo or from any worktree) ──
g="$(git rev-parse --git-common-dir 2>/dev/null)" || { echo "✗ not inside a git repo" >&2; exit 1; }
g="$(cd "$g" && pwd -P)"; root="$(dirname "$g")"
if [ -d "$root/.claude" ]; then rel=".claude/worktrees"; else rel=".worktrees"; fi
wtbase="$root/$rel"; mkdir -p "$wtbase"
gi="$root/.gitignore"
grep -qxF "/$rel/" "$gi" 2>/dev/null || { printf '/%s/\n' "$rel" >> "$gi"; echo "  ↳ .gitignore now ignores /$rel/"; }
wtpath="$wtbase/$name"; branch="$prefix/$name"

# ── Build/reuse the worktree ──
if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$root" worktree add "$wtpath" "$branch" || exit 1
else
  git -C "$root" worktree add "$wtpath" -b "$branch" "$base" || exit 1
fi
echo "✔ worktree : $wtpath"
echo "✔ branch   : $branch"
"$HOME/.config/cc-stack/cc-merge.sh" capture "$root" "$branch" "$PWD" >/dev/null 2>&1

# ── Delegate: open tab + copy .env + start ccteam (plan) + pre-trust + send prompt + register ──
exec "$HOME/.config/cc-stack/cc-cmux-surface-claude.sh" "$wtpath" "$prompt"
