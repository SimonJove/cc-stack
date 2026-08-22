#!/usr/bin/env bash
# cc-stack · smoke test (pure logic, no real cmux tab needed). Guards the regressions we've hit:
#   hook parsing (A path / B cross-repo / unresolvable-target-doesn't-dispatch / non-add-doesn't-trigger / CC_WT_PROMPT), tasks-log, prune/drop, trust add/remove,
#   status-hook (agent-state sidecar writes, Notification classification, gwt-status rendering, install registration).
# Usage: bash ~/.config/cc-stack/test.sh
set -u
# Test the copy of cc-stack this script lives in (a worktree checkout tests itself), fallback to the default install.
CC="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)"; CC="${CC:-$HOME/.config/cc-stack}"
pass=0; fail=0
ok(){ echo "  ✔ $1"; pass=$((pass+1)); }
no(){ echo "  ✗ $1  expected[$3] got[$2]"; fail=$((fail+1)); }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

# ── Live-state isolation ──────────────────────────────────────────────────────────────────────
# The suite must never write the human's real ledgers or trust store. "Add an override at every
# call site" has now failed twice (leaked cmux workspaces, then §19b's `gwt-rm wtguard --branch`
# rewriting the live TSVs), so isolation is two layers instead of a habit:
#   1. SANDBOX — the four ledger vars and the trust-store override are exported here, so a call
#      site that forgets an override lands in a temp dir instead of the live file. Sections that
#      used to `unset` these now call cc_sandbox_ledgers to return to the sandbox, never to the
#      live default path.
#   2. TAIL ASSERTION (§24) — the live files are snapshotted now and re-checked at the end.
#      What it can assert is constrained by churn: a board read prunes-on-read (rewriting
#      worktree-tasks.tsv) and any live agent's status hook rewrites worktree-status.tsv, so
#      neither sha nor mtime is attributable to this suite. The oracles that ARE attributable:
#      nothing pre-existing may DISAPPEAR (rows, files, trust entries), no fixture path may
#      appear, no lock may be left behind, and the overrides must still be sandboxed at the end.
CC_TEST_SANDBOX="$(mktemp -d)"
cc_sandbox_ledgers(){
  export CC_TASKS_FILE="$CC_TEST_SANDBOX/worktree-tasks.tsv"
  export CC_STATUS_FILE="$CC_TEST_SANDBOX/worktree-status.tsv"
  export CC_ARCHIVE_FILE="$CC_TEST_SANDBOX/worktree-tasks-archive.tsv"
  export CC_TABS_FILE="$CC_TEST_SANDBOX/opened-tabs.tsv"
  export CC_TRUST_CFG_OVERRIDE="$CC_TEST_SANDBOX/claude.json"
  rm -f "$CC_TASKS_FILE" "$CC_STATUS_FILE" "$CC_ARCHIVE_FILE" "$CC_TABS_FILE"
  printf '{"projects":{}}\n' > "$CC_TRUST_CFG_OVERRIDE"
}
cc_sandbox_ledgers
CC_LIVE_DIR="$HOME/.config/cc-stack"
CC_LIVE_LEDGERS="worktree-tasks.tsv worktree-status.tsv worktree-tasks-archive.tsv opened-tabs.tsv"
_mt(){ stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
# Which live ledgers exist, and their sha/mtime. Existence is an ASSERTION (a rewrite that filters
# a ledger empty deletes it); sha/mtime are printed as diagnostics only — see the churn note above.
_cc_live_files(){
  local n f
  for n in $CC_LIVE_LEDGERS; do
    f="$CC_LIVE_DIR/$n"
    if [ -e "$f" ]; then echo "$n present sha=$(shasum -a 256 < "$f" | awk '{print $1}') mtime=$(_mt "$f")"
    else echo "$n ABSENT"; fi
  done
}
_cc_live_exist(){ _cc_live_files | awk '{print $1, $2}'; }
# Key sets — the attributable oracle. Outside traffic only ADDS or UPDATES rows; a leak DROPS them.
# tasks/tabs rows can also be checked for fixture paths: every temp dir this suite makes is rooted
# in the OS temp tree, so the count of live rows pointing there must not grow.
_cc_live_keys(){
  cut -f4 "$CC_LIVE_DIR/worktree-tasks.tsv"   2>/dev/null | sed 's/^/task /'
  cut -f1 "$CC_LIVE_DIR/worktree-status.tsv"  2>/dev/null | sed 's/^/stat /'
  cut -f1 "$CC_LIVE_DIR/opened-tabs.tsv"      2>/dev/null | sed 's/^/tab  /'
  cut -f4 "$CC_LIVE_DIR/worktree-tasks-archive.tsv" 2>/dev/null | sed 's/^/arch /'
}
_cc_live_keys_sorted(){ _cc_live_keys | LC_ALL=C sort -u; }
_cc_live_tmp_rows(){ _cc_live_keys | grep -cE ' (/private)?(/var/folders/|/tmp/)' || true; }
# Layer 1's own integrity: count overrides that no longer point into the sandbox. Defined as a
# function on purpose — bash 3.2 mis-parses a `case` pattern's `)` inside a `$( )` substitution.
_cc_overrides_escaped(){
  local v n=0
  for v in "$CC_TASKS_FILE" "$CC_STATUS_FILE" "$CC_ARCHIVE_FILE" "$CC_TABS_FILE" "$CC_TRUST_CFG_OVERRIDE"; do
    case "$v" in "$CC_TEST_SANDBOX"/*) ;; *) n=$((n+1)) ;; esac
  done
  echo "$n"
}
# ~/.claude.json likewise churns (a running claude rewrites lastCost etc.), but cc-trust.sh only
# ever adds or deletes a projects KEY — that is the part worth watching.
_cc_trust_keys(){ python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for k in (d.get("projects") or {}): print(k)' "$HOME/.claude.json" | LC_ALL=C sort -u; }
# install / hook-registration tests run under a fake HOME; the live registrations must not move.
_cc_settings_hooks(){ python3 -c 'import json,sys,hashlib
try: d=json.load(open(sys.argv[1]))
except Exception: print("ABSENT"); sys.exit(0)
print(hashlib.sha256(json.dumps(d.get("hooks"),sort_keys=True).encode()).hexdigest())' "$HOME/.claude/settings.json"; }
CC_LIVE_FILES_BEFORE="$(_cc_live_files)"
CC_LIVE_EXIST_BEFORE="$(_cc_live_exist)"
CC_LIVE_HOOKS_BEFORE="$(_cc_settings_hooks)"
CC_LIVE_TMPROWS_BEFORE="$(_cc_live_tmp_rows)"
_cc_live_keys_sorted > "$CC_TEST_SANDBOX/live-keys.before"
_cc_trust_keys       > "$CC_TEST_SANDBOX/trust-keys.before"

echo "== 1. hook parser =="
# extract the worktree python (the ONLY <<'PY' heredoc in cc-hooks.sh)
# unique per run: a fixed path here let two suites running in parallel overwrite each other
EP1="$(mktemp /tmp/cctest-ep.XXXXXX)"
awk "/<<'PY'/{f=1;next} /^PY\$/{f=0} f" "$CC/cc-hooks.sh" > "$EP1"
run(){ CC_HOOK_INPUT="$1" python3 "$EP1" 2>/dev/null; }
rer(){ CC_HOOK_INPUT="$1" python3 "$EP1" 2>&1 >/dev/null; }   # the no-dispatch REASON (stderr only)
pay(){ python3 -c "import json,sys;print(json.dumps({'tool_name':'Bash','cwd':sys.argv[1],'tool_input':{'command':sys.argv[2]}}))" "$1" "$2"; }
R1=$(mktemp -d); ( cd "$R1"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  git worktree add -q wtC -b feat/C >/dev/null; git worktree add -q wtD -b feat/D >/dev/null )
touch "$R1/wtD/x"; touch "$R1/wtD"       # wtD is the NEWEST linked worktree — what the deleted mtime guess used to pick
C="$(cd "$R1/wtC" && pwd -P)"
# Dispatch now requires an initial prompt (§27 owns that gate), so every path fixture here carries one.
P="CC_WT_PROMPT='doX' "
eq "A parsed path (relative)"  "$(run "$(pay "$R1" "${P}git worktree add wtC -b feat/C")" | cut -f1)" "$C"
eq "A -b before path"          "$(run "$(pay "$R1" "${P}git worktree add -b feat/C wtC")" | cut -f1)" "$C"
eq "A absolute path"           "$(run "$(pay "$R1" "${P}git worktree add $R1/wtC -b feat/C")" | cut -f1)" "$C"
# emit protocol: path \t mode \t base \t prompt — the prompt stays LAST (free text, may hold TABs)
eq "CC_WT_PROMPT extraction"   "$(run "$(pay "$R1" "CC_WT_PROMPT='doX' git worktree add wtC")" | cut -f4)" "doX"
eq "CC_WT_PERMISSION_MODE extraction" "$(run "$(pay "$R1" "CC_WT_PERMISSION_MODE=plan CC_WT_PROMPT='doX' git worktree add wtC")" | cut -f2)" "plan"
# base = the 2nd bare positional of `worktree add`. It becomes the recorded merge target (§9), the
# only thing that still separates the campaign branch from a sibling after a ff equalizes their tips.
eq "base parsed (after path)"  "$(run "$(pay "$R1" "${P}git worktree add wtC -b feat/C feat/base")" | cut -f3)" "feat/base"
eq "base parsed (-b first)"    "$(run "$(pay "$R1" "${P}git worktree add -b feat/C wtC feat/base")" | cut -f3)" "feat/base"
eq "no base → empty field"     "$(run "$(pay "$R1" "${P}git worktree add wtC -b feat/C")" | cut -f3)" ""
eq "no base → prompt still f4" "$(run "$(pay "$R1" "${P}git worktree add wtC -b feat/C")" | cut -f4)" "doX"
# anti-double-tab skip must test only the REAL command: a brief that merely MENTIONS a script name
# (inside the single-quoted CC_WT_PROMPT payload) still dispatches; a command that actually invokes
# cc-dispatch.sh wt-claude opens its own tab, so the hook must not open a second one
eq "brief naming scripts dispatches" "$(run "$(pay "$R1" "CC_WT_PROMPT='read cc-dispatch.sh cc-worktree-claude.sh cc-cmux-surface-claude.sh first' git worktree add wtC")" | cut -f1)" "$C"
eq "dispatcher command skipped"     "$(run "$(pay "$R1" "CC_WT_PROMPT='seed corpus' cc-dispatch.sh wt-claude wtC && git worktree add wtC -b feat/C")" | cut -f1)" ""
R2=$(mktemp -d); ( cd "$R2"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git worktree add -q wtX -b feat/X >/dev/null )
X="$(cd "$R2/wtX" && pwd -P)"
eq "B cross-repo -C"           "$(run "$(pay "$R1" "${P}git -C $R2 worktree add wtX")" | cut -f1)" "$X"
# an unresolvable -C does not cost us an ABSOLUTE target: a linked worktree names its own repo
eq "B unresolvable -C, abs path" "$(run "$(pay "$R1" "${P}"'git -C $root worktree add '"$R1/wtC")" | cut -f1)" "$C"
eq "non-add (list) no trigger"   "$(run "$(pay "$R1" "${P}git worktree list")")" ""
eq "non-add (remove) no trigger" "$(run "$(pay "$R1" "${P}git worktree remove wtC")")" ""
# WAS "$VAR fallback (to mtime)": an unpinnable target used to fall back to the newest worktree, which
# is how a tab got opened on an unrelated dir (2026-08-16: a second claude inside a working sub-task).
# Now it dispatches NOTHING and says why on stderr — the shell turns that into the cc-failures.log line (§27).
D="$(cd "$R1/wtD" && pwd -P)"
UN1="$(pay "$R1" "${P}"'git -C $root worktree add $root/wtNope')"
eq "unpinnable target: no dispatch" "$(run "$UN1")" ""
eq "…not even the newest worktree"  "$(run "$UN1" | grep -cF "$D")" "0"
eq "unpinnable target: reason out"  "$(rer "$UN1" | cut -f1)" "CCWT_UNRESOLVED"
eq "reason carries the add target"  "$(rer "$UN1" | cut -f3)" '$root/wtNope'
# a target that parses but is NOT a linked worktree (the add failed / plain dir) is unpinnable too —
# PostToolUse fires whether the command succeeded or not
mkdir -p "$R1/plain"
eq "non-worktree target: no dispatch" "$(run "$(pay "$R1" "${P}git worktree add plain -b feat/P")")" ""
rm -rf "$R1" "$R2" "$EP1"

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
rm -rf "$RT" "$RT2"; rm -f "$CC_TASKS_FILE"; cc_sandbox_ledgers   # back to the sandbox, NOT the live default

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
rm -rf "$IH" "$RR" "$SB" "$NB" "$RD" "$RD2"; rm -f "$CC_TASKS_FILE" "$CC_STATUS_FILE"; cc_sandbox_ledgers

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
rm -rf "$BRD" "$OTH" "$NORD"; rm -f "$CC_TASKS_FILE" "$CC_STATUS_FILE" "$CC_ARCHIVE_FILE" "$TF" "$SF" "$AF" "$DF"; cc_sandbox_ledgers

echo "== 20. TSV empty-field integrity + worktree lifecycle guards =="
# F1 (P0, 2026-08-16 audit): TAB is IFS *whitespace*, so `while IFS=$'\t' read -r a b c …`
# collapses RUNS of it — one empty field shifts every later field left. A rewriter that then
# re-printf's those shifted variables writes the corruption BACK to disk (prune-on-read,
# _gwt_tasks_rewrite, _gwt_archive_branch, gwt-prune all did). Consequences on a shifted row:
# gwt-resume can't find uuid= in the 8th field and degrades the tab to idle; `cc-dispatch.sh
# close` can't find csuuid/suuid and fail-closed refuses to close it. Every read of the two
# TSVs goes through awk -F'\t' now, and every rewrite re-emits $0 verbatim.
cn(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
TT=$(mktemp -u); TS=$(mktemp -u); TA=$(mktemp -u)
export CC_TASKS_FILE="$TT" CC_STATUS_FILE="$TS" CC_ARCHIVE_FILE="$TA"
LA='uuid=11111111-2222-3333-4444-555555555555:provider=kimi:pm=plan:csuuid=AAAA-BBBB:suuid=CCCC-DDDD'
E1="$(cn "$(mktemp -d)")"   # 7th field (parent) EMPTY — what a detached-HEAD dispatch writes
E2="$(cn "$(mktemp -d)")"   # 5th field (caller) EMPTY
E3="$(cn "$(mktemp -d)")"   # complete 8-field row (the drop target)
E4="$(cn "$(mktemp -d)")"   # pre-feature 7-field row (backward compat)
now20=$(date +%s)
mkrows(){   # regenerate the fixture — every rewrite path is exercised from a clean file
  printf '2026-01-01 00:00:01\tfeat/E1\tsurface:51\t%s\tsurface:9\tdo E1\t\t%s\n'      "$E1" "$LA" >  "$TT"
  printf '2026-01-01 00:00:02\tfeat/E2\tsurface:52\t%s\t\tdo E2\tfeat/par\t%s\n'       "$E2" "$LA" >> "$TT"
  printf '2026-01-01 00:00:03\tfeat/E3\tsurface:53\t%s\tsurface:9\tdo E3\tmain\t%s\n'  "$E3" "$LA" >> "$TT"
  printf '2026-01-01 00:00:04\tfeat/E4\tsurface:54\t%s\tsurface:1\told 7-field row\tmain\n' "$E4" >> "$TT"
}
shape(){ awk -F'\t' -v d="$2" '$4==d{printf "%s|%s|%s|%s|%s\n", NF, $5, $6, $7, $8}' "$1" 2>/dev/null; }
S_E1="8|surface:9|do E1||$LA"; S_E2="8||do E2|feat/par|$LA"; S_E4="7|surface:1|old 7-field row|main|"
# (a) prune-on-read (cc-board.sh render) — the write-back that fossilizes the shift
mkrows
bash "$CC/cc-board.sh" --all >/dev/null 2>&1
eq "prune keeps an empty PARENT row"    "$(shape "$TT" "$E1")" "$S_E1"
eq "prune keeps an empty CALLER row"    "$(shape "$TT" "$E2")" "$S_E2"
eq "prune keeps a 7-field legacy row"   "$(shape "$TT" "$E4")" "$S_E4"
# (b) render: the board's own columns must not shift either
BE="$(bash "$CC/cc-board.sh" --all 2>/dev/null)"
eq "render PARENT with an empty caller" "$(echo "$BE" | awk -v d="$E2" '$5==d{print $3}')" "feat/par"
eq "render TASK with an empty caller"   "$(echo "$BE" | awk -v d="$E2" '$5==d{$1=$2=$3=$4=$5="";sub(/^ +/,"");print}')" "do E2"
eq "render PARENT '-' when unresolvable" "$(echo "$BE" | awk -v d="$E1" '$5==d{print $3}')" "-"
# (c) _gwt_tasks_rewrite (the gwt-rm / gwt-prune path)
mkrows
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; CC_TASKS_FILE='$TT' _gwt_tasks_drop_dir '$E3'" >/dev/null 2>&1
eq "rewrite drops the target row"       "$(cat "$TT" 2>/dev/null | grep -c 'do E3')" "0"
eq "rewrite keeps an empty PARENT row"  "$(shape "$TT" "$E1")" "$S_E1"
eq "rewrite keeps an empty CALLER row"  "$(shape "$TT" "$E2")" "$S_E2"
eq "rewrite keeps a 7-field legacy row" "$(shape "$TT" "$E4")" "$S_E4"
# (d) gwt-prune: dead-dir sweep + newest-per-dir dedup, still verbatim
mkrows
{ printf '2026-01-01 00:00:00\tfeat/E2\tsurface:50\t%s\t\tolder E2 row\tfeat/par\t%s\n' "$E2" "$LA"; cat "$TT"; } > "$TT.x" && mv "$TT.x" "$TT"
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$E1'; CC_TASKS_FILE='$TT' CC_STATUS_FILE='$TS' gwt-prune" >/dev/null 2>&1
eq "gwt-prune drops the older dup"      "$(cat "$TT" 2>/dev/null | grep -c 'older E2 row')" "0"
eq "gwt-prune keeps an empty CALLER row" "$(shape "$TT" "$E2")" "$S_E2"
eq "gwt-prune keeps a 7-field legacy row" "$(shape "$TT" "$E4")" "$S_E4"
# (e) _gwt_archive_branch: merged-at is APPENDED, so 8-field rows → 9, 7-field rows → 8
mkrows; : > "$TA"
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; CC_TASKS_FILE='$TT' CC_STATUS_FILE='$TS' CC_ARCHIVE_FILE='$TA' _gwt_archive_branch feat/E2" >/dev/null 2>&1
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; CC_TASKS_FILE='$TT' CC_STATUS_FILE='$TS' CC_ARCHIVE_FILE='$TA' _gwt_archive_branch feat/E4" >/dev/null 2>&1
eq "archive keeps the empty CALLER"     "$(awk -F'\t' -v d="$E2" '$4==d{printf "%s|%s|%s|%s|%s\n", NF, $5, $6, $7, $8}' "$TA")" "9||do E2|feat/par|$LA"
eq "archive merged-at is 9th on 8-field" "$(awk -F'\t' -v d="$E2" '$4==d{print ($9 ~ /^[0-9]+$/)?"ok":"no"}' "$TA")" "ok"
eq "archive merged-at is 8th on 7-field" "$(awk -F'\t' -v d="$E4" '$4==d{print NF ":" (($8 ~ /^[0-9]+$/)?"ok":"no")}' "$TA")" "8:ok"
# F7: the sidecar (worktree-status.tsv) is swept by the same "does this dir exist?" pass the
# board already runs per row — before this only gwt-prune/gwt-rm touched it and it grew forever.
SLIVE="$(cn "$(mktemp -d)")"; SDEAD="/tmp/cc-board-dead-$$"
mkrows
printf '%s\tworking\t%s\n' "$SLIVE" "$now20"  > "$TS"
printf '%s\tidle\t%s\n'    "$SDEAD" "$now20" >> "$TS"
bash "$CC/cc-board.sh" --all >/dev/null 2>&1
eq "sidecar prune drops a dead dir"     "$(cat "$TS" 2>/dev/null | grep -c "$SDEAD")" "0"
eq "sidecar prune keeps a live dir"     "$(cat "$TS" 2>/dev/null | grep -c "$SLIVE")" "1"
printf '%s\tidle\t%s\n' "$SDEAD" "$now20" >> "$TS"
printf '2026-01-01 00:00:05\tfeat/AR\tsurface:55\t%s\tsurface:1\tarch row\tmain\t%s\n' "$E1" "$LA" > "$TA"
bash "$CC/cc-board.sh" --archive --all >/dev/null 2>&1
eq "archive render spares the sidecar"  "$(cat "$TS" 2>/dev/null | grep -c "$SDEAD")" "1"
printf '%s\tidle\t%s\n' "$SDEAD" "$now20" > "$TS"
bash "$CC/cc-board.sh" --all >/dev/null 2>&1
eq "all-dead sidecar file removed"      "$([ -f "$TS" ] && echo yes || echo no)" "no"
# F2: a worktree whose dir was deleted from OUTSIDE must stay reclaimable. `git worktree remove`
# returns 0 on a gone dir (it prunes the registration); the -d guard added for the partial-shell
# incident bailed before ANY cleanup ran, stranding the registration, the board row, the sidecar
# row and the branch. The guard now falls through to the git registration, never to a blind path.
RMR=$(mktemp -d); RMR="$(cn "$RMR")"
( cd "$RMR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/stale -b feat/stale >/dev/null )
STALEDIR="$RMR/.claude/worktrees/stale"
rm -rf "$STALEDIR"                       # external rm -rf: the dir is gone, the registration is not
printf '2026-01-01 00:00:06\tfeat/stale\tsurface:56\t%s\tsurface:1\tstale ghost row\tmain\t%s\n' "$STALEDIR" "$LA" > "$TT"
printf '%s\tidle\t%s\n' "$STALEDIR" "$now20" > "$TS"
RMO="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$RMR'; CC_TASKS_FILE='$TT' CC_STATUS_FILE='$TS' gwt-rm stale --branch" 2>&1)"; rmrc=$?
eq "gwt-rm reclaims a gone dir (rc 0)"  "$rmrc" "0"
eq "gwt-rm prunes the registration"     "$(git -C "$RMR" worktree list --porcelain | grep -c 'worktrees/stale')" "0"
eq "gwt-rm deletes the stale branch"    "$(git -C "$RMR" branch --list 'feat/stale' | wc -l | tr -d ' ')" "0"
eq "gwt-rm drops the ghost board row"   "$(cat "$TT" 2>/dev/null | grep -c 'stale ghost row')" "0"
eq "gwt-rm drops the ghost sidecar row" "$(cat "$TS" 2>/dev/null | grep -c 'worktrees/stale')" "0"
NEV="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$RMR'; CC_TASKS_FILE='$TT' CC_STATUS_FILE='$TS' gwt-rm neverwas" 2>&1)"; nevrc=$?
eq "gwt-rm unknown name exit!=0"        "$([ "$nevrc" -ne 0 ] && echo y || echo n)" "y"
eq "gwt-rm unknown name says which"     "$(echo "$NEV" | grep -c 'no worktree named')" "1"
# F4: gwt-tree renders DOWN from the trunk, so a node whose merge target no longer exists (the
# README's own `gwt-merge <parent>` → `gwt-rm <parent> --branch` sequence) silently vanished —
# and the merge gate is exactly what gwt-tree is read for. Unreachable nodes get their own block.
TR=$(mktemp -d); TR="$(cn "$TR")"
( cd "$TR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/o1 -b feat/o1 >/dev/null
  git worktree add -q .claude/worktrees/o2 -b feat/o2 >/dev/null )
gtree(){ ( cd "$TR" && CC_TASKS_FILE=/dev/null zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-tree" ) 2>/dev/null; }
git -C "$TR" config branch.feat/o1.ccMergeInto feat/ghost      # parent deleted after its merge
git -C "$TR" config branch.feat/o2.ccMergeInto main
TO="$(gtree)"
eq "tree still renders the trunk child" "$(echo "$TO" | grep -c 'feat/o2')" "1"
eq "tree flags the orphan"              "$(echo "$TO" | grep -c 'orphaned')" "1"
eq "orphan branch is listed"            "$(echo "$TO" | grep -c 'feat/o1')" "1"
eq "orphan names its missing parent"    "$(echo "$TO" | grep 'feat/o1' | grep -c 'feat/ghost')" "1"
git -C "$TR" config branch.feat/o1.ccMergeInto feat/o2         # a cycle: neither is reachable
git -C "$TR" config branch.feat/o2.ccMergeInto feat/o1
TC="$(gtree)"
eq "cycle: trunk still printed"         "$(echo "$TC" | head -1)" "main"
eq "cycle: both nodes surface"          "$(echo "$TC" | grep -c 'feat/o1\|feat/o2')" "2"
eq "cycle: flagged as orphaned"         "$(echo "$TC" | grep -c 'orphaned')" "1"
git -C "$TR" config branch.feat/o1.ccMergeInto main
eq "healthy tree has no orphan block"   "$(gtree | grep -c 'orphaned')" "0"
eq "healthy tree still nests"           "$(gtree | grep -c '├─\|└─')" "2"
# F6: _gwt_dir fails for TWO reasons — the helper is missing (partially loaded shell) or the cwd
# is not a repo. They used to share one message ("source worktree.zsh first") that sent people to
# re-source their shell over a wrong cwd. Both still fail CLOSED (rc 1, nothing touched, §19b).
NOREPO="$(cn "$(mktemp -d)")"
wtp(){ ( cd "$1" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; ${2:-}_gwt_wt_path foo" ) 2>&1; }
eq "_gwt_wt_path outside a repo blames cwd" "$(wtp "$NOREPO")" "✗ not inside a git repo"
eq "_gwt_wt_path outside a repo prints no path" "$( ( cd "$NOREPO" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; _gwt_wt_path foo" ) 2>/dev/null )" ""
eq "_gwt_wt_path partial shell blames shell" "$(wtp "$TR" 'unfunction _gwt_dir 2>/dev/null; ')" "✗ worktree helpers unavailable — source ~/.config/cc-stack/worktree.zsh first"
eq "_gwt_wt_path partial (_gwt_root gone) blames shell" "$(wtp "$TR" 'unfunction _gwt_root 2>/dev/null; ')" "✗ worktree helpers unavailable — source ~/.config/cc-stack/worktree.zsh first"
NRO="$( ( cd "$NOREPO" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; CC_TASKS_FILE='$TT' CC_STATUS_FILE='$TS' gwt-rm foo" ) 2>&1 )"; nrorc=$?
eq "gwt-rm outside a repo exit!=0"      "$([ "$nrorc" -ne 0 ] && echo y || echo n)" "y"
eq "gwt-rm outside a repo blames cwd"   "$(echo "$NRO" | grep -c 'not inside a git repo')" "1"
eq "gwt-rm outside a repo touches nothing" "$(echo "$NRO" | grep -c 'removed\|deleted')" "0"
# F13: the merge-target map is now read ONCE PER REPO instead of once per row, so it must never
# leak across repos (two repos, same branch name, different targets) and must still fall back to
# the per-row `git config` for a row that is not a registered worktree of any repo.
P1=$(mktemp -d); P1="$(cn "$P1")"; P2=$(mktemp -d); P2="$(cn "$P2")"
for P in "$P1" "$P2"; do
  ( cd "$P"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
    mkdir -p .claude; git worktree add -q .claude/worktrees/same -b feat/same >/dev/null )
done
git -C "$P1" config branch.feat/same.ccMergeInto main
git -C "$P2" config branch.feat/same.ccMergeInto release
git -C "$P1" config branch.feat/plain.ccMergeInto main
mkdir -p "$P1/plaindir"                                   # inside repo 1, but not a worktree
printf '2026-01-01 00:00:07\tfeat/same\tsurface:57\t%s\tsurface:1\tsame branch repo1\t\n' "$P1/.claude/worktrees/same" >  "$TT"
printf '2026-01-01 00:00:08\tfeat/same\tsurface:58\t%s\tsurface:1\tsame branch repo2\t\n' "$P2/.claude/worktrees/same" >> "$TT"
printf '2026-01-01 00:00:09\tfeat/plain\tsurface:59\t%s\tsurface:1\tplain dir row\t\n'    "$P1/plaindir"               >> "$TT"
BM="$(bash "$CC/cc-board.sh" --all 2>/dev/null)"
eq "per-repo merge target (repo 1)" "$(echo "$BM" | awk -v d="$P1/.claude/worktrees/same" '$5==d{print $3}')" "main"
eq "per-repo merge target (repo 2)" "$(echo "$BM" | awk -v d="$P2/.claude/worktrees/same" '$5==d{print $3}')" "release"
eq "non-worktree row uses git config" "$(echo "$BM" | awk -v d="$P1/plaindir" '$5==d{print $3}')" "main"
rm -rf "$E1" "$E2" "$E3" "$E4" "$SLIVE" "$RMR" "$TR" "$NOREPO" "$P1" "$P2"
rm -f "$TT" "$TS" "$TA"; cc_sandbox_ledgers   # back to the sandbox, NOT the live default (§24)

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

echo "== 27. hook dispatch decision: intent (CC_WT_PROMPT) + a pinnable target =="
# 2026-08-16 tightening. The hook opens a tab ONLY when BOTH halves are unambiguous:
#   intent — the command carries a non-empty CC_WT_PROMPT (no first instruction = an idle do-nothing
#            tab, which is what bisect helpers / hand-made worktrees / test fixtures used to earn);
#   target — the new worktree path is pinned to a real linked worktree (the "newest mtime" guess is
#            gone; it once opened a second claude inside a dir a sub-task was already working in).
# §1 pins the parser half; this section drives cc-hooks.sh END TO END, entirely on stubs: a fake HOME
# whose cc-dispatch.sh only RECORDS its argv, so a dispatch decision can never reach a real surface,
# plus a fake cmux that answers ping. The gate lives in the HOOK: cc-dispatch.sh surface is unchanged
# and still opens an idle tab when called without a prompt (gwt-resume needs that — §17 guards it).
H27=$(mktemp -d); B27=$(mktemp -d); R27=$(mktemp -d); OP27="$PATH"
mkdir -p "$H27/.config/cc-stack"
cat > "$H27/.config/cc-stack/cc-dispatch.sh" <<'D27'
#!/usr/bin/env bash
printf 'DISPATCH|%s|%s\n' "${CC_WT_PERMISSION_MODE:-}" "$*" >> "$CC_STUB_LOG"
printf 'BASE|%s\n' "${CC_WT_BASE:-}" >> "$CC_STUB_LOG"      # merge target the hook parsed off the add line
exit 0
D27
printf '#!/usr/bin/env bash\nexit 0\n' > "$B27/cmux"            # ping (and anything else) succeeds
chmod +x "$H27/.config/cc-stack/cc-dispatch.sh" "$B27/cmux"
( cd "$R27"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git worktree add -q wt27 -b feat/w27 >/dev/null )
W27="$(cd "$R27/wt27" && pwd -P)"
LG27="$H27/argv"; FL27="$H27/.config/cc-stack/cc-failures.log"
# hook runner: fake HOME + fake cmux, stdout and stderr together (HARD RULES: prints nothing, exits 0)
h27(){ local o rc
  o="$(printf '%s' "$1" | env HOME="$H27" PATH="$B27:$OP27" CC_STUB_LOG="$LG27" \
        ${3:+CC_SEND_FAILLOG="$3"} bash "$CC/cc-hooks.sh" worktree 2>&1)"; rc=$?
  eq "$2 silent" "$o" ""; eq "$2 exit0" "$rc" "0"
}
dis27(){ grep -c '^DISPATCH|' "$LG27" 2>/dev/null || true; }
res27(){ : > "$LG27"; rm -f "$FL27" "$H27/alt.log"; }
# (a) both halves present → exactly one dispatch, carrying dir + prompt + the permission mode, no breadcrumb
res27
h27 "$(pay "$R27" "CC_WT_PERMISSION_MODE=plan CC_WT_PROMPT='do 27' git worktree add wt27 -b feat/w27")" "dispatch"
eq "prompt+target → one dispatch"   "$(dis27)" "1"
eq "dispatch carries dir + prompt"  "$(grep -cF "|surface $W27 do 27" "$LG27")" "1"
eq "permission mode exported"       "$(awk -F'|' 'NR==1{print $2}' "$LG27")" "plan"
eq "a dispatch leaves no crumb"     "$([ -e "$FL27" ] && echo some || echo none)" "none"
eq "no base on the add line → empty CC_WT_BASE" "$(grep -c '^BASE|$' "$LG27")" "1"
# (a2) an explicit base travels to cc-dispatch.sh as CC_WT_BASE — that is what makes it the
# recorded merge target instead of whatever branch the dispatching session happened to stand on
res27
h27 "$(pay "$R27" "CC_WT_PROMPT='do 27' git worktree add wt27 -b feat/w27 camp27")" "dispatch with base"
eq "base reaches the dispatch"      "$(grep -c '^BASE|camp27$' "$LG27")" "1"
eq "base does not disturb the prompt" "$(grep -cF "|surface $W27 do 27" "$LG27")" "1"
# (b) no intent → no tab, and NO breadcrumb: skipping is the normal case here, not a failure
res27
h27 "$(pay "$R27" 'git worktree add wt27 -b feat/w27')" "no CC_WT_PROMPT"
eq "no prompt → no dispatch"        "$(dis27)" "0"
eq "no prompt → no crumb"           "$([ -e "$FL27" ] && echo some || echo none)" "none"
res27
h27 "$(pay "$R27" "CC_WT_PROMPT='' git worktree add wt27")" "empty CC_WT_PROMPT"
eq "empty prompt → no dispatch"     "$(dis27)" "0"
res27
h27 "$(pay "$R27" "CC_WT_PROMPT='   ' git worktree add wt27")" "blank CC_WT_PROMPT"
eq "blank prompt → no dispatch"     "$(dis27)" "0"
eq "blank prompt → no crumb"        "$([ -e "$FL27" ] && echo some || echo none)" "none"
# (c) intent without a pinnable target → no tab, ONE breadcrumb (a dispatch that was meant to happen
# and did not must stay visible; cc-board.sh reads the last 24h of this file)
res27
h27 "$(pay "$R27" "CC_WT_PROMPT='do 27' "'git -C $root worktree add $root/wtNope')" "unpinnable target"
eq "unpinnable → no dispatch"       "$(dis27)" "0"
eq "unpinnable → one crumb line"    "$(wc -l < "$FL27" | tr -d ' ')" "1"
eq "crumb says path unresolved"     "$(grep -c 'worktree path unresolved' "$FL27")" "1"
eq "crumb names the add target"     "$(grep -cF 'add target: $root/wtNope' "$FL27")" "1"
eq "crumb hints the manual form"    "$(grep -c 'gwt-claude <name>' "$FL27")" "1"
# the board filters by a leading [timestamp] and renders "<locator> — <what>": pin that shape
eq "crumb in board format"          "$(grep -cE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] .+ — ' "$FL27")" "1"
# and the crumb path is overridable exactly like every other dispatch breadcrumb (tests, sandboxes)
res27
h27 "$(pay "$R27" "CC_WT_PROMPT='do 27' "'git -C $root worktree add $root/wtNope')" "crumb override" "$H27/alt.log"
eq "CC_SEND_FAILLOG takes the crumb" "$(wc -l < "$H27/alt.log" | tr -d ' ')" "1"
eq "default crumb path untouched"    "$([ -e "$FL27" ] && echo some || echo none)" "none"
rm -rf "$H27" "$B27" "$R27"

echo "== 28. merge target chain: capture contract + dispatch echo (F1-F9) =="
# The 2026-08-21 audit line: "which branch does this line merge into" had three independent
# answers (hook parse, cc-merge capture, board registration) that could disagree silently.
# capture is now the single arbiter AND reports what it recorded.

# ── F1: the hook tokenizer under the spellings the rules doc encourages (§1 pins happy paths) ──
EP28="$(mktemp /tmp/cctest-28.XXXXXX)"   # same parallel-run collision hazard as §1's helper
awk "/<<'PY'/{f=1;next} /^PY\$/{f=0} f" "$CC/cc-hooks.sh" > "$EP28"
run28(){ CC_HOOK_INPUT="$1" python3 "$EP28" 2>/dev/null; }
R28=$(mktemp -d); ( cd "$R28"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main; git branch camp
  git worktree add -q wtC -b feat/C camp >/dev/null )
C28="$(cd "$R28/wtC" && pwd -P)"
P28="CC_WT_PROMPT='doX' "
eq "F1 base survives glued ;"       "$(run28 "$(pay "$R28" "${P28}git worktree add wtC -b feat/C camp; bash cc-board.sh")" | cut -f3)" "camp"
eq "F1 base survives glued &&"      "$(run28 "$(pay "$R28" "${P28}git worktree add wtC -b feat/C camp&& echo ok")" | cut -f3)" "camp"
eq "F1 base after glued redirect"   "$(run28 "$(pay "$R28" "${P28}git worktree add wtC -b feat/C 2>/dev/null camp")" | cut -f3)" "camp"
eq "F1 base after spaced redirect"  "$(run28 "$(pay "$R28" "${P28}git worktree add wtC -b feat/C 2> /dev/null camp")" | cut -f3)" "camp"
eq "F1 base before trailing redir"  "$(run28 "$(pay "$R28" "${P28}git worktree add wtC -b feat/C camp 2>&1")" | cut -f3)" "camp"
eq "F1 merged -fb keeps the path"   "$(run28 "$(pay "$R28" "${P28}git worktree add -fb feat/C wtC camp")" | cut -f1)" "$C28"
eq "F1 merged -fb keeps the base"   "$(run28 "$(pay "$R28" "${P28}git worktree add -fb feat/C wtC camp")" | cut -f3)" "camp"
eq "F1 redir then glued ;: no base"     "$(run28 "$(pay "$R28" "${P28}git worktree add wtC -b feat/C >/dev/null;")" | cut -f3)" ""
eq "F1 opt then glued ;: no base"        "$(run28 "$(pay "$R28" "${P28}git worktree add wtC -b feat/C --detach;")" | cut -f3)" ""
eq "F1 base glued-; command keeps base"  "$(run28 "$(pay "$R28" "${P28}git worktree add wtC -b feat/C camp;echo ok")" | cut -f3)" "camp"
eq "F1 base glued-&& command keeps base" "$(run28 "$(pay "$R28" "${P28}git worktree add wtC -b feat/C camp&&echo ok")" | cut -f3)" "camp"
rm -f "$EP28"

# ── capture NEW CONTRACT: one line "target=<branch>\tsource=<explicit|cwd|trunk|kept>" (F4) ──
# explicit = the base names a local branch; cwd/trunk = fallback chain; kept = the branch
# already carries a target and this call brings no explicit branch base (F6: reused branch).
git -C "$R28" branch f/e1
eq "contract: explicit base"        "$("$CC/cc-merge.sh" capture "$R28" f/e1 "$R28" camp 2>/dev/null)" "$(printf 'target=camp\tsource=explicit')"
git -C "$R28" branch f/e2
eq "F2 origin/x WITH local x"       "$("$CC/cc-merge.sh" capture "$R28" f/e2 "$R28" origin/camp 2>/dev/null)" "$(printf 'target=camp\tsource=explicit')"
git -C "$R28" branch f/e3
eq "F2 origin fallback: cwd source" "$("$CC/cc-merge.sh" capture "$R28" f/e3 "$R28" origin/nope 2>/dev/null)" "$(printf 'target=main\tsource=cwd')"
eq "F2 origin/x w/o local: warns"   "$("$CC/cc-merge.sh" capture "$R28" f/e3 "$R28" origin/nope 2>&1 >/dev/null | grep -c 'no local branch')" "1"
git -C "$R28" branch f/e4
eq "F2 non-branch base: cwd source" "$("$CC/cc-merge.sh" capture "$R28" f/e4 "$R28" '$VAR' 2>/dev/null)" "$(printf 'target=main\tsource=cwd')"
eq "F2 non-branch base: warns"      "$("$CC/cc-merge.sh" capture "$R28" f/e4 "$R28" '$VAR' 2>&1 >/dev/null | grep -c 'not a local branch')" "1"
git -C "$R28" branch f/e5
eq "contract: cwd fallback"         "$("$CC/cc-merge.sh" capture "$R28" f/e5 "$R28" "")" "$(printf 'target=main\tsource=cwd')"
eq "HEAD (wt-claude default) stays quiet" "$("$CC/cc-merge.sh" capture "$R28" f/e5 "$R28" HEAD 2>&1 >/dev/null | wc -l | tr -d ' ')" "0"
git -C "$R28" worktree add -q wtD28 --detach camp >/dev/null
git -C "$R28" branch f/e7
eq "F3 detached caller: trunk source" "$("$CC/cc-merge.sh" capture "$R28" f/e7 "$R28/wtD28" "")" "$(printf 'target=main\tsource=trunk')"
git -C "$R28" branch f/e8
eq "self-target still prints nothing"  "$("$CC/cc-merge.sh" capture "$R28" f/e8 "$R28" f/e8)" ""
eq "self-target writes no config"      "$(git -C "$R28" config branch.f/e8.ccMergeInto 2>/dev/null)" ""

# ── F6: a reused branch must not lose the target an earlier --base recorded ──
git -C "$R28" branch f/e6
"$CC/cc-merge.sh" set-parent "$R28" f/e6 feat/keep
eq "F6 HEAD capture keeps the target" "$("$CC/cc-merge.sh" capture "$R28" f/e6 "$R28" HEAD)" "$(printf 'target=feat/keep\tsource=kept')"
eq "F6 config survives untouched"     "$(git -C "$R28" config branch.f/e6.ccMergeInto)" "feat/keep"
eq "F6 explicit base still overwrites" "$("$CC/cc-merge.sh" capture "$R28" f/e6 "$R28" camp 2>/dev/null)" "$(printf 'target=camp\tsource=explicit')"
eq "F6 config now the explicit one"   "$(git -C "$R28" config branch.f/e6.ccMergeInto)" "camp"
git -C "$R28" branch f/e9
git -C "$R28" config branch.f/e9.ccMergeInto f/e9   # self-target: dirty data, not intent
eq "F6 self-kept skips kept path" "$("$CC/cc-merge.sh" capture "$R28" f/e9 "$C28" "" 2>/dev/null)" "$(printf 'target=feat/C\tsource=cwd')"

# ── capture-dispatch: the echo both dispatch paths show (F4) ──
git -C "$R28" branch f/d1
CR28=$(mktemp -u)
eq "echo: explicit base"            "$("$CC/cc-merge.sh" capture-dispatch "$R28" f/d1 "$R28" camp)" "✔ merge target: camp (explicit --base)"
eq "explicit: no crumb even asked"  "$(CC_CAPTURE_CRUMB=1 CC_SEND_FAILLOG="$CR28" "$CC/cc-merge.sh" capture-dispatch "$R28" f/d1 "$R28" camp >/dev/null 2>&1; [ -e "$CR28" ] && echo some || echo none)" "none"
git -C "$R28" branch f/d2
eq "echo: fallback warns"           "$(CC_SEND_FAILLOG="$CR28" "$CC/cc-merge.sh" capture-dispatch "$R28" f/d2 "$R28" "" 2>/dev/null)" "⚠ merge target: main (from cwd — no explicit base; cc-merge.sh set-parent to change)"
eq "no crumb unless CC_CAPTURE_CRUMB=1" "$([ -e "$CR28" ] && echo some || echo none)" "none"
CC_CAPTURE_CRUMB=1 CC_SEND_FAILLOG="$CR28" "$CC/cc-merge.sh" capture-dispatch "$R28" f/d2 "$R28" "" >/dev/null 2>&1
eq "crumb written when asked"       "$(grep -c 'merge target for f/d2 recorded as: main' "$CR28")" "1"
git -C "$R28" branch f/d3
eq "warnings pass through"          "$(CC_SEND_FAILLOG="$CR28" "$CC/cc-merge.sh" capture-dispatch "$R28" f/d3 "$R28" origin/nope 2>&1 >/dev/null | grep -c 'no local branch')" "1"

# ── F5 end-to-end: the board row PARENT is what capture recorded, not the caller branch ──
# §17D pattern: fake HOME holding a copy of THIS checkout, fake cmux, scratch TSVs. The hook
# path also leaves the no-base breadcrumb (its stdout is swallowed by Claude Code).
F5H=$(mktemp -d); F5B=$(mktemp -d); F5L=$(mktemp -u)
mkdir -p "$F5H/.config"; cp -R "$CC" "$F5H/.config/cc-stack"
cat > "$F5B/cmux" <<'F5C'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  identify) echo '{ "caller": {} }' ;;
  list-pane-surfaces) cat "${CC_FAKE_LIVE:-/dev/null}" 2>/dev/null ;;
  new-surface)
    n=$(cat "${CC_FAKE_LOG}.nscnt" 2>/dev/null || echo 200); n=$((n+1)); echo "$n" > "${CC_FAKE_LOG}.nscnt"
    printf 'NEWSURF|surface:%s|%s\n' "$n" "$*" >> "$CC_FAKE_LOG"; echo "opened surface:$n" ;;
  send) shift; printf 'SEND|%s\n' "$*" >> "$CC_FAKE_LOG" ;;
  send-key) shift; printf 'KEY|%s\n' "$*" >> "$CC_FAKE_LOG" ;;
  notify) shift; printf 'NOTIFY|%s\n' "$*" >> "$CC_FAKE_LOG" ;;
  read-screen) cat "$CC_FAKE_SCREEN" 2>/dev/null ;;
esac
exit 0
F5C
chmod +x "$F5B/cmux"
export CC_FAKE_LOG="$F5B/log"; export CC_FAKE_SCREEN="$F5B/screen"
NB28="$(printf '\xc2\xa0')"
{ echo "RDY22"; printf '\xe2\x9d\xaf%s\n' "$NB28"; echo "? for shortcuts"; } > "$CC_FAKE_SCREEN"
cn28(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
mkd28(){ _d=$(mktemp -d); _d="$(cn28 "$_d")"; ( cd "$_d"; git init -q; git config user.email t@t
  git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  git branch camp; git checkout -q -b feat/x28 ); echo "$_d"; }
D5A="$(mkd28)"
env HOME="$F5H" PATH="$F5B:$PATH" CC_TASKS_FILE="$F5L" CC_SEND_FAILLOG="$F5B/fail" \
  CC_SEND_VERIFY_SEC=0.1 CC_WT_SHARE="" CC_WT_PRETRUST=0 CC_CALLER_CWD="$R28" CC_WT_BASE=camp \
  bash "$CC/cc-dispatch.sh" surface "$D5A" "F5 brief" >/dev/null 2>&1
eq "F5 board parent = capture target" "$(awk -F'\t' -v d="$D5A" '$4==d{print $7}' "$F5L")" "camp"
eq "F5 capture really recorded it"   "$(git -C "$D5A" config branch.feat/x28.ccMergeInto)" "camp"
eq "F5 explicit base: no capture crumb" "$([ -f "$F5B/fail" ] && { grep -c 'merge target' "$F5B/fail" || true; } || echo 0)" "0"
# …and the wt-claude path ECHOES the target to the human dispatching it (F4)
WTOUT28="$( cd "$D5A" && env HOME="$F5H" PATH="$F5B:$PATH" CC_TASKS_FILE="$F5L" \
  CC_SEND_FAILLOG="$F5B/fail" CC_SEND_VERIFY_SEC=0.1 CC_WT_SHARE="" CC_WT_PRETRUST=0 \
  bash "$CC/cc-dispatch.sh" wt-claude t28 "wt-claude brief" --base camp 2>&1 )"
eq "F4 wt-claude echoes the target"  "$(echo "$WTOUT28" | grep -c 'merge target: camp (explicit --base)')" "1"
# same drive WITHOUT a base: target falls back to the caller branch + a breadcrumb is left
D5B="$(mkd28)"
: > "$F5B/fail"
env HOME="$F5H" PATH="$F5B:$PATH" CC_TASKS_FILE="$F5L" CC_SEND_FAILLOG="$F5B/fail" \
  CC_SEND_VERIFY_SEC=0.1 CC_WT_SHARE="" CC_WT_PRETRUST=0 CC_CALLER_CWD="$R28" \
  bash "$CC/cc-dispatch.sh" surface "$D5B" "F5 brief 2" >/dev/null 2>&1
eq "F5 no-base parent = caller branch" "$(awk -F'\t' -v d="$D5B" '$4==d{print $7}' "$F5L")" "main"
eq "F5 no-base leaves a crumb"     "$(grep -c 'merge target for feat/x28 recorded as: main (source: cwd)' "$F5B/fail")" "1"
rm -rf "$F5H" "$F5B" "$D5A" "$D5B"; rm -f "$F5L" "$CR28"
rm -f "${TMPDIR:-/tmp}/cc-cmux-tabs/$(printf '%s' "$D5A" | shasum -a 1 | cut -d' ' -f1)" \
      "${TMPDIR:-/tmp}/cc-cmux-tabs/$(printf '%s' "$D5B" | shasum -a 1 | cut -d' ' -f1)" 2>/dev/null
unset CC_FAKE_LOG CC_FAKE_SCREEN

# ── F7: gwt-rm without --branch leaves exactly this shape — the branch must stay visible ──
"$CC/cc-merge.sh" set-parent "$R28" feat/C camp
eq "F7 live branch listed exactly once" "$("$CC/cc-merge.sh" tree "$R28" | awk -F'\t' '$1=="feat/C"{c++} END{print c+0}')" "1"
"$CC/cc-merge.sh" done "$R28" feat/C true
git -C "$R28" worktree remove wtC >/dev/null 2>&1
eq "F7 worktree-less branch still listed" "$("$CC/cc-merge.sh" tree "$R28" | awk -F'\t' '$1=="feat/C"{print $2"\t"$4"\t"$5}')" "$(printf 'camp\tclean\tdone')"
# the mirror image: a config section whose branch is GONE is a ghost node, not a line — a
# hand-edited section must not gain a tree row that gates its parent ready-check forever
git -C "$R28" config branch.feat/ghost28.ccMergeInto camp
eq "F7 ghost config row not listed" "$("$CC/cc-merge.sh" tree "$R28" | awk -F'\t' '$1=="feat/ghost28"' | wc -l | tr -d ' ')" "0"

# ── F8: python3 is the per-tool-call cost — pay it only when the payload can matter ──
F8H=$(mktemp -d); F8B=$(mktemp -d); PY28="$(command -v python3)"
mkdir -p "$F8H/.config/cc-stack"
printf '#!/usr/bin/env bash\nexit 0\n' > "$F8H/.config/cc-stack/cc-dispatch.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$F8B/cmux"
cat > "$F8B/python3" <<F8P
#!/usr/bin/env bash
echo x >> "\${CC_PY_LOG:-/dev/null}"
exec "$PY28" "\$@"
F8P
chmod +x "$F8H/.config/cc-stack/cc-dispatch.sh" "$F8B/cmux" "$F8B/python3"
git -C "$R28" worktree add -q wtF8 -b feat/F8 camp >/dev/null   # fresh target for the add payload
CNT28="$F8B/pycount"
h28(){ : > "$CNT28"; printf '%s' "$1" | env HOME="$F8H" PATH="$F8B:$PATH" CC_PY_LOG="$CNT28" \
      CC_STUB_LOG="$F8H/argv" bash "$CC/cc-hooks.sh" "$2" >/dev/null 2>&1; wc -l < "$CNT28" | tr -d ' '; }
# a sub-task cwd sits under .claude/worktrees/ — the old prefilter started python3 on EVERY
# plain Bash call of every sub-task (the "worktree" substring came from the cwd alone)
eq "F8 sub-task cwd + ls: no python"   "$(h28 "$(pay "$R28/.claude/worktrees/x" "ls")" worktree)" "0"
# (7) the killer case: sub-task cwd (worktree substring) + the MOST frequent sub-task command
# — "git add -A". The two-word prefilter started python on every one of these.
eq "F8 cwd + git add -A: no python"    "$(h28 "$(pay "$R28/.claude/worktrees/x" "git add -A")" worktree)" "0"
# a real dispatch still parses: once for the heredoc, once for the caller-cwd extraction
eq "F8 real add still parses"          "$(h28 "$(pay "$R28" "${P28}git worktree add wtF8 -b feat/F8 camp")" worktree)" "2"
# the -C form carries the same literal, so the tightened prefilter must not drop it
eq "F8 -C form add still parses"       "$(h28 "$(pay "$R28" "${P28}git -C $R28 worktree add wtF8 -b feat/F8 camp")" worktree)" "2"
# status: registered on every prompt of every session — with no board file there is nothing to
# write, so python must never start (the old order parsed the payload first)
RR28="$(CDPATH= cd -- "$R28" && pwd -P)"   # the hook canonicalizes cwd before matching the board
# NOTE: the payload is built in a variable FIRST — an inline JSON literal inside the nested
# quotes of $(h28 "…" status) gets brace-expanded apart on bash 3.2, and $2 stops being "status"
S28J="{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$RR28\",\"message\":\"\"}"
S28F=$(mktemp -u); S28=$(mktemp -u)
eq "F8 status w/o board: no python"    "$(h28 "$S28J" status)" "0"
printf '2026-01-01 00:00:00\tfeat/C\tsurface:1\t%s\tsurface:9\tt\tmain\n' "$RR28" > "$S28F"
: > "$CNT28"; printf '%s' "$S28J" \
  | env HOME="$F8H" PATH="$F8B:$PATH" CC_PY_LOG="$CNT28" CC_TASKS_FILE="$S28F" CC_STATUS_FILE="$S28" \
    bash "$CC/cc-hooks.sh" status >/dev/null 2>&1
eq "F8 status with board: one python"  "$(wc -l < "$CNT28" | tr -d ' ')" "1"
eq "F8 status sidecar still written"   "$(awk -F'\t' -v d="$RR28" '$1==d{print $2}' "$S28")" "working"
rm -rf "$F8H" "$F8B"; rm -f "$S28" "$S28F" "$CNT28"

# ── F9: the header example must show the trailing base, 4 lines above "base is the target" ──
eq "F9 header example names the base"  "$(grep -c 'git worktree add .claude/worktrees/oauth -b feat/oauth feat/camp' "$CC/cc-hooks.sh")" "1"

rm -rf "$R28"


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
# an EXPLICIT base branch beats the caller cwd (4th arg). This is the 2026-08-17 defect: once a
# sibling fast-forwards into the campaign branch the two tips are identical, so a caller standing
# in the sibling records the SIBLING as the merge target and the campaign branch never advances.
git -C "$MR" worktree add -q wtAz -b feat/Az main >/dev/null
"$CC/cc-merge.sh" capture "$MR" feat/Az "$MR/wtA" main
eq "explicit base beats cwd"    "$(git -C "$MR" config branch.feat/Az.ccMergeInto)" "main"
# a base that is not a branch (HEAD, a tag, a sha) is not intent → the cwd stays the fallback
git -C "$MR" worktree add -q wtAw -b feat/Aw main >/dev/null
"$CC/cc-merge.sh" capture "$MR" feat/Aw "$MR/wtA" HEAD
eq "non-branch base → cwd"      "$(git -C "$MR" config branch.feat/Aw.ccMergeInto)" "feat/A"
# and a self-target (caller cwd IS the new branch's own worktree — the shape a mis-resolved
# dispatch leaves) is never recorded: no config beats a config that merges a branch into itself
git -C "$MR" worktree add -q wtAv -b feat/Av main >/dev/null
"$CC/cc-merge.sh" capture "$MR" feat/Av "$MR/wtAv"
eq "self-target not recorded"   "$(git -C "$MR" config branch.feat/Av.ccMergeInto 2>/dev/null)" ""
eq "…so get-parent says trunk"  "$("$CC/cc-merge.sh" get-parent "$MR" feat/Av)" "main"

echo "== 9b. merge target sanity: self-target refused, target chain visible =="
# The other half of the 2026-08-17 defect: a wrong target passed every check and printed "merged:".
# The graph cannot tell a sibling from the campaign branch after a ff (same commit, same
# merge-base), so the gate cannot decide it — but it must SAY where the target itself goes.
MS=$(mktemp -d); ( cd "$MS"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  git branch camp; git worktree add -q wtS1 -b feat/S1 camp >/dev/null
  git -C wtS1 commit -q --allow-empty -m s1
  git worktree add -q wtS2 -b feat/S2 camp >/dev/null
  git -C wtS2 commit -q --allow-empty -m s2 )
"$CC/cc-merge.sh" set-parent "$MS" feat/S1 camp
"$CC/cc-merge.sh" set-parent "$MS" feat/S2 camp
"$CC/cc-merge.sh" done "$MS" feat/S1 true; "$CC/cc-merge.sh" done "$MS" feat/S2 true
# S1 fast-forwards into camp → camp and feat/S1 are now the SAME commit
"$CC/cc-merge.sh" do-merge "$MS" feat/S1 rebase camp >/dev/null 2>&1
eq "ff left camp == feat/S1" "$(git -C "$MS" rev-parse camp)" "$(git -C "$MS" rev-parse feat/S1)"
PFS="$("$CC/cc-merge.sh" preflight "$MS" feat/S2 feat/S1)"; pfs_rc=$?
eq "sibling target still passes checks" "$(echo "$PFS" | grep -c '^check: .* ok')" "5"
eq "…but names where the target goes"   "$(echo "$PFS" | grep -c '^target-parent: camp')" "1"
eq "…and flags it as a sub-task line"   "$(echo "$PFS" | grep -c '^note: feat/S1 is itself a recorded sub-task line')" "1"
eq "sibling preflight rc unchanged"     "$pfs_rc" "0"
# target == child: FAIL in preflight, refused by do-merge (no "skipped: already merged" rc 0)
PFSELF="$("$CC/cc-merge.sh" preflight "$MS" feat/S2 feat/S2)"; eq "self-target preflight rc1" "$?" "1"
eq "self-target check FAILs" "$(echo "$PFSELF" | awk '/^check: target-not-self/{print $3}')" "FAIL"
DMSELF="$("$CC/cc-merge.sh" do-merge "$MS" feat/S2 squash feat/S2 2>&1)"; eq "self-merge rc2" "$?" "2"
eq "self-merge refused loudly" "$(echo "$DMSELF" | grep -c '^refused:')" "1"
eq "self-merge never says merged/skipped" "$(echo "$DMSELF" | grep -cE '^(merged|skipped):')" "0"
# and the trunk target (the normal case) carries no note
PFT="$("$CC/cc-merge.sh" preflight "$MS" feat/S2 camp)"
eq "trunk-ward target has no note" "$(echo "$PFT" | grep -c '^note:')" "0"
eq "trunk-ward target-parent is the trunk" "$(echo "$PFT" | grep -c '^target-parent: main')" "1"
rm -rf "$MS"

echo "== 12. cc-merge trunk =="
eq "trunk is main" "$("$CC/cc-merge.sh" trunk "$MR")" "main"

echo "== 13. gwt-tree nested render =="
GT=$(mktemp -d); ( cd "$GT"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  git worktree add -q wtA -b feat/A >/dev/null; git -C wtA commit -q --allow-empty -m a
  git worktree add -q wtA1 -b feat/A1 feat/A >/dev/null; git -C wtA1 commit -q --allow-empty -m a1 )
"$CC/cc-merge.sh" set-parent "$GT" feat/A main
"$CC/cc-merge.sh" set-parent "$GT" feat/A1 feat/A
"$CC/cc-merge.sh" done "$GT" feat/A1 true
GTOUT="$(cd "$GT" && CC_TASKS_FILE=/dev/null zsh -c "source '$CC/worktree.zsh'; gwt-tree" 2>/dev/null)"
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
echo "== 31. rules docs: one <base> placeholder, direct-parent semantics, archived roadmap =="
# ── rules-docs line (2026-08-21, feat/rules-docs): the dispatch rule names <base> ONCE, defines
# it as the direct parent branch, and keeps the post-mortem in known-issues. These pin that
# wording so the four-placeholder form (<campaign-branch>/<base>/<campaign>…), the "forces an
# explicit base" claim, the no-base README example, or an un-archived roadmap can't quietly come
# back. grep-level on purpose (bash 3.2, no new deps) — same pattern as §11.
R31="$CC/claude-rules.md"
grep -q -- '-b feat/<name> <base>' "$R31" \
  && ok "rules: dispatch form ends in <base>" || no "rules: dispatch form ends in <base>" missing present
eq "rules: no 'forces an explicit base' claim left (C2)" "$(grep -c 'forces an explicit base' "$R31")" 0
eq "rules: <campaign-branch> placeholder gone (C3)" "$(grep -c '<campaign-branch>' "$R31")" 0
eq "rules: <campaign> placeholder gone (C3)" "$(grep -c '<campaign>' "$R31")" 0
grep -q 'direct parent branch' "$R31" \
  && ok "rules: <base> = the direct parent branch (nested dispatch)" \
  || no "rules: <base> = the direct parent branch (nested dispatch)" missing present
grep -q 'defaults to `HEAD`' "$R31" \
  && ok "rules: gwt-claude --base default (HEAD = cwd fallback) stated" \
  || no "rules: gwt-claude --base default (HEAD = cwd fallback) stated" missing present
grep -q 'known-issues' "$R31" \
  && ok "rules: post-mortem is a known-issues pointer, not inline narrative" \
  || no "rules: post-mortem is a known-issues pointer, not inline narrative" missing present
grep -q -- '-b feat/<name> <base>' "$CC/README.md" \
  && ok "README: dispatch example names <base>" || no "README: dispatch example names <base>" missing present
grep -q 'missing `CC_WT_PROMPT`' "$CC/README.md" \
  && ok "README: no-tab row names missing CC_WT_PROMPT" \
  || no "README: no-tab row names missing CC_WT_PROMPT" missing present
grep -q 're-run `install.sh`' "$CC/README.md" \
  && ok "README: rules/hooks runtime migrates only on install.sh re-run" \
  || no "README: rules/hooks runtime migrates only on install.sh re-run" missing present
grep -q '已归档' "$CC/docs/roadmap.md" \
  && ok "roadmap: archived banner, backlog is the live queue" \
  || no "roadmap: archived banner, backlog is the live queue" missing present
grep -q 'audit-0821 campaign 转写' "$CC/docs/known-issues.md" \
  && ok "known-issues: audit-0821 transcription section present" \
  || no "known-issues: audit-0821 transcription section present" missing present
grep -q '锁 10 处副本' "$CC/docs/known-issues.md" \
  && ok "known-issues: mkdir-lock stale-recovery entry (2nd-wave queue)" \
  || no "known-issues: mkdir-lock stale-recovery entry (2nd-wave queue)" missing present
grep -q 'cc-state' "$CC/docs/backlog.md" \
  && ok "backlog: architecture-campaign section transcribed from audit-0821" \
  || no "backlog: architecture-campaign section transcribed from audit-0821" missing present
echo ""
echo "== 26. workspace scope: liveness probed across ALL workspaces, never just the caller's =="
# `cmux list-pane-surfaces` lists ONE workspace — the caller's ($CMUX_WORKSPACE_ID) — and the CLI
# has NO all-workspaces flag (live-probed 2026-08-16: 8 surfaces from the default call, 13 when the
# two workspaces are enumerated one by one). Two places read that partial list as the answer to
# "is this tab still alive?":
#   · _cctabs_prune (opened-tabs.tsv lazy prune) — DESTRUCTIVE: every tab living in another
#     workspace had its owner row deleted, and a tab with no recorded owner is one `close`
#     fail-closes on forever (4 of 10 live rows on the author's machine, 2026-08-16);
#   · the board's live/some_live probe — three working sub-task tabs rendered ?old-session while
#     one of the same rows said working(11m): tab judged dead, agent visibly alive.
# The half that DELETES is the one that needs the invariant, and this section pins it: absence of
# evidence is never evidence of death. One unreachable workspace blocks the WHOLE prune, genuinely
# dead rows included — a stale row is swept by the next complete read, a deleted live row is gone.
WS26=$(mktemp -d); export CC_FAKE_LOG26="$WS26/log"; : > "$CC_FAKE_LOG26"
cat > "$WS26/cmux" <<'CMUX'
#!/usr/bin/env bash
# fake cmux with TWO workspaces. The UNSCOPED list-pane-surfaces call answers with workspace:1
# alone — exactly what the real CLI does with $CMUX_WORKSPACE_ID context. Knobs:
#   CC_FAKE_WSDOWN=<ref>  that workspace is unreachable (rc 1, no output) → a PARTIAL probe
#   CC_FAKE_NOWS=1        this build cannot list workspaces at all → also partial, and MORE so:
#                         nothing tells us how many workspaces were missed
w=""; s=""; prev=""
for a in "$@"; do
  case "$prev" in --workspace) w="$a" ;; --surface) s="$a" ;; esac
  prev="$a"
done
cmd="$1"; shift
case "$cmd" in
  ping) exit 0 ;;
  identify) echo '{ "caller": {} }' ;;
  restore-session) printf 'RESTORE\n' >> "$CC_FAKE_LOG26"; echo "(fake) nothing to restore" ;;
  list-workspaces)
    [ -n "${CC_FAKE_NOWS:-}" ] && exit 0
    printf '* workspace:1  alpha  [selected]\n'
    printf '  workspace:2  beta\n' ;;
  list-pane-surfaces)
    [ -n "$w" ] || w=workspace:1
    [ "$w" = "${CC_FAKE_WSDOWN:-}" ] && { echo "Error: not_found: Workspace not found" >&2; exit 1; }
    case "$w" in
      workspace:1)
        printf '  surface:11\tAAAAAAAA-1111-1111-1111-111111111111\tchild A\n'
        printf '* surface:12\tCCCCCCCC-3333-3333-3333-333333333333\tparent\n' ;;
      workspace:2)
        printf '  surface:21\tBBBBBBBB-2222-2222-2222-222222222222\tchild B (another workspace)\n' ;;
    esac ;;
  new-surface)
    n=$(cat "$CC_FAKE_LOG26.nscnt" 2>/dev/null || echo 900); n=$((n+1)); echo "$n" > "$CC_FAKE_LOG26.nscnt"
    printf 'NEWSURF|surface:%s|%s\n' "$n" "$*" >> "$CC_FAKE_LOG26"
    printf 'OK surface:%s (99999999-9999-9999-9999-%012d) pane:1 (P) workspace:1 (W)\n' "$n" "$n" ;;
  close-surface)
    printf 'CLOSE|%s\n' "$*" >> "$CC_FAKE_LOG26"
    # a uuid resolves inside the WORKSPACE CONTEXT (docs/known-issues.md): the workspace:2 target
    # needs --workspace or cmux answers "Surface not found" and exits 1
    if [ "$s" = "BBBBBBBB-2222-2222-2222-222222222222" ] && [ "$w" != "workspace:2" ]; then
      echo "Error: not_found: Surface not found: $s" >&2; exit 1
    fi ;;
  send)     printf 'SEND|%s\n' "$*" >> "$CC_FAKE_LOG26" ;;
  send-key) printf 'KEY|%s\n'  "$*" >> "$CC_FAKE_LOG26" ;;
esac
exit 0
CMUX
chmod +x "$WS26/cmux"
OP26="$PATH"
UA26="AAAAAAAA-1111-1111-1111-111111111111"   # a tab in workspace:1 — the caller's own workspace
UB26="BBBBBBBB-2222-2222-2222-222222222222"   # a tab in workspace:2 — invisible to the old probe
UP26="CCCCCCCC-3333-3333-3333-333333333333"   # this session (workspace:1), owner of both
UD26="DEADDEAD-0000-0000-0000-000000000000"   # a surface that is really gone: prune fodder
cn26(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
R26="$(cn26 "$(mktemp -d)")"; mkdir -p "$R26/.claude/worktrees/wtA" "$R26/.claude/worktrees/wtB"
WA26="$R26/.claude/worktrees/wtA"; WB26="$R26/.claude/worktrees/wtB"
rows26(){ [ -f "$1" ] || { echo gone; return 0; }; awk 'END{print NR+0}' "$1"; }

# ── the helper itself: the map is a union, and it carries its own completeness ──────────────
# Lifted out of the script and sourced, the way §21 lifts the ledger block and §1 the hook python —
# the invariant has to hold at the helper, not only at the two subcommands that happen to call it.
PR26=$(mktemp -d)
awk '/^_cctabs_file\(\)/{f=1} /^case /{f=0} f' "$CC/cc-dispatch.sh" > "$PR26/ledger.sh"
eq "26 livemap extracted"  "$(grep -c '^_cctabs_livemap()' "$PR26/ledger.sh")" "1"
lm26(){ ( set -u; . "$PR26/ledger.sh"
          PATH="${3:-$WS26:$OP26}" CC_FAKE_WSDOWN="${1:-}" CC_FAKE_NOWS="${2:-}" _cctabs_livemap ) 2>/dev/null; }
eq "26 livemap sees the caller workspace"  "$(lm26 | awk -F'\t' -v u="$UA26" '$2==u{c++} END{print c+0}')" "1"
eq "26 livemap sees the OTHER workspace"   "$(lm26 | awk -F'\t' -v u="$UB26" '$2==u{c++} END{print c+0}')" "1"
eq "26 livemap keeps ref then uuid"        "$(lm26 | awk -F'\t' -v u="$UB26" '$2==u{print $1}')" "surface:21"
eq "26 livemap tags the workspace"         "$(lm26 | awk -F'\t' -v u="$UB26" '$2==u{print $3}')" "workspace:2"
eq "26 complete map carries no sentinel"   "$(lm26 | grep -cx '!partial')" "0"
eq "26 unreachable workspace is flagged"   "$(lm26 workspace:2 | grep -cx '!partial')" "1"
eq "26 flagged map still lists what it saw" "$(lm26 workspace:2 | awk -F'\t' -v u="$UA26" '$2==u{c++} END{print c+0}')" "1"
eq "26 no cmux at all is an empty map"     "$(lm26 "" "" "/usr/bin:/bin" | wc -l | tr -d ' ')" "0"
# NO workspace list at all (older CLI, or the call failed): the unscoped call still resolves what
# it can see, but it is the LEAST complete evidence of the lot — without the list there is no way
# to know how many workspaces went unlooked-at — so it carries the sentinel too. The first cut of
# this line called that case "the pre-fix behaviour, unchanged" and let it prune; that is the very
# shape this section exists to remove, with "old cmux build" swapped in as the trigger.
eq "26 no-list map = caller workspace only" "$(lm26 "" 1 | awk -F'\t' -v u="$UB26" '$2==u{c++} END{print c+0}')" "0"
eq "26 no-list map still resolves what it saw" "$(lm26 "" 1 | awk -F'\t' -v u="$UA26" '$2==u{print $1}')" "surface:11"
eq "26 no workspace list is INCOMPLETE evidence" "$(lm26 "" 1 | grep -cx '!partial')" "1"
# THE invariant: a map carrying the sentinel prunes NOTHING — not even the row that is really dead
prune26(){ ( set -u; . "$PR26/ledger.sh"; CC_TABS_FILE="$1" _cctabs_prune "$2" ) >/dev/null 2>&1; }
L26="$PR26/tabs.tsv"
mkl26(){ printf 'AAAAAAAA-0000-0000-0000-00000000000A\tOWN\t/tmp/a26\t-\tts\n' >  "$L26"
         printf 'DEADDEAD-0000-0000-0000-00000000000D\tOWN\t/tmp/d26\t-\tts\n' >> "$L26"; }
mkl26; prune26 "$L26" "$(printf 'surface:1\tAAAAAAAA-0000-0000-0000-00000000000A\tworkspace:1\n!partial\n')"
eq "26 partial map prunes nothing"    "$(rows26 "$L26")" "2"
# ...and the SAME map without the sentinel still prunes: the guard is the evidence, not the shape
mkl26; prune26 "$L26" "$(printf 'surface:1\tAAAAAAAA-0000-0000-0000-00000000000A\tworkspace:1\n')"
eq "26 complete map still prunes"     "$(rows26 "$L26")" "1"
eq "26 complete map kept the live row" "$(awk -F'\t' 'NR==1{print substr($1,1,8)}' "$L26" 2>/dev/null)" "AAAAAAAA"

# ── consequence one (destructive): the opened-tabs prune ────────────────────────────────────
TB26=$(mktemp -u)
mk26(){ : > "$TB26"
  printf '%s\t%s\t%s\t-\t2026-01-01 00:00:00\n' "$UA26" "$UP26" "$WA26" >> "$TB26"
  printf '%s\t%s\t%s\t-\t2026-01-01 00:00:00\n' "$UB26" "$UP26" "$WB26" >> "$TB26"
  printf '%s\t%s\t%s\t-\t2026-01-01 00:00:00\n' "$UD26" "$UP26" "/tmp/cc-gone-26" >> "$TB26"; }
tabs26(){ ( cd "$R26" && env PATH="$WS26:$OP26" CC_TABS_FILE="$TB26" CC_CALLER_SURFACE_UUID="$UP26" \
    CC_FAKE_WSDOWN="${1:-}" CC_FAKE_NOWS="${2:-}" bash "$CC/cc-dispatch.sh" tabs --all ) 2>&1; }
mk26; TO26="$(tabs26)"
eq "26 tabs: caller-workspace tab alive"  "$(echo "$TO26" | grep -c "$UA26 .*alive")" "1"
eq "26 tabs: OTHER-workspace tab alive"   "$(echo "$TO26" | grep -c "$UB26 .*alive")" "1"
eq "26 cross-workspace row NOT pruned"    "$(grep -c "^$UB26" "$TB26")" "1"
eq "26 genuinely dead row still pruned"   "$(grep -c "^$UD26" "$TB26")" "0"
eq "26 prune kept exactly the live rows"  "$(rows26 "$TB26")" "2"
# one workspace unreachable → nothing is pruned AT ALL, and the miss is reported as dead? not dead
mk26; TO26="$(tabs26 workspace:2)"
eq "26 partial probe prunes no row"       "$(rows26 "$TB26")" "3"
eq "26 partial probe keeps the dead row"  "$(grep -c "^$UD26" "$TB26")" "1"
eq "26 partial probe says so"             "$(echo "$TO26" | grep -c 'liveness partial')" "1"
eq "26 unseen row prints dead?"           "$(echo "$TO26" | grep -c "$UB26 .*dead?")" "1"
eq "26 seen row is still alive"           "$(echo "$TO26" | grep -c "$UA26 .*alive")" "1"
# no workspace list at all → the SAME refusal. This is the case the parent gate sent back: a build
# that cannot enumerate workspaces cannot know whether other workspaces exist, so pruning there is
# the original defect wearing a different trigger. Cost accepted: on such a build the ledger only
# grows, and a stale row is harmless (its uuid resolves to nothing → close says "no live tab", rc 0).
mk26; TO26="$(tabs26 "" 1)"
eq "26 no workspace list prunes NO row"   "$(rows26 "$TB26")" "3"
eq "26 no workspace list keeps the dead row" "$(grep -c "^$UD26" "$TB26")" "1"
eq "26 no workspace list keeps the cross-workspace row" "$(grep -c "^$UB26" "$TB26")" "1"
eq "26 no workspace list says liveness is partial" "$(echo "$TO26" | grep -c 'liveness partial')" "1"
eq "26 no workspace list still resolves its own tab" "$(echo "$TO26" | grep -c "$UA26 .*alive")" "1"

# ── consequence two: the board's TAB column ─────────────────────────────────────────────────
TF26=$(mktemp -u); SF26=$(mktemp -u); : > "$SF26"
bt26(){ : > "$TF26"                       # $1/$2 = the refs recorded for the wtA / wtB rows
  printf '2026-01-01 00:00:01\tfeat/A26\tsurface:%s\t%s\tsurface:9\ttask in the caller workspace\tmain\n' "${1:-11}" "$WA26" >> "$TF26"
  printf '2026-01-01 00:00:02\tfeat/B26\tsurface:%s\t%s\tsurface:9\ttask in ANOTHER workspace\tmain\n'  "${2:-21}" "$WB26" >> "$TF26"; }
brd26(){ ( cd "$R26" && env PATH="${3:-$WS26:$OP26}" CC_TASKS_FILE="$TF26" CC_STATUS_FILE="$SF26" \
    CC_FAKE_WSDOWN="${1:-}" CC_FAKE_NOWS="${2:-}" bash "$CC/cc-board.sh" --all ) 2>/dev/null; }
tabof26(){ echo "$1" | awk -v d="$2" '$5==d{print $1}'; }
bt26; BO26="$(brd26)"
eq "26 board: caller-workspace tab live"  "$(tabof26 "$BO26" "$WA26")" "✔live"
eq "26 board: OTHER-workspace tab live"   "$(tabof26 "$BO26" "$WB26")" "✔live"
# the four TAB values keep their meanings — only the probe's coverage changed:
bt26 11 99; BO26="$(brd26)"
eq "26 board: a truly closed tab is ⌫closed" "$(tabof26 "$BO26" "$WB26")" "⌫closed"
bt26 98 99; BO26="$(brd26)"
eq "26 board: all refs stale is ?old-session" "$(tabof26 "$BO26" "$WA26")" "?old-session"
bt26; BO26="$(brd26 "" "" "/usr/bin:/bin")"
eq "26 board: no cmux is ?"               "$(tabof26 "$BO26" "$WA26")" "?"
# an unreachable workspace is "unknown", never "closed" — same invariant, non-destructive half
bt26; BO26="$(brd26 workspace:2)"
eq "26 board: unreachable workspace is ?" "$(tabof26 "$BO26" "$WB26")" "?"
eq "26 board: seen tab stays live"        "$(tabof26 "$BO26" "$WA26")" "✔live"
eq "26 board: partial probe is announced" "$(echo "$BO26" | grep -c 'liveness partial')" "1"
eq "26 board: no restart claim on partial" "$(echo "$BO26" | grep -c 'probably restarted')" "0"
# no workspace list → the board treats it as partial for the same reason the prune does: a hit is
# still a hit, a miss is only "unknown"
bt26 11 99; BO26="$(brd26 "" 1)"
eq "26 board: no workspace list keeps a hit live" "$(tabof26 "$BO26" "$WA26")" "✔live"
eq "26 board: no workspace list makes a miss ?"   "$(tabof26 "$BO26" "$WB26")" "?"

# ── consequence three: close resolves — and closes — a tab in another workspace ─────────────
TFC26=$(mktemp -u); ST26="$WS26/store.json"; echo '{}' > "$ST26"
printf '2026-01-01 00:00:01\tfeat/A26\tsurface:11\t%s\tsurface:9\ttask A\tmain\tuuid=u1:provider=anthropic:pm=auto:csuuid=%s:suuid=%s\n' "$WA26" "$UP26" "$UA26" >  "$TFC26"
printf '2026-01-01 00:00:02\tfeat/B26\tsurface:21\t%s\tsurface:9\ttask B\tmain\tuuid=u2:provider=anthropic:pm=auto:csuuid=%s:suuid=%s\n' "$WB26" "$UP26" "$UB26" >> "$TFC26"
cl26(){ ( cd "$R26" && env PATH="$WS26:$OP26" CC_TASKS_FILE="$TFC26" CC_TABS_FILE="$TB26" \
    CC_CMUX_SESSIONS="$ST26" CC_CALLER_SURFACE_UUID="$UP26" CLAUDECODE=1 \
    bash "$CC/cc-dispatch.sh" close "$1" ) 2>&1; }
mk26; : > "$CC_FAKE_LOG26"
CO26="$(cl26 "$WB26")"; crc26=$?
eq "26 close resolves the other workspace" "$(echo "$CO26" | grep -c 'resolved : surface:21')" "1"
eq "26 cross-workspace close exit0"        "$crc26" "0"
eq "26 close retried WITH --workspace"     "$(grep -cFx "CLOSE|--surface $UB26 --workspace workspace:2" "$CC_FAKE_LOG26")" "1"
eq "26 close never used a short ref"       "$(grep -c 'CLOSE|--surface surface:' "$CC_FAKE_LOG26")" "0"
# an unreachable workspace keeps the idempotence contract (rc 0, closes nothing) but must not
# claim the tab is gone — "I could not look there" is a different sentence
mk26; : > "$CC_FAKE_LOG26"
CO26="$( cd "$R26" && env PATH="$WS26:$OP26" CC_TASKS_FILE="$TFC26" CC_TABS_FILE="$TB26" \
    CC_CMUX_SESSIONS="$ST26" CC_CALLER_SURFACE_UUID="$UP26" CLAUDECODE=1 CC_FAKE_WSDOWN=workspace:2 \
    bash "$CC/cc-dispatch.sh" close "$WB26" 2>&1 )"; crc26=$?
eq "26 close on a partial probe exit0"     "$crc26" "0"
eq "26 close on a partial probe closes nothing" "$(grep -c 'CLOSE|' "$CC_FAKE_LOG26")" "0"
eq "26 close on a partial probe says why"  "$(echo "$CO26" | grep -c 'unseen by this probe')" "1"
mk26; : > "$CC_FAKE_LOG26"
CO26="$(cl26 "$WA26")"; crc26=$?
eq "26 same-workspace close exit0"         "$crc26" "0"
eq "26 same-workspace close is the bare form" "$(grep -cFx "CLOSE|--surface $UA26" "$CC_FAKE_LOG26")" "1"
eq "26 same-workspace close does not retry"   "$(grep -c 'CLOSE|' "$CC_FAKE_LOG26")" "1"

# ── consequence four: resume must not reopen a tab that is already back elsewhere ───────────
# gwt-resume matched restored tabs against the same caller-workspace-only list, so a tab cmux
# restored into another workspace looked absent and resume opened a DUPLICATE next to it.
python3 - "$UB26" "$WB26" > "$ST26" <<'PY'
import json, sys
surf, cwd = sys.argv[1], sys.argv[2]
json.dump({"sessions": {"55555555-5555-5555-5555-555555555555":
                        {"surfaceId": surf, "cwd": cwd, "updatedAt": 200}}, "version": 3}, sys.stdout)
PY
TFR26=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/B26\tsurface:77\t%s\tsurface:9\ttask B\tmain\tuuid=55555555-5555-5555-5555-555555555555:provider=anthropic:pm=auto\n' "$WB26" > "$TFR26"
HM26="$WS26/home"; mkdir -p "$HM26/.config"; ln -s "$CC" "$HM26/.config/cc-stack"
: > "$CC_FAKE_LOG26"
RO26="$( cd "$R26" && env HOME="$HM26" PATH="$WS26:$OP26" CC_TASKS_FILE="$TFR26" CC_STATUS_FILE="$SF26" \
    CC_TABS_FILE="$TB26" CC_CMUX_SESSIONS="$ST26" CC_RESUME_SETTLE=0 CC_WT_PRETRUST=0 \
    bash "$CC/cc-dispatch.sh" resume --all 2>&1 )"; rrc26=$?
eq "26 resume exit0"                        "$rrc26" "0"
eq "26 resume opens no duplicate tab"       "$(grep -c 'NEWSURF' "$CC_FAKE_LOG26")" "0"
eq "26 resume refreshed the ref to the other workspace" "$(awk -F'\t' -v d="$WB26" '$4==d{print $3}' "$TFR26")" "surface:21"

# insurance for a future regression: a resume that DOES reopen leaves a contentless dedup marker
# in the real TMPDIR (hash-keyed, written by surface) — sweep ours either way
rm -f "${TMPDIR:-/tmp}/cc-cmux-tabs/$(printf '%s' "$WB26" | shasum -a 1 | cut -d' ' -f1)" 2>/dev/null
rm -rf "$WS26" "$R26" "$PR26"; rm -f "$TB26" "$TF26" "$SF26" "$TFC26" "$TFR26"
unset CC_FAKE_LOG26
echo ""
echo "== 12. gwt-adopt (enroll an existing branch into the tree) =="
AR=$(mktemp -d); ( cd "$AR"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  mkdir .claude                        # so _gwt_dir resolves to .claude/worktrees
  git branch feature/orphan-x; git branch feature/orphan-y )
# gwt-adopt opens a cmux WORKSPACE for the adopted worktree (worktree.zsh → cc-dispatch.sh
# workspace). Unshimmed that reached the REAL cmux and leaked one "feature-orphan-y" workspace
# per suite run (five swept by hand 2026-08-16 with `cmux workspace close --workspace <ref>`).
# A no-op cmux on PATH keeps the suite from touching the live UI at all — the rule is that a test
# never opens a surface or workspace it does not also close.
AFK=$(mktemp -d); printf '#!/bin/sh\nexit 0\n' > "$AFK/cmux"; chmod +x "$AFK/cmux"
azsh(){ PATH="$AFK:$PATH" zsh -c "$1"; }
# register-only: sets parent to the trunk, makes NO worktree, appears in the tree
azsh "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-adopt feature/orphan-x --no-worktree" >/dev/null 2>&1
eq "adopt --no-worktree parent=trunk" "$(git -C "$AR" config branch.feature/orphan-x.ccMergeInto)" "main"
eq "adopt --no-worktree makes no wt"  "$(git -C "$AR" worktree list | wc -l | tr -d ' ')" "1"
# F7 (§28): a register-only branch IS in the tree now — gwt-rm without --branch leaves exactly
# this shape, and an invisible unmergeable branch is worse than a config-only row. dirty=clean:
# no worktree means no possible uncommitted changes, and ready tests compare =="clean". gwt-tree RENDERING
# is the wtz line's call; this pins the TSV contract.
eq "no-worktree branch in the tree"   "$("$CC/cc-merge.sh" tree "$AR" | awk -F'\t' '$1=="feature/orphan-x"{print $2}')" "main"
eq "no-worktree branch dirty=clean"   "$("$CC/cc-merge.sh" tree "$AR" | awk -F'\t' '$1=="feature/orphan-x"{print $4}')" "clean"
# full adopt with --into a non-trunk parent: sets parent + creates a sanitized worktree
azsh "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-adopt feature/orphan-y --into feature/orphan-x" >/dev/null 2>&1
eq "adopt --into sets the parent"     "$(git -C "$AR" config branch.feature/orphan-y.ccMergeInto)" "feature/orphan-x"
eq "adopt creates a worktree"         "$(git -C "$AR" worktree list | wc -l | tr -d ' ')" "2"
eq "adopt worktree dir sanitized"     "$([ -d "$AR/.claude/worktrees/feature-orphan-y" ] && echo yes || echo no)" "yes"
# a worktree'd adopt DOES appear in the tree, hung under the given parent
eq "worktreed adopt is in the tree"   "$("$CC/cc-merge.sh" tree "$AR" | awk -F'\t' '$1=="feature/orphan-y"{print $2}')" "feature/orphan-x"
# guards: a missing branch writes no config; the trunk cannot be adopted
azsh "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-adopt no/such" >/dev/null 2>&1
eq "adopt rejects missing branch"     "$(git -C "$AR" config branch.no/such.ccMergeInto 2>/dev/null)" ""
azsh "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-adopt main" >/dev/null 2>&1; arc=$?
eq "adopt rejects the trunk"          "$arc" "1"

# gwt-rm --branch must resolve the REAL branch (any prefix) from the worktree, not assume feat/<name>
( cd "$AR"; git worktree add -q .claude/worktrees/custom-pre -b fix/custom-pre >/dev/null 2>&1 )
CC_TASKS_FILE=/dev/null CC_STATUS_FILE=/dev/null zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-rm custom-pre --branch" >/dev/null 2>&1
eq "gwt-rm removes the worktree"      "$([ -d "$AR/.claude/worktrees/custom-pre" ] && echo no || echo yes)" "yes"
eq "gwt-rm deletes custom-prefix branch" "$(git -C "$AR" show-ref --verify --quiet refs/heads/fix/custom-pre && echo still-there || echo gone)" "gone"
rm -rf "$AR" "$AFK"

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
echo "== 22. install.sh CLI / idempotence / backups + the rules doc's gwt-done form =="
# Audit findings F3 / F11 / F15 (install.sh), F8 (claude-rules.md), F17 (README anchors).
# HARD RULE for this whole section: every install run is HOME-overridden into a scratch dir, so
# the live ~/.zshrc, ~/.claude/settings.json and ~/.claude/CLAUDE.md are never read or written.
I22=$(mktemp -d); I22="$(CDPATH= cd -- "$I22" && pwd -P)"
# F3 needs a hard timeout: the pre-fix arg loop spins forever on a value-less flag (bash `shift 2`
# with $#<2 returns 1 WITHOUT shifting, and the script sets only -u), which would wedge the suite.
tmo(){ local __s="$1"; shift
  if command -v timeout  >/dev/null 2>&1; then timeout  "$__s" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$__s" "$@"; return $?; fi
  "$@" & local __p=$!; ( sleep "$__s"; kill -9 "$__p" 2>/dev/null ) >/dev/null 2>&1 & local __k=$!
  wait "$__p" 2>/dev/null; local __r=$?; kill "$__k" 2>/dev/null; return "$__r"; }
A22="$(tmo 10 env HOME="$I22" bash "$CC/install.sh" --dir 2>&1)"; RA22=$?
eq "F3 --dir without a value exits 2"          "$RA22" "2"
eq "F3 --dir without a value names the flag"   "$(printf '%s' "$A22" | grep -c -- '--dir')" "1"
A22="$(tmo 10 env HOME="$I22" bash "$CC/install.sh" --repo 2>&1)"; RA22=$?
eq "F3 --repo without a value exits 2"         "$RA22" "2"
eq "F3 a value-less flag installs nothing"     "$([ -e "$I22/.zshrc" ] || [ -e "$I22/.claude" ] && echo touched || echo clean)" "clean"
# F11: step 3's idempotence check must judge THIS target's line only. A .zshrc line pointing at
# some OTHER cc-stack copy used to satisfy it (the first grep matched the bare substring
# "cc-stack/worktree.zsh"), so moving the install with `--dir <new place>` left the new location
# never sourced at all — while the README advertises installing anywhere. Both dirs are therefore
# named cc-stack here: that IS the collision.
H22="$I22/home"; mkdir -p "$H22"
env HOME="$H22" bash "$CC/install.sh" --yes --dir "$H22/one/cc-stack" >/dev/null 2>&1
eq "F11 first install sources its own dir"     "$(grep -cF 'one/cc-stack/worktree.zsh' "$H22/.zshrc" 2>/dev/null)" "1"
B22="$(env HOME="$H22" bash "$CC/install.sh" --yes --dir "$H22/two/cc-stack" 2>&1)"
eq "F11 a second dir gets its own source line" "$(grep -cF 'two/cc-stack/worktree.zsh' "$H22/.zshrc" 2>/dev/null)" "1"
eq "F11 the other copy's line is kept"         "$(grep -cF 'one/cc-stack/worktree.zsh' "$H22/.zshrc" 2>/dev/null)" "1"
eq "F11 and it says so instead of silently"    "$(printf '%s' "$B22" | grep -c 'already sources another cc-stack')" "1"
env HOME="$H22" bash "$CC/install.sh" --yes --dir "$H22/two/cc-stack" >/dev/null 2>&1
eq "F11 re-running the same dir adds no dup"   "$(grep -cF 'two/cc-stack/worktree.zsh' "$H22/.zshrc" 2>/dev/null)" "1"
eq "F8 installed CLAUDE.md carries the path"   "$(grep -c '~/.config/cc-stack/gwt-done' "$H22/.claude/CLAUDE.md" 2>/dev/null)" "1"
# F15: bak() used to fire before the three python blocks decided whether anything changes, so every
# re-run of an installer README sells as "idempotent, re-runnable" grew one more generation of
# ~/.zshrc.bak.* / settings.json.bak.* / CLAUDE.md.bak.*.
H15="$I22/home15"; mkdir -p "$H15"
nb(){ ls -1 "$H15"/.zshrc.bak.* "$H15"/.claude/settings.json.bak.* "$H15"/.claude/CLAUDE.md.bak.* 2>/dev/null | wc -l | tr -d ' '; }
env HOME="$H15" bash "$CC/install.sh" --yes --dir "$H15/cc" >/dev/null 2>&1
eq "F15 fresh install backs up nothing"        "$(nb)" "0"
sleep 1                                        # the .bak suffix has 1s resolution
env HOME="$H15" bash "$CC/install.sh" --yes --dir "$H15/cc" >/dev/null 2>&1
eq "F15 no-op re-run backs up nothing"         "$(nb)" "0"
# …but a run that really changes something still backs up first (README: "backs up before changing
# anything") — seed a stale registration so step 4 has to rewrite settings.json
python3 -c 'import json,sys
p=sys.argv[1]+"/.claude/settings.json"
d=json.load(open(p)); d["hooks"]["Stop"]=[{"hooks":[{"type":"command","command":"~/old/cc-notify.sh"}]}]
json.dump(d,open(p,"w"))' "$H15"
sleep 1
env HOME="$H15" bash "$CC/install.sh" --yes --dir "$H15/cc" >/dev/null 2>&1
eq "F15 a real change still backs up first"    "$(ls -1 "$H15"/.claude/settings.json.bak.* 2>/dev/null | wc -l | tr -d ' ')" "1"
eq "F15 the backup holds the PRE state"        "$(grep -c 'cc-notify' "$H15"/.claude/settings.json.bak.* 2>/dev/null)" "1"
eq "F15 the live file was really rewritten"    "$(grep -c 'cc-notify' "$H15/.claude/settings.json")" "0"
sleep 1
env HOME="$H15" bash "$CC/install.sh" --yes --dry-run --dir "$H15/cc" >/dev/null 2>&1
eq "F15 dry-run writes no backup either"       "$(nb)" "1"
# F8: claude-rules.md is the single source of the ~/.claude/CLAUDE.md managed block, and a sub-task
# reads it as often as the working agreement — so it must teach the same deterministic form §19
# guards for cc-dispatch.sh clause 4: a bare gwt-done is a zsh function that does not exist in the
# sub-task's non-interactive bash (incident 2026-08-16).
R22="$(grep -F 'gwt-done' "$CC/claude-rules.md" | grep -F 'Do run' | head -1)"
eq "rules teach the absolute gwt-done path"    "$(printf '%s' "$R22" | grep -c '~/.config/cc-stack/gwt-done')" "1"
eq "rules warn the bare name is zsh-only"      "$(printf '%s' "$R22" | grep -c 'zsh function')" "1"
eq "rules never say to run a bare gwt-done"    "$(grep -c 'run `gwt-done`' "$CC/claude-rules.md")" "0"
# F17: every in-page README anchor must resolve to a real heading (the TOC still pointed at
# "#three-channels" after the section was renamed "Two channels").
BR22="$(python3 - "$CC/README.md" <<'PY'
import re,sys
t=re.sub(r"(?ms)^```.*?^```","",open(sys.argv[1],encoding="utf-8").read())
def slug(h): return "".join(c for c in h.strip().lower() if c.isalnum() or c in " -_").replace(" ","-")
hd=set(slug(m.group(1)) for m in re.finditer(r"(?m)^#+\s+(.*)$",t))
print(" ".join(sorted(set(a for a in re.findall(r"\]\(#([^)]+)\)",t) if a not in hd))))
PY
)"
eq "F17 every README anchor resolves"          "$BR22" ""
rm -rf "$I22"

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
# D2's rows carry a STALE suuid (the surface uuid its tab had before the crash) plus a csuuid and
# a model — the resume round must refresh suuid to the surface it was restored onto and leave the
# rest of the record, including the model-goes-LAST ordering, exactly where it was.
OLDS17="99999999-0000-0000-0000-000000000000"; CSU17R="AAAAAAAA-0000-0000-0000-000000000000"
printf '2026-01-01 00:00:01\tfeat/R2\tsurface:8\t%s\tsurface:1\tD2 older\tmain\tuuid=%s:provider=anthropic:pm=auto:csuuid=%s:suuid=%s:model=m1\n' "$D2" "$SESS2" "$CSU17R" "$OLDS17"  > "$TF17"
printf '2026-01-01 00:00:02\tfeat/R1\tsurface:9\t%s\tsurface:1\tD1 kimi task\tmain\tuuid=%s:provider=kimi:pm=plan:model=glm-4.6\n' "$D1" "$U1" >> "$TF17"
printf '2026-01-01 00:00:03\tfeat/R2\tsurface:9\t%s\tsurface:1\tD2 plain task\tmain\tuuid=%s:provider=anthropic:pm=auto:csuuid=%s:suuid=%s:model=m1\n' "$D2" "$SESS2" "$CSU17R" "$OLDS17" >> "$TF17"
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
# a restored tab is a NEW surface: the recorded suuid must track it, or the close gate would go on
# comparing against a dead uuid (and refuse the parent its own child forever)
eq "suuid refreshed on restore" "$(awk -F'\t' -v d="$D2" '$4==d{print $8}' "$TF17" | sort -u)" \
                                "uuid=$SESS2:provider=anthropic:pm=auto:csuuid=$CSU17R:suuid=$SURF2:model=m1"
eq "stale suuid is gone"        "$(grep -cF "$OLDS17" "$TF17")" "0"
eq "csuuid survived the rewrite" "$(awk -F'\t' -v d="$D2" '$4==d{print ($8 ~ /:csuuid=/)?"y":"n"}' "$TF17" | sort -u)" "y"
eq "model still LAST after rewrite" "$(awk -F'\t' -v d="$D2" '$4==d{print ($8 ~ /:model=m1$/)?"y":"n"}' "$TF17" | sort -u)" "y"
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
# the composed launch-args on the log row; a non-whitelisted model is dropped, never interpolated.
# CC_CALLER_SURFACE_UUID is pinned so the csuuid the dispatcher records (the PARENT surface, see
# section 18) is deterministic instead of whatever cmux surface the suite happens to run in.
TF17D=$(mktemp -u); D0="$(cn17 "$(mktemp -d)")"
CSU17="EEEEEEEE-1111-2222-3333-444444444444"
: > "$CC_FAKE_LOG"
env HOME="$FH17" PATH="$RF:$OP17" CC_TASKS_FILE="$TF17D" CC_SEND_FAILLOG="$RF/fail" \
  CC_SEND_VERIFY_SEC=0.1 CC_LAUNCH_FILE="$RF/launch" CC_WT_PERMISSION_MODE=plan CC_WT_MODEL='glm-4.6[1m]' \
  CC_CALLER_SURFACE_UUID="$CSU17" \
  bash "$CC/cc-dispatch.sh" surface "$D0" "mint test brief" >/dev/null 2>&1
MINT="$(grep -oE -- '--session-id [0-9a-f-]+' "$CC_FAKE_LOG" | head -1 | cut -d' ' -f2)"
eq "surface mints a uuid"    "$(printf '%s' "$MINT" | grep -cE '^[0-9a-f-]{30,}$')" "1"
eq "minted id on launch"     "$(grep -cF -- "ccteam --session-id $MINT --permission-mode plan --model glm-4.6[1m]" "$CC_FAKE_LOG")" "1"
eq "minted id on log row"    "$(awk -F'\t' -v d="$D0" '$4==d{print $8}' "$TF17D")" "uuid=$MINT:provider=anthropic:pm=plan:csuuid=$CSU17:model=glm-4.6[1m]"
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
echo "== 21. dispatch path resolution: target repo root + the opened-tabs prune =="
# F10 — `git rev-parse --git-common-dir` answers with an ABSOLUTE path when the target is a LINKED
# WORKTREE but with the bare RELATIVE `.git` when it is a MAIN CHECKOUT (live-probed 2026-08-16,
# git 2.55.0/darwin). A relative answer resolves against the CALLER's pwd, never against the
# target — so `cd "$(git -C "$d" rev-parse --git-common-dir)/.."` computes the CALLER's repo root
# whenever $d is a main checkout. `cc-dispatch.sh surface <any-dir>` is a public subcommand, so
# that is a cross-repo FILE LEAK: the caller repo's .env / .claude/settings.local.json / shared
# corpus copied into someone else's checkout, and the merge target captured into the caller's repo
# instead of the target's. Production only ever hands `surface` a linked worktree, which is why it
# never fired — these assertions pin the main-checkout case that the public interface allows.
cn21(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
SF21=$(mktemp -d); export CC_FAKE_LOG21="$SF21/log"; export CF_SCREEN21="$SF21/screen"
cat > "$SF21/cmux" <<'CMUX'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  identify) echo '{ "caller": {} }' ;;
  list-pane-surfaces)
    printf '  surface:801\t11111111-AAAA-AAAA-AAAA-111111111111\thelper tab\n'
    printf '* surface:802\t22222222-AAAA-AAAA-AAAA-222222222222\tthis session\n' ;;
  new-surface)
    n=$(cat "$CC_FAKE_LOG21.nscnt" 2>/dev/null || echo 800); n=$((n+1)); echo "$n" > "$CC_FAKE_LOG21.nscnt"
    printf 'NEWSURF|surface:%s|%s\n' "$n" "$*" >> "$CC_FAKE_LOG21"
    printf 'OK surface:%s (77777777-8888-8888-8888-%012d) pane:1 (P) workspace:1 (W)\n' "$n" "$n" ;;
  close-surface) shift; printf 'CLOSE|%s\n' "$*" >> "$CC_FAKE_LOG21" ;;
  send)     shift; printf 'SEND|%s\n'   "$*" >> "$CC_FAKE_LOG21" ;;
  send-key) shift; printf 'KEY|%s\n'    "$*" >> "$CC_FAKE_LOG21" ;;
  notify)   shift; printf 'NOTIFY|%s\n' "$*" >> "$CC_FAKE_LOG21" ;;
  read-screen) cat "$CF_SCREEN21" 2>/dev/null ;;
esac
exit 0
CMUX
chmod +x "$SF21/cmux"
NB21="$(printf '\xc2\xa0')"
{ echo "RDY22"; printf '\xe2\x9d\xaf%s\n' "$NB21"; echo "? for shortcuts"; } > "$CF_SCREEN21"
OP21="$PATH"
# the CALLER: a repo holding exactly the files that must never travel to another repo
CR21="$(cn21 "$(mktemp -d)")"
( cd "$CR21"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git checkout -q -b feat/caller
  printf 'CALLER_SECRET=leaked\n' > .env
  mkdir -p .claude shared21; printf '{"caller":1}\n' > .claude/settings.local.json
  printf 'caller corpus\n' > shared21/corpus.txt )
# the TARGET: an unrelated repo's MAIN CHECKOUT — the shape whose --git-common-dir comes back relative
TR21="$(cn21 "$(mktemp -d)")"
( cd "$TR21"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git checkout -q -b tmain )
FH21=$(mktemp -d); mkdir -p "$FH21/.config"; cp -R "$CC" "$FH21/.config/cc-stack"
TF21=$(mktemp -u); TB21=$(mktemp -u)
srf21(){ # $1 = the directory handed to `surface`, always called FROM INSIDE the caller repo
  ( cd "$CR21" && env HOME="$FH21" PATH="$SF21:$OP21" CC_TASKS_FILE="$TF21" CC_TABS_FILE="$TB21" \
      CC_CALLER_CWD="$CR21" CC_WT_PRETRUST=0 CC_WT_SHARE=shared21 CC_SEND_VERIFY_SEC=0.1 \
      CC_SEND_FAILLOG="$SF21/fail" CC_CALLER_SURFACE_UUID="22222222-AAAA-AAAA-AAAA-222222222222" \
      bash "$CC/cc-dispatch.sh" surface "$1" ) >/dev/null 2>&1
}
srf21 "$TR21"
ex21(){ [ -e "$1" ] && echo leaked || echo clean; }
eq "main checkout: no .env leak"        "$(ex21 "$TR21/.env")" "clean"
eq "main checkout: no settings leak"    "$(ex21 "$TR21/.claude/settings.local.json")" "clean"
eq "main checkout: no corpus leak"      "$(ex21 "$TR21/shared21/corpus.txt")" "clean"
eq "merge target NOT in caller repo"    "$(git -C "$CR21" config --get branch.tmain.ccMergeInto 2>/dev/null)" ""
eq "merge target in the TARGET repo"    "$(git -C "$TR21" config --get branch.tmain.ccMergeInto 2>/dev/null)" "feat/caller"
# control: the production shape (a LINKED worktree of the caller repo) must still get its
# environment — the guard may not cost the case the copy was written for
( cd "$CR21" && git worktree add -q "$CR21/.claude/worktrees/kid21" -b feat/kid21 >/dev/null 2>&1 )
KD21="$(cn21 "$CR21/.claude/worktrees/kid21")"
srf21 "$KD21"
eq "linked worktree still gets .env"    "$(ex21 "$KD21/.env")" "leaked"
eq "linked worktree still gets corpus"  "$(ex21 "$KD21/shared21/corpus.txt")" "leaked"
eq "linked worktree merge target kept"  "$(git -C "$CR21" config --get branch.feat/kid21.ccMergeInto 2>/dev/null)" "feat/caller"

# F10, third site — _cc_repo_of answers the close gate's "is this branch marked ready (gwt-done)"
# question. Same mis-resolution: for a MAIN checkout it used to name the CALLER's repo, so a
# gwt-done recorded in the real repo went unseen and a collectible tab was refused.
MR21="$(cn21 "$(mktemp -d)")"
( cd "$MR21"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git checkout -q -b feat/ready21
  git config branch.feat/ready21.ccDone true )
U21H="11111111-AAAA-AAAA-AAAA-111111111111"   # the helper tab, live in the fake surface map
U21S="22222222-AAAA-AAAA-AAAA-222222222222"   # this session (the tab's opener)
U21O="33333333-AAAA-AAAA-AAAA-333333333333"   # a DIFFERENT dispatching parent: ownership is not the unlock
TF21B=$(mktemp -u); TB21B=$(mktemp -u); ST21="$SF21/store.json"; echo '{}' > "$ST21"
printf '2026-01-01 00:00:01\tfeat/ready21\tsurface:801\t%s\tsurface:9\tready main checkout\tmain\tuuid=u9:provider=anthropic:pm=auto:csuuid=%s:suuid=%s\n' \
  "$MR21" "$U21O" "$U21H" > "$TF21B"
printf '%s\t%s\t%s\t-\t2026-01-01 00:00:00\n' "$U21H" "$U21S" "$MR21" > "$TB21B"
: > "$CC_FAKE_LOG21"
CO21="$( cd "$CR21" && env PATH="$SF21:$OP21" CC_TASKS_FILE="$TF21B" CC_TABS_FILE="$TB21B" \
    CC_CMUX_SESSIONS="$ST21" CC_CALLER_SURFACE_UUID="$U21S" CLAUDECODE=1 \
    bash "$CC/cc-dispatch.sh" close "$MR21" 2>&1 )"; crc21=$?
eq "close reads gwt-done from the TARGET repo" "$(echo "$CO21" | grep -c 'branch feat/ready21 is marked ready')" "1"
eq "ready main-checkout tab closes (rc0)"      "$crc21" "0"
eq "and it closed BY UUID"                     "$(grep -cF "CLOSE|--surface $U21H" "$CC_FAKE_LOG21")" "1"

# F14 — _cctabs_prune used the NR==FNR two-file idiom. With an EMPTY key file that idiom never
# flips (on the first line of the SECOND file NR is still == FNR), so awk eats the whole ledger as
# keys, prints nothing, and the mv + `[ -s ]` below DELETE opened-tabs.tsv — every helper tab's
# recorded owner gone, and `close` fail-closes on all of them afterwards. The same trap is spelled
# out at _ccres_setref, which is exactly why that one reads its keys with getline-in-BEGIN.
# The upstream `[ -n "$_tlm" ] || return 0` keeps the public subcommands off this path today; what
# is pinned here is the INVARIANT (an empty key set prunes NOTHING), by driving the helper itself —
# the ledger block is lifted out of the script and sourced, the way section 1 lifts the hook python.
PR21=$(mktemp -d)
awk '/^_cctabs_file\(\)/{f=1} /^case /{f=0} f' "$CC/cc-dispatch.sh" > "$PR21/ledger.sh"
eq "ledger helpers extracted" "$(grep -c '^_cctabs_prune()' "$PR21/ledger.sh")" "1"
prune21(){ ( set -u; . "$PR21/ledger.sh"; CC_TABS_FILE="$1" _cctabs_prune "$2" ) >/dev/null 2>&1; }
L21="$PR21/tabs.tsv"
mk21(){ printf 'AAAAAAAA-0000-0000-0000-00000000000A\tOWN\t/tmp/a21\t-\tts\n' >  "$L21"
        printf 'BBBBBBBB-0000-0000-0000-00000000000B\tOWN\t/tmp/b21\t-\tts\n' >> "$L21"; }
rows21(){ [ -f "$1" ] || { echo gone; return 0; }; awk 'END{print NR+0}' "$1"; }
# a non-empty map that yields NO usable keys → no evidence → prune nothing, and above all KEEP the file
mk21; prune21 "$L21" "surface:1"
eq "empty key set keeps the ledger" "$(rows21 "$L21")" "2"
# a real map still prunes exactly the rows whose surface is gone
mk21; prune21 "$L21" "$(printf 'surface:1\tAAAAAAAA-0000-0000-0000-00000000000A')"
eq "prune kept the live row"  "$(awk -F'\t' 'NR==1{print substr($1,1,8)}' "$L21" 2>/dev/null)" "AAAAAAAA"
eq "prune dropped the dead row" "$(rows21 "$L21")" "1"
# every row dead → the ledger file itself goes (unchanged behaviour)
mk21; prune21 "$L21" "$(printf 'surface:1\tCCCCCCCC-0000-0000-0000-00000000000C')"
eq "all-dead ledger removed" "$(rows21 "$L21")" "gone"

# surface leaves contentless dedup markers in the real TMPDIR (hash-keyed) — sweep ours
rm -f "${TMPDIR:-/tmp}/cc-cmux-tabs/$(printf '%s' "$TR21" | shasum -a 1 | cut -d' ' -f1)" \
      "${TMPDIR:-/tmp}/cc-cmux-tabs/$(printf '%s' "$KD21" | shasum -a 1 | cut -d' ' -f1)" 2>/dev/null
( cd "$CR21" && git worktree remove --force "$CR21/.claude/worktrees/kid21" >/dev/null 2>&1 )
rm -rf "$SF21" "$FH21" "$CR21" "$TR21" "$MR21" "$PR21"; rm -f "$TF21" "$TB21" "$TF21B" "$TB21B"
unset CC_FAKE_LOG21 CF_SCREEN21

echo ""
echo "== 29. dispatch-fixes (F1-F7 + H2/H3 + gate rounds 2-3) =="
# Contract: every defect gets an assertion that FAILS against the code it fixed — measured:
# 27 red vs the pre-round-1 product; 15 red vs the round-1 state; 13 red vs the round-2 final
# state; 12 red vs the gate-round-2 fixes alone; 5 red vs the round-3 containment criterion;
# 8 red vs the round-4 prelude (superproject-only) = the round-4 fixes: SUBmodule linked-
# worktree regression ×1, out-of-repo-worktree OR semantics ×2, H2 window cap ×3, kept-pf
# board crumb ×2. SUBWT and OUTWT-own are GREEN against pre-round-1 — bec2f41's
# --show-toplevel showed those shapes their own rows, which is exactly the regression round
# 4 closes; the remaining asserts pin guards that were already correct. Harness = §16's fake-cmux knobs (CC_FAKE_ON_SEND swaps the screen right after a send,
# CC_FAKE_FLUSH_AT flips it to CC_FAKE_TUI29 on the Nth Enter — Enter count INCLUDES the raw RDY
# probe's) + §17/§21's HOME-override surface runner (fake HOME holds a COPY of this checkout, so
# $HOME-callchains never touch the live install). The shim skips the ON_SEND swap for the raw
# RDY echo so the swap lands only after the LAUNCH send, which is the incident ordering.
S29=$(mktemp -d); export CC_FAKE_LOG29="$S29/log"; export CC_FAKE_SCREEN29="$S29/screen"
FL29="$S29/fail.log"
cat > "$S29/cmux" <<'CMUX29'
#!/usr/bin/env bash
case "$1" in
  ping) [ -n "${CC_FAKE_PINGDOWN:-}" ] && exit 1; exit 0 ;;
  identify) echo '{ "caller": {} }' ;;
  restore-session) printf 'RESTORE\n' >> "$CC_FAKE_LOG29"; echo "(fake) nothing to restore" ;;
  list-workspaces) : ;;
  list-pane-surfaces) cat "${CC_FAKE_LIVE29:-/dev/null}" 2>/dev/null ;;
  new-surface)
    n=$(cat "$CC_FAKE_LOG29.nscnt" 2>/dev/null || echo 900); n=$((n+1)); echo "$n" > "$CC_FAKE_LOG29.nscnt"
    printf 'NEWSURF|surface:%s|%s\n' "$n" "$*" >> "$CC_FAKE_LOG29"
    printf 'OK surface:%s (77777777-8888-8888-8888-%012d) pane:1 (P) workspace:1 (W)\n' "$n" "$n" ;;
  send)     shift; printf 'SEND|%s\n' "$*" >> "$CC_FAKE_LOG29"
            case "$*" in *"echo RDY"*) ;;    # the raw RDY echo must not trip the ON_SEND swap
              *) [ -n "${CC_FAKE_ON_SEND:-}" ] && cp "$CC_FAKE_ON_SEND" "$CC_FAKE_SCREEN29" 2>/dev/null ;; esac ;;
  send-key) shift; printf 'KEY|%s\n' "$*" >> "$CC_FAKE_LOG29"
            case "$*" in *Enter*)
              [ -n "${CC_FAKE_FLUSH_AT:-}" ] && {
                n=$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG29"); n=${n:-0}
                [ "$n" -ge "$CC_FAKE_FLUSH_AT" ] && cp "$CC_FAKE_TUI29" "$CC_FAKE_SCREEN29" 2>/dev/null; } ;; esac ;;
  notify)   shift; printf 'NOTIFY|%s\n' "$*" >> "$CC_FAKE_LOG29" ;;
  read-screen) cat "$CC_FAKE_SCREEN29" 2>/dev/null ;;
esac
exit 0
CMUX29
chmod +x "$S29/cmux"
OP29="$PATH"; NB29="$(printf '\xc2\xa0')"
# screens: RDY22 present + TUI markers (fast happy path) / RDY only / no RDY & no TUI (both
# probe loops time out — the F3 "sent anyway" world) / a one-line trust dialog (regression) /
# a trust dialog SHAPED like the real BOX — question at the top, 15 lines of body/options/
# footer below it, so the question sits 16 lines up, outside any bottom-15 window / a 20-line
# screen whose TOP carries a VERBATIM quote of the dialog wording above a healthy TUI (gate
# follow-up: the phrase matches but the TUI markers must win the case-arm race), and one with
# brief PROSE about trusting the folder (trust+folder but none of the exact phrases — the
# phrase layer is all that separates it from a real dialog now that the window is gone).
{ echo "RDY22"; printf '\xe2\x9d\xaf%s\n' "$NB29"; echo "? for shortcuts"; } > "$S29/scr-tui"
{ echo "RDY22"; printf '\xe2\x9d\xaf%s\n' "$NB29"; } > "$S29/scr-shell"
{ echo "shell banner"; printf '\xe2\x9d\xaf%s\n' "$NB29"; echo "plain output"; } > "$S29/scr-notui"
printf 'Do you trust the files in this folder?\n' > "$S29/scr-dialog"
{ echo '╭──────────────────────────────────────╮'
  echo '│ Do you trust the files in this folder?'
  echo '│'
  echo '│ /private/tmp/repo29-fixture           │'
  echo '│'
  echo '│ Claude Code may read files in this folder.'
  echo '│ Proceeding gives it access to every file'
  echo '│ below this directory, and portions may be'
  echo '│ sent back to the model provider as part'
  echo '│ of your prompts.'
  echo '│'
  echo '│ Docs: https://claude.com/docs/trust'
  echo '│'
  echo '│ ❯ 1. Yes, proceed'
  echo '│   2. No, exit'
  echo '╰──────────────────────────────────────╯'
  echo 'a trailing line below the box'
  echo 'another trailing line' ; } > "$S29/scr-dialogbox"
{ echo 'Do you trust the files in this directory?'
  echo '/private/tmp/repo29-fixture'
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do echo "drift filler $i"; done; } > "$S29/scr-dialog-drift"
{ echo "RDY22"; printf '\xe2\x9d\xaf brief quote: do you trust the files in this folder (echoed transcript)\n'
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do echo "transcript filler $i"; done
  printf '\xe2\x9d\xaf%s\n' "$NB29"; echo "? for shortcuts"; } > "$S29/scr-echo-trust"
{ echo "RDY22"; printf '\xe2\x9d\xaf brief quote: if you trust that folder of files, answer yes (echoed transcript)\n'
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do echo "transcript filler $i"; done
  printf '\xe2\x9d\xaf%s\n' "$NB29"; echo "? for shortcuts"; } > "$S29/scr-prose-trust"
# fixture repo: three REGISTERED worktrees in the canonical .claude/worktrees/ layout (the
# PARENT batch map only ever feeds rows in that layout — §2c's wtW-style rows take the per-row
# path and can never see the map), plus a foreign-repo row for the filter guard.
cn29(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
REPO29=$(mktemp -d); ( cd "$REPO29"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  git worktree add -q ".claude/worktrees/wta" -b feat/wta >/dev/null 2>&1
  git worktree add -q ".claude/worktrees/wtb" -b feat/wtb >/dev/null 2>&1
  git worktree add -q ".claude/worktrees/wtp" -b feat/v1.2 >/dev/null 2>&1 )
WTA="$(cn29 "$REPO29/.claude/worktrees/wta")"; WTB="$(cn29 "$REPO29/.claude/worktrees/wtb")"; WTP="$(cn29 "$REPO29/.claude/worktrees/wtp")"
OTH29="$(cn29 "$(mktemp -d)")"
svT="${CC_TASKS_FILE:-}"; svS="${CC_STATUS_FILE:-}"; svA="${CC_ARCHIVE_FILE:-}"
TF29B=$(mktemp -u); SF29B=$(mktemp -u); AF29B=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/wtb\tsurface:41\t%s\tsurface:1\ttask sibling b\tmain\n' "$WTB"  > "$TF29B"
printf '2026-01-01 00:00:02\tfeat/v1.2\tsurface:42\t%s\tsurface:1\ttask parent-map\tfeat/STALE7\n' "$WTP" >> "$TF29B"
printf '2026-01-01 00:00:03\tfeat/foreign29\tsurface:43\t%s\tsurface:1\ttask foreign29\tmain\n' "$OTH29" >> "$TF29B"
git -C "$REPO29" config branch.feat/v1.2.ccMergeInto feat/camp-29
export CC_TASKS_FILE="$TF29B" CC_STATUS_FILE="$SF29B" CC_ARCHIVE_FILE="$AF29B"

# ── F1a: the board's repo filter, run from a LINKED WORKTREE, must resolve the MAIN repo root
# (pre-fix: `git rev-parse --show-toplevel` answered the worktree itself → only its own row)
BO29="$( ( cd "$WTA" && bash "$CC/cc-board.sh" ) 2>/dev/null )"
eq "F1 board: sibling row visible from a linked worktree" "$(echo "$BO29" | grep -c 'task sibling b')" "1"
eq "F1 board: own-repo rows all present"                 "$(echo "$BO29" | grep -c 'task parent-map')" "1"
eq "F1 board: foreign repo row still filtered"           "$(echo "$BO29" | grep -c 'task foreign29')" "0"

# ── PARENT batch map (parent-session finding 2026-08-21): git NORMALIZES the name part of a
# config key to lowercase in --get-regexp output (branch.feat/x.ccMergeInto prints as
# …ccmergeinto), so the CamelCase suffix strip never matched and the map has been dead since
# F13 — the PARENT column silently ran on the TSV 7th-field fallback. Red pre-fix by making the
# config value and the TSV field deliberately DIFFERENT (§2c-style fixtures agree, which is
# exactly why this never failed).
eq "PARENT map: git-config target beats TSV 7th field" "$(echo "$BO29" | awk -v d="$WTP" '$5==d{print $3}')" "feat/camp-29"
eq "PARENT map: strip survives dots in branch names"   "$(echo "$BO29" | awk -v d="$WTP" '$5==d{print $3}' | grep -c 'ccmergeinto')" "0"

# ── H2: consecutive identical failure crumbs fold to ONE line +(×N) (16-in-a-row on 2026-08-21).
# Round 2: the fold needs a WIDE window — tail-8-then-fold capped a 16-run at (×8) and kept
# burying the older distinct crumb the fold existed to surface. Round 4: tail -60 was the
# same trap one size up — a 61-run capped at (×60) and buried the distinct crumb AGAIN — so
# the fold now sees the WHOLE time-filtered stream; only the display tail narrows. 1+61.
LOGB29=$(mktemp -u); ts29="$(date '+%F %T')"
printf '[%s] surface:2 — an older distinct crumb, drowned pre-fix\n' "$ts29" > "$LOGB29"
for i in $(seq 61); do printf '[%s] surface:1 — cc-send parked after send: sixty-one in a row\n' "$ts29" >> "$LOGB29"; done
BO29F="$( ( cd "$WTA" && CC_SEND_FAILLOG="$LOGB29" bash "$CC/cc-board.sh" ) 2>/dev/null )"
eq "H2: a 61-run folds to one (×61), not (×60)" "$(echo "$BO29F" | grep -cF '(×61)')" "1"
eq "H2: never prints the window-capped count"  "$(echo "$BO29F" | grep -cF '(×60)')"  "0"
eq "H2: the older distinct crumb surfaces too" "$(echo "$BO29F" | grep -c 'an older distinct crumb')" "1"
rm -f "$LOGB29"

# ── F1b: `resume` run from a linked worktree must list SIBLING rows of the same repo
TF29R=$(mktemp -u); echo '{}' > "$S29/store29.json"
printf '2026-01-01 00:00:01\tfeat/rsm-sib\tsurface:51\t%s\tsurface:1\tresume sibling row\tmain\tuuid=66666666-6666-6666-6666-666666666666:provider=anthropic:pm=auto\n' "$WTB" > "$TF29R"
OUT29R="$( cd "$WTA" && echo n | env HOME="$HOME" PATH="$S29:$OP29" CC_TASKS_FILE="$TF29R" \
  CC_STATUS_FILE="$SF29B" CC_CMUX_SESSIONS="$S29/store29.json" CC_RESUME_SETTLE=0 \
  CC_SEND_VERIFY_SEC=0.1 CC_SEND_FAILLOG="$FL29" bash "$CC/cc-dispatch.sh" resume 2>&1 )"
eq "F1 resume: sibling branch listed from a linked worktree" "$(printf '%s' "$OUT29R" | grep -c 'feat/rsm-sib')" "1"

# ── SUB (gate round 3): inside a SUBMODULE, --git-common-dir answers <super>/.git/modules/<name>
# and its parent contains neither the submodule nor its rows — the gitroot discipline alone
# filtered EVERYTHING ("no records", board and resume alike). The guard falls back to
# --show-toplevel (the submodule root) and the rows show again. Round 4 widened the criterion
# to an OR: superproject non-empty (this fixture) OR the computed root not containing the
# target (the SUBWT fixture below). The two shapes after this block pin what must NOT drift:
# --separate-git-dir keeps the plain common-dir resolution (bec2f41-identical), and the
# out-of-repo worktree takes the containment fallback (bec2f41-board-identical — see the
# comment at its own assert).
SUP29=$(mktemp -d); ( cd "$SUP29" && git init -q && git config user.email t@t && git config user.name t
  git -c protocol.file.allow=always submodule add -q "$REPO29" sub >/dev/null 2>&1
  git commit -qm super ) >/dev/null 2>&1 || true
SUB29="$(cn29 "$SUP29/sub")"                       # the submodule CHECKOUT (worktrees don't survive a clone)
TF29SUB=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/wtb\tsurface:41\t%s\tsurface:1\tsub sibling row\tmain\n' "$SUB29" > "$TF29SUB"
BO29S="$( ( cd "$SUB29" && CC_TASKS_FILE="$TF29SUB" CC_STATUS_FILE="$SF29B" bash "$CC/cc-board.sh" ) 2>/dev/null )"
eq "SUB: board inside a submodule still shows rows" "$(echo "$BO29S" | grep -c 'sub sibling row')" "1"
OUT29S="$( cd "$SUB29" && echo n | env HOME="$HOME" PATH="$S29:$OP29" CC_TASKS_FILE="$TF29SUB" \
  CC_STATUS_FILE="$SF29B" CC_CMUX_SESSIONS="$S29/store29.json" CC_RESUME_SETTLE=0 \
  CC_SEND_VERIFY_SEC=0.1 CC_SEND_FAILLOG="$FL29" bash "$CC/cc-dispatch.sh" resume 2>&1 )"
eq "SUB: resume inside a submodule still lists siblings" "$(printf '%s' "$OUT29S" | grep -c 'feat/wtb')" "1"
# ── SUBWT (gate round 4 — the regression the OR criterion exists for): from a submodule's
# LINKED worktree (/super/sub/.claude/worktrees/x) the superproject check comes back EMPTY,
# yet the common dir still resolves into <super>/.git/modules — the pure-superproject guard
# never fired, the root WAS .git/modules, and both board and resume lost every row ("no
# records" / "no resumable board rows"). bec2f41's --show-toplevel showed this shape its own
# row. The containment half of the OR catches it: root doesn't contain the worktree →
# --show-toplevel (the worktree itself) → its own row shows again.
git -C "$SUB29" worktree add -q ".claude/worktrees/swtx" -b feat/swtx >/dev/null 2>&1 || true
WTX29="$(cn29 "$SUB29/.claude/worktrees/swtx")"
TF29X=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/swtx\tsurface:46\t%s\tsurface:1\tsubwt own row\tmain\n' "$WTX29" > "$TF29X"
BO29X="$( ( cd "$WTX29" && CC_TASKS_FILE="$TF29X" CC_STATUS_FILE="$SF29B" bash "$CC/cc-board.sh" ) 2>/dev/null )"
eq "SUBWT: a submodule's linked worktree still shows its own row" "$(echo "$BO29X" | grep -c 'subwt own row')" "1"
rm -rf "$SUP29"; rm -f "$TF29SUB" "$TF29X"
# --separate-git-dir (gate placement: worktree and gitdir SHARE a parent — the six-shape
# probe's layout): the common dir is <parent>/sepgit, so the computed root is the shared
# parent, which CONTAINS the worktree → neither guard criterion fires and the plain
# common-dir resolution stands (bec2f41-identical). Two rows pin both properties: the
# checkout's OWN row (this going red means the git dance above failed — round 4 replaced a
# vacuous assert here: every setup step has `|| true`, so a broken fixture left an empty dir
# field, the board dropped the row, and grep 0 read as "no fallback" green), and a SIBLING
# row under the shared parent, which a --show-toplevel fallback (the worktree itself) hides.
SEP29B=$(mktemp -d); mkdir -p "$SEP29B/sepwt" "$SEP29B/sib"   # cn29 cd's in — dirs must exist FIRST
( cd "$SEP29B/sepwt" && git init -q --separate-git-dir="$SEP29B/sepgit" . && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m i && git branch -M main ) >/dev/null 2>&1 || true
WTSEP="$(cn29 "$SEP29B/sepwt")"; SIBSEP="$(cn29 "$SEP29B/sib")"
TF29SEP=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/sepwt\tsurface:44\t%s\tsurface:1\tsep own row\tmain\n' "$WTSEP"  > "$TF29SEP"
printf '2026-01-01 00:00:02\tfeat/sepsib\tsurface:45\t%s\tsurface:1\tsep sibling row\tmain\n' "$SIBSEP" >> "$TF29SEP"
BO29SEP="$( ( cd "$WTSEP" && CC_TASKS_FILE="$TF29SEP" CC_STATUS_FILE="$SF29B" bash "$CC/cc-board.sh" ) 2>/dev/null )"
eq "SEP: own row visible from the separate-git-dir checkout (fixture proof)" "$(echo "$BO29SEP" | grep -c 'sep own row')" "1"
eq "SEP: --separate-git-dir does NOT fall back (sibling under the shared parent shows)" "$(echo "$BO29SEP" | grep -c 'sep sibling row')" "1"
rm -rf "$SEP29B"; rm -f "$TF29SEP"
# out-of-repo worktree: git worktree add <anywhere> (the hook dispatch path allows it). Under
# the round-4 OR criterion this shape CHANGES resolution by design: the computed root (the
# MAIN repo) does not CONTAIN the worktree, the containment half fires, and the root falls
# back to --show-toplevel = the worktree itself (bec2f41-board-identical: its own row shows,
# the main repo's sibling rows do not). Superproject stays empty here, so this is purely the
# containment criterion's call — pinned so the trade doesn't drift silently.
OWTB29=$(mktemp -d); OUTWT29="$(cn29 "$OWTB29")/outwt"
git -C "$REPO29" worktree add -q "$OUTWT29" -b feat/outwt >/dev/null 2>&1 || true
TF29O=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/outwt\tsurface:47\t%s\tsurface:1\toutwt own row\tmain\n' "$OUTWT29" > "$TF29O"
cat "$TF29B" >> "$TF29O"
BO29O="$( ( cd "$OUTWT29" && CC_TASKS_FILE="$TF29O" CC_STATUS_FILE="$SF29B" bash "$CC/cc-board.sh" ) 2>/dev/null )"
eq "OUTWT: own row visible from the out-of-repo worktree"        "$(echo "$BO29O" | grep -c 'outwt own row')"   "1"
eq "OUTWT: main-repo sibling rows hidden (containment fallback)" "$(echo "$BO29O" | grep -c 'task sibling b')" "0"
git -C "$REPO29" worktree remove --force "$OUTWT29" >/dev/null 2>&1; rm -rf "$OWTB29"; rm -f "$TF29O"

# ── F7: a row with an EMPTY surface field must not collapse (TAB is IFS whitespace: fields
# shift left, largs land in task, and the recorded uuid is lost → bogus "no recorded session").
# US (0x1f) is not IFS whitespace, so empty fields survive the awk→read handoff.
TF297=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/f7-empty-surf\t\t%s\tsurface:1\tf7 task text\tmain\tuuid=77777777-7777-7777-7777-777777777777:provider=anthropic:pm=auto\n' "$WTB" > "$TF297"
OUT297="$( cd "$WTA" && echo n | env HOME="$HOME" PATH="$S29:$OP29" CC_TASKS_FILE="$TF297" \
  CC_STATUS_FILE="$SF29B" CC_CMUX_SESSIONS="$S29/store29.json" CC_RESUME_SETTLE=0 \
  CC_SEND_VERIFY_SEC=0.1 CC_SEND_FAILLOG="$FL29" bash "$CC/cc-dispatch.sh" resume 2>&1 )"
eq "F7: empty surface field keeps the uuid → --resume replay" "$(printf '%s' "$OUT297" | grep -c -- '--resume 77777777-7777-7777-7777-777777777777')" "1"
eq "F7: not misread as a pre-recording idle row"              "$(printf '%s' "$OUT297" | grep -c 'no recorded session')" "0"
rm -f "$TF29R" "$TF297"

# ── F2: the parked-after-send breadcrumb must carry the MATCHED LINE (truncated 120, TAB/NL
# stripped) — 16 identical alarms in 6 days were undiagnosable without it
: > "$CC_FAKE_LOG29"; : > "$FL29"; cp "$S29/scr-tui" "$CC_FAKE_SCREEN29"
M200="$(printf 'M%.0s' $(seq 1 200))"
printf '\xe2\x9d\xaf%s%s\n' "$NB29" "$M200" > "$S29/scr-parked200"
CC_FAKE_ON_SEND="$S29/scr-parked200" CC_SEND_FAILLOG="$FL29" CC_SEND_VERIFY_SEC=0.1 \
  PATH="$S29:$OP29" bash "$CC/cc-dispatch.sh" send surface:1 "f2 msg" >/dev/null 2>&1; rcs=$?
eq "F2: parked alarm still fails loudly (rc1)"  "$rcs" "1"
C29="$(grep 'parked after send' "$FL29" 2>/dev/null)"
eq "F2: crumb carries the matched line"         "$(printf '%s' "$C29" | grep -c 'matched line: "MMMM')" "1"
eq "F2: matched line truncated at 120 chars"    "$(printf '%s' "$C29" | grep -oE 'M+' | awk '{print length($0)}' | sort -rn | head -1)" "120"

# ── H3: CC_SEND_NOVERIFY=1 skips the post-send verify for callers that knowingly target a
# SHELL — a ❯-prompt shell echoes the typed launch command, the scan reads the echo as a busy
# composer, and verify false-alarms + Enter-retries a tab with no composer (2026-08-21 live hit)
printf '\xe2\x9d\xaf ccteam --permission-mode auto\n' > "$S29/scr-launch-echo"
: > "$CC_FAKE_LOG29"; : > "$FL29"; cp "$S29/scr-tui" "$CC_FAKE_SCREEN29"
CC_SEND_NOVERIFY=1 CC_FAKE_ON_SEND="$S29/scr-launch-echo" CC_SEND_FAILLOG="$FL29" CC_SEND_VERIFY_SEC=0.1 \
  PATH="$S29:$OP29" bash "$CC/cc-dispatch.sh" send surface:1 "launch line" >/dev/null 2>&1; rcs=$?
eq "H3: NOVERIFY skips the shell-echo false alarm (rc0)" "$rcs" "0"
eq "H3: NOVERIFY one Enter, no retry"                    "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG29")" "1"
eq "H3: NOVERIFY no crumb"                               "$([ -s "$FL29" ] && echo yes || echo no)" "no"
: > "$CC_FAKE_LOG29"; : > "$FL29"; cp "$S29/scr-tui" "$CC_FAKE_SCREEN29"
CC_FAKE_ON_SEND="$S29/scr-launch-echo" CC_SEND_FAILLOG="$FL29" CC_SEND_VERIFY_SEC=0.1 \
  PATH="$S29:$OP29" bash "$CC/cc-dispatch.sh" send surface:1 "launch line" >/dev/null 2>&1; rcs=$?
eq "H3: without the opt-in the same echo alarms (the bug)" "$rcs" "1"
eq "H3: without the opt-in the crumb fires"                "$(grep -c 'parked after send' "$FL29")" "1"
eq "H3: all three launch sends opt out (source pin)"       "$(grep -c 'CC_SEND_QUIET=1 CC_SEND_NOVERIFY=1' "$CC/cc-dispatch.sh")" "3"

# ── surface runner: fake HOME (copy of THIS checkout), scratch ledgers, pinned ids, pre-trust
# off, no shared corpus. mk29 sweeps the 120s dedup marker first — two runs on the same dir
# within 120s would otherwise silently skip the second.
FH29=$(mktemp -d); mkdir -p "$FH29/.config"; cp -R "$CC" "$FH29/.config/cc-stack"
TSKV29=$(mktemp -u); TB29=$(mktemp -u); LF29=$(mktemp -u)
mk29(){ : > "$CC_FAKE_LOG29"; rm -f "$CC_FAKE_LOG29.nscnt"; cp "$1" "$CC_FAKE_SCREEN29"
        unset CC_FAKE_ON_SEND CC_FAKE_TUI29 CC_FAKE_FLUSH_AT CC_FAKE_PINGDOWN CC_LAUNCH_FILE
        rm -f "$S29/cc-cmux-tabs/$(printf '%s' "$2" | shasum -a 1 | cut -d' ' -f1)" 2>/dev/null; }
srf29(){ # $1 dir, $2 prompt (screens are set by mk29); extra knobs come from the environment
  ( cd "$REPO29" && env HOME="$FH29" PATH="$S29:$OP29" TMPDIR="$S29" CC_TASKS_FILE="$TSKV29" CC_TABS_FILE="$TB29" \
      CC_CALLER_CWD="$REPO29" CC_WT_PRETRUST=0 CC_WT_SHARE="" CC_SEND_VERIFY_SEC=0.1 \
      CC_SEND_FAILLOG="$LF29" CC_CALLER_SURFACE_UUID="22222222-AAAA-AAAA-AAAA-222222222222" \
      CC_WT_SESSION_ID="55555555-5555-5555-5555-555555555555" CC_RESUME_SETTLE=0 \
      bash "$CC/cc-dispatch.sh" surface "$1" "$2" ) >/dev/null 2>&1; }
# TMPDIR=$S29: dispatches write their pf temp files and cc-cmux-tabs dedup markers into the
# section-private dir — the shared /tmp is subject to outside traffic (a concurrent sweep of
# cc-wt-prompt litter flipped the F3 counts run-to-run), and every reader below matches.
pf29(){ grep -l 'PROMPT29' "$S29"/cc-wt-prompt.* 2>/dev/null | wc -l | tr -d ' '; }
# pfsweep29: `rm -f "$(grep -l …)"` is broken with >1 match — the multi-line output forms ONE
# bogus filename and nothing gets deleted — and the unquoted `for _pf in $(grep -l …)` form is
# just the same bug one layer out (word-split on IFS: a TMPDIR containing a space means not a
# single file is removed). read -r line-by-line is the only form that holds for both.
pfsweep29(){ grep -l 'PROMPT29' "$S29"/cc-wt-prompt.* 2>/dev/null | while IFS= read -r _pf; do rm -f "$_pf"; done; }

# ── F4: provider validation unified with _ccres_parse's charset whitelist — the value is
# interpolated into a typed terminal command, so `;` must fall back to ccteam, never `cld kim;i`
printf 'kim;i' > "$S29/prov-bad"; printf 'a/b' > "$S29/prov-slash"; printf 'kimi' > "$S29/prov-ok"
mk29 "$S29/scr-tui" "$WTA"; CC_LAUNCH_FILE="$S29/prov-bad" srf29 "$WTA" "PROMPT29 f4 bad" "$S29/scr-tui"
eq "F4: ';'-provider falls back to ccteam"      "$(grep -c 'SEND|.*ccteam --session-id' "$CC_FAKE_LOG29")" "1"
eq "F4: ';'-provider never typed into the tab"  "$(grep -c 'cld kim;i' "$CC_FAKE_LOG29")" "0"
mk29 "$S29/scr-tui" "$WTA"; CC_LAUNCH_FILE="$S29/prov-slash" srf29 "$WTA" "PROMPT29 f4 slash" "$S29/scr-tui"
eq "F4: path-ish provider still blocked"        "$(grep -c 'cld a/b' "$CC_FAKE_LOG29")" "0"
mk29 "$S29/scr-tui" "$WTA"; CC_LAUNCH_FILE="$S29/prov-ok" srf29 "$WTA" "PROMPT29 f4 ok" "$S29/scr-tui"
eq "F4: a clean custom provider still routes cld" "$(grep -c 'SEND|.*cld kimi --session-id' "$CC_FAKE_LOG29")" "1"
# round 2: a LEADING DOT passes the charset but resume's _ccres_parse drops it (.kimi records
# as `cld .kimi`, replays as ccteam) — the launch whitelist must reject it too, or the
# recorded args can never be replayed as launched.
printf '.kimi' > "$S29/prov-dot"
mk29 "$S29/scr-tui" "$WTA"; CC_LAUNCH_FILE="$S29/prov-dot" srf29 "$WTA" "PROMPT29 f4 dot" "$S29/scr-tui"
eq "F4: leading-dot provider falls back to ccteam"    "$(grep -c 'SEND|.*ccteam --session-id' "$CC_FAKE_LOG29")" "1"
eq "F4: never records 'cld .kimi' (resume drops it)"  "$(grep -c 'cld \.kimi' "$CC_FAKE_LOG29")" "0"

# ── F5: the trust scrape matches the REAL dialog phrases over the WHOLE 30-line capture — the
# three exact wordings PLUS the *"do you trust"* catch-all (gate round 3: wording drift like
# "…this directory?" must not silently defeat pre-auth again) —
# (round 2 removed the bottom-15 window: the real dialog is a BOX whose question sits ~15-17
# lines up and fell outside it — pre-auth missed → 24 idle spins → tab stuck on the dialog).
# Two negatives, one per safety layer: (a) a VERBATIM quote of the dialog in the transcript
# ABOVE a healthy TUI — the phrase matches, so only the case-arm ORDER protects (gate
# follow-up: trust-first fired up to 24 stray Enters into the live session); (b) PROSE that
# says trust+folder but none of the exact phrases — the phrase layer. Enter count must stay
# at RDY+launch for both.
mk29 "$S29/scr-echo-trust" "$WTA"; srf29 "$WTA" "PROMPT29 f5neg" "$S29/scr-echo-trust"
eq "F5: verbatim quote above a live TUI never answers Enter" "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG29")" "2"
mk29 "$S29/scr-prose-trust" "$WTA"; srf29 "$WTA" "PROMPT29 f5negp" "$S29/scr-prose-trust"
eq "F5: prose about trust never answers Enter" "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG29")" "2"
# a REAL dialog IS answered: ON_SEND swaps to the dialog after the launch send, FLUSH_AT=3
# flips to the TUI on the dialog's Enter (RDY=1, launch=2, dialog=3). Two shapes: the one-line
# fixture (regression) and the BOX (question 16 lines up — red against the round-1 tail-15 code).
mk29 "$S29/scr-tui" "$WTA"
CC_FAKE_ON_SEND="$S29/scr-dialog" CC_FAKE_TUI29="$S29/scr-tui" CC_FAKE_FLUSH_AT=3 srf29 "$WTA" "PROMPT29 f5pos" "$S29/scr-tui"
eq "F5: a one-line dialog is answered (regression)" "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG29")" "3"
mk29 "$S29/scr-tui" "$WTA"
CC_FAKE_ON_SEND="$S29/scr-dialogbox" CC_FAKE_TUI29="$S29/scr-tui" CC_FAKE_FLUSH_AT=3 srf29 "$WTA" "PROMPT29 f5posbox" "$S29/scr-tui"
eq "F5: full dialog BOX (question 16 lines up) is answered" "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG29")" "3"
mk29 "$S29/scr-tui" "$WTA"
CC_FAKE_ON_SEND="$S29/scr-dialog-drift" CC_FAKE_TUI29="$S29/scr-tui" CC_FAKE_FLUSH_AT=3 srf29 "$WTA" "PROMPT29 f5drift" "$S29/scr-tui"
eq "F5: DRIFTED wording (still 'do you trust') is answered" "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG29")" "3"

# ── F3: the prompt temp file is deleted ONLY once the TUI was actually seen. TUI up → gone;
# neither probe ever confirming (RDY timed out, no TUI markers) → the file SURVIVES so the
# already-sent `$(cat pf)` cannot read empty (pre-fix: deleted unconditionally → red below).
# Sweep first: an unconfirmed-TUI dispatch KEEPS its pf (e.g. the F5 box miss vs the round-1
# code) — without the sweep that leftover inflates F3's counts and masks what F3 itself does.
pfsweep29
mk29 "$S29/scr-tui" "$WTA"; srf29 "$WTA" "PROMPT29 f3b tui" "$S29/scr-tui"
eq "F3: TUI up → prompt file deleted"   "$(pf29)" "0"
mk29 "$S29/scr-notui" "$WTA"; srf29 "$WTA" "PROMPT29 f3a notui" "$S29/scr-notui"
eq "F3: TUI never seen → prompt file survives" "$(pf29)" "1"
eq "F3: kept-pf warning reaches the board log (round 4)" "$(grep -c 'prompt kept in' "$LF29")" "1"
eq "F3: kept-pf warning names the file (source pin, stderr + crumb)" "$(grep -cF 'prompt kept in $pf' "$CC/cc-dispatch.sh")" "2"
# gate round 3 (pf sweep): a leftover older than ~a day is removed on the NEXT dispatch — the
# common cause is a slow-painting TUI (the shell evals $(cat pf) ~6s before the probe gives
# up), and each leftover is a world-readable copy of the full brief.
STALE29="$S29/cc-wt-prompt.STALE.txt"; printf 'an old brief body
' > "$STALE29"; touch -t 202001010000 "$STALE29"
mk29 "$S29/scr-tui" "$WTA"; srf29 "$WTA" "PROMPT29 f3s" "$S29/scr-tui"
eq "F3: stale pf (>1d) swept on next dispatch" "$([ -e "$STALE29" ] && echo kept || echo swept)" "swept"
pfsweep29

# ── F6: cmux PRESENT but unreachable fails the dispatch (rc1, same as new-surface failure —
# wt-claude exec's in, so this rc IS gwt-claude's rc). No cmux BINARY stays the exit-0
# remote-SSH no-op (source pin — rc equality with new-surface is the fix, not the no-op).
mk29 "$S29/scr-tui" "$WTA"; CC_FAKE_PINGDOWN=1 srf29 "$WTA" "PROMPT29 f6" "$S29/scr-tui"; rcs=$?
eq "F6: cmux unreachable fails the dispatch (rc1)" "$rcs" "1"
eq "F6: no tab opened on unreachable cmux"          "$(grep -c 'NEWSURF' "$CC_FAKE_LOG29")" "0"
eq "F6: breadcrumb honors CC_SEND_FAILLOG (unified)" "$(grep -c 'cmux ping unreachable' "$LF29" 2>/dev/null)" "1"
eq "F6: no-cmux-binary no-op still pinned (source)" "$(grep -c '^command -v cmux >/dev/null 2>&1 || exit 0$' "$CC/cc-dispatch.sh")" "1"

# ── working agreement clause (6): sub-task edits stay inside their own worktree
grep -q '(6) Keep every edit inside THIS worktree' "$CC/cc-dispatch.sh" && ok "AG(6): worktree-scope clause assembled into prompts" || no "AG(6): worktree-scope clause assembled into prompts" missing present

# ── restore section-external state and sweep every scratch artefact
PATH="$OP29"
export CC_TASKS_FILE="$svT" CC_STATUS_FILE="$svS" CC_ARCHIVE_FILE="$svA"
for _d in "$WTA" "$WTB" "$WTP"; do rm -f "$S29/cc-cmux-tabs/$(printf '%s' "$_d" | shasum -a 1 | cut -d' ' -f1)" 2>/dev/null; done
pfsweep29
rm -rf "$S29" "$FH29" "$REPO29" "$OTH29" 2>/dev/null; rm -f "$TF29B" "$SF29B" "$AF29B" "$TSKV29" "$TB29" "$LF29" "$FL29"
unset CC_FAKE_LOG29 CC_FAKE_SCREEN29 CC_FAKE_ON_SEND CC_FAKE_TUI29 CC_FAKE_FLUSH_AT CC_FAKE_PINGDOWN CC_LAUNCH_FILE

echo ""
echo "== 18. tab-close policy: the two ledgers + the sanctioned primitive =="
# The 2026-08-16 PreToolUse text gate (hooks/block-unsafe-close.sh) is RETIRED — a parser that had
# to decide whether prose quoting a close command IS a close command kept blocking real dispatch
# briefs, and could never see an alias or a script file anyway (docs/known-issues.md). What is
# tested here is what replaced it: the two LEDGERS (the sub-task board + opened-tabs.tsv) and the
# sanctioned primitive that resolves and enforces on top of them.
#
# fake cmux whose short refs DRIFT — `x-drift` renumbers every surface (surface:1xx/2xx/3xx climb)
# while the UUIDs stay put, exactly what a pane open/close does live and what killed the parent
# session on 2026-08-16. Refs are stable BETWEEN drifts, so a test can capture the current ref,
# drift, and prove the uuid path survives what the ref path does not.
# close-surface/new-surface/new-workspace record into $CC_FAKE_LOG.
CF=$(mktemp -d); export CC_FAKE_LOG="$CF/log"
cat > "$CF/cmux" <<'CMUX'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  identify) echo '{ "caller": {} }' ;;
  x-drift)
    n=$(cat "${CC_FAKE_LOG}.drift" 2>/dev/null || echo 0); echo "$((n+1))" > "${CC_FAKE_LOG}.drift" ;;
  list-pane-surfaces)
    n=$(cat "${CC_FAKE_LOG}.drift" 2>/dev/null || echo 0)
    printf '  surface:%s\tAAAAAAAA-1111-1111-1111-111111111111\tchild A\n' "$((100+n))"
    printf '* surface:%s\tBBBBBBBB-2222-2222-2222-222222222222\tchild B\n' "$((200+n))"
    printf '  surface:%s\tCCCCCCCC-3333-3333-3333-333333333333\tparent\n' "$((300+n))"
    printf '  surface:%s\tFFFFFFFF-6666-6666-6666-666666666666\tprimary checkout\n' "$((400+n))"
    printf '  surface:%s\tEEEEEEEE-5555-5555-5555-555555555555\thelper tab\n' "$((600+n))"
    ;;
  new-surface)
    n=$(cat "${CC_FAKE_LOG}.nscnt" 2>/dev/null || echo 500); n=$((n+1)); echo "$n" > "${CC_FAKE_LOG}.nscnt"
    printf 'NEWSURF|surface:%s|%s\n' "$n" "$*" >> "$CC_FAKE_LOG"
    printf 'OK surface:%s (99999999-7777-7777-7777-%012d) pane:1 (P) workspace:1 (W)\n' "$n" "$n" ;;
  new-workspace)
    n=$(cat "${CC_FAKE_LOG}.wscnt" 2>/dev/null || echo 700); n=$((n+1)); echo "$n" > "${CC_FAKE_LOG}.wscnt"
    printf 'NEWWS|%s\n' "$*" >> "$CC_FAKE_LOG"
    printf 'OK workspace:%s (WWWWWWWW-9999-9999-9999-%012d) surface:%s (88888888-9999-9999-9999-%012d)\n' "$n" "$n" "$n" "$n" ;;
  # ONE workspace, and list-pane-surfaces answers the same set with or without --workspace: this
  # fake is a single-workspace cmux. Needed since §26 — a probe that cannot list workspaces cannot
  # know what it missed, so it now counts as INCOMPLETE evidence and prunes nothing; without this
  # line the section's lazy-prune assertions would be testing the no-evidence path instead.
  list-workspaces) printf '* workspace:1  fake  [selected]\n' ;;
  close-surface) shift; printf 'CLOSE|%s\n' "$*" >> "$CC_FAKE_LOG" ;;
  send)     shift; printf 'SEND|%s\n' "$*" >> "$CC_FAKE_LOG" ;;
  send-key) shift; printf 'KEY|%s\n'  "$*" >> "$CC_FAKE_LOG" ;;
  read-screen) cat "$CF_SCREEN" 2>/dev/null ;;
esac
exit 0
CMUX
chmod +x "$CF/cmux"
NB18="$(printf '\xc2\xa0')"; export CF_SCREEN="$CF/screen"
{ echo "RDY22"; printf '\xe2\x9d\xaf%s\n' "$NB18"; echo "? for shortcuts"; } > "$CF_SCREEN"
OP18="$PATH"
UA="AAAAAAAA-1111-1111-1111-111111111111"   # child A, dispatched by PARENT
UB="BBBBBBBB-2222-2222-2222-222222222222"   # child B, dispatched by SOMEONE ELSE
UP="CCCCCCCC-3333-3333-3333-333333333333"   # PARENT (this session in these tests)
UO="DDDDDDDD-4444-4444-4444-444444444444"   # the other parent
UH="EEEEEEEE-5555-5555-5555-555555555555"   # a HELPER tab (non-worktree dir) opened by PARENT
UM="FFFFFFFF-6666-6666-6666-666666666666"   # the primary checkout tab (human-opened)
UD="DEADDEAD-0000-0000-0000-000000000000"   # a surface that no longer resolves (prune fodder)
cn18(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
R18="$(cn18 "$(mktemp -d)")"; mkdir -p "$R18/.claude/worktrees/wtA" "$R18/.claude/worktrees/wtB"
WA="$R18/.claude/worktrees/wtA"; WB="$R18/.claude/worktrees/wtB"
HD18="$(cn18 "$(mktemp -d)")"                # the helper tab's cwd: a plain, NON-worktree directory
TF18=$(mktemp -u); ST18="$CF/store.json"; echo '{}' > "$ST18"
la18(){ printf 'uuid=u%s:provider=anthropic:pm=auto:csuuid=%s:suuid=%s' "$1" "$2" "$3"; }
printf '2026-01-01 00:00:01\tfeat/A\tsurface:101\t%s\tsurface:9\ttask A\tmain\t%s\n' "$WA"  "$(la18 1 "$UP" "$UA")" >  "$TF18"
printf '2026-01-01 00:00:02\tfeat/B\tsurface:201\t%s\tsurface:9\ttask B\tmain\t%s\n' "$WB"  "$(la18 2 "$UO" "$UB")" >> "$TF18"
printf '2026-01-01 00:00:03\tmain\tsurface:301\t%s\tsurface:9\tprimary checkout\tmain\t%s\n' "$R18" "$(la18 3 "$UP" "$UM")" >> "$TF18"
# pre-feature row (no csuuid/suuid at all) — must still parse, and resolve only via opened-tabs
R18OLD="$(cn18 "$(mktemp -d)")"; mkdir -p "$R18OLD/.claude/worktrees/wtOld"; WOLD="$R18OLD/.claude/worktrees/wtOld"
printf '2026-01-01 00:00:04\tfeat/OLD\tsurface:401\t%s\tsurface:9\told row\tmain\tuuid=u4:provider=kimi:pm=auto:model=glm-4.6\n' "$WOLD" >> "$TF18"

# ── the opened-tabs ledger (item A): who opened which tab ──────────────────────────────────
TB18=$(mktemp -u)
tb18(){ printf '%s\t%s\t%s\t%s\t2026-01-01 00:00:00\n' "$1" "$2" "$3" "${4:--}" >> "$TB18"; }
tb18 "$UA" "$UP" "$WA" "u1"          # the same child the board knows: both ledgers, never deduped
tb18 "$UH" "$UP" "$HD18" "-"         # a helper tab in a NON-worktree dir, opened by this session
tb18 "$UD" "$UP" "/tmp/cc-gone" "-"  # a dead surface: lazy pruning must drop this row
eq "ledger rows are 5 fields"  "$(awk -F'\t' 'NR==1{print NF}' "$TB18")" "5"
eq "ledger writes - for an empty field" "$(awk -F'\t' 'NR==2{print $4}' "$TB18")" "-"

tabs18(){ ( cd "$R18" && env PATH="${2:-$CF:$OP18}" CC_TABS_FILE="$TB18" \
    CC_CALLER_SURFACE_UUID="${3:-$UP}" bash "$CC/cc-dispatch.sh" tabs ${1:-} ) 2>&1; }
# cmux unreachable → nothing is pruned (a probe that failed is not evidence that the tabs died)
TO18="$(tabs18 "" "/usr/bin:/bin")"
eq "tabs warns when cmux is unreachable" "$(echo "$TO18" | grep -c 'cmux unreachable')" "1"
eq "unreachable cmux prunes nothing"     "$(grep -c "^$UD" "$TB18")" "1"
# with a live map: the inventory renders and the dead row is pruned away
TO18="$(tabs18)"
eq "tabs prints the header"        "$(echo "$TO18" | grep -cE '^REF +UUID +STATE +OWNER +DIR')" "1"
eq "tabs resolves the live ref"    "$(echo "$TO18" | grep -c "surface:100 .*$UA .*alive")" "1"
eq "tabs shows the helper tab"     "$(echo "$TO18" | grep -c "$UH .*alive")" "1"
eq "tabs marks this session"       "$(echo "$TO18" | grep -c "$UP (self)")" "2"
eq "tabs prints the dir"           "$(echo "$TO18" | grep -cF "$HD18")" "1"
eq "lazy prune dropped the dead row" "$(awk -v u="$UD" '$1==u{c++} END{print c+0}' "$TB18" 2>/dev/null || echo 0)" "0"
eq "lazy prune kept the live rows"    "$(grep -c . "$TB18")" "2"
# the default view is "tabs I opened"; --all is everyone's
tb18 "$UB" "$UO" "$WB" "u2"
eq "tabs hides another session's row" "$(tabs18 | grep -c "$UB")" "0"
eq "tabs --all shows every row"       "$(tabs18 --all | grep -c "$UB")" "1"

# — the sanctioned primitive: resolves by RECORDED uuid, prints it, enforces the policy —
cl18(){ ( cd "$R18" && env PATH="$CF:$OP18" CC_TASKS_FILE="$TF18" CC_TABS_FILE="$TB18" CC_CMUX_SESSIONS="$ST18" \
    CC_CALLER_SURFACE_UUID="${2:-$UP}" CLAUDECODE=1 bash "$CC/cc-dispatch.sh" close "$1" ) 2>&1; }
: > "$CC_FAKE_LOG"
CO="$(cl18 "$WA")"; crc=$?
eq "close exit0 on own child"  "$crc" "0"
eq "close prints the uuid"     "$(echo "$CO" | grep -c "uuid=$UA")" "1"
eq "close prints a short ref"  "$(echo "$CO" | grep -cE 'resolved : surface:[0-9]+')" "1"
eq "close prints the cwd"      "$(echo "$CO" | grep -cF "cwd=$WA")" "1"
eq "close closes BY UUID"      "$(grep -cF "CLOSE|--surface $UA" "$CC_FAKE_LOG")" "1"
eq "close never uses a ref"    "$(grep -c 'CLOSE|--surface surface:' "$CC_FAKE_LOG")" "0"
# short refs DRIFT; the recorded uuid does not — one pane open/close renumbers everything and the
# primitive still resolves the same tab (this is why nothing is ever closed by a short ref)
env PATH="$CF:$OP18" cmux x-drift >/dev/null 2>&1
: > "$CC_FAKE_LOG"
CO="$(cl18 "$WA")"
eq "close survives a ref drift" "$(grep -cF "CLOSE|--surface $UA" "$CC_FAKE_LOG")" "1"
eq "drifted ref is the NEW one" "$(echo "$CO" | grep -c 'resolved : surface:101')" "1"
: > "$CC_FAKE_LOG"
CO="$(cl18 "$WB")"; crc=$?
eq "close refuses another parent's child" "$crc" "1"
eq "refusal names the owner"   "$(echo "$CO" | grep -c "dispatched by $UO")" "1"
eq "refusal closes nothing"    "$(grep -c 'CLOSE|' "$CC_FAKE_LOG")" "0"
: > "$CC_FAKE_LOG"
CO="$(cl18 "$WA" "$UA")"; crc=$?
eq "close refuses self-close"  "$crc" "1"
eq "self refusal closes nothing" "$(grep -c 'CLOSE|' "$CC_FAKE_LOG")" "0"
: > "$CC_FAKE_LOG"
CO="$(cl18 "$R18")"; crc=$?
eq "close refuses the primary checkout" "$crc" "1"
eq "primary refusal says not a worktree" "$(echo "$CO" | grep -c 'not a worktree checkout')" "1"
eq "primary refusal closes nothing" "$(grep -c 'CLOSE|' "$CC_FAKE_LOG")" "0"
: > "$CC_FAKE_LOG"
CO="$(cl18 "$WOLD")"; crc=$?
eq "close refuses an unresolvable dir" "$crc" "0"
eq "unresolvable says nothing to do"   "$(echo "$CO" | grep -c 'nothing to do')" "1"
eq "unresolvable closes nothing"       "$(grep -c 'CLOSE|' "$CC_FAKE_LOG")" "0"

# — item A, the headline: a HELPER tab (non-worktree dir, no board row at all) is closable by the
#   session that OPENED it, and by nobody else. Before the opened-tabs ledger there was no way to
#   say who opened such a tab, so it was protected from its own opener —
: > "$CC_FAKE_LOG"
CO="$(cl18 "$HD18")"; crc=$?
eq "helper tab closable by its opener" "$crc" "0"
eq "helper close says why it is allowed" "$(echo "$CO" | grep -c 'records THIS session as its opener')" "1"
eq "helper tab closed BY UUID"         "$(grep -cF "CLOSE|--surface $UH" "$CC_FAKE_LOG")" "1"
: > "$CC_FAKE_LOG"
CO="$(cl18 "$HD18" "$UO")"; crc=$?
eq "a THIRD session may not close it" "$crc" "1"
eq "third-session refusal says not a worktree" "$(echo "$CO" | grep -c 'not a worktree checkout')" "1"
eq "third-session refusal closes nothing"      "$(grep -c 'CLOSE|' "$CC_FAKE_LOG")" "0"

# — item A: the board row has NO suuid (pre-ledger child) → resolution falls back to opened-tabs —
TF18P=$(mktemp -u); PW18="$(cn18 "$(mktemp -d)")"; PWD18="$PW18/.claude/worktrees/wtP"; mkdir -p "$PWD18"
printf '2026-01-01 00:00:01\tfeat/P\tsurface:101\t%s\tsurface:9\tpre-ledger child\tmain\tuuid=u9:provider=anthropic:pm=auto\n' "$PWD18" > "$TF18P"
TB18P=$(mktemp -u)
printf '%s\t%s\t%s\tu9\t2026-01-01 00:00:00\n' "$UA" "$UP" "$PWD18" > "$TB18P"
plc18(){ ( cd "$R18" && env PATH="$CF:$OP18" CC_TASKS_FILE="${2:-$TF18P}" CC_TABS_FILE="$TB18P" \
    CC_CMUX_SESSIONS="$ST18" CC_CALLER_SURFACE_UUID="$UP" CLAUDECODE=1 \
    bash "$CC/cc-dispatch.sh" close "$1" ) 2>&1; }
: > "$CC_FAKE_LOG"
CO="$(plc18 "$PWD18")"; crc=$?
eq "suuid-less board row falls back to opened-tabs" "$crc" "0"
eq "fallback closed BY UUID"      "$(grep -cF "CLOSE|--surface $UA" "$CC_FAKE_LOG")" "1"
eq "fallback took the ledger owner" "$(echo "$CO" | grep -c "parent=$UP")" "1"
# — and the regression the human hit live: plain `gwt-rm` drops the board row entirely, then
#   `close <dir>` used to answer "no live tab resolves" and the tab had to be closed by hand.
#   opened-tabs is the ledger gwt-rm does NOT touch (only the lazy prune ever drops a row) —
TF18E=$(mktemp -u); : > "$TF18E"
: > "$CC_FAKE_LOG"
CO="$(plc18 "$PWD18" "$TF18E")"; crc=$?
eq "close works after gwt-rm dropped the row" "$crc" "0"
eq "post-rm close closed BY UUID"  "$(grep -cF "CLOSE|--surface $UA" "$CC_FAKE_LOG")" "1"
eq "post-rm close never says nothing-to-do" "$(echo "$CO" | grep -c 'nothing to do')" "0"

# — the ownership truth table, all four cells. The last one is the protection invariant: an
#   IN-PROGRESS sub-task can only be terminated by its own parent (or by the human) —
DR18="$(cn18 "$(mktemp -d)")"
( cd "$DR18"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wtOwn -b feat/own >/dev/null
  git worktree add -q .claude/worktrees/wtOther -b feat/other >/dev/null )
DOWN="$(cn18 "$DR18/.claude/worktrees/wtOwn")"; DOTH="$(cn18 "$DR18/.claude/worktrees/wtOther")"
TF18T=$(mktemp -u); TB18T=$(mktemp -u); : > "$TB18T"
printf '2026-01-01 00:00:01\tfeat/own\tsurface:101\t%s\tsurface:9\towned child\tmain\t%s\n'   "$DOWN" "$(la18 1 "$UP" "$UA")" >  "$TF18T"
printf '2026-01-01 00:00:02\tfeat/other\tsurface:201\t%s\tsurface:9\tother child\tmain\t%s\n' "$DOTH" "$(la18 2 "$UO" "$UB")" >> "$TF18T"
tt18(){ ( cd "$DR18" && env PATH="$CF:$OP18" CC_TASKS_FILE="$TF18T" CC_TABS_FILE="$TB18T" \
    CC_CMUX_SESSIONS="$ST18" CC_CALLER_SURFACE_UUID="$UP" CLAUDECODE=1 \
    bash "$CC/cc-dispatch.sh" close "$1" >/dev/null 2>&1; echo $? ); }
eq "truth table: owner + NOT done → allow"      "$(tt18 "$DOWN")" "0"
eq "truth table: third party + NOT done → DENY" "$(tt18 "$DOTH")" "1"
bash "$CC/cc-merge.sh" done "$DR18" feat/own   true >/dev/null 2>&1
bash "$CC/cc-merge.sh" done "$DR18" feat/other true >/dev/null 2>&1
eq "truth table: owner + done → allow"          "$(tt18 "$DOWN")" "0"
eq "truth table: third party + done → allow"    "$(tt18 "$DOTH")" "0"
: > "$CC_FAKE_LOG"
CO="$( ( cd "$DR18" && env PATH="$CF:$OP18" CC_TASKS_FILE="$TF18T" CC_TABS_FILE="$TB18T" \
    CC_CMUX_SESSIONS="$ST18" CC_CALLER_SURFACE_UUID="$UP" CLAUDECODE=1 \
    bash "$CC/cc-dispatch.sh" close "$DOTH" ) 2>&1 )"
eq "done-unlock says why it is allowed" "$(echo "$CO" | grep -c 'collectible by any automated caller')" "1"
eq "done-unlock still closes BY UUID"   "$(grep -cF "CLOSE|--surface $UB" "$CC_FAKE_LOG")" "1"
# the unlock is DONE-state only: undoing it restores the protection
bash "$CC/cc-merge.sh" done "$DR18" feat/other false >/dev/null 2>&1
eq "un-done restores the protection" "$(tt18 "$DOTH")" "1"

# — automated vs human is decided by PROCESS ANCESTRY, not by an env var —
# `env -u CLAUDECODE cc-dispatch.sh close <someone-elses-child>` really closed the tab under the
# env-var discriminator (gate review 2026-08-16), because anything in the environment is strip-able
# from the very command line being gated. A fake `ps` on the PATH shim drives both chains.
cat > "$CF/ps" <<'PS'
#!/usr/bin/env bash
# fake ps: answers `-o ppid= -p N` / `-o comm= -p N` from $CC_FAKE_PSMAP ("pid ppid comm" lines).
# A pid that is not in the map is the REAL process the walk starts from — it enters the synthetic
# chain at its first row.
want=""; pid=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) case "$2" in ppid*) want=ppid ;; comm*) want=comm ;; esac; shift 2 ;;
    -p) pid="${2:-}"; shift 2 ;;
    *)  shift ;;
  esac
done
row="$(awk -v p="$pid" '$1==p{print; exit}' "$CC_FAKE_PSMAP" 2>/dev/null)"
if [ -z "$row" ]; then
  if [ "$want" = ppid ]; then awk 'NR==1{print $1}' "$CC_FAKE_PSMAP" 2>/dev/null; else echo "/bin/bash"; fi
  exit 0
fi
set -- $row
if [ "$want" = ppid ]; then echo "$2"; else echo "$3"; fi
PS
chmod +x "$CF/ps"
printf '90001 90002 -/bin/zsh\n90002 90003 /usr/bin/login\n90003 1 /sbin/launchd\n' > "$CF/ps.human"
printf '90001 90002 /bin/bash\n90002 90003 /opt/homebrew/bin/claude\n90003 1 /sbin/launchd\n' > "$CF/ps.agent"
anc18(){ # $1 = chain fixture, $2 = dir  →  runs the primitive with CLAUDECODE stripped
  ( cd "$R18" && env -u CLAUDECODE PATH="$CF:$OP18" CC_TASKS_FILE="$TF18" CC_TABS_FILE="$TB18" \
      CC_CMUX_SESSIONS="$ST18" CC_FAKE_PSMAP="$CF/ps.$1" CC_CALLER_SURFACE_UUID="$UP" \
      bash "$CC/cc-dispatch.sh" close "$2" ) 2>&1; }
: > "$CC_FAKE_LOG"
CO="$(anc18 agent "$WB")"; crc=$?
eq "env -u CLAUDECODE cannot spoof human" "$crc" "1"
eq "spoof attempt closes nothing"         "$(grep -c 'CLOSE|' "$CC_FAKE_LOG")" "0"
eq "spoof refusal names the owner"        "$(echo "$CO" | grep -c "dispatched by $UO")" "1"
: > "$CC_FAKE_LOG"
CO="$(anc18 human "$WB")"
eq "human shell may close another's child" "$(grep -cF "CLOSE|--surface $UB" "$CC_FAKE_LOG")" "1"
eq "human shell still reports the owner"   "$(echo "$CO" | grep -c 'ownership check reported')" "1"
# the ancestry walk never weakens the OTHER two rules
: > "$CC_FAKE_LOG"
CO="$(anc18 human "$R18")"
eq "human shell still refused the primary checkout" "$(echo "$CO" | grep -c 'not a worktree checkout')" "1"
: > "$CC_FAKE_LOG"
CO="$( ( cd "$R18" && env -u CLAUDECODE PATH="$CF:$OP18" CC_TASKS_FILE="$TF18" CC_TABS_FILE="$TB18" \
      CC_CMUX_SESSIONS="$ST18" CC_FAKE_PSMAP="$CF/ps.human" CC_CALLER_SURFACE_UUID="$UA" \
      bash "$CC/cc-dispatch.sh" close "$WA" ) 2>&1 )"
eq "human shell still refused a self-close" "$(echo "$CO" | grep -c 'no automated self-close')" "1"
eq "self refusal closed nothing"            "$(grep -c 'CLOSE|' "$CC_FAKE_LOG")" "0"

# — dispatch records BOTH stable identities on the board row AND a row in the opened-tabs ledger —
FH18=$(mktemp -d); mkdir -p "$FH18/.config"; cp -R "$CC" "$FH18/.config/cc-stack"
TF18D=$(mktemp -u); TB18D=$(mktemp -u); DD="$(cn18 "$(mktemp -d)")"
: > "$CC_FAKE_LOG"
env HOME="$FH18" PATH="$CF:$OP18" CC_TASKS_FILE="$TF18D" CC_TABS_FILE="$TB18D" CC_CMUX_SESSIONS="$ST18" \
  CC_SEND_FAILLOG="$CF/fail" CC_SEND_VERIFY_SEC=0.1 CC_LAUNCH_FILE="$CF/launch" \
  CC_CALLER_SURFACE_UUID="$UP" bash "$CC/cc-dispatch.sh" surface "$DD" "dispatch brief" >/dev/null 2>&1
DLA="$(awk -F'\t' -v d="$DD" '$4==d{print $8}' "$TF18D")"
NSU="$(grep -oE 'NEWSURF\|surface:[0-9]+' "$CC_FAKE_LOG" | head -1 | cut -d: -f2)"
DSU="99999999-7777-7777-7777-$(printf '%012d' "$NSU")"
eq "dispatch asks for both ids" "$(grep -c -- '--id-format both' "$CC_FAKE_LOG")" "1"
eq "row records the caller uuid" "$(printf '%s' "$DLA" | grep -c "csuuid=$UP")" "1"
eq "row records the tab uuid"    "$(printf '%s' "$DLA" | grep -c "suuid=$DSU")" "1"
eq "model still composed LAST"   "$(printf '%s' "$DLA" | grep -c 'suuid=[^:]*$')" "1"
eq "dispatch row has 8 fields"   "$(awk -F'\t' -v d="$DD" '$4==d{print NF}' "$TF18D")" "8"
# the second ledger: one row per opened tab, keyed by the tab's own surface uuid
eq "ledger row written on open"     "$(awk -F'\t' -v u="$DSU" 'toupper($1)==toupper(u){c++} END{print c+0}' "$TB18D")" "1"
eq "ledger row records the OWNER"   "$(awk -F'\t' -v u="$DSU" 'toupper($1)==toupper(u){print $2}' "$TB18D")" "$UP"
eq "ledger row records the dir"     "$(awk -F'\t' -v u="$DSU" 'toupper($1)==toupper(u){print $3}' "$TB18D")" "$DD"
eq "ledger row records the session" "$(awk -F'\t' -v u="$DSU" 'toupper($1)==toupper(u){print ($4!="-" && $4!="")?"yes":"no"}' "$TB18D")" "yes"
eq "ledger session matches the board" "$(awk -F'\t' -v u="$DSU" 'toupper($1)==toupper(u){print "uuid=" $4}' "$TB18D")" "$(printf '%s' "$DLA" | cut -d: -f1)"
eq "board and ledger both kept (no dedupe)" "$(awk -F'\t' -v d="$DD" '$4==d{c++} END{print c+0}' "$TF18D")+$(awk -F'\t' -v d="$DD" '$3==d{c++} END{print c+0}' "$TB18D")" "1+1"
rm -f "${TMPDIR:-/tmp}/cc-cmux-tabs/$(printf '%s' "$DD" | shasum -a 1 | cut -d' ' -f1)" 2>/dev/null
# …and a workspace open (gwt-new / gwt-adopt path) lands in the same ledger
WSD="$(cn18 "$(mktemp -d)")"
: > "$CC_FAKE_LOG"
env HOME="$FH18" PATH="$CF:$OP18" CC_TABS_FILE="$TB18D" CC_CALLER_SURFACE_UUID="$UP" \
  bash "$CC/cc-dispatch.sh" workspace "$WSD" >/dev/null 2>&1
WSU="$(grep -oE 'NEWWS\|' "$CC_FAKE_LOG" | head -1)"
eq "workspace really opened one"     "${WSU:-none}" "NEWWS|"
eq "workspace open records a row"    "$(awk -F'\t' -v d="$WSD" '$3==d{c++} END{print c+0}' "$TB18D")" "1"
eq "workspace row records the owner" "$(awk -F'\t' -v d="$WSD" '$3==d{print $2}' "$TB18D")" "$UP"

# — old rows keep working: a 7-field board row parses and simply has no recorded identity —
TF18O=$(mktemp -u); WO7="$(cn18 "$(mktemp -d)")"
printf '2026-01-01 00:00:01\tfeat/O7\tsurface:101\t%s\tsurface:9\tseven fields\tmain\n' "$WO7" > "$TF18O"
eq "7-field row still 7 fields" "$(awk -F'\t' 'NR==1{print NF}' "$TF18O")" "7"
TB18O=$(mktemp -u); : > "$TB18O"
eq "7-field row has nothing to close" "$( ( cd "$R18" && env PATH="$CF:$OP18" CC_TASKS_FILE="$TF18O" \
  CC_TABS_FILE="$TB18O" CC_CMUX_SESSIONS="$ST18" CC_CALLER_SURFACE_UUID="$UP" CLAUDECODE=1 \
  bash "$CC/cc-dispatch.sh" close "$WO7" 2>&1 | grep -c 'nothing to do' ) )" "1"

# — gwt-rm --close routes the tab close through the primitive (and only that way) —
RM18="$(cn18 "$(mktemp -d)")"
( cd "$RM18"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wtS -b feat/S >/dev/null )
SW18="$(cn18 "$RM18/.claude/worktrees/wtS")"
TF18R=$(mktemp -u); SF18R=$(mktemp -u); TB18R=$(mktemp -u); : > "$TB18R"
printf '2026-01-01 00:00:01\tfeat/S\tsurface:101\t%s\tsurface:9\trm close\tmain\t%s\n' "$SW18" "$(la18 5 "$UP" "$UA")" > "$TF18R"
: > "$CC_FAKE_LOG"
RMOUT="$(env HOME="$FH18" PATH="$CF:$OP18" CC_TASKS_FILE="$TF18R" CC_STATUS_FILE="$SF18R" CC_TABS_FILE="$TB18R" \
  CC_CMUX_SESSIONS="$ST18" CC_CALLER_SURFACE_UUID="$UP" \
  zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$RM18'; gwt-rm wtS --close" 2>&1)"
eq "gwt-rm --close removed the worktree" "$([ -d "$SW18" ] && echo yes || echo no)" "no"
eq "gwt-rm --close closed BY UUID"       "$(grep -cF "CLOSE|--surface $UA" "$CC_FAKE_LOG")" "1"
eq "gwt-rm --close printed the resolution" "$(echo "$RMOUT" | grep -c "uuid=$UA")" "1"
eq "gwt-rm --close still drops the row"  "$(awk -F'\t' -v d="$SW18" '$4==d{c++} END{print c+0}' "$TF18R" 2>/dev/null || echo 0)" "0"
# plain gwt-rm (no flag) touches no tab
( cd "$RM18" && git worktree add -q .claude/worktrees/wtT -b feat/T >/dev/null )
ST18B="$(cn18 "$RM18/.claude/worktrees/wtT")"
printf '2026-01-01 00:00:02\tfeat/T\tsurface:102\t%s\tsurface:9\tno close\tmain\t%s\n' "$ST18B" "$(la18 6 "$UP" "$UA")" > "$TF18R"
: > "$CC_FAKE_LOG"
env HOME="$FH18" PATH="$CF:$OP18" CC_TASKS_FILE="$TF18R" CC_STATUS_FILE="$SF18R" CC_TABS_FILE="$TB18R" \
  CC_CMUX_SESSIONS="$ST18" CC_CALLER_SURFACE_UUID="$UP" \
  zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$RM18'; gwt-rm wtT" >/dev/null 2>&1
eq "plain gwt-rm closes no tab"          "$(grep -c 'CLOSE|' "$CC_FAKE_LOG")" "0"

# — BOTH retired PreToolUse text gates are really gone (files, registrations, references) —
# The commit gate moved out of PreToolUse on 2026-08-16 too (§25): it is now git's own pre-commit
# hook, so NOTHING this stack ships is registered on PreToolUse any more.
eq "close gate file deleted"      "$([ -e "$CC/hooks/block-unsafe-close.sh" ] && echo present || echo gone)" "gone"
eq "commit text gate file deleted" "$([ -e "$CC/hooks/block-worktree-commit.sh" ] && echo present || echo gone)" "gone"
# A retired gate may still be NAMED in a comment (git-pre-commit.sh explains what it replaced, and
# install.sh carries both bare names as sweep data) — what must be gone is any live CODE path that
# still runs one, so comment lines don't count.
eq "no live code path runs them" "$(grep -rn 'block-unsafe-close\|block-worktree-commit' "$CC"/*.sh "$CC"/hooks/* 2>/dev/null \
  | grep -v '/install.sh:' | grep -v '/test.sh:' | grep -vc ':[0-9][0-9]*:[[:space:]]*#')" "0"

# — install distributes the git hook body, registers NOTHING on PreToolUse, sweeps both retired gates —
IH18=$(mktemp -d)
HOME="$IH18" bash "$CC/install.sh" --yes --dir "$IH18/cc" >/dev/null 2>&1
sn18(){ python3 -c 'import json,sys
d=json.load(open(sys.argv[1]+"/.claude/settings.json"))
print(sum(1 for g in d.get("hooks",{}).get("PreToolUse",[]) or [] for h in (g.get("hooks") or []) if sys.argv[2] in (h.get("command") or "")))' "$IH18" "$1"; }
eq "install ships the git-hook body" "$([ -x "$IH18/cc/hooks/git-pre-commit.sh" ] && echo yes || echo no)" "yes"
eq "install ships standalone gwt-done" "$([ -x "$IH18/cc/gwt-done" ] && echo yes || echo no)" "yes"
eq "install registers NO commit gate" "$(sn18 'block-worktree-commit.sh')" "0"
eq "install registers NO close gate"   "$(sn18 'block-unsafe-close.sh')" "0"
eq "install ships no close gate file"  "$([ -e "$IH18/cc/hooks/block-unsafe-close.sh" ] && echo present || echo gone)" "gone"
eq "rules line reaches CLAUDE.md"   "$(grep -c 'cc-dispatch.sh close' "$IH18/.claude/CLAUDE.md")" "1"
eq "rules line warns on short ids"  "$(grep -c 'NEVER hardcode a surface short id' "$IH18/.claude/CLAUDE.md")" "1"
eq "rules line drops the hook claim" "$(grep -c 'PreToolUse hook blocks those forms' "$IH18/.claude/CLAUDE.md")" "0"
# a settings.json still carrying EITHER retired gate (repo path or the pre-repo ~/.claude/hooks/
# copy) is swept, and the retired FILES are deleted from the install dir on the next run
python3 -c 'import json,sys
p=sys.argv[1]+"/.claude/settings.json"
d=json.load(open(p))
d.setdefault("hooks",{}).setdefault("PreToolUse",[]).append({"matcher":"Bash","hooks":[{"type":"command","command":"bash ~/.claude/hooks/block-worktree-commit.sh"}]})
d["hooks"]["PreToolUse"].append({"matcher":"Bash","hooks":[{"type":"command","command":"bash "+sys.argv[1]+"/cc/hooks/block-worktree-commit.sh"}]})
d["hooks"]["PreToolUse"].append({"matcher":"Bash","hooks":[{"type":"command","command":"bash "+sys.argv[1]+"/cc/hooks/block-unsafe-close.sh"}]})
json.dump(d,open(p,"w"))' "$IH18"
touch "$IH18/cc/hooks/block-unsafe-close.sh" "$IH18/cc/hooks/block-worktree-commit.sh"
eq "the stale registrations are really there" "$(sn18 'block-worktree-commit.sh')" "2"
HOME="$IH18" bash "$CC/install.sh" --yes --dir "$IH18/cc" >/dev/null 2>&1
eq "strip removes the orphan registration" "$(sn18 '.claude/hooks/block-worktree-commit.sh')" "0"
eq "strip removes the repo-path registration" "$(sn18 'block-worktree-commit.sh')" "0"
eq "strip removes the retired close gate"  "$(sn18 'block-unsafe-close.sh')" "0"
eq "strip removes the close gate FILE"     "$([ -e "$IH18/cc/hooks/block-unsafe-close.sh" ] && echo present || echo gone)" "gone"
eq "strip removes the commit gate FILE"    "$([ -e "$IH18/cc/hooks/block-worktree-commit.sh" ] && echo present || echo gone)" "gone"
eq "the surviving hooks all survived"      "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]+"/.claude/settings.json"))
h=d.get("hooks",{})
print(sum(1 for ev in ("PostToolUse","UserPromptSubmit","Stop","Notification") for g in h.get(ev,[]) or [] for x in (g.get("hooks") or []) if "cc-hooks.sh" in (x.get("command") or "")))' "$IH18")" "4"
rm -rf "$CF" "$R18" "$R18OLD" "$RM18" "$FH18" "$IH18" "$WO7" "$DD" "$HD18" "$PW18" "$DR18" "$WSD"
rm -f "$TF18" "$TF18D" "$TF18O" "$TF18R" "$SF18R" "$TB18" "$TB18D" "$TB18O" "$TB18R" "$TF18P" "$TB18P" "$TF18E" "$TF18T" "$TB18T"
unset CC_FAKE_LOG CF_SCREEN

echo ""
echo "== 25. commit gate: git's own pre-commit hook (migrated 2026-08-16) =="
# The gate that says "a worktree sub-task may not commit without the human" used to be a PreToolUse
# hook that parsed the TEXT of every Bash command and guessed the commit's target directory out of
# it (hooks/block-worktree-commit.sh, retired with its §23 red/green suite). It is now git's own
# pre-commit hook, mounted once per repo into the COMMON .git/hooks (shared by every linked
# worktree). Three live 2026-08-16 incidents drove the migration and are pinned one-for-one below
# as (a)/(b)/(c): the old gate blocked two things that were not commits at all, and let one real
# worktree commit straight through.
CG=$(mktemp -d); CGR="$(cn "$CG")"
( cd "$CGR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude
  git worktree add -q .claude/worktrees/w25 -b feat/w25 >/dev/null
  git worktree add -q .worktrees/v25       -b feat/v25 >/dev/null )
CGW="$(cn "$CGR/.claude/worktrees/w25")"; CGV="$(cn "$CGR/.worktrees/v25")"
# the DOWNSTREAM project's own hooks — the hard red line: they must keep working, both of them.
# (docs/issues/cc-stack-issues.md records a real repo that enforces Conventional Commits through
# commit-msg; core.hooksPath would have silently switched that off, which is why it is excluded.)
cat > "$CGR/.git/hooks/pre-commit" <<CGHOOK
#!/bin/sh
echo project-pre-commit >> "$CGR/evidence"
CGHOOK
cat > "$CGR/.git/hooks/commit-msg" <<CGHOOK
#!/bin/sh
echo project-commit-msg >> "$CGR/evidence"
CGHOOK
chmod +x "$CGR/.git/hooks/pre-commit" "$CGR/.git/hooks/commit-msg"
CGSHA="$(shasum -a 256 < "$CGR/.git/hooks/pre-commit" | awk '{print $1}')"
cgn(){ git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }   # commits on that checkout
cgev(){ tr '\n' ' ' < "$CGR/evidence" 2>/dev/null | sed 's/ $//'; }  # which project hooks ran

# — mount: preserve-and-chain, never overwrite —
CGM="$(bash "$CC/cc-dispatch.sh" commit-gate mount "$CGW" 2>&1)"
eq "mount reports the preserved hook" "$(printf '%s' "$CGM" | grep -c 'pre-commit.cc-stack-orig')" "1"
eq "gate is installed and executable" "$([ -x "$CGR/.git/hooks/pre-commit" ] && echo yes || echo no)" "yes"
eq "gate is identifiable"             "$(grep -c 'cc-stack:commit-gate' "$CGR/.git/hooks/pre-commit")" "1"
eq "the project's hook was PRESERVED" "$(shasum -a 256 < "$CGR/.git/hooks/pre-commit.cc-stack-orig" | awk '{print $1}')" "$CGSHA"
eq "commit-msg was never touched"     "$(grep -c 'project-commit-msg' "$CGR/.git/hooks/commit-msg")" "1"
# idempotence: a second mount is silent, adds no second copy of the logic, and does NOT swallow
# its own hook into the saved original (that is how a chain turns into a matryoshka)
CGM2="$(bash "$CC/cc-dispatch.sh" commit-gate mount "$CGW" 2>&1)"; cgrc2=$?
eq "re-mount is silent"               "$CGM2" ""
eq "re-mount rc 0"                    "$cgrc2" "0"
eq "still exactly one gate body"      "$(grep -c 'cc-stack:commit-gate' "$CGR/.git/hooks/pre-commit")" "1"
eq "saved original is still theirs"   "$(grep -c 'cc-stack:commit-gate' "$CGR/.git/hooks/pre-commit.cc-stack-orig")" "0"
eq "no nested .cc-stack-orig"         "$([ -e "$CGR/.git/hooks/pre-commit.cc-stack-orig.cc-stack-orig" ] && echo present || echo gone)" "gone"

# — the gate itself: blocked / granted / consumed / re-blocked —
: > "$CGR/evidence"
cgb="$(cgn "$CGW")"
CGO="$( cd "$CGW" && git commit -q --allow-empty -m blocked 2>&1 )"; cgrc=$?
eq "worktree commit is blocked (rc!=0)" "$([ "$cgrc" -ne 0 ] && echo y || echo n)" "y"
eq "and NO commit was produced"         "$(cgn "$CGW")" "$cgb"
eq "the block says how to authorize"    "$(printf '%s' "$CGO" | grep -c '\.commit-authorized')" "1"
eq "a blocked commit runs no project hook" "$(cgev)" ""
touch "$CGW/.commit-authorized"
: > "$CGR/evidence"
( cd "$CGW" && git commit -q --allow-empty -m granted ) >/dev/null 2>&1
eq "sentinel lets exactly one through"  "$(cgn "$CGW")" "$((cgb + 1))"
eq "sentinel is consumed"               "$([ -f "$CGW/.commit-authorized" ] && echo yes || echo no)" "no"
eq "an allowed commit CHAINS both project hooks" "$(cgev)" "project-pre-commit project-commit-msg"
cgb="$(cgn "$CGW")"
( cd "$CGW" && git commit -q --allow-empty -m spent ) >/dev/null 2>&1
eq "re-blocked once the grant is spent" "$(cgn "$CGW")" "$cgb"

# — scope: the primary checkout is untouched, and .worktrees/ is gated exactly like .claude/worktrees/ —
: > "$CGR/evidence"
cgb="$(cgn "$CGR")"
( cd "$CGR" && git commit -q --allow-empty -m primary ) >/dev/null 2>&1
eq "primary checkout is NOT gated"      "$(cgn "$CGR")" "$((cgb + 1))"
eq "and its project hooks still run"    "$(cgev)" "project-pre-commit project-commit-msg"
cgb="$(cgn "$CGV")"
( cd "$CGV" && git commit -q --allow-empty -m blocked ) >/dev/null 2>&1
eq ".worktrees/ layout is gated too"    "$(cgn "$CGV")" "$cgb"
# non-commit git is not even a code path any more — the hook only ever runs on a commit
cgb="$(cgn "$CGW")"
( cd "$CGW" && git status --porcelain ) >/dev/null 2>&1
eq "git status is untouched (rc 0)"     "$( ( cd "$CGW" && git status --porcelain >/dev/null 2>&1; echo $? ) )" "0"

# — the three live 2026-08-16 incidents, one assertion each —
# (a) MIS-BLOCK: a command whose TEXT merely quotes `git … commit` while committing nothing. The
# old gate's trigger grep could not tell prose from a command and blocked a sub-task writing a
# file. The new gate never reads command text at all, so this is trivially true — which is exactly
# the property worth pinning, both behaviourally and structurally.
CGA="$( cd "$CGW" && cat > prose.txt <<'CGPROSE'
example from the brief: git -C "$W" commit -m x   (and: cd /elsewhere && git commit -m y)
CGPROSE
echo $? )"
eq "(a) prose quoting a commit is a no-op" "$CGA" "0"
eq "(a) the file really got written"       "$(grep -c 'git -C' "$CGW/prose.txt")" "1"
eq "(a) the gate parses no command text"   "$(grep -c 'tool_input\|json.load\|read -r cmd' "$CC/hooks/git-pre-commit.sh")" "0"
rm -f "$CGW/prose.txt"
# (b) MIS-ALLOW (the serious one): `git -C "$VAR" commit` from a session parked in the PRIMARY
# checkout. The old gate saw the literal three characters $W, decided that was not a directory,
# fell back to the session cwd, found the primary checkout, and waved the commit through with the
# sentinel never read. git puts the hook's cwd inside the worktree no matter how it was named.
cgb="$(cgn "$CGW")"; CGVAR="$CGW"
( cd "$CGR" && git -C "$CGVAR" commit -q --allow-empty -m viavar ) >/dev/null 2>&1
eq "(b) git -C \$VAR from the primary is BLOCKED" "$(cgn "$CGW")" "$cgb"
eq "(b) and the sentinel still gates it"          "$( touch "$CGW/.commit-authorized"
  ( cd "$CGR" && git -C "$CGVAR" commit -q --allow-empty -m viavar ) >/dev/null 2>&1; cgn "$CGW" )" "$((cgb + 1))"
# (c) MIS-ALLOW: session cwd in the primary checkout, target reached by cd. Same fail-open in the
# old gate whenever the walk could not resolve the cd target (an unbalanced quote, a glob, a
# variable). Nothing to resolve here — the hook runs where the commit happens.
cgb="$(cgn "$CGW")"
( cd "$CGR" && cd "$CGW" && git commit -q --allow-empty -m viacd ) >/dev/null 2>&1
eq "(c) cd-into-the-worktree is BLOCKED"  "$(cgn "$CGW")" "$cgb"

# — accepted residue, pinned so nobody 'fixes' it by accident: --no-verify goes straight through —
cgb="$(cgn "$CGW")"
( cd "$CGW" && git commit -q --no-verify --allow-empty -m bypass ) >/dev/null 2>&1
eq "--no-verify bypasses (accepted)"      "$(cgn "$CGW")" "$((cgb + 1))"
eq "and the hook says so in writing"      "$([ "$(grep -c 'no-verify' "$CC/hooks/git-pre-commit.sh")" -ge 1 ] && echo y || echo n)" "y"

# — unmount: fully reversible, byte-for-byte —
CGU="$(bash "$CC/cc-dispatch.sh" commit-gate unmount "$CGW" 2>&1)"; cgurc=$?
eq "unmount rc 0"                        "$cgurc" "0"
eq "unmount restored the project's hook" "$(shasum -a 256 < "$CGR/.git/hooks/pre-commit" | awk '{print $1}')" "$CGSHA"
eq "and removed the saved copy"          "$([ -e "$CGR/.git/hooks/pre-commit.cc-stack-orig" ] && echo present || echo gone)" "gone"
cgb="$(cgn "$CGW")"
( cd "$CGW" && git commit -q --allow-empty -m ungated ) >/dev/null 2>&1
eq "ungated worktree commits again"      "$(cgn "$CGW")" "$((cgb + 1))"
CGU2="$(bash "$CC/cc-dispatch.sh" commit-gate unmount "$CGW" 2>&1)"
eq "unmount refuses a foreign hook"      "$(printf '%s' "$CGU2" | grep -c 'is not ours')" "1"
eq "and left it in place"                "$(shasum -a 256 < "$CGR/.git/hooks/pre-commit" | awk '{print $1}')" "$CGSHA"

# — a repo with NO pre-commit at all: mount writes one, unmount takes it away and leaves nothing —
CGP=$(mktemp -d); CGPR="$(cn "$CGP")"
( cd "$CGPR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wp -b feat/wp >/dev/null )
bash "$CC/cc-dispatch.sh" commit-gate mount "$CGPR/.claude/worktrees/wp" >/dev/null 2>&1
eq "clean repo: gate mounted"            "$(grep -c 'cc-stack:commit-gate' "$CGPR/.git/hooks/pre-commit")" "1"
eq "clean repo: nothing preserved"       "$([ -e "$CGPR/.git/hooks/pre-commit.cc-stack-orig" ] && echo present || echo gone)" "gone"
bash "$CC/cc-dispatch.sh" commit-gate unmount "$CGPR/.claude/worktrees/wp" >/dev/null 2>&1
eq "clean repo: unmount leaves nothing"  "$([ -e "$CGPR/.git/hooks/pre-commit" ] && echo present || echo gone)" "gone"

# — core.hooksPath: refuse loudly, change nothing. Setting it ourselves would silently disable the
# project's whole hook set (live-probed: its commit-msg stopped running); writing into the path it
# names is no better, because git resolves a RELATIVE core.hooksPath per working tree, so the file
# would land in the main checkout's working tree and be invisible to the worktrees being gated.
CGH=$(mktemp -d); CGHR="$(cn "$CGH")"
( cd "$CGHR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  git config core.hooksPath .githooks; mkdir .claude
  git worktree add -q .claude/worktrees/wh -b feat/wh >/dev/null )
CGHO="$(bash "$CC/cc-dispatch.sh" commit-gate mount "$CGHR/.claude/worktrees/wh" 2>&1)"; cghrc=$?
eq "core.hooksPath repo is refused"      "$cghrc" "3"
eq "the refusal names the reason"        "$(printf '%s' "$CGHO" | grep -c 'refusing to touch it')" "1"
eq "and it wrote NOTHING"                "$([ -e "$CGHR/.git/hooks/pre-commit" ] || [ -e "$CGHR/.githooks/pre-commit" ] && echo wrote || echo clean)" "clean"

# — a directory the repo does not list as a worktree is refused (fail-closed identity check) —
# The accident this pins, in full: install.sh copied the source's `.git` — a FILE in a linked
# worktree — into the install dir, so `git -C <install-dir> rev-parse` answered with the SOURCE
# repo's git dir, and step 4b dutifully wrote a hook into a live checkout nobody had named. Both
# ends are now closed: install.sh no longer copies `.git` (asserted below), and a mount whose
# target the repo does not list as one of its worktrees is refused outright.
CGX=$(mktemp -d); CGXR="$(cn "$CGX")"
( cd "$CGXR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wx -b feat/wx >/dev/null )
CGXF=$(mktemp -d); CGXFR="$(cn "$CGXF")"; mkdir -p "$CGXFR/.claude/worktrees/fake"
cp "$CGXR/.claude/worktrees/wx/.git" "$CGXFR/.claude/worktrees/fake/.git"   # the stray pointer
eq "a stray .git really misdirects git" "$(cn "$(git -C "$CGXFR/.claude/worktrees/fake" rev-parse --git-common-dir 2>/dev/null)")" "$(cn "$CGXR/.git")"
CGXO="$(bash "$CC/cc-dispatch.sh" commit-gate mount "$CGXFR/.claude/worktrees/fake" 2>&1)"; cgxrc=$?
eq "unlisted worktree is refused"       "$cgxrc" "3"
eq "the refusal explains why"           "$(printf '%s' "$CGXO" | grep -c 'does not list it as a worktree')" "1"
eq "and the misdirected repo is clean"  "$([ -e "$CGXR/.git/hooks/pre-commit" ] && echo present || echo gone)" "gone"
rm -rf "$CGX" "$CGXF"

# — a foreign hook sitting on top of an already-saved original is ambiguous: refuse, touch nothing —
CGF=$(mktemp -d); CGFR="$(cn "$CGF")"
( cd "$CGFR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wf -b feat/wf >/dev/null )
printf '#!/bin/sh\nexit 0\n' > "$CGFR/.git/hooks/pre-commit"; chmod +x "$CGFR/.git/hooks/pre-commit"
printf '#!/bin/sh\nexit 0\n' > "$CGFR/.git/hooks/pre-commit.cc-stack-orig"
CGFO="$(bash "$CC/cc-dispatch.sh" commit-gate mount "$CGFR/.claude/worktrees/wf" 2>&1)"; cgfrc=$?
eq "ambiguous state is refused"          "$cgfrc" "3"
eq "the foreign hook is untouched"       "$(grep -c 'cc-stack:commit-gate' "$CGFR/.git/hooks/pre-commit")" "0"

# — the dispatch paths mount it themselves: this is what makes the gate exist without a human —
# Driven through the real `surface` subcommand against a fake cmux, the same harness §21 uses.
CGS=$(mktemp -d); export CC_FAKE_LOG25="$CGS/log"; export CF_SCREEN25="$CGS/screen"
cat > "$CGS/cmux" <<'CGCMUX'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  identify) echo '{ "caller": {} }' ;;
  list-pane-surfaces) printf '* surface:901\t99999999-BBBB-BBBB-BBBB-999999999999\tthis session\n' ;;
  new-surface) printf 'OK surface:901 (99999999-BBBB-BBBB-BBBB-999999999999) pane:1 (P) workspace:1 (W)\n' ;;
  send|send-key|notify|close-surface) : ;;
  read-screen) cat "$CF_SCREEN25" 2>/dev/null ;;
esac
exit 0
CGCMUX
chmod +x "$CGS/cmux"
{ echo "RDY22"; echo "? for shortcuts"; } > "$CF_SCREEN25"
OP25="$PATH"; FH25=$(mktemp -d); mkdir -p "$FH25/.config"; cp -R "$CC" "$FH25/.config/cc-stack"
CGD=$(mktemp -d); CGDR="$(cn "$CGD")"
( cd "$CGDR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wd -b feat/wd >/dev/null )
CGDW="$(cn "$CGDR/.claude/worktrees/wd")"
( cd "$CGDR" && env HOME="$FH25" PATH="$CGS:$OP25" CC_TASKS_FILE="$CC_TEST_SANDBOX/25-tasks.tsv" \
    CC_TABS_FILE="$CC_TEST_SANDBOX/25-tabs.tsv" CC_WT_PRETRUST=0 CC_WT_SHARE="" CC_SEND_VERIFY_SEC=0.1 \
    CC_SEND_FAILLOG="$CGS/fail" bash "$CC/cc-dispatch.sh" surface "$CGDW" ) >/dev/null 2>&1
eq "surface mounts the gate"             "$(grep -c 'cc-stack:commit-gate' "$CGDR/.git/hooks/pre-commit" 2>/dev/null || echo 0)" "1"
cgb="$(cgn "$CGDW")"
( cd "$CGDW" && git commit -q --allow-empty -m x ) >/dev/null 2>&1
eq "and a dispatched worktree is gated"  "$(cgn "$CGDW")" "$cgb"
# a MAIN checkout handed to the public `surface` subcommand gets no hook it never asked for
CGT=$(mktemp -d); CGTR="$(cn "$CGT")"
( cd "$CGTR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i )
( cd "$CGDR" && env HOME="$FH25" PATH="$CGS:$OP25" CC_TASKS_FILE="$CC_TEST_SANDBOX/25-tasks.tsv" \
    CC_TABS_FILE="$CC_TEST_SANDBOX/25-tabs.tsv" CC_WT_PRETRUST=0 CC_WT_SHARE="" CC_SEND_VERIFY_SEC=0.1 \
    CC_SEND_FAILLOG="$CGS/fail" bash "$CC/cc-dispatch.sh" surface "$CGTR" ) >/dev/null 2>&1
eq "a plain main checkout is left alone" "$([ -e "$CGTR/.git/hooks/pre-commit" ] && echo present || echo gone)" "gone"
# and the workspace path (gwt-new / gwt-adopt) mounts it too
CGN=$(mktemp -d); CGNR="$(cn "$CGN")"
( cd "$CGNR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wn -b feat/wn >/dev/null )
( cd "$CGNR" && env HOME="$FH25" PATH="$CGS:$OP25" CC_TABS_FILE="$CC_TEST_SANDBOX/25-tabs.tsv" \
    bash "$CC/cc-dispatch.sh" workspace "$CGNR/.claude/worktrees/wn" wn false ) >/dev/null 2>&1
eq "workspace mounts the gate"           "$(grep -c 'cc-stack:commit-gate' "$CGNR/.git/hooks/pre-commit" 2>/dev/null || echo 0)" "1"

# — install.sh step 4b gates the INSTALL DIR, and nothing else it merely read files from —
# Regression, caught by this suite on 2026-08-16 during the migration itself: step 4b originally
# also mounted into LOCAL_SRC (the clone install.sh was launched from). Run from a cc-stack
# WORKTREE — which is what `bash test.sh` does — that arm resolved the worktree to its PARENT repo
# and wrote a pre-commit hook into the live cc-stack checkout, a repo nobody had named. An
# installer writes into the directory it was given; a source it only read files from is not a target.
CGI=$(mktemp -d); CGIH="$CGI/home"; CGID="$CGI/dest"; mkdir -p "$CGIH" "$CGID"
( cd "$CGID"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i )
CGISRC="$(cn "$CC")"                                   # the clone install.sh is launched FROM
CGIB="$( [ -e "$CGISRC/.git" ] && bash -c 'cd "$1" && git rev-parse --git-common-dir' _ "$CGISRC" 2>/dev/null )"
CGIB="$( [ -n "$CGIB" ] && cn "$CGIB" )"               # its shared .git — the thing that must stay untouched
CGIPRE="$([ -n "$CGIB" ] && [ -e "$CGIB/hooks/pre-commit" ] && echo present || echo gone)"
HOME="$CGIH" bash "$CC/install.sh" --yes --dir "$CGID" >/dev/null 2>&1
eq "install gates its own install dir"   "$(grep -c 'cc-stack:commit-gate' "$CGID/.git/hooks/pre-commit" 2>/dev/null || echo 0)" "1"
eq "install leaves the SOURCE repo alone" "$([ -n "$CGIB" ] && [ -e "$CGIB/hooks/pre-commit" ] && echo present || echo gone)" "$CGIPRE"
# the other end of the same accident: the copy must never carry the source's `.git`. In a linked
# worktree that is a FILE, so `! -path ./.git/*` alone never excluded it, and the install dir came
# out looking to git like a worktree of the source repo.
eq "install never copies the source .git" "$(git -C "$CGID" rev-parse --git-common-dir 2>/dev/null | grep -c 'cc-stack')" "0"
HOME="$CGIH" bash "$CC/install.sh" --yes --dir "$CGID" >/dev/null 2>&1
eq "re-install adds no second gate body" "$(grep -c 'cc-stack:commit-gate' "$CGID/.git/hooks/pre-commit")" "1"
# a dispatched worktree of THAT repo is really gated end to end, through the installed copy
( cd "$CGID" && mkdir -p .claude && git worktree add -q .claude/worktrees/wi -b feat/wi >/dev/null 2>&1 )
cgb="$(cgn "$CGID/.claude/worktrees/wi")"
( cd "$CGID/.claude/worktrees/wi" && git commit -q --allow-empty -m x ) >/dev/null 2>&1
eq "installed gate blocks for real"      "$(cgn "$CGID/.claude/worktrees/wi")" "$cgb"
# --dry-run changes nothing
CGJ=$(mktemp -d); CGJH="$CGJ/home"; CGJD="$CGJ/dest"; mkdir -p "$CGJH" "$CGJD"
( cd "$CGJD"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i )
HOME="$CGJH" bash "$CC/install.sh" --yes --dry-run --dir "$CGJD" >/dev/null 2>&1
eq "--dry-run mounts nothing"            "$([ -e "$CGJD/.git/hooks/pre-commit" ] && echo present || echo gone)" "gone"
( cd "$CGID" && git worktree remove --force .claude/worktrees/wi >/dev/null 2>&1 )

# surface leaves a contentless dedup marker in the real TMPDIR (hash-keyed) — sweep ours
rm -f "${TMPDIR:-/tmp}/cc-cmux-tabs/$(printf '%s' "$CGDW" | shasum -a 1 | cut -d' ' -f1)" \
      "${TMPDIR:-/tmp}/cc-cmux-tabs/$(printf '%s' "$CGTR" | shasum -a 1 | cut -d' ' -f1)" 2>/dev/null
rm -rf "$CG" "$CGP" "$CGH" "$CGF" "$CGS" "$FH25" "$CGD" "$CGT" "$CGN" "$CGI" "$CGJ"
unset CC_FAKE_LOG25 CF_SCREEN25

echo ""
echo "== 30. wtz-guards: gwt-rm destructive-path guards + gwt-tree cross-workspace liveness + CC_WT_COPY no-overwrite =="
# F1 (data-loss, 2026-08-21): `gwt-rm` fell back to `git worktree remove --force` on a dirty
# tree and deleted uncommitted work with NO confirmation — the exact opposite of the project's
# "never silently lose anything" line. The fallback is now earned: a refused remove prints the
# status and stops (rc 1, nothing cleaned) unless --force names the deletion. --force is THE one
# destructive switch: it also gates `git branch -D` (--branch now tries -d first — its success
# IS the merged-proof).
# F2: gwt-tree probed ONE workspace (the caller's) — a live sub-task in another workspace
# rendered ⌫closed. Same union fix cc-board.sh / the tabs prune got on 2026-08-16, and the same
# partial-evidence rule: a miss under an incomplete probe renders "?", never dead.
# F3: CC_WT_COPY overwrote a reused worktree's own .env etc. — cc-dispatch.sh's copy skips
# existing files; the zsh side now matches.
W30_CN(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
W30_T=$(mktemp -u); W30_S=$(mktemp -u); W30_TRUST=$(mktemp -u); : > "$W30_T"; : > "$W30_S"; : > "$W30_TRUST"
# every zsh -c below carries its OWN sandbox overrides (the suite's rule: never the live TSVs /
# ~/.claude.json) and disables CC_WT_SHARE so the real cc-worktree-shared.sh is never reached.
w30env(){ echo "CC_TASKS_FILE='$W30_T' CC_STATUS_FILE='$W30_S' CC_TRUST_CFG_OVERRIDE='$W30_TRUST' CC_WT_SHARE=''"; }

# ── F1: dirty worktree refused without --force ───────────────────────────────────────────────
W30_D=$(mktemp -d); W30_D="$(W30_CN "$W30_D")"
( cd "$W30_D"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/dirty -b feat/dirty >/dev/null )
W30_W="$W30_D/.claude/worktrees/dirty"
echo "uncommitted work" > "$W30_W/untracked.txt"
printf '2026-01-01 00:00:01\tfeat/dirty\tsurface:61\t%s\tsurface:1\tdirty row\tmain\n' "$W30_W" > "$W30_T"
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_D'; $(w30env) gwt-rm dirty" 2>&1)"; W30_RC=$?
eq "30 dirty tree: rc!=0"              "$([ "$W30_RC" -ne 0 ] && echo y || echo n)" "y"
eq "30 dirty tree: says uncommitted"   "$(echo "$W30_O" | grep -c 'uncommitted changes')" "1"
eq "30 dirty tree: lists the files"    "$(echo "$W30_O" | grep -c 'untracked.txt')" "1"
eq "30 dirty tree: worktree survives"  "$([ -d "$W30_W" ] && echo y || echo n)" "y"
eq "30 dirty tree: board row survives" "$(grep -c 'dirty row' "$W30_T")" "1"
eq "30 dirty tree: sidecar untouched"  "$([ -f "$W30_S" ] && echo y || echo n)" "y"
# --force names the deletion: worktree AND its uncommitted file fall, branch stays (no --branch)
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_D'; $(w30env) gwt-rm dirty --force" 2>&1)"; W30_RC=$?
eq "30 --force: rc=0"                  "$W30_RC" "0"
eq "30 --force: worktree gone"         "$([ -d "$W30_W" ] && echo y || echo n)" "n"
eq "30 --force: branch kept (no --branch)" "$(git -C "$W30_D" branch --list 'feat/dirty' | wc -l | tr -d ' ')" "1"
# cat-first: a successful gwt-rm may leave the TSV deleted (_gwt_drop_lines removes an emptied file)
eq "30 --force: board row dropped"     "$(cat "$W30_T" 2>/dev/null | grep -c 'dirty row')" "0"

# ── F1: unmerged branch survives --branch unless --force ─────────────────────────────────────
W30_DB=$(mktemp -d); W30_DB="$(W30_CN "$W30_DB")"
( cd "$W30_DB"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/um -b feat/um >/dev/null )
( cd "$W30_DB/.claude/worktrees/um"; echo x > f.txt; git add f.txt; git commit -q -m "unmerged work" )
git -C "$W30_DB" config branch.feat/um.ccMergeInto main
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_DB'; $(w30env) gwt-rm um --branch" 2>&1)"; W30_RC=$?
eq "30 unmerged branch: kept"          "$(git -C "$W30_DB" branch --list 'feat/um' | wc -l | tr -d ' ')" "1"
eq "30 unmerged branch: says not merged" "$(echo "$W30_O" | grep -c 'not merged')" "1"
eq "30 unmerged branch: names --force" "$(echo "$W30_O" | grep -c -- '--force')" "1"
eq "30 unmerged branch: merge target kept" "$(git -C "$W30_DB" config --get branch.feat/um.ccMergeInto)" "main"
eq "30 unmerged branch: worktree went (clean tree)" "$([ -d "$W30_DB/.claude/worktrees/um" ] && echo y || echo n)" "n"
# --branch --force is what drops the unmerged commits — SEPARATE repo: the one above already
# removed its worktree, so a second gwt-rm there would only hit the "no worktree named" path
W30_DB2=$(mktemp -d); W30_DB2="$(W30_CN "$W30_DB2")"
( cd "$W30_DB2"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/um2 -b feat/um2 >/dev/null )
( cd "$W30_DB2/.claude/worktrees/um2"; echo x > f.txt; git add f.txt; git commit -q -m "unmerged work" )
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_DB2'; $(w30env) gwt-rm um2 --branch --force" 2>&1)"; W30_RC=$?
eq "30 --branch --force: branch gone"  "$(git -C "$W30_DB2" branch --list 'feat/um2' | wc -l | tr -d ' ')" "0"
eq "30 --branch --force: worktree gone" "$([ -d "$W30_DB2/.claude/worktrees/um2" ] && echo y || echo n)" "n"
eq "30 --branch --force: says dropped" "$(echo "$W30_O" | grep -c 'unmerged commits dropped')" "1"
# ...and a MERGED branch goes with plain --branch — "merged" judged against the RECORDED target
# (ancestry here; the squash/Child-Tip path has its own scenario below), never via branch -d
W30_D2=$(mktemp -d); W30_D2="$(W30_CN "$W30_D2")"
( cd "$W30_D2"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/mg -b feat/mg >/dev/null; git merge -q feat/mg >/dev/null 2>&1
  git config branch.feat/mg.ccMergeInto main )
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_D2'; $(w30env) gwt-rm mg --branch" 2>&1)"; W30_RC=$?
eq "30 merged branch: judged+deleted"  "$([ "$W30_RC" -eq 0 ] && echo y || echo n)" "y"
eq "30 merged branch: deleted"         "$(git -C "$W30_D2" branch --list 'feat/mg' | wc -l | tr -d ' ')" "0"
eq "30 merged branch: says merged into" "$(echo "$W30_O" | grep -c 'merged into main')" "1"
eq "30 merged branch: target config gone" "$(git -C "$W30_D2" config --get branch.feat/mg.ccMergeInto)" ""

# ── F2: gwt-tree liveness across ALL workspaces (fake cmux, §26-style) ────────────────────────
W30_WS=$(mktemp -d)
cat > "$W30_WS/cmux" <<'CMUX30'
#!/usr/bin/env bash
# two workspaces; the UNSCOPED list-pane-surfaces answers workspace:1 alone (what the real CLI
# does under $CMUX_WORKSPACE_ID). The SELECTED row carries the leading '*' the real cmux prints
# (every other fake cmux in this suite does too). CC_FAKE_WSDOWN=<ref> makes that workspace
# unreachable (rc 1).
w=""; prev=""
for a in "$@"; do case "$prev" in --workspace) w="$a" ;; esac; prev="$a"; done
cmd="$1"; shift
case "$cmd" in
  ping) exit 0 ;;
  list-workspaces)
    printf '* workspace:1  alpha  [selected]\n'
    printf '  workspace:2  beta\n' ;;
  list-pane-surfaces)
    [ -n "$w" ] || w=workspace:1
    [ "$w" = "${CC_FAKE_WSDOWN:-}" ] && exit 1
    case "$w" in
      workspace:1) printf '* surface:3\t33333333-3333-3333-3333-333333333333\tchild D (selected)\n'
                    printf '  surface:101\t11111111-1111-1111-1111-111111111111\tchild A\n' ;;
      workspace:2) printf '  surface:202\t22222222-2222-2222-2222-222222222222\tchild B elsewhere\n' ;;
    esac ;;
esac
exit 0
CMUX30
chmod +x "$W30_WS/cmux"
W30_R=$(mktemp -d); W30_R="$(W30_CN "$W30_R")"
( cd "$W30_R"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude
  git worktree add -q .claude/worktrees/wtA -b feat/w30A >/dev/null
  git worktree add -q .claude/worktrees/wtB -b feat/w30B >/dev/null
  git worktree add -q .claude/worktrees/wtC -b feat/w30C >/dev/null
  git worktree add -q .claude/worktrees/wtD -b feat/w30D >/dev/null )
W30_TT=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/w30A\tsurface:101\t%s\tsurface:1\ttask A\tmain\n' "$W30_R/.claude/worktrees/wtA" > "$W30_TT"
printf '2026-01-01 00:00:02\tfeat/w30B\tsurface:202\t%s\tsurface:1\ttask B\tmain\n' "$W30_R/.claude/worktrees/wtB" >> "$W30_TT"
printf '2026-01-01 00:00:03\tfeat/w30C\tsurface:10\t%s\tsurface:1\ttask C\tmain\n' "$W30_R/.claude/worktrees/wtC" >> "$W30_TT"
printf '2026-01-01 00:00:04\tfeat/w30D\tsurface:3\t%s\tsurface:1\ttask D\tmain\n' "$W30_R/.claude/worktrees/wtD" >> "$W30_TT"
w30tree(){ ( cd "$W30_R" && PATH="$W30_WS:$PATH" CC_FAKE_WSDOWN="${1:-}" CC_TASKS_FILE="$W30_TT" \
    zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-tree" ) 2>/dev/null; }
W30_TO="$(w30tree)"
eq "30 tree: caller-workspace tab live"   "$(echo "$W30_TO" | grep -c 'feat/w30A.*✔live')" "1"
eq "30 tree: OTHER-workspace tab live"    "$(echo "$W30_TO" | grep -c 'feat/w30B.*✔live')" "1"
eq "30 tree: no false ⌫closed"            "$(echo "$W30_TO" | grep -c 'feat/w30B.*⌫closed')" "0"
# the SELECTED row carries a leading '*' in real cmux output — it must still match its ref
eq "30 tree: selected '*' row still live" "$(echo "$W30_TO" | grep -c 'feat/w30D.*✔live')" "1"
# exact-field match: surface:10 must NOT ride on surface:101's substring — a closed tab is closed
eq "30 tree: substring not a match"       "$(echo "$W30_TO" | grep -c 'feat/w30C.*⌫closed')" "1"
eq "30 tree: closed ≠ live"               "$(echo "$W30_TO" | grep -c 'feat/w30C.*✔live')" "0"
eq "30 tree: no footnote when full"       "$(echo "$W30_TO" | grep -c 'enumeration was incomplete')" "0"
# partial probe (workspace:2 unreachable): the miss renders "?" — unknown, NOT dead
W30_TO="$(w30tree workspace:2)"
eq "30 tree: partial miss renders ?"      "$(echo "$W30_TO" | grep -c 'feat/w30B.*\[?\]')" "1"
eq "30 tree: partial miss not ⌫closed"    "$(echo "$W30_TO" | grep -c 'feat/w30B.*⌫closed')" "0"
eq "30 tree: partial still sees its own"  "$(echo "$W30_TO" | grep -c 'feat/w30A.*✔live')" "1"
eq "30 tree: partial footnote printed"    "$(echo "$W30_TO" | grep -c 'enumeration was incomplete')" "1"

# ── F3: CC_WT_COPY never overwrites a file the worktree already has ──────────────────────────
# tracked-.env construction: HEAD carries .env ("committed"); the ROOT working tree drifts to a
# newer "root snapshot" afterwards. A fresh bootstrap checks out HEAD into the worktree — the
# buggy code then clobbered that checkout with the root's newer snapshot (and a REUSED worktree's
# own edits fared the same); the fixed code skips, like cc-dispatch.sh's surface copy does.
W30_F=$(mktemp -d); W30_F="$(W30_CN "$W30_F")"
( cd "$W30_F"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  echo "committed" > .env; git add .env; git commit -q -m "track .env"
  mkdir -p .claude )
echo "root snapshot" > "$W30_F/.env"
echo "absent file still gets copied" > "$W30_F/.env2"
W30_BO="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; $(w30env) CC_WT_COPY='.env .env2' _gwt_bootstrap_wt '$W30_F' '$W30_F/.claude/worktrees/reuse' feat/reuse" 2>&1)"
eq "30 copy: checkout's .env kept"        "$(cat "$W30_F/.claude/worktrees/reuse/.env" 2>/dev/null)" "committed"
eq "30 copy: absent file copied"          "$(cat "$W30_F/.claude/worktrees/reuse/.env2" 2>/dev/null)" "absent file still gets copied"
eq "30 copy: kept line printed"           "$(printf '%s' "$W30_BO" | grep -c "kept worktree's own .env")" "1"

# ── gate round (2026-08-22): refusal must be fail-closed, a kept branch keeps its metadata,
# squash merges count, liveness matches exactly, collect runs after the guard, empty share OK ──
# submodule trees: an UNPOPULATED gitlink (worktree add never populates submodules) is removed
# fine by git itself — the pre-flight must not be stricter than git and block it. Only a
# POPULATED submodule makes remove refuse, and that refusal is handled by the stderr path.
W30_G1=$(mktemp -d); W30_G1="$(W30_CN "$W30_G1")"
( cd "$W30_G1"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir sub && ( cd sub; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m s )
  git update-index --add --cacheinfo 160000,"$(git -C sub rev-parse HEAD)",vendored
  git commit -q -m gitlink
  mkdir -p .claude; git worktree add -q .claude/worktrees/sub -b feat/sub >/dev/null )
W30_GW="$W30_G1/.claude/worktrees/sub"
eq "30 submod premise: status reads empty" "$(git -C "$W30_GW" status --short 2>/dev/null)" ""
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_G1'; $(w30env) gwt-rm sub" 2>&1)"; W30_RC=$?
eq "30 unpop. gitlink: removed fine"      "$([ "$W30_RC" -eq 0 ] && echo y || echo n)" "y"
eq "30 unpop. gitlink: worktree gone"     "$([ -d "$W30_GW" ] && echo y || echo n)" "n"
# populated submodule: git itself refuses — its stderr shows, rc 1, nothing deleted
W30_G1B=$(mktemp -d); W30_G1B="$(W30_CN "$W30_G1B")"
( cd "$W30_G1B"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir sub && ( cd sub; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m s )
  mkdir -p .claude; git worktree add -q .claude/worktrees/pop -b feat/pop >/dev/null )
( cd "$W30_G1B/.claude/worktrees/pop"; git -c protocol.file.allow=always submodule add -q "$W30_G1B/sub" vendored
  git add .gitmodules vendored; git commit -q -m sub )
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_G1B'; $(w30env) gwt-rm pop" 2>&1)"; W30_RC=$?
eq "30 pop. submod: rc!=0"                "$([ "$W30_RC" -ne 0 ] && echo y || echo n)" "y"
eq "30 pop. submod: worktree survives"    "$([ -d "$W30_G1B/.claude/worktrees/pop" ] && echo y || echo n)" "y"
eq "30 pop. submod: git's stderr shown"   "$(echo "$W30_O" | grep -c 'submodule')" "1"

# squash merge: no ancestry in the target, but do-merge stamps the child tip into the squash
# commit — that trailer counts as the merge proof
W30_SQ=$(mktemp -d); W30_SQ="$(W30_CN "$W30_SQ")"
( cd "$W30_SQ"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/sq -b feat/sq >/dev/null )
( cd "$W30_SQ/.claude/worktrees/sq"; echo y > g.txt; git add g.txt; git commit -q -m "child work" )
W30_SQTIP="$(git -C "$W30_SQ/.claude/worktrees/sq" rev-parse HEAD)"
( cd "$W30_SQ"; git config branch.feat/sq.ccMergeInto main
  git merge -q --squash feat/sq >/dev/null 2>&1; git commit -q -m "chore: merge feat/sq into main" -m "Child-Tip: $W30_SQTIP" )
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_SQ'; $(w30env) gwt-rm sq --branch" 2>&1)"; W30_RC=$?
eq "30 squash: rc=0 (judged merged)"      "$W30_RC" "0"
eq "30 squash: branch deleted"            "$(git -C "$W30_SQ" branch --list 'feat/sq' | wc -l | tr -d ' ')" "0"
eq "30 squash: says merged into"          "$(echo "$W30_O" | grep -c 'merged into main')" "1"

# a REFUSED rm must leave the root untouched too — the corpus collect runs after the guard
W30_G5=$(mktemp -d); W30_G5="$(W30_CN "$W30_G5")"
( cd "$W30_G5"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/share -b feat/share >/dev/null )
mkdir -p "$W30_G5/e2e" "$W30_G5/.claude/worktrees/share/e2e"
echo "old corpus" > "$W30_G5/e2e/old.spec.ts"
echo "new corpus" > "$W30_G5/.claude/worktrees/share/e2e/new.spec.ts"
echo "uncommitted" > "$W30_G5/.claude/worktrees/share/dirty.txt"
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_G5'; $(w30env) CC_WT_SHARE='e2e' gwt-rm share" 2>&1)"; W30_RC=$?
eq "30 collect: refused rc!=0"            "$([ "$W30_RC" -ne 0 ] && echo y || echo n)" "y"
eq "30 collect: root untouched"           "$([ -e "$W30_G5/e2e/new.spec.ts" ] && echo y || echo n)" "n"
eq "30 collect: worktree survives"        "$([ -d "$W30_G5/.claude/worktrees/share" ] && echo y || echo n)" "y"

# LOCKED clean worktree: the status/submodule probes read clean, so without a lock check the
# collect would run FIRST and only then would remove refuse — a refused rm must leave the root
# with zero new files. Corpus file is COMMITTED so the tree is genuinely clean.
W30_LK=$(mktemp -d); W30_LK="$(W30_CN "$W30_LK")"
( cd "$W30_LK"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/lk -b feat/lk >/dev/null )
mkdir -p "$W30_LK/e2e"
echo "old corpus" > "$W30_LK/e2e/old.spec.ts"
( cd "$W30_LK/.claude/worktrees/lk"; mkdir e2e; echo "new corpus" > e2e/new.spec.ts; git add e2e; git commit -q -m corpus )
git -C "$W30_LK" worktree lock "$W30_LK/.claude/worktrees/lk"
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_LK'; $(w30env) CC_WT_SHARE='e2e' gwt-rm lk" 2>&1)"; W30_RC=$?
eq "30 locked: rc!=0"                     "$([ "$W30_RC" -ne 0 ] && echo y || echo n)" "y"
eq "30 locked: root share zero new"       "$([ -e "$W30_LK/e2e/new.spec.ts" ] && echo y || echo n)" "n"
eq "30 locked: worktree survives"         "$([ -d "$W30_LK/.claude/worktrees/lk" ] && echo y || echo n)" "y"
eq "30 locked: says locked"               "$(echo "$W30_O" | grep -c 'locked')" "1"

# CC_WT_SHARE exported-empty is a SUPPORTED off switch (README) — gwt-new must still finish:
# record the merge target, open the workspace (a no-op without cmux), cd. The old one-liner
# tail left rc=1 right after building the worktree, skipping all of that.
W30_G8=$(mktemp -d); W30_G8="$(W30_CN "$W30_G8")"
( cd "$W30_G8"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude/worktrees )   # pick the .claude/worktrees convention, like every repo above
# PATH carries the fake cmux (§26 pattern): gwt-new reaches cc-dispatch.sh workspace, which
# only checks `command -v cmux` + ping — unshimmed it opened a REAL workspace and stole focus
# (2026-08-22: eleven leaked workspaces had to be closed by hand)
W30_O="$(cd "$W30_G8" && PATH="$W30_WS:$PATH" zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; $(w30env) CC_WT_SHARE='' gwt-new nx" 2>&1)"; W30_RC=$?
eq "30 gwt-new: rc=0 with empty share"    "$W30_RC" "0"
eq "30 gwt-new: worktree built"           "$([ -d "$W30_G8/.claude/worktrees/nx" ] && echo y || echo n)" "y"
eq "30 gwt-new: target recorded"          "$(git -C "$W30_G8" config --get branch.feat/nx.ccMergeInto)" "main"

# gwt-rm run from INSIDE the worktree it removes (gwt-new cd's you there): the root must be
# resolved BEFORE the removal — afterwards every bare git runs in a dead cwd and a MERGED
# branch reads as "not merged" (gate 5)
W30_SL=$(mktemp -d); W30_SL="$(W30_CN "$W30_SL")"
( cd "$W30_SL"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/sl -b feat/sl >/dev/null )
( cd "$W30_SL/.claude/worktrees/sl"; echo z > s.txt; git add s.txt; git commit -q -m "sl work" )
W30_SLTIP="$(git -C "$W30_SL/.claude/worktrees/sl" rev-parse HEAD)"
( cd "$W30_SL"; git merge -q --squash feat/sl >/dev/null 2>&1; git commit -q -m "chore: merge" -m "Child-Tip: $W30_SLTIP"
  git config branch.feat/sl.ccMergeInto main )
W30_O="$(cd "$W30_SL/.claude/worktrees/sl" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; $(w30env) gwt-rm sl --branch" 2>&1)"; W30_RC=$?
eq "30 self-rm: rc=0"                     "$W30_RC" "0"
eq "30 self-rm: judged merged"            "$(echo "$W30_O" | grep -c 'merged into main')" "1"
eq "30 self-rm: branch deleted"           "$(git -C "$W30_SL" branch --list 'feat/sl' | wc -l | tr -d ' ')" "0"

# recorded target deleted by the README's own gwt-merge <parent>; gwt-rm <parent> --branch
# sequence: fall back to the trunk — the merged child must still be judged merged (gate 6)
W30_TD=$(mktemp -d); W30_TD="$(W30_CN "$W30_TD")"
( cd "$W30_TD"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/td -b feat/td >/dev/null )
( cd "$W30_TD/.claude/worktrees/td"; echo w > t.txt; git add t.txt; git commit -q -m "td work" )
( cd "$W30_TD"; git branch gone; git merge -q feat/td >/dev/null 2>&1; git config branch.feat/td.ccMergeInto gone; git branch -D gone >/dev/null 2>&1 )
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_TD'; $(w30env) gwt-rm td --branch" 2>&1)"; W30_RC=$?
eq "30 target-gone: rc=0 judged merged"   "$W30_RC" "0"
eq "30 target-gone: merged into trunk"    "$(echo "$W30_O" | grep -c 'merged into main')" "1"
eq "30 target-gone: branch deleted"       "$(git -C "$W30_TD" branch --list 'feat/td' | wc -l | tr -d ' ')" "0"

# reclaim path on a name whose fallback branch never existed (dir name ≠ branch name): the
# stale merge record under the fallback name must be cleared, not left forever (gate 7)
W30_J=$(mktemp -d); W30_J="$(W30_CN "$W30_J")"
( cd "$W30_J"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  git branch feat/real
  mkdir -p .claude; git worktree add -q .claude/worktrees/gn feat/real >/dev/null
  git config branch.feat/gn.ccMergeInto main    # stale record under the FALLBACK name
  rm -rf .claude/worktrees/gn )                  # directory gone; registration stays (reclaim)
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_J'; $(w30env) gwt-rm gn --branch" 2>&1)"; W30_RC=$?
eq "30 reclaim-gone: rc=0"                "$W30_RC" "0"
eq "30 reclaim-gone: merge record cleared" "$(git -C "$W30_J" config --get branch.feat/gn.ccMergeInto)" ""
eq "30 reclaim-gone: says already gone"   "$(echo "$W30_O" | grep -c 'clearing its merge record')" "1"

# bootstrap with CC_WT_SHARE on: seeding is best-effort — even a seed command that CANNOT RUN
# (HOME pointed at an empty dir, so the hard-coded ~/.config/cc-stack path is unreachable and
# the seed call lands rc 127) must not fail the finished bootstrap. On the base build the
# seed's rc leaked out through the function tail.
W30_KH=$(mktemp -d)
W30_K=$(mktemp -d); W30_K="$(W30_CN "$W30_K")"
( cd "$W30_K"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude/worktrees )
HOME="$W30_KH" zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; $(w30env) CC_WT_SHARE='e2e' _gwt_bootstrap_wt '$W30_K' '$W30_K/.claude/worktrees/seed' feat/seed" >/dev/null 2>&1
eq "30 seed-on: bootstrap rc=0"           "$?" "0"
rm -rf "$W30_KH"

rm -rf "$W30_D" "$W30_DB" "$W30_DB2" "$W30_D2" "$W30_R" "$W30_F" "$W30_WS" "$W30_G1" "$W30_G1B" "$W30_SQ" "$W30_G5" "$W30_LK" "$W30_G8" "$W30_SL" "$W30_TD" "$W30_J" "$W30_K" "$W30_T" "$W30_S" "$W30_TRUST" "$W30_TT"

echo ""
echo "== 19. gwt-done as a standalone command (no zsh, no sourcing) =="
# Incident 2026-08-16: a sub-task ran `gwt-done` from its non-interactive Bash and got
# "_gwt_root: command not found" — a zsh function does not exist in a shell that never sourced
# worktree.zsh, so whether the command worked was luck. The command is now a FILE.
GD=$(mktemp -d); GDR="$(CDPATH= cd -- "$GD" && pwd -P)"
( cd "$GDR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wtG -b feat/G >/dev/null )
GDW="$GDR/.claude/worktrees/wtG"
eq "gwt-done ships as an executable file" "$([ -x "$CC/gwt-done" ] && echo yes || echo no)" "yes"
eq "gwt-done has no zsh in it" "$(grep -c 'emulate -L zsh' "$CC/gwt-done")" "0"
# the LC scenario, both shells, WITHOUT sourcing anything
GO="$(cd "$GDW" && bash "$CC/gwt-done" 2>&1)"
eq "bash, unsourced: marks ready"  "$GO" "✔ feat/G marked ready (gwt-done)"
eq "bash, unsourced: flag landed"  "$(bash "$CC/cc-merge.sh" is-done "$GDR" feat/G >/dev/null 2>&1; echo $?)" "0"
GO="$(cd "$GDW" && bash "$CC/gwt-done" --undone 2>&1)"
eq "--undone clears the flag"      "$(bash "$CC/cc-merge.sh" is-done "$GDR" feat/G >/dev/null 2>&1; echo $?)" "1"
GO="$(zsh -c "cd '$GDW'; '$CC/gwt-done'" 2>&1)"
eq "zsh, unsourced: marks ready"   "$GO" "✔ feat/G marked ready (gwt-done)"
eq "zsh, unsourced: no _gwt_root"  "$(printf '%s' "$GO" | grep -c '_gwt_root')" "0"
# the interactive sugar still works and now delegates to the same file
bash "$CC/cc-merge.sh" done "$GDR" feat/G false >/dev/null 2>&1
GO="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$GDW'; gwt-done" 2>&1)"
eq "zsh function still works"      "$GO" "✔ feat/G marked ready (gwt-done)"
GO="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$GDW'; gwt-undone" 2>&1)"
eq "gwt-undone function works"     "$GO" "✔ feat/G marked not-ready"
# outside a repo it fails loudly instead of half-working
eq "outside a repo: loud failure"  "$( ( cd /tmp && bash "$CC/gwt-done" >/dev/null 2>&1; echo $? ) )" "1"
# and every dispatch teaches the deterministic form
W4="$(grep -F '(4) When you finish implementing' "$CC/cc-dispatch.sh" | head -1)"
eq "clause 4 teaches the absolute path" "$(printf '%s' "$W4" | grep -c '~/.config/cc-stack/gwt-done')" "1"
eq "clause 4 warns the bare name is zsh-only" "$(printf '%s' "$W4" | grep -c 'zsh function')" "1"
rm -rf "$GD"
echo ""
echo "== 19b. fail-closed path guards (partial-shell incident 2026-08-16) =="
# Real incident: a partially-loaded shell had gwt-rm but not _gwt_dir → wtpath="/<name>" (fs ROOT)
# fed to `git worktree remove`. Every _gwt_dir-built path must now fail closed via _gwt_wt_path.
GT2=$(mktemp -d); GT2="$(cd "$GT2" && pwd -P)"; ( cd "$GT2"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/wtguard -b feat/guard >/dev/null )
gsrc(){ zsh -c '
  source "'"$CC"'/worktree.zsh" >/dev/null 2>&1
  unfunction _gwt_dir _gwt_root 2>/dev/null          # simulate the partially-loaded shell
  cd "'"$GT2"'"; gwt-rm wtguard' 2>&1; }
grc="$(gsrc)"; grc_rc=$?
eq "gwt-rm partial-shell exit!=0" "$([ "$grc_rc" -ne 0 ] && echo y || echo n)" "y"
eq "gwt-rm partial-shell says why" "$(echo "$grc" | grep -c 'source ~/.config/cc-stack/worktree.zsh')" "1"
eq "gwt-rm partial-shell touches NOTHING" "$(git -C "$GT2" worktree list --porcelain | grep -c wtguard)" "1"   # worktree still there
gout="$(zsh -c '
  source "'"$CC"'/worktree.zsh" >/dev/null 2>&1
  unfunction _gwt_dir 2>/dev/null
  cd "'"$GT2"'"; gwt-new newguard' 2>&1)"; grc2=$?
eq "gwt-new partial-shell exit!=0" "$([ "$grc2" -ne 0 ] && echo y || echo n)" "y"
eq "gwt-new partial-shell creates nothing" "$(git -C "$GT2" branch --list 'feat/newguard' | wc -l | tr -d ' ')" "0"
eq "_gwt_wt_path healthy echoes dir/name" "$(zsh -c 'source "'"$CC"'/worktree.zsh" >/dev/null 2>&1; cd "'"$GT2"'"; _gwt_wt_path foo' 2>/dev/null)" "$GT2/.claude/worktrees/foo"
# This one runs gwt-rm for real, i.e. through _gwt_tasks_drop_dir / _gwt_status_drop_dir /
# cc-trust.sh --remove. Unisolated it rewrote the human's live TSVs on every suite run (proved by
# their mtime moving) and reached into the live ~/.claude.json. The sandbox at the top of this
# file already covers it; the explicit prefix keeps the call site self-documenting, matching the
# other gwt-rm tests (§2b, §12).
env CC_TASKS_FILE="$CC_TEST_SANDBOX/19b-tasks.tsv" CC_STATUS_FILE="$CC_TEST_SANDBOX/19b-status.tsv" \
  CC_TRUST_CFG_OVERRIDE="$CC_TEST_SANDBOX/19b-claude.json" \
  zsh -c 'source "'"$CC"'/worktree.zsh" >/dev/null 2>&1; cd "'"$GT2"'"; gwt-rm wtguard --branch' >/dev/null 2>&1
eq "gwt-rm healthy path still works" "$(git -C "$GT2" worktree list --porcelain | grep -c wtguard)" "0"
rm -rf "$GT2"

echo "== syntax =="
for s in "$CC"/*.sh "$CC"/hooks/*.sh; do bash -n "$s" && : || { echo "  ✗ syntax $s"; fail=$((fail+1)); }; done
zsh -n "$CC/worktree.zsh" && ok "worktree.zsh syntax" || { no "worktree.zsh syntax" x x; }

echo ""
echo "== 10. zsh commands present =="
for fn in gwt-tree gwt-done gwt-undone gwt-merge gwt-collect gwt-adopt gwt-log gwt-resume gwt-tabs; do
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
grep -q "gwt-tabs" "$CC/worktree.zsh" && grep -q "gwt-tabs" "$CC/README.md" \
  && ok "gwt-tabs documented" || no "gwt-tabs documented" missing present
grep -q "opened-tabs.tsv" "$CC/README.md" && grep -q "CC_TABS_FILE" "$CC/README.md" \
  && ok "opened-tabs ledger documented" || no "opened-tabs ledger documented" missing present
grep -qxF "opened-tabs.tsv" "$CC/.gitignore" \
  && ok "opened-tabs.tsv gitignored" || no "opened-tabs.tsv gitignored" missing present
grep -q "hooks/git-pre-commit.sh" "$CC/README.md" && grep -q "commit-authorized" "$CC/README.md" \
  && ok "commit gate documented" || no "commit gate documented" missing present
grep -q "no-verify" "$CC/README.md" \
  && ok "the accepted --no-verify residue is documented" || no "the accepted --no-verify residue is documented" missing present

echo ""
echo "== 24. live-state isolation (the suite must not write the human's real files) =="
# The recurrence guard for a defect that has now landed three times: leaked cmux workspaces
# (2026-08-16), then §19b rewriting the live TSVs, then whatever comes next. Snapshot taken at the
# top of this file; anything that reached a live path shows up here instead of in the human's data.
# a filtering rewrite that empties a ledger DELETES it — the loudest outcome of a missing override
eq "no live ledger vanished" "$(_cc_live_exist)" "$CC_LIVE_EXIST_BEFORE"
# nothing that was on a live ledger may be gone: outside traffic only adds/updates rows, a leaked
# _gwt_*_drop_dir / _gwt_archive_branch drops them
_cc_live_keys_sorted > "$CC_TEST_SANDBOX/live-keys.after"
_cc_trust_keys       > "$CC_TEST_SANDBOX/trust-keys.after"
eq "no live ledger row dropped" \
  "$(comm -23 "$CC_TEST_SANDBOX/live-keys.before" "$CC_TEST_SANDBOX/live-keys.after" | wc -l | tr -d ' ')" "0"
eq "no live trust entry dropped" \
  "$(comm -23 "$CC_TEST_SANDBOX/trust-keys.before" "$CC_TEST_SANDBOX/trust-keys.after" | wc -l | tr -d ' ')" "0"
# and no fixture of this suite may have been registered on a live ledger
eq "no fixture path reached a live ledger" "$(_cc_live_tmp_rows)" "$CC_LIVE_TMPROWS_BEFORE"
eq "live hook registrations unchanged"     "$(_cc_settings_hooks)" "$CC_LIVE_HOOKS_BEFORE"
# an interrupted rewrite leaves its mkdir lock behind; every later real write then stalls ~3s
eq "no stale lock on a live ledger" \
  "$(ls -d "$CC_LIVE_DIR"/worktree-tasks.tsv.lock "$CC_LIVE_DIR"/worktree-status.tsv.lock \
       "$CC_LIVE_DIR"/worktree-tasks-archive.tsv.lock "$CC_LIVE_DIR"/opened-tabs.tsv.lock 2>/dev/null | wc -l | tr -d ' ')" "0"
# layer 1's own integrity: a section that unsets an override instead of re-pointing it silently
# hands the NEXT section the live default path — that is precisely how §19b leaked
eq "ledger overrides still sandboxed" "$(_cc_overrides_escaped)" "0"
# sha/mtime are diagnostics, not assertions: a board read prunes-on-read and any live agent's
# status hook rewrites these files, so a change here is not attributable to this suite
if [ "$(_cc_live_files)" != "$CC_LIVE_FILES_BEFORE" ]; then
  echo "  · note: a live ledger changed during the run (outside traffic is expected here):"
  diff <(printf '%s\n' "$CC_LIVE_FILES_BEFORE") <(printf '%s\n' "$(_cc_live_files)") | sed 's/^/      /'
fi
rm -rf "$CC_TEST_SANDBOX"

echo ""
echo "result: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
