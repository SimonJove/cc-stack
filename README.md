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
- [cmux.json key settings](#cmuxjson-key-settings)
- [Rollback](#rollback)

---

## Two channels

| Channel | When | How |
|------|--------|--------|
| **Local main** | sitting at the mac mini | **cmux native teams** (`ccteam` = `cmux claude-teams --teammate-mode in-process`) — teammates/subagents stay in-process: no split panes, no lost completion events; named-pane teammates still available per-launch by appending `--teammate-mode auto` (last flag wins) |
| **Remote live view** | connecting back to the mini from another machine | **screen sharing + Tailscale** — you see the same still-running cmux, all sessions continue as-is |

> Design point: local agent orchestration goes to **cmux**; for terminal-only remote access cmux has its own `cmux ssh` / remotes / iOS client. (A former SSH + Zellij fallback channel was removed — zellij is no longer installed.)

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
4. Add the Claude Code hooks to `~/.claude/settings.json`: the PostToolUse tab hook (opens the tab on `git worktree add`) and the `cc-status-hook.sh` status hook on `UserPromptSubmit`/`Stop`/`Notification` (agent-state tracking; also strips any stale `cc-notify` hooks left by older installs)
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
5. starts a **`ccteam` (team-ready claude)** in the new tab with **`--permission-mode auto`** (prefix `CC_WT_PERMISSION_MODE=plan` on the `git worktree add` to get the plan-first gate instead);
6. sends `CC_WT_PROMPT` as the **first message** (via a temp file, so any length / multi-line works);
7. **registers** the sub-task into the list (queryable via `gwt-status`).

### Sub-task working rules (enforced by CLAUDE.md + the prompt, both)

- **Investigate, then edit**: in auto mode (the default) the sub-task researches first and then implements with **no approval round-trip** — structural/destructive decisions still come back to you; `CC_WT_PERMISSION_MODE=plan` restores the old "present a plan and wait" gate;
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

> Not inside cmux (remote SSH) → everything is a **safe no-op**.

### The task board: `gwt-status`

`gwt-status` renders the sub-task board — one row per registered worktree sub-task:

| Column | Meaning |
|---|---|
| `TAB` | cmux surface liveness: `✔live` / `⌫closed` (ref gone within the same cmux session) / `?old-session` (no registered ref alive → cmux probably restarted) / `?` (cmux unreachable) |
| `BRANCH` | the sub-task's branch |
| `PARENT` | its recorded merge target (`branch.<b>.ccMergeInto`; falls back to the parent branch recorded at dispatch once that config is gone, e.g. branch deleted after merge) |
| `STATUS` | agent state from the hook sidecar (table below) |
| `DIR` / `TASK` | the worktree dir and the dispatch prompt summary |

Row rules: the **newest record per dir wins**; rows whose dir no longer exists are **pruned on read**;
and a **repo filter** shows only rows under the current repo's git root — both sides canonicalized
with `pwd -P`, so macOS's `/var/...` ↔ `/private/var/...` forms never hide a row. `--all` disables
the filter; outside any repo everything shows.

**One board implementation, any shell.** `gwt-status` is THE board command (docs, rules and tests
reference it); under the hood it is a thin wrapper over `cc-board.sh` (bash). Claude's
non-interactive Bash tool cannot run zsh functions, so it calls the implementation entry directly:
`bash ~/.config/cc-stack/cc-board.sh [--all]` (humans keep using `gwt-status`). When `gwt-merge`
lands a branch, its rows move out of the live board into `worktree-tasks-archive.tsv` (with a
merged-at timestamp) — `gwt-log` renders that archive with the same columns and repo filter.

### Sub-task agent status: working / idle / blocked

`gwt-status` shows a **STATUS** column per sub-task. It is driven by Claude Code **hooks**, not by the
model: `install.sh` registers `cc-status-hook.sh` for `UserPromptSubmit` / `Stop` / `Notification`, and
the hook writes a tiny sidecar row (`worktree-status.tsv`, joined on dir) — **zero model cooperation,
zero token cost**. Only dirs already on the task board get rows, so the main session and unrelated
projects never write anything.

| STATUS cell | Written on | Meaning |
|---|---|---|
| `working(23m)` | `UserPromptSubmit` | the sub-task claude just got a message and is on it (age = time since the last event) |
| `idle(2h)` | `Stop` | the agent finished its turn, **not running — NOT done** |
| `blocked(5m)` | `Notification` whose message mentions *permission* | the sub-task is stuck on a permission prompt — answer its tab |
| `-` | (no row) | no hook event recorded yet (sub-task started before the hook was installed, or claude never launched) |

**`idle` ≠ done.** An idle sub-task has simply stopped running; it may be waiting for you, done, or
crashed mid-thought. Readiness to merge still comes **only** from `gwt-done` plus a clean working tree
(what `gwt-tree` shows) — the hook deliberately never writes a "ready" state; that stays a human
decision. State rows are swept along with the board (`gwt-rm` drops the row, `gwt-prune` removes rows
whose dir no longer exists).

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
ccteam                 # = cmux claude-teams --teammate-mode in-process, team-enabled Claude Code, teammates in-process
ccteam --continue      # continue the last session
ccteam --model sonnet  # pick a model
ccteam --teammate-mode auto  # one-off: named teammates get their own split panes again (last flag wins)
```
> Typing `claude`/`cld` inside cmux also auto-launches "team-ready"; subcommands (mcp/config), headless (`-p`), and remote auto-route to native claude. Force native temporarily: `command claude …` or `\claude …`.

### git worktree sub-tasks
```
gwt-claude <name> "<prompt>"   # build worktree + new tab running claude (plan) + send prompt (manual spawn)
gwt-new <name>                 # build worktree and cd into it (opens an empty workspace, no claude)
gwt-adopt <branch> [--into <parent>] [--no-worktree]  # enroll an EXISTING branch into the tree: record its
                               #   merge parent (→ shows in gwt-tree, mergeable via gwt-merge/gwt-collect) and,
                               #   by default, give it a worktree so an agent can start on it. Does not cd or
                               #   steal focus, so an orchestrating claude can fold hand-made branches in.
gwt-ls                         # git worktree list
gwt-status                     # THE board command: TAB liveness + BRANCH + PARENT (merge target) + agent STATUS (working/idle/blocked + age)
                               #   + DIR + TASK; current repo only (--all = every repo); auto-cleans deleted dirs.
                               #   Any-shell implementation entry: bash ~/.config/cc-stack/cc-board.sh [--all]
gwt-log                        # the merged-task archive with the same columns/filter (rows moved there by gwt-merge)
gwt-rm <name> [--branch]       # remove worktree (+ clear task record + clear pre-trust; optionally the branch)
gwt-prune                      # compact the task list (drop dead records + keep newest per dir)
gwt-clean                      # git worktree prune + show current state
gwt-provider <name>            # set AI provider for NEW sub-tasks: kimi|glm|anthropic (team mode either way; existing unchanged); no arg lists current + available
gwt-help                       # command cheatsheet
gwt-test                       # run the smoke test (self-check for regressions after editing cc-stack)
```

- Worktree dir: `<project>/.claude/worktrees/<name>` when the project has `.claude`, otherwise `<project>/.worktrees/<name>` (the base dir is auto-added to `.gitignore`); branch is `feat/<name>`.

---

## Switching provider for new sub-tasks (limited fallback)

When your main provider gets rate-limited mid-session, switch which provider cc-stack uses to start **new** sub-tasks. Already-running sub-tasks keep their launch-time provider (env is process-local), so nothing in flight is disturbed.

```
gwt-provider               # show current provider + available (e.g. glm, kimi, anthropic)
gwt-provider kimi           # NEW sub-tasks now start on the kimi provider
gwt-provider anthropic      # back to default
```

Every sub-task still launches in **team mode** (`cmux claude-teams`) regardless of provider — `gwt-provider` only changes which AI backend answers; kimi / glm / anthropic are identical apart from the provider. This just rewrites `~/.config/cc-stack/launch`; the main session and any already-open sub-task tabs are untouched. For a one-off session on another provider, open a cmux tab and run `cld <provider>` directly.

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `CC_WT_PROMPT` | (none) | The **first message** for the sub-task when creating a worktree; multi-line supported. Without it, an idle ccteam starts. |
| `CC_WT_PERMISSION_MODE` | `auto` | The sub-task claude's `--permission-mode`. Set `plan` for the plan-first approval gate. Also accepted as a **prefix token on the `git worktree add` line** (the hook parses it out of the command text, like `CC_WT_PROMPT` — an env prefix alone never reaches the hook process). Whitelist: `plan` `auto` `acceptEdits` `bypassPermissions` `manual` `dontAsk`; anything else falls back to `auto`. |
| `CC_WT_PRETRUST` | `1` | Whether to pre-trust the worktree dir (skip the trust prompt). Set `0` to disable (falls back to screen-scrape confirmation). |
| `CC_WT_COPY` | `.env .env.local .claude/settings.local.json` | Files copied from the main repo into a new worktree (space-separated, no spaces in paths). |
| `CC_WT_SHARE` | `scratchpad/e2e` | Gitignored dir(s) shared across worktrees as **independent copies**: seeded into a new worktree on create, merged back into the main repo on `gwt-rm` (never overwrites main; clashes kept as `<name>.from-<branch>.<ext>`). Space-separated; **export** it to customize, exported-empty (`""`) disables. |
| `CC_TASKS_FILE` | `~/.config/cc-stack/worktree-tasks.tsv` | Task list path (rarely changed). |
| `CC_STATUS_FILE` | `~/.config/cc-stack/worktree-status.tsv` | Agent-state sidecar written by `cc-status-hook.sh`, read by the board's STATUS column (override for tests). |
| `CC_ARCHIVE_FILE` | `~/.config/cc-stack/worktree-tasks-archive.tsv` | Merged-task archive written on `gwt-merge`, rendered by `gwt-log` / `cc-board.sh --archive` (override for tests). |
| `CC_LAUNCH_FILE` | `~/.config/cc-stack/launch` | Written by `gwt-provider`; the provider name for NEW sub-tasks (`kimi`, `glm`, or `anthropic`/empty=default). Override path for tests. |

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
  │  ④ open tab  ⑤ probe shell-ready  ⑥ start ccteam --permission-mode auto (or CC_WT_PERMISSION_MODE) via temp file + send prompt
  │  ⑦ screen-scrape trust fallback  ⑧ register (cc-tasks-log.sh)   failure → cc-failures.log + cmux notify
  ▼
worktree-tasks.tsv  ──►  cc-board.sh (bash; gwt-status wraps it): joins the sidecar, judges tab liveness
  │                       via cmux, applies the repo filter, auto-prunes deleted dirs
  ▼
gwt-merge (on do-merge success) ──► worktree-tasks-archive.tsv (+merged-at) ──► gwt-log

each sub-task claude's own lifecycle events ──►
cc-status-hook.sh             UserPromptSubmit / Stop / permission-Notification hooks (registered globally,
  │                           but only board dirs ever match): dir + state + ts under a mkdir lock
  ▼
worktree-status.tsv  ──►  the board's STATUS column: working(23m) / idle(2h) / blocked(5m) / -
```

**Key design choices:**
- **Single source of truth**: the whole tab-opening logic lives only in `cc-cmux-surface-claude.sh`; both the hook and `gwt-claude` call it, so the logic can't drift into two copies.
- **One board implementation**: all board rendering lives in `cc-board.sh` (plain bash, so it runs from any shell — Claude's non-interactive Bash included); `gwt-status` / `gwt-log` are thin wrappers over it.
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
| **Sub-task stuck on `blocked(...)`** | It's waiting on a permission prompt in its tab — go answer there; the state refreshes on the sub-task's next event. |
| **Sub-task can't run without `.env`** | Ensure `$CC_WT_COPY` includes the needed files; the hook path now copies them automatically. **Port collisions** between parallel dev servers must be handled by parameterizing ports in each worktree's `.env`. |
| **Afraid of breaking cc-stack when editing it** | `gwt-test` runs the smoke test (hook parsing / registration / prune / trust) in one command. |

---

## File list

```
worktree.zsh                 # gwt-* functions (sourced by .zshrc)
aliases.zsh                  # ccteam / gwt-test / claude router (sourced by .zshrc)
cc-claude                    # claude/cld launch router (in cmux → team-ready, remote/subcommands → native)
cc-worktree-cmux-hook.sh     # PostToolUse(Bash) hook: git worktree add → call the surface script
cc-cmux-surface-claude.sh    # [single source of truth] open tab + copy .env + pre-trust + start ccteam(plan) + send prompt + register (with retries/failure breadcrumb)
cc-worktree-claude.sh        # gwt-claude: build worktree + ensure .gitignore, delegates the surface part above
cc-cmux-workspace.sh         # used by gwt-new: open an empty workspace for a dir (no-op when not in cmux)
cc-tasks-log.sh              # single task-registration entry point (keeps TSV format consistent)
cc-board.sh                  # [the board] renders gwt-status/gwt-log from any shell (bash): tasks+status join, repo filter, tab liveness, prune-on-read
cc-status-hook.sh            # UserPromptSubmit/Stop/Notification hook: sub-task agent state (working/idle/blocked) → worktree-status.tsv
cc-trust.sh                  # pre-authorize/revoke trust for a dir (edits ~/.claude.json, atomic write, only adds/removes pure-trust signatures)
claude-rules.md              # single source of the global CLAUDE.md worktree rules (install syncs it into the managed block)
install.sh                   # one-command install/repair (idempotent/backs up; --dry-run / --cmux)
config/cmux.json             # workflow cmux config (minimalMode + workspace/tab nav keys); applied via install.sh --cmux
test.sh                      # smoke test (gwt-test calls it)
worktree-tasks.tsv           # task registration list (auto-generated)
worktree-tasks-archive.tsv   # merged sub-task rows, moved on gwt-merge (auto-generated; rendered by gwt-log)
worktree-status.tsv          # per-sub-task agent state, written by cc-status-hook.sh (auto-generated)
cc-failures.log              # records of tabs that failed to open (auto-generated)
README.md                    # this file
```

**External files the installer changes** (all backed up): `~/.zshrc`, `~/.claude/settings.json`, `~/.claude/CLAUDE.md`. `cc-trust.sh` edits `~/.claude.json` at runtime (only adds/removes pure-trust-signature entries).

---

## cmux.json key settings

The workflow cmux config lives in the repo at `config/cmux.json`. `install.sh --cmux` **deep-merges** it into `~/.config/cmux/cmux.json` (backs yours up first, only overrides these keys, keeps everything else). Restart cmux or run `cmux reload-config` afterward. Not applied by default — it's opinionated.

- `app.minimalMode = true`: hide the workspace title bar.
- `shortcuts.bindings` (**Cmd=workspace, Ctrl=tab**): `alt+space` to summon; `cmd+j/k` + `cmd+1‑9` switch **workspaces**; `ctrl+j/k` + `ctrl+1‑9` switch **tabs**.
  - Cost: `Ctrl+j`/`Ctrl+k` are captured by cmux → the terminal loses `Ctrl-J` (newline) / `Ctrl-K` (delete-to-end-of-line).

---

## Rollback

Every changed file has a `*.bak.<timestamp>` backup — just `cp` it back. To temporarily disable a feature: `CC_WT_PRETRUST=0` (no pre-trust), `CC_WT_PERMISSION_MODE=default` (sub-tasks don't enter plan mode).
