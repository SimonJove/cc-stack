# cc-stack — two defects found while orchestrating a 3-line worktree batch

**Environment**
- cc-stack at `~/.config/cc-stack`, HEAD `ef9eb00` ("docs(roadmap): finalize the cc-send collision-safe design")
- macOS (darwin 25.3.0), zsh, cmux
- Downstream repo: a Java/Vue monorepo whose `commit-msg` hook enforces Conventional Commits

Both were hit in a single session driving three parallel worktree sub-tasks through a
gate → fix → merge loop. Each cost real time and each produced a **misleading** symptom rather
than a clear failure, which is the part worth fixing.

---

## Defect 1 — `gwt-merge` cannot complete any merge in a repo with a Conventional-Commits `commit-msg` hook, and reports the failure as "conflict"

**Status: FIXED (2026-08-15, campaign `fix/gwt-merge-hooks`)** — conventional default message (`chore: merge <child> into <target>`) + `--message`/`CC_MERGE_MESSAGE` override; captured git output printed on failure; three-way triage (conflict / commit-rejected with the staged merge PRESERVED for manual finishing / failed+output); rebase runs from the child worktree with a dirty-tree refusal; squash commits carry a `Child-Tip: <sha>` trailer. Both smaller points addressed (rebase-in-worktree; trade-off line at the strategy prompt — squash stays the default). Known follow-up: temp-worktree lifecycle (target has no worktree) is gatekeeper-verified but not yet suite-covered.

**Severity:** high — `gwt-merge` is unusable in such a repo, and the reported cause is wrong.

### Symptom

```
── preflight: feat/user-menu-ia → feature/email-ingestion-defects ──
check: clean ok
check: done ok
check: target-exists ok
check: conflict ok                      ← preflight says NO conflict
About to merge feat/user-menu-ia --no-ff into feature/email-ingestion-defects. Proceed? [y/N] y
conflict: feat/user-menu-ia -> feature/email-ingestion-defects      ← but this is printed
```

There is no content conflict. Running the same merge by hand shows the real cause:

```
$ git merge --no-ff -m "merge feat/user-menu-ia into feature/email-ingestion-defects" feat/user-menu-ia
Commit message rejected by commit-msg hook:
  - Subject must follow Conventional Commits format:
  -   <type>(<scope>): <subject>
  - Allowed types: feat|fix|refactor|test|docs|chore|perf|build|ci|style
  - Got: merge feat/user-menu-ia into feature/email-ingestion-defects
Not committing merge; use 'git commit' to complete the merge.
```

### Root cause

`cc-merge.sh` hardcodes a merge message that is not Conventional Commits, in both strategies:

- `cc-merge.sh:117` (squash) — `git commit -q -m "merge $child into $target (squash)"`
- `cc-merge.sh:121` (no-ff)  — `git merge --no-ff -m "merge $child into $target" "$child"`

and both run under `>/dev/null 2>&1`, so the hook's output is discarded. Every nonzero rc that is
not 2 or 4 then falls through to:

- `cc-merge.sh:135` — `else echo "conflict: $child -> $target"; fi`

So *any* merge failure is labelled "conflict", including one where the trees merged perfectly and
only the commit was refused. Note the no-ff path also runs `git merge --abort`, so the successful
merge result is thrown away before the user can inspect it.

### Suggested fix

1. **Make the message conventional by default**, e.g. `chore: merge <child> into <target>` — this
   satisfies Conventional Commits and is harmless everywhere else.
2. **Make it overridable** — a `--message` flag and/or a `CC_MERGE_MESSAGE` / config key, since
   different repos enforce different formats (some also cap subject length; ours is 72).
3. **Stop swallowing stderr.** Capture it and print it on failure. At minimum, distinguish
   "merge produced conflicts" from "merge succeeded but the commit was rejected" — they need
   opposite responses from the operator.
4. Consider offering `--no-commit` + leaving the staged merge in place on commit failure, so the
   operator can finish it manually instead of losing the merge to `--abort`.

**Workaround we used:** skip `gwt-merge`'s commit entirely.

```sh
git merge --no-ff --no-commit <child>
git commit -m "chore(<scope>): merge <child> into campaign branch"
```

### Two related, smaller points in the same code path

- **`--rebase` is refused when the branch is checked out in a worktree** (`cc-merge.sh:101`):
  `rebase-unsupported: <child> is checked out in a worktree; use --squash or --no-ff`.
  This is a self-imposed limit, not a git one: `cc-merge.sh:124` runs
  `git -C "$repo" rebase "$target" "$child"` from the **main** repo, which git refuses because the
  branch lives in another worktree. Running the rebase **from that worktree's directory** works
  fine — we did exactly that by hand for two branches with zero problems. Suggest resolving the
  worktree dir and rebasing there instead of refusing.
- **The default strategy is `squash`.** For an orchestration tool this is a costly default: squash
  discards the child's commit SHA, so afterwards there is no ref to verify the work by. Our
  project's own notes are full of entries marked "UNREACHABLE (squash)" — records citing a SHA that
  no branch contains, because a squash retired it, which then forces slow code-form re-verification
  of whether the work actually landed. Suggest defaulting to `--no-ff` (keeps the child commit in
  history and still marks the merge clearly), or at least documenting the traceability trade-off at
  the strategy prompt.

---

## Defect 2 — `cmux send` to an **idle** pane silently parks the message in the composer and never executes it

**Severity:** high — an orchestrator's instructions can be silently lost with a success return.

### Symptom

`cmux send --surface surface:165 "<text>"` returns:

```
OK surface:165 workspace:69
```

…and the message is **never executed**. It sits in the pane's composer indefinitely. There is no
error and no indication anything is wrong.

The behaviour is **asymmetric**, which is what makes it so easy to miss:

| Target pane state | Result |
|---|---|
| agent **busy / working** | message queues correctly and IS consumed (`Press up to edit queued messages`) |
| agent **idle** (just finished and reported) | message **parks in the composer forever** |

In our run, the parent sent a review-rejection to a sub-task that had just finished and gone idle.
It sat unread for **1h 34m**. The board was the only clue — one row reading `idle(1h)` next to
siblings reading `working(1m)`. Flushing the composer later revealed that an **earlier** message
(sent ~1.5h before that) was also still parked underneath, so messages had been silently
accumulating the whole time.

### Additional observations from the recovery

1. **Leading characters are dropped in transit.** `读 /Us…` arrived as `ers/…`, and `主会话:…`
   arrived as `会话:…`. The path in the message was therefore unusable even after flushing.
   Consistently the first few characters; possibly a race with pane focus/mode.
2. **Parked messages concatenate.** Flushing submitted a merged blob of two unrelated messages
   sent 1.5h apart.
3. **A pane in vim VISUAL mode swallows the keystrokes.** The stuck pane showed `-- VISUAL --`
   while its siblings showed `-- INSERT --`. Neither `cmux send-key ctrl+u` nor `d d` cleared the
   composer; only `cmux send-key enter` flushed it.
4. The pane's title had changed to `fg`, instead of its task name — a useful secondary tell that
   something had gone wrong with that surface.

### Suggested fix

1. **Make `cmux send` submit by default**, or add an explicit `--submit` / `--enter` flag. Silently
   populating an input box is almost never what an automated caller wants.
2. **Return a distinguishable status**: `queued` (agent busy, will be consumed) vs `parked`
   (sitting in composer, will NOT be consumed) vs `delivered`. Today all three return `OK`.
3. **Fix or document the leading-character drop** — settle the pane before writing, or write via a
   paste/bracketed-paste path rather than simulated keystrokes.
4. Consider refusing to write into a composer that already has unsent content, rather than
   appending to it.

### Workaround we adopted

After every `cmux send`, verify and flush:

```sh
cmux send --surface surface:N "<text>"
cmux capture-pane --surface surface:N | tail -5     # is the text sitting at the ❯ prompt?
cmux send-key --surface surface:N enter             # if so, flush it
cmux capture-pane --surface surface:N | tail -5     # confirm the agent actually started working
```

Diagnostic tell for an already-stuck line: `bash ~/.config/cc-stack/cc-board.sh` showing
`idle(Nh)` beside `working(Nm)` siblings, and/or a surface titled `fg`. Ultimately the only
trustworthy check is whether the files you asked to be changed actually changed.

---

## Not a cc-stack issue (recorded here only to pre-empt it being filed as one)

A third trap from the same session — a worktree's frontend dev server on an alt port getting
**HTTP 403 on login** — turned out to be **our own** application's CORS allowlist plus standard
`http-proxy` semantics (`changeOrigin: true` rewrites `Host`, not `Origin`). Nothing for cc-stack
to fix; it belongs in our project's own docs.
