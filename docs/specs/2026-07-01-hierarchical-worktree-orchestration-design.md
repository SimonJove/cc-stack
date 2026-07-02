# cc-stack · Hierarchical Worktree Orchestration — Design

**Date:** 2026-07-01
**Status:** Approved (design), pending implementation plan
**Scope:** Extend cc-stack so a tree of worktrees (A ⊃ {A1,A2,A3}, B ⊃ {B1,B2,B3}) can be tracked, visualized, and merged back along the tree — children into their parent, parents into main — with a human authorization gate at every merge.

---

## 1. Problem

cc-stack today spins a sub-task worktree off the caller's branch and opens a parallel cmux tab running claude. This already works for a *flat* set of sub-tasks. It breaks down for a *hierarchy*:

- Branch **A** lives in the primary checkout; branch **B** lives in a worktree. A and B are unrelated tasks (both branch off `main`).
- A's claude spins off **A1/A2/A3** as worktrees; B's claude spins off **B1/B2/B3**.
- When A1/A2/A3 are done they must merge into **A** (not `main`); B1/B2/B3 into **B**.
- When A and B are done they merge into **main**.

What's missing in the current implementation:

1. **No record of the merge target.** The tasks TSV stores branch/dir/caller but nothing says "A1 merges into feat/A, not main." The system has no idea a tree exists.
2. **No merge command at all.** A1→A, A→main are entirely manual git, and it's easy to fat-finger a merge into the wrong target.
3. **The board is flat.** `gwt-status` is one row per tab; it shows no hierarchy and no "children all green → parent can collect" verdict.
4. **Merge-target can't be derived from path.** All worktrees pool under the main repo's `.claude/worktrees/`, so physical layout doesn't encode ownership.

## 2. Design decisions (locked)

| Dimension | Decision |
|---|---|
| **Scope** | Full-chain orchestration, but **one authorization gate per merge**. The system never executes a merge on its own. It sequences and prepares each merge to a one-keystroke-to-approve state, then stops. |
| **Tree capture** | **Automatic at worktree-creation time.** The base branch (the caller's current branch) is captured and stored in git itself. Top-level branches with no record default their target to `main`. |
| **Readiness signal** | **Both** an objective git state *and* a sub-task-reported `done` flag. `gwt-merge` preflight checks both; if unmet it warns but allows `--force`. |
| **Merge strategy** | **Chosen by the human at each merge** (default `--squash`, overridable to `--no-ff` / `--rebase`). Not a fixed global default. |

### Explicitly out of scope (YAGNI)
- Auto-removing worktrees / auto-deleting branches after merge (cleanup stays a separate, explicit `gwt-rm` — it's its own authorization per the user's rule).
- Cross-machine sync of the tree.
- "All children green → auto-merge" (violates the per-merge gate).

## 3. Data model — the tree lives in git, not in the volatile tasks table

Two per-branch git-config keys, written into the repo where the branch lives:

- **Merge target:** `git config branch.<branch>.ccMergeInto <parentBranch>`
  Written the moment the worktree is created. `<parentBranch>` = the symbolic branch name of the caller's `HEAD` at creation. If the caller is detached (base is a raw commit), fall back to the repo's main branch.
- **Ready flag:** `git config branch.<branch>.ccDone true`
  Set by the sub-task via `gwt-done` after it finishes implementing and reporting. This is a pure annotation — it changes no history — so it does **not** require the merge-authorization gate.

**Why git config, not the tasks TSV:** the merge relationship and readiness are durable properties of the branch/worktree. They must outlive a cmux tab. A tab closes, cmux restarts, you come back two days later — `git config` is still there. The tasks TSV stays what it is: a volatile snapshot of "which tab is alive," used only for liveness in the board.

**Top-level default:** a branch that is a known worktree branch but has no `ccMergeInto` (e.g. A in the primary checkout, created by hand) is treated as merging into `main`.

## 4. New commands (4)

### `gwt-tree`
Hierarchical board. Enumerates all worktree branches, reads each `ccMergeInto`, builds a parent map rooted at `main`, and renders:

```
main
├─ feat/A        ↑3  clean          [tab ✔live]   children: 2/3 ready
│  ├─ feat/A1    ↑2  clean  ✓done   [tab ⌫closed]  → ready ✅
│  ├─ feat/A2    ↑1  clean  ✓done   [tab ✔live]    → ready ✅
│  └─ feat/A3    ↑4  dirty          [tab ✔live]    → not ready ⏳
└─ feat/B        ↑1  clean          [tab ✔live]   children: 0/3 ready
   └─ ...
```

Per node: commits ahead of parent (`↑N`), clean/dirty working tree, `✓done` flag, cmux tab liveness (reused from the tasks TSV), and a **readiness verdict**. Parent nodes show `children: N/M ready`.

### `gwt-done` / `gwt-undone`
Run inside a sub-task worktree. Sets/clears `branch.<current>.ccDone`, lighting/dimming the board's ready lamp.

### `gwt-merge <name> [--squash|--no-ff|--rebase] [--into <branch>]`
The gated merge. Sequence:

1. **Resolve target** = `ccMergeInto` (overridable by `--into`; falls back to `main`).
2. **Preflight** — show a summary of:
   - child working tree clean?
   - `ccDone` set?
   - target branch exists?
   - conflict dry-run via `git merge-tree`.
   If any check fails → warn; only `--force` proceeds.
3. **Strategy** — if interactive and no strategy flag was given, prompt for one (default `--squash`).
4. **Authorization gate** — print exactly what will happen ("about to merge `feat/A1` `--squash` into `feat/A`") and wait for explicit confirmation. Never triggered from the hook or any autonomous path.
5. **Execute** on confirm; report the result. Does **not** remove the worktree or delete the branch (cleanup is a separate authorization via `gwt-rm`); prints the cleanup command for convenience.
6. **Conflict** → abort, report, leave the resolution to the human.

### `gwt-collect <parent>`
Orchestration sugar. Walks every **ready** child of `<parent>` and runs the gated `gwt-merge` for each — **one gate per child** (matching the locked "one gate per merge" decision). Not-ready children are skipped and listed. This is the "system knows the order and prepares each merge to approvable" behavior, without ever crossing a gate on its own.

## 5. Ordering guard (the orchestration "brain")

`gwt-merge A` (A→main) when A still has unmerged or not-ready children → warn: "A still has A2 not ready; run `gwt-collect A` first." The system knows the correct **children-before-parent** order and surfaces it, but never overrides a gate.

## 6. Capture points (3 creation paths kept consistent)

The `ccMergeInto` write must happen on every path that creates a worktree:

1. **`gwt-new`** — after `git worktree add` succeeds, write `ccMergeInto` = the branch the caller was on.
2. **`cc-worktree-claude.sh`** (`gwt-claude`) — same, after its `git worktree add`.
3. **Hook path** — the main claude runs `git worktree add` itself; the hook only observes it and opens a tab. So the write happens in `cc-cmux-surface-claude.sh`, deriving the parent branch from the hook payload's caller `cwd` and writing `ccMergeInto` on the new worktree's branch.

Edge case for all three: if the base resolves to a raw commit (detached caller HEAD), fall back to the repo's main branch.

## 7. Docs & sub-task working agreement

- `gwt-help`, `README.md`, `claude-rules.md` gain the new commands.
- The sub-task "working agreement" prompt gains one line: after you finish implementing and reporting, run `gwt-done` to light the board green; your merge target is already recorded, so you don't decide where to merge.

## 8. Testing

Extend `test.sh` (pure logic, no real cmux tab, in the style of the existing 13 checks). In a throwaway git repo, verify:

- `ccMergeInto` is captured on creation (all three paths, plus detached-HEAD fallback to main).
- Tree derivation builds the correct parent map from git config.
- `gwt-merge` preflight: clean/dirty detection, `ccDone` detection, `git merge-tree` conflict detection (a hand-made conflicting pair).
- `gwt-done` / `gwt-undone` set and clear the flag.
- The ordering guard fires when a parent has a not-ready child.

## 9. Files touched (summary)

| File | Change |
|---|---|
| `worktree.zsh` | add `_gwt_tree`, `gwt-tree`, `gwt-done`/`gwt-undone`, `gwt-merge`, `gwt-collect`; write `ccMergeInto` in `gwt-new` |
| `cc-worktree-claude.sh` | write `ccMergeInto` after `git worktree add` |
| `cc-cmux-surface-claude.sh` | derive parent from caller cwd, write `ccMergeInto` on the hook path |
| `test.sh` | add capture / tree / preflight / done / ordering-guard checks |
| `gwt-help` (in `worktree.zsh`), `README.md`, `claude-rules.md` | document new commands + `gwt-done` convention |

## 10. Authorization alignment (the user's iron rule)

- `gwt-merge` always stops at the gate; it is never invoked from the hook or any autonomous path.
- Cleanup (worktree remove / branch delete) stays separate and explicit (`gwt-rm`).
- `gwt-done` is a harmless annotation (no history change), so it needs no gate.
