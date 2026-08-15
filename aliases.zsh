# cc-stack · aliases
# Local main channel: cmux native teams launch, teammates forced in-process (no split panes):
# cmux claude-teams defaults teammate mode to `auto` (named teammates → split pane; their completion
# event races pane teardown → stuck inline task marker until Ctrl+C). Override per launch: append
# --teammate-mode <mode> AFTER this alias (last flag wins).
alias ccteam='cmux claude-teams --teammate-mode in-process'

# By default, run claude (and cld) in cmux as "team-ready" (= cmux claude-teams) — teammates can be spawned mid-task.
# Subcommands (mcp/config…), headless (-p), remote (SSH) auto-route to native claude.
# Force native temporarily:  command claude …  or  \claude …
claude() { ~/.config/cc-stack/cc-claude "$@" }

# Spin a task off into an independent sub-task: build worktree + new cmux tab running claude + send initial prompt
# Usage: gwt-claude <name> "<initial-prompt>" [--prefix <p>] [--base <b>]
alias gwt-claude='~/.config/cc-stack/cc-dispatch.sh wt-claude'

# cc-stack self-test: run the smoke test in one command (self-check for regressions after editing cc-stack)
alias gwt-test='bash ~/.config/cc-stack/test.sh'
