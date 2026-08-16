#!/usr/bin/env bash
# cc-stack · smoke test (pure logic, no real cmux tab needed). Guards the regressions we've hit:
#   hook parsing (A path / B cross-repo / $VAR fallback / non-add-doesn't-trigger / CC_WT_PROMPT), tasks-log, prune/drop, trust add/remove,
#   status-hook (agent-state sidecar writes, Notification classification, gwt-status rendering, install registration).
# Usage: bash ~/.config/cc-stack/test.sh
set -u
# Test the copy of cc-stack this script lives in (a worktree checkout tests itself), fallback to the default install.
CC="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)"; CC="${CC:-$HOME/.config/cc-stack}"
pass=0; fail=0
ok(){ echo "  ✔ $1"; pass=$((pass+1)); }
no(){ echo "  ✗ $1  expected[$3] got[$2]"; fail=$((fail+1)); }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

echo "== 1. hook parser =="
# extract the worktree python (the ONLY <<'PY' heredoc in cc-hooks.sh)
awk "/<<'PY'/{f=1;next} /^PY\$/{f=0} f" "$CC/cc-hooks.sh" > /tmp/cctest-ep.py
run(){ CC_HOOK_INPUT="$1" python3 /tmp/cctest-ep.py 2>/dev/null; }
pay(){ python3 -c "import json,sys;print(json.dumps({'tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':sys.argv[2]}}))" "$1" "$2"; }
R1=$(mktemp -d); ( cd "$R1"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  git worktree add -q wtC -b feat/C >/dev/null; git worktree add -q wtD -b feat/D >/dev/null )
touch "$R1/wtD/x"; touch "$R1/wtD"
C="$(cd "$R1/wtC" && pwd -P)"
eq "A parsed-path beats mtime" "$(run "$(pay "$R1" 'git worktree add wtC -b feat/C')" | cut -f1)" "$C"
eq "A -b before path"          "$(run "$(pay "$R1" 'git worktree add -b feat/C wtC')" | cut -f1)" "$C"
eq "CC_WT_PROMPT extraction"   "$(run "$(pay "$R1" "CC_WT_PROMPT='doX' git worktree add wtC")" | cut -f3)" "doX"
eq "CC_WT_PERMISSION_MODE extraction" "$(run "$(pay "$R1" "CC_WT_PERMISSION_MODE=plan CC_WT_PROMPT='doX' git worktree add wtC")" | cut -f2)" "plan"
# anti-double-tab skip must test only the REAL command: a brief that merely MENTIONS a script name
# (inside the single-quoted CC_WT_PROMPT payload) still dispatches; a command that actually invokes
# cc-dispatch.sh wt-claude opens its own tab, so the hook must not open a second one
eq "brief naming scripts dispatches" "$(run "$(pay "$R1" "CC_WT_PROMPT='read cc-dispatch.sh cc-worktree-claude.sh cc-cmux-surface-claude.sh first' git worktree add wtC")" | cut -f1)" "$C"
eq "dispatcher command skipped"     "$(run "$(pay "$R1" "CC_WT_PROMPT='seed corpus' cc-dispatch.sh wt-claude wtC && git worktree add wtC -b feat/C")" | cut -f1)" ""
R2=$(mktemp -d); ( cd "$R2"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git worktree add -q wtX -b feat/X >/dev/null )
X="$(cd "$R2/wtX" && pwd -P)"
eq "B cross-repo -C"           "$(run "$(pay "$R1" "git -C $R2 worktree add wtX")" | cut -f1)" "$X"
eq "non-add (list) no trigger"   "$(run "$(pay "$R1" 'git worktree list')")" ""
eq "non-add (remove) no trigger" "$(run "$(pay "$R1" 'git worktree remove wtC')")" ""
# $VAR fallback: invalid repo falls back to cwd, unmatched path falls back to mtime (newest = wtD, which we touched)
D="$(cd "$R1/wtD" && pwd -P)"
eq "\$VAR fallback (to mtime)"  "$(run "$(pay "$R1" 'git -C $root worktree add $root/wtNope')" | cut -f1)" "$D"
rm -rf "$R1" "$R2" /tmp/cctest-ep.py

echo "== 2. cc-board.sh log (task registration) =="
export CC_TASKS_FILE=$(mktemp -u)
"$CC/cc-board.sh" log "/tmp/nodir_A" "surface:1" "surface:9" "task	with tab|pipe" "feat/par" "uuid=11111111-2222-3333-4444-555555555555:provider=kimi:pm=plan:model=glm-4.6"
eq "writes 8 fields"          "$(awk -F'\t' 'NR==1{print NF}' "$CC_TASKS_FILE")" "8"
eq "7th field is parent"      "$(awk -F'\t' 'NR==1{print $7}' "$CC_TASKS_FILE")" "feat/par"
eq "8th field is launch-args" "$(awk -F'\t' 'NR==1{print $8}' "$CC_TASKS_FILE")" "uuid=11111111-2222-3333-4444-555555555555:provider=kimi:pm=plan:model=glm-4.6"
eq "task sanitized (no tab)"  "$(awk -F'\t' 'NR==1{print ($6 ~ /\t/)?"bad":"ok"}' "$CC_TASKS_FILE")" "ok"
# launch-args sanitization: a TAB inside the value must never split the row
"$CC/cc-board.sh" log "/tmp/nodir_B" "surface:2" "surface:9" "t2" "feat/p2" "uuid=u1:provider=kimi:pm=auto	mod"
eq "launch-args sanitized"    "$(awk -F'\t' 'NR==2{print NF}' "$CC_TASKS_FILE")" "8"
# round-trip: a logged row renders on the board (dir must exist — prune-on-read drops dead dirs;
# --all so the repo filter can't hide the foreign row)
RT=$(mktemp -d)
"$CC/cc-board.sh" log "$RT" "surface:2" "surface:1" "round trip task" "feat/rt"
eq "log→board round-trip" "$(CC_TASKS_FILE="$CC_TASKS_FILE" CC_STATUS_FILE=/dev/null bash "$CC/cc-board.sh" --all 2>/dev/null | grep -c 'round trip task')" "1"
# pre-feature 7-field rows: survive the prune-on-read rewrite VERBATIM (bash read gives the last
# variable the remainder with its TABs, so nothing shifts) and still render
RT2=$(mktemp -d); CRT2="$(cd "$RT2" && pwd -P)"
printf '2026-01-01 00:00:00\tfeat/OLD\tsurface:7\t%s\tsurface:1\told row task\tmain\n' "$CRT2" >> "$CC_TASKS_FILE"
CC_STATUS_FILE=/dev/null bash "$CC/cc-board.sh" --all >/dev/null 2>&1
eq "old 7-field row kept"     "$(awk -F'\t' -v d="$CRT2" '$4==d{print NF}' "$CC_TASKS_FILE" | sort -u)" "7"
eq "old row still renders"    "$(CC_TASKS_FILE="$CC_TASKS_FILE" CC_STATUS_FILE=/dev/null bash "$CC/cc-board.sh" --all 2>/dev/null | grep -c 'old row task')" "1"
rm -rf "$RT" "$RT2"; rm -f "$CC_TASKS_FILE"; unset CC_TASKS_FILE

echo "== 2b. cc-hooks.sh status: agent-state sidecar =="
# Board rows must hold pwd -P-canonical dirs — exactly what cc-board.sh log writes in production
# (mktemp hands back /var/... which pwd -P resolves to /private/var/... on macOS).
cn(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
SB="$(cn "$(mktemp -d)")"; NB="$(cn "$(mktemp -d)")"; RD="$(cn "$(mktemp -d)")"   # SB: board dir  NB: not on the board  RD: render-only
export CC_TASKS_FILE=$(mktemp -u) CC_STATUS_FILE=$(mktemp -u)
printf '2026-01-01 00:00:00\tfeat/B\tsurface:2\t%s\tsurface:1\tdo B\n' "$SB" > "$CC_TASKS_FILE"
hj(){ python3 -c 'import json,sys; print(json.dumps({"hook_event_name":sys.argv[1],"cwd":sys.argv[2],"message":sys.argv[3]}))' "$1" "$2" "$3"; }
hr(){ printf '%s' "$1" | "$CC/cc-hooks.sh" status 2>&1; }               # hook runner: stdout+stderr together
hs(){ local o rc; o="$(hr "$1")"; rc=$?; eq "$2 silent" "$o" ""; eq "$2 exit0" "$rc" "0"; }   # HARD RULES: prints nothing, exits 0 — every path
hs "$(hj UserPromptSubmit "$SB" '')" "UPS board-dir"
eq "UPS writes working"        "$(awk -F'\t' -v d="$SB" '$1==d{print $2}' "$CC_STATUS_FILE")" "working"
eq "ts is unix epoch"          "$(awk -F'\t' -v d="$SB" '$1==d{print ($3 ~ /^[0-9]+$/)?"ok":"no"}' "$CC_STATUS_FILE")" "ok"
hs "$(hj Stop "$SB" '')" "Stop board-dir"
eq "Stop updates to idle"      "$(awk -F'\t' -v d="$SB" '$1==d{print $2}' "$CC_STATUS_FILE")" "idle"
eq "one row per dir"           "$(wc -l < "$CC_STATUS_FILE" | tr -d ' ')" "1"
hs "$(hj Notification "$SB" 'Claude needs your permission to use Bash')" "permission notification"
eq "permission → blocked"      "$(awk -F'\t' -v d="$SB" '$1==d{print $2}' "$CC_STATUS_FILE")" "blocked"
tsb=$(awk -F'\t' -v d="$SB" '$1==d{print $3}' "$CC_STATUS_FILE"); sleep 1
hs "$(hj Notification "$SB" 'Task completed successfully')" "non-permission notification"
eq "non-perm keeps state"      "$(awk -F'\t' -v d="$SB" '$1==d{print $2}' "$CC_STATUS_FILE")" "blocked"
eq "non-perm keeps ts"         "$(awk -F'\t' -v d="$SB" '$1==d{print $3}' "$CC_STATUS_FILE")" "$tsb"
hs "$(hj UserPromptSubmit "$NB" '')" "UPS non-board-dir"
eq "non-board dir writes no row" "$(grep -cF "$NB" "$CC_STATUS_FILE")" "0"
hs "not json" "malformed stdin"
hs "" "empty stdin"
# gwt-status rendering against a fabricated tasks+status pair: working/idle/blocked with age, dash when no row
# (--all: cc-board.sh filters rows to the caller's repo by default; the fabricated dirs live outside it)
RD2="$(cn "$(mktemp -d)")"; RD3="$(cn "$(mktemp -d)")"
printf '2026-01-01 00:00:00\tfeat/Q\tsurface:4\t%s\tsurface:1\tno status row\n' "$RD"  >> "$CC_TASKS_FILE"
printf '2026-01-01 00:00:00\tfeat/R\tsurface:5\t%s\tsurface:1\trender R\n' "$RD2" >> "$CC_TASKS_FILE"
printf '2026-01-01 00:00:00\tfeat/S\tsurface:6\t%s\tsurface:1\trender S\n' "$RD3" >> "$CC_TASKS_FILE"
now=$(date +%s)
printf '%s\tworking\t%s\n%s\tidle\t%s\n%s\tblocked\t%s\n' "$RD" $((now-23*60)) "$RD2" $((now-2*3600)) "$RD3" $((now-5*60)) > "$CC_STATUS_FILE"
ROUT="$(CC_TASKS_FILE="$CC_TASKS_FILE" CC_STATUS_FILE="$CC_STATUS_FILE" zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-status --all" 2>/dev/null)"
eq "render working(23m)"  "$(echo "$ROUT" | grep -c 'working(23m)')" "1"
eq "render idle(2h)"      "$(echo "$ROUT" | grep -c 'idle(2h)')" "1"
eq "render blocked(5m)"   "$(echo "$ROUT" | grep -c 'blocked(5m)')" "1"
eq "render dash w/o row"  "$(echo "$ROUT" | grep -F "$SB" | grep -c ' - ')" "1"
eq "header has TAB+STATUS" "$(echo "$ROUT" | head -1 | grep -c 'TAB.*STATUS')" "1"
# gwt-prune sweeps status rows whose dir no longer exists (sidecar stays consistent with the board)
rm -rf "$RD3"
CC_TASKS_FILE="$CC_TASKS_FILE" CC_STATUS_FILE="$CC_STATUS_FILE" zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-prune" >/dev/null 2>&1
eq "prune sweeps dead status row" "$(grep -cF "$RD3" "$CC_STATUS_FILE")" "0"
eq "prune keeps live status rows" "$(wc -l < "$CC_STATUS_FILE" | tr -d ' ')" "2"
# gwt-rm drops the status row of the removed dir (same bookkeeping as the task list)
RR=$(mktemp -d); ( cd "$RR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wtS -b feat/S >/dev/null )
SW="$(cd "$RR/.claude/worktrees/wtS" && pwd -P)"
printf '%s\tidle\t%s\n' "$SW" "$(date +%s)" >> "$CC_STATUS_FILE"
CC_TASKS_FILE="$CC_TASKS_FILE" CC_STATUS_FILE="$CC_STATUS_FILE" zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$RR'; gwt-rm wtS" >/dev/null 2>&1
eq "gwt-rm drops status row" "$(grep -cF "$SW" "$CC_STATUS_FILE" 2>/dev/null)" "0"
# install.sh registers the cc-hooks.sh subcommands idempotently and strips stale
# registrations from pre-refactor installs (cc-notify + the two absorbed hook scripts)
IH=$(mktemp -d)
HOME="$IH" bash "$CC/install.sh" --yes --dir "$IH/cc" >/dev/null 2>&1
sn(){ python3 -c 'import json,sys
d=json.load(open(sys.argv[1]+"/.claude/settings.json"))
print(sum(1 for g in d.get("hooks",{}).get(sys.argv[2],[]) or [] for h in (g.get("hooks") or []) if sys.argv[3] in (h.get("command") or "")))' "$IH" "$1" "$2"; }
eq "install registers PostToolUse worktree" "$(sn PostToolUse "cc-hooks.sh worktree")" "1"
eq "install registers UserPromptSubmit"    "$(sn UserPromptSubmit "cc-hooks.sh status")" "1"
eq "install registers Stop"                "$(sn Stop "cc-hooks.sh status")" "1"
eq "install registers Notification"        "$(sn Notification "cc-hooks.sh status")" "1"
HOME="$IH" bash "$CC/install.sh" --yes --dir "$IH/cc" >/dev/null 2>&1
eq "re-install adds no duplicate" "$(sn UserPromptSubmit "cc-hooks.sh status")+$(sn Stop "cc-hooks.sh status")+$(sn Notification "cc-hooks.sh status")" "1+1+1"
# stale registrations (what a pre-refactor install would still carry): seeded, then stripped
python3 -c 'import json,sys
p=sys.argv[1]+"/.claude/settings.json"
d={"hooks":{
 "PostToolUse":[{"matcher":"Bash|EnterWorktree","hooks":[{"type":"command","command":"~/old/cc-worktree-cmux-hook.sh"}]}],
 "UserPromptSubmit":[{"hooks":[{"type":"command","command":"~/old/cc-status-hook.sh"}]}],
 "Stop":[{"hooks":[{"type":"command","command":"~/old/cc-status-hook.sh"},{"type":"command","command":"~/old/cc-notify.sh"}]}],
 "Notification":[{"hooks":[{"type":"command","command":"~/old/cc-status-hook.sh"}]}]}}
json.dump(d,open(p,"w"))' "$IH"
HOME="$IH" bash "$CC/install.sh" --yes --dir "$IH/cc" >/dev/null 2>&1
eq "strip removes stale PostToolUse"  "$(sn PostToolUse "cc-worktree-cmux-hook.sh")" "0"
eq "strip removes stale status hooks" "$(sn UserPromptSubmit "cc-status-hook.sh")+$(sn Stop "cc-status-hook.sh")+$(sn Notification "cc-status-hook.sh")" "0+0+0"
eq "strip removes stale cc-notify"    "$(sn Stop "cc-notify")" "0"
eq "strip keeps new registration"     "$(sn Stop "cc-hooks.sh status")" "1"
HOME="$IH" bash "$CC/install.sh" --yes --dir "$IH/cc" >/dev/null 2>&1
eq "re-install after strip is stable" "$(sn PostToolUse "cc-hooks.sh worktree")+$(sn Stop "cc-hooks.sh status")" "1+1"
rm -rf "$IH" "$RR" "$SB" "$NB" "$RD" "$RD2"; rm -f "$CC_TASKS_FILE" "$CC_STATUS_FILE"; unset CC_TASKS_FILE CC_STATUS_FILE

echo ""
echo "== 2c. cc-board: the board from ANY shell (bash-direct, no zsh) =="
cn(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
# fixture repo: two worktree branches with recorded merge parents (+ an unrelated dir as a foreign row)
BRD=$(mktemp -d); ( cd "$BRD"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  git worktree add -q wtW -b feat/W >/dev/null
  git worktree add -q wtW1 -b feat/W1 feat/W >/dev/null )
"$CC/cc-merge.sh" set-parent "$BRD" feat/W main
"$CC/cc-merge.sh" set-parent "$BRD" feat/W1 feat/W
BW="$(cn "$BRD/wtW")"; BW1="$(cn "$BRD/wtW1")"; OTH="$(cn "$(mktemp -d)")"; NORD="$(mktemp -d)"   # OTH: other repo row  NORD: not a repo
export CC_TASKS_FILE=$(mktemp -u) CC_STATUS_FILE=$(mktemp -u) CC_ARCHIVE_FILE=$(mktemp -u)
now=$(date +%s)
printf '2026-01-01 00:00:01\tfeat/W\tsurface:31\t%s\tsurface:1\tboard task W (older)\tmain\n' "$BW"  > "$CC_TASKS_FILE"
printf '2026-01-01 00:00:02\tfeat/W\tsurface:32\t%s\tsurface:1\tboard task W\tmain\n' "$BW" >> "$CC_TASKS_FILE"
printf '2026-01-01 00:00:03\tfeat/W1\tsurface:33\t%s\tsurface:1\tboard task W1\tfeat/W\n' "$BW1" >> "$CC_TASKS_FILE"
printf '2026-01-01 00:00:04\tfeat/X\tsurface:34\t%s\tsurface:1\ttask in another repo\tmain\n' "$OTH" >> "$CC_TASKS_FILE"
printf '%s\tworking\t%s\n%s\tidle\tabc\n' "$BW" $((now-23*60)) "$BW1" > "$CC_STATUS_FILE"
brd(){ ( cd "$1" && bash "$CC/cc-board.sh" ${2:-} ) 2>/dev/null; }            # bash-DIRECT invocation, never via zsh
rowof(){ echo "$1" | awk -v d="$2" '$5==d'; }                                 # board row by DIR column
taskof(){ rowof "$1" "$2" | awk '{$1=$2=$3=$4=$5=""; sub(/^ +/,""); print}'; } # TASK cell = fields after DIR
BO="$(brd "$BRD")"
eq "board header columns"          "$(echo "$BO" | head -1 | tr -s ' ')" "TAB BRANCH PARENT STATUS DIR TASK"
eq "header TAB before STATUS"      "$(echo "$BO" | head -1 | grep -c 'TAB.*STATUS')" "1"
eq "newest row per dir wins"       "$(echo "$BO" | grep -c 'board task W (older)')" "0"
eq "W row TASK cell"               "$(taskof "$BO" "$BW")" "board task W"
eq "W1 row TASK cell"              "$(taskof "$BO" "$BW1")" "board task W1"
eq "PARENT from git config"        "$(rowof "$BO" "$BW"  | awk '{print $3}')" "main"
eq "PARENT feat/W1 from config"    "$(rowof "$BO" "$BW1" | awk '{print $3}')" "feat/W"
eq "STATUS join working(23m)"      "$(rowof "$BO" "$BW"  | awk '{print $4}')" "working(23m)"
eq "malformed ts renders ?"        "$(rowof "$BO" "$BW1" | awk '{print $4}')" "idle(?)"
eq "repo filter hides other repo"  "$(echo "$BO" | grep -c 'task in another repo')" "0"
# PARENT falls back to the 7th TSV field once the git config is gone (branch deleted after merge)
git -C "$BRD" config --unset branch.feat/W1.ccMergeInto
BO2="$(brd "$BRD")"
eq "PARENT falls back to 7th field" "$(rowof "$BO2" "$BW1" | awk '{print $3}')" "feat/W"
# --all disables the filter (and a missing sidecar row still renders a dash STATUS)
BALL="$(brd "$BRD" --all)"
eq "--all shows other repo"        "$(echo "$BALL" | grep -c 'task in another repo')" "1"
eq "dash when no status row"       "$(rowof "$BALL" "$OTH" | awk '{print $4}')" "-"
# outside any repo → no filter
BNR="$( ( cd "$NORD" && bash "$CC/cc-board.sh") 2>/dev/null )"
eq "outside repo shows all"        "$(echo "$BNR" | grep -c 'task in another repo')" "1"
# canonicalization trap: a row stored with the LOGICAL dir (/var/...) must still match the PHYSICAL
# git root (/private/var/...) — both sides get pwd -P before the prefix compare
awk -F'\t' -v OFS='\t' -v p="$BRD" '$2=="feat/W1"{$4=p "/wtW1"} {print}' "$CC_TASKS_FILE" > "$CC_TASKS_FILE.cx" && mv "$CC_TASKS_FILE.cx" "$CC_TASKS_FILE"
eq "logical row dir still shows"   "$(brd "$BRD" | grep -c 'board task W1')" "1"
# prune-on-read: dead-dir rows are dropped from the tasks file by the render itself (mkdir-lock rewrite)
printf '2026-01-01 00:00:05\tfeat/G\tsurface:35\t%s\tsurface:1\tdead dir row\tmain\n' "$BRD/gone" >> "$CC_TASKS_FILE"
brd "$BRD" >/dev/null
eq "prune drops dead-dir row"      "$(grep -c 'dead dir row' "$CC_TASKS_FILE")" "0"
eq "prune keeps live rows"         "$(wc -l < "$CC_TASKS_FILE" | tr -d ' ')" "4"
DF=$(mktemp -u); printf '2026-01-01 00:00:05\tfeat/G\tsurface:35\t%s\tsurface:1\tdead dir row\tmain\n' "/tmp/cc-board-gone-$$" > "$DF"
eq "all-dead message"              "$(CC_TASKS_FILE="$DF" CC_STATUS_FILE=/dev/null bash "$CC/cc-board.sh" 2>/dev/null)" "no registered worktree tasks"
eq "all-dead removes file"         "$([ -f "$DF" ] && echo yes || echo no)" "no"
# _gwt_archive_branch: move ALL rows of a branch to the archive (+ drop their status rows), keep others
TF=$(mktemp -u); SF=$(mktemp -u); AF=$(mktemp -u)
export CC_TASKS_FILE="$TF" CC_STATUS_FILE="$SF" CC_ARCHIVE_FILE="$AF"
printf '2026-01-01 00:00:01\tfeat/W\tsurface:41\t%s\tsurface:1\tarch task W1\tmain\n' "$BW"  > "$TF"
printf '2026-01-01 00:00:02\tfeat/W\tsurface:42\t%s\tsurface:1\tarch task W2\tmain\n' "$BRD" >> "$TF"
printf '2026-01-01 00:00:03\tfeat/W1\tsurface:43\t%s\tsurface:1\tarch task W1b\tfeat/W\n' "$BW1" >> "$TF"
# new-format row (8 live fields incl. launch-args) → archive must gain 9 fields, args intact
printf '2026-01-01 00:00:04\tfeat/W\tsurface:47\t%s\tsurface:1\tarch task W3\tmain\tuuid=99999999-8888-7777-6666-555555555555:provider=glm:pm=auto:model=g1\n' "$BRD" >> "$TF"
printf '%s\tidle\t%s\n' "$BW" "$now" > "$SF"; printf '%s\tidle\t%s\n' "$BRD" "$now" >> "$SF"; printf '%s\tidle\t%s\n' "$BW1" "$now" >> "$SF"
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; CC_TASKS_FILE='$TF' CC_STATUS_FILE='$SF' CC_ARCHIVE_FILE='$AF' _gwt_archive_branch feat/W" >/dev/null 2>&1
eq "archive moves ALL branch rows"   "$(awk -F'\t' '$2=="feat/W"' "$TF" | wc -l | tr -d ' ')" "0"
eq "other branch stays"              "$(awk -F'\t' '$2=="feat/W1"' "$TF" | wc -l | tr -d ' ')" "1"
eq "archive gained all rows"         "$(awk -F'\t' '$2=="feat/W"' "$AF" | wc -l | tr -d ' ')" "3"
eq "archive old rows have 8 fields"  "$(awk -F'\t' 'NR==1{print NF}' "$AF")" "8"
eq "archive new row has 9 fields"    "$(awk -F'\t' '$2=="feat/W" && $6=="arch task W3"{print NF}' "$AF")" "9"
eq "archive keeps launch-args"       "$(awk -F'\t' '$2=="feat/W" && $8 ~ /^uuid=/{c++} END{print c+0}' "$AF")" "1"
eq "merged-at is a unix ts"          "$(awk -F'\t' '$2=="feat/W"{print ($NF ~ /^[0-9]+$/)?"ok":"no"}' "$AF" | sort -u)" "ok"
eq "moved status rows dropped"       "$(awk -F'\t' -v a="$BW" -v b="$BRD" '$1==a||$1==b{c++} END{print c+0}' "$SF")" "0"
eq "other status row kept"           "$(awk -F'\t' -v d="$BW1" '$1==d{c++} END{print c+0}' "$SF")" "1"
# gwt-merge archives on success (and on skipped-already-merged, same rc 0 path)
"$CC/cc-merge.sh" set-parent "$BRD" feat/W1 feat/W
"$CC/cc-merge.sh" done "$BRD" feat/W1 true
( cd "$BRD/wtW1" && git commit -q --allow-empty -m w1 )
printf '\ny\n' | zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$BRD'; CC_TASKS_FILE='$TF' CC_STATUS_FILE='$SF' CC_ARCHIVE_FILE='$AF' gwt-merge feat/W1" >/dev/null 2>&1; gmrc=$?
eq "gwt-merge exit 0"                "$gmrc" "0"
eq "merge archives branch rows"      "$(awk -F'\t' '$2=="feat/W1"' "$TF" 2>/dev/null | wc -l | tr -d ' ')" "0"
eq "merge appends to archive"        "$(awk -F'\t' '$2=="feat/W1"' "$AF" | wc -l | tr -d ' ')" "1"
# gwt-log renders the archive: same columns, same repo filter
printf '2026-01-01 00:00:09\tfeat/Y\tsurface:44\t%s\tsurface:1\tarch other repo\tmain\n' "$OTH" >> "$AF"
LO="$(brd "$BRD" --archive)"
eq "gwt-log header"                  "$(echo "$LO" | head -1 | tr -s ' ')" "TAB BRANCH PARENT STATUS DIR TASK"
eq "gwt-log shows archive"           "$(echo "$LO" | grep -c 'arch task W2')" "1"
eq "gwt-log PARENT not shifted"      "$(rowof "$LO" "$BW" | awk '{print $3}')" "main"
eq "gwt-log repo filter"             "$(echo "$LO" | grep -c 'arch other repo')" "0"
eq "gwt-log --all"                   "$(brd "$BRD" "--archive --all" | grep -c 'arch other repo')" "1"
LOW="$( ( cd "$BRD" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-log") 2>/dev/null )"
eq "gwt-log wrapper renders"         "$(echo "$LOW" | grep -c 'arch task W2')" "1"
# gwt-status wrapper: forwards to bash cc-board.sh, filter + STATUS join intact end-to-end
printf '2026-01-01 00:00:06\tfeat/W\tsurface:45\t%s\tsurface:1\twrap task W\tmain\n' "$BW"  > "$CC_TASKS_FILE"
printf '2026-01-01 00:00:07\tfeat/X\tsurface:46\t%s\tsurface:1\twrap other\tmain\n' "$OTH" >> "$CC_TASKS_FILE"
printf '%s\tworking\t%s\n' "$BW" $((now-23*60)) > "$CC_STATUS_FILE"
SW="$( ( cd "$BRD" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-status") 2>/dev/null )"
eq "gwt-status wrapper renders"      "$(echo "$SW" | grep -c 'wrap task W')" "1"
eq "wrapper STATUS join"             "$(echo "$SW" | grep -c 'working(23m)')" "1"
eq "wrapper applies repo filter"     "$(echo "$SW" | grep -c 'wrap other')" "0"
SWA="$( ( cd "$BRD" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-status --all") 2>/dev/null )"
eq "wrapper forwards --all"          "$(echo "$SWA" | grep -c 'wrap other')" "1"
rm -rf "$BRD" "$OTH" "$NORD"; rm -f "$CC_TASKS_FILE" "$CC_STATUS_FILE" "$CC_ARCHIVE_FILE" "$TF" "$SF" "$AF" "$DF"; unset CC_TASKS_FILE CC_STATUS_FILE CC_ARCHIVE_FILE

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
# Defect 1/rebase: a child checked out in its own (clean) worktree is rebased THERE, not refused
git -C "$MR2" worktree add -q wtR -b feat/R feat/P >/dev/null
git -C "$MR2" worktree add -q wtR1 -b feat/R1 feat/R >/dev/null
( cd "$MR2/wtR1"; printf 'r1\n' > r1.txt; git add r1.txt; git commit -q -m r1 )
( cd "$MR2/wtR";  printf 'rr\n' > r.txt;  git add r.txt;  git commit -q -m r )   # target moves after R1 forked
"$CC/cc-merge.sh" do-merge "$MR2" feat/R1 rebase feat/R >/dev/null 2>&1; eq "rebase-in-worktree exit0" "$?" "0"
eq "rebase lands child tip on target" "$(git -C "$MR2" rev-parse feat/R)" "$(git -C "$MR2" rev-parse feat/R1)"
eq "rebase brought the file"          "$(git -C "$MR2" show feat/R:r1.txt 2>/dev/null)" "r1"
# no worktree holds the child → the rebase still runs from the repo itself
git -C "$MR2" worktree add -q wtR2 -b feat/R2 feat/R >/dev/null
( cd "$MR2/wtR2"; printf 'r2\n' > r2.txt; git add r2.txt; git commit -q -m r2 )
git -C "$MR2" worktree remove wtR2 >/dev/null 2>&1     # branch survives, checked out nowhere
"$CC/cc-merge.sh" do-merge "$MR2" feat/R2 rebase feat/R >/dev/null 2>&1; eq "rebase no-worktree exit0" "$?" "0"
eq "no-worktree rebase fast-forwards" "$(git -C "$MR2" rev-parse feat/R)" "$(git -C "$MR2" rev-parse feat/R2)"
# a DIRTY child worktree is refused cleanly (new rc) before anything moves
git -C "$MR2" worktree add -q wtR3 -b feat/R3 feat/R >/dev/null
( cd "$MR2/wtR3"; printf 'r3\n' > r3.txt; git add r3.txt; git commit -q -m r3; printf 'dirt\n' > dirty.txt )
"$CC/cc-merge.sh" do-merge "$MR2" feat/R3 rebase feat/R > /tmp/cctest-rb.txt 2>&1; eq "rebase-dirty exit5" "$?" "5"
eq "rebase-dirty message"    "$(grep -c 'rebase-dirty:' /tmp/cctest-rb.txt)" "1"
eq "rebase-dirty target unmoved" "$(git -C "$MR2" rev-parse feat/R)" "$(git -C "$MR2" rev-parse feat/R2)"
rm -f /tmp/cctest-rb.txt

echo "== 8b. do-merge × commit-msg hook (Defect 1: conventional defaults + failure triage) =="
MR3=$(mktemp -d); ( cd "$MR3"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  git worktree add -q wtT -b feat/T >/dev/null
  git -C wtT commit -q --allow-empty -m t
  git worktree add -q wtT1 -b feat/T1 feat/T >/dev/null
  cd wtT1; printf 'one\n' > f1.txt; git add f1.txt; git commit -q -m 'chore: t1' )
"$CC/cc-merge.sh" set-parent "$MR3" feat/T1 feat/T
# commit-msg hook enforcing Conventional Commits on the subject (like the downstream monorepo)
cat > "$MR3/.git/hooks/commit-msg" <<'HOOK'
#!/usr/bin/env bash
head -1 "$1" | grep -qE '^(feat|fix|refactor|test|docs|chore|perf|build|ci|style)(\([a-z0-9/-]+\))?: .' || {
  echo "subject must follow Conventional Commits: <type>(<scope>): <subject>" >&2; exit 1; }
HOOK
chmod +x "$MR3/.git/hooks/commit-msg"
# (a) default message passes the hook and merges; content asserted (+ (g) Child-Tip trailer)
OUT="$("$CC/cc-merge.sh" do-merge "$MR3" feat/T1 squash feat/T)"; rc=$?
eq "hooked squash exit0" "$rc" "0"
eq "squash default subject" "$(git -C "$MR3" log -1 --format=%s feat/T)" "chore: merge feat/T1 into feat/T (squash)"
want_tip="$(git -C "$MR3" rev-parse feat/T1)"
eq "squash Child-Tip trailer" "$(git -C "$MR3" log -1 --format=%B feat/T | grep -c "Child-Tip: $want_tip")" "1"
git -C "$MR3" worktree add -q wtT2 -b feat/T2 feat/T >/dev/null
( cd "$MR3/wtT2"; printf 'two\n' > f2.txt; git add f2.txt; git commit -q -m 'chore: t2' )
"$CC/cc-merge.sh" do-merge "$MR3" feat/T2 no-ff feat/T >/dev/null; eq "hooked no-ff exit0" "$?" "0"
eq "no-ff default subject" "$(git -C "$MR3" log -1 --format=%s feat/T)" "chore: merge feat/T2 into feat/T"
# (b) overrides: --message flag > CC_MERGE_MESSAGE env > default (override is used verbatim)
git -C "$MR3" worktree add -q wtT3 -b feat/T3 feat/T >/dev/null
( cd "$MR3/wtT3"; printf 'three\n' > f3.txt; git add f3.txt; git commit -q -m 'chore: t3' )
CC_MERGE_MESSAGE='chore(env): env beats default' "$CC/cc-merge.sh" do-merge "$MR3" feat/T3 squash feat/T >/dev/null
eq "CC_MERGE_MESSAGE override" "$(git -C "$MR3" log -1 --format=%s feat/T)" "chore(env): env beats default"
git -C "$MR3" worktree add -q wtT4 -b feat/T4 feat/T >/dev/null
( cd "$MR3/wtT4"; printf 'four\n' > f4.txt; git add f4.txt; git commit -q -m 'chore: t4' )
CC_MERGE_MESSAGE='chore(env): should lose' "$CC/cc-merge.sh" do-merge "$MR3" feat/T4 squash feat/T --message 'fix(flag): flag beats env' >/dev/null
eq "--message beats env" "$(git -C "$MR3" log -1 --format=%s feat/T)" "fix(flag): flag beats env"
# (c) hook rejection → commit-rejected (NOT conflict), hook text printed, staged state preserved
git -C "$MR3" worktree add -q wtT5 -b feat/T5 feat/T >/dev/null
( cd "$MR3/wtT5"; printf 'five\n' > f5.txt; git add f5.txt; git commit -q -m 'chore: t5' )
OUT="$($CC/cc-merge.sh do-merge "$MR3" feat/T5 squash feat/T --message 'not a conventional subject at all' 2>&1)"; rc=$?
eq "squash hook-reject exit3"     "$rc" "3"
eq "squash reject says commit-rejected" "$(echo "$OUT" | grep -c 'commit-rejected:')" "1"
eq "squash reject never says conflict"   "$(echo "$OUT" | grep -c '^conflict:')" "0"
eq "squash reject prints hook text"      "$(echo "$OUT" | grep -c 'Conventional Commits')" "1"
eq "squash reject preserves staged"      "$(git -C "$MR3/wtT" diff --cached --name-only | grep -c f5.txt)" "1"
git -C "$MR3/wtT" reset --hard HEAD >/dev/null 2>&1        # clean the preserved state for the next case
OUT="$($CC/cc-merge.sh do-merge "$MR3" feat/T5 no-ff feat/T --message 'still not conventional' 2>&1)"; rc=$?
eq "no-ff hook-reject exit3"       "$rc" "3"
eq "no-ff reject says commit-rejected" "$(echo "$OUT" | grep -c 'commit-rejected:')" "1"
eq "no-ff reject never says conflict"   "$(echo "$OUT" | grep -c '^conflict:')" "0"
eq "no-ff reject prints hook text"      "$(echo "$OUT" | grep -c 'Conventional Commits')" "1"
eq "no-ff reject preserves MERGE_HEAD"  "$(git -C "$MR3/wtT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && echo yes || echo no)" "yes"
git -C "$MR3/wtT" merge --abort >/dev/null 2>&1
# (d) a REAL content conflict still reports conflict, prints git output, leaves a clean tree
( cd "$MR3/wtT";  printf 'T-side\n'  > clash5.txt; git add clash5.txt; git commit -q -m 'chore: t side' )
( cd "$MR3/wtT5"; printf 'T5-side\n' > clash5.txt; git add clash5.txt; git commit -q -m 'chore: t5 side' )
OUT="$($CC/cc-merge.sh do-merge "$MR3" feat/T5 no-ff feat/T 2>&1)"; rc=$?
eq "no-ff real conflict exit1"     "$rc" "1"
eq "real conflict says conflict"   "$(echo "$OUT" | grep -c '^conflict:')" "1"
eq "conflict prints git output"    "$(echo "$OUT" | grep -c 'CONFLICT')" "1"
eq "conflict leaves clean tree"    "$(git -C "$MR3/wtT" status --porcelain | wc -l | tr -d ' ')" "0"
# zsh layer: --message flows through gwt-merge to do-merge (fake HOME so ~/.config/cc-stack
# resolves to THIS checkout's cc-merge.sh, never the live install; TSVs pinned to scratch files)
FH=$(mktemp -d); mkdir -p "$FH/.config/cc-stack"; cp "$CC/cc-merge.sh" "$FH/.config/cc-stack/"
TF8=$(mktemp -u); SF8=$(mktemp -u); AF8=$(mktemp -u)
git -C "$MR3" worktree add -q wtT6 -b feat/T6 feat/T >/dev/null
( cd "$MR3/wtT6"; printf 'six\n' > f6.txt; git add f6.txt; git commit -q -m 'chore: t6' )
"$CC/cc-merge.sh" set-parent "$MR3" feat/T6 feat/T
"$CC/cc-merge.sh" done "$MR3" feat/T6 true
printf '\ny\n' | HOME="$FH" CC_TASKS_FILE="$TF8" CC_STATUS_FILE="$SF8" CC_ARCHIVE_FILE="$AF8" \
  zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$MR3'; gwt-merge feat/T6 --message 'chore(zsh): flag through gwt-merge'" >/dev/null 2>&1; zrc=$?
eq "gwt-merge --message exit0"  "$zrc" "0"
eq "gwt-merge passes --message" "$(git -C "$MR3" log -1 --format=%s feat/T)" "chore(zsh): flag through gwt-merge"
rm -rf "$MR3" "$FH"; rm -f "$TF8" "$SF8" "$AF8"

echo "== 8c. do-merge temp-worktree lifecycle (target checked out NOWHERE) =="
# 8b always gives the target a real worktree; here feat/camp exists only as a ref, so do-merge
# must mint a temporary worktree and clean it up correctly on every path except commit-rejected.
MR4=$(mktemp -d); ( cd "$MR4" || exit 1; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  git branch feat/camp main                                # target branch, never checked out
  git worktree add -q wtC1 -b feat/C1 feat/camp >/dev/null
  cd wtC1; printf 'c1\n' > c1.txt; git add c1.txt; git commit -q -m 'chore: c1' )
cat > "$MR4/.git/hooks/commit-msg" <<'HOOK'
#!/usr/bin/env bash
head -1 "$1" | grep -qE '^(feat|fix|refactor|test|docs|chore|perf|build|ci|style)(\([a-z0-9/-]+\))?: .' || {
  echo "subject must follow Conventional Commits: <type>(<scope>): <subject>" >&2; exit 1; }
HOOK
chmod +x "$MR4/.git/hooks/commit-msg"
# (a) SUCCESS: temp worktree minted, merge lands, registration count unchanged afterwards
wtc="$(git -C "$MR4" worktree list --porcelain | grep -c '^worktree ')"
OUT="$("$CC/cc-merge.sh" do-merge "$MR4" feat/C1 squash feat/camp)"; rc=$?
eq "temp-path squash exit0"          "$rc" "0"
eq "temp-path squash subject"        "$(git -C "$MR4" log -1 --format=%s feat/camp)" "chore: merge feat/C1 into feat/camp (squash)"
eq "temp-path Child-Tip trailer"     "$(git -C "$MR4" log -1 --format=%B feat/camp | grep -c "Child-Tip: $(git -C "$MR4" rev-parse feat/C1)")" "1"
eq "temp-path content landed"        "$(git -C "$MR4" show feat/camp:c1.txt 2>/dev/null)" "c1"
eq "temp wt deregistered on success" "$(git -C "$MR4" worktree list --porcelain | grep -c '^worktree ')" "$wtc"
# (b) COMMIT-REJECTED: the temp worktree is deliberately KEPT, its dir printed, manual finish works
git -C "$MR4" worktree add -q wtC2 -b feat/C2 feat/camp >/dev/null
( cd "$MR4/wtC2" || exit 1; printf 'c2\n' > c2.txt; git add c2.txt; git commit -q -m 'chore: c2' )
OUT="$($CC/cc-merge.sh do-merge "$MR4" feat/C2 squash feat/camp --message 'not a conventional subject at all' 2>&1)"; rc=$?
# NB: parse with bash string ops, NOT sed — macOS BSD sed mis-matches BREs whose literal "(" +
# ".*" must cross a ")" in the subject before anchoring "$" (see docs/known-issues.md)
presline="$(echo "$OUT" | grep 'staged merge PRESERVED in:')"
kept="${presline#*PRESERVED in: }"
kept="${kept%% (branch*}"
eq "temp-path reject exit3"          "$rc" "3"
eq "temp-path reject keeps wt"       "$(git -C "$MR4" worktree list --porcelain | grep -c '^worktree ')" "$((wtc + 2))"   # +wtC2 +kept temp
eq "temp-path reject prints dir"     "$( [ -n "$kept" ] && [ -d "$kept" ] && echo yes || echo no)" "yes"
eq "temp-path reject temp hint"      "$(echo "$OUT" | grep -c 'is a temporary worktree')" "1"
eq "temp-path staged preserved"      "$(git -C "$kept" diff --cached --name-only 2>/dev/null | grep -c c2.txt)" "1"
git -C "$kept" commit -q -m 'chore: finish by hand'; eq "manual finish commits" "$?" "0"
eq "manual finish lands content"     "$(git -C "$MR4" show feat/camp:c2.txt 2>/dev/null)" "c2"
git -C "$MR4" worktree remove "$kept" >/dev/null 2>&1
eq "kept wt removable after finish"  "$(git -C "$MR4" worktree list --porcelain | grep -c '^worktree ')" "$((wtc + 1))" # +wtC2 only
# (c) REAL CONFLICT via the temp path: aborted, deregistered, output visible.
# Child MUST branch before the target advances, otherwise it contains the target side (no conflict).
git -C "$MR4" worktree add -q wtC3 -b feat/C3 feat/camp >/dev/null
( cd "$MR4/wtC3" || exit 1; printf 'child-side\n' > clash.txt; git add clash.txt; git commit -q -m 'chore: child side' )
git -C "$MR4" worktree add -q wtX feat/camp >/dev/null
( cd "$MR4/wtX" || exit 1; printf 'target-side\n' > clash.txt; git add clash.txt; git commit -q -m 'chore: target side' )
git -C "$MR4" worktree remove --force wtX >/dev/null 2>&1        # feat/camp is nowhere again
OUT="$($CC/cc-merge.sh do-merge "$MR4" feat/C3 no-ff feat/camp 2>&1)"; rc=$?
eq "temp-path conflict exit1"        "$rc" "1"
eq "temp-path conflict label"        "$(echo "$OUT" | grep -c '^conflict:')" "1"
eq "temp-path conflict output"       "$(echo "$OUT" | grep -c 'CONFLICT')" "1"
eq "temp wt deregistered on conflict" "$(git -C "$MR4" worktree list --porcelain | grep -c '^worktree ')" "$((wtc + 2))" # +wtC2 +wtC3
rm -rf "$MR4"

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
grep -q 'cc-worktree-shared.sh" seed' "$CC/cc-dispatch.sh" && ok "surface script seeds corpus" || no "surface script seeds corpus" missing present
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

# gwt-rm --branch must resolve the REAL branch (any prefix) from the worktree, not assume feat/<name>
( cd "$AR"; git worktree add -q .claude/worktrees/custom-pre -b fix/custom-pre >/dev/null 2>&1 )
CC_TASKS_FILE=/dev/null CC_STATUS_FILE=/dev/null zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-rm custom-pre --branch" >/dev/null 2>&1
eq "gwt-rm removes the worktree"      "$([ -d "$AR/.claude/worktrees/custom-pre" ] && echo no || echo yes)" "yes"
eq "gwt-rm deletes custom-prefix branch" "$(git -C "$AR" show-ref --verify --quiet refs/heads/fix/custom-pre && echo still-there || echo gone)" "gone"
rm -rf "$AR"

echo ""
echo "== 15. gwt-provider (provider switch for new sub-tasks) =="
LF=$(mktemp -u); PD=$(mktemp -d); : > "$PD/kimi.sh"; : > "$PD/glm.sh"
zprov(){ zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; CC_LAUNCH_FILE='$LF' CC_LAUNCH_PROVDIR='$PD' gwt-provider $1" 2>/dev/null; }
eq "gwt-provider default anthropic" "$(zprov '' | awk '/^current/{print $3}')" "anthropic"
zprov 'kimi' >/dev/null 2>&1;       eq "gwt-provider kimi writes file" "$(cat "$LF")" "kimi"
zprov 'glm' >/dev/null 2>&1;        eq "gwt-provider glm writes file" "$(cat "$LF")" "glm"
zprov 'anthropic' >/dev/null 2>&1;  eq "gwt-provider anthropic writes file" "$(cat "$LF")" "anthropic"
zprov 'default' >/dev/null 2>&1;    eq "gwt-provider default=anthropic" "$(cat "$LF")" "anthropic"
zprov 'nope' >/dev/null 2>&1;       eq "gwt-provider rejects unknown" "$?" "1"
zprov '../x' >/dev/null 2>&1;       eq "gwt-provider rejects traversal" "$?" "1"
rm -f "$LF"; rm -rf "$PD"
# surface maps provider name → launch command (default ccteam; other → cld <name>)
grep -q 'CC_LAUNCH_FILE' "$CC/cc-dispatch.sh" && ok "surface reads provider config" || no "surface reads provider config" missing present
grep -q 'cld \$_provider' "$CC/cc-dispatch.sh" && ok "surface maps provider→cld" || no "surface maps provider→cld" missing present

echo ""
echo "== 16. cc-send (roadmap 2b: collision-safe send primitive) =="
# fake-cmux harness: a fake `cmux` on PATH records send/send-key/notify into $CC_FAKE_LOG and
# serves $CC_FAKE_SCREEN from read-screen. CC_FAKE_CLEAR_AT=N flips the screen to the empty
# input line on the Nth read (the human submits their draft); CC_FAKE_FAIL=1 makes read-screen
# fail (cmux hiccup). CC_FAKE_ON_SEND=<file> swaps the screen in right after a `send` (the text
# PARKS in the composer); CC_FAKE_FLUSH_AT=N flips it back to the empty line on the Nth Enter
# (the retry submits the parked text). CC_SEND_FAILLOG keeps breadcrumbs off the live
# cc-failures.log. CC_SEND_VERIFY_SEC=0.2 shrinks the post-send verify delays for speed.
FS=$(mktemp -d); export CC_FAKE_LOG="$FS/log"; export CC_FAKE_SCREEN="$FS/screen"
cat > "$FS/cmux" <<'CMUX'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  send)     shift; printf 'SEND|%s\n'  "$*" >> "$CC_FAKE_LOG"
            [ -n "${CC_FAKE_ON_SEND:-}" ] && cp "$CC_FAKE_ON_SEND" "$CC_FAKE_SCREEN" 2>/dev/null ;;
  send-key) shift; printf 'KEY|%s\n'   "$*">> "$CC_FAKE_LOG"
            case "$*" in *Enter*)
              [ -n "${CC_FAKE_FLUSH_AT:-}" ] && {
                n=$(grep -c 'Enter$' "$CC_FAKE_LOG" 2>/dev/null); n=${n:-0}
                [ "$n" -ge "$CC_FAKE_FLUSH_AT" ] && printf '\xe2\x9d\xaf\xc2\xa0\n' > "$CC_FAKE_SCREEN"; } ;; esac ;;
  notify)   shift; printf 'NOTIFY|%s\n' "$*" >> "$CC_FAKE_LOG" ;;
  read-screen)
    [ -n "${CC_FAKE_FAIL:-}" ] && exit 1
    if [ -n "${CC_FAKE_CLEAR_AT:-}" ]; then
      n=$(( $(cat "${CC_FAKE_LOG}.cnt" 2>/dev/null || echo 0) + 1 )); echo "$n" > "${CC_FAKE_LOG}.cnt"
      [ "$n" -ge "$CC_FAKE_CLEAR_AT" ] && printf '\xe2\x9d\xaf\xc2\xa0\n' > "$CC_FAKE_SCREEN"
    fi
    cat "$CC_FAKE_SCREEN" 2>/dev/null ;;
esac
exit 0
CMUX
chmod +x "$FS/cmux"
FL="$FS/failures.log"
csend_reset(){ : > "$CC_FAKE_LOG"; rm -f "${CC_FAKE_LOG}.cnt"; rm -f "$FL"; cp "$1" "$CC_FAKE_SCREEN"; }
OPATH="$PATH"; PATH="$FS:$PATH"; export CC_SEND_VERIFY_SEC=0.2
# byte-exact fixtures from the 2026-08-15 live probes (claude 2.1.233, BOTH renderers):
# empty input line = prompt glyph + U+00A0 NBSP cursor placeholder; composing = + draft; the
# transcript echoes submitted messages as prompt + ASCII space + text (ABOVE the live box).
P='❯'; NB="$(printf '\xc2\xa0')"; R20='────────────────────────────'
fw(){ echo ""; echo "$R20"; printf '%s%s\n' "$P" "$NB"; echo "$R20"; echo "  glm-5.3[1m] 7% / session"; echo "  -- INSERT -- auto mode on"; }
{ echo "╰──────────╯"; fw; }                                        > "$FS/scr-def-empty"   # default renderer
{ fw; }                                                            > "$FS/scr-full-empty"  # fullscreen renderer
{ echo "$R20"; printf '%s%s%s\n' "$P" "$NB" 'user typing draft text 123'; echo "$R20"; echo "  status"; } > "$FS/scr-busy"
{ echo ""; printf '%s %s\n' "$P" 'fullscreen draft xyzparked draft for smoke2'; fw; } > "$FS/scr-echo"   # transcript echo ABOVE empty live box
{ echo "$ last login"; echo "PROMPT> "; }                          > "$FS/scr-prompt"     # no claude TUI at all
# busy-indicator fixtures — byte-exact from the 2026-08-15 live probe (own tab mid-turn, claude
# 2.1.233): working line at column 0, "<spinner> <gerund>… (<dur> · <stats>)"; spinner rotates
# through 6 glyphs (· ✢ ✳ ✶ ✻ ✽ — ✻ here = e2 9c bb, … = e2 80 a6, · = c2 b7, ↓ = e2 86 93)
SP="$(printf '\xe2\x9c\xbb')"
spun(){ printf '%s Befuddling\xe2\x80\xa6 (2m 26s \xc2\xb7 \xe2\x86\x93 14.2k tokens)\n' "$1"; }
{ spun "$SP"; echo "$R20"; printf '%s%s%s\n' "$P" "$NB" 'queued msg text'; echo "$R20"; } > "$FS/scr-spin-queued"
{ spun "$SP"; echo "$R20"; printf '%s%s\n'    "$P" "$NB";               echo "$R20"; } > "$FS/scr-spin-empty"
{ echo "WORKING hard now (always)"; echo "$R20"; printf '%s%s%s\n' "$P" "$NB" 'queued msg text'; } > "$FS/scr-custom-busy"
printf '%s%s%s\n' "$P" "$NB" '[Pasted text +1]'                    > "$FS/scr-parked"     # text parked in the composer after send
{ echo "$R20"; printf '%s%s%s\n' "$P" "$NB" 'user is drafting 0123456789ABCDEFGHIJ'; echo "$R20"; } > "$FS/scr-longdraft"
# 1) empty input line → immediate send (both renderer fixtures), no notify, no crumb
csend_reset "$FS/scr-full-empty"
CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "hello gate" >"$FS/out" 2>&1; rcs=$?
eq "fullscreen empty rc0"       "$rcs" "0"
eq "fullscreen empty sends"     "$(grep -cF 'hello gate' "$CC_FAKE_LOG")" "1"
eq "fullscreen empty Enter"     "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG")" "1"
eq "fullscreen empty no notify" "$(grep -c 'NOTIFY|' "$CC_FAKE_LOG")" "0"
eq "fullscreen empty no crumb"  "$([ -f "$FL" ] && echo yes || echo no)" "no"
eq "empty path not the fast-path" "$(grep -cF '(queued' "$FS/out")" "0"
csend_reset "$FS/scr-def-empty"
CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "hi default" >/dev/null 2>&1
eq "default empty sends"        "$(grep -cF 'hi default' "$CC_FAKE_LOG")" "1"
eq "default empty no crumb"     "$([ -f "$FL" ] && echo yes || echo no)" "no"
# 2) transcript echo (busy-looking, prompt+ASCII space) must NOT beat the live empty box
csend_reset "$FS/scr-echo"
CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "beat the echo" >/dev/null 2>&1
eq "echo-above still sends"     "$(grep -cF 'beat the echo' "$CC_FAKE_LOG")" "1"
eq "echo-above no crumb"        "$([ -f "$FL" ] && echo yes || echo no)" "no"
# 3) composing → waits, sends after the line clears (CLEAR_AT=3 → two 0.5s waits)
csend_reset "$FS/scr-busy"
t0=$(date +%s)
CC_FAKE_CLEAR_AT=3 CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "after clear" >/dev/null 2>&1
t1=$(date +%s)
eq "busy waits (≥1s)"           "$(( t1 - t0 >= 1 ))" "1"
eq "busy sends after clear"     "$(grep -cF 'after clear' "$CC_FAKE_LOG")" "1"
eq "busy no notify (60s def)"   "$(grep -c 'NOTIFY|' "$CC_FAKE_LOG")" "0"
# 4) timeout (short env override) → notify fired once, KEEPS waiting, still delivers after clear
csend_reset "$FS/scr-busy"
t0=$(date +%s)
CC_SEND_TIMEOUT=1 CC_FAKE_CLEAR_AT=6 CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "held msg" >/dev/null 2>&1
t1=$(date +%s)
eq "timeout notifies once"      "$(grep -c 'NOTIFY|' "$CC_FAKE_LOG")" "1"
eq "timeout kept waiting (≥2s)" "$(( t1 - t0 >= 2 ))" "1"
eq "timeout never drops"        "$(grep -cF 'held msg' "$CC_FAKE_LOG")" "1"
nline=$(grep -n 'NOTIFY|' "$CC_FAKE_LOG" | cut -d: -f1); sline=$(grep -n 'SEND|' "$CC_FAKE_LOG" | head -1 | cut -d: -f1)
[ "$nline" -lt "$sline" ] && ok "notify precedes send" || no "notify precedes send" "$nline" "< $sline"
# 4b) heartbeat: while still holding, re-notify every CC_SEND_HEARTBEAT_SEC (short override for
# speed), each carrying the held duration + the blocked-by preview of the blocking line
csend_reset "$FS/scr-busy"
CC_SEND_TIMEOUT=1 CC_SEND_HEARTBEAT_SEC=1 CC_SEND_FAILLOG="$FL" \
  CC_FAKE_CLEAR_AT=9 bash "$CC/cc-dispatch.sh" send surface:1 "hb msg" >/dev/null 2>&1
nhb=$(grep -c 'NOTIFY|' "$CC_FAKE_LOG")
eq "heartbeat re-fires (≥2)"    "$(( nhb >= 2 && nhb <= 8 ))" "1"
eq "heartbeat still delivers"   "$(grep -cF 'hb msg' "$CC_FAKE_LOG")" "1"
eq "heartbeat carries duration" "$(grep -cE 'held the message for [0-9]+s' "$CC_FAKE_LOG")" "$nhb"
eq "heartbeat carries preview"  "$(grep -cF 'blocked by: "user typing draft text 123"' "$CC_FAKE_LOG")" "$nhb"
# 4c) preview truncates at CC_SEND_PREVIEW_CHARS; 0 disables it (notify still fires)
csend_reset "$FS/scr-longdraft"
CC_SEND_TIMEOUT=1 CC_SEND_PREVIEW_CHARS=10 CC_SEND_FAILLOG="$FL" \
  CC_FAKE_CLEAR_AT=4 bash "$CC/cc-dispatch.sh" send surface:1 "trunc msg" >/dev/null 2>&1
eq "preview truncates at limit" "$(grep -cF 'blocked by: "user is dr"' "$CC_FAKE_LOG")" "1"
eq "preview drops the tail"     "$(grep -cF 'ABCDEFGHIJ' "$CC_FAKE_LOG")" "0"
csend_reset "$FS/scr-longdraft"
CC_SEND_TIMEOUT=1 CC_SEND_PREVIEW_CHARS=0 CC_SEND_FAILLOG="$FL" \
  CC_FAKE_CLEAR_AT=4 bash "$CC/cc-dispatch.sh" send surface:1 "noprev msg" >/dev/null 2>&1
eq "preview off still notifies" "$(grep -c 'NOTIFY|' "$CC_FAKE_LOG")" "1"
eq "preview off omits preview"  "$(grep -c 'blocked by' "$CC_FAKE_LOG")" "0"
# 5) read-screen failure → fail-open raw send + breadcrumb; CC_SEND_QUIET suppresses the crumb
csend_reset "$FS/scr-busy"
CC_FAKE_FAIL=1 CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "failopen" >/dev/null 2>&1; rcs=$?
eq "read-fail rc0 (sent)"       "$rcs" "0"
eq "read-fail sends anyway"     "$(grep -cF 'failopen' "$CC_FAKE_LOG")" "1"
eq "read-fail crumbs"           "$(grep -c 'fail-open' "$FL" 2>/dev/null)" "1"
csend_reset "$FS/scr-busy"
CC_FAKE_FAIL=1 CC_SEND_QUIET=1 CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "quiet" >/dev/null 2>&1
eq "quiet sends"                "$(grep -cF 'quiet' "$CC_FAKE_LOG")" "1"
eq "quiet no crumb"             "$([ -f "$FL" ] && echo yes || echo no)" "no"
# 6) CC_SEND_INPUT_PATTERNS REPLACES the defaults (no union), auto-anchored at line start
csend_reset "$FS/scr-prompt"
CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "foreign layout" >/dev/null 2>&1
eq "foreign layout fail-opens"  "$(grep -c 'fail-open' "$FL" 2>/dev/null)" "1"
csend_reset "$FS/scr-prompt"
CC_SEND_INPUT_PATTERNS='PROMPT>' CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "custom pat" >/dev/null 2>&1
eq "override matches new form"  "$(grep -cF 'custom pat' "$CC_FAKE_LOG")" "1"
eq "override no crumb"          "$([ -f "$FL" ] && echo yes || echo no)" "no"
csend_reset "$FS/scr-busy"
CC_SEND_INPUT_PATTERNS='PROMPT>' CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "no union" >/dev/null 2>&1
eq "override replaces defaults" "$(grep -c 'fail-open' "$FL" 2>/dev/null)" "1"
# 6b) empty list entries (trailing/double colon — one-char typo in the drift-recovery knob) must
# be skipped, NOT treated as match-anything: an empty pattern hits any line with RLENGTH=0, rest
# becomes the whole line, and an EMPTY input line would read BUSY → silent hold-forever
csend_reset "$FS/scr-full-empty"
CC_SEND_INPUT_PATTERNS='^❯:' CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "trailcolon" >/dev/null 2>&1
eq "trailing-colon still sends"  "$(grep -cF 'trailcolon' "$CC_FAKE_LOG")" "1"
eq "trailing-colon no crumb"     "$([ -f "$FL" ] && echo yes || echo no)" "no"
csend_reset "$FS/scr-full-empty"
CC_SEND_INPUT_PATTERNS='^❯::^>' CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "dblcolon" >/dev/null 2>&1
eq "double-colon still sends"    "$(grep -cF 'dblcolon' "$CC_FAKE_LOG")" "1"
eq "double-colon no crumb"       "$([ -f "$FL" ] && echo yes || echo no)" "no"
# 6c) busy fast-path: a working-indicator line (probed spinner form) sends IMMEDIATELY — no hold
# (even with QUEUED text in the input box), no notify, no post-send verify (one Enter only).
# CC_SEND_TIMEOUT/CC_FAKE_CLEAR_AT are the SAFETY NET: if the fast-path ever regresses, the case
# degrades to the normal hold→clear→send path and the "(queued" asserts catch it instead of hanging.
csend_reset "$FS/scr-spin-queued"
CC_SEND_TIMEOUT=1 CC_FAKE_CLEAR_AT=4 CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "fastpath" >"$FS/out" 2>&1; rcs=$?
eq "fastpath queued-input rc0"   "$rcs" "0"
eq "fastpath sends now"          "$(grep -cF 'fastpath' "$CC_FAKE_LOG")" "1"
eq "fastpath no notify"          "$(grep -c 'NOTIFY|' "$CC_FAKE_LOG")" "0"
eq "fastpath one Enter (no verify)" "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG")" "1"
eq "fastpath says queued"        "$(grep -cF '(queued' "$FS/out")" "1"
eq "fastpath no crumb"           "$([ -f "$FL" ] && echo yes || echo no)" "no"
# the scan runs BEFORE the empty/busy verdict — a spinner over an EMPTY input line fast-paths too
# (distinguishable from the normal empty-path only by the output line + the missing verify re-read)
csend_reset "$FS/scr-spin-empty"
CC_SEND_TIMEOUT=1 CC_FAKE_CLEAR_AT=4 CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "spinempty" >"$FS/out" 2>&1
eq "fastpath fires before verdict" "$(grep -cF '(queued' "$FS/out")" "1"
eq "fastpath empty-input no verify" "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG")" "1"
# CC_SEND_BUSY_PATTERNS REPLACES the defaults (no union) and skips empty entries
# (an empty ERE matches every line → would fast-path every send)
csend_reset "$FS/scr-custom-busy"
CC_SEND_TIMEOUT=1 CC_FAKE_CLEAR_AT=4 CC_SEND_BUSY_PATTERNS='^WORKING' CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "custom busy" >"$FS/out" 2>&1
eq "busy override matches custom" "$(grep -cF 'custom busy' "$CC_FAKE_LOG")" "1"
eq "busy override says queued"    "$(grep -cF '(queued' "$FS/out")" "1"
eq "busy override no notify"      "$(grep -c 'NOTIFY|' "$CC_FAKE_LOG")" "0"
csend_reset "$FS/scr-spin-queued"
CC_SEND_TIMEOUT=1 CC_FAKE_CLEAR_AT=4 CC_SEND_BUSY_PATTERNS='^WORKING' CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "norepl" >"$FS/out" 2>&1
eq "busy override replaces defaults" "$(grep -cF '(queued' "$FS/out")" "0"
eq "busy override still delivers"    "$(grep -cF 'norepl' "$CC_FAKE_LOG")" "1"
csend_reset "$FS/scr-spin-queued"
CC_SEND_TIMEOUT=1 CC_FAKE_CLEAR_AT=4 CC_SEND_BUSY_PATTERNS=':' CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "emptyentry" >"$FS/out" 2>&1
eq "busy empty-entry skipped"     "$(grep -cF '(queued' "$FS/out")" "0"
eq "busy empty-entry delivers"    "$(grep -cF 'emptyentry' "$CC_FAKE_LOG")" "1"
# 6d) post-send verify (empty path): the text PARKS after send (Enter swallowed) → exactly ONE
# Enter retry, then success; the retry is swallowed too → loud failure (rc≠0 + breadcrumb + stderr),
# never a silent success
csend_reset "$FS/scr-full-empty"
CC_FAKE_ON_SEND="$FS/scr-parked" CC_FAKE_FLUSH_AT=2 CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "parked once" >"$FS/out" 2>&1; rcs=$?
eq "verify retry rc0"            "$rcs" "0"
eq "verify retry sends once"     "$(grep -cF 'parked once' "$CC_FAKE_LOG")" "1"
eq "verify retry Enter twice"    "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG")" "2"
eq "verify retry success line"   "$(grep -c '✔ cc-send: delivered' "$FS/out")" "1"
eq "verify retry no crumb"       "$([ -f "$FL" ] && echo yes || echo no)" "no"
csend_reset "$FS/scr-full-empty"
CC_FAKE_ON_SEND="$FS/scr-parked" CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "parked twice" >"$FS/out" 2>&1; rcs=$?
eq "verify park-fail rc1"        "$rcs" "1"
eq "verify park-fail one retry"  "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG")" "2"
eq "verify park-fail no success" "$(grep -c '✔ cc-send: delivered' "$FS/out")" "0"
eq "verify park-fail loud msg"   "$(grep -c '✗ cc-send: sent' "$FS/out")" "1"
eq "verify park-fail crumb"      "$(grep -c 'parked after send' "$FL" 2>/dev/null)" "1"
# 7) calibration: breadcrumb on pattern miss; hit stays silent; read-fail is not drift
csend_reset "$FS/scr-prompt"
CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" calibrate surface:9 /tmp/cal-x >/dev/null 2>&1; rcs=$?
eq "calibrate miss rc1"         "$rcs" "1"
eq "calibrate miss crumbs"      "$(grep -c 'calibration' "$FL" 2>/dev/null)" "1"
csend_reset "$FS/scr-full-empty"
CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" calibrate surface:9 /tmp/cal-x >/dev/null 2>&1; rcs=$?
eq "calibrate hit rc0"          "$rcs" "0"
eq "calibrate hit no crumb"     "$([ -f "$FL" ] && echo yes || echo no)" "no"
csend_reset "$FS/scr-prompt"
CC_FAKE_FAIL=1 CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" calibrate surface:9 /tmp/cal-x >/dev/null 2>&1; rcs=$?
eq "calibrate read-fail skip"   "$rcs" "0"
eq "calibrate read-fail quiet"  "$([ -f "$FL" ] && echo yes || echo no)" "no"
# 8) usage + migration surface: raw `cmux send` remains ONLY at the RDY exception + the raw exit
bash "$CC/cc-dispatch.sh" send >/dev/null 2>&1; eq "send usage rc2" "$?" "2"
eq "raw cmux send sites = RDY + raw-exit" "$(grep -cE '^[[:space:]]*cmux send ' "$CC/cc-dispatch.sh")" "2"
eq "cc-hooks.sh has no send site"         "$(grep -c 'cmux send' "$CC/cc-hooks.sh")" "0"
grep -q 'cc-dispatch.sh send \$caller_surface' "$CC/cc-dispatch.sh" && ok "backchannel teaches cc-send" || no "backchannel teaches cc-send" missing present
PATH="$OPATH"; unset CC_FAKE_LOG CC_FAKE_SCREEN CC_SEND_VERIFY_SEC; rm -rf "$FS"

echo ""
echo "== 17. gwt-resume (roadmap 2: recorded-args session resume) =="
# fake cmux (PATH shim): every call lands in $RF/log; list-pane-surfaces serves $RF/live,
# new-surface mints surface:101+ recording its args, read-screen serves a screen that is a
# shell whose claude TUI is already up (RDY22 for the shell probe, ❯+NBSP input line + shortcuts
# hint for cc-send / the trust scrape / calibration) — surface runs at full speed, zero cmux.
# The resume subcommand re-invokes surface via $HOME → a fake HOME holding a copy of THIS
# checkout (never the live install), TSVs pinned to scratch files, CC_RESUME_SETTLE=0.
RF=$(mktemp -d); export CC_FAKE_LOG="$RF/log"; export CC_FAKE_SCREEN="$RF/screen"
cat > "$RF/cmux" <<'CMUX'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  identify) echo '{ "caller": {} }' ;;
  restore-session) printf 'RESTORE-SESSION\n' >> "$CC_FAKE_LOG"; echo "(fake) session restored" ;;
  list-pane-surfaces) printf 'LIST\n' >> "$CC_FAKE_LOG"; cat "${CC_FAKE_LIVE:-/dev/null}" 2>/dev/null ;;
  new-surface)
    n=$(cat "${CC_FAKE_LOG}.nscnt" 2>/dev/null || echo 100); n=$((n+1)); echo "$n" > "${CC_FAKE_LOG}.nscnt"
    printf 'NEWSURF|surface:%s|%s\n' "$n" "$*" >> "$CC_FAKE_LOG"
    echo "opened surface:$n" ;;
  send)     shift; printf 'SEND|%s\n' "$*" >> "$CC_FAKE_LOG" ;;
  send-key) shift; printf 'KEY|%s\n'   "$*" >> "$CC_FAKE_LOG" ;;
  notify)   shift; printf 'NOTIFY|%s\n' "$*" >> "$CC_FAKE_LOG" ;;
  read-screen) cat "$CC_FAKE_SCREEN" 2>/dev/null ;;
esac
exit 0
CMUX
chmod +x "$RF/cmux"
NB17="$(printf '\xc2\xa0')"
{ echo "RDY22"; printf '\xe2\x9d\xaf%s\n' "$NB17"; echo "? for shortcuts"; } > "$CC_FAKE_SCREEN"
FH17=$(mktemp -d); mkdir -p "$FH17/.config"; cp -R "$CC" "$FH17/.config/cc-stack"
OP17="$PATH"
# fixture: a repo with three sub-task dirs (+ a dead-dir row + a foreign-repo row), a session
# store where D2's recorded session sits on the LIVE surface:55, stale agent-state rows
cn17(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
REPO17=$(mktemp -d); ( cd "$REPO17"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i )
mkdir "$REPO17/wt1" "$REPO17/wt2" "$REPO17/wt3"
D1="$(cn17 "$REPO17/wt1")"; D2="$(cn17 "$REPO17/wt2")"; D3="$(cn17 "$REPO17/wt3")"
OTH17="$(cn17 "$(mktemp -d)")"; UNREL17="$(cn17 "$(mktemp -d)")"
U1="11111111-1111-1111-1111-111111111111"; SESS2="22222222-2222-2222-2222-222222222222"
SURF2="33333333-3333-3333-3333-333333333333"; U4="44444444-4444-4444-4444-444444444444"
TF17=$(mktemp -u); SF17=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/R2\tsurface:8\t%s\tsurface:1\tD2 older\tmain\tuuid=%s:provider=anthropic:pm=auto\n' "$D2" "$SESS2"  > "$TF17"
printf '2026-01-01 00:00:02\tfeat/R1\tsurface:9\t%s\tsurface:1\tD1 kimi task\tmain\tuuid=%s:provider=kimi:pm=plan:model=glm-4.6\n' "$D1" "$U1" >> "$TF17"
printf '2026-01-01 00:00:03\tfeat/R2\tsurface:9\t%s\tsurface:1\tD2 plain task\tmain\tuuid=%s:provider=anthropic:pm=auto\n' "$D2" "$SESS2" >> "$TF17"
printf '2026-01-01 00:00:04\tfeat/R3\tsurface:10\t%s\tsurface:1\tD3 old row\tmain\n' "$D3" >> "$TF17"
printf '2026-01-01 00:00:05\tfeat/R4\tsurface:11\t%s/gone\tsurface:1\tdead dir row\tmain\tuuid=%s:provider=kimi:pm=auto\n' "$REPO17" "$U1" >> "$TF17"
printf '2026-01-01 00:00:06\tfeat/R5\tsurface:12\t%s\tsurface:1\tforeign repo row\tmain\tuuid=%s:provider=glm:pm=auto\n' "$OTH17" "$U4" >> "$TF17"
printf '%s\tblocked\t%s\n' "$D1" 100 >  "$SF17"
printf '%s\tidle\t%s\n'    "$D2" 100 >> "$SF17"
printf '%s\tidle\t%s\n'    "$UNREL17" 100 >> "$SF17"
# agent session store fixture in the REAL nested shape (probed live 2026-08-15): the per-session
# records live under "sessions"; the top level also carries activeSessionsBySurface /
# activeSessionsByWorkspace and an INT version. A parser that iterates the top level crashes on
# that int and emits nothing → every row would fall through to reopen (duplicate-tab bug), so
# scenario A asserts below are the regression net for the descent.
python3 - "$SESS2" "$SURF2" "$D2" > "$RF/store.json" <<'PY'
import json, sys
sess, surf, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({
  "activeSessionsBySurface": {surf: sess},
  "activeSessionsByWorkspace": {"77F86A0A-7F57-48E9-A08A-42B2A6BC7A33": [sess]},
  "sessions": {sess: {"surfaceId": surf, "cwd": cwd, "updatedAt": 200,
                      "agentLifecycle": "idle", "isRestorable": True}},
  "version": 3,
}, sys.stdout)
PY
printf '* surface:55\t%s\tD2 tab\n  surface:60\t99999999-9999-9999-9999-999999999999\tunrelated\n' "$SURF2" > "$RF/live"
renv17(){ # resume runner: fake HOME (copy of this checkout) + fake cmux + scratch TSVs
  ( cd "$REPO17" && env HOME="$FH17" PATH="$RF:$OP17" CC_TASKS_FILE="$TF17" CC_STATUS_FILE="$SF17" \
      CC_CMUX_SESSIONS="$RF/store.json" CC_RESUME_SETTLE=0 CC_SEND_VERIFY_SEC=0.1 \
      CC_SEND_FAILLOG="$RF/fail" CC_FAKE_LIVE="$RF/live" bash "$CC/cc-dispatch.sh" resume "$@" )
}
# A) default run, confirmed: D2 restored natively (store uuid → live surface:55), D1 reopened
# with the EXACT recorded cld command, D3 degraded to idle, foreign/dead rows untouched
: > "$CC_FAKE_LOG"
ROUT="$(printf 'y\n' | renv17 2>&1)"; rrc=$?
eq "resume exit0"            "$rrc" "0"
eq "native restore invoked"  "$(grep -c 'RESTORE-SESSION' "$CC_FAKE_LOG")" "1"
eq "restored row ref refreshed" "$(awk -F'\t' -v d="$D2" '$4==d{print $3}' "$TF17" | sort -u)" "surface:55"
eq "ALL rows of dir refreshed"  "$(awk -F'\t' -v d="$D2" '$4==d{print $3}' "$TF17" | wc -l | tr -d ' ')" "2"
eq "reopened exact cld cmd"  "$(grep -cF "cld kimi --resume $U1 --permission-mode plan --model glm-4.6" "$CC_FAKE_LOG")" "1"
eq "reopen dir VERBATIM"     "$(grep "NEWSURF" "$CC_FAKE_LOG" | grep -cF -- "--working-directory $D1")" "1"
eq "idle degrade bare ccteam" "$(grep -cE "^SEND\|--surface surface:[0-9]+ ccteam$" "$CC_FAKE_LOG")" "1"
eq "listing shows idle note" "$(echo "$ROUT" | grep -c 'no recorded session')" "1"
eq "listing header"          "$(echo "$ROUT" | grep -c 'BRANCH')" "1"
eq "no board row appended"   "$(awk -F'\t' -v d="$D1" '$4==d' "$TF17" | wc -l | tr -d ' ')" "1"
eq "reopen ref recorded"     "$(awk -F'\t' -v d="$D1" '$4==d{print $3}' "$TF17")" \
                             "$(grep -F -- "--working-directory $D1" "$CC_FAKE_LOG" | grep -oE 'surface:[0-9]+' | head -1)"
eq "stale status D1 cleared" "$(grep -cF "$D1" "$SF17")" "0"
eq "stale status D2 cleared" "$(grep -cF "$D2" "$SF17")" "0"
eq "unrelated status kept"   "$(grep -cF "$UNREL17" "$SF17")" "1"
eq "foreign row not touched" "$(grep -cF -- "--working-directory $OTH17" "$CC_FAKE_LOG")" "0"
eq "exactly 2 tabs opened"   "$(grep -c 'NEWSURF' "$CC_FAKE_LOG")" "2"
eq "dead dir never opened"   "$(grep -cF -- "--working-directory $REPO17/gone" "$CC_FAKE_LOG")" "0"
# B) declined confirm: nothing reopens (native restores above stand), rc 1, refs untouched
: > "$CC_FAKE_LOG"
BREF="$(awk -F'\t' -v d="$D1" '$4==d{print $3}' "$TF17")"
ROUT="$(printf 'n\n' | renv17 2>&1)"; rrc=$?
eq "decline exit1"           "$rrc" "1"
eq "decline opens nothing"   "$(grep -c 'NEWSURF' "$CC_FAKE_LOG")" "0"
eq "decline keeps refs"      "$(awk -F'\t' -v d="$D1" '$4==d{print $3}' "$TF17")" "$BREF"
# B2) immediate re-run on the SAME dirs must not be eaten by the 120s dedup marker (resume mode
# skips it) — the marker from run A is minutes fresh here
: > "$CC_FAKE_LOG"
ROUT="$(printf 'y\n' | renv17 2>&1)"; rrc=$?
eq "re-run not marker-blocked" "$(grep -c 'NEWSURF' "$CC_FAKE_LOG")" "2"
# C) repo filter vs --all: a board holding ONLY a foreign-repo row
TF17C=$(mktemp -u); printf '2026-01-01 00:00:01\tfeat/C1\tsurface:70\t%s\tsurface:1\tforeign only\tmain\tuuid=%s:provider=glm:pm=auto\n' "$OTH17" "$U4" > "$TF17C"
: > "$CC_FAKE_LOG"
ROUT="$(printf 'y\n' | ( cd "$REPO17" && env HOME="$FH17" PATH="$RF:$OP17" CC_TASKS_FILE="$TF17C" CC_STATUS_FILE="$(mktemp -u)" \
      CC_CMUX_SESSIONS="$RF/store.json" CC_RESUME_SETTLE=0 CC_SEND_FAILLOG="$RF/fail" CC_FAKE_LIVE="$RF/live" \
      bash "$CC/cc-dispatch.sh" resume) 2>&1)"; rrc=$?
eq "filter: nothing in repo" "$rrc" "0"
eq "filter says try --all"   "$(echo "$ROUT" | grep -c 'no resumable board rows')" "1"
eq "filter opens nothing"    "$(grep -c 'NEWSURF' "$CC_FAKE_LOG")" "0"
ROUT="$(printf 'y\n' | ( cd "$REPO17" && env HOME="$FH17" PATH="$RF:$OP17" CC_TASKS_FILE="$TF17C" CC_STATUS_FILE="$(mktemp -u)" \
      CC_CMUX_SESSIONS="$RF/store.json" CC_RESUME_SETTLE=0 CC_SEND_FAILLOG="$RF/fail" CC_FAKE_LIVE="$RF/live" \
      bash "$CC/cc-dispatch.sh" resume --all) 2>&1)"; rrc=$?
eq "--all reopens foreign"   "$rrc" "0"
eq "--all exact cmd (omit unrecorded)" "$(grep -cF "cld glm --resume $U4 --permission-mode auto" "$CC_FAKE_LOG")" "1"
eq "no --model when unrecorded" "$(grep -c -- '--model' "$CC_FAKE_LOG")" "0"
# D) dispatch records the minted uuid: surface (fresh mode) puts --session-id on the launch AND
# the composed launch-args on the log row; a non-whitelisted model is dropped, never interpolated
TF17D=$(mktemp -u); D0="$(cn17 "$(mktemp -d)")"
: > "$CC_FAKE_LOG"
env HOME="$FH17" PATH="$RF:$OP17" CC_TASKS_FILE="$TF17D" CC_SEND_FAILLOG="$RF/fail" \
  CC_SEND_VERIFY_SEC=0.1 CC_LAUNCH_FILE="$RF/launch" CC_WT_PERMISSION_MODE=plan CC_WT_MODEL='glm-4.6[1m]' \
  bash "$CC/cc-dispatch.sh" surface "$D0" "mint test brief" >/dev/null 2>&1
MINT="$(grep -oE -- '--session-id [0-9a-f-]+' "$CC_FAKE_LOG" | head -1 | cut -d' ' -f2)"
eq "surface mints a uuid"    "$(printf '%s' "$MINT" | grep -cE '^[0-9a-f-]{30,}$')" "1"
eq "minted id on launch"     "$(grep -cF -- "ccteam --session-id $MINT --permission-mode plan --model glm-4.6[1m]" "$CC_FAKE_LOG")" "1"
eq "minted id on log row"    "$(awk -F'\t' -v d="$D0" '$4==d{print $8}' "$TF17D")" "uuid=$MINT:provider=anthropic:pm=plan:model=glm-4.6[1m]"
eq "mint row has 8 fields"   "$(awk -F'\t' -v d="$D0" '$4==d{print NF}' "$TF17D")" "8"
D0B="$(cn17 "$(mktemp -d)")"
: > "$CC_FAKE_LOG"
env HOME="$FH17" PATH="$RF:$OP17" CC_TASKS_FILE="$TF17D" CC_SEND_FAILLOG="$RF/fail" \
  CC_SEND_VERIFY_SEC=0.1 CC_LAUNCH_FILE="$RF/launch" CC_WT_MODEL='bad model;rm -rf' \
  bash "$CC/cc-dispatch.sh" surface "$D0B" "model guard" >/dev/null 2>&1
eq "bad model never launched" "$(grep -c -- '--model' "$CC_FAKE_LOG")" "0"
eq "bad model not recorded"   "$(awk -F'\t' -v d="$D0B" '$4==d{print ($8 ~ /model=/)?"bad":"ok"}' "$TF17D")" "ok"
rm -rf "$RF" "$FH17" "$REPO17" "$OTH17" "$UNREL17" "$D0" "$D0B"; rm -f "$TF17" "$SF17" "$TF17C" "$TF17D"
# fresh-mode surface leaves dedup markers in the real TMPDIR (hash-keyed, contentless) — sweep ours
rm -f "${TMPDIR:-/tmp}/cc-cmux-tabs/$(printf '%s' "$D0"  | shasum -a 1 | cut -d' ' -f1)" \
      "${TMPDIR:-/tmp}/cc-cmux-tabs/$(printf '%s' "$D0B" | shasum -a 1 | cut -d' ' -f1)" 2>/dev/null
unset CC_FAKE_LOG CC_FAKE_SCREEN

echo ""
echo "== syntax =="
for s in "$CC"/*.sh; do bash -n "$s" && : || { echo "  ✗ syntax $s"; fail=$((fail+1)); }; done
zsh -n "$CC/worktree.zsh" && ok "worktree.zsh syntax" || { no "worktree.zsh syntax" x x; }

echo ""
echo "== 10. zsh commands present =="
for fn in gwt-tree gwt-done gwt-undone gwt-merge gwt-collect gwt-adopt gwt-log gwt-resume; do
  grep -q "^$fn()" "$CC/worktree.zsh" && ok "$fn defined" || no "$fn defined" missing present
done

echo "== 11. docs mention new commands =="
grep -q "gwt-merge" "$CC/worktree.zsh" && grep -q "gwt-merge" "$CC/README.md" \
  && ok "gwt-merge documented" || no "gwt-merge documented" missing present
grep -q "gwt-done" "$CC/README.md" && ok "gwt-done documented" || no "gwt-done documented" missing present
grep -q "gwt-adopt" "$CC/README.md" && ok "gwt-adopt documented" || no "gwt-adopt documented" missing present
grep -q "gwt-log" "$CC/README.md" && ok "gwt-log documented" || no "gwt-log documented" missing present
grep -q "gwt-resume" "$CC/README.md" && ok "gwt-resume documented" || no "gwt-resume documented" missing present
grep -q "cc-board.sh" "$CC/README.md" && ok "cc-board.sh documented" || no "cc-board.sh documented" missing present

echo ""
echo "result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
