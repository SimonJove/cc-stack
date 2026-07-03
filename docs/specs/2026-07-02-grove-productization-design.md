# cc-stack → grove · Productization Design

**Date:** 2026-07-02
**Status:** Approved (design), pending implementation plan
**Working name:** **grove** (a grove = a stand of trees → a stand of worktrees; also `grove.toml`). Name is changeable; used throughout for a stable referent.
**Scope:** Turn the cc-stack shell toolkit (Claude Code + cmux + git worktree) into a publishable, single-binary Go TUI whose signature capability is **human-gated hierarchical merge** of parallel Claude Code agents. This spec covers product positioning, the target architecture, and the seven feature decisions worked through in the design session. Build sequencing is deferred to the implementation plan.

---

## 1. Positioning (locked)

| Dimension | Decision | Consequence |
|---|---|---|
| **Ambition** | Personal tool, hardened, then published (lazygit-style OSS). **Not** commercial/cloud/team. | Optimize for a great single-user experience + easy install; don't build multi-tenant/billing/cloud. |
| **Agent scope** | **Claude Code only**, deep integration (hooks / plan mode / `.worktreeinclude`). Not multi-agent. | Narrow audience, maximal differentiation. We can ride Claude-Code-specific mechanisms that generic tools can't. |
| **Form factor** | **Go single binary + TUI** (bubbletea/lipgloss), lazygit interaction model. | Install = one binary. Claude interaction goes over the official `claude` CLI, so Go (not the TS SDK) is fine. |

**One-line positioning:** *"lazygit for parallel Claude Code worktrees — the only one that merges them back in human-gated, dependency-ordered layers."*

## 2. Differentiation thesis — structured convergence (anti-homogenization)

Every competitor does **flat parallelism**: N agents → N branches → review each → merge each into main independently (claude-squad, ccmanager, Conductor, Cursor). None does **hierarchical** merge.

grove's single bet is **structured convergence**: agents form a dependency **tree** (feature → sub-features), and the human collapses the tree **bottom-up** through one gated merge per edge. This operationalizes the research finding that for senior engineers the real cost is *coordination/integration*, not generation. Everything else in the design serves this.

### Competitive context (2026-mid, from research)
- **claude-squad** (Go TUI, tmux+worktree, ~8k★): the closest architectural analog. Flat manual merge (diff tab + single-key commit/push). No plan gate, no backchannel, no tree.
- **ccmanager** (TS TUI, 8 agents, ~1.2k★, active): in-app worktree create/merge/delete, **single-layer** merge.
- **Conductor** (Mac GUI, Melty Labs, ~$22M A-round, active): strong diff reviewer + PR flow, worktree-per-workspace, flat.
- **Sculptor** (Imbue, container-per-agent, research preview): "Pairing Mode" bidirectional sync + auto conflict flagging.
- **Claude Code Agent Teams** (experimental, flag-gated): lead+teammates, file-locked shared task list + mailbox, plan approval is **agent-approves-agent**, **no worktree isolation, no merge workflow**.
- **Cursor**: native worktree-per-task, `.cursor/worktrees.json` setup scripts (forward `.env` seed), human review, flat.
- **Shutdowns**: Terragon (2026-02-09, open-sourced), Crystal (2026-02, → paid Nimbalyst), Vibe Kanban parent Bloop (2026-04). The space is crowded (~120 tools) and churning — reinforces betting on a defensible niche, not breadth.

**Nobody does human-gated hierarchical merge, and nobody does backward corpus collect.** Those are the two moats.

## 3. Signature UX — the merge tree is the home screen

The main view is **not** a session list (that is the homogenized claude-squad/ccmanager design); it is an **interactive `gwt-tree`**:

```
main
├─ feat/auth              ↑3   ⚠ 2 children not ready
│  ├─ feat/auth-oauth     ✓ready   ✔live      → [⏎ merge]
│  └─ feat/auth-session   ●dirty   ✔live      → [→ attach]
└─ feat/ui                ↑1   ✓ready   ✔live  → [⏎ merge]

[⏎] gated merge   [→] attach live agent   [c] collect ready children   [d] diff vs target   [a] approve plan
```

- Navigate the tree; **Enter a node = attach into that agent's live PTY session** (take over the conversation).
- On a ready node, one key opens the **gated-merge flow**: inline preflight (clean? conflicts? children ready?) → strategy pick → human confirm.
- `collect` on a parent = merge every ready child up, one gated step each.
- Right panel = live **diff of the selected node vs its merge target** (see §7).
- Node lamps reflect agent state fed by official hooks (§8): ⏸ plan-pending, ●dirty, ✓ready, ⚠ blocked, ✔live/⌫closed.

## 4. Architecture (locked)

- **Embedded PTY (target architecture).** The Go process spawns each `claude` as a child, **owns its PTY**, and renders sessions in TUI panes. No external multiplexer in the endgame — cmux and tmux are both gone.
- **`Backend` interface seam, left unbuilt.** A thin session-backend interface exists so a future tmux/cmux backend *could* be plugged in, but **we do not implement one** (YAGNI). Default and only backend at ship: embedded PTY.
- **Interactive PTY, not headless.** Because "human attaches and takes over the agent" is the product's spine, sessions are real interactive `claude` PTYs — not `-p --output-format stream-json` headless. Structured signals come from hooks (§8), not from parsing a headless stream.
- **State: SQLite**, owned by the orchestrator. Holds the tree (parent/child, merge target, ready state) and per-agent task metadata. Replaces the volatile `worktree-tasks.tsv`. (Durable branch facts like merge-target may still live in `git config` per the existing hierarchical-merge design; SQLite is the runtime/UI store.)
- **Stack:** Go + bubbletea/lipgloss (TUI), git via shell-out (not go-git), a PTY lib (e.g. `creack/pty`), embedded SQLite.

## 5. Plan-first = a real hard gate (locked; mechanism verified)

The human approves each agent's plan in grove's TUI, and the agent **cannot edit** until approved. Built on **official, documented Claude Code hooks** (durable — unlike the trust-json hack being cut). Verified against the hooks reference:

- **Mechanism:** a **`PermissionRequest`** hook (fires "when a permission dialog appears" — covers both plan approval and edit/tool permission), complemented by a **`PreToolUse` match on `ExitPlanMode`** to capture the plan markdown for display.
- **Block-until-approval is viable.** Command-hook timeout defaults to **600s**, configurable higher (`timeout: 3600`, no documented max). The hook **synchronously blocks**: writes "⏸ plan-pending" + captured plan into SQLite, the TUI lamps the node and shows the plan in the right panel, the hook polls for the TUI's approval marker, then returns **allow/deny** (`hookSpecificOutput.permissionDecision` for PreToolUse; `hookSpecificOutput.decision.behavior` allow/deny for PermissionRequest).
- **Why this beats the old design:** one hook gates both "approve plan" and "approve edit"; no screen-scraping, no honor-system, no reliance on plan-mode being correctly engaged.
- **Minimal-first (per YAGNI):** ship the single synchronous gate; only add a belt-and-suspenders `PreToolUse` deny-on-`Edit|Write|MultiEdit` backstop if the primary gate proves leaky.

**Spike before implementing (§11.1):** confirm the exact field carrying the plan markdown in the `ExitPlanMode`/`PermissionRequest` payload.

## 6. Corpus sync — configurable, split with the platform (locked)

Replaces global env vars (`CC_WT_COPY` / `CC_WT_SHARE`) with **per-project, committed config**, and splits responsibility with Claude Code's native `.worktreeinclude`:

- **Forward file copy** (`.env`, secrets — seed-only, never collected back): delegate to official **`.worktreeinclude`** (gitignore-syntax, native). grove honors it; a `grove.toml` `copy` key exists only as a fallback for users who don't want the native file.
- **Bidirectional shared dirs** (test corpus): owned by **`grove.toml` `[worktree.share]`** — `dirs` (seeded forward on create, collected back on removal) + `exclude` (patterns skipped both ways).
- **`exclude` is now per-project.** This fixes the current footgun where hardcoded `*/html/*`, `*/output/*` etc. match *any* nested dir of that name and silently drop fixtures.
- **Backward collect (the moat) is kept and hardened:** never overwrites main; same-name/different-content clashes preserved as `<name>.from-<branch>.<ext>`; glob-safe (`set -f`), trailing-slash tolerant, opt-in. This is the differentiated half — `.worktreeinclude` and Cursor only seed forward; nobody collects gitignored agent-authored tests back.
- **Evolution (folds in old row "Sculptor Pairing Mode"):** corpus sync moves from **batch collect on removal** → **live bidirectional sync** with pending conflicts surfaced as **⚠ on the tree node**. Trigger via official **`WorktreeCreate` / `WorktreeRemove`** hooks (cleaner than reverse-parsing `git worktree add`).
- **Default when no `grove.toml`:** disabled (opt-in) — right for a published tool; won't surprise strangers with a `scratchpad/e2e` default.

```toml
# grove.toml — per-project, committed
[worktree]
copy = [".env", ".env.local", ".claude/settings.local.json"]   # fallback; prefer .worktreeinclude

[worktree.share]
dirs    = ["scratchpad/e2e"]                                    # seeded forward + collected back
exclude = ["*-shots/", "reports/", "output/", "html/"]          # per-project, both directions
```

## 7. Diff reviewer = core; PR flow = deferred (locked)

- **Diff reviewer is core, not a borrow.** A gated merge needs an informed decision, so the right panel's **branch-vs-merge-target diff** is mandatory. Scope is deliberately simple: syntax-highlighted, scrollable, file-by-file navigation (renders `git diff <target>...<node>`). **No** per-hunk staging or inline comments (that is heavyweight PR-review interaction; out of scope).
- **`merge → push → PR` is deferred (YAGNI).** The signature is **local** gated hierarchical merge. The user's own workflow is local-worktree + gated-merge + "default keep the branch, don't land," not PR-centric. A future optional "push + open PR" terminal action (via `gh`, gated the same way, for top-of-tree → main) is a **seam, not built for MVP**.

## 8. Task ledger + signals — own the store, feed from official hooks (locked; option C)

The orchestrator is the Go TUI + human, not another claude. We own every PTY, so we already *see* the agents; we need **structured signals**, not injected terminal text.

- **Task ledger:** the orchestrator's **SQLite** table (needed for the tree regardless). Populated at spawn (we know the task), then updated by **official lifecycle hooks**: `Stop`/`StopFailure` (turn ended = idle/done), `Notification` (`permission_prompt` = waiting on input), `PermissionRequest` (waiting on approval — already used by §5), `SubagentStop`. Each hook identifies its worktree by `cwd`/`session_id` and updates the row. **Replaces `worktree-tasks.tsv`; no cmux.**
- **Backchannel: the cmux-send text injection is removed entirely.**
  - *Freeform* (agent asks the human a question) = **attach into the PTY** (Enter on the node). We own the PTY; attach *is* the channel.
  - *Structured* (done / blocked / waiting) = official hooks → SQLite → **tree lamps**.
  - *"I'm ready + summary"* = evolves the existing `gwt-done` convention into `grove done`, writing ready-state (+ optional summary) into SQLite.
- **Rejected: Claude Code Agent Teams native mailbox/task-list.** Two hard blockers: it is experimental/flag-gated, and it does **no worktree isolation** (teammates share one dir), which conflicts with grove's per-worktree independent-`claude` model. grove spawns independent top-level sessions, not teammates.

## 9. What's cut, and why (locked)

All five are symptoms of one root cause — *the terminal was owned by cmux, not us* — and all **vanish** (not "rewritten") once grove owns the PTY:

| Cut | Why it existed | Fate under embedded PTY |
|---|---|---|
| Screen-scrape RDY probe | cmux tab starts a shell async with no ready signal | Gone — we spawn the process and read its stream directly |
| Trust pre-authorization (writes `~/.claude.json`) | can't answer the trust dialog in a backgrounded tab | Gone — answer via our owned PTY or a documented flag; **kills the biggest private-format dependency risk** |
| cmux surface management (open/track/liveness) | cmux is the terminal backend we orchestrate | Gone — we *are* the backend; state comes from process handles |
| Failure breadcrumbs (`cc-failures.log`) | async tab-open could silently fail | Whole failure class gone — in-process spawn fails loudly |
| zellij fan (`gwt-fan`) | fallback multiplexer channel | Cut — no external multiplexer at all |

## 10. Migration

Target architecture is §4 (embedded PTY). The user's "harden, don't rewrite" stance implies an **incremental** migration (a Go state/TUI layer grows over the working, tested shell system; execution moves into the Go process backend-by-backend; shell scripts retire as their Go equivalents land; cmux is retired last). **The concrete phase breakdown is the implementation plan's job**, not this spec.

## 11. Open items to resolve before/at implementation

1. **Plan-payload field (spike):** confirm the exact field carrying the plan markdown in the `ExitPlanMode` / `PermissionRequest` hook payload (the hooks reference doesn't enumerate `ExitPlanMode`). Low-risk 5-minute verification; gates the §5 minimal version.
2. **Trust dialog via owned PTY:** confirm grove can cleanly answer "Do you trust this folder?" through the owned PTY (or that a documented non-interactive flag exists), so the trust-json hack (§9) can be dropped with confidence.

## 12. Explicitly out of scope (YAGNI)

- Setup/bootstrap scripts on worktree create (`npm install`, DB init) — deferred until a real need appears.
- `merge → push → PR` flow — seam only (§7).
- tmux / cmux session backends — interface seam only, unbuilt (§4).
- Per-hunk diff staging / inline review comments (§7).
- Agent Teams native mailbox/task-list (§8).
- Multi-agent (Codex/Gemini/…) support (§1).
- Commercial/cloud/team features; cross-machine tree sync.

---

## Decision log (this session)

1. **Positioning:** personal-hardened-then-published · Claude-Code-only · Go single-binary TUI.
2. **Moat:** human-gated **hierarchical** merge + **backward** corpus collect. Bet everything on structured convergence.
3. **Plan-first = hard gate** via official `PermissionRequest` (+ `ExitPlanMode` capture), synchronous block, verified feasible (600s→3600s timeout).
4. **Corpus sync:** per-project `grove.toml` `[share]`, split with native `.worktreeinclude`; opt-in default; exclude per-project; keep/harden backward collect; evolve to live sync via `WorktreeCreate/Remove` hooks.
5. **Embedded PTY** committed as target; `Backend` seam left unbuilt (no tmux/cmux).
6. **Diff reviewer** = core (simple); **PR flow** = deferred seam.
7. **Task ledger/signals** = own SQLite + official lifecycle hooks; attach-PTY for freeform; **no** cmux-send injection; **reject** Agent Teams native.
8. **Cut** the five cmux-era hacks as a consequence of embedded PTY.
