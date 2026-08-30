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
#   1. SANDBOX — the library path and the trust-store override are exported here, so a call
#      site that forgets an override lands in a temp dir instead of the live file. Sections that
#      used to `unset` these now call cc_sandbox_ledgers to return to the sandbox, never to the
#      live default path. Phase D collapsed this to ONE ledger variable (spec §8 invariant 9):
#      the four CC_*_FILE overrides are retired and a legacy TSV is found beside CC_STATE_DB.
#      That is the stronger form of layer 1 — "half the overrides set" was not a habit failure
#      but a representable state, and it once migrated the live ledgers into a scratch library.
#   2. TAIL ASSERTION (§24) — the live files are snapshotted now and re-checked at the end.
#      What it can assert is constrained by churn: a board read prunes-on-read (rewriting
#      worktree-tasks.tsv) and any live agent's status hook rewrites worktree-status.tsv, so
#      neither sha nor mtime is attributable to this suite. The oracles that ARE attributable:
#      nothing pre-existing may DISAPPEAR (rows, files, trust entries), no fixture path may
#      appear, no lock may be left behind, and the overrides must still be sandboxed at the end.
CC_TEST_SANDBOX="$(mktemp -d)"
cc_sandbox_ledgers(){
  export CC_TRUST_CFG_OVERRIDE="$CC_TEST_SANDBOX/claude.json"
  # The engine's library — and, since phase D, the ONLY thing a caller points anywhere. The
  # legacy TSVs are wherever the library is, so pointing the library moves the whole store set
  # at once and a section can no longer set half of it.
  export CC_STATE_DB="$CC_TEST_SANDBOX/cc-state.db"
  rm -f "$CC_TEST_SANDBOX/worktree-tasks.tsv" "$CC_TEST_SANDBOX/worktree-status.tsv" \
        "$CC_TEST_SANDBOX/worktree-tasks-archive.tsv" "$CC_TEST_SANDBOX/opened-tabs.tsv" \
        "$CC_STATE_DB" "$CC_STATE_DB-wal" "$CC_STATE_DB-shm"
  printf '{"projects":{}}\n' > "$CC_TRUST_CFG_OVERRIDE"
}
cc_sandbox_ledgers
# ── Fixture seeding through the facade ────────────────────────────────────────────────────────
# The fixtures in this suite are RAW BYTES on purpose, and that is not laziness: a 7-field legacy
# row, an empty middle field, a lone non-UTF-8 byte, a row no verb would ever compose are
# expressible as bytes and in no other way. They used to be `printf > "$tasks_tsv"`, which
# hardwired every one of them to "a store is a file I can redirect into". `cc-state load` is the
# byte-level write half of the dump/load pair, so a fixture keeps exactly the control it had
# while the suite stops naming the backend — the same move Task 1 made for the callers.
#   st_seed   <store> [<db>]   stdin REPLACES the store   (the old `> "$tasks_tsv"`)
#   st_append <store> [<db>]   stdin is appended to it    (the old `>> "$tasks_tsv"`)
#   st_dump   <store> [<db>]   the store's raw bytes      (the old `cat "$tasks_tsv"`)
# Reads go the other way: `"$CC/cc-state" dump <store>` in place of cat/awk/grep on the file.
# dump is the RAW passthrough — a filtered verb (task-list) would hide dead/duplicate rows at
# read time and make every "the sweep really happened" assertion vacuously green.
#
# The optional second argument is the LIBRARY, not the store file. That is the engine swap
# showing through: a store used to be identified by its own file, so a section isolated itself
# by re-pointing four paths; now all four stores live in one library and the library path is
# what identifies a store set. Sections that export CC_STATE_DB once can omit it entirely; the
# ones that juggle several store sets (§29, §37) name the library per call. It is applied
# inside a subshell because in bash a `VAR=x func` prefix leaks VAR into the caller after the
# function returns, unlike the same prefix on a command.
_st_db(){ [ -n "${1:-}" ] && export CC_STATE_DB="$1"; return 0; }
st_seed(){ ( _st_db "${2:-}"; "$CC/cc-state" load "$1" - ); }
st_append(){ ( _st_db "${2:-}"; { "$CC/cc-state" dump "$1"; cat; } | "$CC/cc-state" load "$1" - ); }
st_dump(){ ( _st_db "${2:-}"; "$CC/cc-state" dump "$1" ); }
# D 期：tab-open 去重时间戳是 tasks 上的一列,不再是 $TMPDIR 里以 dir 的 sha1 命名的标记文件。
# 测试里「让同一 dir 在 120s 内还能再派一次」于是从「删掉标记」变成「清掉那一列」。
unstamp(){ python3 -c 'import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1]); c.execute("UPDATE tasks SET tab_opened_ts=NULL"); c.commit()
except Exception:
    pass' "$1" 2>/dev/null; return 0; }
CC_LIVE_DIR="$HOME/.config/cc-stack"
CC_LIVE_LEDGERS="worktree-tasks.tsv worktree-status.tsv worktree-tasks-archive.tsv opened-tabs.tsv cc-state.db"
# WAL sidecars are DIAGNOSTICS, never an existence assertion. Any connection creates them and a
# clean close removes them, so on a machine whose own sessions write state their presence is no
# more attributable to this suite than a ledger's mtime is — asserting on it would give a
# time-sensitive byte the authority of an oracle, which is how a suite starts failing at random.
CC_LIVE_WAL="cc-state.db-wal cc-state.db-shm"
_mt(){ stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
_cc_live_stat(){
  local n f
  for n in "$@"; do
    f="$CC_LIVE_DIR/$n"
    if [ -e "$f" ]; then echo "$n present sha=$(shasum -a 256 < "$f" | awk '{print $1}') mtime=$(_mt "$f")"
    else echo "$n ABSENT"; fi
  done
}
# Which live stores exist, and their sha/mtime. Existence is an ASSERTION for the ledgers and the
# library (a rewrite that filters a store empty deletes it); sha/mtime, and the WAL sidecars
# entirely, are printed as diagnostics only — see the churn note above.
_cc_live_files(){ _cc_live_stat $CC_LIVE_LEDGERS $CC_LIVE_WAL; }
_cc_live_exist(){ _cc_live_stat $CC_LIVE_LEDGERS | awk '{print $1, $2}'; }
# THE oracle for the engine swap. Migration renames a legacy TSV to <name>.migrated.<ts>, and
# that rename is the one unmistakable signature of an unsandboxed run reaching the human's real
# stores. Unlike a row count it cannot be produced by outside traffic — nothing else in the stack
# writes that name — and it is also the most destructive thing this suite could do: until the
# human re-runs install.sh the install dir still runs the PRE-SWAP cc-state, which after such a
# rename would find no TSVs at all and show an empty board.
_cc_live_migrated(){ ls -d "$CC_LIVE_DIR"/*.migrated.* 2>/dev/null | wc -l | tr -d ' '; }
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
# The library is binary, but a leaked fixture path is stored inside it as literal bytes, so
# `grep -a` finds one without this watchdog having to know a single thing about the schema —
# which is the point: §24 must stay independent of the facade it is watching.
# `grep -c` prints its 0 AND exits 1, so a `|| echo 0` fallback leg answers TWICE ("0\n0") on the
# healthy path and the caller's $(( )) below dies with a syntax error on every clean run. Substitute
# once, default the EMPTY case (file missing / unreadable) instead of chaining on rc.
_cc_live_db_tmp(){ _n="$(grep -ac '/var/folders/\|/tmp/' "$CC_LIVE_DIR/cc-state.db" 2>/dev/null)"; echo "${_n:-0}"; }
_cc_live_tmp_rows(){ echo $(( $(_cc_live_keys | grep -cE ' (/private)?(/var/folders/|/tmp/)' || true) + $(_cc_live_db_tmp) )); }
# Layer 1's own integrity: count overrides that no longer point into the sandbox. Defined as a
# function on purpose — bash 3.2 mis-parses a `case` pattern's `)` inside a `$( )` substitution.
_cc_overrides_escaped(){
  local v n=0
  for v in "$CC_STATE_DB" "$CC_TRUST_CFG_OVERRIDE"; do
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
CC_LIVE_MIGRATED_BEFORE="$(_cc_live_migrated)"
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

echo ""
echo "== 33. cc-hooks.sh status via cc-state =="
# The status hook now delegates every state write to the facade (plan Task 4): parse the event,
# classify it, canonicalize the cwd, ONE cc-state call. This section pins the hook's hard rules —
# zero output, always exit 0, never ready — on the facade path, plus the two questions the brief
# left to verification:
#   H1 (canonicalization timing): the hook KEEPS its cd+pwd -P. Not for matching — cc-state's
#     dir rule takes the raw string OR the canonical form, so a legacy LOGICAL-path row (/var
#     vs /private/var, spec §3.5 defect 3) joins either way — but as the enterability gate:
#     cd must succeed, while cc-state's best-effort realpath never fails, so a vanished cwd
#     must be stopped HERE or it writes a sidecar row the board can never join.
#   H2 (no python3): two spawns this round (parse + cc-state), deliberately unmerged (that is
#     C-phase work); with no python3 on PATH the hook must still exit 0, silent, writing nothing.
#   F8 (no-board fast path): the [ -f "$tasks" ] gate STAYS in front of everything — it is
#     payload-independent, fires on the hottest path in the stack, and saves both python
#     startups on no-board machines (the common case). Round-2 gate restored it after a
#     10.5× slowdown (4.3→45.1 ms/event); the zero-start contract is pinned below.
S33=$(mktemp -d)
s33cn(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
B33="$(s33cn "$(mktemp -d)")"    # registered board dir — physical form, like a production row
U33="$(s33cn "$(mktemp -d)")"    # a dir with no board row
V33="$(mktemp -d)"               # mktemp hands back the LOGICAL $TMPDIR form (/var/...)
P33="$(s33cn "$V33")"            # ...its physical twin (/private/var/...)
export CC_STATE_DB="$S33/cc-state.db"
printf '2026-01-01 00:00:00\tfeat/33\tsurface:33\t%s\tsurface:1\ttask 33\n' "$B33" | st_seed tasks
printf '2026-01-01 00:00:00\tfeat/33L\tsurface:34\t%s\tsurface:1\tlegacy logical row\n' "$V33" | st_append tasks
s33pay(){ python3 -c 'import json,sys; print(json.dumps({"hook_event_name":sys.argv[1],"cwd":sys.argv[2],"message":sys.argv[3]}))' "$1" "$2" "$3"; }
s33run(){ printf '%s' "$(s33pay "$1" "$2" "${3:-}")" | bash "$CC/cc-hooks.sh" status 2>&1; }
# contract 1 + the write itself: silent, exit 0, and the state lands through the facade
o33="$(s33run UserPromptSubmit "$B33")"; rc33=$?
eq "33 hook writes nothing to stdout/stderr" "$o33" ""
eq "33 hook always exits 0" "$rc33" "0"
eq "33 working written through the facade" "$("$CC/cc-state" dump status | cut -f2)" "working"
# (Task 8) sidecar VALUE reads go through the facade from here on — `dump status` is the raw
# read verb; its byte-passthrough is itself pinned in §32, so these greps/awks still see
# exactly the bytes the hook + facade wrote (they are NOT excused like §32's direct reads)
# H2: a PATH without python3 (cat still on it — the payload must arrive) degrades to a silent
# no-op: exit 0, not a byte out, not one new sidecar row
NP33="$S33/nopy"; mkdir "$NP33"
# env re-execs bash THROUGH the restricted PATH, so the interpreter itself must be on it
ln -s /bin/bash "$NP33/bash"; ln -s /bin/cat "$NP33/cat"; ln -s /usr/bin/dirname "$NP33/dirname"
n33=$("$CC/cc-state" dump status | wc -l | tr -d ' ')
o33np="$(printf '%s' "$(s33pay UserPromptSubmit "$B33" '')" | env PATH="$NP33" bash "$CC/cc-hooks.sh" status 2>&1)"; rc33np=$?
eq "33 no python3 degrades to exit 0" "$rc33np" "0"
eq "33 no python3 writes nothing" "$o33np" ""
# (red-proof note: no realistic mutation reaches this row assertion — both write legs need
# python3, so a no-python hook cannot write; it is indirectly covered by the R2 sibling
# "unregistered dir writes no row" and stays as a contract guard for any future python-free
# write leg)
eq "33 no python3 adds no sidecar row" "$("$CC/cc-state" dump status | wc -l | tr -d ' ')" "$n33"
# F8 fast path, pinned by ASSERTION this time (round-2 gate): with NO board file the hook must
# not start python3 even once — the prefilter predates the facade, is payload-independent,
# sits on the hottest path in the stack, and task-set-state would be a silent no-op anyway,
# so the gate only buys back cost: both python startups (4.3ms vs 45.1ms/event measured when
# the gate was deleted). Count spawns with the §27 trick: a PATH-fronted python3 shim that
# logs each start, then execs the real interpreter.
S33F8=$(mktemp -d); S33RP="$(command -v python3)"
cat > "$S33F8/python3" <<S33P
#!/usr/bin/env bash
echo x >> "\${CC_PY_LOG:-/dev/null}"
exec "$S33RP" "\$@"
S33P
chmod +x "$S33F8/python3"
: > "$S33F8/pylog"
printf '%s' "$(s33pay UserPromptSubmit "$B33" '')" \
  | env PATH="$S33F8:$PATH" CC_PY_LOG="$S33F8/pylog" \
    CC_STATE_DB="$S33F8/absent.db" \
    bash "$CC/cc-hooks.sh" status >/dev/null 2>&1
eq "33 no board: zero python3 starts (F8)" "$(wc -l < "$S33F8/pylog" | tr -d ' ')" "0"
# membership: an unregistered dir is a silent no-op (now the facade's rule, not the hook's awk)
o33u="$(s33run UserPromptSubmit "$U33")"; rc33u=$?
eq "33 unregistered dir is silent" "$o33u" ""
eq "33 unregistered dir exits 0" "$rc33u" "0"
eq "33 unregistered dir writes no row" "$("$CC/cc-state" dump status | grep -cF "$U33")" "0"
# H1: the legacy LOGICAL row gains a state — the old exact-match awk never joined it (defect 3)
# — and the sidecar row is keyed PHYSICAL, the form the board render joins on
eq "33 H1 fixture is a logical/physical pair" "$([ "$V33" != "$P33" ] && echo yes || echo no)" "yes"
o33l="$(s33run UserPromptSubmit "$V33")"
eq "33 logical-cwd event is silent" "$o33l" ""
eq "33 legacy logical row gains state (H1/defect 3)" "$("$CC/cc-state" dump status | awk -F'\t' -v d="$P33" '$1==d{print $2}')" "working"
# contract 3: after every event this hook fires, the sidecar holds no ready (the facade refuses
# the value outright — §32 pins that refusal; this pins the disk after the hook ran)
eq "33 sidecar never holds ready" "$("$CC/cc-state" dump status | grep -c ready)" "0"
# structure: the lock loop and the read-modify-write are gone from the hook; exactly one
# facade call remains; and the no-board fast path is PRESENT (round-2 gate — the membership
# awk it used to feed is gone, the [ -f ] gate itself stays)
eq "33 hook has no mkdir lock left"          "$(grep -c 'mkdir "\$lock"' "$CC/cc-hooks.sh")" "0"
eq "33 hook has no tmp+mv rewrite left"      "$(grep -c 'mv "\$tmp"' "$CC/cc-hooks.sh")" "0"
eq "33 the no-board fast path is present"    "$(grep -cF '[ -f "$db" ] || [ -f "$dbdir/worktree-tasks.tsv" ] || exit 0' "$CC/cc-hooks.sh")" "1"
eq "33 hook delegates via one facade call"   "$(grep -c 'cc-state" task-set-state' "$CC/cc-hooks.sh")" "1"
# the worktree branch's python heredoc must have survived untouched: still the file's ONLY
# heredoc, still apostrophe-free inside (bash 3.2 mis-parses one in a heredoc nested in $( ))
eq "33 the PY heredoc is still the only one" "$(grep -c "<<'PY'" "$CC/cc-hooks.sh")" "1"
S33H="$(awk "/<<'PY'/{f=1;next} /^PY\$/{f=0} f" "$CC/cc-hooks.sh" | grep -c "'")"
eq "33 no apostrophe inside the heredoc body" "$S33H" "0"
rm -rf "$S33" "$S33F8" "$V33" "$B33" "$U33"; cc_sandbox_ledgers   # back to the sandbox before §2b re-exports

echo "== 2b. cc-hooks.sh status: agent-state sidecar =="
# Board rows must hold pwd -P-canonical dirs — exactly what the write path produces in
# production (cc-state task-add since Task 9; the retired cc-board.sh log before it;
# mktemp hands back /var/... which pwd -P resolves to /private/var/... on macOS).
cn(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
SB="$(cn "$(mktemp -d)")"; NB="$(cn "$(mktemp -d)")"; RD="$(cn "$(mktemp -d)")"   # SB: board dir  NB: not on the board  RD: render-only
S2B=$(mktemp -d)
export CC_STATE_DB="$S2B/cc-state.db"
printf '2026-01-01 00:00:00\tfeat/B\tsurface:2\t%s\tsurface:1\tdo B\n' "$SB" | st_seed tasks
hj(){ python3 -c 'import json,sys; print(json.dumps({"hook_event_name":sys.argv[1],"cwd":sys.argv[2],"message":sys.argv[3]}))' "$1" "$2" "$3"; }
hr(){ printf '%s' "$1" | "$CC/cc-hooks.sh" status 2>&1; }               # hook runner: stdout+stderr together
hs(){ local o rc; o="$(hr "$1")"; rc=$?; eq "$2 silent" "$o" ""; eq "$2 exit0" "$rc" "0"; }   # HARD RULES: prints nothing, exits 0 — every path
hs "$(hj UserPromptSubmit "$SB" '')" "UPS board-dir"
# (Task 8) sidecar reads through the facade's raw read verb — see the §33 note; expected
# values below are UNCHANGED from the direct-file era, only the read path moved
eq "UPS writes working"        "$("$CC/cc-state" dump status | awk -F'\t' -v d="$SB" '$1==d{print $2}')" "working"
eq "ts is unix epoch"          "$("$CC/cc-state" dump status | awk -F'\t' -v d="$SB" '$1==d{print ($3 ~ /^[0-9]+$/)?"ok":"no"}')" "ok"
hs "$(hj Stop "$SB" '')" "Stop board-dir"
eq "Stop updates to idle"      "$("$CC/cc-state" dump status | awk -F'\t' -v d="$SB" '$1==d{print $2}')" "idle"
eq "one row per dir"           "$("$CC/cc-state" dump status | wc -l | tr -d ' ')" "1"
hs "$(hj Notification "$SB" 'Claude needs your permission to use Bash')" "permission notification"
eq "permission → blocked"      "$("$CC/cc-state" dump status | awk -F'\t' -v d="$SB" '$1==d{print $2}')" "blocked"
tsb=$("$CC/cc-state" dump status | awk -F'\t' -v d="$SB" '$1==d{print $3}'); sleep 1
hs "$(hj Notification "$SB" 'Task completed successfully')" "non-permission notification"
eq "non-perm keeps state"      "$("$CC/cc-state" dump status | awk -F'\t' -v d="$SB" '$1==d{print $2}')" "blocked"
eq "non-perm keeps ts"         "$("$CC/cc-state" dump status | awk -F'\t' -v d="$SB" '$1==d{print $3}')" "$tsb"
hs "$(hj UserPromptSubmit "$NB" '')" "UPS non-board-dir"
eq "non-board dir writes no row" "$("$CC/cc-state" dump status | grep -cF "$NB")" "0"
hs "not json" "malformed stdin"
hs "" "empty stdin"
# gwt-status rendering against a fabricated tasks+status pair: working/idle/blocked with age, dash when no row
# (--all: cc-board.sh filters rows to the caller's repo by default; the fabricated dirs live outside it)
RD2="$(cn "$(mktemp -d)")"; RD3="$(cn "$(mktemp -d)")"
printf '2026-01-01 00:00:00\tfeat/Q\tsurface:4\t%s\tsurface:1\tno status row\n' "$RD"  | st_append tasks
printf '2026-01-01 00:00:00\tfeat/R\tsurface:5\t%s\tsurface:1\trender R\n' "$RD2" | st_append tasks
printf '2026-01-01 00:00:00\tfeat/S\tsurface:6\t%s\tsurface:1\trender S\n' "$RD3" | st_append tasks
now=$(date +%s)
printf '%s\tworking\t%s\n%s\tidle\t%s\n%s\tblocked\t%s\n' "$RD" $((now-23*60)) "$RD2" $((now-2*3600)) "$RD3" $((now-5*60)) | st_seed status
ROUT="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-status --all" 2>/dev/null)"
eq "render working(23m)"  "$(echo "$ROUT" | grep -c 'working(23m)')" "1"
eq "render idle(2h)"      "$(echo "$ROUT" | grep -c 'idle(2h)')" "1"
eq "render blocked(5m)"   "$(echo "$ROUT" | grep -c 'blocked(5m)')" "1"
eq "render dash w/o row"  "$(echo "$ROUT" | grep -F "$SB" | grep -c ' - ')" "1"
eq "header has TAB+STATUS" "$(echo "$ROUT" | head -1 | grep -c 'TAB.*STATUS')" "1"
# gwt-prune sweeps status rows whose dir no longer exists (sidecar stays consistent with the board)
rm -rf "$RD3"
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-prune" >/dev/null 2>&1
# (Task 8, §4-trap cases) these two test the SWEEP's side effect on what is on disk, so the
# read verb is `dump status` (raw passthrough) — a filtered verb like the board view would
# hide dead rows at read time and make "swept" vacuously green
eq "prune sweeps dead status row" "$("$CC/cc-state" dump status | grep -cF "$RD3")" "0"
eq "prune keeps live status rows" "$("$CC/cc-state" dump status | wc -l | tr -d ' ')" "2"
# gwt-rm drops the status row of the removed dir (same bookkeeping as the task list)
RR=$(mktemp -d); ( cd "$RR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wtS -b feat/S >/dev/null )
SW="$(cd "$RR/.claude/worktrees/wtS" && pwd -P)"
printf '%s\tidle\t%s\n' "$SW" "$(date +%s)" | st_append status
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$RR'; gwt-rm wtS" >/dev/null 2>&1
# (Task 8 edge) the emptied sidecar may not even EXIST here: old form `grep -cF … 2>/dev/null`
# printed 0 for a missing file; `dump status` of a missing file is silent rc 0 with no bytes,
# and grep -c on empty input still prints 0 — same assertion, same value, no error path left
eq "gwt-rm drops status row" "$("$CC/cc-state" dump status | grep -cF "$SW")" "0"
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
rm -rf "$IH" "$RR" "$SB" "$NB" "$RD" "$RD2" "$S2B"; cc_sandbox_ledgers

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
S2C=$(mktemp -d)
export CC_STATE_DB="$S2C/cc-state.db"
now=$(date +%s)
printf '2026-01-01 00:00:01\tfeat/W\tsurface:31\t%s\tsurface:1\tboard task W (older)\tmain\n' "$BW"  | st_seed tasks
printf '2026-01-01 00:00:02\tfeat/W\tsurface:32\t%s\tsurface:1\tboard task W\tmain\n' "$BW" | st_append tasks
printf '2026-01-01 00:00:03\tfeat/W1\tsurface:33\t%s\tsurface:1\tboard task W1\tfeat/W\n' "$BW1" | st_append tasks
printf '2026-01-01 00:00:04\tfeat/X\tsurface:34\t%s\tsurface:1\ttask in another repo\tmain\n' "$OTH" | st_append tasks
printf '%s\tworking\t%s\n%s\tidle\tabc\n' "$BW" $((now-23*60)) "$BW1" | st_seed status
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
"$CC/cc-state" dump tasks | awk -F'\t' -v OFS='\t' -v p="$BRD" '$2=="feat/W1"{$4=p "/wtW1"} {print}' | st_seed tasks
eq "logical row dir still shows"   "$(brd "$BRD" | grep -c 'board task W1')" "1"
# prune-on-read: dead-dir rows are dropped from the tasks file by the render itself (mkdir-lock rewrite)
printf '2026-01-01 00:00:05\tfeat/G\tsurface:35\t%s\tsurface:1\tdead dir row\tmain\n' "$BRD/gone" | st_append tasks
brd "$BRD" >/dev/null
# (Task 8, §4-trap cases) both assert the SWEEP's side effect on disk, so the read verb is
# `dump tasks` (raw passthrough) — `task-list` skips dead dirs and dedups per dir AT READ
# TIME, so it would report "0"/"4" even if the sweep never ran: vacuously green
eq "prune drops dead-dir row"      "$("$CC/cc-state" dump tasks | grep -c 'dead dir row')" "0"
eq "prune keeps live rows"         "$("$CC/cc-state" dump tasks | wc -l | tr -d ' ')" "4"
DF=$(mktemp -u); printf '2026-01-01 00:00:05\tfeat/G\tsurface:35\t%s\tsurface:1\tdead dir row\tmain\n' "/tmp/cc-board-gone-$$" | st_seed tasks "$DF.db"
eq "all-dead message"              "$(CC_STATE_DB="$DF.db" bash "$CC/cc-board.sh" 2>/dev/null)" "no registered worktree tasks"
eq "all-dead removes file"         "$([ -f "$DF" ] && echo yes || echo no)" "no"
# _gwt_archive_branch: move ALL rows of a branch to the archive (+ drop their status rows), keep others
TF=$(mktemp -u); SF=$(mktemp -u); AF=$(mktemp -u)
export CC_STATE_DB="$TF.db"
printf '2026-01-01 00:00:01\tfeat/W\tsurface:41\t%s\tsurface:1\tarch task W1\tmain\n' "$BW"  | st_seed tasks
printf '2026-01-01 00:00:02\tfeat/W\tsurface:42\t%s\tsurface:1\tarch task W2\tmain\n' "$BRD" | st_append tasks
printf '2026-01-01 00:00:03\tfeat/W1\tsurface:43\t%s\tsurface:1\tarch task W1b\tfeat/W\n' "$BW1" | st_append tasks
# new-format row (8 live fields incl. launch-args) → archive must gain 9 fields, args intact
printf '2026-01-01 00:00:04\tfeat/W\tsurface:47\t%s\tsurface:1\tarch task W3\tmain\tuuid=99999999-8888-7777-6666-555555555555:provider=glm:pm=auto:model=g1\n' "$BRD" | st_append tasks
printf '%s\tidle\t%s\n%s\tidle\t%s\n%s\tidle\t%s\n' "$BW" "$now" "$BRD" "$now" "$BW1" "$now" | st_seed status
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; _gwt_archive_branch feat/W" >/dev/null 2>&1
# (Task 8b) WHERE THE ROWS ENDED UP is a write side effect, so these read the raw store via
# `dump` — the stores are exported to $TF/$SF/$AF above. A filtering verb must not appear here:
# task-list skips dead dirs and dedups per dir AT READ TIME, so "moved" would report 0 with the
# move never made. The three FORMAT pins below keep their direct file read (see their note).
eq "archive moves ALL branch rows"   "$("$CC/cc-state" dump tasks | awk -F'\t' '$2=="feat/W"' | wc -l | tr -d ' ')" "0"
eq "other branch stays"              "$("$CC/cc-state" dump tasks | awk -F'\t' '$2=="feat/W1"' | wc -l | tr -d ' ')" "1"
eq "archive gained all rows"         "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/W"' | wc -l | tr -d ' ')" "3"
# FORMAT PINS — §32-class. Their subject is the archive row's LAYOUT (8 live fields → 9 with
# merged-at APPENDED as the last field), selected by file position / branch. The awk selection is
# unchanged; only the byte SOURCE moved off the file onto `dump`, the raw passthrough — what is
# compared is still the bytes the writer put into the store.
eq "archive old rows have 8 fields"  "$("$CC/cc-state" dump archive | awk -F'\t' 'NR==1{print NF}')" "8"
eq "archive new row has 9 fields"    "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/W" && $6=="arch task W3"{print NF}')" "9"
eq "archive keeps launch-args"       "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/W" && $8 ~ /^uuid=/{c++} END{print c+0}')" "1"
eq "merged-at is a unix ts"          "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/W"{print ($NF ~ /^[0-9]+$/)?"ok":"no"}' | sort -u)" "ok"
eq "moved status rows dropped"       "$("$CC/cc-state" dump status | awk -F'\t' -v a="$BW" -v b="$BRD" '$1==a||$1==b{c++} END{print c+0}')" "0"
eq "other status row kept"           "$("$CC/cc-state" dump status | awk -F'\t' -v d="$BW1" '$1==d{c++} END{print c+0}')" "1"
# gwt-merge archives on success (and on skipped-already-merged, same rc 0 path)
"$CC/cc-merge.sh" set-parent "$BRD" feat/W1 feat/W
"$CC/cc-merge.sh" done "$BRD" feat/W1 true
( cd "$BRD/wtW1" && git commit -q --allow-empty -m w1 )
printf '\ny\n' | zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$BRD'; gwt-merge feat/W1" >/dev/null 2>&1; gmrc=$?
eq "gwt-merge exit 0"                "$gmrc" "0"
# (Task 8b edge, same as Task 8's sidecar one) the old awk carried `2>/dev/null` because the
# tasks file may not EXIST here (every row moved out → the rewriter deletes it); `dump` of a
# missing store is silent rc 0 with no bytes, so the error path is gone rather than muffled
eq "merge archives branch rows"      "$("$CC/cc-state" dump tasks | awk -F'\t' '$2=="feat/W1"' | wc -l | tr -d ' ')" "0"
eq "merge appends to archive"        "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/W1"' | wc -l | tr -d ' ')" "1"
# gwt-log renders the archive: same columns, same repo filter
printf '2026-01-01 00:00:09\tfeat/Y\tsurface:44\t%s\tsurface:1\tarch other repo\tmain\n' "$OTH" | st_append archive
LO="$(brd "$BRD" --archive)"
eq "gwt-log header"                  "$(echo "$LO" | head -1 | tr -s ' ')" "TAB BRANCH PARENT STATUS DIR TASK"
eq "gwt-log shows archive"           "$(echo "$LO" | grep -c 'arch task W2')" "1"
eq "gwt-log PARENT not shifted"      "$(rowof "$LO" "$BW" | awk '{print $3}')" "main"
eq "gwt-log repo filter"             "$(echo "$LO" | grep -c 'arch other repo')" "0"
eq "gwt-log --all"                   "$(brd "$BRD" "--archive --all" | grep -c 'arch other repo')" "1"
LOW="$( ( cd "$BRD" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-log") 2>/dev/null )"
eq "gwt-log wrapper renders"         "$(echo "$LOW" | grep -c 'arch task W2')" "1"
# gwt-status wrapper: forwards to bash cc-board.sh, filter + STATUS join intact end-to-end
printf '2026-01-01 00:00:06\tfeat/W\tsurface:45\t%s\tsurface:1\twrap task W\tmain\n' "$BW"  | st_seed tasks
printf '2026-01-01 00:00:07\tfeat/X\tsurface:46\t%s\tsurface:1\twrap other\tmain\n' "$OTH" | st_append tasks
printf '%s\tworking\t%s\n' "$BW" $((now-23*60)) | st_seed status
SW="$( ( cd "$BRD" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-status") 2>/dev/null )"
eq "gwt-status wrapper renders"      "$(echo "$SW" | grep -c 'wrap task W')" "1"
eq "wrapper STATUS join"             "$(echo "$SW" | grep -c 'working(23m)')" "1"
eq "wrapper applies repo filter"     "$(echo "$SW" | grep -c 'wrap other')" "0"
SWA="$( ( cd "$BRD" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-status --all") 2>/dev/null )"
eq "wrapper forwards --all"          "$(echo "$SWA" | grep -c 'wrap other')" "1"
rm -rf "$BRD" "$OTH" "$NORD" "$S2C"; rm -f "$TF" "$SF" "$AF" "$DF" "$TF.db" "$DF.db"; cc_sandbox_ledgers

echo ""
echo "== 34. cc-board renders through cc-state (the render owns no state access) =="
DB_34="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
cn34(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
# fixture repo: two registered worktrees + a foreign dir (another repo's row). The header
# literal below is MEASURED from the pre-change board's real output (brief §4: column -t's
# spacing depends on cell widths, so the expected value is transcribed, never composed).
B34="$(mktemp -d)"; ( cd "$B34"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  git worktree add -q .claude/worktrees/wA -b feat/34A >/dev/null
  git worktree add -q .claude/worktrees/wB -b feat/34B >/dev/null )
B34="$(cn34 "$B34")"; W34A="$B34/.claude/worktrees/wA"; W34B="$B34/.claude/worktrees/wB"
OTH34="$(cn34 "$(mktemp -d)")"
git -C "$B34" config branch.feat/34A.ccMergeInto main
NOW34=$(date +%s); T34=$(mktemp -u); S34=$(mktemp -u); A34=$(mktemp -u)
mk34(){  # the B row's 7th field is "camp": the PARENT fallback a branch without config takes
  printf '2026-01-01 00:00:01\tfeat/34A\tsurface:61\t%s\tsurface:1\t34 task A (older)\tmain\n' "$W34A" |  st_seed tasks "$DB_34"
  printf '2026-01-01 00:00:02\tfeat/34A\tsurface:62\t%s\tsurface:1\t34 task A\tmain\n'     "$W34A" | st_append tasks "$DB_34"
  printf '2026-01-01 00:00:03\tfeat/34B\tsurface:63\t%s\tsurface:1\t34 task B\tcamp\n'     "$W34B" | st_append tasks "$DB_34"
  printf '2026-01-01 00:00:04\tfeat/34X\tsurface:64\t%s\tsurface:1\t34 foreign\tmain\n'    "$OTH34" | st_append tasks "$DB_34"
  printf '%s\tworking\t%s\n' "$W34A" $((NOW34-1230)) |  st_seed status "$DB_34"       # 20m — far from a bucket edge
  printf '%s\tidle\tabc\n'  "$W34B"             | st_append status "$DB_34"            # malformed ts → idle(?)
  printf '2026-01-01 00:00:09\tfeat/34AR\tsurface:65\t%s\tsurface:1\t34 archived\tmain\n' "$W34A" |  st_seed archive "$DB_34"
  printf '2026-01-01 00:00:10\tfeat/34XR\tsurface:66\t%s\tsurface:1\t34 arch foreign\tmain\n' "$OTH34" | st_append archive "$DB_34"
}
# PATH without cmux → deterministic "?" TAB cells and no liveness notes; CC_SEND_FAILLOG silenced.
# Flags forward one per argument (${2:-} ${3:-}): a quoted "--archive --all" would arrive as ONE
# argument under zsh's no-split expansion and silently render a different board.
brd34(){ ( cd "${1:-$B34}" && env PATH=/usr/bin:/bin CC_STATE_DB="$DB_34" \
    CC_STATE_DB="$DB_34" CC_SEND_FAILLOG=/dev/null bash "$CC/cc-board.sh" ${2:-} ${3:-} ) 2>/dev/null; }
row34(){ echo "$1" | awk -v d="$2" '$5==d'; }                       # board row by DIR column
cell34(){ row34 "$1" "$2" | awk -v c="$3" '{print $c}'; }           # one column of that row
mk34; BO34="$(brd34 "$B34" --all)"
# header: the fixed columns' spacing is byte-pinned up to DIR — the DIR column's own padding
# tracks the widest dir (a mktemp path), so the literal stops at the column name
eq "34 header contract" "$(printf '%s\n' "$BO34" | head -1 | sed 's/\(DIR\).*/\1/')" \
  "TAB  BRANCH    PARENT  STATUS        DIR"
eq "34 status cell shape"        "$(cell34 "$BO34" "$W34A" 4)" "working(20m)"
eq "34 malformed ts renders ?"   "$(cell34 "$BO34" "$W34B" 4)" "idle(?)"
eq "34 dash when no status row"  "$(cell34 "$BO34" "$OTH34" 4)" "-"
eq "34 TAB cell is ? w/o cmux"   "$(cell34 "$BO34" "$W34A" 1)" "?"
eq "34 newest row per dir wins"  "$(printf '%s\n' "$BO34" | grep -c '34 task A (older)')" "0"
eq "34 PARENT from git config"   "$(cell34 "$BO34" "$W34A" 3)" "main"
eq "34 PARENT falls to 7th field" "$(cell34 "$BO34" "$W34B" 3)" "camp"
eq "34 --all shows foreign"      "$(printf '%s\n' "$BO34" | grep -c '34 foreign')" "1"
# row order = task-list's newest-first (reversed file order): X, B, A
eq "34 rows newest-first" "$(printf '%s\n' "$BO34" | sed -n '2p;3p;4p' | \
  awk -v o="$OTH34" -v b="$W34B" -v a="$W34A" '{ if ($5==o) k=k"X"; else if ($5==b) k=k"B"; else if ($5==a) k=k"A" } END{print k}')" "XBA"
# the gate round-2 pair: a LEGACY LOGICAL row (recorded as /var/…; mktemp hands back the
# logical form while the hook's sidecar key is the canonical /private/var form)
# · STATUS must still join — the join lives in task-list --with-state and keys on the facade's
#   dir rule (both forms). A caller-side raw-string join shows "-" for exactly these rows.
# · DIR showing the RECORDED string is an intentional deviation (gate-ruled): the old board
#   silently re-canonicalized every dir on read — the read-side half of spec §3.5 defect 3 —
#   hiding how the row was actually logged. Do NOT "fix" this back.
LG34="$(mktemp -d)"; LGC34="$(cn34 "$LG34")"
mk34; printf '2026-01-01 00:00:06\tfeat/34L\tsurface:68\t%s\tsurface:1\t34 legacy logical row\tmain\n' "$LG34" | st_append tasks "$DB_34"
printf '%s\tworking\t%s\n' "$LGC34" $((NOW34-1230)) | st_append status "$DB_34"
BO34L="$(brd34 "$B34" --all)"
eq "34 legacy logical row: STATUS still joins" "$(cell34 "$BO34L" "$LG34" 4)" "working(20m)"
eq "34 legacy logical row: DIR shows the recorded string (intentional)" "$(cell34 "$BO34L" "$LG34" 5)" "$LG34"
BO34P="$(brd34 "$B34")"
eq "34 repo filter hides foreign"   "$(printf '%s\n' "$BO34P" | grep -c '34 foreign')" "0"
eq "34 repo filter keeps own rows"  "$(printf '%s\n' "$BO34P" | grep -c '34 task [AB]')" "2"
# H2, the known-issue shape: run from a LINKED worktree, the root must still resolve to the MAIN
# repo root (computed here, handed to the facade as --repo) so same-repo siblings stay visible
BO34W="$(brd34 "$W34A")"
eq "34 from a linked worktree: siblings visible" "$(printf '%s\n' "$BO34W" | grep -c '34 task [AB]')" "2"
eq "34 from a linked worktree: foreign hidden"   "$(printf '%s\n' "$BO34W" | grep -c '34 foreign')" "0"
# the archive: every row, file order, repo filter on (what gwt-log shows)
eq "34 archive renders"              "$(brd34 "$B34" --archive | grep -c '34 archived')" "1"
eq "34 archive repo filter"          "$(brd34 "$B34" --archive | grep -c '34 arch foreign')" "0"
eq "34 archive --all shows foreign"  "$(brd34 "$B34" --archive --all | grep -c '34 arch foreign')" "1"
# H1: prune-on-read is still a WRITE (a board read that silently stopped deleting rows would
# strand dead rows on disk forever) — now one facade call sweeping the tasks+sidecar pair
mk34
printf '2026-01-01 00:00:05\tfeat/34G\tsurface:67\t%s\tsurface:1\t34 dead row\tmain\n' "$B34/gone" | st_append tasks "$DB_34"
DDEAD34="$(mktemp -u)"                                    # a dir string that never exists
# D 期：状态是任务行上的列 —— 「无关的 sidecar 行」就是「一条带状态的无关任务行」
printf '2026-01-01 00:00:07\tfeat/34X\tsurface:69\t%s\tsurface:1\t34 dead sidecar row\tmain\n' "$DDEAD34" | st_append tasks "$DB_34"
printf '%s\tidle\t%s\n' "$DDEAD34" "$NOW34" | st_append status "$DB_34"
brd34 "$B34" >/dev/null
# (Task 8b, §4-trap cases) all four test the SWEEP's side effect on disk, so the read verb is
# `dump` (raw passthrough), env-scoped to this section's stores. task-list would skip the dead
# dir and dedup per dir at READ time and report "0"/"4" with the sweep never run: vacuously green
eq "34 render prunes dead task rows via facade"   "$(CC_STATE_DB="$DB_34" "$CC/cc-state" dump tasks | grep -c '34 dead row')" "0"
eq "34 render prunes dead sidecar rows via facade" "$(CC_STATE_DB="$DB_34" "$CC/cc-state" dump status | grep -cF "$DDEAD34")" "0"
eq "34 render keeps live task rows"                "$(CC_STATE_DB="$DB_34" "$CC/cc-state" dump tasks | wc -l | tr -d ' ')" "4"
eq "34 render keeps live sidecar rows"             "$(CC_STATE_DB="$DB_34" "$CC/cc-state" dump status | wc -l | tr -d ' ')" "2"
mk34
printf '2026-01-01 00:00:07\tfeat/34X\tsurface:69\t%s\tsurface:1\t34 dead sidecar row\tmain\n' "$DDEAD34" | st_append tasks "$DB_34"
printf '%s\tidle\t%s\n' "$DDEAD34" "$NOW34" | st_append status "$DB_34"
brd34 "$B34" --archive >/dev/null
# the dead row is still THERE — "not swept" can only be read raw (a filtered view hides it)
eq "34 archive render spares the sidecar" "$(CC_STATE_DB="$DB_34" "$CC/cc-state" dump status | grep -cF "$DDEAD34")" "1"
TONE34=$(mktemp -u)
printf '2026-01-01 00:00:05\tfeat/34G\tsurface:67\t%s\tsurface:1\t34 dead row\tmain\n' "$(mktemp -u)" | st_seed tasks "$DB_34"
eq "34 all-dead message" "$(CC_STATE_DB="$DB_34" \
  bash "$CC/cc-board.sh" 2>/dev/null)" "no registered worktree tasks"
eq "34 all-dead removes file" "$([ -f "$TONE34" ] && echo yes || echo no)" "no"
# the structural swap: the board keeps rendering + the git joins; the lock, the line droppers,
# the read-side canon map and the inline repo filter are gone from the file
eq "34 no lock/dropper helpers left"   "$(grep -c 'ccb_lock\|ccb_dead_lines\|ccb_drop_lines' "$CC/cc-board.sh")" "0"
eq "34 no read-side canon map left"    "$(grep -c 'CCB_CMAP' "$CC/cc-board.sh")" "0"
eq "34 sidecar join is the facade's"   "$(grep -c 'dump status' "$CC/cc-board.sh")" "0"
eq "34 board prunes through the facade" "$(grep -c '"$STATE" task-prune' "$CC/cc-board.sh")" "1"
eq "34 board lists rows through the facade" \
  "$([ "$(grep -c '"$STATE" task-list' "$CC/cc-board.sh")" -ge 1 ] && echo yes || echo no)" "yes"
rm -rf "$B34" "$OTH34" "$LG34"; rm -f "$T34" "$S34" "$A34" "$TONE34"; cc_sandbox_ledgers

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
export CC_STATE_DB="$TT.db"
LA='uuid=11111111-2222-3333-4444-555555555555:provider=kimi:pm=plan:csuuid=AAAA-BBBB:suuid=CCCC-DDDD'
E1="$(cn "$(mktemp -d)")"   # 7th field (parent) EMPTY — what a detached-HEAD dispatch writes
E2="$(cn "$(mktemp -d)")"   # 5th field (caller) EMPTY
E3="$(cn "$(mktemp -d)")"   # complete 8-field row (the drop target)
E4="$(cn "$(mktemp -d)")"   # pre-feature 7-field row (backward compat)
now20=$(date +%s)
mkrows(){   # regenerate the fixture — every rewrite path is exercised from a clean file
  printf '2026-01-01 00:00:01\tfeat/E1\tsurface:51\t%s\tsurface:9\tdo E1\t\t%s\n'      "$E1" "$LA" |  st_seed tasks
  printf '2026-01-01 00:00:02\tfeat/E2\tsurface:52\t%s\t\tdo E2\tfeat/par\t%s\n'       "$E2" "$LA" | st_append tasks
  printf '2026-01-01 00:00:03\tfeat/E3\tsurface:53\t%s\tsurface:9\tdo E3\tmain\t%s\n'  "$E3" "$LA" | st_append tasks
  printf '2026-01-01 00:00:04\tfeat/E4\tsurface:54\t%s\tsurface:1\told 7-field row\tmain\n' "$E4" | st_append tasks
}
# shape() is a FORMAT PIN — §32-class. Its subject is the stored LAYOUT of a rewritten row
# (field count, and that an empty 5th/7th field is still empty IN PLACE rather than shifted):
# the TAB-collapse class this whole section exists to catch. It used to read the store file
# directly; there is no file now, so it reads the raw passthrough. That is not the same as
# reading through a filtering verb — `dump` reconstructs the row and nothing else, so a row
# the rewriter corrupted is still visible exactly as stored.
shape(){ st_dump "$1" | awk -F'\t' -v d="$2" '$4==d{printf "%s|%s|%s|%s|%s\n", NF, $5, $6, $7, $8}'; }
S_E1="8|surface:9|do E1||$LA"; S_E2="8||do E2|feat/par|$LA"; S_E4="7|surface:1|old 7-field row|main|"
# (a) prune-on-read (cc-board.sh render) — the write-back that fossilizes the shift
mkrows
bash "$CC/cc-board.sh" --all >/dev/null 2>&1
eq "prune keeps an empty PARENT row"    "$(shape tasks "$E1")" "$S_E1"
eq "prune keeps an empty CALLER row"    "$(shape tasks "$E2")" "$S_E2"
eq "prune keeps a 7-field legacy row"   "$(shape tasks "$E4")" "$S_E4"
# (b) render: the board's own columns must not shift either
BE="$(bash "$CC/cc-board.sh" --all 2>/dev/null)"
eq "render PARENT with an empty caller" "$(echo "$BE" | awk -v d="$E2" '$5==d{print $3}')" "feat/par"
eq "render TASK with an empty caller"   "$(echo "$BE" | awk -v d="$E2" '$5==d{$1=$2=$3=$4=$5="";sub(/^ +/,"");print}')" "do E2"
eq "render PARENT '-' when unresolvable" "$(echo "$BE" | awk -v d="$E1" '$5==d{print $3}')" "-"
# (c) _gwt_tasks_rewrite (the gwt-rm / gwt-prune path)
mkrows
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; _gwt_tasks_drop_dir '$E3'" >/dev/null 2>&1
eq "rewrite drops the target row"       "$("$CC/cc-state" dump tasks | grep -c 'do E3')" "0"
eq "rewrite keeps an empty PARENT row"  "$(shape tasks "$E1")" "$S_E1"
eq "rewrite keeps an empty CALLER row"  "$(shape tasks "$E2")" "$S_E2"
eq "rewrite keeps a 7-field legacy row" "$(shape tasks "$E4")" "$S_E4"
# (d) gwt-prune: dead-dir sweep + newest-per-dir dedup, still verbatim
mkrows
{ printf '2026-01-01 00:00:00\tfeat/E2\tsurface:50\t%s\t\tolder E2 row\tfeat/par\t%s\n' "$E2" "$LA"; st_dump tasks; } | st_seed tasks
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$E1'; gwt-prune" >/dev/null 2>&1
eq "gwt-prune drops the older dup"      "$("$CC/cc-state" dump tasks | grep -c 'older E2 row')" "0"
eq "gwt-prune keeps an empty CALLER row" "$(shape tasks "$E2")" "$S_E2"
eq "gwt-prune keeps a 7-field legacy row" "$(shape tasks "$E4")" "$S_E4"
# (e) _gwt_archive_branch: merged-at is APPENDED, so 8-field rows → 9, 7-field rows → 8
mkrows; : | st_seed archive
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; _gwt_archive_branch feat/E2" >/dev/null 2>&1
zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; _gwt_archive_branch feat/E4" >/dev/null 2>&1
# FORMAT PINS again (same reason as shape()): merged-at is APPENDED, so which POSITION it lands
# in is the contract — 9th on an 8-field row, 8th on a legacy 7-field one. Direct read stays.
eq "archive keeps the empty CALLER"     "$(shape archive "$E2")" "9||do E2|feat/par|$LA"
eq "archive merged-at is 9th on 8-field" "$(st_dump archive | awk -F'\t' -v d="$E2" '$4==d{print ($9 ~ /^[0-9]+$/)?"ok":"no"}')" "ok"
eq "archive merged-at is 8th on 7-field" "$(st_dump archive | awk -F'\t' -v d="$E4" '$4==d{print NF ":" (($8 ~ /^[0-9]+$/)?"ok":"no")}')" "8:ok"
# F7: the sidecar (worktree-status.tsv) is swept by the same "does this dir exist?" pass the
# board already runs per row — before this only gwt-prune/gwt-rm touched it and it grew forever.
SLIVE="$(cn "$(mktemp -d)")"; SDEAD="/tmp/cc-board-dead-$$"
mkrows
# D 期：状态是任务行上的列 —— 「无关的 sidecar 行」就是「一条带状态的无关任务行」
printf '2026-01-01 00:00:06\tfeat/SL\tsurface:56\t%s\tsurface:1\tsidecar live\tmain\t%s\n' "$SLIVE" "$LA" | st_append tasks
printf '2026-01-01 00:00:07\tfeat/SD\tsurface:57\t%s\tsurface:1\tsidecar dead\tmain\t%s\n' "$SDEAD" "$LA" | st_append tasks
printf '%s\tworking\t%s\n' "$SLIVE" "$now20"  | st_seed status
printf '%s\tidle\t%s\n'    "$SDEAD" "$now20" | st_append status
bash "$CC/cc-board.sh" --all >/dev/null 2>&1
# (Task 8b, §4-trap) sweep side effects on the sidecar: raw `dump status`, never a filtered view
eq "sidecar prune drops a dead dir"     "$("$CC/cc-state" dump status | grep -c "$SDEAD")" "0"
eq "sidecar prune keeps a live dir"     "$("$CC/cc-state" dump status | grep -c "$SLIVE")" "1"
printf '2026-01-01 00:00:07\tfeat/SD\tsurface:57\t%s\tsurface:1\tsidecar dead\tmain\t%s\n' "$SDEAD" "$LA" | st_append tasks
printf '%s\tidle\t%s\n' "$SDEAD" "$now20" | st_append status
printf '2026-01-01 00:00:05\tfeat/AR\tsurface:55\t%s\tsurface:1\tarch row\tmain\t%s\n' "$E1" "$LA" | st_seed archive
bash "$CC/cc-board.sh" --archive --all >/dev/null 2>&1
eq "archive render spares the sidecar"  "$("$CC/cc-state" dump status | grep -c "$SDEAD")" "1"
printf '%s\tidle\t%s\n' "$SDEAD" "$now20" | st_seed status
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
printf '2026-01-01 00:00:06\tfeat/stale\tsurface:56\t%s\tsurface:1\tstale ghost row\tmain\t%s\n' "$STALEDIR" "$LA" | st_seed tasks
printf '%s\tidle\t%s\n' "$STALEDIR" "$now20" | st_seed status
RMO="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$RMR'; gwt-rm stale --branch" 2>&1)"; rmrc=$?
eq "gwt-rm reclaims a gone dir (rc 0)"  "$rmrc" "0"
eq "gwt-rm prunes the registration"     "$(git -C "$RMR" worktree list --porcelain | grep -c 'worktrees/stale')" "0"
eq "gwt-rm deletes the stale branch"    "$(git -C "$RMR" branch --list 'feat/stale' | wc -l | tr -d ' ')" "0"
eq "gwt-rm drops the ghost board row"   "$("$CC/cc-state" dump tasks | grep -c 'stale ghost row')" "0"
eq "gwt-rm drops the ghost sidecar row" "$("$CC/cc-state" dump status | grep -c 'worktrees/stale')" "0"
NEV="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$RMR'; gwt-rm neverwas" 2>&1)"; nevrc=$?
eq "gwt-rm unknown name exit!=0"        "$([ "$nevrc" -ne 0 ] && echo y || echo n)" "y"
eq "gwt-rm unknown name says which"     "$(echo "$NEV" | grep -c 'no worktree named')" "1"
# F4: gwt-tree renders DOWN from the trunk, so a node whose merge target no longer exists (the
# README's own `gwt-merge <parent>` → `gwt-rm <parent> --branch` sequence) silently vanished —
# and the merge gate is exactly what gwt-tree is read for. Unreachable nodes get their own block.
TR=$(mktemp -d); TR="$(cn "$TR")"
( cd "$TR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/o1 -b feat/o1 >/dev/null
  git worktree add -q .claude/worktrees/o2 -b feat/o2 >/dev/null )
gtree(){ ( cd "$TR" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-tree" ) 2>/dev/null; }
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
NRO="$( ( cd "$NOREPO" && zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; gwt-rm foo" ) 2>&1 )"; nrorc=$?
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
printf '2026-01-01 00:00:07\tfeat/same\tsurface:57\t%s\tsurface:1\tsame branch repo1\t\n' "$P1/.claude/worktrees/same" |  st_seed tasks
printf '2026-01-01 00:00:08\tfeat/same\tsurface:58\t%s\tsurface:1\tsame branch repo2\t\n' "$P2/.claude/worktrees/same" | st_append tasks
printf '2026-01-01 00:00:09\tfeat/plain\tsurface:59\t%s\tsurface:1\tplain dir row\t\n'    "$P1/plaindir"               | st_append tasks
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
DB_28="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
env HOME="$F5H" PATH="$F5B:$PATH" CC_STATE_DB="$DB_28" CC_SEND_FAILLOG="$F5B/fail" \
  CC_SEND_VERIFY_SEC=0.1 CC_WT_SHARE="" CC_WT_PRETRUST=0 CC_CALLER_CWD="$R28" CC_WT_BASE=camp \
  bash "$CC/cc-dispatch.sh" surface "$D5A" "F5 brief" >/dev/null 2>&1
# (Task 8b) the parent recorded on ONE dir's dispatch row → task-get, the verb for that question
eq "F5 board parent = capture target" "$(CC_STATE_DB="$DB_28" "$CC/cc-state" task-get "$D5A" | awk -F'\t' '{print $7}')" "camp"
eq "F5 capture really recorded it"   "$(git -C "$D5A" config branch.feat/x28.ccMergeInto)" "camp"
eq "F5 explicit base: no capture crumb" "$([ -f "$F5B/fail" ] && { grep -c 'merge target' "$F5B/fail" || true; } || echo 0)" "0"
# …and the wt-claude path ECHOES the target to the human dispatching it (F4)
WTOUT28="$( cd "$D5A" && env HOME="$F5H" PATH="$F5B:$PATH" CC_STATE_DB="$DB_28" \
  CC_SEND_FAILLOG="$F5B/fail" CC_SEND_VERIFY_SEC=0.1 CC_WT_SHARE="" CC_WT_PRETRUST=0 \
  bash "$CC/cc-dispatch.sh" wt-claude t28 "wt-claude brief" --base camp 2>&1 )"
eq "F4 wt-claude echoes the target"  "$(echo "$WTOUT28" | grep -c 'merge target: camp (explicit --base)')" "1"
# same drive WITHOUT a base: target falls back to the caller branch + a breadcrumb is left
D5B="$(mkd28)"
: > "$F5B/fail"
env HOME="$F5H" PATH="$F5B:$PATH" CC_STATE_DB="$DB_28" CC_SEND_FAILLOG="$F5B/fail" \
  CC_SEND_VERIFY_SEC=0.1 CC_WT_SHARE="" CC_WT_PRETRUST=0 CC_CALLER_CWD="$R28" \
  bash "$CC/cc-dispatch.sh" surface "$D5B" "F5 brief 2" >/dev/null 2>&1
eq "F5 no-base parent = caller branch" "$(CC_STATE_DB="$DB_28" "$CC/cc-state" task-get "$D5B" | awk -F'\t' '{print $7}')" "main"
eq "F5 no-base leaves a crumb"     "$(grep -c 'merge target for feat/x28 recorded as: main (source: cwd)' "$F5B/fail")" "1"
rm -rf "$F5H" "$F5B" "$D5A" "$D5B"; rm -f "$F5L" "$CR28"
unstamp "$DB_28"
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
# status: the board-file prefilter STAYS (round-2 gate): payload-independent, hottest path in
# the stack — with no board file task-set-state would be a silent no-op anyway, so the gate
# buys back both python3 startups (measured 4.3ms vs 45.1ms/event when it was deleted).
# No board → 0 python starts. With a board the event costs TWO python3 startups — parse +
# facade, deliberately unmerged this round (the merge into one spawn is C-phase work)
RR28="$(CDPATH= cd -- "$R28" && pwd -P)"   # the hook canonicalizes cwd before matching the board
# NOTE: the payload is built in a variable FIRST — an inline JSON literal inside the nested
# quotes of $(h28 "…" status) gets brace-expanded apart on bash 3.2, and $2 stops being "status"
S28J="{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$RR28\",\"message\":\"\"}"
S28F=$(mktemp -u); S28=$(mktemp -u)
eq "F8 status w/o board: no python"   "$(h28 "$S28J" status)" "0"
printf '2026-01-01 00:00:00\tfeat/C\tsurface:1\t%s\tsurface:9\tt\tmain\n' "$RR28" | st_seed tasks "$DB_28"
: > "$CNT28"; printf '%s' "$S28J" \
  | env HOME="$F8H" PATH="$F8B:$PATH" CC_PY_LOG="$CNT28" CC_STATE_DB="$DB_28" \
    bash "$CC/cc-hooks.sh" status >/dev/null 2>&1
eq "F8 status with board: parse+facade"  "$(wc -l < "$CNT28" | tr -d ' ')" "2"
# the sidecar write is a side effect and has no per-dir question verb → raw `dump status`
eq "F8 status sidecar still written"   "$(CC_STATE_DB="$DB_28" "$CC/cc-state" dump status | awk -F'\t' -v d="$RR28" '$1==d{print $2}')" "working"
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
DB_8b="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
printf '\ny\n' | HOME="$FH" CC_STATE_DB="$DB_8b" \
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
DB_13="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
GT=$(mktemp -d); ( cd "$GT"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  git worktree add -q wtA -b feat/A >/dev/null; git -C wtA commit -q --allow-empty -m a
  git worktree add -q wtA1 -b feat/A1 feat/A >/dev/null; git -C wtA1 commit -q --allow-empty -m a1 )
"$CC/cc-merge.sh" set-parent "$GT" feat/A main
"$CC/cc-merge.sh" set-parent "$GT" feat/A1 feat/A
"$CC/cc-merge.sh" done "$GT" feat/A1 true
GTOUT="$(cd "$GT" && CC_STATE_DB="$DB_13" zsh -c "source '$CC/worktree.zsh'; gwt-tree" 2>/dev/null)"
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
# The entry is CLOSED (C phase deleted all ten lock copies instead of unifying them), and it
# stays in the file as a shape worth remembering — so what this pins is that the record of it
# survives, not that the work is still queued. The label said "2nd-wave queue" until 2026-08-29.
grep -q '锁 10 处副本' "$CC/docs/known-issues.md" \
  && ok "known-issues: the mkdir-lock entry is still on the record" \
  || no "known-issues: the mkdir-lock entry is still on the record" missing present
grep -q 'cc-state' "$CC/docs/backlog.md" \
  && ok "backlog: architecture-campaign section transcribed from audit-0821" \
  || no "backlog: architecture-campaign section transcribed from audit-0821" missing present
echo ""
echo "== 26. workspace scope: liveness probed across ALL workspaces, never just the caller's =="
DB_26="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
# (Task 8b) the row count comes out of the raw store via `dump tabs`, scoped to the ledger this
# call is about. It must NOT become `tab-list`: that verb drops rows another session owns (and
# every row here is owned by $UP26, not by the test process), so a pruned and an unpruned ledger
# would count the same. The [ -f ] probe stays a FILE question — an emptied store is DELETED by
# the rewriter, and "gone" is a different answer from "0 rows" that `dump` cannot give.
# "gone" used to mean the ledger FILE had been removed by a rewrite that emptied it. There is
# no per-store file now, so the observable end of that is a store with no rows — which is
# exactly the sentence `exists` was defined on. The distinction the callers draw is preserved:
# 0 rows is still reported as a different answer from "2 rows", never folded into it.
rows26(){ CC_STATE_DB="$DB_26" "$CC/cc-state" exists tabs || { echo gone; return 0; }
          CC_STATE_DB="$DB_26" "$CC/cc-state" dump tabs | awk 'END{print NR+0}'; }

# ── the helper itself: the map is a union, and it carries its own completeness ──────────────
# Lifted out of the script and sourced, the way §21 lifts the ledger block and §1 the hook python —
# the invariant has to hold at the helper, not only at the two subcommands that happen to call it.
PR26=$(mktemp -d)
awk '/^_cctabs_uc\(\)/{f=1} /^case /{f=0} f' "$CC/cc-dispatch.sh" > "$PR26/ledger.sh"
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
prune26(){ ( set -u; . "$PR26/ledger.sh"; CC_STATE_DB="$DB_26" _cctabs_prune "$2" ) >/dev/null 2>&1; }
L26="$PR26/tabs.tsv"
mkl26(){ printf 'AAAAAAAA-0000-0000-0000-00000000000A\tOWN\t/tmp/a26\t-\tts\n' |  st_seed tabs "$DB_26"
         printf 'DEADDEAD-0000-0000-0000-00000000000D\tOWN\t/tmp/d26\t-\tts\n' | st_append tabs "$DB_26"; }
mkl26; prune26 "$L26" "$(printf 'surface:1\tAAAAAAAA-0000-0000-0000-00000000000A\tworkspace:1\n!partial\n')"
eq "26 partial map prunes nothing"    "$(rows26)" "2"
# ...and the SAME map without the sentinel still prunes: the guard is the evidence, not the shape
mkl26; prune26 "$L26" "$(printf 'surface:1\tAAAAAAAA-0000-0000-0000-00000000000A\tworkspace:1\n')"
eq "26 complete map still prunes"     "$(rows26)" "1"
eq "26 complete map kept the live row" "$(CC_STATE_DB="$DB_26" "$CC/cc-state" dump tabs | awk -F'\t' 'NR==1{print substr($1,1,8)}')" "AAAAAAAA"

# ── consequence one (destructive): the opened-tabs prune ────────────────────────────────────
TB26=$(mktemp -u)
mk26(){ : | st_seed tabs "$DB_26"
  printf '%s\t%s\t%s\t-\t2026-01-01 00:00:00\n' "$UA26" "$UP26" "$WA26" | st_append tabs "$DB_26"
  printf '%s\t%s\t%s\t-\t2026-01-01 00:00:00\n' "$UB26" "$UP26" "$WB26" | st_append tabs "$DB_26"
  printf '%s\t%s\t%s\t-\t2026-01-01 00:00:00\n' "$UD26" "$UP26" "/tmp/cc-gone-26" | st_append tabs "$DB_26"; }
tabs26(){ ( cd "$R26" && env PATH="$WS26:$OP26" CC_STATE_DB="$DB_26" CC_CALLER_SURFACE_UUID="$UP26" \
    CC_FAKE_WSDOWN="${1:-}" CC_FAKE_NOWS="${2:-}" bash "$CC/cc-dispatch.sh" tabs --all ) 2>&1; }
mk26; TO26="$(tabs26)"
eq "26 tabs: caller-workspace tab alive"  "$(echo "$TO26" | grep -c "$UA26 .*alive")" "1"
eq "26 tabs: OTHER-workspace tab alive"   "$(echo "$TO26" | grep -c "$UB26 .*alive")" "1"
# (Task 8b, §4-trap — the exact case the ruling names) these test whether the prune WROTE, so
# they read the raw ledger through `dump tabs`. `tab-list` filters by owner at read time and
# `tab-list --all` still skips empty-suuid rows: a filtered read would answer the same whether
# the prune ran or not, which is how "NOT pruned" goes vacuously green.
eq "26 cross-workspace row NOT pruned"    "$(CC_STATE_DB="$DB_26" "$CC/cc-state" dump tabs | grep -c "^$UB26")" "1"
eq "26 genuinely dead row still pruned"   "$(CC_STATE_DB="$DB_26" "$CC/cc-state" dump tabs | grep -c "^$UD26")" "0"
eq "26 prune kept exactly the live rows"  "$(rows26)" "2"
# one workspace unreachable → nothing is pruned AT ALL, and the miss is reported as dead? not dead
mk26; TO26="$(tabs26 workspace:2)"
eq "26 partial probe prunes no row"       "$(rows26)" "3"
eq "26 partial probe keeps the dead row"  "$(CC_STATE_DB="$DB_26" "$CC/cc-state" dump tabs | grep -c "^$UD26")" "1"
eq "26 partial probe says so"             "$(echo "$TO26" | grep -c 'liveness partial')" "1"
eq "26 unseen row prints dead?"           "$(echo "$TO26" | grep -c "$UB26 .*dead?")" "1"
eq "26 seen row is still alive"           "$(echo "$TO26" | grep -c "$UA26 .*alive")" "1"
# no workspace list at all → the SAME refusal. This is the case the parent gate sent back: a build
# that cannot enumerate workspaces cannot know whether other workspaces exist, so pruning there is
# the original defect wearing a different trigger. Cost accepted: on such a build the ledger only
# grows, and a stale row is harmless (its uuid resolves to nothing → close says "no live tab", rc 0).
mk26; TO26="$(tabs26 "" 1)"
eq "26 no workspace list prunes NO row"   "$(rows26)" "3"
eq "26 no workspace list keeps the dead row" "$(CC_STATE_DB="$DB_26" "$CC/cc-state" dump tabs | grep -c "^$UD26")" "1"
eq "26 no workspace list keeps the cross-workspace row" "$(CC_STATE_DB="$DB_26" "$CC/cc-state" dump tabs | grep -c "^$UB26")" "1"
eq "26 no workspace list says liveness is partial" "$(echo "$TO26" | grep -c 'liveness partial')" "1"
eq "26 no workspace list still resolves its own tab" "$(echo "$TO26" | grep -c "$UA26 .*alive")" "1"

# ── consequence two: the board's TAB column ─────────────────────────────────────────────────
TF26=$(mktemp -u); SF26=$(mktemp -u); : | st_seed status "$DB_26"
bt26(){ : | st_seed tasks "$DB_26"        # $1/$2 = the refs recorded for the wtA / wtB rows
  printf '2026-01-01 00:00:01\tfeat/A26\tsurface:%s\t%s\tsurface:9\ttask in the caller workspace\tmain\n' "${1:-11}" "$WA26" | st_append tasks "$DB_26"
  printf '2026-01-01 00:00:02\tfeat/B26\tsurface:%s\t%s\tsurface:9\ttask in ANOTHER workspace\tmain\n'  "${2:-21}" "$WB26" | st_append tasks "$DB_26"; }
brd26(){ ( cd "$R26" && env PATH="${3:-$WS26:$OP26}" CC_STATE_DB="$DB_26" \
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
printf '2026-01-01 00:00:01\tfeat/A26\tsurface:11\t%s\tsurface:9\ttask A\tmain\tuuid=u1:provider=anthropic:pm=auto:csuuid=%s:suuid=%s\n' "$WA26" "$UP26" "$UA26" |  st_seed tasks "$DB_26"
printf '2026-01-01 00:00:02\tfeat/B26\tsurface:21\t%s\tsurface:9\ttask B\tmain\tuuid=u2:provider=anthropic:pm=auto:csuuid=%s:suuid=%s\n' "$WB26" "$UP26" "$UB26" | st_append tasks "$DB_26"
cl26(){ ( cd "$R26" && env PATH="$WS26:$OP26" CC_STATE_DB="$DB_26" \
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
CO26="$( cd "$R26" && env PATH="$WS26:$OP26" CC_STATE_DB="$DB_26" \
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
printf '2026-01-01 00:00:01\tfeat/B26\tsurface:77\t%s\tsurface:9\ttask B\tmain\tuuid=55555555-5555-5555-5555-555555555555:provider=anthropic:pm=auto\n' "$WB26" | st_seed tasks "$DB_26"
HM26="$WS26/home"; mkdir -p "$HM26/.config"; ln -s "$CC" "$HM26/.config/cc-stack"
: > "$CC_FAKE_LOG26"
RO26="$( cd "$R26" && env HOME="$HM26" PATH="$WS26:$OP26" CC_STATE_DB="$DB_26" \
    CC_STATE_DB="$DB_26" CC_CMUX_SESSIONS="$ST26" CC_RESUME_SETTLE=0 CC_WT_PRETRUST=0 \
    bash "$CC/cc-dispatch.sh" resume --all 2>&1 )"; rrc26=$?
eq "26 resume exit0"                        "$rrc26" "0"
eq "26 resume opens no duplicate tab"       "$(grep -c 'NEWSURF' "$CC_FAKE_LOG26")" "0"
# (Task 8b) a VALUE of one dir's row → task-get answers exactly that question ("the newest row
# recorded for this dir"), which is what the '$4==d' awk selected; $TFR26 holds a single row
eq "26 resume refreshed the ref to the other workspace" "$(CC_STATE_DB="$DB_26" "$CC/cc-state" task-get "$WB26" | awk -F'\t' '{print $3}')" "surface:21"

# insurance for a future regression: a resume that DOES reopen leaves a contentless dedup marker
# in the real TMPDIR (hash-keyed, written by surface) — sweep ours either way
unstamp "$DB_26"
rm -rf "$WS26" "$R26" "$PR26"; rm -f "$TB26" "$TF26" "$SF26" "$TFC26" "$TFR26"
unset CC_FAKE_LOG26
echo ""
echo "== 12. gwt-adopt (enroll an existing branch into the tree) =="
DB_12="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
CC_STATE_DB="$DB_12" zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$AR'; gwt-rm custom-pre --branch" >/dev/null 2>&1
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
                if [ "$n" -ge "$CC_FAKE_FLUSH_AT" ]; then
                  # CC_FAKE_FLUSH_TO=<file> flushes TO that screen instead of the empty input line
                  # (the retry submits the parked draft into a target that is working by then, so
                  # what the box shows next is the queued-message hint, not a bare prompt)
                  if [ -n "${CC_FAKE_FLUSH_TO:-}" ]; then cp "$CC_FAKE_FLUSH_TO" "$CC_FAKE_SCREEN"
                  else printf '\xe2\x9d\xaf\xc2\xa0\n' > "$CC_FAKE_SCREEN"; fi
                fi; } ;; esac ;;
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
# queued-state fixtures — byte-exact from the 2026-08-23 live probe (own tab, 45 frames/s across an
# idle → send → queued transition). The box holds the HINT, drawn with the ordinary prompt prefix
# and an ASCII space (NOT the NBSP placeholder), and for the first ~0.8s NO working indicator is on
# screen (frame s0003) — the indicator only renders later (s0040). scr-queued-nospin is therefore
# the fixture that matters: it is the state the busy fast-path cannot see and the state the
# 2026-08-22 23:16 breadcrumb caught ("matched line: \"Press up to edit queued messages\"").
QH='Press up to edit queued messages'
{ echo "$R20"; printf '%s %s\n' "$P" "$QH"; echo "$R20"; echo "  status"; } > "$FS/scr-queued-nospin"
{ spun "$SP"; echo "$R20"; printf '%s %s\n' "$P" "$QH"; echo "$R20"; }      > "$FS/scr-queued-spin"
# true-parked fixtures — the 2026-08-22 TRUE positive, pressed to its real shape: a ~1100-char
# multi-line message of which only the first screen-width chunk reached the box, three Enters never
# submitted it, and the process sat at 0.7% CPU (so: no working indicator either). A short toy draft
# would pass these assertions for the wrong reason; the two adversarial ones sit right on the
# start-anchor boundary — a draft that CONTAINS the hint, and one that starts with a PREFIX of it.
PLONG='打回清单 · 只有第一屏宽进了输入框:'
for _i in 1 2 3 4 5 6 7 8; do PLONG="$PLONG 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"; done
printf '%s%s%s\n' "$P" "$NB" "$PLONG"                              > "$FS/scr-parked-long"
printf '%s%s%s\n' "$P" "$NB" "看第三行 $QH 那句"                    > "$FS/scr-parked-contains"
printf '%s%s%s\n' "$P" "$NB" 'Press up to edit the deploy plan'    > "$FS/scr-parked-prefix"
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
# 6e) queued-message state (2026-08-23): the input box holds the QUEUED-MESSAGE HINT, not a draft.
# That is a DELIVERED end state — the empty-path twin of the busy fast-path — and reporting it as
# parked is the false alarm of 2026-08-22 23:16 (a re-send would duplicate the message). Both sides
# are asserted here: the queued state must go quiet, and the TRUE parked positives must stay loud.
# ── queued side ──
# (A) the live false positive verbatim: gate sees an EMPTY box → sends → the target was idle and the
# send itself made it work, so the box comes back holding the hint with NO working indicator yet.
csend_reset "$FS/scr-full-empty"
CC_FAKE_ON_SEND="$FS/scr-queued-nospin" CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "queued after send" >"$FS/out" 2>&1; rcs=$?
eq "queued verify rc0"           "$rcs" "0"
eq "queued verify says queued"   "$(grep -cF '(queued' "$FS/out")" "1"
eq "queued verify no park msg"   "$(grep -c '✗ cc-send: sent' "$FS/out")" "0"
eq "queued verify no Enter retry" "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG")" "1"
eq "queued verify no crumb"      "$([ -f "$FL" ] && echo yes || echo no)" "no"
# (B) gate side: the hint is already up when cc-send arrives and the working indicator is NOT (the
# ~0.8s lag) — the busy fast-path cannot see it, so the queued verdict has to take the same exit.
# CC_SEND_TIMEOUT/CC_FAKE_CLEAR_AT are the safety net: a regression degrades to hold→clear→send and
# the "(queued" assert catches it instead of hanging.
csend_reset "$FS/scr-queued-nospin"
CC_SEND_TIMEOUT=1 CC_FAKE_CLEAR_AT=4 CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "queued at gate" >"$FS/out" 2>&1; rcs=$?
eq "queued gate rc0"             "$rcs" "0"
eq "queued gate sends now"       "$(grep -cF 'queued at gate' "$CC_FAKE_LOG")" "1"
eq "queued gate says queued"     "$(grep -cF '(queued' "$FS/out")" "1"
eq "queued gate no notify"       "$(grep -c 'NOTIFY|' "$CC_FAKE_LOG")" "0"
eq "queued gate one Enter"       "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG")" "1"
eq "queued gate no crumb"        "$([ -f "$FL" ] && echo yes || echo no)" "no"
# with the indicator on screen the busy fast-path wins first — same exit, asserted so the two
# paths can never disagree about what a queued box means
csend_reset "$FS/scr-queued-spin"
CC_SEND_TIMEOUT=1 CC_FAKE_CLEAR_AT=4 CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "queued with spinner" >"$FS/out" 2>&1
eq "queued+spinner says queued"  "$(grep -cF '(queued' "$FS/out")" "1"
eq "queued+spinner no crumb"     "$([ -f "$FL" ] && echo yes || echo no)" "no"
# (C) the ONE Enter retry submits a genuinely parked draft into a target that is working by then →
# the second re-read shows the hint. Delivered, not parked.
csend_reset "$FS/scr-full-empty"
CC_FAKE_ON_SEND="$FS/scr-parked" CC_FAKE_FLUSH_AT=2 CC_FAKE_FLUSH_TO="$FS/scr-queued-nospin" \
  CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "retry into queue" >"$FS/out" 2>&1; rcs=$?
eq "retry→queued rc0"            "$rcs" "0"
eq "retry→queued says queued"    "$(grep -cF '(queued' "$FS/out")" "1"
eq "retry→queued one retry"      "$(grep -c 'KEY|.*Enter' "$CC_FAKE_LOG")" "2"
eq "retry→queued no crumb"       "$([ -f "$FL" ] && echo yes || echo no)" "no"
# ── true-parked side: none of the above may buy silence for a real park ──
# (D) the 2026-08-22 true positive's own shape: one screen width of a long multi-line message stuck
# in the box, no working indicator, Enter swallowed twice
csend_reset "$FS/scr-full-empty"
CC_FAKE_ON_SEND="$FS/scr-parked-long" CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "long park" >"$FS/out" 2>&1; rcs=$?
eq "long park rc1"               "$rcs" "1"
eq "long park loud msg"          "$(grep -c '✗ cc-send: sent' "$FS/out")" "1"
eq "long park no success line"   "$(grep -c '✔ cc-send: delivered' "$FS/out")" "0"
eq "long park crumbs"            "$(grep -c 'parked after send' "$FL" 2>/dev/null)" "1"
# (E)/(F) the start-anchor boundary: a draft that CONTAINS the hint, and one that starts with a
# PREFIX of it, are drafts — matching them anywhere but at the start of the rest would go silent
csend_reset "$FS/scr-full-empty"
CC_FAKE_ON_SEND="$FS/scr-parked-contains" CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "contains hint" >"$FS/out" 2>&1; rcs=$?
eq "park containing hint rc1"    "$rcs" "1"
eq "park containing hint crumbs" "$(grep -c 'parked after send' "$FL" 2>/dev/null)" "1"
csend_reset "$FS/scr-full-empty"
CC_FAKE_ON_SEND="$FS/scr-parked-prefix" CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "prefix hint" >"$FS/out" 2>&1; rcs=$?
eq "park on hint prefix rc1"     "$rcs" "1"
eq "park on hint prefix crumbs"  "$(grep -c 'parked after send' "$FL" 2>/dev/null)" "1"
# (G) CC_SEND_QUEUED_PATTERNS REPLACES the default (no union) and SKIPS empty entries. The empty
# entry is the dangerous one: an empty ERE matches every rest, so a parked draft would read
# "queued" and every true positive would go silent — the exact failure this knob must not have.
csend_reset "$FS/scr-full-empty"
CC_FAKE_ON_SEND="$FS/scr-parked-long" CC_SEND_QUEUED_PATTERNS=':' CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "empty entry park" >"$FS/out" 2>&1; rcs=$?
eq "queued empty-entry skipped"  "$rcs" "1"
eq "queued empty-entry crumbs"   "$(grep -c 'parked after send' "$FL" 2>/dev/null)" "1"
csend_reset "$FS/scr-full-empty"
CC_FAKE_ON_SEND="$FS/scr-queued-nospin" CC_SEND_QUEUED_PATTERNS='^No such hint' CC_SEND_FAILLOG="$FL" \
  bash "$CC/cc-dispatch.sh" send surface:1 "queued override" >"$FS/out" 2>&1; rcs=$?
eq "queued override replaces"    "$rcs" "1"
eq "queued override no queued"   "$(grep -cF '(queued' "$FS/out")" "0"
csend_reset "$FS/scr-full-empty"
CC_FAKE_ON_SEND="$FS/scr-parked-prefix" CC_SEND_QUEUED_PATTERNS='^Press up to edit the deploy' \
  CC_SEND_FAILLOG="$FL" bash "$CC/cc-dispatch.sh" send surface:1 "queued custom" >"$FS/out" 2>&1; rcs=$?
eq "queued override matches new" "$rcs" "0"
eq "queued override says queued"  "$(grep -cF '(queued' "$FS/out")" "1"
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
cc_sandbox_ledgers

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
DB_17="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
printf '2026-01-01 00:00:01\tfeat/R2\tsurface:8\t%s\tsurface:1\tD2 older\tmain\tuuid=%s:provider=anthropic:pm=auto:csuuid=%s:suuid=%s:model=m1\n' "$D2" "$SESS2" "$CSU17R" "$OLDS17"  | st_seed tasks "$DB_17"
printf '2026-01-01 00:00:02\tfeat/R1\tsurface:9\t%s\tsurface:1\tD1 kimi task\tmain\tuuid=%s:provider=kimi:pm=plan:model=glm-4.6\n' "$D1" "$U1" | st_append tasks "$DB_17"
printf '2026-01-01 00:00:03\tfeat/R2\tsurface:9\t%s\tsurface:1\tD2 plain task\tmain\tuuid=%s:provider=anthropic:pm=auto:csuuid=%s:suuid=%s:model=m1\n' "$D2" "$SESS2" "$CSU17R" "$OLDS17" | st_append tasks "$DB_17"
printf '2026-01-01 00:00:04\tfeat/R3\tsurface:10\t%s\tsurface:1\tD3 old row\tmain\n' "$D3" | st_append tasks "$DB_17"
printf '2026-01-01 00:00:05\tfeat/R4\tsurface:11\t%s/gone\tsurface:1\tdead dir row\tmain\tuuid=%s:provider=kimi:pm=auto\n' "$REPO17" "$U1" | st_append tasks "$DB_17"
printf '2026-01-01 00:00:06\tfeat/R5\tsurface:12\t%s\tsurface:1\tforeign repo row\tmain\tuuid=%s:provider=glm:pm=auto\n' "$OTH17" "$U4" | st_append tasks "$DB_17"
printf '%s\tblocked\t%s\n' "$D1" 100 |  st_seed status "$DB_17"
printf '%s\tidle\t%s\n'    "$D2" 100 | st_append status "$DB_17"
# D 期：状态是任务行上的列 —— 「无关的 sidecar 行」就是「一条带状态的无关任务行」
printf '2026-01-01 00:00:07\tfeat/UN\tsurface:19\t%s\tsurface:1\tunrelated row\tmain\n' "$UNREL17" | st_append tasks "$DB_17"
printf '%s\tidle\t%s\n'    "$UNREL17" 100 | st_append status "$DB_17"
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
  ( cd "$REPO17" && env HOME="$FH17" PATH="$RF:$OP17" CC_STATE_DB="$DB_17" \
      CC_CMUX_SESSIONS="$RF/store.json" CC_RESUME_SETTLE=0 CC_SEND_VERIFY_SEC=0.1 \
      CC_SEND_FAILLOG="$RF/fail" CC_FAKE_LIVE="$RF/live" bash "$CC/cc-dispatch.sh" resume "$@" )
}
# A) default run, confirmed: D2 restored natively (store uuid → live surface:55), D1 reopened
# with the EXACT recorded cld command, D3 degraded to idle, foreign/dead rows untouched
: > "$CC_FAKE_LOG"
ROUT="$(printf 'y\n' | renv17 2>&1)"; rrc=$?
eq "resume exit0"            "$rrc" "0"
eq "native restore invoked"  "$(grep -c 'RESTORE-SESSION' "$CC_FAKE_LOG")" "1"
# (Task 8b) D2 owns TWO rows and set-ref must rewrite EVERY one of them, so these read the raw
# store through `dump tasks`: the `sort -u` collapsing to a single value IS the assertion, and
# task-get returns only the dir's NEWEST row — it would stay green with the older row still
# carrying its pre-crash ref (mutation-proved: see the Task 8b report's red/green table).
eq "restored row ref refreshed" "$(CC_STATE_DB="$DB_17" "$CC/cc-state" dump tasks | awk -F'\t' -v d="$D2" '$4==d{print $3}' | sort -u)" "surface:55"
eq "ALL rows of dir refreshed"  "$(CC_STATE_DB="$DB_17" "$CC/cc-state" dump tasks | awk -F'\t' -v d="$D2" '$4==d{print $3}' | wc -l | tr -d ' ')" "2"
# a restored tab is a NEW surface: the recorded suuid must track it, or the close gate would go on
# comparing against a dead uuid (and refuse the parent its own child forever)
eq "suuid refreshed on restore" "$(CC_STATE_DB="$DB_17" "$CC/cc-state" dump tasks | awk -F'\t' -v d="$D2" '$4==d{print $8}' | sort -u)" \
                                "uuid=$SESS2:provider=anthropic:pm=auto:csuuid=$CSU17R:suuid=$SURF2:model=m1"
eq "stale suuid is gone"        "$(CC_STATE_DB="$DB_17" "$CC/cc-state" dump tasks | grep -cF "$OLDS17")" "0"
eq "csuuid survived the rewrite" "$(CC_STATE_DB="$DB_17" "$CC/cc-state" dump tasks | awk -F'\t' -v d="$D2" '$4==d{print ($8 ~ /:csuuid=/)?"y":"n"}' | sort -u)" "y"
eq "model still LAST after rewrite" "$(CC_STATE_DB="$DB_17" "$CC/cc-state" dump tasks | awk -F'\t' -v d="$D2" '$4==d{print ($8 ~ /:model=m1$/)?"y":"n"}' | sort -u)" "y"
eq "reopened exact cld cmd"  "$(grep -cF "cld kimi --resume $U1 --permission-mode plan --model glm-4.6" "$CC_FAKE_LOG")" "1"
eq "reopen dir VERBATIM"     "$(grep "NEWSURF" "$CC_FAKE_LOG" | grep -cF -- "--working-directory $D1")" "1"
eq "idle degrade bare ccteam" "$(grep -cE "^SEND\|--surface surface:[0-9]+ ccteam$" "$CC_FAKE_LOG")" "1"
eq "listing shows idle note" "$(echo "$ROUT" | grep -c 'no recorded session')" "1"
eq "listing header"          "$(echo "$ROUT" | grep -c 'BRANCH')" "1"
# "no board row appended" COUNTS the dir's rows — task-get always prints exactly one, so it
# would be green next to a duplicate row: raw read. The ref value below is a per-row question.
eq "no board row appended"   "$(CC_STATE_DB="$DB_17" "$CC/cc-state" dump tasks | awk -F'\t' -v d="$D1" '$4==d' | wc -l | tr -d ' ')" "1"
eq "reopen ref recorded"     "$(CC_STATE_DB="$DB_17" "$CC/cc-state" task-get "$D1" | awk -F'\t' '{print $3}')" \
                             "$(grep -F -- "--working-directory $D1" "$CC_FAKE_LOG" | grep -oE 'surface:[0-9]+' | head -1)"
# the sidecar has no per-dir question verb; these are clear/keep side effects → raw dump status
eq "stale status D1 cleared" "$(CC_STATE_DB="$DB_17" "$CC/cc-state" dump status | grep -cF "$D1")" "0"
eq "stale status D2 cleared" "$(CC_STATE_DB="$DB_17" "$CC/cc-state" dump status | grep -cF "$D2")" "0"
eq "unrelated status kept"   "$(CC_STATE_DB="$DB_17" "$CC/cc-state" dump status | grep -cF "$UNREL17")" "1"
eq "foreign row not touched" "$(grep -cF -- "--working-directory $OTH17" "$CC_FAKE_LOG")" "0"
eq "exactly 2 tabs opened"   "$(grep -c 'NEWSURF' "$CC_FAKE_LOG")" "2"
eq "dead dir never opened"   "$(grep -cF -- "--working-directory $REPO17/gone" "$CC_FAKE_LOG")" "0"
# B) declined confirm: nothing reopens (native restores above stand), rc 1, refs untouched
: > "$CC_FAKE_LOG"
BREF="$(CC_STATE_DB="$DB_17" "$CC/cc-state" task-get "$D1" | awk -F'\t' '{print $3}')"
ROUT="$(printf 'n\n' | renv17 2>&1)"; rrc=$?
eq "decline exit1"           "$rrc" "1"
eq "decline opens nothing"   "$(grep -c 'NEWSURF' "$CC_FAKE_LOG")" "0"
eq "decline keeps refs"      "$(CC_STATE_DB="$DB_17" "$CC/cc-state" task-get "$D1" | awk -F'\t' '{print $3}')" "$BREF"
# B2) immediate re-run on the SAME dirs must not be eaten by the 120s dedup marker (resume mode
# skips it) — the marker from run A is minutes fresh here
: > "$CC_FAKE_LOG"
ROUT="$(printf 'y\n' | renv17 2>&1)"; rrc=$?
eq "re-run not marker-blocked" "$(grep -c 'NEWSURF' "$CC_FAKE_LOG")" "2"
# C) repo filter vs --all: a board holding ONLY a foreign-repo row
TF17C=$(mktemp -u); printf '2026-01-01 00:00:01\tfeat/C1\tsurface:70\t%s\tsurface:1\tforeign only\tmain\tuuid=%s:provider=glm:pm=auto\n' "$OTH17" "$U4" | st_seed tasks "$DB_17"
: > "$CC_FAKE_LOG"
ROUT="$(printf 'y\n' | ( cd "$REPO17" && env HOME="$FH17" PATH="$RF:$OP17" CC_STATE_DB="$DB_17" \
      CC_CMUX_SESSIONS="$RF/store.json" CC_RESUME_SETTLE=0 CC_SEND_FAILLOG="$RF/fail" CC_FAKE_LIVE="$RF/live" \
      bash "$CC/cc-dispatch.sh" resume) 2>&1)"; rrc=$?
eq "filter: nothing in repo" "$rrc" "0"
eq "filter says try --all"   "$(echo "$ROUT" | grep -c 'no resumable board rows')" "1"
eq "filter opens nothing"    "$(grep -c 'NEWSURF' "$CC_FAKE_LOG")" "0"
ROUT="$(printf 'y\n' | ( cd "$REPO17" && env HOME="$FH17" PATH="$RF:$OP17" CC_STATE_DB="$DB_17" \
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
env HOME="$FH17" PATH="$RF:$OP17" CC_STATE_DB="$DB_17" CC_SEND_FAILLOG="$RF/fail" \
  CC_SEND_VERIFY_SEC=0.1 CC_LAUNCH_FILE="$RF/launch" CC_WT_PERMISSION_MODE=plan CC_WT_MODEL='glm-4.6[1m]' \
  CC_CALLER_SURFACE_UUID="$CSU17" \
  bash "$CC/cc-dispatch.sh" surface "$D0" "mint test brief" >/dev/null 2>&1
MINT="$(grep -oE -- '--session-id [0-9a-f-]+' "$CC_FAKE_LOG" | head -1 | cut -d' ' -f2)"
eq "surface mints a uuid"    "$(printf '%s' "$MINT" | grep -cE '^[0-9a-f-]{30,}$')" "1"
eq "minted id on launch"     "$(grep -cF -- "ccteam --session-id $MINT --permission-mode plan --model glm-4.6[1m]" "$CC_FAKE_LOG")" "1"
# (Task 8b) the dispatch row of ONE dir → task-get, the verb for that exact question; the field
# count reads off the returned row unchanged. task-get collapses to the dir's NEWEST row, which
# is exact here (D0/D0B are each dispatched once); "how many rows does a dir have" is a separate
# question and stays on the raw read, above ("no board row appended").
eq "minted id on log row"    "$(CC_STATE_DB="$DB_17" "$CC/cc-state" task-get "$D0" | awk -F'\t' '{print $8}')" "uuid=$MINT:provider=anthropic:pm=plan:csuuid=$CSU17:model=glm-4.6[1m]"
eq "mint row has 8 fields"   "$(CC_STATE_DB="$DB_17" "$CC/cc-state" task-get "$D0" | awk -F'\t' '{print NF}')" "8"
D0B="$(cn17 "$(mktemp -d)")"
: > "$CC_FAKE_LOG"
env HOME="$FH17" PATH="$RF:$OP17" CC_STATE_DB="$DB_17" CC_SEND_FAILLOG="$RF/fail" \
  CC_SEND_VERIFY_SEC=0.1 CC_LAUNCH_FILE="$RF/launch" CC_WT_MODEL='bad model;rm -rf' \
  bash "$CC/cc-dispatch.sh" surface "$D0B" "model guard" >/dev/null 2>&1
eq "bad model never launched" "$(grep -c -- '--model' "$CC_FAKE_LOG")" "0"
eq "bad model not recorded"   "$(CC_STATE_DB="$DB_17" "$CC/cc-state" task-get "$D0B" | awk -F'\t' '{print ($8 ~ /model=/)?"bad":"ok"}')" "ok"
rm -rf "$RF" "$FH17" "$REPO17" "$OTH17" "$UNREL17" "$D0" "$D0B"; rm -f "$TF17" "$SF17" "$TF17C" "$TF17D"
# fresh-mode surface leaves dedup markers in the real TMPDIR (hash-keyed, contentless) — sweep ours
unstamp "$DB_17"
unset CC_FAKE_LOG CC_FAKE_SCREEN

echo ""
echo "== 32. cc-state facade (Phase A: one lock, one access path, TSV backend) =="
DB_32="$(mktemp -u).db"   # this section's library
# The facade's contract under test (docs/state-model-plan.md Task 1–3): every verb's bytes on disk
# are EXACTLY what today's hand-rolled awk/mkdir-lock code produces — same sanitization, same
# fallbacks, same empty-set-deletes-file behaviour — so the round-2 lines can swap callers without
# any observable change. mktemp everywhere (a worktree tests itself, siblings run in parallel).
# §32's job is to pin the FORMAT: the frozen log oracle, the 7-field round-trips, the 8/9-field
# layouts, the sidecar row shape. That used to be done by reading the store FILE, on the
# argument that reading through the facade would make the facade vouch for itself. The engine
# swap removed the file, so the argument has to be re-made rather than re-cited: what keeps
# this section honest now is that its EXPECTATIONS are independent artifacts — the frozen
# F32OR literals recorded from the writer this facade replaced, and (below) the legacy TSV as
# it was on disk before migration touched it. Comparing dump against those is not comparing
# cc-state with cc-state.
S32=$(mktemp -d); export CC_STATE_DB="$S32/cc-state.db"
# dump used to be a raw byte passthrough of the store file, so "byte-identical" compared it to
# `cat`. There is no file to cat; what dump has to reproduce now is the legacy TSV it IMPORTED,
# and the migration keeps that file (renamed, never deleted) which makes it a perfectly good
# independent expectation — bytes written by a printf, not by the facade.
printf '2026-01-01 00:00:00\tfeat/x\tsurface:1\t/d/x\tsurface:9\tdo x\tcamp\tuuid=u1\n' > "$S32/worktree-tasks.tsv"
cp "$S32/worktree-tasks.tsv" "$S32/pre-migration"
"$CC/cc-state" dump tasks >/dev/null            # first open imports and renames the TSV aside
eq "32 dump rebuilds the imported bytes exactly" \
  "$("$CC/cc-state" dump tasks | od -An -c | tr -d ' \n')" "$(od -An -c "$S32/pre-migration" | tr -d ' \n')"
eq "32 the legacy file was renamed, not deleted" "$(ls "$S32"/worktree-tasks.tsv.migrated.* 2>/dev/null | wc -l | tr -d ' ')" "1"
eq "32 ...and the renamed copy still holds the original bytes" \
  "$(cmp -s "$S32"/worktree-tasks.tsv.migrated.* "$S32/pre-migration" && echo same || echo differ)" "same"
eq "32 dump of an empty store is empty" "$("$CC/cc-state" dump tabs)" ""
# A final line with NO newline: still a row, and the rebuild supplies the newline. That second
# half is the ONE deliberate deviation the engine adds to dump's byte contract — state-model
# §3.5 #10. It is asserted, not tolerated, so it cannot happen again unnoticed.
# NB: a FRESH library. Migration imports a legacy TSV only when the library does not exist
# yet, so this fixture cannot reuse the section's — that one was created by the import above.
S32NL=$(mktemp -d); printf 'a\tb' > "$S32NL/opened-tabs.tsv"
nl32(){ env CC_STATE_DB="$S32NL/cc-state.db" "$CC/cc-state" "$@"; }
eq "32 a newline-less final row is still a row"  "$(nl32 dump tabs)" "$(printf 'a\tb')"
eq "32 ...and the rebuild supplies the newline (deviation 10)" \
  "$(nl32 dump tabs | tail -c 1 | od -An -tx1 -v | tr -d ' \n')" "0a"
rm -rf "$S32NL"
# ... and the same row reaches the VERBS as a row, not chaff — a reader that dropped it would
# turn the next rewrite into data loss
S32X=$(mktemp -d); printf '2026-01-01 00:00:00\tfeat/nt\tsurface:1\t/d/nt\tc\trow sans newline\tcamp\t' > "$S32X/worktree-tasks.tsv"
eq "32 no-trailing-newline row is still a row" \
  "$(CC_STATE_DB="$S32X/cc-state.db" "$CC/cc-state" task-get /d/nt | cut -f2)" "feat/nt"
rm -rf "$S32X"
# The four mkdir-lock assertions that stood here are GONE, not moved: there is no lock to hold,
# reclaim or wait on. Deleting real assertions in exchange for a structural grep is how a suite
# quietly loses coverage, so their replacement (§39) was run against the PRE-SWAP code first and
# confirmed RED — six of seven lines, including the behavioural one. See the C2b report.

# ── Task 2: the tasks-store verbs (byte contract of the retired cc-board.sh log —
# frozen as the oracle below — / cc-hooks.sh status / the worktree.zsh rewriters /
# cc-dispatch.sh's $TMPDIR marker) ──────────
S32B=$(mktemp -d); export CC_STATE_DB="$S32B/cc-state.db"
# task-add / task-get: the placeholder row is exactly the retired cc-board.sh log's
# row (see the frozen oracle below) with caller+largs left empty for task-set-launch
# to fill at the end of the dispatch
"$CC/cc-state" task-add /d/y feat/y surface:2 'do y' camp
eq "32 task-add appends"        "$("$CC/cc-state" task-get /d/y | cut -f2)" "feat/y"
eq "32 task-add 8 fields"       "$("$CC/cc-state" task-get /d/y | awk -F'\t' '{print NF}')" "8"
eq "32 placeholder caller+largs empty" "$("$CC/cc-state" task-get /d/y | awk -F'\t' '{print $5"|"$8}')" "|"
"$CC/cc-state" task-get /d/nope >/dev/null 2>&1; eq "32 task-get miss rc1" "$?" "1"
# D2b (§3.1 "dir 做主键就吃掉了 newest-per-dir 去重"): the LIVE store holds ONE row per dir —
# a re-dispatch REPLACES that dir's row instead of stacking a second one. Enforced at every
# write the PRODUCT makes; `load` deliberately stays the raw byte footgun it was designed as,
# so a hand-written or migrated duplicate is still expressible and task-prune --compact still
# has a job. (A UNIQUE index on the raw string was the other candidate and is the wrong tool:
# it cannot express the actual rule — dir_match, not string equality — and it would take
# `load`'s contract with it. See docs/state-model-d-plan.md §8.)
S32AD=$(mktemp -d); D32AD="$(cd "$S32AD" && pwd -P)/wt"; mkdir -p "$D32AD"
DB32AD="$S32AD/cc-state.db"
ad32(){ env CC_STATE_DB="$DB32AD" "$CC/cc-state" "$@"; }
ad32 task-add "$D32AD" feat/first s:1 'first dispatch' main
ad32 task-set-state "$D32AD" working
ad32 task-mark-opened "$D32AD"
ad32 task-add "$D32AD" feat/second s:2 'second dispatch' main
eq "32 a re-dispatch replaces the dir's row" "$(ad32 dump tasks | wc -l | tr -d ' ')" "1"
eq "32 ...and the surviving row is the NEW one" "$(ad32 dump tasks | cut -f2)" "feat/second"
# the two columns that live OUTSIDE the line are keyed to the DIR, not to the row — they were a
# sidecar file and a $TMPDIR marker keyed by dir before they were columns, and replacing the row
# under them must not lose that. _put's carry/restore already does it; this is what says so.
eq "32 ...the dir's state survived the replace" "$(ad32 dump status | cut -f2)" "working"
ad32 task-opened-recently "$D32AD" 120; eq "32 ...and so did the tab-opened stamp" "$?" "0"
# matching is dir_match, NOT string equality: a legacy row holding the LOGICAL /var form names
# the same worktree as the canonical /private/var one task-add writes, and a re-dispatch that
# left both would put two rows for one worktree back on the board — defect 3 all over again.
V32AD=$(mktemp -d); P32AD="$(cd "$V32AD" && pwd -P)"
printf '2026-01-01 00:00:01\tfeat/legacy\ts:1\t%s\tc\tlogical row\tmain\tu\n' "$V32AD" | st_seed tasks "$DB32AD"
ad32 task-add "$P32AD" feat/again s:3 'same worktree' main
eq "32 a logical-path row is replaced too" "$(ad32 dump tasks | wc -l | tr -d ' ')" "1"
eq "32 ...by the canonical row"            "$(ad32 dump tasks | cut -f2)" "feat/again"
# and a DIFFERENT dir is untouched — without this the replace could just be "task-add clears
# the store", which passes every assertion above
ad32 task-add "$D32AD/other" feat/other s:4 'another dir' main
eq "32 ...while another dir keeps its own row" "$(ad32 dump tasks | wc -l | tr -d ' ')" "2"
rm -rf "$S32AD" "$V32AD"
"$CC/cc-state" task-set-launch /d/y surface:9 'uuid=u2:pm=auto'
eq "32 set-launch fills field 8" "$("$CC/cc-state" task-get /d/y | cut -f8)" "uuid=u2:pm=auto"
eq "32 set-launch fills field 5" "$("$CC/cc-state" task-get /d/y | cut -f5)" "surface:9"
# H1 byte oracle, FROZEN (Task 9): cc-board.sh log — the writer this facade replaced —
# had no production caller left and was deleted, so these expected values are its
# RECORDED output at commit 3edabd17890825a8d6fec59c3072ffa0cf9bcbb1 (2026-08-23) for
# exactly the inputs below. They are LITERALS, never computed: the oracle needs a
# reference INDEPENDENT of the facade under test — deriving the expectation from
# sanitization code of our own would compare the facade with itself, always green,
# proving nothing (the class of failure this section exists to catch). Field 1 is the
# wall-clock timestamp and is excluded; $2..$8 are frozen field for field. CHANGING
# THESE BYTES IS NOT FIXING A TEST: it means the on-disk row format changed — a
# docs/state-model.md byte-contract change that must land in the same commit.
# The task/largs texts are deliberately LONGER than the 140/200 cut lines so the
# truncation itself is inside the compared bytes (round-2 B6: an oracle fixture that
# never crosses the boundary proved nothing when the cap was mutated).
LONGOR="$(printf 'or	task|test ')$(python3 -c 'print("x"*250)')"
LONGOR2="$(printf 'uuid=o1:pm=auto	model ')$(python3 -c 'print("y"*250)')"
F32OR1='?|s:5|/d/oracle|c:9|or task/test xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx|feat/or|uuid=o1:pm=auto model yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy'
flds32='{print $2"|"$3"|"$4"|"$5"|"$6"|"$7"|"$8}'
"$CC/cc-state" task-add /d/oracle '' s:5 "$LONGOR" feat/or
"$CC/cc-state" task-set-launch /d/oracle c:9 "$LONGOR2"
# no NR guard, and no tail -2 dance any more (round-2 B6: `NR>1` on one-line input made
# both sides empty and the assertion vacuous; the log-side row it used to tail off is
# gone, so the facade row is compared straight against the frozen literal)
eq "32 facade writes the frozen log bytes (sanitize + both cuts)" \
  "$("$CC/cc-state" dump tasks | tail -1 | awk -F'\t' "$flds32")" "$F32OR1"
# B7: the retired log's ref="${2:-?}" — an empty surface ref became '?'; task-add
# replicates it (ref or "?"). Same provenance as F32OR1.
F32OR2='?|?|/d/oref|c:9|ref fallback|feat/or2|uuid=o2'
"$CC/cc-state" task-add /d/oref '' '' "ref fallback" feat/or2
"$CC/cc-state" task-set-launch /d/oref c:9 "uuid=o2"
eq "32 empty ref falls back to ? (frozen)" \
  "$("$CC/cc-state" dump tasks | tail -1 | awk -F'\t' "$flds32")" "$F32OR2"
# ── migrated from §2 (log's own section, retired with it in Task 9) ────────────────────
# §2 tested the log ENTRY POINT. Its assertions that tested still-live behaviour moved
# here in facade form; the rest died with the entry. Classification (full table in the
# Task 9 gate report): "7th field is parent" / "8th field is launch-args" / "task
# sanitized" / "launch-args sanitized" are SUBSUMED by the frozen F32OR1 (it pins $2..$8
# byte for byte, TAB and | inside the compared bytes); the three groups below carry what
# the frozen oracle does not: the full two-verb write's field count, the write→render
# agreement across the cc-state → cc-board boundary, and the empty-dir guard the facade
# replicated from log ([ -n "$dir" ] || exit 0 → task-add returns 0, writes nothing).
RT32="$(cd "$(mktemp -d)" && pwd -P)"    # live dir: the sweep inside the render must keep it
RTF32=$(mktemp -u)
CC_STATE_DB="$RTF32.db" "$CC/cc-state" task-add "$RT32" '' surface:2 'round trip task' feat/rt
CC_STATE_DB="$RTF32.db" "$CC/cc-state" task-set-launch "$RT32" surface:1 ''
eq "32 full write keeps 8 fields" "$(st_dump tasks "$RTF32.db" | awk -F'\t' '{print NF}')" "8"
eq "32 facade-written row renders on the board" \
  "$(CC_STATE_DB="$RTF32.db" bash "$CC/cc-board.sh" --all 2>/dev/null | grep -c 'round trip task')" "1"
rm -f "$RTF32"
N32E="$("$CC/cc-state" dump tasks | wc -l | tr -d ' ')"
"$CC/cc-state" task-add '' feat/x s:1 'no dir' p; rc=$?
eq "32 task-add empty dir rc0" "$rc" "0"
eq "32 task-add empty dir writes no row" "$("$CC/cc-state" dump tasks | wc -l | tr -d ' ')" "$N32E"
# H1 fallbacks and truncation
"$CC/cc-state" task-add /d/h3 feat/h3 s:1 "" p3
eq "32 empty task falls back" "$("$CC/cc-state" task-get /d/h3 | cut -f6)" "(idle ccteam, no initial prompt)"
LONG32=$(python3 -c 'print("x"*300)')
"$CC/cc-state" task-set-launch /d/h3 c:1 "$LONG32"
eq "32 largs truncated at 200" "$("$CC/cc-state" task-get /d/h3 | awk -F'\t' '{print length($8)}')" "200"
eq "32 largs keeps pipes (no |→/)" "$("$CC/cc-state" task-set-launch /d/h3 c:1 'a|b' >/dev/null; "$CC/cc-state" task-get /d/h3 | cut -f8)" "a|b"
# task-set-state: the hook's membership rule (no row → silent no-op, rc 0, no byte)
"$CC/cc-state" task-set-state /d/nope working; rc=$?
eq "32 set-state unknown dir rc0" "$rc" "0"
eq "32 set-state unknown dir writes nothing" "$("$CC/cc-state" dump status | wc -c | tr -d ' ')" "0"
"$CC/cc-state" task-set-state /d/y working
eq "32 set-state registered dir" "$("$CC/cc-state" dump status | cut -f2)" "working"
eq "32 sidecar row is dir\\tstate\\tepoch" "$("$CC/cc-state" dump status | awk -F'\t' '$1=="/d/y"{print ($3 ~ /^[0-9]+$/)?"ok":"bad"}')" "ok"
"$CC/cc-state" task-set-state /d/y ready; rc=$?
eq "32 set-state refuses ready rc2" "$rc" "2"
eq "32 sidecar never holds ready" "$("$CC/cc-state" dump status | grep -c ready)" "0"
"$CC/cc-state" task-set-state /d/y idle
eq "32 set-state newest wins" "$("$CC/cc-state" dump status | awk -F'\t' '$1=="/d/y"{print $2}')" "idle"
eq "32 sidecar one row per dir" "$("$CC/cc-state" dump status | wc -l | tr -d ' ')" "1"
# the facade is a public entry: a TAB inside the state value must not split the row
# (today's hook only ever passes a closed set, but nothing enforces that here)
"$CC/cc-state" task-set-state /d/y "$(printf 'wor\tking')"
eq "32 set-state collapses a tab in the value" \
  "$("$CC/cc-state" dump status | awk -F'\t' '$1=="/d/y"{print $2"|"(NF==3?"3f":NF"")}')" "wor king|3f"
# task-set-ref: raw lines must round-trip byte-identically — empty middle fields stay
# empty (the TAB-collapse class), and a 7-field legacy row must NOT gain a field
# (spec §3.5 defect 6: _ccres_setref's $3=r OFS-rebuild was the one exception)
printf '2026-01-01 00:00:00\tfeat/z\tsurface:3\t/d/z\t\tdo z\t\tuuid=u3\n' | st_append tasks
"$CC/cc-state" task-set-ref /d/z surface:33
eq "32 set-ref rewrites field 3" "$("$CC/cc-state" task-get /d/z | cut -f3)" "surface:33"
eq "32 empty fields survive rewrite" "$("$CC/cc-state" task-get /d/z | cut -f8)" "uuid=u3"
eq "32 rewrite keeps field count" "$("$CC/cc-state" task-get /d/z | awk -F'\t' '{print NF}')" "8"
printf '2026-01-01 00:00:00\tfeat/z7\tsurface:4\t/d/z7\tsurface:1\tseven field row\tmain\n' | st_append tasks
"$CC/cc-state" task-set-ref /d/z7 surface:44
eq "32 7-field row keeps 7 fields" "$("$CC/cc-state" task-get /d/z7 | awk -F'\t' '{print NF}')" "7"
# the launch-args suuid swap: existing suuid= replaced in place, model= stays LAST
# (it may itself contain colons — every parser stops there)
"$CC/cc-state" task-add /d/r feat/r s:6 'refresh me' camp
"$CC/cc-state" task-set-launch /d/r c:1 'uuid=u9:pm=auto:csuuid=OLD:suuid=OLDS:model=m.1'
"$CC/cc-state" task-set-ref /d/r surface:66 NEWSUUID-1234
eq "32 set-ref swaps suuid, model last" "$("$CC/cc-state" task-get /d/r | cut -f8)" \
  "uuid=u9:pm=auto:csuuid=OLD:suuid=NEWSUUID-1234:model=m.1"
# task-list: newest-per-dir (canonical key, like the render's SEEN[c]), dead dirs
# skipped at read time (like resume's -d test), newest-first output
D32A="$(cd "$(mktemp -d)" && pwd -P)"; D32B="$(cd "$(mktemp -d)" && pwd -P)"
printf '2026-01-01 00:00:00\tfeat/old\tsurface:2\t%s\tc:1\tfirst gen\tcamp\tuuid=o\n' "$D32A" | st_append tasks
printf '2026-01-02 00:00:00\tfeat/new\tsurface:3\t%s\tc:1\tsecond gen\tcamp\tuuid=n\n' "$D32A" | st_append tasks
printf '2026-01-01 00:00:00\tfeat/other\tsurface:4\t%s\tc:1\tother repo\tcamp\t\n' "$D32B" | st_append tasks
eq "32 task-list newest per dir" "$("$CC/cc-state" task-list | grep -c "$D32A")" "1"
eq "32 task-list keeps the newest row" "$("$CC/cc-state" task-list | grep "$D32A" | cut -f2)" "feat/new"
eq "32 task-list hides dead dirs" "$("$CC/cc-state" task-list | grep -c '/d/')" "0"
eq "32 task-list renders newest-first" "$("$CC/cc-state" task-list | head -1 | cut -f4)" "$D32B"
D32N="$D32A/nested"; mkdir -p "$D32N"
printf '2026-01-01 00:00:00\tfeat/nest\tsurface:5\t%s\tc:1\tnested\tcamp\t\n' "$D32N" | st_append tasks
eq "32 task-list --repo keeps rows under root" "$("$CC/cc-state" task-list --repo "$D32A" | grep -c "$D32N")" "1"
eq "32 task-list --repo drops foreign rows" "$("$CC/cc-state" task-list --repo "$D32A" | grep -c "$D32B")" "0"
# --archive: the archive is a history — every row, file order, no dead-dir skip
printf '2026-01-01 00:00:00\tfeat/done\tsurface:9\t%s\tc:1\tdone task\tcamp\tuuid=d\t1700000000\n' "$D32A" | st_append archive
printf '2026-01-02 00:00:00\tfeat/done\tsurface:9\t%s\tc:1\tdone task 2\tcamp\tuuid=d2\t1700000001\n' "$D32A" | st_append archive
eq "32 task-list --archive keeps every row" "$("$CC/cc-state" task-list --archive | grep -c 'done task')" "2"
# task-drop: raw-dir match (what gwt-rm feeds), and H2 — an emptied store deletes the file
"$CC/cc-state" task-drop "$D32B"
eq "32 task-drop removes the dir's rows" "$("$CC/cc-state" dump tasks | grep -c "$D32B")" "0"
S32C=$(mktemp -d)
CC_STATE_DB="$S32C/cc-state.db" "$CC/cc-state" task-add /d/solo feat/s s:1 solo p
CC_STATE_DB="$S32C/cc-state.db" "$CC/cc-state" task-drop /d/solo
eq "32 empty row set deletes the file" "$([ -f "$S32C/one.tsv" ] && echo yes || echo no)" "no"
rm -rf "$S32C"
# task-prune: sweeps dead-dir rows from the task list AND the sidecar (both real
# callers — board prune-on-read and gwt-prune — always sweep the pair)
LIVE32="$(cd "$(mktemp -d)" && pwd -P)"
printf '2026-01-01 00:00:00\tfeat/live\tsurface:6\t%s\tc:1\tlive row\tcamp\t\n' "$LIVE32" | st_append tasks
printf '%s\tidle\t200\n/d/dead\tworking\t100\n' "$LIVE32" | st_seed status
"$CC/cc-state" task-prune
eq "32 task-prune sweeps dead task rows" "$("$CC/cc-state" dump tasks | grep -c '/d/')" "0"
eq "32 task-prune keeps live task rows" "$("$CC/cc-state" dump tasks | grep -c "$LIVE32")" "1"
eq "32 task-prune sweeps the sidecar too" "$("$CC/cc-state" dump status | grep -c '/d/dead')" "0"
eq "32 task-prune keeps live sidecar rows" "$("$CC/cc-state" dump status | grep -c "$LIVE32")" "1"
# (migrated from §2) a legacy 7-field row is legal in a live store and must survive the
# sweep AS 7 FIELDS — the set-ref pins above prove 7-field survival through a REWRITE,
# not through the prune sweep, and a naive read-loop rewrite of this row shape is the
# TAB-collapse hazard class this store was built never to commit
printf '2026-01-01 00:00:00\tfeat/OLD7\tsurface:7\t%s\tsurface:1\told row task\tmain\n' "$LIVE32" | st_append tasks
"$CC/cc-state" task-prune
eq "32 7-field row survives the sweep as 7 fields" "$("$CC/cc-state" dump tasks | awk -F'\t' '$2=="feat/OLD7"{print NF}')" "7"
eq "32 7-field row still renders" "$(bash "$CC/cc-board.sh" --all 2>/dev/null | grep -c 'old row task')" "1"
# task-archive: row verbatim + merged-at (8→9 fields), moved dirs on stdout, sidecar
# rows of the moved dirs swept (the _gwt_archive_branch contract)
"$CC/cc-state" task-set-state "$D32A" blocked          # the moved dir gets a sidecar row
moved="$("$CC/cc-state" task-archive feat/new trunk)"
eq "32 archive returns moved dirs" "$moved" "$D32A"
eq "32 archive row keeps fields verbatim" "$("$CC/cc-state" dump archive | grep 'feat/new' | tail -1 | cut -f6)" "second gen"
eq "32 archive appends merged-at + merged-into (10 fields)" "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/new"{print NF}' | tail -1)" "10"
eq "32 archive merged-at stays the 9th field" "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/new"{print ($9 ~ /^[0-9]+$/)?"ok":"no"}' | tail -1)" "ok"
eq "32 archive records where it merged into"  "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/new"{print $10}' | tail -1)" "trunk"
eq "32 archive moves rows out of tasks" "$("$CC/cc-state" dump tasks | grep -c 'feat/new')" "0"
eq "32 archive sweeps the sidecar for moved dirs" "$("$CC/cc-state" dump status | grep -c "$D32A")" "0"
eq "32 archive keeps other sidecar rows" "$("$CC/cc-state" dump status | grep -c "$LIVE32")" "1"
# an EMPTY <merged-into> must leave the row exactly as it always was: 9 fields, merged-at
# last. The field is appended ONLY when there is something to record — which is what keeps
# every frozen archive fixture (and the shim's own no-target callers) byte-identical.
printf '2026-01-01 00:00:09\tfeat/mi0\ts:9\t%s\tc\tno target\tmain\tu\n' "$D32A" | st_append tasks
"$CC/cc-state" task-archive feat/mi0 "" >/dev/null
eq "32 empty merged-into appends nothing"       "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/mi0"{print NF}')" "9"
eq "32 empty merged-into leaves merged-at last" "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/mi0"{print ($NF ~ /^[0-9]+$/)?"ok":"no"}')" "ok"
# and a <merged-into> carrying a TAB must not forge a 11th field — same _sanitize_field rule
# every other caller-supplied string goes through
printf '2026-01-01 00:00:10\tfeat/mi1\ts:9\t%s\tc\ttabby target\tmain\tu\n' "$D32A" | st_append tasks
"$CC/cc-state" task-archive feat/mi1 "$(printf 'a\tb')" >/dev/null
eq "32 merged-into cannot forge a field"        "$("$CC/cc-state" dump archive | awk -F'\t' '$2=="feat/mi1"{print NF":"$10}')" "10:a b"
mo32(){ python3 -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
r=[x for (x,) in c.execute("SELECT tab_opened_ts FROM tasks") if x is not None]
print("set" if r else "none")' "$CC_STATE_DB"; }
# the dedup timestamp says "a tab actually opened", so task-add must NOT stamp it (a failed
# dispatch must leave no blocking stamp — B5); task-mark-opened does. D 期起它是 tasks 上的
# tab_opened_ts 列,不再是 $TMPDIR 里那个以 dir 的 sha1 命名的文件 —— 于是 TMPDIR 不再参与,
# 而「shasum 不可用 → 哈希为空 → 标记指向目录本身 → 120 秒内吞掉所有派发」那条静默失败
# 路径随之消失(整数列没有空键)。
"$CC/cc-state" task-add /d/m1 feat/m s:1 marker p
eq "32 task-add does not stamp the timestamp" "$(mo32)" "none"
"$CC/cc-state" task-opened-recently /d/m1 120; eq "32 opened-recently false before mark" "$?" "1"
"$CC/cc-state" task-mark-opened /d/m1; eq "32 mark-opened rc0" "$?" "0"
eq "32 mark-opened writes the timestamp" "$(mo32)" "set"
"$CC/cc-state" task-opened-recently /d/m1 120; eq "32 opened-recently rc0 in window" "$?" "0"
# age it out by rewriting the column, the way `touch -t` aged the file
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("UPDATE tasks SET tab_opened_ts=1 WHERE tab_opened_ts IS NOT NULL"); c.commit()' "$CC_STATE_DB"
"$CC/cc-state" task-opened-recently /d/m1 120; eq "32 opened-recently rc1 outside window" "$?" "1"
"$CC/cc-state" task-opened-recently /d/never 120; eq "32 opened-recently rc1 without a row" "$?" "1"
# the stamp is a CARRIED column: a line-based rewrite of tasks must not lose it
"$CC/cc-state" task-mark-opened /d/m1
"$CC/cc-state" task-set-ref /d/m1 s:9 >/dev/null 2>&1
"$CC/cc-state" task-opened-recently /d/m1 120; eq "32 the stamp survives a rewrite" "$?" "0"

# ── Task 3: the tabs-store verbs (byte contract of _cctabs_log / _cctabs_by_dir /
# _cctabs_owner / _cctabs_prune) ─────────────────────────────────────────────────
"$CC/cc-state" tab-add aaaa-1 bbbb-2 /d/y sid-1
eq "32 tab-add uppercases uuids" "$("$CC/cc-state" dump tabs | cut -f1,2)" "$(printf 'AAAA-1\tBBBB-2')"
"$CC/cc-state" tab-add CCCC-3 '' /d/z ''
eq "32 tab-add writes - for empty owner/session" "$("$CC/cc-state" dump tabs | tail -1 | cut -f2,4)" "$(printf -- '-\t-')"
N32=$("$CC/cc-state" dump tabs | wc -l | tr -d ' ')
"$CC/cc-state" tab-add 'surface:9' OW /d/w s9; rc=$?
eq "32 tab-add non-uuid suuid rc0" "$rc" "0"
eq "32 tab-add non-uuid suuid writes no row" "$("$CC/cc-state" dump tabs | wc -l | tr -d ' ')" "$N32"
"$CC/cc-state" tab-add DDDD-4 'surface:7' /d/w2 s4
eq "32 tab-add non-uuid owner becomes -" "$("$CC/cc-state" dump tabs | tail -1 | cut -f2)" "-"
# tab-list: default = only this session's rows (session = CC_CALLER_SURFACE_UUID /
# CMUX_SURFACE_ID, uppercased); --all = every row; no session identity at all = no filter
eq "32 tab-list default = this session's rows" \
  "$(CC_CALLER_SURFACE_UUID=BBBB-2 "$CC/cc-state" tab-list | wc -l | tr -d ' ')" "1"
eq "32 tab-list --all = every row" "$("$CC/cc-state" tab-list --all | wc -l | tr -d ' ')" "3"
eq "32 tab-list with no session shows all" \
  "$(env -u CC_CALLER_SURFACE_UUID -u CMUX_SURFACE_ID "$CC/cc-state" tab-list | wc -l | tr -d ' ')" "3"
# tab-owner: the NEWEST ledger row for the uuid that actually names an owner
printf 'AAAA-1\tEEEE-9\t/d/y\ts2\t2026-01-02 00:00:00\n' | st_append tabs
eq "32 tab-owner newest non-dash owner" "$("$CC/cc-state" tab-owner aaaa-1)" "EEEE-9"
"$CC/cc-state" tab-owner NOPE-0 >/dev/null 2>&1; eq "32 tab-owner miss rc1" "$?" "1"
# tab-resolve (spec §4, round-2 shape): ALL ledger candidates in priority order,
# one `source \t suuid \t owner \t branch` line each — the facade gives evidence,
# close keeps the liveness cascade. Board candidate first: its largs suuid/owner;
# the tabs candidate follows and is NOT crowded out by a bad board value.
"$CC/cc-state" task-add /d/tb feat/tb s:7 'resolve me' camp
"$CC/cc-state" task-set-launch /d/tb c:8 'uuid=u77:pm=auto:csuuid=CS-1:suuid=AAAA-1:model=m'
"$CC/cc-state" tab-add FFFF-5 OTHER-9 /d/tb sX
eq "32 tab-resolve emits board then tabs" "$("$CC/cc-state" tab-resolve /d/tb)" \
  "$(printf 'board\tAAAA-1\tCS-1\tfeat/tb\ntabs\tFFFF-5\t-\t-')"
# B3 fixture 1: a recorded SHORT REF is an address, never an identity — the board
# candidate is dropped (not emitted as "surface") and the real tabs candidate shows
"$CC/cc-state" task-add /d/sr feat/sr s:7 'short ref' camp
"$CC/cc-state" task-set-launch /d/sr c:8 'uuid=u:suuid=surface:283:model=m'
"$CC/cc-state" tab-add EEEE-1 FFFF-2 /d/sr sR
eq "32 tab-resolve drops a non-uuid identity" "$("$CC/cc-state" tab-resolve /d/sr)" \
  "$(printf 'tabs\tEEEE-1\tFFFF-2\t-')"
# B3 fixture 2: identities come back UPPERCASED, like every close comparison
"$CC/cc-state" task-add /d/sr2 feat/sr2 s:7 'lowercase' camp
"$CC/cc-state" task-set-launch /d/sr2 c:8 'uuid=u:csuuid=abcd-1:suuid=beef-2'
eq "32 tab-resolve uppercases identities" "$("$CC/cc-state" tab-resolve /d/sr2)" \
  "$(printf 'board\tBEEF-2\tABCD-1\tfeat/sr2')"
# board row without a suuid → only the opened-tabs candidate answers
"$CC/cc-state" task-add /d/tb2 feat/tb2 s:7 'fallback' camp
"$CC/cc-state" task-set-launch /d/tb2 c:8 'uuid=u78:pm=auto'
"$CC/cc-state" tab-add 1111-6 2222-7 /d/tb2 sY
eq "32 tab-resolve falls back to opened-tabs" "$("$CC/cc-state" tab-resolve /d/tb2)" \
  "$(printf 'tabs\t1111-6\t2222-7\t-')"
# board row with a suuid but no csuuid → owner from the ledger's newest row for
# THAT suuid (close's by-uuid fallback; the by-dir owner is dead code there)
"$CC/cc-state" task-add /d/tb3 feat/tb3 s:7 'owner fallback' camp
"$CC/cc-state" task-set-launch /d/tb3 c:8 'uuid=u79:pm=auto:suuid=3333-8'
"$CC/cc-state" tab-add 3333-8 '' /d/tb3 sZ
"$CC/cc-state" tab-add 3333-8 4444-9 /d/tb3 sZ2
eq "32 tab-resolve owner falls back to the ledger" "$("$CC/cc-state" tab-resolve /d/tb3)" \
  "$(printf 'board\t3333-8\t4444-9\tfeat/tb3\ntabs\t3333-8\t4444-9\t-')"
"$CC/cc-state" tab-resolve /d/void >/dev/null 2>&1; eq "32 tab-resolve nothing rc1" "$?" "1"
eq "32 tab-resolve nothing prints nothing" "$("$CC/cc-state" tab-resolve /d/void)" ""
# tab-prune takes the RAW live map (`ref \t uuid [\t ws]` lines) and recognizes the
# !partial sentinel ITSELF (B8): completeness is structural here, not caller
# discipline — a pre-extracted uuid list has already thrown the completeness bit
# away. No evidence — empty map, missing map, PARTIAL map — prunes not one row.
B32=$("$CC/cc-state" tab-list --all | wc -l | tr -d ' ')
: > "$S32/live.empty"
"$CC/cc-state" tab-prune "$S32/live.empty"; rc=$?
eq "32 tab-prune empty evidence rc0" "$rc" "0"
eq "32 tab-prune empty evidence prunes nothing" "$("$CC/cc-state" tab-list --all | wc -l | tr -d ' ')" "$B32"
"$CC/cc-state" tab-prune "$S32/live.missing"; eq "32 tab-prune missing evidence file rc0" "$?" "0"
printf 'surface:1\tAAAA-1\tworkspace:1\n!partial\n' > "$S32/live.part"
"$CC/cc-state" tab-prune "$S32/live.part"; rc=$?
eq "32 tab-prune partial map rc0" "$rc" "0"
eq "32 tab-prune partial map prunes nothing" "$("$CC/cc-state" tab-list --all | wc -l | tr -d ' ')" "$B32"
printf 'surface:1\taaaa-1\tworkspace:1\n' > "$S32/live.one"   # lowercase uuid: keys fold like toupper($2)
"$CC/cc-state" tab-prune "$S32/live.one"
eq "32 tab-prune keeps live uuids (case-folded)" "$("$CC/cc-state" tab-list --all | wc -l | tr -d ' ')" "2"
eq "32 tab-prune dropped the dead" "$("$CC/cc-state" tab-list --all | cut -f1 | sort -u)" "AAAA-1"
printf 'surface:1\tZZZZ-0\tworkspace:1\n' > "$S32/live.none"
"$CC/cc-state" tab-prune "$S32/live.none"
"$CC/cc-state" exists tabs; eq "32 tab-prune all-dead empties the store" "$?" "1"
# the CLI surface itself
eq "32 help lists every verb" "$("$CC/cc-state" --help 2>&1 | grep -oE 'task-add|tab-prune|dump' | wc -l | tr -d ' ')" "3"
"$CC/cc-state" bogus-verb >/dev/null 2>&1; eq "32 unknown verb rc2" "$?" "2"
printf '\t\t\t/d/x\n' | st_seed tasks      # 状态挂在任务行上,先有行才有状态
printf '/d/x\tworking\t123\n' | st_seed status
eq "32 dump status works" "$("$CC/cc-state" dump status)" "$(printf '/d/x\tworking\t123')"

# ── round-2 gate fixes ──────────────────────────────────────────────────────────
# B1: read→transform→write must sit inside ONE lock hold (the shell shape). A
# plain-campaign race: 40 concurrent appends against 40 concurrent rewrites of the
# same pre-existing row — every one of the 41 records must survive.
S32R=$(mktemp -d); R32="$S32R/race"; mkdir -p "$R32"
CC_STATE_DB="$S32R/cc-state.db" "$CC/cc-state" task-add "$R32" feat/race s:1 'race seed' p
for i in $(seq 1 40); do mkdir -p "$S32R/w$i"; done
for i in $(seq 1 40); do
  ( CC_STATE_DB="$S32R/cc-state.db" "$CC/cc-state" task-add "$S32R/w$i" "feat/w$i" s:1 "race $i" p ) &
  ( CC_STATE_DB="$S32R/cc-state.db" "$CC/cc-state" task-set-ref "$R32" "surface:$i" "UUID-$i" ) &
done
wait
eq "32 no row lost to a concurrent rewrite (B1)" "$(st_dump tasks "$S32R/cc-state.db" | wc -l | tr -d ' ')" "41"
eq "32 every raced append survived" "$(st_dump tasks "$S32R/cc-state.db" | grep -c "race [0-9]")" "40"
# B2: one stray non-UTF-8 byte must not take the list verbs down (awk doesn't);
# must hold in a UTF-8 locale AND under LC_ALL=C
printf 'AAAA-1\tBBBB-2\t/d/nf\t-\tts\nCCCC-3\t-\t/d/nf2\t-\tts\nDDDD-4\tBBBB-2\t/d/nf\xff3\t-\tts\n' | st_seed tabs
o32a="$(LANG=en_US.UTF-8 "$CC/cc-state" tab-list --all 2>/dev/null)"; r32a=$?
eq "32 non-UTF-8 byte survives a UTF-8 locale" "$r32a$(printf '%s\n' "$o32a" | wc -l | tr -d ' ')" "03"
o32b="$(LC_ALL=C "$CC/cc-state" tab-list --all 2>/dev/null)"; r32b=$?
eq "32 non-UTF-8 byte survives LC_ALL=C" "$r32b$(printf '%s\n' "$o32b" | wc -l | tr -d ' ')" "03"
# B4: a truncated 1-field row is skipped/shown, never a traceback
printf 'AAAA-1\n' | st_seed tabs
CC_CALLER_SURFACE_UUID=BBBB-2 "$CC/cc-state" tab-list >/dev/null 2>&1; eq "32 short row: default filter rc0" "$?" "0"
eq "32 short row still listed with --all" "$("$CC/cc-state" tab-list --all | wc -l | tr -d ' ')" "1"
# B9: --all disables the repo filter, in either flag order (cc-board.sh's contract)
R32A="$(cd "$(mktemp -d)" && pwd -P)"; R32B="$(cd "$(mktemp -d)" && pwd -P)"
printf '2026-01-01 00:00:00\tfeat/ra\ts:1\t%s\tc:1\ta row\tcamp\t\n' "$R32A" | st_append tasks
printf '2026-01-01 00:00:00\tfeat/rb\ts:1\t%s\tc:1\tb row\tcamp\t\n' "$R32B" | st_append tasks
eq "32 --repo alone filters"       "$("$CC/cc-state" task-list --repo "$R32A" | grep -c "$R32B")" "0"
eq "32 --all after --repo disables" "$("$CC/cc-state" task-list --repo "$R32A" --all | grep -c "$R32B")" "1"
eq "32 --all before --repo disables" "$("$CC/cc-state" task-list --all --repo "$R32A" | grep -c "$R32B")" "1"
# B10: ONE dir rule for every verb — a LOGICAL-path row (/var → /private/var on
# macOS) must be found by a canonical caller, and the reverse; new writes are
# canonicalized (write-side normalization, spec §3.5 defect 3)
V32="$(mktemp -d)"; V32C="$(cd "$V32" && pwd -P)"
[ "$V32" != "$V32C" ] || { echo "  ✗ 32 fixture needs a logical path (mktemp under /var)"; fail=$((fail+1)); }
printf '2026-01-01 00:00:00\tfeat/v\ts:1\t%s\tc:1\tlogical row\tcamp\tuuid=u1:pm=auto:csuuid=CCCC-1:suuid=DDDD-1\n' "$V32" | st_seed tasks
eq "32 logical row found by canonical caller (get)" "$("$CC/cc-state" task-get "$V32C" | cut -f2)" "feat/v"
"$CC/cc-state" task-set-launch "$V32C" c2 'uuid=u1:pm=auto:csuuid=CCCC-1:suuid=DDDD-1'
eq "32 logical row found by canonical caller (set-launch)" "$("$CC/cc-state" task-get "$V32" | cut -f5)" "c2"
"$CC/cc-state" task-set-state "$V32C" working
eq "32 logical row found by canonical caller (set-state)" "$("$CC/cc-state" dump status | awk -F'\t' -v d="$V32C" '$1==d{print $2}')" "working"
"$CC/cc-state" task-set-ref "$V32C" s:9
eq "32 logical row found by canonical caller (set-ref)" "$("$CC/cc-state" task-get "$V32" | cut -f3)" "s:9"
"$CC/cc-state" tab-add EEEE-2 FFFF-3 "$V32" sV
eq "32 logical dir found by canonical caller (tab-resolve)" "$("$CC/cc-state" tab-resolve "$V32C" | head -1)" \
  "$(printf 'board\tDDDD-1\tCCCC-1\tfeat/v')"
"$CC/cc-state" task-drop "$V32C"
eq "32 logical row found by canonical caller (drop)" \
  "$("$CC/cc-state" dump tasks | grep -c "feat/v")" "0"
"$CC/cc-state" task-add "$V32" feat/v2 s:1 'written logical' p
eq "32 task-add canonicalizes what it writes" "$("$CC/cc-state" dump tasks | grep -c "$V32C")" "1"
eq "32 ...and drops the logical form" "$("$CC/cc-state" dump tasks | awk -F'\t' -v d="$V32" '$4==d' | wc -l | tr -d ' ')" "0"
# B11: a failed archive rewrite is LOUD (rc 1 + stderr), tasks untouched — a
# read-only store dir makes the tmp-write fail while the archive stays writable
# B11: a failed archive is LOUD (rc 1 + stderr) and leaves the task list alone. The injection
# had to move with the backend: it used to make the store DIRECTORY unwritable so the tmp-write
# failed. Now the write is a transaction, so the equivalent is a library the engine can read
# but not write — chmod 444 on the file itself, which is also the shape a real machine hits
# (a store restored from a backup with the wrong mode).
S32RO=$(mktemp -d)
printf '2026-01-01 00:00:00\tfeat/ro\ts:1\t/d/ro\tc:1\tread only\tcamp\t\n' | st_seed tasks "$S32RO/cc-state.db"
B32RO="$(st_dump tasks "$S32RO/cc-state.db" | wc -l | tr -d ' ')"
# both, and in this order: a read-only FILE alone still lets WAL write its -wal sidecar, so
# the directory has to refuse that too. (Verified by watching this assertion stay green with
# only the chmod 444 — which is exactly the shape of a mutation that proves nothing.)
chmod 444 "$S32RO/cc-state.db"; chmod 555 "$S32RO"
CC_STATE_DB="$S32RO/cc-state.db" \
  "$CC/cc-state" task-archive feat/ro trunk >/dev/null 2>"$S32B/ro-err"; r32ro=$?
chmod 755 "$S32RO"; chmod 644 "$S32RO/cc-state.db"
eq "32 archive rewrite failure is loud rc1" "$r32ro" "1"
eq "32 archive rewrite failure says so" "$(grep -c 'archive rewrite failed' "$S32B/ro-err")" "1"
eq "32 tasks left untouched on failure" "$(st_dump tasks "$S32RO/cc-state.db" | wc -l | tr -d ' ')" "$B32RO"
# B13: a downstream `| head` must not leak a traceback onto stderr
python3 -c 'import sys
sys.stdout.write("".join(
  "2026-01-01 00:00:00\tfeat/b%d\ts:1\t/d/b%d\tc\trow %d\tcamp\t\n" % (i, i, i)
  for i in range(5000)))' | st_seed tasks "$DB_32"
CC_STATE_DB="$DB_32" "$CC/cc-state" dump tasks 2>"$S32B/bp-err" | head -2 >/dev/null
eq "32 broken pipe is silent" "$([ -s "$S32B/bp-err" ] && echo noise || echo quiet)" "quiet"
python3 -c 'import sys
sys.stdout.write("".join(
  "AAAA-%04d\tBBBB-2\t/d/t%d\t-\t2026-01-01 00:00:00\n" % (i, i)
  for i in range(5000)))' | st_seed tabs "$DB_32"
CC_STATE_DB="$DB_32" "$CC/cc-state" tab-list --all 2>>"$S32B/bp-err" | head -2 >/dev/null
eq "32 broken pipe is silent (list path)" "$([ -s "$S32B/bp-err" ] && echo noise || echo quiet)" "quiet"
# B14: a dir with a raw non-UTF-8 byte (from argv) must not crash the verbs that
# hash it — fsencode, not str.encode
BD32=$(printf '/d/bad\xff')
# 戳记现在挂在任务行上,所以先要有一行 —— 而这正好把 B14 测得更全:那个裸字节要活着穿过
# argv → 列存 → dir_match 三道,不只是穿过一次哈希。
"$CC/cc-state" task-add "$BD32" feat/bad s:1 'non-utf8 dir' p
"$CC/cc-state" task-mark-opened "$BD32"; eq "32 non-UTF-8 dir: mark-opened rc0" "$?" "0"
"$CC/cc-state" task-opened-recently "$BD32" 120; eq "32 non-UTF-8 dir: stamp round-trips" "$?" "0"
"$CC/cc-state" task-add "$BD32" feat/bd s:1 'bad bytes dir' p; eq "32 non-UTF-8 dir: task-add rc0" "$?" "0"
eq "32 non-UTF-8 dir: row round-trips" "$("$CC/cc-state" task-get "$BD32" | wc -l | tr -d ' ')" "1"

# ── round-3 gate hardening ──────────────────────────────────────────────────────
# C1: rewrite()'s change detection must hold even against a fn that mutates its
# argument IN PLACE and returns it (the mutation has to land, not be silently
# skipped because out and rows are the same object) — driven at module level,
# the way the gate reproduced it
C1OUT=$(python3 - "$CC/cc-state" "$S32B/c1.tsv" <<'PY'
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
sys.dont_write_bytecode = True   # no __pycache__/ next to the repo's cc-state
loader = SourceFileLoader("ccstate", sys.argv[1])   # no .py extension → explicit loader
spec = importlib.util.spec_from_loader("ccstate", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
os.environ["CC_STATE_DB"] = sys.argv[2] + ".db"
m.append_line("tasks", "a\tb")
def inplace(rows):
    rows.append("c\td")           # mutates and returns the SAME list object
    return rows
m.rewrite("tasks", inplace)
sys.stdout.write(str(len(m.read_lines("tasks"))))
PY
)
eq "32 rewrite fires even for an in-place fn (C1)" "$C1OUT" "2"
# C2: the !partial sentinel must survive sloppy whitespace — '!partial ' or
# '!partial\r' still means "evidence incomplete", and pruning stays off
printf 'AAAA-1\tBBBB-2\t/d/c2\t-\tts\nCCCC-3\t-\t/d/c2b\t-\tts\n' | st_seed tabs
printf 'surface:1\tAAAA-1\tworkspace:1\n!partial \n' > "$S32/live.ps"
"$CC/cc-state" tab-prune "$S32/live.ps"; r32ps=$?
eq "32 sentinel with trailing space: rc0" "$r32ps" "0"
eq "32 sentinel with trailing space: nothing pruned" "$("$CC/cc-state" tab-list --all | wc -l | tr -d ' ')" "2"
printf 'surface:1\tAAAA-1\tworkspace:1\n!partial\r\n' > "$S32/live.cr"
"$CC/cc-state" tab-prune "$S32/live.cr"
eq "32 sentinel with CR: nothing pruned" "$("$CC/cc-state" tab-list --all | wc -l | tr -d ' ')" "2"
# C3: dump must not swallow genuine read errors (a blanket except OSError would report partial
# output as success); a MISSING store stays silent rc 0. The injection is a CORRUPT library
# now instead of a store path that is a directory — and unlike the old one this is a failure
# mode real machines have (a truncated copy, a half-written restore).
printf 'this is not a sqlite database at all\n' > "$S32B/corrupt.db"
CC_STATE_DB="$S32B/corrupt.db" "$CC/cc-state" dump tasks >/dev/null 2>"$S32B/corrupt-err"; r32dir=$?
eq "32 dump read error is loud" "$r32dir" "1"
eq "32 dump read error says which store" "$(grep -c '^cc-state: dump tasks: ' "$S32B/corrupt-err")" "1"
# ...while the hook's write path degrades SILENTLY on the very same library (contract 1)
o32c="$(CC_STATE_DB="$S32B/corrupt.db" "$CC/cc-state" task-set-state /d/x working 2>&1)"; r32c=$?
eq "32 a corrupt library is a silent no-op for the hook path" "$r32c/$o32c" "0/"
CC_STATE_DB="$S32B/none.db" "$CC/cc-state" dump tasks; r32none=$?
eq "32 dump missing file stays silent rc0" "$r32none" "0"
# C5: the BrokenPipe leak had a SIZE window (~90–136KB): the write returns cleanly,
# head exits, and EPIPE only surfaces at the interpreter's exit-time flush — outside
# every handler. Pin the fixture INSIDE the window and run both paths 5×: the
# in-main flush must make the handler reachable at every size
python3 -c 'import sys
sys.stdout.write("".join(
  "2026-01-01 00:00:00\tfeat/c5-%04d\tsurface:1\t/d/c5-%04d\tc:1\tc5 archive row %04d sized into the pipe leak window\tcamp\tuuid=u:pm=auto\t1700000000\n"
  % (i, i, i) for i in range(800)))' | st_seed archive "$DB_32"
SZ32=$(st_dump archive "$DB_32" | wc -c | tr -d ' ')
eq "32 C5 fixture sits inside the 90-136KB leak window" "$(( SZ32 >= 90000 && SZ32 <= 136000 ? 1 : 0 ))" "1"
L32=0
for i in 1 2 3 4 5; do
  CC_STATE_DB="$DB_32" "$CC/cc-state" dump archive 2>"$S32B/c5e1" | head -2 >/dev/null
  [ -s "$S32B/c5e1" ] && L32=$((L32+1))
done
eq "32 C5 dump through the window leaks nothing (5 runs)" "$L32" "0"
L32=0
for i in 1 2 3 4 5; do
  CC_STATE_DB="$DB_32" "$CC/cc-state" task-list --archive 2>"$S32B/c5e2" | head -2 >/dev/null
  [ -s "$S32B/c5e2" ] && L32=$((L32+1))
done
eq "32 C5 list path through the window leaks nothing (5 runs)" "$L32" "0"
CC_STATE_DB="$DB_32" "$CC/cc-state" dump archive 2>/dev/null | head -2 >/dev/null; r32c5=${PIPESTATUS[0]}
eq "32 C5 rc stays 0 through the window" "$r32c5" "0"

# ── task-clear-state: the sidecar counterpart of task-set-state ───────────────────
# The verb resume (_ccres_dropstatus) and gwt-rm (_gwt_status_drop_dir) need and no
# other verb provides: clearing the agent-state row of a dir that is still ALIVE.
# task-prune only sweeps dirs that are GONE; task-drop only touches the task list.
S32CL=$(mktemp -d); D32CL="$S32CL/live dir"; mkdir -p "$D32CL"   # NB: a SPACE in the path
export CC_STATE_DB="$S32CL/cc-state.db"
P32CL="$(cd "$D32CL" && pwd -P)"
# D 期：状态是任务行上的列,所以两条状态行各自要有一条任务行。原夹具故意把 tasks 留空来表达
# 「清除不受板成员资格约束」—— 那个前提在新模型下结构上不成立(没有任务行就没有状态)。同一条
# 性质改用它现在的形状表达:清一个不在板上的 dir 是无害的 no-op,rc 0 且不动别人。
{ printf '2026-01-01 00:00:01\tfeat/cl\ts:1\t%s\tc\tclear-state row\tmain\t\n' "$D32CL"
  printf '2026-01-01 00:00:02\tfeat/oth\ts:2\t%s\tc\tunrelated row\tmain\t\n' "$S32CL/other"; } | st_seed tasks
printf '%s\tworking\t111\n%s\tblocked\t222\n' "$D32CL" "$S32CL/other" | st_seed status
"$CC/cc-state" task-clear-state "$D32CL"
# spec 3.5 defect 1: _ccres_dropstatus' awk had no -F'\t', so it split on whitespace and a
# dir with a space in it could never be dropped. Byte-matching on the field kills that class.
eq "32 clear-state drops a dir whose path has a space" "$("$CC/cc-state" dump status | grep -cF "$D32CL	")" "0"
eq "32 clear-state leaves unrelated rows"              "$("$CC/cc-state" dump status | grep -cF "$S32CL/other")" "1"
"$CC/cc-state" task-clear-state "$S32CL/nosuchdir"; rc32cl=$?
eq "32 clear-state on a non-member dir is rc 0"       "$rc32cl" "0"
eq "32 clear-state is not gated on board membership"  "$("$CC/cc-state" dump status | wc -l | tr -d ' ')" "1"
# the file-header dir rule, both directions (macOS /var vs /private/var)
printf '%s\tworking\t111\n%s\tidle\t222\n' "$D32CL" "$S32CL/other" | st_seed status
"$CC/cc-state" task-clear-state "$P32CL"
eq "32 clear-state matches a logical row by its physical form" "$("$CC/cc-state" dump status | grep -cF "$D32CL	")" "0"
printf '%s\tworking\t111\n%s\tidle\t222\n' "$P32CL" "$S32CL/other" | st_seed status
"$CC/cc-state" task-clear-state "$D32CL"
eq "32 clear-state matches a physical row by its logical form" "$("$CC/cc-state" dump status | grep -cF "$P32CL	")" "0"
# no match is a silent rc 0 (resume clears dirs that may have no row at all)
c32cl="$("$CC/cc-state" task-clear-state /d/never-recorded 2>&1)"; rc32cl=$?
eq "32 clear-state on an unknown dir is rc 0" "$rc32cl" "0"
eq "32 clear-state on an unknown dir is silent" "$c32cl" ""
# emptying the store leaves NO rows — the observable end of today's `[ -s ] || rm -f`.
# Stated on rows, not on a file: there has been no per-store file to stat since the engine
# swap, so the `[ -e ]` form of this assertion could only ever answer "no".
printf '%s\tworking\t111\n' "$P32CL" | st_seed status
"$CC/cc-state" task-clear-state "$P32CL"
"$CC/cc-state" exists status; eq "32 clear-state leaves the store with no rows" "$?" "1"
rm -rf "$S32CL"

# ── task-archive --repo / task-prune --compact ───────────────────────────────────
# Both exist because worktree.zsh cannot express them without a hand-rolled locked
# rewrite, which is the thing this phase deletes. Defaults are today's semantics,
# so every existing caller and fixture is untouched — the flags are opt-in.
S32F=$(mktemp -d); A32="$S32F/repoA"; B32="$S32F/repoB"; O32="$S32F/repoA-other"
mkdir -p "$A32/wt" "$A32/wt2" "$B32/wt" "$O32/wt"
export CC_STATE_DB="$S32F/cc-state.db"
# spec 3.5 defect 2: _gwt_archive_branch matched on branch NAME alone, so merging
# feat/x in repo A archived repo B's feat/x rows too.
mk32f(){
  : | st_seed archive
  printf '2026-01-01 00:00:01\tfeat/x\ts:1\t%s\tc\tA row\tp\tu\n'      "$A32/wt" |  st_seed tasks
  printf '2026-01-01 00:00:02\tfeat/x\ts:2\t%s\tc\tB row\tp\tu\n'      "$B32/wt" | st_append tasks
  printf '2026-01-01 00:00:03\tfeat/x\ts:3\t\tc\tno-dir row\tp\tu\n'             | st_append tasks
}
mk32f; "$CC/cc-state" task-archive feat/x feature/camp --repo "$A32" >/dev/null
eq "32 --repo archives only this repo's rows"  "$("$CC/cc-state" dump tasks | grep -c 'A row')" "0"
eq "32 --repo leaves the other repo alone"     "$("$CC/cc-state" dump tasks | grep -c 'B row')" "1"
# an empty dir belongs to no repo — never swept by a repo-scoped archive
eq "32 --repo leaves an empty-dir row alone"   "$("$CC/cc-state" dump tasks | grep -c 'no-dir row')" "1"
eq "32 --repo archive row is verbatim + 2"     "$("$CC/cc-state" dump archive | awk -F'\t' 'END{print NF":"$10}')" "10:feature/camp"
# component-boundary containment: /a/repoA must not swallow /a/repoA-other
: | st_seed archive
printf '2026-01-01 00:00:04\tfeat/y\ts:1\t%s\tc\tsibling row\tp\tu\n' "$O32/wt" | st_seed tasks
"$CC/cc-state" task-archive feat/y feature/camp --repo "$A32" >/dev/null
eq "32 --repo does not swallow a sibling-named repo" "$("$CC/cc-state" dump tasks | grep -c 'sibling row')" "1"
# no flag = today's global semantics: branch name alone, so ALL THREE rows go —
# both repos AND the empty-dir row. That the empty-dir row survives above is a
# property of --repo (a dir-less row is in no repo), not of archiving in general.
mk32f; "$CC/cc-state" task-archive feat/x feature/camp >/dev/null
eq "32 archive without --repo stays global" \
  "$("$CC/cc-state" dump tasks | grep -c 'row')" "0"
eq "32 global archive moved all three rows" "$("$CC/cc-state" dump archive | wc -l | tr -d ' ')" "3"
# --compact: gwt-prune's `tail -r | awk '$4!="" && !seen[$4]++' | tail -r`, verbatim
mk32c(){
  printf '2026-01-01 00:00:01\tfeat/a\ts:1\t%s\tc\tOLD dup\tp\tu\n' "$A32/wt"  |  st_seed tasks
  printf '2026-01-01 00:00:02\tfeat/b\ts:2\t%s\tc\tw2 row\tp\tu\n'  "$A32/wt2" | st_append tasks
  printf '2026-01-01 00:00:03\tfeat/a\ts:3\t%s\tc\tNEW dup\tp\tu\n' "$A32/wt"  | st_append tasks
  printf '2026-01-01 00:00:04\tfeat/c\ts:4\t\tc\tempty dir\tp\tu\n'            | st_append tasks
}
# the default must NOT compact — the board's prune-on-read calls it on every render
mk32c; "$CC/cc-state" task-prune
eq "32 task-prune alone does not compact"  "$("$CC/cc-state" dump tasks | grep -c 'OLD dup')" "1"
mk32c; "$CC/cc-state" task-prune --compact
eq "32 --compact drops the older dup"      "$("$CC/cc-state" dump tasks | grep -c 'OLD dup')" "0"
eq "32 --compact keeps the newest"         "$("$CC/cc-state" dump tasks | grep -c 'NEW dup')" "1"
eq "32 --compact drops an empty-dir row"   "$("$CC/cc-state" dump tasks | grep -c 'empty dir')" "0"
# ORIGINAL file order survives (tail -r … | tail -r), it is not newest-first
eq "32 --compact preserves row order"      "$("$CC/cc-state" dump tasks | cut -f6 | tr '\n' ',')" "w2 row,NEW dup,"
rm -rf "$S32F"

# ── task-list --with-state: the sidecar join belongs to the facade ────────────────
# The board used to get legacy rows right only by re-canonicalizing EVERY dir on
# read — the half of spec 3.5 defect 3 this phase removes. Drop that and a caller
# joining on the raw string shows '-' for exactly the rows defect 3 is about, which
# is a STATUS regression, not a cosmetic one. So the facade owns the join.
S32S=$(mktemp -d); D32S="$S32S/wt"; mkdir -p "$D32S"
export CC_STATE_DB="$S32S/cc-state.db"
L32S="$S32S/wt"; P32S="$(cd "$D32S" && pwd -P)"
# the row is recorded LOGICAL (/var/...), the hook writes the sidecar CANONICAL
# (/private/var/...) because cc-hooks.sh does cd + pwd -P before calling the facade
printf '2026-01-01 00:00:00\tfeat/leg\ts:1\t%s\tc\tlegacy row\tcamp\tu\n' "$L32S" | st_seed tasks
printf '%s\tworking\t111\n' "$P32S" | st_seed status
eq "32 without --with-state the row is untouched" \
  "$("$CC/cc-state" task-list --all | awk -F'\t' '{print NF}')" "8"
eq "32 --with-state joins a logical row to a canonical sidecar key" \
  "$("$CC/cc-state" task-list --all --with-state | awk -F'\t' '{print $9}')" "working"
eq "32 --with-state carries the epoch through" \
  "$("$CC/cc-state" task-list --all --with-state | awk -F'\t' '{print $10}')" "111"
# a row with no sidecar still gets the two fields, so the column count never varies
: | st_seed status
eq "32 --with-state pads a stateless row" \
  "$("$CC/cc-state" task-list --all --with-state | awk -F'\t' '{print NF"/"$9}')" "10/-"
rm -rf "$S32S"



rm -rf "$S32" "$S32B" "$S32R" "$S32RO" "$D32A" "$D32B" "$LIVE32" "$R32A" "$R32B" "$V32"
rm -f "$S32/live.empty" "$S32/live.missing" "$S32/live.part" "$S32/live.one" "$S32/live.none" 2>/dev/null
cc_sandbox_ledgers   # back to the sandbox before the next section

echo ""
echo "== 21. dispatch path resolution: target repo root + the opened-tabs prune =="
DB_21="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
  ( cd "$CR21" && env HOME="$FH21" PATH="$SF21:$OP21" CC_STATE_DB="$DB_21" \
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
  "$MR21" "$U21O" "$U21H" | st_seed tasks "$DB_21"
printf '%s\t%s\t%s\t-\t2026-01-01 00:00:00\n' "$U21H" "$U21S" "$MR21" | st_seed tabs "$DB_21"
: > "$CC_FAKE_LOG21"
CO21="$( cd "$CR21" && env PATH="$SF21:$OP21" CC_STATE_DB="$DB_21" \
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
awk '/^_cctabs_uc\(\)/{f=1} /^case /{f=0} f' "$CC/cc-dispatch.sh" > "$PR21/ledger.sh"
eq "ledger helpers extracted" "$(grep -c '^_cctabs_prune()' "$PR21/ledger.sh")" "1"
prune21(){ ( set -u; . "$PR21/ledger.sh"; CC_STATE_DB="$DB_21" _cctabs_prune "$2" ) >/dev/null 2>&1; }
L21="$PR21/tabs.tsv"
mk21(){ { printf 'AAAAAAAA-0000-0000-0000-00000000000A\tOWN\t/tmp/a21\t-\tts\n'
          printf 'BBBBBBBB-0000-0000-0000-00000000000B\tOWN\t/tmp/b21\t-\tts\n'; } | st_seed tabs "$DB_21"; }
# same move as rows26: "gone" was the emptied ledger's FILE disappearing; the observable end
# of that is now a store with no rows, and `exists` is the verb that says so.
rows21(){ CC_STATE_DB="$DB_21" "$CC/cc-state" exists tabs || { echo gone; return 0; }
          CC_STATE_DB="$DB_21" "$CC/cc-state" dump tabs | awk 'END{print NR+0}'; }
# a non-empty map that yields NO usable keys → no evidence → prune nothing, and above all KEEP the file
mk21; prune21 "$L21" "surface:1"
eq "empty key set keeps the ledger" "$(rows21)" "2"
# a real map still prunes exactly the rows whose surface is gone
mk21; prune21 "$L21" "$(printf 'surface:1\tAAAAAAAA-0000-0000-0000-00000000000A')"
eq "prune kept the live row"  "$(st_dump tabs "$DB_21" | awk -F'\t' 'NR==1{print substr($1,1,8)}')" "AAAAAAAA"
eq "prune dropped the dead row" "$(rows21)" "1"
# every row dead → the ledger file itself goes (unchanged behaviour)
mk21; prune21 "$L21" "$(printf 'surface:1\tCCCCCCCC-0000-0000-0000-00000000000C')"
eq "all-dead ledger removed" "$(rows21)" "gone"

# surface leaves contentless dedup markers in the real TMPDIR (hash-keyed) — sweep ours
unstamp "$DB_21"
( cd "$CR21" && git worktree remove --force "$CR21/.claude/worktrees/kid21" >/dev/null 2>&1 )
rm -rf "$SF21" "$FH21" "$CR21" "$TR21" "$MR21" "$PR21"; rm -f "$TF21" "$TB21" "$TF21B" "$TB21B"
unset CC_FAKE_LOG21 CF_SCREEN21

echo ""
echo "== 29. dispatch-fixes (F1-F7 + H2/H3 + gate rounds 2-3) =="
DB_29="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
printf '2026-01-01 00:00:01\tfeat/wtb\tsurface:41\t%s\tsurface:1\ttask sibling b\tmain\n' "$WTB"  | st_seed tasks "$DB_29"
printf '2026-01-01 00:00:02\tfeat/v1.2\tsurface:42\t%s\tsurface:1\ttask parent-map\tfeat/STALE7\n' "$WTP" | st_append tasks "$DB_29"
printf '2026-01-01 00:00:03\tfeat/foreign29\tsurface:43\t%s\tsurface:1\ttask foreign29\tmain\n' "$OTH29" | st_append tasks "$DB_29"
git -C "$REPO29" config branch.feat/v1.2.ccMergeInto feat/camp-29
export CC_STATE_DB="$DB_29"

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
printf '2026-01-01 00:00:01\tfeat/rsm-sib\tsurface:51\t%s\tsurface:1\tresume sibling row\tmain\tuuid=66666666-6666-6666-6666-666666666666:provider=anthropic:pm=auto\n' "$WTB" | st_seed tasks "$DB_29"
OUT29R="$( cd "$WTA" && echo n | env HOME="$HOME" PATH="$S29:$OP29" CC_STATE_DB="$DB_29" \
  CC_STATE_DB="$DB_29" CC_CMUX_SESSIONS="$S29/store29.json" CC_RESUME_SETTLE=0 \
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
printf '2026-01-01 00:00:01\tfeat/wtb\tsurface:41\t%s\tsurface:1\tsub sibling row\tmain\n' "$SUB29" | st_seed tasks "$DB_29"
BO29S="$( ( cd "$SUB29" && CC_STATE_DB="$DB_29" bash "$CC/cc-board.sh" ) 2>/dev/null )"
eq "SUB: board inside a submodule still shows rows" "$(echo "$BO29S" | grep -c 'sub sibling row')" "1"
OUT29S="$( cd "$SUB29" && echo n | env HOME="$HOME" PATH="$S29:$OP29" CC_STATE_DB="$DB_29" \
  CC_STATE_DB="$DB_29" CC_CMUX_SESSIONS="$S29/store29.json" CC_RESUME_SETTLE=0 \
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
printf '2026-01-01 00:00:01\tfeat/swtx\tsurface:46\t%s\tsurface:1\tsubwt own row\tmain\n' "$WTX29" | st_seed tasks "$DB_29"
BO29X="$( ( cd "$WTX29" && CC_STATE_DB="$DB_29" bash "$CC/cc-board.sh" ) 2>/dev/null )"
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
printf '2026-01-01 00:00:01\tfeat/sepwt\tsurface:44\t%s\tsurface:1\tsep own row\tmain\n' "$WTSEP"  | st_seed tasks "$DB_29"
printf '2026-01-01 00:00:02\tfeat/sepsib\tsurface:45\t%s\tsurface:1\tsep sibling row\tmain\n' "$SIBSEP" | st_append tasks "$DB_29"
BO29SEP="$( ( cd "$WTSEP" && CC_STATE_DB="$DB_29" bash "$CC/cc-board.sh" ) 2>/dev/null )"
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
printf '2026-01-01 00:00:01\tfeat/outwt\tsurface:47\t%s\tsurface:1\toutwt own row\tmain\n' "$OUTWT29" | st_seed tasks "$DB_29"
st_dump tasks "$DB_29" | st_append tasks "$DB_29"
BO29O="$( ( cd "$OUTWT29" && CC_STATE_DB="$DB_29" bash "$CC/cc-board.sh" ) 2>/dev/null )"
eq "OUTWT: own row visible from the out-of-repo worktree"        "$(echo "$BO29O" | grep -c 'outwt own row')"   "1"
eq "OUTWT: main-repo sibling rows hidden (containment fallback)" "$(echo "$BO29O" | grep -c 'task sibling b')" "0"
git -C "$REPO29" worktree remove --force "$OUTWT29" >/dev/null 2>&1; rm -rf "$OWTB29"; rm -f "$TF29O"

# ── F7: a row with an EMPTY surface field must not collapse (TAB is IFS whitespace: fields
# shift left, largs land in task, and the recorded uuid is lost → bogus "no recorded session").
# US (0x1f) is not IFS whitespace, so empty fields survive the awk→read handoff.
TF297=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/f7-empty-surf\t\t%s\tsurface:1\tf7 task text\tmain\tuuid=77777777-7777-7777-7777-777777777777:provider=anthropic:pm=auto\n' "$WTB" | st_seed tasks "$DB_29"
OUT297="$( cd "$WTA" && echo n | env HOME="$HOME" PATH="$S29:$OP29" CC_STATE_DB="$DB_29" \
  CC_STATE_DB="$DB_29" CC_CMUX_SESSIONS="$S29/store29.json" CC_RESUME_SETTLE=0 \
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
        unstamp "$DB_29"; }
srf29(){ # $1 dir, $2 prompt (screens are set by mk29); extra knobs come from the environment
  ( cd "$REPO29" && env HOME="$FH29" PATH="$S29:$OP29" TMPDIR="$S29" CC_STATE_DB="$DB_29" \
      CC_CALLER_CWD="$REPO29" CC_WT_PRETRUST=0 CC_WT_SHARE="" CC_SEND_VERIFY_SEC=0.1 \
      CC_SEND_FAILLOG="$LF29" CC_CALLER_SURFACE_UUID="22222222-AAAA-AAAA-AAAA-222222222222" \
      CC_WT_SESSION_ID="55555555-5555-5555-5555-555555555555" CC_RESUME_SETTLE=0 \
      bash "$CC/cc-dispatch.sh" surface "$1" "$2" ) >/dev/null 2>&1; }
# TMPDIR=$S29: dispatches write their pf temp files into the
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
export CC_STATE_DB="$DB_29"
unstamp "$DB_29"
pfsweep29
rm -rf "$S29" "$FH29" "$REPO29" "$OTH29" 2>/dev/null; rm -f "$TSKV29" "$TB29" "$LF29" "$FL29"
unset CC_FAKE_LOG29 CC_FAKE_SCREEN29 CC_FAKE_ON_SEND CC_FAKE_TUI29 CC_FAKE_FLUSH_AT CC_FAKE_PINGDOWN CC_LAUNCH_FILE

echo ""
echo "== 18. tab-close policy: the two ledgers + the sanctioned primitive =="
DB_18="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
printf '2026-01-01 00:00:01\tfeat/A\tsurface:101\t%s\tsurface:9\ttask A\tmain\t%s\n' "$WA"  "$(la18 1 "$UP" "$UA")" | st_seed tasks "$DB_18"
printf '2026-01-01 00:00:02\tfeat/B\tsurface:201\t%s\tsurface:9\ttask B\tmain\t%s\n' "$WB"  "$(la18 2 "$UO" "$UB")" | st_append tasks "$DB_18"
printf '2026-01-01 00:00:03\tmain\tsurface:301\t%s\tsurface:9\tprimary checkout\tmain\t%s\n' "$R18" "$(la18 3 "$UP" "$UM")" | st_append tasks "$DB_18"
# pre-feature row (no csuuid/suuid at all) — must still parse, and resolve only via opened-tabs
R18OLD="$(cn18 "$(mktemp -d)")"; mkdir -p "$R18OLD/.claude/worktrees/wtOld"; WOLD="$R18OLD/.claude/worktrees/wtOld"
printf '2026-01-01 00:00:04\tfeat/OLD\tsurface:401\t%s\tsurface:9\told row\tmain\tuuid=u4:provider=kimi:pm=auto:model=glm-4.6\n' "$WOLD" | st_append tasks "$DB_18"

# ── the opened-tabs ledger (item A): who opened which tab ──────────────────────────────────
TB18=$(mktemp -u)
tb18(){ printf '%s\t%s\t%s\t%s\t2026-01-01 00:00:00\n' "$1" "$2" "$3" "${4:--}" | st_append tabs "$DB_18"; }
tb18 "$UA" "$UP" "$WA" "u1"          # the same child the board knows: both ledgers, never deduped
tb18 "$UH" "$UP" "$HD18" "-"         # a helper tab in a NON-worktree dir, opened by this session
tb18 "$UD" "$UP" "/tmp/cc-gone" "-"  # a dead surface: lazy pruning must drop this row
# (Task 8b) FORMAT PINS (§32-class, direct read stays): the ledger row's layout — five fields,
# "-" standing in for an empty one — selected BY FILE POSITION, which is not a question any
# facade verb answers. Everything below that asks about ROWS goes through cc-state.
eq "ledger rows are 5 fields"  "$(st_dump tabs "$DB_18" | awk -F'\t' 'NR==1{print NF}')" "5"
eq "ledger writes - for an empty field" "$(st_dump tabs "$DB_18" | awk -F'\t' 'NR==2{print $4}')" "-"

tabs18(){ ( cd "$R18" && env PATH="${2:-$CF:$OP18}" CC_STATE_DB="$DB_18" \
    CC_CALLER_SURFACE_UUID="${3:-$UP}" bash "$CC/cc-dispatch.sh" tabs ${1:-} ) 2>&1; }
# cmux unreachable → nothing is pruned (a probe that failed is not evidence that the tabs died)
TO18="$(tabs18 "" "/usr/bin:/bin")"
eq "tabs warns when cmux is unreachable" "$(echo "$TO18" | grep -c 'cmux unreachable')" "1"
# (Task 8b, §4-trap) prune side effects on the ledger: raw `dump tabs`. `tab-list` hides rows
# this process does not own — with it, pruned and unpruned ledgers read the same
eq "unreachable cmux prunes nothing"     "$(CC_STATE_DB="$DB_18" "$CC/cc-state" dump tabs | grep -c "^$UD")" "1"
# with a live map: the inventory renders and the dead row is pruned away
TO18="$(tabs18)"
eq "tabs prints the header"        "$(echo "$TO18" | grep -cE '^REF +UUID +STATE +OWNER +DIR')" "1"
eq "tabs resolves the live ref"    "$(echo "$TO18" | grep -c "surface:100 .*$UA .*alive")" "1"
eq "tabs shows the helper tab"     "$(echo "$TO18" | grep -c "$UH .*alive")" "1"
eq "tabs marks this session"       "$(echo "$TO18" | grep -c "$UP (self)")" "2"
eq "tabs prints the dir"           "$(echo "$TO18" | grep -cF "$HD18")" "1"
eq "lazy prune dropped the dead row" "$(CC_STATE_DB="$DB_18" "$CC/cc-state" dump tabs | awk -v u="$UD" '$1==u{c++} END{print c+0}')" "0"
eq "lazy prune kept the live rows"    "$(CC_STATE_DB="$DB_18" "$CC/cc-state" dump tabs | grep -c .)" "2"
# the default view is "tabs I opened"; --all is everyone's
tb18 "$UB" "$UO" "$WB" "u2"
eq "tabs hides another session's row" "$(tabs18 | grep -c "$UB")" "0"
eq "tabs --all shows every row"       "$(tabs18 --all | grep -c "$UB")" "1"

# — the sanctioned primitive: resolves by RECORDED uuid, prints it, enforces the policy —
cl18(){ ( cd "$R18" && env PATH="$CF:$OP18" CC_STATE_DB="$DB_18" CC_CMUX_SESSIONS="$ST18" \
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
TF18P=$(mktemp -u); TB18P=$(mktemp -u); PW18="$(cn18 "$(mktemp -d)")"; PWD18="$PW18/.claude/worktrees/wtP"; mkdir -p "$PWD18"
printf '2026-01-01 00:00:01\tfeat/P\tsurface:101\t%s\tsurface:9\tpre-ledger child\tmain\tuuid=u9:provider=anthropic:pm=auto\n' "$PWD18" | st_seed tasks "$TB18P.db"
printf '%s\t%s\t%s\tu9\t2026-01-01 00:00:00\n' "$UA" "$UP" "$PWD18" | st_seed tabs "$TB18P.db"
plc18(){ ( cd "$R18" && env PATH="$CF:$OP18" CC_STATE_DB="$TB18P.db" \
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
TF18T=$(mktemp -u); TB18T=$(mktemp -u); : | st_seed tabs "$TB18T.db"
printf '2026-01-01 00:00:01\tfeat/own\tsurface:101\t%s\tsurface:9\towned child\tmain\t%s\n'   "$DOWN" "$(la18 1 "$UP" "$UA")" | st_seed tasks "$TB18T.db"
printf '2026-01-01 00:00:02\tfeat/other\tsurface:201\t%s\tsurface:9\tother child\tmain\t%s\n' "$DOTH" "$(la18 2 "$UO" "$UB")" | st_append tasks "$TB18T.db"
tt18(){ ( cd "$DR18" && env PATH="$CF:$OP18" CC_STATE_DB="$TB18T.db" \
    CC_CMUX_SESSIONS="$ST18" CC_CALLER_SURFACE_UUID="$UP" CLAUDECODE=1 \
    bash "$CC/cc-dispatch.sh" close "$1" >/dev/null 2>&1; echo $? ); }
eq "truth table: owner + NOT done → allow"      "$(tt18 "$DOWN")" "0"
eq "truth table: third party + NOT done → DENY" "$(tt18 "$DOTH")" "1"
bash "$CC/cc-merge.sh" done "$DR18" feat/own   true >/dev/null 2>&1
bash "$CC/cc-merge.sh" done "$DR18" feat/other true >/dev/null 2>&1
eq "truth table: owner + done → allow"          "$(tt18 "$DOWN")" "0"
eq "truth table: third party + done → allow"    "$(tt18 "$DOTH")" "0"
: > "$CC_FAKE_LOG"
CO="$( ( cd "$DR18" && env PATH="$CF:$OP18" CC_STATE_DB="$TB18T.db" \
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
  ( cd "$R18" && env -u CLAUDECODE PATH="$CF:$OP18" CC_STATE_DB="$DB_18" \
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
CO="$( ( cd "$R18" && env -u CLAUDECODE PATH="$CF:$OP18" CC_STATE_DB="$DB_18" \
      CC_CMUX_SESSIONS="$ST18" CC_FAKE_PSMAP="$CF/ps.human" CC_CALLER_SURFACE_UUID="$UA" \
      bash "$CC/cc-dispatch.sh" close "$WA" ) 2>&1 )"
eq "human shell still refused a self-close" "$(echo "$CO" | grep -c 'no automated self-close')" "1"
eq "self refusal closed nothing"            "$(grep -c 'CLOSE|' "$CC_FAKE_LOG")" "0"

# — dispatch records BOTH stable identities on the board row AND a row in the opened-tabs ledger —
FH18=$(mktemp -d); mkdir -p "$FH18/.config"; cp -R "$CC" "$FH18/.config/cc-stack"
TF18D=$(mktemp -u); TB18D=$(mktemp -u); DD="$(cn18 "$(mktemp -d)")"
: > "$CC_FAKE_LOG"
env HOME="$FH18" PATH="$CF:$OP18" CC_STATE_DB="$TB18D.db" CC_CMUX_SESSIONS="$ST18" \
  CC_SEND_FAILLOG="$CF/fail" CC_SEND_VERIFY_SEC=0.1 CC_LAUNCH_FILE="$CF/launch" \
  CC_CALLER_SURFACE_UUID="$UP" bash "$CC/cc-dispatch.sh" surface "$DD" "dispatch brief" >/dev/null 2>&1
DLA="$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" task-get "$DD" | awk -F'\t' '{print $8}')"
NSU="$(grep -oE 'NEWSURF\|surface:[0-9]+' "$CC_FAKE_LOG" | head -1 | cut -d: -f2)"
DSU="99999999-7777-7777-7777-$(printf '%012d' "$NSU")"
eq "dispatch asks for both ids" "$(grep -c -- '--id-format both' "$CC_FAKE_LOG")" "1"
eq "row records the caller uuid" "$(printf '%s' "$DLA" | grep -c "csuuid=$UP")" "1"
eq "row records the tab uuid"    "$(printf '%s' "$DLA" | grep -c "suuid=$DSU")" "1"
eq "model still composed LAST"   "$(printf '%s' "$DLA" | grep -c 'suuid=[^:]*$')" "1"
eq "dispatch row has 8 fields"   "$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" task-get "$DD" | awk -F'\t' '{print NF}')" "8"
# the second ledger: one row per opened tab, keyed by the tab's own surface uuid
# the ledger gaining a row IS the assertion (a write side effect) → raw `dump tabs`; the OWNER
# has its own verb, `tab-owner <suuid>`, which answers exactly this question. The remaining
# fields (dir, session) have no by-uuid verb — tab-resolve goes dir→candidates, not uuid→row.
eq "ledger row written on open"     "$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" dump tabs | awk -F'\t' -v u="$DSU" 'toupper($1)==toupper(u){c++} END{print c+0}')" "1"
eq "ledger row records the OWNER"   "$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" tab-owner "$DSU")" "$UP"
eq "ledger row records the dir"     "$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" dump tabs | awk -F'\t' -v u="$DSU" 'toupper($1)==toupper(u){print $3}')" "$DD"
eq "ledger row records the session" "$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" dump tabs | awk -F'\t' -v u="$DSU" 'toupper($1)==toupper(u){print ($4!="-" && $4!="")?"yes":"no"}')" "yes"
eq "ledger session matches the board" "$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" dump tabs | awk -F'\t' -v u="$DSU" 'toupper($1)==toupper(u){print "uuid=" $4}')" "$(printf '%s' "$DLA" | cut -d: -f1)"
# both counts stay RAW: each verb collapses its store to at most one row per key (task-get to
# the newest, tab-owner to one owner), and "kept in BOTH ledgers, never deduped" is precisely
# a statement about how many rows are on disk
eq "board and ledger both kept (no dedupe)" "$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" dump tasks | awk -F'\t' -v d="$DD" '$4==d{c++} END{print c+0}')+$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" dump tabs | awk -F'\t' -v d="$DD" '$3==d{c++} END{print c+0}')" "1+1"
unstamp "$TB18D.db"
# WINDOW B (spec §3.1): resume REOPENS a tab, so it must stamp the dedup timestamp too. The stamp
# used to sit inside the `if [ -z "$rsmode" ]` branch, i.e. only on the fresh-dispatch path, so a
# resumed tab left none and the very next dispatch for that dir sailed through the 120s gate and
# opened a SECOND one. Behavioural, not a grep: dispatch in resume mode against a row that already
# exists (which is exactly why resume skips task-add), then ask the gate itself.
WB18="$(cn18 "$(mktemp -d)")"
env CC_STATE_DB="$TB18D.db" "$CC/cc-state" task-add "$WB18" "" s:1 'resume row' main >/dev/null
eq "window B: no stamp before the resume" "$(env CC_STATE_DB="$TB18D.db" "$CC/cc-state" task-opened-recently "$WB18" 120; echo $?)" "1"
: > "$CC_FAKE_LOG"
env HOME="$FH18" PATH="$CF:$OP18" CC_STATE_DB="$TB18D.db" \
  CC_CMUX_SESSIONS="$ST18" CC_SEND_FAILLOG="$CF/fail" CC_SEND_VERIFY_SEC=0.1 CC_LAUNCH_FILE="$CF/launch" \
  CC_CALLER_SURFACE_UUID="$UP" CC_WT_LAUNCH_CMD='ccteam --resume probe' \
  bash "$CC/cc-dispatch.sh" surface "$WB18" "resume brief" >/dev/null 2>&1
eq "window B: resume really reopened a tab" "$(grep -c 'NEWSURF|' "$CC_FAKE_LOG")" "1"
eq "window B: and it stamped the dedup timestamp" "$(env CC_STATE_DB="$TB18D.db" "$CC/cc-state" task-opened-recently "$WB18" 120; echo $?)" "0"
# …and a workspace open (gwt-new / gwt-adopt path) lands in the same ledger
WSD="$(cn18 "$(mktemp -d)")"
: > "$CC_FAKE_LOG"
env HOME="$FH18" PATH="$CF:$OP18" CC_STATE_DB="$TB18D.db" CC_CALLER_SURFACE_UUID="$UP" \
  bash "$CC/cc-dispatch.sh" workspace "$WSD" >/dev/null 2>&1
WSU="$(grep -oE 'NEWWS\|' "$CC_FAKE_LOG" | head -1)"
eq "workspace really opened one"     "${WSU:-none}" "NEWWS|"
eq "workspace open records a row"    "$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" dump tabs | awk -F'\t' -v d="$WSD" '$3==d{c++} END{print c+0}')" "1"
eq "workspace row records the owner" "$(CC_STATE_DB="$TB18D.db" "$CC/cc-state" dump tabs | awk -F'\t' -v d="$WSD" '$3==d{print $2}')" "$UP"

# — old rows keep working: a 7-field board row parses and simply has no recorded identity —
TF18O=$(mktemp -u); WO7="$(cn18 "$(mktemp -d)")"
printf '2026-01-01 00:00:01\tfeat/O7\tsurface:101\t%s\tsurface:9\tseven fields\tmain\n' "$WO7" | st_seed tasks "$TF18O.db"
# FORMAT PIN: the fixture row's own layout, selected by file position — direct read stays
eq "7-field row still 7 fields" "$(st_dump tasks "$TF18O.db" | awk -F'\t' 'NR==1{print NF}')" "7"
TB18O=$(mktemp -u); : | st_seed tabs "$TF18O.db"
eq "7-field row has nothing to close" "$( ( cd "$R18" && env PATH="$CF:$OP18" CC_STATE_DB="$TF18O.db" \
  CC_STATE_DB="$TF18O.db" CC_CMUX_SESSIONS="$ST18" CC_CALLER_SURFACE_UUID="$UP" CLAUDECODE=1 \
  bash "$CC/cc-dispatch.sh" close "$WO7" 2>&1 | grep -c 'nothing to do' ) )" "1"

# — gwt-rm --close routes the tab close through the primitive (and only that way) —
RM18="$(cn18 "$(mktemp -d)")"
( cd "$RM18"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wtS -b feat/S >/dev/null )
SW18="$(cn18 "$RM18/.claude/worktrees/wtS")"
TF18R=$(mktemp -u); SF18R=$(mktemp -u); TB18R=$(mktemp -u); : | st_seed tabs "$TB18R.db"
printf '2026-01-01 00:00:01\tfeat/S\tsurface:101\t%s\tsurface:9\trm close\tmain\t%s\n' "$SW18" "$(la18 5 "$UP" "$UA")" | st_seed tasks "$TB18R.db"
: > "$CC_FAKE_LOG"
RMOUT="$(env HOME="$FH18" PATH="$CF:$OP18" CC_STATE_DB="$TB18R.db" \
  CC_CMUX_SESSIONS="$ST18" CC_CALLER_SURFACE_UUID="$UP" \
  zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$RM18'; gwt-rm wtS --close" 2>&1)"
eq "gwt-rm --close removed the worktree" "$([ -d "$SW18" ] && echo yes || echo no)" "no"
eq "gwt-rm --close closed BY UUID"       "$(grep -cF "CLOSE|--surface $UA" "$CC_FAKE_LOG")" "1"
eq "gwt-rm --close printed the resolution" "$(echo "$RMOUT" | grep -c "uuid=$UA")" "1"
# a row REMOVAL: raw read (and `dump` of the store gwt-rm may have deleted outright is silently
# empty, so the `2>/dev/null || echo 0` fallback the awk needed is gone rather than muffled)
eq "gwt-rm --close still drops the row"  "$(CC_STATE_DB="$TB18R.db" "$CC/cc-state" dump tasks | awk -F'\t' -v d="$SW18" '$4==d{c++} END{print c+0}')" "0"
# plain gwt-rm (no flag) touches no tab
( cd "$RM18" && git worktree add -q .claude/worktrees/wtT -b feat/T >/dev/null )
ST18B="$(cn18 "$RM18/.claude/worktrees/wtT")"
printf '2026-01-01 00:00:02\tfeat/T\tsurface:102\t%s\tsurface:9\tno close\tmain\t%s\n' "$ST18B" "$(la18 6 "$UP" "$UA")" | st_seed tasks "$TB18R.db"
: > "$CC_FAKE_LOG"
env HOME="$FH18" PATH="$CF:$OP18" CC_STATE_DB="$TB18R.db" \
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
echo "== 35. dispatch state goes through cc-state =="
DB_35="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
# cc-dispatch.sh is on the facade now (state-model Phase A, plan Task 6): the 22 field-level parse
# points and the mkdir locks are gone; what the file keeps is cmux PROBING and the orchestration.
# Structural pins first (what may no longer exist / what must survive), then behaviour: the
# dispatch-window fix (spec §3.1 — the board row used to appear only at the END of a dispatch,
# up to ~40s after the tab opened, so a crash in between left an open tab with no row AND a dedup
# marker blocking the retry), the two defect pins this line owns (spec §3.5 #1: _ccres_dropstatus
# split on whitespace, so a dir WITH A SPACE never lost its sidecar row; #6: _ccres_setref's
# $3=r OFS rebuild widened 7-field legacy rows to 8), and the H1–H3 shape pins from the brief.
# The fake cmux snapshots, on the first read-screen AFTER the launch send, whether the board row
# already exists — a deterministic witness for "the row is there while the trust loop is still
# running", no racing sleep in the test itself.
S35=$(mktemp -d); export CC_35_LOG="$S35/log"; export CC_35_SCREEN="$S35/screen"
export CC_35_STATE="$CC/cc-state"   # the shim below asks the facade, not a store file
sv35TMP="${TMPDIR:-}"; export TMPDIR="$S35/tmp"; mkdir -p "$TMPDIR"
cat > "$S35/cmux" <<'CMUX35'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  identify) echo '{ "caller": { "surface_ref": "surface:9", "workspace_ref": "workspace:1" } }' ;;
  list-workspaces)
    [ -n "${CC_35_NOWS:-}" ] && exit 0
    printf '* workspace:1  fake  [selected]\n' ;;
  list-pane-surfaces) cat "${CC_35_LIVE:-/dev/null}" 2>/dev/null ;;
  new-surface)
    n=$(cat "${CC_35_LOG}.nscnt" 2>/dev/null || echo 500); n=$((n+1)); echo "$n" > "${CC_35_LOG}.nscnt"
    printf 'NEWSURF|surface:%s|%s\n' "$n" "$*" >> "$CC_35_LOG"
    printf 'OK surface:%s (99999999-7777-7777-7777-%012d) pane:1 (P) workspace:1 (W)\n' "$n" "$n" ;;
  close-surface) shift; printf 'CLOSE|%s\n' "$*" >> "$CC_35_LOG" ;;
  send)     shift; printf 'SEND|%s\n' "$*" >> "$CC_35_LOG"
            case "$*" in *ccteam*|*"cld "*) : > "${CC_35_LOG}.launched" ;; esac ;;
  send-key) shift; printf 'KEY|%s\n'  "$*" >> "$CC_35_LOG" ;;
  notify)   shift; printf 'NOTIFY|%s\n' "$*" >> "$CC_35_LOG" ;;
  read-screen)
    cat "$CC_35_SCREEN" 2>/dev/null
    if [ -f "${CC_35_LOG}.launched" ] && [ ! -e "${CC_35_LOG}.saw" ]; then
      if "$CC_35_STATE" dump tasks 2>/dev/null | grep -qF -- "$CC_35_DIR"; then
        echo row > "${CC_35_LOG}.saw"
      else
        echo norow > "${CC_35_LOG}.saw"
      fi
    fi ;;
esac
exit 0
CMUX35
chmod +x "$S35/cmux"
NB35="$(printf '\xc2\xa0')"
{ echo "RDY22"; printf '\xe2\x9d\xaf%s\n' "$NB35"; echo "? for shortcuts"; } > "$S35/scr-tui"
{ echo "RDY22"; printf '\xe2\x9d\xaf%s\n' "$NB35"; } > "$S35/scr-settle"   # no TUI markers: trust loop runs its full course
OP35="$PATH"
in35close(){ sed -n '/^close)/,/^;;/p' "$CC/cc-dispatch.sh" | grep -c "$1" | awk '{print ($1>0)?"yes":"no"}'; }

# ── structure: the facade carries the state, the shell keeps the probe ─────────────────────
eq "35 close resolves via tab-resolve"    "$(grep -c 'cc-state" tab-resolve' "$CC/cc-dispatch.sh")" "1"
eq "35 close still probes liveness itself" "$(in35close '_cctabs_livemap')" "yes"
eq "35 cmux session-store fallback untouched" "$(in35close 'CC_CMUX_SESSIONS')" "yes"
# (Task 9) the "cc-board log call is gone" eq that lived here was DELETED, not kept:
# cc-board.sh log itself is retired, so a grep for calls to it can never go red again —
# an always-green assertion that reads like coverage while testing nothing (round-2 pit 1).
# The write path's contract now lives in §32 (frozen oracle + the migrated §2 groups).
# NB: there is deliberately NO "no tabs-file awk left" structural assertion here. The old
# offenders were MULTILINE awk invocations (the awk -F'\t' and the "$_tf" argument sit on
# different physical lines), so every line-based grep counts 0 against the old code too — an
# always-green assertion that reads like coverage while testing nothing (gate round 2). The real
# guards on "the ledger is not parsed by hand any more": `_cctabs_lock` = 0 below (the lock every
# direct rewrite needed), `cc-state" tab-resolve` = 1 above, and the behavioural suites — §18
# (close/tabs over both ledgers), §21 (the sourced prune fragment), §26 (workspace-scope prune).
eq "35 no mkdir lock left"     "$(grep -c '_cctabs_lock' "$CC/cc-dispatch.sh")" "0"
# the facade never forks a probe: cmux names in it are backend facts (the $TMPDIR marker dir,
# CMUX_SURFACE_ID), not dependencies. (It may NAME cmux; it may not RUN anything but git.)
eq "35 git is the only command cc-state runs" \
  "$(grep -oE 'subprocess\.run\(\["[a-z-]+"' "$CC/cc-state" | sort -u | tr '\n' ',')" \
  'subprocess.run(["git",'

# ── the dispatch window (spec §3.1): the board row exists WHILE the tab is still settling ───
cn35(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
DD35="$(cn35 "$(mktemp -d)")"; TF35=$(mktemp -u); TB35=$(mktemp -u)   # physical: the row records surface's canonical form
: > "$CC_35_LOG"; rm -f "${CC_35_LOG}.nscnt" "${CC_35_LOG}.saw" "${CC_35_LOG}.launched"
export CC_35_DIR="$DD35"; export CC_35_LIVE="$S35/live.empty"; : > "$CC_35_LIVE"
CC_35_SCREEN="$S35/scr-settle" \
env PATH="$S35:$OP35" TMPDIR="$TMPDIR" CC_STATE_DB="$DB_35" \
  CC_SEND_FAILLOG="$S35/fail" CC_SEND_VERIFY_SEC=0.1 CC_LAUNCH_FILE="$S35/launch" \
  CC_WT_PRETRUST=0 CC_WT_SESSION_ID="abcdef01-1234-4567-890a-bcdef0123456" \
  CC_WT_PERMISSION_MODE=plan CC_CALLER_SURFACE_UUID="CCCCCCCC-3333-3333-3333-333333333333" \
  bash "$CC/cc-dispatch.sh" surface "$DD35" "window probe brief" >/dev/null 2>&1
eq "35 board row exists while the tab is still settling" "$(cat "${CC_35_LOG}.saw" 2>/dev/null)" "row"
eq "35 dispatch opened exactly one tab"  "$(grep -c 'NEWSURF' "$CC_35_LOG")" "1"
# (Task 8) the dispatch row's assertions read through the facade — task-get picks the dir's
# newest row (what the old '$4==d' awk selected); TF35 is a section-local file, so the read
# is env-scoped to it. Expected values unchanged.
eq "35 completed row has its launch args" "$(CC_STATE_DB="$DB_35" "$CC/cc-state" task-get "$DD35" | awk -F'\t' '{print ($8 ~ /uuid=/)?"y":"n"}')" "y"
eq "35 completed row has its caller ref"  "$(CC_STATE_DB="$DB_35" "$CC/cc-state" task-get "$DD35" | awk -F'\t' '{print $5}')" "surface:9"
# D 期：戳记是 tasks 上的 tab_opened_ts 列,不再是 $TMPDIR 里的标记文件。问题没变 ——
# 「这个 dir 最近开过 tab 吗」—— 所以这两条断言的主题一字未动,只是问法换了。
eq "35 dispatch stamped the dedup timestamp" \
  "$(env CC_STATE_DB="$DB_35" "$CC/cc-state" task-opened-recently "$DD35" 120; echo $?)" "0"

# H2 window: a fresh marker silently eats the retry; a 121s-stale one lets it through
n35b=$(grep -c 'NEWSURF' "$CC_35_LOG")
env PATH="$S35:$OP35" TMPDIR="$TMPDIR" CC_STATE_DB="$DB_35" \
  CC_SEND_FAILLOG="$S35/fail" CC_SEND_VERIFY_SEC=0.1 CC_WT_PRETRUST=0 \
  bash "$CC/cc-dispatch.sh" surface "$DD35" "retry brief" >/dev/null 2>&1
eq "35 fresh stamp eats the retry"  "$([ "$(grep -c 'NEWSURF' "$CC_35_LOG")" = "$n35b" ] && [ "$(CC_STATE_DB="$DB_35" "$CC/cc-state" dump tasks | wc -l | tr -d ' ')" = 1 ] && echo yes || echo no)" "yes"
# 把戳记做旧 121 秒（原来是 touch -t 那个标记文件）
python3 -c 'import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE tasks SET tab_opened_ts=? WHERE tab_opened_ts IS NOT NULL", (int(time.time()) - 121,))
c.commit()' "$DB_35"
: > "$CC_35_LOG"; rm -f "${CC_35_LOG}.nscnt"
CC_35_SCREEN="$S35/scr-tui" \
env PATH="$S35:$OP35" TMPDIR="$TMPDIR" CC_STATE_DB="$DB_35" \
  CC_SEND_FAILLOG="$S35/fail" CC_SEND_VERIFY_SEC=0.1 CC_WT_PRETRUST=0 \
  bash "$CC/cc-dispatch.sh" surface "$DD35" "retry brief" >/dev/null 2>&1
eq "35 stale (121s) stamp lets the retry through" "$(grep -c 'NEWSURF' "$CC_35_LOG")" "1"

# ── H1 shape: close's refusal and partial-evidence sentences, byte for byte ────────────────
UA35="AAAAAAAA-1111-1111-1111-111111111111"; UB35="BBBBBBBB-2222-2222-2222-222222222222"
UP35="CCCCCCCC-3333-3333-3333-333333333333"; UO35="DDDDDDDD-4444-4444-4444-444444444444"
R35="$(mktemp -d)"; mkdir -p "$R35/.claude/worktrees/wt35"; WA35="$R35/.claude/worktrees/wt35"
printf '  surface:100\t%s\tw1\n' "$UA35" > "$S35/live.one"
TF35C=$(mktemp -u); TB35C=$(mktemp -u); echo '{}' > "$S35/store35.json"
cl35(){ ( cd "$R35" && env PATH="$S35:$OP35" CC_STATE_DB="$DB_35" \
    CC_CMUX_SESSIONS="$S35/store35.json" CC_CALLER_SURFACE_UUID="${2:-$UP35}" CLAUDECODE=1 \
    CC_35_NOWS="${3:-}" CC_35_LIVE="${4:-$S35/live.one}" \
    bash "$CC/cc-dispatch.sh" close "${1:-$WA35}" ) 2>&1; }
# both ledgers name no owner: the refusal an automated caller gets
printf '2026-01-01 00:00:01\tfeat/h1a\tsurface:101\t%s\tsurface:9\tno owner row\tmain\tuuid=u1:provider=anthropic:pm=auto:suuid=%s\n' "$WA35" "$UA35" | st_seed tasks "$DB_35"
printf '%s\t-\t%s\tu1\t2026-01-01 00:00:00\n' "$UA35" "$WA35" | st_seed tabs "$DB_35"
cl35 > "$S35/h1a.out"; h1a_rc=$?
eq "35 H1 no-owner refusal rc" "$h1a_rc" "1"
eq "35 H1 no-owner refusal sentence" \
  "$(grep -c 'refusing: no dispatching parent recorded for this dir and the branch is not marked ready — treat it as human-opened' "$S35/h1a.out")" "1"
# no workspace list at all = the least complete evidence: nothing closed, and the claim is qualified
printf '  surface:300\t%s\tw1\n' "$UP35" > "$S35/live.other"
cl35 "$WA35" "" 1 "$S35/live.other" > "$S35/h1b.out"; h1b_rc=$?
eq "35 H1 partial probe rc" "$h1b_rc" "0"
eq "35 H1 partial probe says nothing to do" \
  "$(grep -c 'no live tab resolves to this directory' "$S35/h1b.out")" "1"
eq "35 H1 partial probe qualifies its claim" \
  "$(grep -c 'cmux workspace enumeration was incomplete — the tab may be alive in a workspace unseen by this probe' "$S35/h1b.out")" "1"
# board identity dead, ledger identity live: the cascade takes the LIVE one and the recorded
# parent still comes off the board row (owner = board csuuid, not the ledger's opener)
printf '2026-01-01 00:00:01\tfeat/h1c\tsurface:101\t%s\tsurface:9\tdead board id\tmain\tuuid=u2:provider=anthropic:pm=auto:csuuid=%s:suuid=%s\n' "$WA35" "$UO35" "$UB35" | st_seed tasks "$DB_35"
printf '%s\t%s\t%s\tu2\t2026-01-01 00:00:00\n' "$UA35" "$UA35" "$WA35" | st_seed tabs "$DB_35"
: > "$CC_35_LOG"
cl35 "$WA35" "$UO35" > "$S35/h1c.out"
eq "35 cascade picks the LIVE identity" \
  "$(grep -c "resolved : surface:100  uuid=$UA35" "$S35/h1c.out")/$(grep -cF "CLOSE|--surface $UA35" "$CC_35_LOG")" "1/1"
eq "35 parent stays the board row's csuuid" "$(grep -c "recorded : parent=$UO35" "$S35/h1c.out")" "1"

# ── resume: the two defect pins + the verbatim-dir invariant (H3) ───────────────────────────
FH35=$(mktemp -d); mkdir -p "$FH35/.config"; cp -R "$CC" "$FH35/.config/cc-stack"
RD35="$(mktemp -d)"
DSP35="$RD35/wt space"; D735="$RD35/wt7"                            # the space dir is spec §3.5 #1's fixture
mkdir "$DSP35" "$D735"
# the third row's dir is recorded by its LOGICAL path string (mktemp prints /var/... on macOS;
# cd+pwd -P would give /private/var/... — two strings, one dir: the H3 edge)
LOGD35="$(mktemp -d)"; PHYD35="$(cd "$LOGD35" && pwd -P)"
SP35="33333333-3333-3333-3333-333333333333"; S735="44444444-4444-4444-4444-444444444444"
TF35R=$(mktemp -u); SF35R=$(mktemp -u)
printf '2026-01-01 00:00:01\tfeat/sp35\tsurface:12\t%s\tsurface:1\tspace dir\tmain\tuuid=11111111-1111-1111-1111-111111111111:provider=anthropic:pm=auto\n' "$DSP35" | st_seed tasks "$DB_35"
printf '2026-01-01 00:00:02\tfeat/f7-35\tsurface:13\t%s\tsurface:1\tseven field row\tmain\n' "$D735" | st_append tasks "$DB_35"
printf '2026-01-01 00:00:03\tfeat/log35\tsurface:14\t%s\tsurface:1\tlogical dir row\tmain\tuuid=55555555-5555-5555-5555-555555555555:provider=anthropic:pm=plan\n' "$LOGD35" | st_append tasks "$DB_35"
printf '%s\tblocked\t100\n' "$DSP35" | st_seed status "$DB_35"
printf '%s\tidle\t100\n' "$LOGD35" | st_append status "$DB_35"
# D 期：状态是任务行上的列 —— 「无关的 sidecar 行」就是「一条带状态的无关任务行」
printf '2026-01-01 00:00:04\tfeat/els35\tsurface:15\t%s\tsurface:1\telsewhere row\tmain\n' "$RD35/elsewhere" | st_append tasks "$DB_35"
printf '%s\tworking\t100\n' "$RD35/elsewhere" | st_append status "$DB_35"
python3 - "$SP35" "$DSP35" "$S735" "$D735" > "$S35/store35b.json" <<'PY35'
import json, sys
sp, dsp, s7, d7 = sys.argv[1:5]
json.dump({"sessions": {
  "33333333-0000-0000-0000-000000000001": {"surfaceId": sp, "cwd": dsp, "updatedAt": 200},
  "44444444-0000-0000-0000-000000000002": {"surfaceId": s7, "cwd": d7, "updatedAt": 200},
}, "version": 3}, sys.stdout)
PY35
{ printf '  surface:41\t%s\tw1\n' "$SP35"; printf '  surface:42\t%s\tw1\n' "$S735"; } > "$S35/live.resume"
: > "$CC_35_LOG"; rm -f "${CC_35_LOG}.nscnt"
CC_35_LIVE="$S35/live.resume" CC_35_SCREEN="$S35/scr-tui" \
env HOME="$FH35" PATH="$S35:$OP35" TMPDIR="$TMPDIR" CC_STATE_DB="$DB_35" \
  CC_STATE_DB="$DB_35" CC_CMUX_SESSIONS="$S35/store35b.json" CC_RESUME_SETTLE=0 \
  CC_SEND_VERIFY_SEC=0.1 CC_WT_PRETRUST=0 CC_SEND_FAILLOG="$S35/fail" \
  bash -c 'printf "y\n" | "$0" resume --all' "$FH35/.config/cc-stack/cc-dispatch.sh" >/dev/null 2>&1
# spec §3.5 #1 — _ccres_dropstatus split on whitespace; a dir WITH A SPACE never lost its row
# (Task 8) sidecar reads via `dump status`, env-scoped to the section-local file
eq "35 resume clears a space-dir sidecar row" "$(CC_STATE_DB="$DB_35" "$CC/cc-state" dump status | grep -cF "$DSP35")" "0"
eq "35 resume clears the reopened dir's sidecar row" "$(CC_STATE_DB="$DB_35" "$CC/cc-state" dump status | grep -cF "$LOGD35")" "0"
eq "35 resume keeps unrelated sidecar rows"  "$(CC_STATE_DB="$DB_35" "$CC/cc-state" dump status | grep -cF "$RD35/elsewhere")" "1"
# spec §3.5 #6 — the old $3=r OFS rebuild widened legacy rows; the facade rewrite must not
eq "35 resume keeps a 7-field row 7 fields" \
  "$(CC_STATE_DB="$DB_35" "$CC/cc-state" task-get "$D735" | awk -F'\t' '{print NF}')" "7"
eq "35 7-field row still got its ref refreshed" \
  "$(CC_STATE_DB="$DB_35" "$CC/cc-state" task-get "$D735" | awk -F'\t' '{print $3}')" "surface:42"
# H3 — the recorded dir string survives the refresh as the row's own field (the facade matches it
# through the canonical form; what it writes back is the RECORDED string), and the reopened tab
# went to that dir (surface canonicalizes for cmux, as it always has)
eq "35 refreshed row keeps its logical dir string" \
  "$(CC_STATE_DB="$DB_35" "$CC/cc-state" task-get "$LOGD35" | awk -F'\t' '{print $4}')" "$LOGD35"
eq "35 logical row's tab reopened in its dir" \
  "$(grep 'NEWSURF' "$CC_35_LOG" | grep -cF -- "--working-directory $PHYD35")" "1"

rm -rf "$S35" "$FH35" "$R35" "$RD35" "$DD35"
rm -f "$TF35" "$TB35" "$TF35C" "$TB35C" "$TF35R" "$SF35R"
unset CC_35_LOG CC_35_SCREEN CC_35_DIR CC_35_LIVE
if [ -n "$sv35TMP" ]; then export TMPDIR="$sv35TMP"; else unset TMPDIR; fi
cc_sandbox_ledgers

echo ""
echo "== 25. commit gate: git's own pre-commit hook (migrated 2026-08-16) =="
DB_25="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
( cd "$CGDR" && env HOME="$FH25" PATH="$CGS:$OP25" CC_STATE_DB="$DB_25" \
    CC_STATE_DB="$DB_25" CC_WT_PRETRUST=0 CC_WT_SHARE="" CC_SEND_VERIFY_SEC=0.1 \
    CC_SEND_FAILLOG="$CGS/fail" bash "$CC/cc-dispatch.sh" surface "$CGDW" ) >/dev/null 2>&1
eq "surface mounts the gate"             "$(grep -c 'cc-stack:commit-gate' "$CGDR/.git/hooks/pre-commit" 2>/dev/null || echo 0)" "1"
cgb="$(cgn "$CGDW")"
( cd "$CGDW" && git commit -q --allow-empty -m x ) >/dev/null 2>&1
eq "and a dispatched worktree is gated"  "$(cgn "$CGDW")" "$cgb"
# a MAIN checkout handed to the public `surface` subcommand gets no hook it never asked for
CGT=$(mktemp -d); CGTR="$(cn "$CGT")"
( cd "$CGTR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i )
( cd "$CGDR" && env HOME="$FH25" PATH="$CGS:$OP25" CC_STATE_DB="$DB_25" \
    CC_STATE_DB="$DB_25" CC_WT_PRETRUST=0 CC_WT_SHARE="" CC_SEND_VERIFY_SEC=0.1 \
    CC_SEND_FAILLOG="$CGS/fail" bash "$CC/cc-dispatch.sh" surface "$CGTR" ) >/dev/null 2>&1
eq "a plain main checkout is left alone" "$([ -e "$CGTR/.git/hooks/pre-commit" ] && echo present || echo gone)" "gone"
# and the workspace path (gwt-new / gwt-adopt) mounts it too
CGN=$(mktemp -d); CGNR="$(cn "$CGN")"
( cd "$CGNR"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  mkdir .claude; git worktree add -q .claude/worktrees/wn -b feat/wn >/dev/null )
( cd "$CGNR" && env HOME="$FH25" PATH="$CGS:$OP25" CC_STATE_DB="$DB_25" \
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
unstamp "$DB_25"
rm -rf "$CG" "$CGP" "$CGH" "$CGF" "$CGS" "$FH25" "$CGD" "$CGT" "$CGN" "$CGI" "$CGJ"
unset CC_FAKE_LOG25 CF_SCREEN25

echo ""
echo "== 30. wtz-guards: gwt-rm destructive-path guards + gwt-tree cross-workspace liveness + CC_WT_COPY no-overwrite =="
DB_30="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
w30env(){ echo "CC_STATE_DB='$DB_30' CC_TRUST_CFG_OVERRIDE='$W30_TRUST' CC_WT_SHARE=''"; }

# ── F1: dirty worktree refused without --force ───────────────────────────────────────────────
W30_D=$(mktemp -d); W30_D="$(W30_CN "$W30_D")"
( cd "$W30_D"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/dirty -b feat/dirty >/dev/null )
W30_W="$W30_D/.claude/worktrees/dirty"
echo "uncommitted work" > "$W30_W/untracked.txt"
printf '2026-01-01 00:00:01\tfeat/dirty\tsurface:61\t%s\tsurface:1\tdirty row\tmain\n' "$W30_W" | st_seed tasks "$DB_30"
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_D'; $(w30env) gwt-rm dirty" 2>&1)"; W30_RC=$?
eq "30 dirty tree: rc!=0"              "$([ "$W30_RC" -ne 0 ] && echo y || echo n)" "y"
eq "30 dirty tree: says uncommitted"   "$(echo "$W30_O" | grep -c 'uncommitted changes')" "1"
eq "30 dirty tree: lists the files"    "$(echo "$W30_O" | grep -c 'untracked.txt')" "1"
eq "30 dirty tree: worktree survives"  "$([ -d "$W30_W" ] && echo y || echo n)" "y"
# (Task 8b) the guard's whole point is that NOTHING was written — read the raw store, a filtered
# view would answer the same with the row already gone
eq "30 dirty tree: board row survives" "$(CC_STATE_DB="$DB_30" "$CC/cc-state" dump tasks | grep -c 'dirty row')" "1"
eq "30 dirty tree: sidecar untouched"  "$([ -f "$W30_S" ] && echo y || echo n)" "y"
# --force names the deletion: worktree AND its uncommitted file fall, branch stays (no --branch)
W30_O="$(zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; cd '$W30_D'; $(w30env) gwt-rm dirty --force" 2>&1)"; W30_RC=$?
eq "30 --force: rc=0"                  "$W30_RC" "0"
eq "30 --force: worktree gone"         "$([ -d "$W30_W" ] && echo y || echo n)" "n"
eq "30 --force: branch kept (no --branch)" "$(git -C "$W30_D" branch --list 'feat/dirty' | wc -l | tr -d ' ')" "1"
# cat-first: a successful gwt-rm may leave the TSV deleted (_gwt_drop_lines removes an emptied file)
eq "30 --force: board row dropped"     "$(CC_STATE_DB="$DB_30" "$CC/cc-state" dump tasks | grep -c 'dirty row')" "0"

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
printf '2026-01-01 00:00:01\tfeat/w30A\tsurface:101\t%s\tsurface:1\ttask A\tmain\n' "$W30_R/.claude/worktrees/wtA" | st_seed tasks "$DB_30"
printf '2026-01-01 00:00:02\tfeat/w30B\tsurface:202\t%s\tsurface:1\ttask B\tmain\n' "$W30_R/.claude/worktrees/wtB" | st_append tasks "$DB_30"
printf '2026-01-01 00:00:03\tfeat/w30C\tsurface:10\t%s\tsurface:1\ttask C\tmain\n' "$W30_R/.claude/worktrees/wtC" | st_append tasks "$DB_30"
printf '2026-01-01 00:00:04\tfeat/w30D\tsurface:3\t%s\tsurface:1\ttask D\tmain\n' "$W30_R/.claude/worktrees/wtD" | st_append tasks "$DB_30"
w30tree(){ ( cd "$W30_R" && PATH="$W30_WS:$PATH" CC_FAKE_WSDOWN="${1:-}" CC_STATE_DB="$DB_30" \
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
echo ""
echo "== 36. worktree.zsh state via cc-state =="
# Phase A on the zsh layer (docs/state-model.md): every state mutation goes through the
# facade, so the four mkdir-lock loops, the _gwt_dead_lines/_gwt_drop_lines dropper, the
# predicate rewriters and gwt-prune's tail-r dedup pipeline are gone from worktree.zsh.
# What stays is the zsh interaction layer: messages, guards, and the two named shims
# (_gwt_tasks_drop_dir / _gwt_archive_branch) older callers still invoke by name.
eq "36 no zsh lock loops left"       "$(grep -c 'mkdir "\$lock"' "$CC/worktree.zsh")" "0"
eq "36 no hand-rolled line dropper"  "$(grep -c '_gwt_drop_lines' "$CC/worktree.zsh")" "0"
eq "36 no dead-line collector left"  "$(grep -c '_gwt_dead_lines' "$CC/worktree.zsh")" "0"
eq "36 no predicate rewriters left"  "$(grep -cE '_gwt_(tasks|status)_rewrite' "$CC/worktree.zsh")" "0"
eq "36 gwt-rm clears state by dir"   "$(grep -c 'task-clear-state' "$CC/worktree.zsh")" "1"
# gwt-prune's three messages survive the facade swap byte-for-byte (the had/-s shape against
# the facade's empty-set-deletes-file lifecycle) — gwt-rm's sidecar drop uses clear-state,
# not prune, because that dir may still exist when the row must go (the 2026-08-22 ruling).
cn36(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
zw36(){ zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; $*" ; }
S36=$(mktemp -d); T36="$S36/t.tsv"; ST36="$S36/s.tsv"; A36="$S36/a.tsv"
export CC_STATE_DB="$T36.db"
L36='uuid=36363636-1111-2222-3333-444444444444:provider=glm:pm=auto:model=g1'
D36A="$(cn36 "$(mktemp -d)")"; D36B="$(cn36 "$(mktemp -d)")"; D36D="$S36/gone"   # D36D never created
zw36 gwt-prune >"$S36/p0" 2>&1; eq "36 prune: no list says so" "$(cat "$S36/p0")" "list is empty"
printf '2026-01-01 00:00:01\tfeat/A\tsurface:71\t%s\tsurface:9\tthirtysix A\tmain\t%s\n' "$D36A" "$L36" | st_seed tasks
printf '%s\tidle\t1700000001\n%s\tworking\t1700000002\n' "$D36A" "$D36D" | st_seed status
zw36 gwt-prune >"$S36/p1" 2>&1; eq "36 prune: live rows compacted" "$(cat "$S36/p1")" "✔ task list compacted"
# (Task 8b, §4-trap) what the sweep left on disk → raw `dump status` (the stores are exported
# above); a filtered view hides dead rows at read time and would pass with no sweep at all
eq "36 prune keeps the live sidecar row"  "$("$CC/cc-state" dump status | grep -cF "$D36A")" "1"
eq "36 prune swept the dead sidecar row"  "$("$CC/cc-state" dump status | grep -cF "$D36D")" "0"
# a list whose dirs are ALL gone empties AND removes the file — the facade deletes an emptied
# store; the had-check keeps the three messages distinguishable
rm -rf "$D36A"
zw36 gwt-prune >"$S36/p2" 2>&1; eq "36 prune: all dead says emptied" "$(cat "$S36/p2")"$'\n'"$([ -f "$T36" ] && echo kept || echo gone)" "✔ emptied (no live records)"$'\n'"gone"
# CHANGED, C phase Task 1 — recorded, not silent. A store the facade never wrote: zero bytes on
# disk, truncated by hand. gwt-prune used to stat the FILE, so it read this as "there is a list
# and pruning emptied it" (✔ emptied) and unlinked it; it now asks cc-state exists, which is
# defined on ROWS, so the same store reads as "no rows" — the empty-list message, and the
# zero-byte file left alone. The stack cannot produce this state (every store cc-state empties
# is unlinked), and once the four TSVs are one library there is no per-store file to truncate.
: > "$T36"
zw36 gwt-prune >"$S36/p3" 2>&1; eq "36 prune: a hand-truncated store reads as empty" "$(cat "$S36/p3")"$'\n'"$([ -f "$T36" ] && echo kept || echo gone)" "list is empty"$'\n'"kept"
rm -f "$T36"
mkdir -p "$D36A"
# _gwt_archive_branch through the facade: the archived row is the tasks row VERBATIM with
# merged-at appended (8→9 fields), launch-args and the empty caller field intact
printf '2026-01-01 00:00:02\tfeat/B\tsurface:72\t%s\t\tarch B (empty caller)\tmain\t%s\n' "$D36B" "$L36" | st_seed tasks
printf '2026-01-01 00:00:03\tfeat/C\tsurface:73\t%s\tsurface:9\tarch C stays\tfeat/B\t%s\n' "$D36A" "$L36" | st_append tasks
printf '%s\tidle\t1700000003\n%s\tidle\t1700000004\n' "$D36B" "$D36A" | st_seed status
O36="$(zw36 "_gwt_archive_branch feat/B")"; r36=$?
eq "36 archive summary line"              "$O36" "  ↳ archived 1 record(s) for feat/B (see gwt-log)"
# FORMAT PINS (§32-class, direct read stays): 8 live fields → 9 with merged-at appended, and an
# empty 5th field still empty IN PLACE — the archive row's layout is the object under test here,
# and the branch-keyed selection is not a question any facade verb answers.
eq "36 archive row keeps every field"     "$(st_dump archive | awk -F'\t' '$2=="feat/B"{print NF}')" "9"
eq "36 archive keeps the empty caller"    "$(st_dump archive | awk -F'\t' '$2=="feat/B"{print $5"|"$8}')" "|$L36"
eq "36 archive leaves other branches"     "$("$CC/cc-state" dump tasks | awk -F'\t' '$2=="feat/C"' | wc -l | tr -d ' ')" "1"
eq "36 archive swept the moved sidecar"   "$("$CC/cc-state" dump status | grep -cF "$D36B")" "0"
eq "36 archive kept the other sidecar"    "$("$CC/cc-state" dump status | grep -cF "$D36A")" "1"
# defects 4/5 (spec §3.5): an archive rewrite failure is LOUD — rc 1 out of the shim,
# stderr names it, the task list is left untouched — the rc is never eaten
printf '2026-01-01 00:00:04\tfeat/F\tsurface:74\t%s\tsurface:9\tfail me\tmain\t%s\n' "$D36A" "$L36" | st_seed tasks
st_dump tasks > "$S36/t.before"; : > "$S36/f.out"; : > "$S36/f.err"
# an unwritable LIBRARY: the file refuses the write and the directory refuses the -wal sidecar
chmod 444 "$T36.db"; chmod 500 "$S36"
zw36 "_gwt_archive_branch feat/F" >"$S36/f.out" 2>"$S36/f.err"; r36f=$?
chmod 700 "$S36"; chmod 644 "$T36.db"
eq "36 archive failure rc1"               "$r36f" "1"
eq "36 archive failure surfaces"          "$(grep -c 'archive rewrite failed' "$S36/f.err")" "1"
eq "36 archive failure leaves tasks untouched" "$(st_dump tasks | cmp -s - "$S36/t.before" && echo same || echo differ)" "same"
# and it is equally audible through gwt-merge itself — the call site does not swallow it
R36=$(mktemp -d)
( cd "$R36"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  git branch -M main; mkdir -p .claude; git worktree add -q .claude/worktrees/wtF36 -b feat/F36 >/dev/null )
"$CC/cc-merge.sh" set-parent "$R36" feat/F36 main
"$CC/cc-merge.sh" done "$R36" feat/F36 true
( cd "$R36/.claude/worktrees/wtF36" && git commit -q --allow-empty -m f36 )
printf '2026-01-01 00:00:05\tfeat/F36\tsurface:75\t%s\tsurface:9\tmerge fail archive\tmain\t%s\n' "$R36/.claude/worktrees/wtF36" "$L36" | st_seed tasks
chmod 444 "$T36.db"; chmod 500 "$S36"
M36="$(printf '\ny\n' | zw36 "cd '$R36'; gwt-merge feat/F36" 2>&1)"; m36=$?
chmod 700 "$S36"; chmod 644 "$T36.db"
eq "36 merge itself still exits 0"        "$m36" "0"
eq "36 archive failure audible through gwt-merge" "$(echo "$M36" | grep -c 'archive rewrite failed')" "1"
# defect 2 (spec §3.5): _gwt_archive_branch matched on branch NAME alone, so merging feat/S
# in repo A archived repo B's feat/S rows too. gwt-merge now scopes the archive call to its
# own repo root; B's same-name row must survive untouched.
R36A=$(mktemp -d); R36B=$(mktemp -d)
( cd "$R36A"; git init -q; git config user.email t@t; git config user.name t; git commit -q --allow-empty -m i
  git branch -M main; mkdir -p .claude; git worktree add -q .claude/worktrees/wtS -b feat/S >/dev/null )
WS36A="$R36A/.claude/worktrees/wtS"; WS36B="$R36B/wtS"; mkdir -p "$WS36B"
"$CC/cc-merge.sh" set-parent "$R36A" feat/S main
"$CC/cc-merge.sh" done "$R36A" feat/S true
( cd "$WS36A" && git commit -q --allow-empty -m s36 )
printf '2026-01-01 00:00:06\tfeat/S\tsurface:76\t%s\tsurface:9\trepo A same-branch\tmain\t%s\n' "$WS36A" "$L36" | st_seed tasks
printf '2026-01-01 00:00:07\tfeat/S\tsurface:77\t%s\tsurface:9\trepo B same-branch\tmain\t%s\n' "$WS36B" "$L36" | st_append tasks
printf '\ny\n' | zw36 "cd '$R36A'; gwt-merge feat/S" >/dev/null 2>&1
eq "36 archiving in repo A leaves repo B's row alone" "$("$CC/cc-state" dump tasks | grep -c 'repo B same-branch')" "1"
eq "36 repo A's own row did move"                     "$("$CC/cc-state" dump tasks | grep -c 'repo A same-branch')" "0"
eq "36 only repo A's row reached the archive"         "$("$CC/cc-state" dump archive | grep -c 'same-branch')" "1"
# item 3 of the D plan, end to end: the archive row records the branch the merge actually
# LANDED ON, not the parent recorded at dispatch — gwt-merge's --into override and a target
# that fast-forwarded make those two different, and only this one is history.
eq "36 gwt-merge records the target it merged into"   "$("$CC/cc-state" dump archive | awk -F'\t' '/same-branch/{print $NF}')" "main"
eq "36 gwt-merge scopes its archive call"             "$(grep -c '_gwt_archive_branch "$child" "$root" "$target"' "$CC/worktree.zsh")" "1"
rm -rf "$S36" "$R36" "$D36A" "$D36B" "$R36A" "$R36B" "$WS36B"; cc_sandbox_ledgers

echo "== 19b. fail-closed path guards (partial-shell incident 2026-08-16) =="
DB_19b="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
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
env CC_STATE_DB="$DB_19b" \
  CC_TRUST_CFG_OVERRIDE="$CC_TEST_SANDBOX/19b-claude.json" \
  zsh -c 'source "'"$CC"'/worktree.zsh" >/dev/null 2>&1; cd "'"$GT2"'"; gwt-rm wtguard --branch' >/dev/null 2>&1
eq "gwt-rm healthy path still works" "$(git -C "$GT2" worktree list --porcelain | grep -c wtguard)" "0"
rm -rf "$GT2"


echo ""
echo "== 37. storage awareness lives in the facade (C phase, Task 1) =="
DB_37="$(mktemp -u).db"   # this section's library: one per store set, like the per-section files before it
# The nine places outside cc-state that knew WHICH FILE the state lives in were all
# `[ -f <store> ]` prechecks, and every one of them is fail-silent-empty: after the engine
# swap the file is simply not there any more, the check goes false, and the caller takes its
# "nothing here" branch without a word. The whole class is invisible to an "empty store →
# empty output" assertion, because empty output is what BOTH branches produce. So every
# assertion below pits the two branches against each other — store ABSENT (message names the
# store) vs store PRESENT but nothing matched (message says "no records"/"none of mine") —
# which is exactly the distinction the `[ -f ]` used to draw and the new verb must keep.
#
# `cc-state exists <store>` is defined on ROWS, not on files: rc 0 = at least one row.
# The two are the same question today only because _write_unlocked DELETES an emptied store,
# and only the row question still means something once the four TSVs become one library.
cn37(){ CDPATH= cd -- "$1" >/dev/null 2>&1 && pwd -P; }
S37=$(mktemp -d); S37="$(cn37 "$S37")"
T37="$S37/tasks.tsv"; ST37="$S37/status.tsv"; A37="$S37/archive.tsv"; TB37="$S37/tabs.tsv"
st37(){ env CC_STATE_DB="$DB_37" \
            "$CC/cc-state" "$@"; }
ex37(){ st37 exists "$1" >"$S37/o" 2>"$S37/e"; echo $?; }

# ── the verb's contract: the engine swap replaced its implementation, not one word of this ──
# Task 1 defined `exists` on ROWS rather than on files precisely so these sentences would
# survive this moment, and they did — what changed is only how a fixture says "empty": there
# is no per-store file to rm any more, so an empty store is one that has been loaded empty.
: | st_seed tasks "$DB_37"
eq "37 exists: absent store is rc 1"          "$(ex37 tasks)" "1"
eq "37 exists: rc 1 is silent"                "$(cat "$S37/o")$(cat "$S37/e")" ""
printf 'one row\n' | st_seed tasks "$DB_37"
eq "37 exists: a store with a row is rc 0"    "$(ex37 tasks)" "0"
eq "37 exists: rc 0 is silent"                "$(cat "$S37/o")$(cat "$S37/e")" ""
# The old fixture here truncated the store FILE to zero bytes to prove the contract is "at
# least one ROW, not the file is there". There is no per-store file left to truncate, but the
# distinction did not disappear — it MOVED: the library file now exists as soon as ANY store
# has a row, so "the backing file is there" and "this store has rows" have come apart for
# real, in production, instead of only under a hand edit. That is what this pins now.
printf 'a\tb\n' | st_seed tabs "$DB_37"
: | st_seed tasks "$DB_37"
eq "37 exists: a live library is not a non-empty store" \
   "$([ -s "$DB_37" ] && echo "library-has-bytes" || echo "library-empty")/$(ex37 tasks)" "library-has-bytes/1"
eq "37 exists: ...while the store that DOES have a row still answers 0" "$(ex37 tabs)" "0"
: | st_seed tabs "$DB_37"
eq "37 exists: unknown store is rc 2"         "$(ex37 nosuchstore)" "2"
eq "37 exists: rc 2 prints usage on stderr"   "$(grep -c '^usage: cc-state exists ' "$S37/e")" "1"
eq "37 exists: rc 2 prints nothing on stdout" "$(cat "$S37/o")" ""
eq "37 exists: no argument is rc 2"           "$(ex37 "")" "2"
eq "37 exists: two arguments is rc 2"         "$(st37 exists tasks tabs >/dev/null 2>&1; echo $?)" "2"
for s37 in tasks status archive tabs; do : | st_seed "$s37" "$DB_37"; done
n37=0; for s37 in tasks status archive tabs; do st37 exists "$s37" || n37=$((n37+1)); done
eq "37 exists: all four stores answer, empty" "$n37" "4"
# 状态行只能挂在一条已存在的任务行上（D 期：sidecar 是 tasks 的两列），所以 filled 夹具里
# tasks 那行要带一个真的 dir(第 4 字段)，status 那行按它来键。
for s37 in archive tabs; do printf 'r\n' | st_seed "$s37" "$DB_37"; done
printf 'r\t\t\t/d/s37\n'      | st_seed tasks  "$DB_37"
printf '/d/s37\tworking\t1\n' | st_seed status "$DB_37"
n37=0; for s37 in tasks status archive tabs; do st37 exists "$s37" && n37=$((n37+1)); done
eq "37 exists: all four stores answer, filled" "$n37" "4"
eq "37 exists is a registered verb"           "$("$CC/cc-state" --help 2>&1 | grep -c '^verbs:.* exists ')" "1"
for s37 in tasks status archive tabs; do : | st_seed "$s37" "$DB_37"; done

# ── fixtures: a repo with one registered worktree, plus a dir belonging to nobody ───────────
B37="$(cn37 "$(mktemp -d)")"
( cd "$B37"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  mkdir -p .claude; git worktree add -q .claude/worktrees/w37 -b feat/37W >/dev/null )
W37="$B37/.claude/worktrees/w37"; OTH37="$(cn37 "$(mktemp -d)")"
row37(){ printf '2026-01-01 00:00:0%s\t%s\tsurface:%s\t%s\tsurface:9\t%s\tmain\tuuid=z\n' \
           "$1" "$2" "$3" "$4" "$5"; }

# ── cc-board.sh: the two messages the precheck exists to tell apart ─────────────────────────
brd37(){ ( cd "$B37" && env PATH=/usr/bin:/bin CC_STATE_DB="$DB_37" \
    CC_SEND_FAILLOG=/dev/null \
    bash "$CC/cc-board.sh" ${1:-} ) 2>/dev/null; }
: | st_seed tasks "$DB_37"; : | st_seed archive "$DB_37"
eq "37 board: no task store names the store"  "$(brd37)" "no registered worktree tasks"
# a store that IS there but holds only another repo's row: the repo filter empties the render,
# and the message must flip. (This is the half an "empty store" fixture can never reach.)
row37 1 feat/37F 61 "$OTH37" '37 foreign row' | st_seed tasks "$DB_37"
eq "37 board: store present, nothing matched" "$(brd37)" "no records"
eq "37 board: the foreign row survived the read" \
   "$(st_dump tasks "$DB_37" | grep -c '37 foreign row')" "1"
: | st_seed archive "$DB_37"
eq "37 board: no archive names the archive"   "$(brd37 --archive)" "no archived tasks"
row37 2 feat/37FA 62 "$OTH37" '37 foreign archive' | st_seed archive "$DB_37"
eq "37 board: archive present, nothing matched" "$(brd37 --archive)" "no records"

# ── the cost rule: `exists` may only be asked on a path that is ALREADY empty ───────────────
# The live board is the most-run command in the stack; it forks python three times today
# (task-prune, task-list, dump tasks) and this round may not add a fourth. A PATH-fronted
# python3 shim logs each start with its argv, so both halves are countable: how many, and
# which verb. (§33's F8 trick; here the argv matters, not just the count.)
PY37="$S37/shim"; mkdir -p "$PY37"; RP37="$(command -v python3)"
cat > "$PY37/python3" <<PY37SHIM
#!/usr/bin/env bash
echo "\$*" >> "\${CC_PY_LOG:-/dev/null}"
exec "$RP37" "\$@"
PY37SHIM
chmod +x "$PY37/python3"
cat > "$PY37/cmux" <<'CMUX37'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  identify) echo '{ "caller": {} }' ;;
  restore-session) echo "(fake) nothing to restore" ;;
  list-workspaces) printf '* workspace:1  fake  [selected]\n' ;;
  list-pane-surfaces) cat "${CC_37_LIVE:-/dev/null}" 2>/dev/null ;;
esac
exit 0
CMUX37
chmod +x "$PY37/cmux"
export CC_37_LIVE="$S37/live"
printf 'surface:13  AAAAAAAA-1111-1111-1111-111111111111\n' > "$CC_37_LIVE"
brdpy37(){ : > "$S37/pylog"
  ( cd "$B37" && env PATH="$PY37:/usr/bin:/bin" CC_PY_LOG="$S37/pylog" CC_STATE_DB="$DB_37" \
      CC_STATE_DB="$DB_37" CC_SEND_FAILLOG=/dev/null \
      bash "$CC/cc-board.sh" ) >/dev/null 2>&1; }
row37 3 feat/37W 13 "$W37" '37 live row' | st_seed tasks "$DB_37"
brdpy37
eq "37 cost: a rendering board still forks python 3x" "$(wc -l < "$S37/pylog" | tr -d ' ')" "3"
eq "37 cost: a rendering board never asks exists"     "$(grep -cw exists "$S37/pylog")" "0"
# and on the cold path it is asked exactly once — not once per store, not in a loop
: | st_seed tasks "$DB_37"; brdpy37
eq "37 cost: the empty board asks exists once"        "$(grep -cw exists "$S37/pylog")" "1"

# ── cc-dispatch.sh tabs: ledger absent vs ledger present but none of mine ───────────────────
SELF37="CCCCCCCC-3333-3333-3333-333333333333"
tabs37(){ ( cd "$S37" && env PATH=/usr/bin:/bin CC_STATE_DB="$DB_37" \
    CC_CALLER_SURFACE_UUID="$SELF37" bash "$CC/cc-dispatch.sh" tabs ) 2>&1; }
: | st_seed tabs "$DB_37"
O37="$(tabs37)"
eq "37 tabs: no ledger says (no tabs recorded)" "$(printf '%s\n' "$O37" | tail -1)" "  (no tabs recorded)"
# ...and says NOTHING else: no cmux warning, no column header. That is the whole point of the
# precheck sitting where it sits, and it is what a post-hoc check would quietly change.
eq "37 tabs: no ledger prints two lines only"   "$(printf '%s\n' "$O37" | wc -l | tr -d ' ')" "2"
printf 'AAAAAAAA-1111-1111-1111-111111111111\tBBBBBBBB-2222-2222-2222-222222222222\t%s\tsess\t2026-01-01 00:00:00\n' \
  "$S37" | st_seed tabs "$DB_37"
O37B="$(tabs37)"
eq "37 tabs: ledger present, none of mine"      "$(printf '%s\n' "$O37B" | tail -1)" \
  "  (no tabs opened by this session — cc-dispatch.sh tabs --all shows every row)"
eq "37 tabs: ledger present still warns + heads" \
  "$(printf '%s\n' "$O37B" | grep -cE 'cmux unreachable|^REF +UUID')" "2"
# the ledger row is another session's, so an unpruned read must leave it alone (cmux was
# unreachable → no evidence → no prune); read RAW, a filtered view hides it either way
eq "37 tabs: an unreachable probe pruned nothing" \
  "$(st_dump tabs "$DB_37" | grep -c .)" "1"

# ── cc-dispatch.sh resume: same split, over the task store ─────────────────────────────────
res37(){ ( cd "$B37" && env PATH="$PY37:/usr/bin:/bin" CC_STATE_DB="$DB_37" \
    CC_STATE_DB="$DB_37" CC_CMUX_SESSIONS="$S37/nosuch.json" CC_RESUME_SETTLE=0 \
    bash "$CC/cc-dispatch.sh" resume ) 2>&1; }
: | st_seed tasks "$DB_37"
eq "37 resume: no task store names the store" "$(res37 | tail -1)" \
  "no registered worktree tasks (nothing to resume)"
row37 4 feat/37F 64 "$OTH37" '37 foreign row' | st_seed tasks "$DB_37"
eq "37 resume: store present, nothing matched" "$(res37 | tail -1)" \
  "no resumable board rows (current repo; try --all)"

# ── worktree.zsh gwt-prune: three messages, one facade ──────────────────────────────────────
# PATH carries the fake cmux: gwt-tree's TAB cell is a liveness verdict, so on the real cmux
# the tree assertions below would render whatever surfaces this machine happens to have open.
zw37(){ ( cd "${2:-$S37}" && env PATH="$PY37:/usr/bin:/bin" CC_STATE_DB="$DB_37" \
    CC_STATE_DB="$DB_37" zsh -c "source '$CC/worktree.zsh' >/dev/null 2>&1; $1" ) 2>&1; }
: | st_seed tasks "$DB_37"
eq "37 gwt-prune: no store says list is empty" "$(zw37 gwt-prune)" "list is empty"
row37 5 feat/37W 13 "$W37" '37 live row' | st_seed tasks "$DB_37"
eq "37 gwt-prune: live rows compact"           "$(zw37 gwt-prune)" "✔ task list compacted"
row37 6 feat/37G 65 "$S37/never-existed" '37 dead row' | st_seed tasks "$DB_37"
eq "37 gwt-prune: all-dead empties"            "$(zw37 gwt-prune)" "✔ emptied (no live records)"
eq "37 gwt-prune: the emptied store is gone"   "$([ -f "$T37" ] && echo kept || echo gone)" "gone"

# ── worktree.zsh gwt-tree: the ref map (the 47th field-level parse, and the trap in it) ─────
# This one is NOT `task-list --all`. task-list answers a different question than the file:
# it skips rows whose dir is gone, dedups newest-per-dir, and emits NEWEST FIRST. Feeding it
# to a `_gt_ref[branch]=ref` loop inverts the winner (the loop's last write wins, so reversed
# input hands the OLDEST ref to a branch recorded twice) and drops the ref of any branch whose
# worktree dir has been removed by hand — a ⌫closed tab silently rendering as "-".
# `dump <store>` is the raw row stream, which is the question this scan actually asks, and it
# is the same shape cc-board.sh's stale-ref probe already uses.
R37="$(cn37 "$(mktemp -d)")"
( cd "$R37"; git init -q; git config user.email t@t; git config user.name t
  git commit -q --allow-empty -m i; git branch -M main
  git branch feat/37X; git branch feat/37D )
"$CC/cc-merge.sh" set-parent "$R37" feat/37X main >/dev/null
"$CC/cc-merge.sh" set-parent "$R37" feat/37D main >/dev/null
D37GONE="$S37/removed-by-hand"                       # recorded once, never created
# feat/37X twice: the older row points at a dead ref, the newer at the LIVE surface:13.
row37 7 feat/37X 90 "$B37" '37 older X'  >  "$T37"
row37 8 feat/37X 13 "$W37" '37 newer X'  | st_append tasks "$DB_37"
row37 9 feat/37D 91 "$D37GONE" '37 gone dir' | st_append tasks "$DB_37"
TREE37="$(zw37 gwt-tree "$R37")"
eq "37 gwt-tree: the NEWEST row wins the ref"  "$(printf '%s\n' "$TREE37" | grep 'feat/37X' | grep -c '✔live')" "1"
eq "37 gwt-tree: a gone dir keeps its ref"     "$(printf '%s\n' "$TREE37" | grep 'feat/37D' | grep -c '⌫closed')" "1"
eq "37 gwt-tree: no store means no refs at all" \
   "$(: | st_seed tasks "$DB_37"; printf '%s\n' "$(zw37 gwt-tree "$R37")" | grep 'feat/37[XD]' | grep -c '\[-\]')" "2"

# ── structure: who is still allowed to name a state FILE ───────────────────────────────────
# ONE survivor now, and it is deliberate: cc-hooks.sh's hot-path precheck, where a facade call
# would put a 15 ms python start on every prompt of every session. It grew a second leg with
# the engine (library OR legacy TSV) and both are pinned below, because dropping either one
# is silent — library-only never migrates a machine that still has TSVs, TSV-only goes dark
# the moment migration renames them away.
# cc-dispatch.sh's `tabs` header used to be the second survivor: it PRINTED the ledger path,
# because the human troubleshoots that ledger by hand. The path stopped being where the data
# is, so the header now names the COMMAND that shows it — the intent survived, the literal
# did not, and this assertion moved with it rather than being dropped.
eq "37 cc-board.sh names no store file"   "$(grep -cE '\$\{CC_(TASKS|STATUS|ARCHIVE|TABS)_FILE:-' "$CC/cc-board.sh")" "0"
eq "37 worktree.zsh names no store file"  "$(grep -cE '\$\{CC_(TASKS|STATUS|ARCHIVE|TABS)_FILE:-' "$CC/worktree.zsh")" "0"
eq "37 cc-dispatch.sh now names none"     "$(grep -cE '\$\{CC_(TASKS|STATUS|ARCHIVE|TABS)_FILE:-' "$CC/cc-dispatch.sh")" "0"
eq "37 ...and its tabs header names the verb instead" \
   "$(grep -cF 'opened tabs (cc-state dump tabs)' "$CC/cc-dispatch.sh")" "1"
# cc-hooks.sh is the ONE caller outside cc-state that still knows where state lives, and since
# phase D it needs ONE variable to know it: the legacy TSV is DERIVED from the library's dir,
# so this is a duplicated derivation rule, not a second knob that could drift on its own.
eq "37 cc-hooks.sh names no retired override" \
   "$(grep -cE '\$\{CC_(TASKS|STATUS|ARCHIVE|TABS)_FILE:-' "$CC/cc-hooks.sh")" "0"
eq "37 ...and its fast path knows the library" \
   "$(grep -cE '\$\{CC_STATE_DB:-' "$CC/cc-hooks.sh")" "1"
eq "37 ...and takes BOTH legs before giving up" \
   "$(grep -cF '[ -f "$db" ] || [ -f "$dbdir/worktree-tasks.tsv" ] || exit 0' "$CC/cc-hooks.sh")" "1"
eq "37 no caller tests a store with [ -f ]" \
   "$(grep -cE '\[ *-f *"\$(tasks|arch|status|tabs_f|_tl_f)"' "$CC/cc-board.sh" "$CC/cc-dispatch.sh" | awk -F: '{s+=$2} END{print s+0}')" "0"
unset CC_37_LIVE
rm -rf "$S37" "$B37" "$OTH37" "$R37"; cc_sandbox_ledgers
echo ""
echo "== 38. cc-state load: the byte-level write half of the dump/load pair =="
# `load <store> <file|->` REPLACES a store with the raw lines of its source. Two reasons it
# exists, and the assertions below split along them:
#   · the human's move. Until the stores were files, fixing one corrupted row was
#     `$EDITOR worktree-tasks.tsv`. `dump` gives back the reading half; without a writing half
#     the engine swap would take a capability away, so README's troubleshooting section now
#     documents `dump > f && $EDITOR f && load f`.
#   · this suite's fixtures. A 7-field legacy row, an empty middle field, a lone non-UTF-8 byte
#     are expressible as BYTES and in no other way — which is why they used to be printf'd
#     straight at the file, and why st_seed/st_append go through this verb instead.
# It deliberately bypasses every verb's semantics: no canonicalization, no sanitization, no
# membership rule, no truncation. That is the same footgun a text editor pointed at the TSV
# always was, so it is documented, not gated — and pinned here, so a later "helpful"
# normalization inside load shows up as a red assertion instead of as silently rewritten state.
S38=$(mktemp -d)
st38(){ env \
            "$CC/cc-state" "$@"; }
# The fixture carries all three byte-level oddities at once: a real 0xff (NOT an ASCII stand-in
# — a TEXT-typed column cannot hold one, so this row is what makes the round-trip a real test),
# a 7-field legacy row, and an empty middle field.
F38="$S38/fixture"
{ printf '2026-01-01 00:00:01\tfeat/38a\ts:1\t/d/38a\tc:1\teight field row\tcamp\tuuid=u1\n'
  printf '2026-01-01 00:00:02\tfeat/38b\ts:2\t/d/38b\tsurface:1\tseven field row\tmain\n'
  printf '2026-01-01 00:00:03\tfeat/38c\ts:3\t/d/38c\t\tbad\xffbyte and an empty caller\tcamp\t\n'
} > "$F38"
st38 load tasks "$F38"; rc38=$?
eq "38 load rc 0"                     "$rc38" "0"
eq "38 load writes nothing to stdout" "$(st38 load tasks "$F38")" ""
# Not vacuous: the store really holds the three rows. Without this line every byte assertion
# below would also pass on an EMPTY store loaded from an empty source (empty == empty).
eq "38 the store holds the loaded rows" "$(st38 dump tasks | wc -l | tr -d ' ')" "3"
eq "38 loaded bytes are the source bytes" \
  "$(st38 dump tasks | od -An -c | tr -d ' \n')" "$(od -An -c "$F38" | tr -d ' \n')"
# the whole point of the fixture: a real non-UTF-8 byte survived, and the 7-field row is
# still 7 fields (no column-count normalization on the way in)
eq "38 a real non-UTF-8 byte survives the round trip" \
  "$(st38 dump tasks | od -An -tx1 -v | tr ' ' '\n' | grep -cx ff)" "1"
eq "38 the 7-field row is still 7 fields" \
  "$(st38 dump tasks | awk -F'\t' '$2=="feat/38b"{print NF}')" "7"
eq "38 the empty middle field is still empty" \
  "$(st38 dump tasks | awk -F'\t' '$2=="feat/38c"{print "["$5"]"}')" "[]"
# dump | load | dump is byte-identical — the contract README's hand-edit path rests on
st38 dump tasks > "$S38/rt1"
st38 load tasks "$S38/rt1"
st38 dump tasks > "$S38/rt2"
eq "38 dump|load|dump is byte-identical" \
  "$(od -An -c "$S38/rt1" | tr -d ' \n')" "$(od -An -c "$S38/rt2" | tr -d ' \n')"
eq "38 ...and did not empty the store on the way" "$(wc -l < "$S38/rt2" | tr -d ' ')" "3"
# REPLACE, not append: the verb's most dangerous property, so it is pinned rather than assumed
printf '2026-01-01 00:00:04\tfeat/38z\ts:9\t/d/38z\tc\tthe only row now\tcamp\tu\n' > "$S38/one"
st38 load tasks "$S38/one"
eq "38 load replaces, never appends"  "$(st38 dump tasks | wc -l | tr -d ' ')" "1"
eq "38 ...with the new rows"          "$(st38 dump tasks | cut -f6)" "the only row now"
# `-` reads stdin (the only verb that does; every other one is safe to call with a closed stdin)
printf 'A\tB\nC\tD\n' | st38 load tabs -
eq "38 load - reads stdin"            "$(st38 dump tabs | wc -l | tr -d ' ')" "2"
eq "38 stdin bytes land verbatim"     "$(st38 dump tabs | tr '\t' '|' | tr '\n' ',')" "A|B,C|D,"
# an empty source empties the store (the `[ -s ] || rm -f` behaviour every rewriter here has)
: > "$S38/empty"
st38 load tabs "$S38/empty"; rc38e=$?
eq "38 empty source rc 0"             "$rc38e" "0"
eq "38 empty source empties the store" "$(st38 dump tabs | wc -c | tr -d ' ')" "0"
st38 exists tabs; eq "38 ...and the store then has no rows" "$?" "1"
# the ONE normalization, shared with the migration importer: a source whose last line has no
# newline still round-trips as that many rows, and the newline is supplied on write. This is a
# deliberate deviation from `cat`, and the reason a hand-edited file cannot lose its last row.
printf 'x\ty\nz\tw' > "$S38/nonl"
st38 load tabs "$S38/nonl"
eq "38 a source without a trailing newline keeps both rows" "$(st38 dump tabs | wc -l | tr -d ' ')" "2"
eq "38 ...and the store gains the newline" \
  "$(st38 dump tabs | tail -c 1 | od -An -tx1 -v | tr -d ' \n')" "0a"
# rc contract: 1 = the source could not be read, 2 = usage. Neither may be mistaken for success,
# and neither may quietly wipe the store it was pointed at.
N38="$(st38 dump tasks | wc -l | tr -d ' ')"
st38 load tasks "$S38/nosuchfile" >"$S38/o" 2>"$S38/e"; eq "38 unreadable source is rc 1" "$?" "1"
eq "38 unreadable source says so on stderr" "$(grep -c '^cc-state: load tasks: ' "$S38/e")" "1"
eq "38 unreadable source prints nothing on stdout" "$(cat "$S38/o")" ""
eq "38 unreadable source leaves the store alone"   "$(st38 dump tasks | wc -l | tr -d ' ')" "$N38"
st38 load nosuchstore "$F38" >"$S38/o" 2>"$S38/e"; eq "38 unknown store is rc 2" "$?" "2"
eq "38 unknown store prints usage"    "$(grep -c '^usage: cc-state load ' "$S38/e")" "1"
st38 load tasks >/dev/null 2>&1;      eq "38 missing file argument is rc 2" "$?" "2"
st38 load tasks "$F38" extra >/dev/null 2>&1; eq "38 extra argument is rc 2" "$?" "2"
# no verb semantics on the way in — the contrast that makes the footgun explicit. task-add
# canonicalizes its dir and cuts the summary at 140 characters; load does neither.
LONG38="$(python3 -c 'print("q"*300)')"
V38="$(mktemp -d)"; V38C="$(cd "$V38" && pwd -P)"
[ "$V38" != "$V38C" ] || { echo "  ✗ 38 fixture needs a logical path (mktemp under /var)"; fail=$((fail+1)); }
printf '2026-01-01 00:00:05\tfeat/38r\ts:1\t%s\tc\t%s\tcamp\ta|b\n' "$V38" "$LONG38" > "$S38/raw"
st38 load tasks "$S38/raw"
eq "38 load does not truncate the task field" "$(st38 dump tasks | awk -F'\t' '{print length($6)}')" "300"
eq "38 load does not canonicalize the dir"    "$(st38 dump tasks | awk -F'\t' -v d="$V38" '$4==d{print "raw"}')" "raw"
eq "38 load does not translate pipes"         "$(st38 dump tasks | cut -f8)" "a|b"
# the replace semantics is visible from the CLI, not only from the README
eq "38 --help names the replace semantics" \
  "$("$CC/cc-state" --help 2>&1 | grep -c 'REPLACES that whole store')" "1"
# ...and README carries the whole move, not just the verb name: the hand-edit path is the
# capability `load` exists to preserve, so losing the doc line is losing the feature
eq "38 README documents the dump|load hand-edit path" \
  "$(grep -c 'cc-state load <store> /tmp/x' "$CC/README.md")" "1"
rm -rf "$S38" "$V38"

echo ""
echo "== 39. the engine: one sqlite library, no locks =="
# ── the locks are GONE (plan Task 2, pinned assertion 7) ─────────────────────────────────────
# The plan flags this block as the likeliest fraud in the whole task: §32's four lock
# assertions are DELETED by the engine swap, not re-expressed, and swapping four real
# assertions for one structural grep that was green all along is a NET LOSS. So every line
# below was run against the PRE-SWAP code first and confirmed RED; the evidence is in the
# C2b report, not a claim that someone checked.
S39=$(mktemp -d)
st39(){ env CC_STATE_DB="$S39/cc-state.db" "$CC/cc-state" "$@"; }
# Structural, but split into five: a HALF-removed lock (say the contextmanager gone but the
# stale knob still read, or one `with lock(...)` left behind) must not be able to hide inside
# a single coarse grep.
eq "39 no mkdir lock left in the facade" "$(grep -c 'os\.mkdir' "$CC/cc-state")" "0"
eq "39 no .lock path left in the facade" "$(grep -c '\.lock' "$CC/cc-state")" "0"
eq "39 no stale-lock knob left"          "$(grep -c 'CC_STATE_LOCK_STALE' "$CC/cc-state")" "0"
eq "39 no lock() contextmanager left"    "$(grep -c '^def lock(' "$CC/cc-state")" "0"
eq "39 nothing takes a lock any more"    "$(grep -c 'with lock(' "$CC/cc-state")" "0"
# Behavioural, and this is the half that actually matters: TODAY a writer that meets a FRESH
# lock dir burns its whole 3s deadline and only then writes (unlocked). With the lock gone
# there is nothing to wait for — a stray directory named after a store is just a directory.
mkdir -p "$S39/t.tsv.lock" "$S39/cc-state.db.lock"
t39a=$(date +%s); st39 task-add /d/39lock feat/39 s:1 'lock is gone' camp >/dev/null 2>&1; t39b=$(date +%s)
eq "39 a stray .lock dir does not delay a write" "$(( t39b - t39a < 3 ? 1 : 0 ))" "1"
eq "39 ...and the write landed anyway"           "$(st39 dump tasks | grep -c 'lock is gone')" "1"

# ── WAL, and the sidecars it leaves ──────────────────────────────────────────────────────────
eq "39 the library is in WAL mode" \
  "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("PRAGMA journal_mode").fetchone()[0])' "$S39/cc-state.db")" "wal"
eq "39 schema version is stamped" \
  "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("PRAGMA user_version").fetchone()[0])' "$S39/cc-state.db")" "3"
# D2a: the row lives in NAMED columns, not f1..fN. Positional columns are the same shape as
# the awk field indexing whose shift bugs started this campaign — a structural assertion is
# what stops them coming back one convenient `fN` at a time.
eq "39 the row columns are named" \
  "$(python3 -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
print(",".join(r[1] for r in c.execute("PRAGMA table_info(tasks)")))' "$S39/cc-state.db")" \
  "seq,nf,created_at,branch,surface_ref,dir,caller_ref,task,parent,launch_args,fx,state,state_ts,tab_opened_ts"
# D2c: no verb may index a store row by a bare number again. Positional indexing IS the
# shape of the awk field-shift bugs this campaign started from — the position and the column
# name now come from one definition (NAMES → _Ix), and a hand-written f[3] is how they would
# drift apart again. The one place that legitimately parses by position (cmux's live map, not
# a store) uses a differently-named variable so this pin needs no exception list.
eq "39 no verb indexes a store row by a bare position" \
  "$(grep -c '\bf\[[0-9]\+\]' "$CC/cc-state")" "0"
eq "39 ...and the archive carries merged_into as a column, not overflow" \
  "$(python3 -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
print(",".join(r[1] for r in c.execute("PRAGMA table_info(archive)")))' "$S39/cc-state.db")" \
  "seq,nf,created_at,branch,surface_ref,dir,caller_ref,task,parent,launch_args,merged_at,merged_into,fx"
# A DOWNGRADE must cost visibility, never data. Code from before the model convergence opens a v2
# library happily — it reads f1..f8 and ignores the carried columns — but it also re-creates an
# empty `status` table and stamps the version back to 1. Coming back UP must not then fold that
# empty sidecar over the columns that still hold the real state. Simulated here rather than run
# against an old binary: the two things old code leaves behind are exactly these two statements.
DG39="$S39/dg"; mkdir -p "$DG39/w"
dg39(){ env CC_STATE_DB="$DG39/cc-state.db" "$CC/cc-state" "$@"; }
dg39 task-add "$DG39/w" feat/dg s:1 'downgrade probe' main >/dev/null
dg39 task-set-state "$DG39/w" working
eq "39 state is carried before the downgrade" "$(dg39 dump status | wc -l | tr -d ' ')" "1"
python3 - "$DG39/cc-state.db" <<'PYDG'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS status (seq INTEGER PRIMARY KEY, nf INTEGER NOT NULL, "
          "f1 BLOB, f2 BLOB, f3 BLOB, fx BLOB)")
c.execute("PRAGMA user_version=1")
c.commit()
PYDG
# The $TMPDIR dedup marker is gone from the CODE, comments included: a grep for its directory
# name is the only thing between "retired" and "quietly reintroduced". Confirmed RED before the
# change (cc-state carried one hit) — the plan flags this exact assertion as the kind that is
# born green and stays green for the wrong reason, so it was checked the other way first.
eq "39 the dedup marker path is gone" "$(cat "$CC/cc-state" "$CC/cc-dispatch.sh" | grep -c 'cc-cmux-tabs')" "0"
eq "39 a downgrade round trip keeps the state" "$(dg39 dump status | wc -l | tr -d ' ')" "1"
eq "39 ...and it is the same state"            "$(dg39 dump status | cut -f2)" "working"
eq "39 ...and the sidecar table is gone again" \
  "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT count(*) FROM sqlite_master WHERE type=\"table\" AND name=\"status\"").fetchone()[0])' "$DG39/cc-state.db")" "0"
# CHANGED 2026-08-29. This used to assert the -wal/-shm sidecars are GONE after a clean exit.
# That belief is FALSE on the floor python: macOS's system sqlite (3.51, the build
# /usr/bin/python3 links — and therefore the one the HOOK runs on every prompt of every
# session) keeps them across close(); a newer sqlite (3.53) removes them. Measured directly,
# connect → write → close, not inferred. The suite could not see it because a developer shell
# has a much newer python3 first on PATH — which is what the floor probe below now covers.
# The honest invariant, and the one this replaced the mkdir-lock assertions with: a clean exit
# leaves nothing a next process has to clean up — no litter other than the library's own two
# sidecars, and every row already visible.
WL39=$(mktemp -d)
env CC_STATE_DB="$WL39/cc-state.db" "$CC/cc-state" task-add /d/wl feat/wl s:1 'wal probe' p
eq "39 a clean exit leaves no litter beside the library" \
  "$(ls -A "$WL39" | grep -vE '^cc-state\.db(-wal|-shm)?$' | wc -l | tr -d ' ')" "0"
eq "39 ...and the next process sees the row" \
  "$(env CC_STATE_DB="$WL39/cc-state.db" "$CC/cc-state" dump tasks | wc -l | tr -d ' ')" "1"
rm -rf "$WL39"
# ── the FLOOR python, by name ────────────────────────────────────────────────────────────────
# Everything else in this suite runs on whatever python3 is first on PATH, which in a developer
# shell is not the one that matters: cc-hooks.sh resolves to /usr/bin/python3 under a stripped
# PATH. 1354 assertions were green on 3.14 while the floor behaved differently, so the floor
# gets asked for BY NAME — migration, read and write, on the schema it actually lands on.
if [ -x /usr/bin/python3 ]; then
  FL39=$(mktemp -d)
  printf '2026-01-01 00:00:01\tfeat/fl\ts:1\t/d/fl\tc\tfloor row\tmain\n' > "$FL39/worktree-tasks.tsv"
  fl39(){ env CC_STATE_DB="$FL39/cc-state.db" /usr/bin/python3 "$CC/cc-state" "$@"; }
  eq "39 the floor python migrates a legacy TSV" "$(fl39 dump tasks | cut -f2)" "feat/fl"
  fl39 task-add /d/fl2 feat/fl2 s:2 'floor add' main
  fl39 task-set-state /d/fl2 working
  eq "39 ...writes"                    "$(fl39 dump tasks | wc -l | tr -d ' ')" "2"
  eq "39 ...and its state columns"     "$(fl39 dump status | cut -f2)" "working"
  eq "39 ...onto the current schema"   \
    "$(/usr/bin/python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("PRAGMA user_version").fetchone()[0])' "$FL39/cc-state.db")" "3"
  rm -rf "$FL39"
fi

# ── row ORDER is insertion order (seq), not whatever sqlite feels like ───────────────────────
# task-prune --compact's newest-per-dir reads file order; without an explicit ordering column
# this is the assertion that would have caught it, silently, on a table that happened to
# come back sorted differently after a rewrite.
# D 期起 status 是 tasks 两列的投影,它的序来自 tasks.seq —— 要测「存储层保住插入序」就得测
# 一个仍逐行存储的表,而这条注释说的 task-prune --compact 读的本来就是 tasks 的序。
{ printf 'r1\tone\nr2\ttwo\nr3\tthree\n'; } | st_seed tasks "$S39/cc-state.db"
env CC_STATE_DB="$S39/cc-state.db" "$CC/cc-state" task-set-ref /d/nothing s:1 >/dev/null 2>&1   # a no-op rewrite
eq "39 rows come back in insertion order" "$(st39 dump tasks | cut -f1 | tr '\n' ',')" "r1,r2,r3,"

# ── the byte classes the column store has to survive ─────────────────────────────────────────
# A real 0xff (BLOB columns + surrogateescape — a TEXT column cannot hold the lone surrogate
# that produces and raises on the INSERT), a 7-field legacy row beside an 8-field one, an empty
# middle field, and a row WIDER than the table's columns (only a hand edit or `load` makes one,
# and dropping its tail would be the one kind of data loss the human cannot undo).
F39="$S39/bytes"
{ printf '2026-01-01 00:00:01\tfeat/a\ts:1\t/d/a\tc\teight field row\tcamp\tuuid=u\n'
  printf '2026-01-01 00:00:02\tfeat/b\ts:2\t/d/b\tsurface:1\tseven field row\tmain\n'
  printf '2026-01-01 00:00:03\tfeat/c\ts:3\t/d/c\t\tbad\xffbyte\tcamp\t\n'
  printf 'w1\tw2\tw3\tw4\tw5\tw6\tw7\tw8\tw9\tw10\tw11\n'; } > "$F39"
st39 load tasks "$F39"
eq "39 the column store rebuilds every byte" \
  "$(st39 dump tasks | od -An -c | tr -d ' \n')" "$(od -An -c "$F39" | tr -d ' \n')"
eq "39 a real non-UTF-8 byte survived the column store" \
  "$(st39 dump tasks | od -An -tx1 -v | tr ' ' '\n' | grep -cx ff)" "1"
eq "39 the 7-field row did not gain a field" "$(st39 dump tasks | awk -F'\t' 'NR==2{print NF}')" "7"
eq "39 an over-wide row keeps its overflow"  "$(st39 dump tasks | awk -F'\t' 'NR==4{print NF"/"$11}')" "11/w11"

# ── migration ────────────────────────────────────────────────────────────────────────────────
# Its own tests, not a side effect of fixtures: the importer is the one piece of this task that
# touches data the human cannot get back if it is wrong.
M39=$(mktemp -d)
m39(){ env CC_STATE_DB="$M39/cc-state.db" "$CC/cc-state" "$@"; }
printf '2026-01-01 00:00:01\tfeat/m\ts:1\t/d/m\tc\tlegacy 7 field\tmain\n' > "$M39/worktree-tasks.tsv"
printf '2026-01-01 00:00:02\tfeat/n\ts:2\t/d/n\tc\tno final newline\tmain\tu' >> "$M39/worktree-tasks.tsv"
printf '/d/m\tworking\t100\n' > "$M39/worktree-status.tsv"
cp "$M39/worktree-tasks.tsv" "$M39/before"
m39 dump tasks >/dev/null                       # first open imports
eq "39 migration imported every row"        "$(m39 dump tasks | wc -l | tr -d ' ')" "2"
eq "39 migration kept the 7-field row at 7" "$(m39 dump tasks | awk -F'\t' 'NR==1{print NF}')" "7"
eq "39 migration also took the sidecar"     "$(m39 dump status | cut -f2)" "working"
eq "39 the legacy file was RENAMED, not deleted" \
  "$(ls "$M39"/worktree-tasks.tsv.migrated.* 2>/dev/null | wc -l | tr -d ' ')" "1"
eq "39 ...and the renamed copy is byte-identical to what was there" \
  "$(cmp -s "$M39"/worktree-tasks.tsv.migrated.* "$M39/before" && echo same || echo differ)" "same"
eq "39 ...and the original path is gone"    "$([ -e "$M39/worktree-tasks.tsv" ] && echo there || echo renamed)" "renamed"
# idempotent: opening again imports nothing and renames nothing
N39="$(m39 dump tasks | wc -l | tr -d ' ')"; R39="$(ls "$M39"/*.migrated.* | wc -l | tr -d ' ')"
m39 dump tasks >/dev/null; m39 dump status >/dev/null
eq "39 a second open imports nothing new"   "$(m39 dump tasks | wc -l | tr -d ' ')" "$N39"
eq "39 ...and renames nothing new"          "$(ls "$M39"/*.migrated.* | wc -l | tr -d ' ')" "$R39"
# the ONE deliberate deviation, asserted rather than tolerated (state-model §3.5 #10)
eq "39 the newline-less legacy row gained a newline (deviation 10)" \
  "$(m39 dump tasks | tail -c 1 | od -An -tx1 -v | tr -d ' \n')" "0a"
# D plan Task 1 assertion 6 — v0 → v2 DIRECT. A machine that still has only the four TSVs
# must land on the current schema in one migration, not build a v1 library and then upgrade it:
# the two-step would run the fold path over data that was never a sidecar table, and a new
# machine would carry a transitional shape it never had any reason to have.
eq "39 a v0 machine migrates straight to the current schema" \
  "$(python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print("%d/%d" % (c.execute("PRAGMA user_version").fetchone()[0], c.execute("SELECT count(*) FROM sqlite_master WHERE type=\"table\" AND name=\"status\"").fetchone()[0]))' "$M39/cc-state.db")" "3/0"
# D plan Task 1 assertion 4 / §1.5 deviation A — a sidecar row belonging to NO task row cannot
# be represented once state is two columns on the task row, so the import drops it. Today's
# task-prune already sweeps such rows; this turns "will be swept" into "cannot be stored", and
# the assertion is what keeps the drop deliberate rather than a coincidence of the fold.
OR39=$(mktemp -d)
printf '2026-01-01 00:00:01\tfeat/or\ts:1\t/d/or\tc\thas a task row\tmain\n' > "$OR39/worktree-tasks.tsv"
printf '/d/or\tworking\t100\n/d/nobody\tblocked\t200\n' > "$OR39/worktree-status.tsv"
or39(){ env CC_STATE_DB="$OR39/cc-state.db" "$CC/cc-state" "$@"; }
or39 dump tasks >/dev/null                      # first open imports both TSVs
eq "39 an orphan sidecar row is dropped on import" "$(or39 dump status | wc -l | tr -d ' ')" "1"
eq "39 ...and it is the one WITH a task row that survived" "$(or39 dump status | cut -f1)" "/d/or"
rm -rf "$OR39"
# the same rule at the OTHER entry point: a v1 library (four tables) upgrading in place. The
# fold has its own matching code, so a v0-only assertion would leave it uncovered.
U39=$(mktemp -d)
python3 - "$U39/cc-state.db" <<'PYU'
import sqlite3, sys
COLS = {"tasks": 8, "status": 3, "archive": 9, "tabs": 5}
c = sqlite3.connect(sys.argv[1])
for t, n in COLS.items():                        # the v1 shape, verbatim
    c.execute("CREATE TABLE %s (seq INTEGER PRIMARY KEY, nf INTEGER NOT NULL, %s, fx BLOB)"
              % (t, ", ".join("f%d BLOB" % (i + 1) for i in range(n))))
c.execute("INSERT INTO tasks (nf,f1,f2,f3,f4,f5,f6,f7,f8,fx) VALUES (7,?,?,?,?,?,?,?,NULL,NULL)",
          (b"2026-01-01 00:00:01", b"feat/u", b"s:1", b"/d/u", b"c", b"v1 row", b"main"))
c.execute("INSERT INTO status (nf,f1,f2,f3,fx) VALUES (3,?,?,?,NULL)", (b"/d/u", b"idle", b"300"))
c.execute("INSERT INTO status (nf,f1,f2,f3,fx) VALUES (3,?,?,?,NULL)", (b"/d/ghost", b"working", b"400"))
c.execute("PRAGMA user_version=1")
c.commit()
PYU
u39(){ env CC_STATE_DB="$U39/cc-state.db" "$CC/cc-state" "$@"; }
eq "39 a v1 library upgrades in place" \
  "$(u39 dump tasks >/dev/null; python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("PRAGMA user_version").fetchone()[0])' "$U39/cc-state.db")" "3"
eq "39 ...folding the sidecar onto its task row"   "$(u39 dump status)" "$(printf '/d/u\tidle\t300')"
eq "39 ...and dropping the one with no task row"   "$(u39 dump status | grep -c ghost)" "0"
eq "39 ...while the 7-field task row stays 7"      "$(u39 dump tasks | awk -F'\t' '{print NF}')" "7"
eq "39 ...and the v1 positional columns are gone"  \
  "$(python3 -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
n=[r[1] for r in c.execute("PRAGMA table_info(tasks)")]
print("f1" in n, "dir" in n)' "$U39/cc-state.db")" "False True"
rm -rf "$U39"
# A v2 library whose ARCHIVE holds a 10-field row: merged_into was appended to the LINE and
# therefore rode in `fx` (the table was 9 columns wide). v3 widens the table, so the rebuild
# has to promote that overflow into the new column — and the promotion is not hand-written
# field shuffling, it falls out of reading at the old width and writing at the new one. If
# that ever stops being true the row comes back ELEVEN fields wide, silently.
W39=$(mktemp -d)
python3 - "$W39/cc-state.db" <<'PYW'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
for t, n in (("tasks", 8), ("archive", 9), ("tabs", 5)):
    c.execute("CREATE TABLE %s (seq INTEGER PRIMARY KEY, nf INTEGER NOT NULL, %s, fx BLOB)"
              % (t, ", ".join("f%d BLOB" % (i + 1) for i in range(n))))
for col, typ in (("state","BLOB"),("state_ts","BLOB"),("tab_opened_ts","INTEGER"),
                 ("merged_at","INTEGER"),("merged_into","BLOB")):
    c.execute("ALTER TABLE tasks ADD COLUMN %s %s" % (col, typ))
c.execute("INSERT INTO archive (nf,f1,f2,f3,f4,f5,f6,f7,f8,f9,fx) "
          "VALUES (10,?,?,?,?,?,?,?,?,?,?)",
          (b"2026-01-01 00:00:01", b"feat/w", b"s:1", b"/d/w", b"c", b"wide row",
           b"main", b"uuid=u", b"1700000000", b"feature/camp"))
c.execute("PRAGMA user_version=2")
c.commit()
PYW
w39(){ env CC_STATE_DB="$W39/cc-state.db" "$CC/cc-state" "$@"; }
eq "39 a v2 10-field archive row survives the widening" \
  "$(w39 dump archive)" "$(printf '2026-01-01 00:00:01\tfeat/w\ts:1\t/d/w\tc\twide row\tmain\tuuid=u\t1700000000\tfeature/camp')"
eq "39 ...and its overflow became the merged_into COLUMN" \
  "$(python3 -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
mi,fx = c.execute("SELECT merged_into, fx FROM archive").fetchone()
print("%s/%s" % (mi.decode(), "null" if fx is None else "left-in-fx"))' "$W39/cc-state.db")" "feature/camp/null"
rm -rf "$W39"

# A migration that fails AFTER the library file was created must take it back down. The
# fixture below (read-only DIRECTORY) cannot reach that path — sqlite never gets to create
# the file — so it proves nothing about the cleanup. Found by mutation: deleting the unlink
# reddened NOTHING. This one makes the directory writable and the legacy file unreadable,
# so the library IS created and the import then fails.
MH39=$(mktemp -d)
printf '2026-01-01 00:00:01\tfeat/h\ts:1\t/d/h\tc\tunreadable\tmain\n' > "$MH39/worktree-tasks.tsv"
chmod 000 "$MH39/worktree-tasks.tsv"
env CC_STATE_DB="$MH39/cc-state.db" "$CC/cc-state" dump tasks >/dev/null 2>&1; r39u=$?
chmod 644 "$MH39/worktree-tasks.tsv"
eq "39 a mid-flight migration failure removes the library it created" \
  "$(ls "$MH39"/cc-state.db* 2>/dev/null | wc -l | tr -d ' ')" "0"
eq "39 ...and left the unreadable legacy file alone" \
  "$([ -e "$MH39/worktree-tasks.tsv" ] && echo there || echo gone)" "there"
eq "39 ...and said so"  "$r39u" "1"
rm -rf "$MH39"

# migration failure → no library, no rename, the machine keeps running the way it did
MF39=$(mktemp -d)
printf '2026-01-01 00:00:01\tfeat/f\ts:1\t/d/f\tc\tstays put\tmain\n' > "$MF39/worktree-tasks.tsv"
cp "$MF39/worktree-tasks.tsv" "$MF39.keep"
chmod 555 "$MF39"
mf39(){ env CC_STATE_DB="$MF39/cc-state.db" "$CC/cc-state" "$@"; }
mf39 dump tasks >/dev/null 2>&1; r39f=$?
o39f="$(mf39 task-set-state /d/f working 2>&1)"; r39h=$?
chmod 755 "$MF39"
eq "39 a failed migration creates no library"  "$([ -e "$MF39/cc-state.db" ] && echo built || echo none)" "none"
eq "39 ...renames nothing"                     "$(ls "$MF39"/*.migrated.* 2>/dev/null | wc -l | tr -d ' ')" "0"
eq "39 ...and leaves the legacy file exactly as it was" \
  "$(cmp -s "$MF39/worktree-tasks.tsv" "$MF39.keep" && echo same || echo differ)" "same"
eq "39 ...loud for a reader"                   "$r39f" "1"
eq "39 ...but a silent no-op for the hook path" "$r39h/$o39f" "0/"

# THE incident guard: a caller that points CC_STATE_DB somewhere scratch must NOT import —
# and rename away — the real ledgers next door. This cost the live opened-tabs and archive
# ledgers once during this task, from a one-off command that set CC_STATE_DB and nothing else.
# Phase D turned the rule that fixed it from a CHECK into the way the paths are built (there
# is no second place to point a store at any more), which is why this assertion outlives the
# _migratable function it was written for: the property is the deliverable, not the code.
I39=$(mktemp -d); J39=$(mktemp -d)
printf '2026-01-01 00:00:01\tfeat/live\ts:1\t/d/live\tc\tsomebody else store\tmain\n' > "$I39/worktree-tasks.tsv"
CC_STATE_DB="$J39/cc-state.db" "$CC/cc-state" dump tasks >/dev/null 2>&1
eq "39 a library does not import a store from another directory" \
  "$([ -e "$I39/worktree-tasks.tsv" ] && echo untouched || echo EATEN)" "untouched"
eq "39 ...and renamed nothing there"  "$(ls "$I39"/*.migrated.* 2>/dev/null | wc -l | tr -d ' ')" "0"
eq "39 ...while the same store beside its own library DOES import" \
  "$(cp "$I39/worktree-tasks.tsv" "$J39/worktree-tasks.tsv"
     CC_STATE_DB="$J39/cc-state.db" "$CC/cc-state" dump tasks | grep -c 'somebody else store')" "1"

# The hook's fast path has TWO legs and the library-only half is the silent one: a machine
# that still has legacy TSVs and no library must STILL record state (the first call migrates).
# Mutation found this uncovered — dropping the TSV leg reddened only the structural grep.
HK39=$(mktemp -d); HW39="$(cd "$(mktemp -d)" && pwd -P)"
printf '2026-01-01 00:00:01\tfeat/hk\ts:1\t%s\tc\thook leg\tmain\n' "$HW39" > "$HK39/worktree-tasks.tsv"
printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","message":""}' "$HW39" \
  | env CC_STATE_DB="$HK39/cc-state.db" \
    bash "$CC/cc-hooks.sh" status >/dev/null 2>&1
eq "39 legacy TSVs but no library: the hook still records state" \
  "$(env CC_STATE_DB="$HK39/cc-state.db" "$CC/cc-state" dump status | cut -f2)" "working"
rm -rf "$HK39" "$HW39"

# ── the four retired ledger overrides ────────────────────────────────────────────────────────
# Phase D (spec §8 invariant 9) retired CC_TASKS_FILE / CC_STATUS_FILE / CC_ARCHIVE_FILE /
# CC_TABS_FILE. What replaced them is not a smaller knob, it is the removal of a REPRESENTABLE
# STATE: five paths that could be aimed at each other's directories became one, so "half the
# overrides set" — the shape of the incident guarded just above, and of two sandbox escapes
# before it — cannot be written down any more.
# What can still bite is a shell that has one of the four exported from before: its file goes
# quietly unread, and a silently empty board is the failure this campaign keeps hunting. So the
# retirement is said out loud, and these assertions are what keep it honest — the two negative
# ones are there because an implementation that simply always warns passes the positive ones.
O39=$(mktemp -d); P39=$(mktemp -d)
printf '2026-01-01 00:00:01\tfeat/orph\ts:1\t/d/orph\tc\tmoved away\tmain\n' > "$P39/worktree-tasks.tsv"
env CC_STATE_DB="$O39/cc-state.db" CC_TASKS_FILE="$P39/worktree-tasks.tsv" \
    "$CC/cc-state" dump tasks >/dev/null 2>"$O39/err"
eq "39 a retired override is named on stderr" \
  "$(grep -c 'CC_TASKS_FILE is retired and IGNORED' "$O39/err")" "1"
eq "39 ...and the notice names the fix"  "$(grep -cF "cc-state load tasks $P39/worktree-tasks.tsv" "$O39/err")" "1"
# IGNORED has to be literally true: the file it points at is neither read nor renamed aside
eq "39 ...and the file it points at is untouched" \
  "$([ -e "$P39/worktree-tasks.tsv" ] && echo untouched || echo EATEN)/$(ls "$P39"/*.migrated.* 2>/dev/null | wc -l | tr -d ' ')" "untouched/0"
eq "39 ...and none of its rows appear" \
  "$(env CC_STATE_DB="$O39/cc-state.db" CC_TASKS_FILE="$P39/worktree-tasks.tsv" "$CC/cc-state" dump tasks 2>/dev/null | grep -c 'moved away')" "0"
# the hook may not gain a voice from this: cc-hooks.sh redirects, and that is pinned, not assumed
printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","message":""}' "$PWD" \
  | env CC_STATE_DB="$O39/cc-state.db" CC_TASKS_FILE="$P39/worktree-tasks.tsv" \
    bash "$CC/cc-hooks.sh" status >"$O39/hout" 2>"$O39/herr"; r39o=$?
eq "39 ...while the hook path stays silent and exits 0" \
  "$r39o/$(cat "$O39/hout")$(cat "$O39/herr")" "0/"
# NEGATIVE 1: export none of them and there is nothing to say
env CC_STATE_DB="$O39/cc-state.db" "$CC/cc-state" dump tasks >/dev/null 2>"$O39/err2"
eq "39 no retired override set draws no notice" "$(wc -c < "$O39/err2" | tr -d ' ')" "0"
# NEGATIVE 2: an EMPTY value is not someone pointing anywhere — same `or` rule the paths used
env CC_STATE_DB="$O39/cc-state.db" CC_ARCHIVE_FILE= "$CC/cc-state" dump tasks >/dev/null 2>"$O39/err5"
eq "39 an empty retired override draws no notice" "$(wc -c < "$O39/err5" | tr -d ' ')" "0"
# it fires on the VALUE being set, not on the file existing — someone pointing at a path that
# never existed still believes it works, and is the person who most needs telling
env CC_STATE_DB="$O39/cc-state.db" CC_STATUS_FILE="$O39/never-existed.tsv" \
    "$CC/cc-state" dump tasks >/dev/null 2>"$O39/err3"
eq "39 the notice does not wait for the file to exist" \
  "$(grep -c 'CC_STATUS_FILE is retired' "$O39/err3")" "1"
# all four at once: one line each, each naming ITS OWN store for the load command — a single
# shared "some override is set" line would pass every assertion above
env CC_STATE_DB="$O39/cc-state.db" CC_TASKS_FILE=/x/a CC_STATUS_FILE=/x/b \
    CC_ARCHIVE_FILE=/x/c CC_TABS_FILE=/x/d "$CC/cc-state" dump tasks >/dev/null 2>"$O39/err4"
eq "39 every retired override gets its own line" "$(grep -c 'is retired and IGNORED' "$O39/err4")" "4"
eq "39 ...each naming its own store" \
  "$(grep -oE 'cc-state load [a-z]+ /x/.' "$O39/err4" | LC_ALL=C sort | tr '\n' ',')" "cc-state load archive /x/c,cc-state load status /x/b,cc-state load tabs /x/d,cc-state load tasks /x/a,"
rm -rf "$O39" "$P39"

# ── the writes are ATOMIC, not merely serialized ─────────────────────────────────────────────
# The concurrency block below tests "no write is lost" — 24 processes over 24 different dirs,
# all going through rewrite(). That is a DIFFERENT property from "one write is one transaction",
# and gate found the gap the honest way: splitting write_lines' whole-table replace into two
# transactions (DELETE; COMMIT; INSERT; COMMIT) left the suite at 1308 passed, 0 failed. The
# end state is identical on the happy path, so nothing that only inspects the end state can see
# it — and between those two commits the store is VISIBLY EMPTY to every other process. A crash
# in that window loses the whole board, which is the exact failure state-model §5 says the
# engine abolishes ("事务取代写 tmp 再 mv，半损坏那一类不存在了"). The headline deliverable
# needs an assertion or the next refactor can quietly undo it.
#
# Structural half: each write path opens exactly one transaction. The property IS structural,
# and gate's mutation is literally "add a COMMIT", so this cannot be green against it.
body39(){ awk -v f="$1" '$0 ~ "^(def )?" f "\\(" {n=1} n && /^(def |    """|# ──)/ && !/'"$1"'\(/ && ++k>1 {exit} n' "$CC/cc-state"; }
for w39 in write_lines rewrite append_line cmd_task_archive; do
  eq "39 $w39 opens exactly one transaction" \
    "$(body39 "$w39" | grep -c 'BEGIN IMMEDIATE')/$(body39 "$w39" | grep -c '"COMMIT"')" "1/1"
done
# Behavioural half, and deliberately NOT a timing race: a watcher polls count(*) in a tight
# in-process loop (microseconds per sample) while the replace runs, so the two-transaction
# window — however short — is sampled thousands of times. Correct code shows a WAL reader only
# the old snapshot or the new one; split in two it shows zero. Three rounds, because one missed
# sample should not be able to turn this green.
A39=$(mktemp -d)
AT39="$(python3 - "$A39/atomic.db" "$CC/cc-state" <<'PYATOM'
import os, sqlite3, subprocess, sys, threading, time
db, cc = sys.argv[1], sys.argv[2]
env = dict(os.environ, CC_STATE_DB=db)
def load(store, rows):
    subprocess.run([cc, "load", store, "-"], env=env, check=True,
                   input=b"".join(b"r%d\tpayload\n" % i for i in range(rows)))
OLD, NEW = 2000, 1500
load("tasks", OLD)
seen, stop = set(), []
def watch():
    c = sqlite3.connect(db)
    while not stop:
        try: seen.add(c.execute("SELECT count(*) FROM tasks").fetchone()[0])
        except sqlite3.Error: pass
t = threading.Thread(target=watch); t.start()
time.sleep(0.05)
for _ in range(3):
    load("tasks", NEW); load("tasks", OLD)
stop.append(1); t.join()
print("clean" if not [x for x in seen if x not in (OLD, NEW)] else "torn:%s" % sorted(seen)[:4])
PYATOM
)"
eq "39 a whole-table replace is never observably empty" "$AT39" "clean"
# The archive MOVE is the same property across two stores, and it is spec §3.5 defect 5 dying:
# the old code appended to the archive and rewrote the task list as two separate writes, so a
# failure between them left rows in both places (its own error message admitted it). A row must
# be in exactly one store at every instant — the total never dips and never doubles.
AR39="$(python3 - "$A39/arch.db" "$CC/cc-state" <<'PYARCH'
import os, sqlite3, subprocess, sys, threading, time
db, cc = sys.argv[1], sys.argv[2]
env = dict(os.environ, CC_STATE_DB=db)
N = 1200
subprocess.run([cc, "load", "tasks", "-"], env=env, check=True,
               input=b"".join(b"2026-01-01 00:00:0%d\tfeat/atomic\ts:1\t/d/a%d\tc\trow\tmain\tu\n"
                              % (i % 10, i) for i in range(N)))
seen, stop = set(), []
def watch():
    c = sqlite3.connect(db)
    # ONE statement = one read snapshot; two separate counts could straddle a commit
    while not stop:
        try: seen.add(c.execute("SELECT (SELECT count(*) FROM tasks)+(SELECT count(*) FROM archive)").fetchone()[0])
        except sqlite3.Error: pass
t = threading.Thread(target=watch); t.start()
time.sleep(0.05)
subprocess.run([cc, "task-archive", "feat/atomic", "trunk"], env=env, check=True,
               stdout=subprocess.DEVNULL)
stop.append(1); t.join()
print("clean" if seen == {N} else "torn:%s" % sorted(seen)[:4])
PYARCH
)"
eq "39 the archive move never shows a row in neither store (defect 5)" "$AR39" "clean"
rm -rf "$A39"

# ── concurrency, run for real ────────────────────────────────────────────────────────────────
# A-phase measured 41 dispatch records losing 18 of them under plain campaign concurrency with
# no transaction. N processes, N different dirs, all at once, nothing lost and nothing doubled.
C39=$(mktemp -d); c39(){ env CC_STATE_DB="$C39/cc-state.db" "$CC/cc-state" "$@"; }
for i39 in $(seq 1 24); do mkdir -p "$C39/w$i39"; c39 task-add "$C39/w$i39" "feat/c$i39" s:1 "row $i39" p; done
for i39 in $(seq 1 24); do ( c39 task-set-state "$C39/w$i39" working ) & done; wait
eq "39 every concurrent write landed"   "$(c39 dump status | wc -l | tr -d ' ')" "24"
eq "39 ...exactly once each"            "$(c39 dump status | cut -f1 | sort -u | wc -l | tr -d ' ')" "24"
eq "39 ...and no task row was lost"     "$(c39 dump tasks | wc -l | tr -d ' ')" "24"
rm -rf "$S39" "$M39" "$MF39" "$MF39.keep" "$I39" "$J39" "$C39"

echo "== syntax =="
for s in "$CC"/*.sh "$CC"/hooks/*.sh; do bash -n "$s" && : || { echo "  ✗ syntax $s"; fail=$((fail+1)); }; done
zsh -n "$CC/worktree.zsh" && ok "worktree.zsh syntax" || { no "worktree.zsh syntax" x x; }
python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$CC/cc-state" \
  && ok "cc-state compiles" || { no "cc-state compiles" x x; }

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
grep -q "opened-tabs.tsv" "$CC/README.md" && grep -q "gwt-tabs" "$CC/README.md" \
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
# an unsandboxed run would have MIGRATED the human's real TSVs out from under the pre-swap
# cc-state the install dir still runs — the single most destructive outcome available here
eq "no live ledger was migrated away"     "$(_cc_live_migrated)" "$CC_LIVE_MIGRATED_BEFORE"
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
