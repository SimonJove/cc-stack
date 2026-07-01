#!/usr/bin/env bash
# cc-stack · Claude Code hook (Stop / SubagentStop / Notification)
#
# Status: no-op.
#   - Local cmux / cmux native teams: already has native per-agent notifications, this script is unneeded.
#   - Zellij fallback channel: no reliable external notification hook yet; add when needed.
# The old "send message to tmux" logic is gone — tmux is uninstalled and it would misfire against cmux's tmux shim.
# settings.json still points its hooks here, so we keep this as a safe, side-effect-free no-op.
cat >/dev/null 2>&1 || true   # drain the hook's stdin to avoid pipe errors
exit 0
