# cc-stack — cmux + Claude Code + git worktree parallel dev stack

A workflow for developing projects with **Claude Code** inside the **cmux** terminal. The core capability: **let the main Claude spin any task off into an isolated worktree sub-task with one sentence — it opens a new tab, starts a parallel claude in it, and (in plan mode) presents a plan for your approval before editing code**, while you (the main session) stay put and keep working.

Around that: a task board (`gwt-status`), lifecycle management (`gwt-*`), a one-command installer (`install.sh`), and remote/low-bandwidth fallback channels.

---

## Contents
- [Two channels](#two-channels)
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

### What the installer does (7 idempotent steps)
1. Install the source into the target dir (excluding `.git`/backups/runtime-generated files)
2. Executable bits + dependency check (cmux / claude / git / python3 / zsh / shasum / column)
3. Make `~/.zshrc` load `worktree.zsh` + `aliases.zsh`
4. Add the Claude Code hooks to `~/.claude/settings.json`: the PostToolUse tab hook (opens the tab on `git worktree add`) and the `cc-hooks.sh status` hook on `UserPromptSubmit`/`Stop`/`Notification` (agent-state tracking; also strips any stale hook registrations left by older installs — `cc-notify`, `cc-worktree-cmux-hook.sh`, and the two retired PreToolUse text gates `block-unsafe-close.sh` / `block-worktree-commit.sh`, whose files are deleted from the install dir too). **Nothing is registered on PreToolUse any more.**
4b. Mount the **commit gate** (`hooks/git-pre-commit.sh` → `.git/hooks/pre-commit`) on the install dir and, when different, the clone you ran the installer from. Every other repo gets it automatically the first time cc-stack opens a tab for a worktree in it
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
CC_WT_PROMPT='the full first instruction for the task (may be multi-line)' git worktree add .claude/worktrees/<name> -b feat/<name> <base>
```

### What happens

1. The **PostToolUse hook** detects this `git worktree add` and parses out the new directory;
2. opens a **new tab in the current cmux workspace** (background, no focus steal), cwd = the worktree;
3. **copies** the main repo's `.env` etc. (`$CC_WT_COPY`) into the worktree;
4. **pre-trusts** the directory (skips claude's "Do you trust this folder?" prompt);
5. starts a **`ccteam` (team-ready claude)** in the new tab with **`--permission-mode auto`** (prefix `CC_WT_PERMISSION_MODE=plan` on the `git worktree add` to get the plan-first gate instead) and a **caller-minted `--session-id <uuid>`** (recorded so `gwt-resume` can resume this exact session later);
6. sends `CC_WT_PROMPT` as the **first message** (via a temp file, so any length / multi-line works);
7. **registers** the sub-task into the list (queryable via `gwt-status`), including a compact **launch-args** record (session uuid + provider + permission-mode + optional model) that `gwt-resume` replays after a crash.

### Sub-task working rules (enforced by CLAUDE.md + the prompt, both)

- **Investigate, then edit**: in auto mode (the default) the sub-task researches first and then implements with **no approval round-trip** — structural/destructive decisions still come back to you; `CC_WT_PERMISSION_MODE=plan` restores the old "present a plan and wait" gate;
- **Respect the project harness**: works per the **sub-task's own project** `CLAUDE.md`/`.claude`, no going rogue;
- **Don't land changes**: `commit` / `rebase` / `merge` / `push` / remove worktree / delete branch **all require your authorization**, defaulting to "keep the branch";
- **Backchannel**: the sub-task reports back via `cc-dispatch.sh send <caller-surface> "<message>"` (the cc-send primitive — it waits out any half-typed line in the target tab instead of colliding with it; raw `cmux send` + Enter is never used).
- **cc-send can legitimately wait minutes**: a held message re-notifies on a heartbeat (`CC_SEND_HEARTBEAT_SEC`, default 300s) and sends the moment the line clears — when calling it from a claude Bash tool use, run it with `run_in_background` or raise `CC_SEND_TIMEOUT`; a killed loop loses the message (no queue, no persistence).

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
model: `install.sh` registers `cc-hooks.sh status` for `UserPromptSubmit` / `Stop` / `Notification`, and
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

### After a cmux crash/restart: `gwt-resume`

When cmux dies and comes back, sub-task tabs are gone but their worktrees, branches and board rows
survive. `gwt-resume [--all]` rebuilds the tabs — **same sessions, same providers, same dirs**:

1. **cmux native restore first** (`cmux restore-session`) — fail-soft: nothing to restore just
   continues to the next step;
2. board rows whose tab is already back get their **surface refs refreshed** (matched by the
   recorded session uuid against cmux's agent session store, canonical-cwd fallback) and their
   stale agent-state rows cleared;
3. rows still without a tab are **re-opened replaying the recorded launch args**:
   `cld <provider> --resume <uuid> --permission-mode <pm> [--model <m>]` (plain rows resume
   without `cld`; flags that weren't recorded are omitted), launched in the **recorded dir
   verbatim** — claude keys project identity/trust/CLAUDE.md on the exact path string, so the
   path is never re-resolved from repo/branch;
4. rows from before this feature (no recorded session) **degrade to an idle ccteam tab** —
   listed as such, never silently skipped.

It lists `BRANCH | summary | dir | disposition` first and asks **one y/N** (only the re-opens;
declining leaves native restores standing). `--all` skips the confirm **and** the repo filter.
Known gap, shown as a ⚠ on affected rows: native restore is **provider-blind** — a kimi/glm tab
that cmux itself brought back runs with the default provider env; close that tab and re-run
`gwt-resume` to reopen it with the recorded provider.

---

## Hierarchical worktrees (A ⊃ {A1,A2,A3})

When a sub-task claude spins off its own worktrees, cc-stack records each
child's merge target automatically (`git config branch.<b>.ccMergeInto`).
An explicitly named base branch — `gwt-claude … --base <b>`, `gwt-new`'s base
argument, the base on a hook-path `git worktree add <path> <base>` — IS that
target; only without one does the caller's own branch stand in. Name it:
once a sibling fast-forwards into the campaign branch the two are the same
commit, and the caller's branch can no longer tell them apart. You then drive
the merges back up the tree — each stops at a confirmation gate.

    gwt-tree                 # see the whole tree: A ⊃ {A1,A2,A3}, ready state, tabs
    gwt-done                 # (run inside A1) mark A1 ready when it's finished
    gwt-merge A1             # gated merge A1 → feat/A (asks strategy [default: squash] + confirmation;
                             #   --message <text> overrides the merge commit message)
    gwt-collect A            # merge every ready child of A into A, one gate each
    gwt-merge A              # finally merge A → main (its recorded/def target)

`gwt-merge` never merges without an explicit `y`. Readiness = clean working
tree **and** `gwt-done`; otherwise it warns and needs `--force`. Cleanup
(`gwt-rm`) stays a separate, explicit step.

Merge commits default to a Conventional-Commits-safe message
(`chore: merge <child> into <target>`, plus a `Child-Tip: <sha>` trailer on squash so the
retired child ref stays verifiable) — override per call with `--message` or repo-wide with
`CC_MERGE_MESSAGE` (some repos cap the subject at 72 chars). Failures are triaged, never
lumped as "conflict": a real content conflict aborts and reports `conflict:`, while a commit
refused by a hook reports `commit-rejected:` with the hook's output and **preserves the staged
merge** in the target worktree so you can finish it by hand; `--rebase` rebases inside the
child's own worktree (refusing cleanly only while that tree is dirty).

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
gwt-resume [--all]             # after a cmux crash/restart: native restore first, then re-open still-missing sub-task tabs
                               #   replaying the RECORDED session uuid + provider + permission-mode (+ model) in the recorded
                               #   dir verbatim; lists first + asks y/N (--all = every repo, no confirm); rows without a
                               #   recorded session degrade to an idle ccteam tab (visible)
gwt-rm <name> [--branch] [--close] [--force]
                               # remove worktree (+ clear task record + clear pre-trust; --close also closes its tab)
                               # --branch deletes the branch ONLY when it merged into its recorded target
                               #   (ancestry, or the Child-Tip trailer a squash leaves); otherwise it is kept
                               # a dirty or locked worktree is REFUSED and nothing is cleaned; --force is the
                               #   single destructive switch and covers the working tree and the branch alike
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
| `CC_WT_PROMPT` | (none) | The **first message** for the sub-task when creating a worktree; multi-line supported. **It is what turns a `git worktree add` into a dispatch**: without it the hook opens no tab at all and skips silently (`gwt-claude` / `gwt-resume` still open tabs on their own). |
| `CC_WT_PERMISSION_MODE` | `auto` | The sub-task claude's `--permission-mode`. Set `plan` for the plan-first approval gate. Also accepted as a **prefix token on the `git worktree add` line** (the hook parses it out of the command text, like `CC_WT_PROMPT` — an env prefix alone never reaches the hook process). Whitelist: `plan` `auto` `acceptEdits` `bypassPermissions` `manual` `dontAsk`; anything else falls back to `auto`. |
| `CC_WT_PRETRUST` | `1` | Whether to pre-trust the worktree dir (skip the trust prompt). Set `0` to disable (falls back to screen-scrape confirmation). |
| `CC_WT_COPY` | `.env .env.local .claude/settings.local.json` | Files copied from the main repo into a new worktree (space-separated, no spaces in paths). |
| `CC_WT_SHARE` | `scratchpad/e2e` | Gitignored dir(s) shared across worktrees as **independent copies**: seeded into a new worktree on create, merged back into the main repo on `gwt-rm` (never overwrites main; clashes kept as `<name>.from-<branch>.<ext>`). Space-separated; **export** it to customize, exported-empty (`""`) disables. |
| `CC_WT_MODEL` | (none) | Optional `--model` pin for a sub-task launch; recorded in the row's launch-args and replayed by `gwt-resume`. Charset-whitelisted (letters/digits/`.`/`_`/`-`/`[`/`]`); anything else is dropped, never interpolated into the typed command. |
| `CC_CMUX_SESSIONS` | `~/.cmuxterm/claude-hook-sessions.json` | cmux agent session store read by `gwt-resume` to match restored tabs (session id → surface + cwd). Override for tests. |
| `CC_RESUME_SETTLE` | `2` | Seconds `gwt-resume` waits after `cmux restore-session` for restored surfaces to register (0 in tests). |
| `CC_TASKS_FILE` | `~/.config/cc-stack/worktree-tasks.tsv` | Task list path (rarely changed). |
| `CC_TABS_FILE` | `~/.config/cc-stack/opened-tabs.tsv` | Opened-tabs ledger: every tab this stack opened (surface uuid, owner surface uuid, dir, session uuid, ts). Written by `cc-dispatch.sh surface`/`workspace`, read by `close` / `tabs` (override for tests). |
| `CC_STATUS_FILE` | `~/.config/cc-stack/worktree-status.tsv` | Agent-state sidecar written by `cc-hooks.sh status`, read by the board's STATUS column (override for tests). |
| `CC_ARCHIVE_FILE` | `~/.config/cc-stack/worktree-tasks-archive.tsv` | Merged-task archive written on `gwt-merge`, rendered by `gwt-log` / `cc-board.sh --archive` (override for tests). |
| `CC_LAUNCH_FILE` | `~/.config/cc-stack/launch` | Written by `gwt-provider`; the provider name for NEW sub-tasks (`kimi`, `glm`, or `anthropic`/empty=default). Override path for tests. |
| `CC_MERGE_MESSAGE` | (conventional default) | Merge commit message for `gwt-merge` / `do-merge` (`--message` flag wins over this over the `chore: merge <child> into <target>` default — use it in repos that cap the subject, e.g. at 72 chars). |

---

## Architecture & data flow

```
Main Claude: "open a worktree"
  │  (Bash: CC_WT_PROMPT=... git worktree add ...)
  ▼
cc-hooks.sh worktree            PostToolUse(Bash) hook: dispatch only when intent AND target are unambiguous —
  │                             a non-empty CC_WT_PROMPT, and a path parsed out of the command (cross-repo -C aware)
  │                             that pins to a real linked worktree. No prompt → silent skip; unpinnable path (an
  │                             unexpanded $VAR) → no tab + one cc-failures.log line, never a guess at another dir.
  │                             Only triggers on a real `git worktree add`; list/remove/EnterWorktree do not.
  ▼
cc-dispatch.sh surface  ◀────── single source of truth ──────  cc-dispatch.sh wt-claude (gwt-claude: builds worktree then exec-delegates)
  │  ① ping/new-surface short retry (rides out cmux hiccups)  ② copy .env  ③ pre-trust (cc-trust.sh)
  │  ④ open tab → register immediately (cc-state task-add; the board shows the tab from the moment it exists)
  │  ⑤ probe shell-ready  ⑥ start ccteam --session-id <minted-uuid> --permission-mode auto (or CC_WT_PERMISSION_MODE) via temp file + send prompt
  │  ⑦ screen-scrape trust fallback  ⑧ complete the row (cc-state task-set-launch: caller-ref + launch-args)   failure → cc-failures.log + cmux notify
  ▼
worktree-tasks.tsv  ──►  cc-state (python3): the ONLY reader/writer of stack state — newest-per-dir,
  │                       the repo filter, the dead-dir sweep and the sidecar join, one call each
  ▼
cc-board.sh (bash; gwt-status wraps it): renders, and judges tab liveness via cmux — nothing else
  ▼
gwt-merge (on do-merge success) ──► worktree-tasks-archive.tsv (+merged-at) ──► gwt-log

each sub-task claude's own lifecycle events ──►
cc-hooks.sh status             UserPromptSubmit / Stop / permission-Notification hooks (registered globally,
  │                           but only board dirs ever match). Parses the event, canonicalizes cwd, and
  │                           hands the write to cc-state — membership, locking and the rewrite are its job.
  │                           A cheap board-file check runs BEFORE the parse: no board, no python at all.
  ▼
worktree-status.tsv  ──►  the board's STATUS column: working(23m) / idle(2h) / blocked(5m) / -

after a cmux restart: gwt-resume (worktree.zsh) ──► cc-dispatch.sh resume
  │  ① cmux restore-session (native, fail-soft)  ② refreshed surface refs for tabs that came back
  │     (recorded uuid ─► ~/.cmuxterm/claude-hook-sessions.json ─► live surface UUID ─► short ref)
  │  ③ still-missing rows re-opened via surface (CC_WT_LAUNCH_CMD) replaying the recorded args
  │     in the recorded dir VERBATIM  ④ stale sidecar rows cleared for revived dirs

opening a tab ──► opened-tabs.tsv   surface-uuid | owner-surface-uuid | dir | session-uuid | ts
  │                                 EVERY tab this stack opens (sub-task or plain helper tab);
  │                                 pruned lazily when a surface stops resolving.
  ▼                                 `cc-dispatch.sh tabs` / `gwt-tabs` = the live inventory
closing tabs: cc-dispatch.sh close <dir>   ① dir → stable surface uuid: board suuid, then
              gwt-rm <name> --close          opened-tabs by dir (survives gwt-rm), then the cmux
                                             session store  ② print the resolution  ③ policy:
                                             never self; a non-worktree dir only when THIS session
                                             opened it; a live sub-task only by its dispatching
                                             parent, or by anyone once gwt-done marked it ready
                                             (automated callers — decided by process ancestry;
                                             a human shell reports instead of refusing)
                                          ④ close by the STABLE uuid, never a short ref
```

**Key design choices:**
- **Single source of truth**: the whole tab-opening logic lives only in `cc-dispatch.sh surface`; both the hook (`cc-hooks.sh worktree`) and `gwt-claude` (`cc-dispatch.sh wt-claude`) call it, so the logic can't drift into two copies.
- **One board implementation**: all board rendering lives in `cc-board.sh` (plain bash, so it runs from any shell — Claude's non-interactive Bash included); `gwt-status` / `gwt-log` are thin wrappers over it.
- **Prompt via file**: `ccteam "$(cat tempfile)"` — the command is short (a very long line would be shredded), and the shell passes the whole file (newlines and all) to claude as a single argument (multi-line preserved).
- **Reliability**: short retries during cmux hiccups; a hard failure leaves `cc-failures.log` (surfaced by `gwt-status`).
- **Reliable status**: `gwt-status` judges tab liveness against cmux's live surface list; after a cmux restart, stale refs show `?old-session` rather than falsely "closed".
- **Recorded-args resume**: dispatch mints the claude `--session-id` and records the full launch args on the board row, so `gwt-resume` replays exactly what was launched (provider env included — the thing cmux's own restore loses). The resume always launches in the **recorded dir string verbatim**: claude keys project identity on the exact path, so `/Users` vs `/private` is a different project.
- **Close permission model — ledgers + sanctioned paths, no interception layer**: tab identity is always a stable surface UUID, never a drifting short ref. Two ledgers answer two different questions and are never deduped: the board (`csuuid`/`suuid` inside launch-args) answers *whose sub-task is this*, `opened-tabs.tsv` answers *who opened this tab* — which is what makes a plain helper tab (a runner in the primary checkout, a scratch dir) closable by the session that opened it, and what keeps a close working after `gwt-rm` dropped the board row. `cc-dispatch.sh close <dir>` and `gwt-rm --close` are the sanctioned paths: they resolve, print the resolution, then enforce the policy (never self; a live sub-task only by its dispatching parent — ancestry-decided, not env-decidable — or by anyone once `gwt-done` marked the branch ready; parent/primary-checkout tabs stay the human's in the cmux UI). The 2026-08-16 PreToolUse text-parsing gate over every Bash command was **retired**: a parser that must decide whether prose quoting `cmux close-surface` is a command kept blocking real dispatch briefs, and could never see an alias or a script file anyway. The rules now live in `claude-rules.md` (installed into `~/.claude/CLAUDE.md`) plus these ledgers.
- **Commit gate — enforced where git enforces it, not by reading command text**: "a worktree sub-task may not commit without the human" is a git `pre-commit` hook (`hooks/git-pre-commit.sh`), mounted once per repo into the shared `.git/hooks`. It replaced a PreToolUse hook that had to guess a commit's target directory out of the Bash command **text** — the same parser class as the retired close gate, and it failed both ways on 2026-08-16: it blocked two commands that were writing files while merely *quoting* `git … commit`, and it waved through a real `git -C "$W" commit` because `$W` reached the hook unexpanded, was not a directory, and the fallback landed on the primary checkout. A git hook has neither problem — it never sees command text, and it runs with cwd already inside the worktree that is actually committing, whatever syntax got git there. Grant with `touch <worktree>/.commit-authorized` (consumed on use: one grant, one commit). Coexistence is the hard constraint: `core.hooksPath` is never set (it silently replaces a project's *entire* hook set, `commit-msg` included) and a repo that already uses one is refused rather than half-gated; an existing `pre-commit` is preserved as `pre-commit.cc-stack-orig` and `exec`'d once the gate passes. `--no-verify` bypasses it — deliberately, exactly as every bypass of the old version did. This gate stops a slip of the hand and a skill acting on its own initiative; it is not a security boundary.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| **Worktree built but no tab opened** | Usually **missing `CC_WT_PROMPT`** — the hook only opens a tab when this env var is set. Redo via `gwt-claude <name> "<prompt>" --base <base>` (it sets `CC_WT_PROMPT` automatically; `--base` names the merge target). Otherwise cmux was restarting / transiently unstable: it retries; a hard failure logs to `cc-failures.log` (`gwt-status` warns at the top). |
| **Main Claude "does it in the background", no tab** | It used `EnterWorktree` instead of Bash `git worktree add`. Make sure the global `CLAUDE.md` rules block is present (`install.sh` installs it) and it's a **newly started session** (CLAUDE.md is read at session start). |
| **Sub-task edits code right away** | Not in plan mode. Check `CC_WT_PERMISSION_MODE` isn't set to a non-plan value; only newly spawned sub-tasks pick it up. |
| **Sub-task auto-merges / removes the worktree** | The superpowers `finishing-a-development-branch` skill picked "merge" by itself in an autonomous sub-task. The CLAUDE.md rules forbid this; make sure the rules block is present and it's a new session. |
| **`gwt-status` shows all `?old-session`** | cmux was restarted, all registered surface refs are stale. Run **`gwt-resume`** to bring the tabs back (same sessions/providers); dirs still exist meanwhile, cleanup is unaffected; `gwt-prune` compacts it. |
| **Sub-task stuck on `blocked(...)`** | It's waiting on a permission prompt in its tab — go answer there; the state refreshes on the sub-task's next event. |
| **Sub-task can't run without `.env`** | Ensure `$CC_WT_COPY` includes the needed files; the hook path now copies them automatically. **Port collisions** between parallel dev servers must be handled by parameterizing ports in each worktree's `.env`. |
| **Afraid of breaking cc-stack when editing it** | `gwt-test` runs the smoke test (hook parsing / registration / prune / trust) in one command. |
| **Edited `claude-rules.md` / `hooks/`, but sessions still behave the old way** | The runtime copies under `~/.claude/` migrate only when you **re-run `install.sh`** — by hand, after such a change lands. The main checkout IS the install dir, so behavior flips the moment the change merges into the campaign branch, not at `main`; and only newly started sessions re-read `CLAUDE.md`. |

---

## File list

```
worktree.zsh                 # gwt-* functions (sourced by .zshrc)
aliases.zsh                  # ccteam / gwt-test / claude router (sourced by .zshrc)
cc-claude                    # claude/cld launch router (in cmux → team-ready, remote/subcommands → native)
cc-hooks.sh                  # ALL Claude Code hook entries: worktree (PostToolUse tab opener) + status (agent-state sidecar writer)
cc-dispatch.sh               # the dispatch pipeline: wt-claude (gwt-claude) | surface ([single source of truth] open tab + copy .env + pre-trust + start ccteam + send prompt + register, with retries/failure breadcrumb) | send (cc-send: the collision-safe text+Enter primitive, the only sanctioned injection exit into a running claude tab) | calibrate (re-probe the cc-send patterns on a known-empty tab) | close (THE sanctioned tab close: dir → recorded stable surface uuid → policy → close) | tabs (the opened-tabs inventory, backs gwt-tabs) | resume (gwt-resume engine: native restore + recorded-args reopen) | workspace (empty workspace for a dir, used by gwt-new) | commit-gate mount|unmount (THE commit gate: install/remove git's own pre-commit hook on a repo)
cc-board.sh                  # [the board] renders gwt-status/gwt-log from any shell (bash): tasks+status join, repo filter, tab liveness, prune-on-read; `log` subcommand = single task-registration write point
cc-merge.sh                  # branch tree: set/get-parent, preflight, do-merge (squash/no-ff/rebase, conventional message + triaged failures), capture, tree (backs gwt-merge/gwt-collect/gwt-tree)
cc-worktree-shared.sh        # shared test corpus (CC_WT_SHARE): seed into a new worktree, collect back on merge
cc-trust.sh                  # pre-authorize/revoke trust for a dir (edits ~/.claude.json, atomic write, only adds/removes pure-trust signatures)
hooks/git-pre-commit.sh      # THE commit gate: git's own pre-commit hook. Mounted per REPO into .git/hooks (shared by every linked worktree) by cc-dispatch.sh surface/workspace and by install.sh step 4b. Blocks a commit made inside .claude/worktrees/ or .worktrees/ unless the parent granted it (touch <worktree>/.commit-authorized — one grant, one commit, consumed on use); the primary checkout is untouched. A pre-commit that was already there is preserved as pre-commit.cc-stack-orig and still runs; core.hooksPath is never set (it would silently disable the project's own hooks) and a repo that uses one is refused, loudly. `cc-dispatch.sh commit-gate unmount <dir>` reverses it. `--no-verify` bypasses it by design — this stops a slip, it is not a security boundary
claude-rules.md              # single source of the global CLAUDE.md worktree rules (install syncs it into the managed block)
install.sh                   # one-command install/repair (idempotent/backs up; --dry-run / --cmux)
config/cmux.json             # workflow cmux config (minimalMode + workspace/tab nav keys); applied via install.sh --cmux
test.sh                      # smoke test (gwt-test calls it)
gwt-done                     # standalone `gwt-done` (bash, no zsh): mark this worktree's branch ready — the form sub-tasks are taught (a zsh function does not exist in their non-interactive shell)
opened-tabs.tsv              # opened-tabs ledger: every tab this stack opened (auto-generated; who opened what, pruned when a surface stops resolving)
worktree-tasks.tsv           # task registration list (auto-generated; 8th field = launch-args recorded at dispatch, replayed by gwt-resume)
worktree-tasks-archive.tsv   # merged sub-task rows, moved on gwt-merge (auto-generated; rendered by gwt-log)
worktree-status.tsv          # per-sub-task agent state, written by cc-hooks.sh status (auto-generated)
cc-failures.log              # records of tabs that failed to open (auto-generated)
README.md                    # this file
```

**External files the installer changes** (all backed up): `~/.zshrc`, `~/.claude/settings.json`, `~/.claude/CLAUDE.md`, plus `.git/hooks/pre-commit` in the install dir / source clone (step 4b — an existing hook is preserved next to it as `pre-commit.cc-stack-orig`, never overwritten). `cc-trust.sh` edits `~/.claude.json` at runtime (only adds/removes pure-trust-signature entries); `cc-dispatch.sh` writes the same `.git/hooks/pre-commit` into any repo it opens a worktree tab for.

---

## cmux.json key settings

The workflow cmux config lives in the repo at `config/cmux.json`. `install.sh --cmux` **deep-merges** it into `~/.config/cmux/cmux.json` (backs yours up first, only overrides these keys, keeps everything else). Restart cmux or run `cmux reload-config` afterward. Not applied by default — it's opinionated.

- `app.minimalMode = true`: hide the workspace title bar.
- `shortcuts.bindings` (**Cmd=workspace, Ctrl=tab**): `alt+space` to summon; `cmd+j/k` + `cmd+1‑9` switch **workspaces**; `ctrl+j/k` + `ctrl+1‑9` switch **tabs**.
  - Cost: `Ctrl+j`/`Ctrl+k` are captured by cmux → the terminal loses `Ctrl-J` (newline) / `Ctrl-K` (delete-to-end-of-line).

---

## Rollback

Every changed file has a `*.bak.<timestamp>` backup — just `cp` it back. To temporarily disable a feature: `CC_WT_PRETRUST=0` (no pre-trust), `CC_WT_PERMISSION_MODE=default` (sub-tasks don't enter plan mode).
