#!/usr/bin/env bash
# cc-stack · Append one worktree sub-task record to the task list (read by gwt-status).
# The single write point, keeping the TSV format consistent with gwt-status's parsing.
# Called by cc-cmux-surface-claude.sh and cc-worktree-claude.sh.
# Usage: cc-tasks-log.sh <worktree-dir> <surface_ref> <caller_surface> <initial-prompt>
# Fields (TAB-separated): time \t branch \t surface \t dir \t caller-tab \t task-summary
set -u

dir="${1:-}"; ref="${2:-?}"; caller="${3:-}"; prompt="${4:-}"
[ -n "$dir" ] || exit 0
f="${CC_TASKS_FILE:-$HOME/.config/cc-stack/worktree-tasks.tsv}"

branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
# Task summary: collapse to one line, strip TAB/pipe, truncate — keeps TSV and `column` display intact
summary="$(printf '%s' "$prompt" | tr '\t\n' '  ' | tr '|' '/' | cut -c1-140)"
[ -n "$summary" ] || summary='(idle ccteam, no initial prompt)'

# Locked append (avoid losing lines racing with gwt-status's prune rewrite). mkdir is atomic; macOS lacks flock.
lock="$f.lock"
for _ in $(seq 1 60); do
  if mkdir "$lock" 2>/dev/null; then trap 'rmdir "$lock" 2>/dev/null' EXIT; break; fi
  sleep 0.05
done
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$branch" "$ref" "$dir" "$caller" "$summary" \
  >> "$f" 2>/dev/null || true
