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

echo ""
echo "== syntax =="
for s in "$CC"/*.sh; do bash -n "$s" && : || { echo "  ✗ syntax $s"; fail=$((fail+1)); }; done
zsh -n "$CC/worktree.zsh" && ok "worktree.zsh syntax" || { no "worktree.zsh syntax" x x; }

echo ""
echo "result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
