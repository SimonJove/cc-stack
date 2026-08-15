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
"$CC/cc-board.sh" log "/tmp/nodir_A" "surface:1" "surface:9" "task	with tab|pipe" "feat/par"
eq "writes 7 fields"        "$(awk -F'\t' 'NR==1{print NF}' "$CC_TASKS_FILE")" "7"
eq "7th field is parent"    "$(awk -F'\t' 'NR==1{print $7}' "$CC_TASKS_FILE")" "feat/par"
eq "task sanitized (no tab)" "$(awk -F'\t' 'NR==1{print ($6 ~ /\t/)?"bad":"ok"}' "$CC_TASKS_FILE")" "ok"
# round-trip: a logged row renders on the board (dir must exist — prune-on-read drops dead dirs;
# --all so the repo filter can't hide the foreign row)
RT=$(mktemp -d)
"$CC/cc-board.sh" log "$RT" "surface:2" "surface:1" "round trip task" "feat/rt"
eq "log→board round-trip" "$(CC_TASKS_FILE="$CC_TASKS_FILE" CC_STATUS_FILE=/dev/null bash "$CC/cc-board.sh" --all 2>/dev/null | grep -c 'round trip task')" "1"
rm -rf "$RT"; rm -f "$CC_TASKS_FILE"; unset CC_TASKS_FILE

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
printf '%s\tidle\t%s\n' "$BW" "$now" > "$SF"; printf '%s\tidle\t%s\n' "$BRD" "$now" >> "$SF"; printf '%s\tidle\t%s\n' "$BW1" "$now" >> "$SF"
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; CC_TASKS_FILE='$TF' CC_STATUS_FILE='$SF' CC_ARCHIVE_FILE='$AF' _gwt_archive_branch feat/W" >/dev/null 2>&1
eq "archive moves ALL branch rows"   "$(awk -F'\t' '$2=="feat/W"' "$TF" | wc -l | tr -d ' ')" "0"
eq "other branch stays"              "$(awk -F'\t' '$2=="feat/W1"' "$TF" | wc -l | tr -d ' ')" "1"
eq "archive gained both rows"        "$(awk -F'\t' '$2=="feat/W"' "$AF" | wc -l | tr -d ' ')" "2"
eq "archive rows have 8 fields"      "$(awk -F'\t' 'NR==1{print NF}' "$AF")" "8"
eq "merged-at is a unix ts"          "$(awk -F'\t' '$2=="feat/W"{print ($8 ~ /^[0-9]+$/)?"ok":"no"}' "$AF" | sort -u)" "ok"
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
echo "== syntax =="
for s in "$CC"/*.sh; do bash -n "$s" && : || { echo "  ✗ syntax $s"; fail=$((fail+1)); }; done
zsh -n "$CC/worktree.zsh" && ok "worktree.zsh syntax" || { no "worktree.zsh syntax" x x; }

echo ""
echo "== 10. zsh commands present =="
for fn in gwt-tree gwt-done gwt-undone gwt-merge gwt-collect gwt-adopt gwt-log; do
  grep -q "^$fn()" "$CC/worktree.zsh" && ok "$fn defined" || no "$fn defined" missing present
done

echo "== 11. docs mention new commands =="
grep -q "gwt-merge" "$CC/worktree.zsh" && grep -q "gwt-merge" "$CC/README.md" \
  && ok "gwt-merge documented" || no "gwt-merge documented" missing present
grep -q "gwt-done" "$CC/README.md" && ok "gwt-done documented" || no "gwt-done documented" missing present
grep -q "gwt-adopt" "$CC/README.md" && ok "gwt-adopt documented" || no "gwt-adopt documented" missing present
grep -q "gwt-log" "$CC/README.md" && ok "gwt-log documented" || no "gwt-log documented" missing present
grep -q "cc-board.sh" "$CC/README.md" && ok "cc-board.sh documented" || no "cc-board.sh documented" missing present

echo ""
echo "result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
