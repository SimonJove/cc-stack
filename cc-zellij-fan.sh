#!/usr/bin/env bash
# cc-stack · Fan every worktree of the current git repo into its own zellij pane, each running claude.
# For the zellij fallback channel. Call `gwt-fan` from inside zellij.
# Override the launch command with CC_FAN_CMD (default: claude).
set -eu

[ -n "${ZELLIJ:-}" ] || { echo "must run inside zellij" >&2; exit 1; }
git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "cc-fan: not inside a git repo" >&2; exit 0; }

launch="${CC_FAN_CMD:-claude}"
git worktree list --porcelain | awk '/^worktree /{print $2}' | while IFS= read -r p; do
  [ -d "$p" ] || continue
  zellij action new-pane --cwd "$p" -n "$(basename "$p")" -- $launch
done
