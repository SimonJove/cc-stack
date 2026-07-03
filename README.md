# cc-stack — cmux + Claude Code + git worktree parallel dev stack

A workflow for developing projects with **Claude Code** inside the **cmux** terminal. The core capability: **let the main Claude spin any task off into an isolated worktree sub-task with one sentence — it opens a new tab, starts a parallel claude in it, and (in plan mode) presents a plan for your approval before editing code**, while you (the main session) stay put and keep working.

Around that: a task board (`gwt-status`), lifecycle management (`gwt-*`), a one-command installer (`install.sh`), and remote/low-bandwidth fallback channels.

---

## Contents
- [Three channels](#three-channels)
- [Quick start / install](#quick-start--install)
- [Core: worktree parallel sub-tasks](#core-worktree-parallel-sub-tasks)
- [Command cheatsheet](#command-cheatsheet)
- [Environment variables](#environment-variables)
- [Architecture & data flow](#architecture--data-flow)
- [Troubleshooting](#troubleshooting)
- [File list](#file-list)
- [SSH + Zellij fallback channel](#ssh--zellij-fallback-channel)
- [cmux.json key settings](#cmuxjson-key-settings)
- [Rollback](#rollback)

---

## Three channels

| Channel | When | How |
|------|--------|--------|
| **Local main** | sitting at the mac mini | **cmux native teams** (`ccteam`) — teammate/subagent = native cmux pane, most accurate per-agent notifications |
| **Remote live view** | connecting back to the mini from another machine | **screen sharing + Tailscale** — you see the same still-running cmux, all sessions continue as-is |
| **Lightweight terminal fallback** | low bandwidth / phone / pure terminal SSH | **SSH + Zellij** — attach the mini's persistent zellij session, survives disconnects |

> Design point: local agent orchestration goes to **cmux**; **Zellij is only a fallback terminal channel**.

---

## Quick start / install

Prereq: cmux ([cmux.com](https://cmux.com)) and Claude Code installed. The installer is **idempotent, re-runnable, and backs up before changing anything** (`*.bak.<timestamp>`). It installs into a target dir (default `~/.config/cc-stack`) and configures the environment.

### Option A: install from GitHub with one command (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/SimonJove/cc-stack/main/install.sh | bash
```
It auto `git clone`s into `~/.config/cc-stack` and configures. To install elsewhere:
```bash
curl -fsSL https://raw.githubusercontent.com/SimonJove/cc-stack/main/install.sh | bash -s -- --dir ~/somewhere/cc-stack
```

### Option B: clone anywhere, then install

```bash
git clone https://github.com/SimonJove/cc-stack.git ~/Desktop/cc-stack   # clone wherever
cd ~/Desktop/cc-stack && ./install.sh                                     # guided: asks where to install (default ~/.config/cc-stack), copies there and configures
```

### What the installer does (6 idempotent steps)
1. Install the source into the target dir (excluding `.git`/backups/runtime-generated files)
2. Executable bits + dependency check (cmux / claude / git / python3 / zsh / shasum / column)
3. Make `~/.zshrc` load `worktree.zsh` + `aliases.zsh`
4. Add hooks to `~/.claude/settings.json` (PostToolUse to open the tab + notification placeholders)
5. Add the worktree rules to `~/.claude/CLAUDE.md` (a managed block, sourced from `claude-rules.md`)
6. cmux.json workflow settings (optional, `--cmux`; deep-merged, your config is backed up)

**Options**: `--dir <path>`, `--repo <url>`, `--yes` (non-interactive), `--dry-run` (preview only), `--cmux`.
Matching env vars: `CC_STACK_DIR` / `CC_STACK_REPO`.

**After installing**: open a new terminal (or `source <target-dir>/worktree.zsh`), then start a new claude session. After editing cc-stack, run `gwt-test`.

---

## Core: worktree parallel sub-tasks

### How to use (from the main Claude)

Just tell the main Claude: **"open a worktree and fix X", "spin off a sub-task to do Y in parallel"**, etc. Following the `CLAUDE.md` rules it runs a Bash command:

```bash
CC_WT_PROMPT='the full first instruction for the task (may be multi-line)' git worktree add .claude/worktrees/<name> -b feat/<name>
```

### What happens

1. The **PostToolUse hook** detects this `git worktree add` and parses out the new directory;
2. opens a **new tab in the current cmux workspace** (background, no focus steal), cwd = the worktree;
3. **copies** the main repo's `.env` etc. (`$CC_WT_COPY`) into the worktree;
4. **pre-trusts** the directory (skips claude's "Do you trust this folder?" prompt);
5. starts a **`ccteam` (team-ready claude)** in the new tab with **`--permission-mode plan`**;
6. sends `CC_WT_PROMPT` as the **first message** (via a temp file, so any length / multi-line works);
7. **registers** the sub-task into the list (queryable via `gwt-status`).

### Sub-task working rules (enforced by CLAUDE.md + the prompt, both)

- **Plan first**: in plan mode, the sub-task presents a plan and **waits for your approval** before editing;
- **Respect the project harness**: works per the **sub-task's own project** `CLAUDE.md`/`.claude`, no going rogue;
- **Don't land changes**: `commit` / `rebase` / `merge` / `push` / remove worktree / delete branch **all require your authorization**, defaulting to "keep the branch";
- **Backchannel**: the sub-task knows how to `cmux send` a report back to the main task.

### The ways to create a worktree

| Way | Who | Effect |
|---|---|---|
| Bash `git worktree add` (with `CC_WT_PROMPT`) | main Claude / you | ✅ new tab + parallel claude (**the primary path**) |
| `EnterWorktree` (native tool) | — | ❌ moves the current claude in, **no new tab** (avoids two claudes colliding) |
| `gwt-claude <name> "<prompt>"` (manual) | you | ✅ same as the Bash path, one command (also copies `.env`) |
| `gwt-new <name>` (manual) | you | just builds a worktree + opens an empty workspace, no claude |

> Not inside cmux (remote SSH / Zellij) → everything is a **safe no-op**.

---

## Hierarchical worktrees (A ⊃ {A1,A2,A3})

When a sub-task claude spins off its own worktrees, cc-stack records each
child's merge target automatically (`git config branch.<b>.ccMergeInto`,
captured from the caller's branch at creation). You then drive the merges
back up the tree — each stops at a confirmation gate.

    gwt-tree                 # see the whole tree: A ⊃ {A1,A2,A3}, ready state, tabs
    gwt-done                 # (run inside A1) mark A1 ready when it's finished
    gwt-merge A1             # gated merge A1 → feat/A (asks strategy [default: squash] + confirmation)
    gwt-collect A            # merge every ready child of A into A, one gate each
    gwt-merge A              # finally merge A → main (its recorded/def target)

`gwt-merge` never merges without an explicit `y`. Readiness = clean working
tree **and** `gwt-done`; otherwise it warns and needs `--force`. Cleanup
(`gwt-rm`) stays a separate, explicit step.

---

## Command cheatsheet

### cmux native teams
```
ccteam                 # = cmux claude-teams, launch team-enabled Claude Code
ccteam --continue      # continue the last session
ccteam --model sonnet  # pick a model
```
> Typing `claude`/`cld` inside cmux also auto-launches "team-ready"; subcommands (mcp/config), headless (`-p`), and remote auto-route to native claude. Force native temporarily: `command claude …` or `\claude …`.

### git worktree sub-tasks
```
gwt-claude <name> "<prompt>"   # build worktree + new tab running claude (plan) + send prompt (manual spawn)
gwt-new <name>                 # build worktree and cd into it (opens an empty workspace, no claude)
gwt-ls                         # git worktree list
gwt-status                     # board: status (✔live/⌫closed/?old-session) + branch + surface + dir + what it's doing (auto-cleans deleted dirs)
gwt-rm <name> [--branch]       # remove worktree (+ clear task record + clear pre-trust; optionally the branch)
gwt-prune                      # compact the task list (drop dead records + keep newest per dir)
gwt-clean                      # git worktree prune + show current state
gwt-fan                        # zellij only: fan each worktree into a pane running claude
gwt-help                       # command cheatsheet
gwt-test                       # run the smoke test (self-check for regressions after editing cc-stack)
```

- Worktree dir: `<project>/.claude/worktrees/<name>` when the project has `.claude`, otherwise `<project>/.worktrees/<name>` (the base dir is auto-added to `.gitignore`); branch is `feat/<name>`.

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `CC_WT_PROMPT` | (none) | The **first message** for the sub-task when creating a worktree; multi-line supported. Without it, an idle ccteam starts. |
| `CC_WT_PERMISSION_MODE` | `plan` | The sub-task claude's `--permission-mode`. Set `default`/`acceptEdits` to skip planning and edit directly. |
| `CC_WT_PRETRUST` | `1` | Whether to pre-trust the worktree dir (skip the trust prompt). Set `0` to disable (falls back to screen-scrape confirmation). |
| `CC_WT_COPY` | `.env .env.local .claude/settings.local.json` | Files copied from the main repo into a new worktree (space-separated, no spaces in paths). |
| `CC_WT_SHARE` | `scratchpad/e2e` | Gitignored dir(s) shared across worktrees as **independent copies**: seeded into a new worktree on create, merged back into the main repo on `gwt-rm` (never overwrites main; clashes kept as `<name>.from-<branch>.<ext>`). Space-separated; **export** it to customize, exported-empty (`""`) disables. |
| `CC_TASKS_FILE` | `~/.config/cc-stack/worktree-tasks.tsv` | Task list path (rarely changed). |

---

## Architecture & data flow

```
Main Claude: "open a worktree"
  │  (Bash: CC_WT_PROMPT=... git worktree add ...)
  ▼
cc-worktree-cmux-hook.sh        PostToolUse(Bash) hook: parse the command for the new worktree path (cross-repo -C aware; $VAR falls back to mtime)
  │                             Only triggers on a real `git worktree add`; list/remove/EnterWorktree do not.
  ▼
cc-cmux-surface-claude.sh  ◀────── single source of truth ──────  cc-worktree-claude.sh (gwt-claude: builds worktree then exec-delegates)
  │  ① ping/new-surface short retry (rides out cmux hiccups)  ② copy .env  ③ pre-trust (cc-trust.sh)
  │  ④ open tab  ⑤ probe shell-ready  ⑥ start ccteam --permission-mode plan via temp file + send prompt
  │  ⑦ screen-scrape trust fallback  ⑧ register (cc-tasks-log.sh)   failure → cc-failures.log + cmux notify
  ▼
worktree-tasks.tsv  ──►  gwt-status (reads the list + judges liveness via cmux; auto-prunes deleted dirs)
```

**Key design choices:**
- **Single source of truth**: the whole tab-opening logic lives only in `cc-cmux-surface-claude.sh`; both the hook and `gwt-claude` call it, so the logic can't drift into two copies.
- **Prompt via file**: `ccteam "$(cat tempfile)"` — the command is short (a very long line would be shredded), and the shell passes the whole file (newlines and all) to claude as a single argument (multi-line preserved).
- **Reliability**: short retries during cmux hiccups; a hard failure leaves `cc-failures.log` (surfaced by `gwt-status`).
- **Reliable status**: `gwt-status` judges tab liveness against cmux's live surface list; after a cmux restart, stale refs show `?old-session` rather than falsely "closed".

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| **Worktree built but no tab opened** | Usually **cmux is restarting / transiently unstable**. The script already retries; a hard failure is logged to `cc-failures.log` and `gwt-status` warns at the top. Fix by hand: `gwt-claude <name> "<prompt>"`. |
| **Main Claude "does it in the background", no tab** | It used `EnterWorktree` instead of Bash `git worktree add`. Make sure the global `CLAUDE.md` rules block is present (`install.sh` installs it) and it's a **newly started session** (CLAUDE.md is read at session start). |
| **Sub-task edits code right away** | Not in plan mode. Check `CC_WT_PERMISSION_MODE` isn't set to a non-plan value; only newly spawned sub-tasks pick it up. |
| **Sub-task auto-merges / removes the worktree** | The superpowers `finishing-a-development-branch` skill picked "merge" by itself in an autonomous sub-task. The CLAUDE.md rules forbid this; make sure the rules block is present and it's a new session. |
| **`gwt-status` shows all `?old-session`** | cmux was restarted, all registered surface refs are stale. Dirs still exist, cleanup is unaffected; `gwt-prune` compacts it. |
| **Sub-task can't run without `.env`** | Ensure `$CC_WT_COPY` includes the needed files; the hook path now copies them automatically. **Port collisions** between parallel dev servers must be handled by parameterizing ports in each worktree's `.env`. |
| **Afraid of breaking cc-stack when editing it** | `gwt-test` runs the smoke test (hook parsing / registration / prune / trust) in one command. |

---

## File list

```
worktree.zsh                 # gwt-* functions (sourced by .zshrc)
aliases.zsh                  # ccteam / zmain / gwt-test / claude router (sourced by .zshrc)
cc-claude                    # claude/cld launch router (in cmux → team-ready, remote/subcommands → native)
cc-worktree-cmux-hook.sh     # PostToolUse(Bash) hook: git worktree add → call the surface script
cc-cmux-surface-claude.sh    # [single source of truth] open tab + copy .env + pre-trust + start ccteam(plan) + send prompt + register (with retries/failure breadcrumb)
cc-worktree-claude.sh        # gwt-claude: build worktree + ensure .gitignore, delegates the surface part above
cc-cmux-workspace.sh         # used by gwt-new: open an empty workspace for a dir (no-op when not in cmux)
cc-tasks-log.sh              # single task-registration entry point (keeps TSV format consistent)
cc-trust.sh                  # pre-authorize/revoke trust for a dir (edits ~/.claude.json, atomic write, only adds/removes pure-trust signatures)
cc-zellij-fan.sh             # worktree fan-out (zellij fallback channel)
cc-notify.sh                 # CC notification hook (tmux-era leftover, currently a silent no-op)
claude-rules.md              # single source of the global CLAUDE.md worktree rules (install syncs it into the managed block)
install.sh                   # one-command install/repair (idempotent/backs up; --dry-run / --cmux)
config/cmux.json             # workflow cmux config (minimalMode + workspace/tab nav keys); applied via install.sh --cmux
test.sh                      # smoke test (gwt-test calls it)
worktree-tasks.tsv           # task registration list (auto-generated)
cc-failures.log              # records of tabs that failed to open (auto-generated)
README.md                    # this file
```

**External files the installer changes** (all backed up): `~/.zshrc`, `~/.claude/settings.json`, `~/.claude/CLAUDE.md`. `cc-trust.sh` edits `~/.claude.json` at runtime (only adds/removes pure-trust-signature entries).

---

## SSH + Zellij fallback channel

On the local box (mini): `zmain` (= `zellij attach -c main`, attach/create the persistent session).
Remote: `ssh <mini-tailscale-host> -t 'zellij attach -c main'`.

Common zellij keys (the bottom of the screen shows live hints):
```
Ctrl+p then n   # new pane (d/r splits down/right)
Ctrl+t then n   # new tab
Ctrl+o then d   # detach (leave the session running on the mini)
Ctrl+g          # lock/unlock keybindings
```
> For flaky networks / phones: `brew install mosh`, then `mosh <mini> -- zellij attach -c main`.

**Notifications**: local/screen-sharing relies on cmux's native per-agent notifications (ring + sidebar + desktop banner); in Zellij it relies on pane/tab indicators + visible agent output.

---

## cmux.json key settings

The workflow cmux config lives in the repo at `config/cmux.json`. `install.sh --cmux` **deep-merges** it into `~/.config/cmux/cmux.json` (backs yours up first, only overrides these keys, keeps everything else). Restart cmux or run `cmux reload-config` afterward. Not applied by default — it's opinionated.

- `app.minimalMode = true`: hide the workspace title bar.
- `shortcuts.bindings` (**Cmd=workspace, Ctrl=tab**): `alt+space` to summon; `cmd+j/k` + `cmd+1‑9` switch **workspaces**; `ctrl+j/k` + `ctrl+1‑9` switch **tabs**.
  - Cost: `Ctrl+j`/`Ctrl+k` are captured by cmux → the terminal loses `Ctrl-J` (newline) / `Ctrl-K` (delete-to-end-of-line).

---

## Rollback

Every changed file has a `*.bak.<timestamp>` backup — just `cp` it back. To temporarily disable a feature: `CC_WT_PRETRUST=0` (no pre-trust), `CC_WT_PERMISSION_MODE=default` (sub-tasks don't enter plan mode).
