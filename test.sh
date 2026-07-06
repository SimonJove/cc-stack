#!/usr/bin/env bash
# cc-stack · smoke test (pure logic, no real cmux tab needed). Guards the regressions we've hit:
#   hook parsing (A path / B cross-repo / $VAR fallback / non-add-doesn't-trigger / CC_WT_PROMPT), tasks-log, prune/drop, trust add/remove.
# Usage: bash ~/.config/cc-stack/test.sh
set -u
CC=~/.config/cc-stack
pass=0; fail=0
ok(){ echo "  ✔ $1"; pass=$((pass+1)); }
no(){ echo "  ✗ $1  expected[$3] got[$2]"; fail=$((fail+1)); }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

echo "== 1. hook parser =="
awk "/<<'PY'/{f=1;next} /^PY\$/{f=0} f" "$CC/cc-worktree-cmux-hook.sh" > /tmp/cctest-ep.py
run(){ CC_HOOK_INPUT="$1" python3 /tmp/cctest-ep.py 2>/dev/null; }
pay(){ python3 -c "import json,sys;print(json.dumps({'tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':sys.argv[2]}}))" "$1" "$2"; }
R1=$(mktemp -d); ( cd "$R1"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  git worktree add -q wtC -b feat/C >/dev/null; git worktree add -q wtD -b feat/D >/dev/null )
touch "$R1/wtD/x"; touch "$R1/wtD"
C="$(cd "$R1/wtC" && pwd -P)"
eq "A parsed-path beats mtime" "$(run "$(pay "$R1" 'git worktree add wtC -b feat/C')" | cut -f1)" "$C"
eq "A -b before path"          "$(run "$(pay "$R1" 'git worktree add -b feat/C wtC')" | cut -f1)" "$C"
eq "CC_WT_PROMPT extraction"   "$(run "$(pay "$R1" "CC_WT_PROMPT='doX' git worktree add wtC")" | cut -f2)" "doX"
R2=$(mktemp -d); ( cd "$R2"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git worktree add -q wtX -b feat/X >/dev/null )
X="$(cd "$R2/wtX" && pwd -P)"
eq "B cross-repo -C"           "$(run "$(pay "$R1" "git -C $R2 worktree add wtX")" | cut -f1)" "$X"
eq "non-add (list) no trigger"   "$(run "$(pay "$R1" 'git worktree list')")" ""
eq "non-add (remove) no trigger" "$(run "$(pay "$R1" 'git worktree remove wtC')")" ""
# $VAR fallback: invalid repo falls back to cwd, unmatched path falls back to mtime (newest = wtD, which we touched)
D="$(cd "$R1/wtD" && pwd -P)"
eq "\$VAR fallback (to mtime)"  "$(run "$(pay "$R1" 'git -C $root worktree add $root/wtNope')" | cut -f1)" "$D"
rm -rf "$R1" "$R2" /tmp/cctest-ep.py

echo "== 2. cc-tasks-log + prune/drop =="
export CC_TASKS_FILE=$(mktemp -u)
"$CC/cc-tasks-log.sh" "/tmp/nodir_A" "surface:1" "surface:9" "task	with tab|pipe"
eq "writes 6 fields"        "$(awk -F'\t' 'NR==1{print NF}' "$CC_TASKS_FILE")" "6"
eq "task sanitized (no tab)" "$(awk -F'\t' 'NR==1{print ($6 ~ /\t/)?"bad":"ok"}' "$CC_TASKS_FILE")" "ok"
rm -f "$CC_TASKS_FILE"; unset CC_TASKS_FILE

echo "== 3. cc-trust add/remove (isolated json) =="
TJ=$(mktemp); echo '{"projects":{}}' > "$TJ"
TD=$(mktemp -d)
CC_TRUST_CFG_OVERRIDE="$TJ" "$CC/cc-trust.sh" "$TD" >/dev/null 2>&1
eq "trusted after add" "$(python3 -c "import json,os;print(json.load(open('$TJ'))['projects'].get(os.path.realpath('$TD'),{}).get('hasTrustDialogAccepted'))")" "True"
CC_TRUST_CFG_OVERRIDE="$TJ" "$CC/cc-trust.sh" --remove "$(cd "$TD"&&pwd -P)" >/dev/null 2>&1
eq "entry gone after remove" "$(python3 -c "import json;print(len(json.load(open('$TJ'))['projects']))")" "0"
# remove must not touch a project with real fields
python3 -c "import json;json.dump({'projects':{'/real':{'hasTrustDialogAccepted':True,'lastCost':1.2}}},open('$TJ','w'))"
CC_TRUST_CFG_OVERRIDE="$TJ" "$CC/cc-trust.sh" --remove "/real" >/dev/null 2>&1
eq "remove keeps real project" "$(python3 -c "import json;print('/real' in json.load(open('$TJ'))['projects'])")" "True"
rm -rf "$TJ" "$TD"

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

echo "== 5. cc-merge done/is-done =="
"$CC/cc-merge.sh" done "$MR" feat/A1
eq "done sets flag" "$(git -C "$MR" config branch.feat/A1.ccDone)" "true"
"$CC/cc-merge.sh" is-done "$MR" feat/A1 && eq "is-done true" ok ok || eq "is-done true" no ok
"$CC/cc-merge.sh" done "$MR" feat/A1 false
"$CC/cc-merge.sh" is-done "$MR" feat/A1 && eq "is-done false" no ok || eq "is-done false" ok ok

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
# squash CONFLICT into an already-checked-out target must leave that worktree clean (reset --hard, not the no-op merge --abort)
git -C "$MR2" worktree add -q wtP3 -b feat/P3 feat/P >/dev/null
( cd "$MR2/wtP";  printf 'PP\n' > clash2.txt; git add clash2.txt; git commit -q -m pclash )
( cd "$MR2/wtP3"; printf 'P3\n' > clash2.txt; git add clash2.txt; git commit -q -m p3clash )
"$CC/cc-merge.sh" do-merge "$MR2" feat/P3 squash feat/P >/dev/null 2>&1; eq "squash-conflict exit1" "$?" "1"
eq "target worktree clean after squash-conflict abort" "$(git -C "$MR2/wtP" status --porcelain | wc -l | tr -d ' ')" "0"
# Fix A: re-merging an already-squash-merged child is a benign skip, not a conflict (idempotent gwt-collect)
OUT2="$("$CC/cc-merge.sh" do-merge "$MR2" feat/P1 squash feat/P 2>&1)"; eq "already-merged squash exit0" "$?" "0"
eq "already-merged reports skipped" "$(echo "$OUT2" | grep -c 'skipped:')" "1"
b4=$(git -C "$MR2" rev-list --count feat/P)
"$CC/cc-merge.sh" do-merge "$MR2" feat/P1 squash feat/P >/dev/null 2>&1
eq "already-merged adds no commit" "$(( $(git -C "$MR2" rev-list --count feat/P) - b4 ))" "0"
# Fix B: rebase of a child checked out in its own worktree is refused with a clear message
"$CC/cc-merge.sh" do-merge "$MR2" feat/P2 rebase feat/P > /tmp/cctest-rb.txt 2>&1; eq "rebase-unsupported exit4" "$?" "4"
eq "rebase-unsupported message" "$(grep -c 'rebase-unsupported:' /tmp/cctest-rb.txt)" "1"
rm -f /tmp/cctest-rb.txt

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

echo "== 12. cc-merge trunk =="
eq "trunk is main" "$("$CC/cc-merge.sh" trunk "$MR")" "main"

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

echo "== 14. cc-worktree-shared seed/collect =="
SR=$(mktemp -d); ( cd "$SR"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git worktree add -q wtL -b feat/L >/dev/null )
SROOT="$(cd "$SR" && pwd -P)"; WT="$SR/wtL"
mkdir -p "$SROOT/scratchpad/e2e/lib" "$SROOT/scratchpad/e2e/a1-shots"
printf 'MAIN\n'  > "$SROOT/scratchpad/e2e/lib/harness.mjs"
printf 'same\n'  > "$SROOT/scratchpad/e2e/existing.mjs"
printf 'png\n'   > "$SROOT/scratchpad/e2e/a1-shots/x.png"
# seed: copies corpus into worktree, excluding regenerable outputs
"$CC/cc-worktree-shared.sh" seed "$SROOT" "$WT" scratchpad/e2e >/dev/null 2>&1
eq "seed copies harness"        "$(cat "$WT/scratchpad/e2e/lib/harness.mjs" 2>/dev/null)" "MAIN"
eq "seed copies existing"       "$(cat "$WT/scratchpad/e2e/existing.mjs" 2>/dev/null)" "same"
eq "seed excludes *-shots"      "$( [ -e "$WT/scratchpad/e2e/a1-shots" ] && echo yes || echo no )" "no"
# in worktree: add a new test, diverge the harness (conflict), keep existing identical, add an output
printf 'new\n' > "$WT/scratchpad/e2e/newtest.mjs"
printf 'WT\n'  > "$WT/scratchpad/e2e/lib/harness.mjs"
mkdir -p "$WT/scratchpad/e2e/b1-shots"; printf 'png2\n' > "$WT/scratchpad/e2e/b1-shots/y.png"
# collect: fold new work back into main
"$CC/cc-worktree-shared.sh" collect "$SROOT" "$WT" scratchpad/e2e >/dev/null 2>&1
eq "collect folds new file"     "$(cat "$SROOT/scratchpad/e2e/newtest.mjs" 2>/dev/null)" "new"
eq "collect never overwrites main" "$(cat "$SROOT/scratchpad/e2e/lib/harness.mjs" 2>/dev/null)" "MAIN"
eq "collect preserves conflict" "$(cat "$SROOT/scratchpad/e2e/lib/harness.from-feat-L.mjs" 2>/dev/null)" "WT"
eq "collect excludes *-shots"   "$( [ -e "$SROOT/scratchpad/e2e/b1-shots" ] && echo yes || echo no )" "no"
# regression: glob-char filenames must never glob-expand (x[1].mjs used to vanish when x1.mjs existed)
printf 'BR\n' > "$WT/scratchpad/e2e/x[1].mjs"
printf 'PL\n' > "$WT/scratchpad/e2e/x1.mjs"
"$CC/cc-worktree-shared.sh" collect "$SROOT" "$WT" scratchpad/e2e >/dev/null 2>&1
eq "collect keeps bracket-name file" "$(cat "$SROOT/scratchpad/e2e/x[1].mjs" 2>/dev/null)" "BR"
eq "collect keeps its glob sibling"  "$(cat "$SROOT/scratchpad/e2e/x1.mjs" 2>/dev/null)" "PL"
# regression: trailing slash in relbase must not mangle target paths
mkdir -p "$SROOT/shareX"; printf 'ts\n' > "$SROOT/shareX/t.mjs"
"$CC/cc-worktree-shared.sh" seed "$SROOT" "$WT" "shareX/" >/dev/null 2>&1
eq "seed tolerates trailing slash" "$(cat "$WT/shareX/t.mjs" 2>/dev/null)" "ts"
# no <relbase> args → default corpus from cc-worktree-shared.sh itself; exported-EMPTY disables
( cd "$SR"; git worktree add -q wtM -b feat/M >/dev/null; git worktree add -q wtN -b feat/N >/dev/null )
env -u CC_WT_SHARE "$CC/cc-worktree-shared.sh" seed "$SROOT" "$SR/wtM" >/dev/null 2>&1
eq "no-arg seed uses default corpus" "$(cat "$SR/wtM/scratchpad/e2e/existing.mjs" 2>/dev/null)" "same"
CC_WT_SHARE= "$CC/cc-worktree-shared.sh" seed "$SROOT" "$SR/wtN" >/dev/null 2>&1
eq "empty CC_WT_SHARE disables seed" "$( [ -e "$SR/wtN/scratchpad/e2e" ] && echo yes || echo no )" "no"
# zsh side: an exported-empty CC_WT_SHARE must survive sourcing (docs say empty disables)
eq "zsh keeps empty CC_WT_SHARE" "$(CC_WT_SHARE= zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; printf '%s' \"\$CC_WT_SHARE\"")" ""
# gwt-claude + hook both go through the surface script → it must be the one seeding
grep -q 'cc-worktree-shared.sh" seed' "$CC/cc-cmux-surface-claude.sh" && ok "surface script seeds corpus" || no "surface script seeds corpus" missing present
rm -rf "$SR"

echo ""
echo "== 12. gwt-adopt (enroll an existing branch into the tree) =="
AR=$(mktemp -d); ( cd "$AR"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  mkdir .claude                        # so _gwt_dir resolves to .claude/worktrees
  git branch feature/orphan-x; git branch feature/orphan-y )
# register-only: sets parent to the trunk, makes NO worktree, appears in the tree
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-adopt feature/orphan-x --no-worktree" >/dev/null 2>&1
eq "adopt --no-worktree parent=trunk" "$(git -C "$AR" config branch.feature/orphan-x.ccMergeInto)" "main"
eq "adopt --no-worktree makes no wt"  "$(git -C "$AR" worktree list | wc -l | tr -d ' ')" "1"
# gwt-tree enumerates WORKTREES, so a register-only branch is intentionally not in it yet
eq "no-worktree branch not in tree"   "$("$CC/cc-merge.sh" tree "$AR" | awk -F'\t' '$1=="feature/orphan-x"{print $2}')" ""
# full adopt with --into a non-trunk parent: sets parent + creates a sanitized worktree
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-adopt feature/orphan-y --into feature/orphan-x" >/dev/null 2>&1
eq "adopt --into sets the parent"     "$(git -C "$AR" config branch.feature/orphan-y.ccMergeInto)" "feature/orphan-x"
eq "adopt creates a worktree"         "$(git -C "$AR" worktree list | wc -l | tr -d ' ')" "2"
eq "adopt worktree dir sanitized"     "$([ -d "$AR/.claude/worktrees/feature-orphan-y" ] && echo yes || echo no)" "yes"
# a worktree'd adopt DOES appear in the tree, hung under the given parent
eq "worktreed adopt is in the tree"   "$("$CC/cc-merge.sh" tree "$AR" | awk -F'\t' '$1=="feature/orphan-y"{print $2}')" "feature/orphan-x"
# guards: a missing branch writes no config; the trunk cannot be adopted
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-adopt no/such" >/dev/null 2>&1
eq "adopt rejects missing branch"     "$(git -C "$AR" config branch.no/such.ccMergeInto 2>/dev/null)" ""
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-adopt main" >/dev/null 2>&1; arc=$?
eq "adopt rejects the trunk"          "$arc" "1"
rm -rf "$AR"

echo ""
echo "== syntax =="
for s in "$CC"/*.sh; do bash -n "$s" && : || { echo "  ✗ syntax $s"; fail=$((fail+1)); }; done
zsh -n "$CC/worktree.zsh" && ok "worktree.zsh syntax" || { no "worktree.zsh syntax" x x; }

echo ""
echo "== 10. zsh commands present =="
for fn in gwt-tree gwt-done gwt-undone gwt-merge gwt-collect gwt-adopt; do
  grep -q "^$fn()" "$CC/worktree.zsh" && ok "$fn defined" || no "$fn defined" missing present
done

echo "== 11. docs mention new commands =="
grep -q "gwt-merge" "$CC/worktree.zsh" && grep -q "gwt-merge" "$CC/README.md" \
  && ok "gwt-merge documented" || no "gwt-merge documented" missing present
grep -q "gwt-done" "$CC/README.md" && ok "gwt-done documented" || no "gwt-done documented" missing present
grep -q "gwt-adopt" "$CC/README.md" && ok "gwt-adopt documented" || no "gwt-adopt documented" missing present

echo ""
echo "result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
