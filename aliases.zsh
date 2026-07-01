# cc-stack · aliases
# Local main channel: cmux native teams — teammate/subagent = native cmux pane, most accurate per-agent notifications
alias ccteam='cmux claude-teams'

# By default, run claude (and cld) in cmux as "team-ready" (= cmux claude-teams) — teammates can be spawned mid-task.
# Subcommands (mcp/config…), headless (-p), remote (SSH/Zellij) auto-route to native claude.
# Force native temporarily:  command claude …  or  \claude …
claude() { ~/.config/cc-stack/cc-claude "$@" }

# Spin a task off into an independent sub-task: build worktree + new cmux tab running claude + send initial prompt
# Usage: gwt-claude <name> "<initial-prompt>" [prefix=feat] [base=HEAD]
alias gwt-claude='~/.config/cc-stack/cc-worktree-claude.sh'

# cc-stack self-test: run the smoke test in one command (self-check for regressions after editing cc-stack)
alias gwt-test='bash ~/.config/cc-stack/test.sh'

# SSH+Zellij fallback channel: attach/create the persistent local session "main"
# Connect from a remote machine:  ssh <mini-tailscale-host> -t 'zellij attach -c main'
alias zmain='zellij attach -c main'
