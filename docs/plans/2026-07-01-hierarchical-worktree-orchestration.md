# Hierarchical Worktree Orchestration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let cc-stack track a tree of worktrees (A ⊃ {A1,A2,A3}, B ⊃ {B1,B2,B3}), render it, and merge children→parent→main with a human authorization gate at every merge.

**Architecture:** All git mechanics go in a new standalone bash script `cc-merge.sh` (subcommands, unit-testable in a throwaway repo — same pattern as `cc-trust.sh`/`cc-tasks-log.sh`). The merge relationship and ready flag live in git config (`branch.<b>.ccMergeInto`, `branch.<b>.ccDone`), not the volatile tasks TSV. The zsh `gwt-*` commands in `worktree.zsh` wrap `cc-merge.sh` and own the interactive authorization gate — `cc-merge.sh do-merge` only ever runs *after* the human confirms.

**Tech Stack:** bash + git plumbing (`worktree list --porcelain`, `config`, `rev-list`, `merge-tree`, `merge`), zsh functions, existing `test.sh` harness (bash, `eq`/`ok`/`no` helpers, throwaway `git init` repos).

## Global Constraints

- **Authorization iron rule:** merge/commit/cleanup never run autonomously. `cc-merge.sh do-merge` is invoked ONLY from `gwt-merge` after an explicit human confirm; it is never reachable from the PostToolUse hook or any auto path. `gwt-done` is a pure annotation (no history change) and needs no gate.
- **One gate per merge:** `gwt-collect` walks ready children and runs one gated `gwt-merge` per child — never a batch auto-merge.
- **Merge target storage:** `git config branch.<branch>.ccMergeInto <parentBranch>`. Ready flag: `git config branch.<branch>.ccDone true`. Branch names contain `/` (e.g. `feat/A1`) — git config subsection handles this; always quote in `[branch "..."]` form, and via CLI `git config branch.feat/A1.ccMergeInto ...` parses correctly (section=`branch`, subsection=`feat/A1`, key=`ccMergeInto`).
- **Trunk detection:** trunk = `origin/HEAD`'s target, else `main`, else `master`, else literal `main`. Never hardcode `main` alone.
- **Top-level default:** a worktree branch with no `ccMergeInto` set and name ≠ trunk → its merge target defaults to trunk.
- **Merge strategy:** chosen per merge by the human (default `--squash`, overridable `--no-ff`/`--rebase`). Not a fixed global default.
- **English only** in all files (docs, comments, runtime output) — this is a public repo.
- **cc-merge.sh header** must follow the existing script style: `#!/usr/bin/env bash`, `set -u`, a 3-line purpose comment.
- **bash 3.2 compatibility (stock macOS):** the target machine's `/usr/bin/env bash` is bash 3.2.57. Do NOT use bash-4-only features — no `declare -A`/associative arrays, no `${var,,}`/`${var^^}`, no `mapfile`/`readarray`. Process substitution `< <(...)` and `${var#...}`/`${var%...}` are fine. Never change the shebang or depend on a homebrew bash.
- **Files live in** `~/.config/cc-stack/` (repo root). Tests append to `test.sh`. Do all commits on branch `feat/hierarchical-worktree-orchestration`.

---

### Task 1: `cc-merge.sh` skeleton + merge-target read/write

**Files:**
- Create: `cc-merge.sh`
- Test: `test.sh` (append a new section)

**Interfaces:**
- Produces:
  - `cc-merge.sh set-parent <repo> <branch> <parent>` → writes `branch.<branch>.ccMergeInto=<parent>`, exit 0.
  - `cc-merge.sh get-parent <repo> <branch>` → prints the parent branch. If unset and `<branch>` ≠ trunk → prints trunk. If `<branch>` = trunk → prints nothing. Exit 0.
  - internal `_cm_main_branch <repo>` → prints trunk branch name.

- [ ] **Step 1: Write the failing test** — append to `test.sh` immediately before the `echo "== syntax =="` line:

```bash
echo "== 4. cc-merge set/get-parent =="
MR=$(mktemp -d); ( cd "$MR"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  git worktree add -q wtA -b feat/A >/dev/null
  git -C wtA commit -q --allow-empty -m a
  git worktree add -q wtA1 -b feat/A1 feat/A >/dev/null )
"$CC/cc-merge.sh" set-parent "$MR" feat/A1 feat/A
eq "set-parent writes config" "$(git -C "$MR" config branch.feat/A1.ccMergeInto)" "feat/A"
eq "get-parent returns it"    "$("$CC/cc-merge.sh" get-parent "$MR" feat/A1)" "feat/A"
eq "get-parent falls back to trunk" "$("$CC/cc-merge.sh" get-parent "$MR" feat/A)" "main"
eq "get-parent of trunk is empty"   "$("$CC/cc-merge.sh" get-parent "$MR" main)" ""
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: FAIL — `cc-merge.sh: No such file or directory` on the set/get lines.

- [ ] **Step 3: Write minimal implementation** — create `cc-merge.sh`:

```bash
#!/usr/bin/env bash
# cc-stack · merge mechanics for hierarchical worktrees.
# Stores each worktree branch's merge target + ready flag in git config
# (branch.<b>.ccMergeInto / branch.<b>.ccDone), derives the parent tree,
# runs merge preflight, and performs the gated merge. The interactive
# authorization gate lives in worktree.zsh (gwt-merge), never here.
set -u

_cm_main_branch() {   # <repo> → trunk branch name
  local repo="$1" h b
  h="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" \
    && { echo "${h#origin/}"; return; }
  for b in main master; do
    git -C "$repo" show-ref --verify --quiet "refs/heads/$b" && { echo "$b"; return; }
  done
  echo main
}

cmd_set_parent() {    # <repo> <branch> <parent>
  local repo="$1" branch="$2" parent="$3"
  git -C "$repo" config "branch.$branch.ccMergeInto" "$parent"
}

cmd_get_parent() {    # <repo> <branch> → parent (trunk fallback; empty if branch==trunk)
  local repo="$1" branch="$2" p trunk
  p="$(git -C "$repo" config --get "branch.$branch.ccMergeInto" 2>/dev/null)"
  if [ -n "$p" ]; then echo "$p"; return; fi
  trunk="$(_cm_main_branch "$repo")"
  [ "$branch" = "$trunk" ] && return 0
  echo "$trunk"
}

case "${1:-}" in
  set-parent) shift; cmd_set_parent "$@" ;;
  get-parent) shift; cmd_get_parent "$@" ;;
  *) echo "usage: cc-merge.sh {set-parent|get-parent} ..." >&2; exit 2 ;;
esac
```

Then: `chmod +x ~/.config/cc-stack/cc-merge.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: PASS — the four new `✔` lines under `== 4. cc-merge set/get-parent ==`; syntax section still green.

- [ ] **Step 5: Commit**

```bash
cd ~/.config/cc-stack
git add cc-merge.sh test.sh
git commit -m "feat: cc-merge.sh set-parent/get-parent (merge target in git config)"
```

---

### Task 2: ready flag (`done` / `is-done`)

**Files:**
- Modify: `cc-merge.sh`
- Test: `test.sh`

**Interfaces:**
- Consumes: `cc-merge.sh` dispatch from Task 1.
- Produces:
  - `cc-merge.sh done <repo> <branch> [true|false]` → sets `branch.<branch>.ccDone` (default `true`). Exit 0.
  - `cc-merge.sh is-done <repo> <branch>` → exit 0 if `ccDone`==`true`, else exit 1. Prints nothing.

- [ ] **Step 1: Write the failing test** — append to `test.sh` after Task 1's block:

```bash
echo "== 5. cc-merge done/is-done =="
"$CC/cc-merge.sh" done "$MR" feat/A1
eq "done sets flag" "$(git -C "$MR" config branch.feat/A1.ccDone)" "true"
"$CC/cc-merge.sh" is-done "$MR" feat/A1 && eq "is-done true" ok ok || eq "is-done true" no ok
"$CC/cc-merge.sh" done "$MR" feat/A1 false
"$CC/cc-merge.sh" is-done "$MR" feat/A1 && eq "is-done false" no ok || eq "is-done false" ok ok
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: FAIL — `usage: cc-merge.sh {set-parent|get-parent}` on the `done` line.

- [ ] **Step 3: Write minimal implementation** — add these two functions to `cc-merge.sh` before the `case` block:

```bash
cmd_done() {          # <repo> <branch> [true|false]
  local repo="$1" branch="$2" val="${3:-true}"
  git -C "$repo" config "branch.$branch.ccDone" "$val"
}

cmd_is_done() {       # <repo> <branch> → exit 0 if done
  local repo="$1" branch="$2"
  [ "$(git -C "$repo" config --get "branch.$branch.ccDone" 2>/dev/null)" = "true" ]
}
```

And add these two cases to the `case` block (before the `*)` line):

```bash
  done)       shift; cmd_done "$@" ;;
  is-done)    shift; cmd_is_done "$@" ;;
```

Update the usage string to `{set-parent|get-parent|done|is-done}`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: PASS — three new `✔` lines under `== 5. cc-merge done/is-done ==`.

- [ ] **Step 5: Commit**

```bash
cd ~/.config/cc-stack
git add cc-merge.sh test.sh
git commit -m "feat: cc-merge.sh done/is-done ready flag"
```

---

### Task 3: tree derivation

**Files:**
- Modify: `cc-merge.sh`
- Test: `test.sh`

**Interfaces:**
- Consumes: `_cm_main_branch`, `cmd_get_parent`, `cmd_is_done` from Tasks 1-2.
- Produces:
  - `cc-merge.sh tree <repo>` → one TSV line per worktree branch:
    `branch \t parent \t ahead \t dirty \t done` where `ahead` = commits ahead of parent (integer), `dirty` = `dirty`|`clean`, `done` = `done`|`-`. Trunk itself is not emitted (it's the implicit root). Exit 0.

- [ ] **Step 1: Write the failing test** — append to `test.sh`:

```bash
echo "== 6. cc-merge tree =="
"$CC/cc-merge.sh" set-parent "$MR" feat/A main
"$CC/cc-merge.sh" set-parent "$MR" feat/A1 feat/A
"$CC/cc-merge.sh" done "$MR" feat/A1 true
git -C "$MR/wtA1" commit -q --allow-empty -m a1
TREE="$("$CC/cc-merge.sh" tree "$MR")"
eq "tree has feat/A→main"   "$(echo "$TREE" | awk -F'\t' '$1=="feat/A"{print $2}')" "main"
eq "tree has feat/A1→feat/A" "$(echo "$TREE" | awk -F'\t' '$1=="feat/A1"{print $2}')" "feat/A"
eq "tree A1 ahead=1"        "$(echo "$TREE" | awk -F'\t' '$1=="feat/A1"{print $3}')" "1"
eq "tree A1 done"           "$(echo "$TREE" | awk -F'\t' '$1=="feat/A1"{print $5}')" "done"
eq "tree omits trunk"       "$(echo "$TREE" | awk -F'\t' '$1=="main"' | wc -l | tr -d ' ')" "0"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: FAIL — usage error on the `tree` line.

- [ ] **Step 3: Write minimal implementation** — add to `cc-merge.sh` before the `case` block:

```bash
cmd_tree() {          # <repo> → TSV: branch \t parent \t ahead \t dirty \t done
  # bash 3.2 safe: no associative array — emit each row inline as we read the
  # porcelain stream (a `branch` line always follows its `worktree` line).
  local repo="$1" trunk dir="" line b parent ahead dirty done
  trunk="$(_cm_main_branch "$repo")"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) dir="${line#worktree }" ;;
      "branch refs/heads/"*)
        b="${line#branch refs/heads/}"
        if [ "$b" = "$trunk" ]; then dir=""; continue; fi
        parent="$(cmd_get_parent "$repo" "$b")"
        ahead="$(git -C "$repo" rev-list --count "$parent..$b" 2>/dev/null || echo 0)"
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then dirty=dirty; else dirty=clean; fi
        if cmd_is_done "$repo" "$b"; then done=done; else done=-; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$parent" "$ahead" "$dirty" "$done"
        dir="" ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain)
}
```

Add case: `  tree)       shift; cmd_tree "$@" ;;` and extend usage string with `|tree`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: PASS — five new `✔` lines under `== 6. cc-merge tree ==`.

- [ ] **Step 5: Commit**

```bash
cd ~/.config/cc-stack
git add cc-merge.sh test.sh
git commit -m "feat: cc-merge.sh tree derivation from git config"
```

---

### Task 4: merge preflight

**Files:**
- Modify: `cc-merge.sh`
- Test: `test.sh`

**Interfaces:**
- Consumes: `cmd_get_parent`, `cmd_is_done` from Tasks 1-2.
- Produces:
  - `cc-merge.sh preflight <repo> <child> [<target>]` → prints one `check: <name> <ok|WARN|FAIL>` line per check (`clean`, `done`, `target-exists`, `conflict`) and a final `target: <resolved-target>` line. Exit 0 if all pass; exit 1 if any WARN/FAIL. `<target>` defaults to `get-parent <child>`.

- [ ] **Step 1: Write the failing test** — append to `test.sh`:

```bash
echo "== 7. cc-merge preflight =="
# clean + done + no conflict → exit 0
PF="$("$CC/cc-merge.sh" preflight "$MR" feat/A1 feat/A)"; pf_rc=$?
eq "preflight ok exit0" "$pf_rc" "0"
eq "preflight resolves target" "$(echo "$PF" | awk '/^target:/{print $2}')" "feat/A"
# dirty child → WARN + exit 1
echo x > "$MR/wtA1/dirtyfile"
"$CC/cc-merge.sh" preflight "$MR" feat/A1 feat/A >/dev/null; eq "preflight dirty exit1" "$?" "1"
rm -f "$MR/wtA1/dirtyfile"
# conflict: make feat/A and feat/A1 both touch same line differently
( cd "$MR/wtA";  printf 'A-side\n' > clash.txt; git add clash.txt; git commit -q -m clashA )
( cd "$MR/wtA1"; printf 'A1-side\n' > clash.txt; git add clash.txt; git commit -q -m clashA1 )
"$CC/cc-merge.sh" preflight "$MR" feat/A1 feat/A > /tmp/cctest-pf.txt 2>&1
eq "preflight detects conflict" "$(awk '/^check: conflict/{print $3}' /tmp/cctest-pf.txt)" "FAIL"
rm -f /tmp/cctest-pf.txt
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: FAIL — usage error on the first `preflight` line.

- [ ] **Step 3: Write minimal implementation** — add to `cc-merge.sh`:

```bash
cmd_preflight() {     # <repo> <child> [<target>] → prints checks; exit 1 if any not ok
  local repo="$1" child="$2" target="${3:-}" rc=0 cdir=""
  [ -n "$target" ] || target="$(cmd_get_parent "$repo" "$child")"
  # locate child worktree dir for the dirty check
  local br="" dir=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) dir="${line#worktree }" ;;
      "branch refs/heads/"*) [ "${line#branch refs/heads/}" = "$child" ] && cdir="$dir" ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain)
  # clean
  if [ -n "$cdir" ] && [ -n "$(git -C "$cdir" status --porcelain 2>/dev/null)" ]; then
    echo "check: clean WARN"; rc=1; else echo "check: clean ok"; fi
  # done
  if cmd_is_done "$repo" "$child"; then echo "check: done ok"; else echo "check: done WARN"; rc=1; fi
  # target-exists
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$target"; then
    echo "check: target-exists ok"; else echo "check: target-exists FAIL"; rc=1; fi
  # conflict (git 2.38+ --write-tree exits nonzero on conflict)
  if git -C "$repo" merge-tree --write-tree "$target" "$child" >/dev/null 2>&1; then
    echo "check: conflict ok"; else echo "check: conflict FAIL"; rc=1; fi
  echo "target: $target"
  return $rc
}
```

Add case: `  preflight)  shift; cmd_preflight "$@" ;;` and extend usage with `|preflight`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: PASS — four new `✔` lines under `== 7. cc-merge preflight ==`.

- [ ] **Step 5: Commit**

```bash
cd ~/.config/cc-stack
git add cc-merge.sh test.sh
git commit -m "feat: cc-merge.sh preflight (clean/done/target-exists/conflict)"
```

---

### Task 5: `do-merge` (the post-gate merge)

**Files:**
- Modify: `cc-merge.sh`
- Test: `test.sh`

**Interfaces:**
- Consumes: `cmd_get_parent`.
- Produces:
  - `cc-merge.sh do-merge <repo> <child> <strategy> [<target>]` where `strategy` ∈ `squash|no-ff|rebase`. Performs the merge into `<target>` (default `get-parent <child>`), operating in the target's existing worktree if checked out, else in a temp worktree it creates and removes. Prints `merged: <child> -> <target> (<strategy>)` on success (exit 0); on conflict aborts cleanly and prints `conflict: <child> -> <target>` (exit 1). Never removes the child worktree or deletes any branch.

- [ ] **Step 1: Write the failing test** — append to `test.sh`. Uses a fresh repo (`MR2`) so earlier conflict state doesn't interfere:

```bash
echo "== 8. cc-merge do-merge =="
MR2=$(mktemp -d); ( cd "$MR2"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  git worktree add -q wtP -b feat/P >/dev/null
  git -C wtP commit -q --allow-empty -m p
  git worktree add -q wtP1 -b feat/P1 feat/P >/dev/null
  cd wtP1; printf 'hello\n' > f.txt; git add f.txt; git commit -q -m p1 )
before=$(git -C "$MR2" rev-list --count feat/P)
"$CC/cc-merge.sh" set-parent "$MR2" feat/P1 feat/P
OUT="$("$CC/cc-merge.sh" do-merge "$MR2" feat/P1 squash feat/P)"; rc=$?
eq "do-merge squash exit0" "$rc" "0"
after=$(git -C "$MR2" rev-list --count feat/P)
eq "squash adds exactly 1 commit" "$((after-before))" "1"
eq "squash brought the file"      "$(git -C "$MR2" show feat/P:f.txt 2>/dev/null)" "hello"
# no-ff creates a merge commit
git -C "$MR2" worktree add -q wtP2 -b feat/P2 feat/P >/dev/null
( cd "$MR2/wtP2"; printf 'two\n' > g.txt; git add g.txt; git commit -q -m p2 )
"$CC/cc-merge.sh" do-merge "$MR2" feat/P2 no-ff feat/P >/dev/null
eq "no-ff makes a merge commit" "$(git -C "$MR2" rev-list --merges --count feat/P)" "1"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: FAIL — usage error on the `do-merge` line.

- [ ] **Step 3: Write minimal implementation** — add to `cc-merge.sh`:

```bash
# locate the worktree dir a branch is checked out in (empty if none)
_cm_worktree_of() {   # <repo> <branch>
  local repo="$1" want="$2" dir=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) dir="${line#worktree }" ;;
      "branch refs/heads/"*) [ "${line#branch refs/heads/}" = "$want" ] && { echo "$dir"; return; } ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain)
}

cmd_do_merge() {      # <repo> <child> <strategy> [<target>]
  local repo="$1" child="$2" strategy="$3" target="${4:-}"
  [ -n "$target" ] || target="$(cmd_get_parent "$repo" "$child")"
  local tdir tmp="" tmpparent="" rc=0
  tdir="$(_cm_worktree_of "$repo" "$target")"
  if [ -z "$tdir" ]; then
    tmpparent="$(mktemp -d)"; tmp="$tmpparent/t"
    git -C "$repo" worktree add -q "$tmp" "$target" || { rm -rf "$tmpparent"; return 1; }
    tdir="$tmp"
  fi
  case "$strategy" in
    squash)
      # NOTE: `merge --squash` sets no MERGE_HEAD, so `merge --abort` would no-op
      # and leave an existing worktree dirty — reset --hard is the correct undo.
      if git -C "$tdir" merge --squash "$child" >/dev/null 2>&1; then
        git -C "$tdir" commit -q -m "merge $child into $target (squash)" || { git -C "$tdir" reset --hard HEAD >/dev/null 2>&1; rc=1; }
      else git -C "$tdir" reset --hard HEAD >/dev/null 2>&1; rc=1; fi ;;
    no-ff)
      git -C "$tdir" merge --no-ff -m "merge $child into $target" "$child" >/dev/null 2>&1 \
        || { git -C "$tdir" merge --abort 2>/dev/null; rc=1; } ;;
    rebase)
      if git -C "$repo" rebase "$target" "$child" >/dev/null 2>&1; then
        git -C "$tdir" merge --ff-only "$child" >/dev/null 2>&1 || rc=1
      else git -C "$repo" rebase --abort 2>/dev/null; rc=1; fi ;;
    *) echo "unknown strategy: $strategy" >&2; rc=2 ;;
  esac
  [ -n "$tmp" ] && git -C "$repo" worktree remove --force "$tmp" 2>/dev/null
  [ -n "$tmpparent" ] && rm -rf "$tmpparent"
  if [ "$rc" = 0 ]; then echo "merged: $child -> $target ($strategy)";
  elif [ "$rc" = 2 ]; then :   # usage error already emitted to stderr; no stdout line
  else echo "conflict: $child -> $target"; fi
  return $rc
}
```

Add case: `  do-merge)   shift; cmd_do_merge "$@" ;;` and extend usage with `|do-merge`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: PASS — four new `✔` lines under `== 8. cc-merge do-merge ==`.

- [ ] **Step 5: Commit**

```bash
cd ~/.config/cc-stack
git add cc-merge.sh test.sh
git commit -m "feat: cc-merge.sh do-merge (squash/no-ff/rebase, temp-worktree fallback)"
```

---

### Task 6: capture merge target on all creation paths

**Files:**
- Modify: `cc-merge.sh` (add `capture`), `worktree.zsh` (`gwt-new`), `cc-worktree-claude.sh`, `cc-cmux-surface-claude.sh`
- Test: `test.sh`

**Interfaces:**
- Consumes: `cmd_set_parent`, `_cm_main_branch`.
- Produces:
  - `cc-merge.sh capture <repo> <newBranch> <callerCwd>` → resolves the caller's current branch via `git -C <callerCwd> symbolic-ref --short HEAD`; if detached/unresolved, uses trunk; writes `ccMergeInto`. Exit 0.

- [ ] **Step 1: Write the failing test** — append to `test.sh`:

```bash
echo "== 9. cc-merge capture =="
# caller is on feat/A (wtA) → new branch feat/Ax should capture parent feat/A
git -C "$MR" worktree add -q wtAx -b feat/Ax feat/A >/dev/null
"$CC/cc-merge.sh" capture "$MR" feat/Ax "$MR/wtA"
eq "capture from caller branch" "$(git -C "$MR" config branch.feat/Ax.ccMergeInto)" "feat/A"
# caller detached → fall back to trunk
git -C "$MR/wtAx" checkout -q --detach 2>/dev/null
git -C "$MR" worktree add -q wtAy -b feat/Ay feat/A >/dev/null
"$CC/cc-merge.sh" capture "$MR" feat/Ay "$MR/wtAx"
eq "capture detached→trunk" "$(git -C "$MR" config branch.feat/Ay.ccMergeInto)" "main"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: FAIL — usage error on the `capture` line.

- [ ] **Step 3: Write minimal implementation** — add to `cc-merge.sh`:

```bash
cmd_capture() {       # <repo> <newBranch> <callerCwd>
  local repo="$1" branch="$2" cwd="$3" parent
  parent="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)"
  [ -n "$parent" ] || parent="$(_cm_main_branch "$repo")"
  cmd_set_parent "$repo" "$branch" "$parent"
}
```

Add case: `  capture)    shift; cmd_capture "$@" ;;` and extend usage with `|capture`.

Then wire the three creation paths:

In `worktree.zsh`, inside `gwt-new`, right after the `echo "✔ worktree: ..."` line (line ~87), add:

```bash
  ~/.config/cc-stack/cc-merge.sh capture "$root" "$branch" "$PWD" >/dev/null 2>&1
```

In `cc-worktree-claude.sh`, after the `echo "✔ branch   : $branch"` line (line ~33), add:

```bash
"$HOME/.config/cc-stack/cc-merge.sh" capture "$root" "$branch" "$PWD" >/dev/null 2>&1
```

In `cc-cmux-surface-claude.sh`, near the top after the worktree path is known, add a capture using the caller cwd passed by the hook via `CC_CALLER_CWD`. **Gate the whole block on `CC_CALLER_CWD` being set** — this path runs the capture ONLY on the hook path (where the main claude ran `git worktree add` directly and no other capture happened). The `gwt-claude` path already captured with the true caller `$PWD` in `cc-worktree-claude.sh` before exec'ing this script, so re-capturing here (with the repo root, whose checked-out branch may differ) would OVERWRITE the correct parent. Add after the block that resolves the worktree path and its branch (use whatever variable name that script uses for the worktree path):

```bash
# Record the merge target (parent = caller's branch) — HOOK PATH ONLY.
# On the gwt-claude path CC_CALLER_CWD is unset and cc-worktree-claude.sh already
# captured with the real caller cwd; skipping here avoids overwriting it.
if [ -n "${CC_CALLER_CWD:-}" ] && command -v git >/dev/null 2>&1; then
  _root="$(git -C "$wtpath" rev-parse --git-common-dir 2>/dev/null)" && _root="$(cd "$_root/.." && pwd -P)"
  _br="$(git -C "$wtpath" symbolic-ref --short HEAD 2>/dev/null)"
  [ -n "$_root" ] && [ -n "$_br" ] && \
    "$HOME/.config/cc-stack/cc-merge.sh" capture "$_root" "$_br" "$CC_CALLER_CWD" >/dev/null 2>&1
fi
```

And in `cc-worktree-cmux-hook.sh`, where it invokes `cc-cmux-surface-claude.sh`, export the caller cwd first so the capture resolves the true parent. Find the invocation and prefix it with the payload cwd (the hook already parses `cwd` into a variable — pass it as `CC_CALLER_CWD`):

```bash
CC_CALLER_CWD="$cwd" "$HOME/.config/cc-stack/cc-cmux-surface-claude.sh" "$target_path" "$prompt"
```

(If the hook builds the command differently, set `export CC_CALLER_CWD="$cwd"` immediately before the existing invocation — do not change any other argument.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: PASS — two new `✔` under `== 9. cc-merge capture ==`; `bash -n`/`zsh -n` syntax section still green for all edited scripts.

- [ ] **Step 5: Commit**

```bash
cd ~/.config/cc-stack
git add cc-merge.sh worktree.zsh cc-worktree-claude.sh cc-cmux-surface-claude.sh cc-worktree-cmux-hook.sh test.sh
git commit -m "feat: capture merge target on all worktree-creation paths"
```

---

### Task 7: zsh commands — `gwt-tree`, `gwt-done`/`gwt-undone`, `gwt-merge`, `gwt-collect`

**Files:**
- Modify: `worktree.zsh`
- Test: `test.sh` (syntax only — logic is covered by cc-merge.sh tests)

**Interfaces:**
- Consumes: `cc-merge.sh {tree,done,is-done,get-parent,preflight,do-merge}`, existing `_gwt_root`, `_gwt_tasks_file`.
- Produces zsh functions: `gwt-tree`, `gwt-done`, `gwt-undone`, `gwt-merge`, `gwt-collect`. `gwt-merge`/`gwt-collect` are the interactive authorization gate — they call `cc-merge.sh do-merge` only after a `y` confirmation.

- [ ] **Step 1: Write the failing test** — append to `test.sh` (in the syntax section there is already a `zsh -n` check; add an explicit presence assertion right after it):

```bash
echo "== 10. zsh commands present =="
for fn in gwt-tree gwt-done gwt-undone gwt-merge gwt-collect; do
  grep -q "^$fn()" "$CC/worktree.zsh" && ok "$fn defined" || no "$fn defined" missing present
done
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: FAIL — `gwt-tree defined` … `gwt-collect defined` all report `missing`.

- [ ] **Step 3: Write minimal implementation** — add to `worktree.zsh` before `gwt-help`:

```bash
# gwt-tree — hierarchical board: branches by merge-target, git state, ready flag, tab liveness
gwt-tree() {
  emulate -L zsh
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  local data; data="$(~/.config/cc-stack/cc-merge.sh tree "$root")"
  [[ -n "$data" ]] || { echo "no worktree branches (nothing to show)"; return 0 }
  # tab liveness from the tasks TSV (best-effort)
  local live=""
  command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 && live="$(cmux list-pane-surfaces 2>/dev/null)"
  local f; f="$(_gwt_tasks_file)"
  typeset -A ref_of
  if [[ -f "$f" ]]; then
    local ts br rf dir cl tk
    while IFS=$'\t' read -r ts br rf dir cl tk; do [[ -n "$br" ]] && ref_of[$br]="$rf"; done < "$f"
  fi
  local trunk; trunk="$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"; trunk="${trunk#origin/}"
  [[ -n "$trunk" ]] || trunk=main
  echo "$trunk"
  local branch parent ahead dirty done rf tab ready
  echo "$data" | while IFS=$'\t' read -r branch parent ahead dirty done; do
    rf="${ref_of[$branch]:-}"
    if [[ -z "$live" ]]; then tab="?"
    elif [[ -n "$rf" ]] && grep -qF "$rf" <<<"$live"; then tab="✔live"
    elif [[ -n "$rf" ]]; then tab="⌫closed"; else tab="-"; fi
    if [[ "$dirty" == clean && "$done" == done ]]; then ready="ready ✅"; else ready="not ready ⏳"; fi
    printf '  %-16s ↑%-3s %-5s %-5s [%s]  → %s  (into %s)\n' \
      "$branch" "$ahead" "$dirty" "${done/-/}" "$tab" "$ready" "$parent"
  done
}

# gwt-done / gwt-undone — mark the current worktree's branch ready (harmless annotation, no gate)
gwt-done() {
  emulate -L zsh
  local root b; root="$(_gwt_root)" || return 1
  b="$(git symbolic-ref --short HEAD 2>/dev/null)" || { echo "✗ detached HEAD"; return 1 }
  ~/.config/cc-stack/cc-merge.sh done "$root" "$b" true && echo "✔ $b marked ready (gwt-done)"
}
gwt-undone() {
  emulate -L zsh
  local root b; root="$(_gwt_root)" || return 1
  b="$(git symbolic-ref --short HEAD 2>/dev/null)" || { echo "✗ detached HEAD"; return 1 }
  ~/.config/cc-stack/cc-merge.sh done "$root" "$b" false && echo "✔ $b marked not-ready"
}

# gwt-merge <name-or-branch> [--squash|--no-ff|--rebase] [--into <b>] [--force] — GATED merge
gwt-merge() {
  emulate -L zsh
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  local arg="$1"; shift 2>/dev/null
  [[ -n "$arg" ]] || { echo "usage: gwt-merge <name|branch> [--squash|--no-ff|--rebase] [--into <b>] [--force]"; return 1 }
  # accept a bare name (feat/<name>) or a full branch
  local child="$arg"
  git -C "$root" show-ref --verify --quiet "refs/heads/$child" || child="feat/$arg"
  git -C "$root" show-ref --verify --quiet "refs/heads/$child" || { echo "✗ no such branch: $arg"; return 1 }
  local strategy="" target="" force=""
  while (( $# )); do
    case "$1" in
      --squash) strategy=squash ;; --no-ff) strategy=no-ff ;; --rebase) strategy=rebase ;;
      --into) shift; target="$1" ;; --force) force=1 ;;
      *) echo "unknown flag: $1"; return 1 ;;
    esac; shift
  done
  [[ -n "$target" ]] || target="$(~/.config/cc-stack/cc-merge.sh get-parent "$root" "$child")"
  # ordering guard: if child itself has not-ready children, warn
  local kids; kids="$(~/.config/cc-stack/cc-merge.sh tree "$root" | awk -F'\t' -v p="$child" '$2==p && !($4=="clean" && $5=="done"){print $1}')"
  [[ -n "$kids" ]] && echo "⚠ $child still has not-ready children: ${kids//$'\n'/, } — consider 'gwt-collect $child' first"
  echo "── preflight: $child → $target ──"
  local pf rc; pf="$(~/.config/cc-stack/cc-merge.sh preflight "$root" "$child" "$target")"; rc=$?
  echo "$pf" | grep '^check:'
  if (( rc != 0 )) && [[ -z "$force" ]]; then
    echo "✗ preflight not clean. Re-run with --force to override, or fix the flagged items."; return 1
  fi
  # strategy prompt (default squash)
  if [[ -z "$strategy" ]]; then
    printf "strategy? [S]quash / [n]o-ff / [r]ebase (default squash): "
    local ans; read -r ans
    case "$ans" in n|N|no-ff) strategy=no-ff ;; r|R|rebase) strategy=rebase ;; *) strategy=squash ;; esac
  fi
  # AUTHORIZATION GATE
  printf "About to merge \033[1m%s\033[0m --%s into \033[1m%s\033[0m. Proceed? [y/N] " "$child" "$strategy" "$target"
  local ok; read -r ok
  [[ "$ok" == y || "$ok" == Y ]] || { echo "aborted."; return 1 }
  ~/.config/cc-stack/cc-merge.sh do-merge "$root" "$child" "$strategy" "$target"
  local mrc=$?
  (( mrc == 0 )) && echo "  (cleanup when ready: gwt-rm ${child#feat/} --branch)"
  return $mrc
}

# gwt-collect <parent-name-or-branch> — run one GATED gwt-merge per ready child
gwt-collect() {
  emulate -L zsh
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  local p="$1"; [[ -n "$p" ]] || { echo "usage: gwt-collect <parent-name|branch>"; return 1 }
  git -C "$root" show-ref --verify --quiet "refs/heads/$p" || p="feat/$p"
  local ready skipped line branch dirty done
  while IFS=$'\t' read -r branch _ _ dirty done; do
    [[ -n "$branch" ]] || continue
    if [[ "$dirty" == clean && "$done" == done ]]; then ready+=" $branch"; else skipped+=" $branch"; fi
  done < <(~/.config/cc-stack/cc-merge.sh tree "$root" | awk -F'\t' -v p="$p" '$2==p')
  [[ -n "$skipped" ]] && echo "⏭ skipping not-ready:${skipped}"
  [[ -n "$ready" ]] || { echo "no ready children of $p"; return 0 }
  local b
  for b in ${=ready}; do
    echo "════ collect: $b → $p ════"
    gwt-merge "$b" --into "$p" || { echo "  ↳ aborted/failed at $b — nothing further merged; re-run 'gwt-collect $1' to continue"; break }
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: PASS — five new `✔` under `== 10. zsh commands present ==`; `worktree.zsh syntax` still `✔`.

- [ ] **Step 5: Commit**

```bash
cd ~/.config/cc-stack
git add worktree.zsh test.sh
git commit -m "feat: gwt-tree/done/undone/merge/collect (gated hierarchical merge)"
```

---

### Task 8: docs + sub-task working agreement

**Files:**
- Modify: `worktree.zsh` (`gwt-help` heredoc), `README.md`, `claude-rules.md`, `cc-cmux-surface-claude.sh` (working-agreement prompt text)
- Test: `test.sh` (grep presence)

**Interfaces:**
- Consumes: nothing new. Documents Tasks 6-7.

- [ ] **Step 1: Write the failing test** — append to `test.sh`:

```bash
echo "== 11. docs mention new commands =="
grep -q "gwt-merge" "$CC/worktree.zsh" && grep -q "gwt-merge" "$CC/README.md" \
  && ok "gwt-merge documented" || no "gwt-merge documented" missing present
grep -q "gwt-done" "$CC/README.md" && ok "gwt-done documented" || no "gwt-done documented" missing present
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: FAIL — `gwt-merge documented`/`gwt-done documented` report `missing` (README not yet updated).

- [ ] **Step 3: Write minimal implementation**

In `worktree.zsh` `gwt-help` heredoc, add these lines after the `gwt-ls` line:

```
  gwt-tree                               hierarchical board: branch tree, merge target, ready state, tab liveness
  gwt-done / gwt-undone                  (inside a sub-task) mark this branch ready / not-ready for merge
  gwt-merge <name> [--squash|--no-ff|--rebase] [--into <b>] [--force]
                                         GATED merge of a branch into its recorded parent (asks before merging)
  gwt-collect <parent>                   run one gated gwt-merge per ready child of <parent>
```

In `README.md`, add a new section "## Hierarchical worktrees (A ⊃ A1/A2/A3)" documenting: how the merge target is auto-captured (`branch.<b>.ccMergeInto`), `gwt-tree`, `gwt-done`, `gwt-merge`, `gwt-collect`, and that every merge stops at a confirmation gate. Include this concrete example block:

```markdown
## Hierarchical worktrees (A ⊃ {A1,A2,A3})

When a sub-task claude spins off its own worktrees, cc-stack records each
child's merge target automatically (`git config branch.<b>.ccMergeInto`,
captured from the caller's branch at creation). You then drive the merges
back up the tree — each stops at a confirmation gate.

    gwt-tree                 # see the whole tree: A ⊃ {A1,A2,A3}, ready state, tabs
    gwt-done                 # (run inside A1) mark A1 ready when it's finished
    gwt-merge A1             # gated merge A1 → feat/A (asks strategy + confirmation)
    gwt-collect A            # merge every ready child of A into A, one gate each
    gwt-merge A              # finally merge A → main (its recorded/def target)

`gwt-merge` never merges without an explicit `y`. Readiness = clean working
tree **and** `gwt-done`; otherwise it warns and needs `--force`. Cleanup
(`gwt-rm`) stays a separate, explicit step.
```

In `claude-rules.md`, add one bullet under the sub-task rules:

```markdown
- When a sub-task finishes implementing and has reported back, run `gwt-done`
  to light it green on `gwt-tree`. Its merge target was recorded automatically
  at creation — you do not decide where to merge. Merging itself is a separate,
  human-gated step (`gwt-merge` / `gwt-collect`); never merge autonomously.
```

In `cc-cmux-surface-claude.sh`, in the English "Working agreement" note appended to the sub-task prompt, add one sentence:

```
When you finish implementing and have reported back, run `gwt-done` to mark this branch ready; your merge target is already recorded, so you never choose where to merge, and you never merge without my authorization.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: PASS — `gwt-merge documented` / `gwt-done documented` both `✔`. Full suite green (all sections 1-11 + syntax).

- [ ] **Step 5: Commit**

```bash
cd ~/.config/cc-stack
git add worktree.zsh README.md claude-rules.md cc-cmux-surface-claude.sh test.sh
git commit -m "docs: document gwt-tree/done/merge/collect + sub-task gwt-done convention"
```

---

### Task 9: nested tree rendering for `gwt-tree`

**Files:**
- Modify: `worktree.zsh` (replace `gwt-tree` body; add `_gwt_tree_render` helper)
- Test: `test.sh`

**Interfaces:**
- Consumes: `cc-merge.sh tree`, `cc-merge.sh trunk`, `_gwt_root`, `_gwt_tasks_file`.
- Produces: `gwt-tree` renders the indented tree from design §4 (`├─`/`└─`/`│` guides, `children: R/T ready` on parent nodes) instead of a flat list.

- [ ] **Step 1: Write the failing test** — append to `test.sh` immediately before the `== syntax ==` line:

```bash
echo "== 13. gwt-tree nested render =="
GT=$(mktemp -d); ( cd "$GT"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  git worktree add -q wtA -b feat/A >/dev/null; git -C wtA commit -q --allow-empty -m a
  git worktree add -q wtA1 -b feat/A1 feat/A >/dev/null; git -C wtA1 commit -q --allow-empty -m a1 )
"$CC/cc-merge.sh" set-parent "$GT" feat/A main
"$CC/cc-merge.sh" set-parent "$GT" feat/A1 feat/A
"$CC/cc-merge.sh" done "$GT" feat/A1 true
GTOUT="$(cd "$GT" && CC_TASKS_FILE=/dev/null zsh -c 'source ~/.config/cc-stack/worktree.zsh; gwt-tree' 2>/dev/null)"
eq "tree root is trunk"        "$(echo "$GTOUT" | head -1)" "main"
eq "tree shows feat/A"         "$(echo "$GTOUT" | grep -c 'feat/A ')" "1"
eq "tree shows feat/A1"        "$(echo "$GTOUT" | grep -c 'feat/A1')" "1"
eq "tree A children summary"   "$(echo "$GTOUT" | grep -c 'children: 1/1 ready')" "1"
eq "tree A1 ready lamp"        "$(echo "$GTOUT" | grep 'feat/A1' | grep -c 'ready ✅')" "1"
eq "tree has a tree guide"     "$(echo "$GTOUT" | grep -c '├─\|└─')" "2"
eq "no stray typeset output"   "$(echo "$GTOUT" | grep -c '^tab=\|^ready=')" "0"
rm -rf "$GT"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: FAIL — the flat renderer prints no `├─`/`└─` guides and no `children: 1/1 ready`.

- [ ] **Step 3: Write minimal implementation** — replace the ENTIRE existing `gwt-tree` function with the two functions below (helper first):

```bash
# _gwt_tree_render <node> <prefix> — recursive tree drawer (uses _gt_* globals set by gwt-tree)
_gwt_tree_render() {
  emulate -L zsh
  local node="$1" prefix="$2"
  local kids=(${=_gt_kids[$node]:-})
  local n=${#kids} i=1 kid conn childprefix
  for kid in $kids; do
    if (( i == n )); then conn="└─ "; childprefix="$prefix   "; else conn="├─ "; childprefix="$prefix│  "; fi
    local ahead="${_gt_ahead[$kid]}" dirty="${_gt_dirty[$kid]}" dn="${_gt_done[$kid]}"
    local doneflag=""; [[ "$dn" == done ]] && doneflag="✓done"
    local rf="${_gt_ref[$kid]:-}" tab=""
    if [[ -z "$_gt_live" ]]; then tab="?"
    elif [[ -n "$rf" ]] && grep -qF "$rf" <<<"$_gt_live"; then tab="✔live"
    elif [[ -n "$rf" ]]; then tab="⌫closed"; else tab="-"; fi
    local ready=""
    # NOTE: tab= and ready= MUST have initial values — a bare `local x` in this
    # recursive function reprints x (zsh typeset-p behavior) at depth ≥2.
    if [[ "$dirty" == clean && "$dn" == done ]]; then ready="ready ✅"; else ready="not ready ⏳"; fi
    local grandkids=(${=_gt_kids[$kid]:-}) summary=""
    if (( ${#grandkids} )); then
      local r=0 gk
      for gk in $grandkids; do [[ "${_gt_dirty[$gk]}" == clean && "${_gt_done[$gk]}" == done ]] && (( r++ )); done
      summary="  children: $r/${#grandkids} ready"
    fi
    printf '%s%s%-14s ↑%-3s %-5s %-6s [%s]  → %s%s\n' \
      "$prefix" "$conn" "$kid" "$ahead" "$dirty" "$doneflag" "$tab" "$ready" "$summary"
    _gwt_tree_render "$kid" "$childprefix"
    (( i++ ))
  done
}

# gwt-tree — hierarchical board: nested branch tree by merge-target, git state, ready flag, tab liveness
gwt-tree() {
  emulate -L zsh
  local root; root="$(_gwt_root)" || { echo "✗ not inside a git repo"; return 1 }
  local data; data="$(~/.config/cc-stack/cc-merge.sh tree "$root")"
  [[ -n "$data" ]] || { echo "no worktree branches (nothing to show)"; return 0 }
  local trunk; trunk="$(~/.config/cc-stack/cc-merge.sh trunk "$root")"
  # tab liveness (best-effort)
  typeset -gA _gt_ref _gt_parent _gt_ahead _gt_dirty _gt_done _gt_kids
  _gt_ref=(); _gt_parent=(); _gt_ahead=(); _gt_dirty=(); _gt_done=(); _gt_kids=()
  _gt_live=""
  command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 && _gt_live="$(cmux list-pane-surfaces 2>/dev/null)"
  local f; f="$(_gwt_tasks_file)"
  if [[ -f "$f" ]]; then
    local ts br rf dir cl tk
    while IFS=$'\t' read -r ts br rf dir cl tk; do [[ -n "$br" ]] && _gt_ref[$br]="$rf"; done < "$f"
  fi
  local branch parent ahead dirty dn
  while IFS=$'\t' read -r branch parent ahead dirty dn; do
    [[ -n "$branch" ]] || continue
    _gt_parent[$branch]="$parent"; _gt_ahead[$branch]="$ahead"
    _gt_dirty[$branch]="$dirty"; _gt_done[$branch]="$dn"
    _gt_kids[$parent]="${_gt_kids[$parent]:-} $branch"
  done <<< "$data"
  echo "$trunk"
  _gwt_tree_render "$trunk" ""
  unset _gt_ref _gt_parent _gt_ahead _gt_dirty _gt_done _gt_kids _gt_live
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/.config/cc-stack/test.sh`
Expected: PASS — the six new `✔` lines under `== 13. gwt-tree nested render ==`; `zsh -n worktree.zsh` still green.

- [ ] **Step 5: Commit**

```bash
cd ~/.config/cc-stack
git add worktree.zsh test.sh
git commit -m "feat: gwt-tree renders the nested tree (design §4) with children-ready summary"
```

---

## Final verification (after all tasks)

- [ ] Run the full suite: `bash ~/.config/cc-stack/test.sh` → all sections + `result: N passed, 0 failed`.
- [ ] Manual smoke in a throwaway repo: create nested worktrees, `gwt-tree` renders the tree, `gwt-done` flips a lamp, `gwt-merge <child>` stops at the gate and merges on `y`, `gwt-merge <parent>` warns if a child is still not ready.
- [ ] `git -C ~/.config/cc-stack log --oneline` shows one commit per task, all on `feat/hierarchical-worktree-orchestration`.
- [ ] Report branch state to the user and wait for authorization before merging to `main` (per the iron rule).
