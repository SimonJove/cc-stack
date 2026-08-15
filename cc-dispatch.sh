#!/usr/bin/env bash
# cc-dispatch.sh · THE dispatch pipeline — one script, three subcommands.
#   wt-claude <name> <prompt> [--prefix <p>] [--base <b>]   gwt-claude implementation: build/reuse
#                                                             the worktree, then delegate to surface
#                                                             [absorbs cc-worktree-claude.sh]
#   surface   <path> [prompt]                                open tab + copy .env + trust + launch +
#                                                             register — the single source of truth
#                                                             [absorbs cc-cmux-surface-claude.sh]
#   workspace <path> [name] [focus]                          open a cmux workspace (empty shell) for a dir
#                                                             [absorbs cc-cmux-workspace.sh]
set -u

case "${1:-}" in

# ─────────────────────────────────────────────────────────────────────────────
# wt-claude — gwt-claude: spin a task off the main task into an independent sub-task.
#   This subcommand only handles "build/reuse the worktree + ensure .gitignore", then DELEGATES the
#   whole "open tab + copy .env + start ccteam (plan) + pre-trust + send prompt + register" part to
#   surface (single source of truth, avoids two copies of the logic drifting).
# Usage: cc-dispatch.sh wt-claude <name> <initial-prompt> [--prefix <p>] [--base <b>]
#        (legacy positional form still accepted: <name> <initial-prompt> [branch-prefix=feat] [base=HEAD])
wt-claude)
shift
name="${1:-}"; prompt="${2:-}"
[ -n "$name" ] && [ -n "$prompt" ] || {
  echo "usage: cc-dispatch.sh wt-claude <name> <initial-prompt> [--prefix <p>] [--base <b>]" >&2; exit 2; }
shift 2

# Flag form (what the worktree-subtask skill documents) or legacy positionals — both work.
prefix="feat"; base="HEAD"; posi=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base)   [ -n "${2:-}" ] || { echo "✗ --base needs a value" >&2; exit 2; }; base="$2"; shift 2 ;;
    --prefix) [ -n "${2:-}" ] || { echo "✗ --prefix needs a value" >&2; exit 2; }; prefix="$2"; shift 2 ;;
    *)
      posi=$((posi+1))
      case $posi in 1) prefix="$1" ;; 2) base="$1" ;; *) echo "✗ unexpected argument: $1" >&2; exit 2 ;; esac
      shift ;;
  esac
done

# Must be inside cmux (this whole thing is designed around cmux tabs)
command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 || {
  echo "✗ can't reach cmux, aborting (this command needs cmux)" >&2; exit 1; }

# ── Resolve main repo root + worktree dir (works from the main repo or from any worktree) ──
g="$(git rev-parse --git-common-dir 2>/dev/null)" || { echo "✗ not inside a git repo" >&2; exit 1; }
g="$(cd "$g" && pwd -P)"; root="$(dirname "$g")"
if [ -d "$root/.claude" ]; then rel=".claude/worktrees"; else rel=".worktrees"; fi
wtbase="$root/$rel"; mkdir -p "$wtbase"
gi="$root/.gitignore"
grep -qxF "/$rel/" "$gi" 2>/dev/null || { printf '/%s/\n' "$rel" >> "$gi"; echo "  ↳ .gitignore now ignores /$rel/"; }
wtpath="$wtbase/$name"; branch="$prefix/$name"

# ── Build/reuse the worktree ──
if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$root" worktree add "$wtpath" "$branch" || exit 1
else
  git -C "$root" worktree add "$wtpath" -b "$branch" "$base" || exit 1
fi
echo "✔ worktree : $wtpath"
echo "✔ branch   : $branch"
"$HOME/.config/cc-stack/cc-merge.sh" capture "$root" "$branch" "$PWD" >/dev/null 2>&1

# ── Delegate: open tab + copy .env + start ccteam (plan) + pre-trust + send prompt + register ──
exec "$HOME/.config/cc-stack/cc-dispatch.sh" surface "$wtpath" "$prompt"
;;

# ─────────────────────────────────────────────────────────────────────────────
# surface — open a new surface (tab) in the CURRENT cmux workspace for an existing directory and
#   start a ccteam claude, optionally with an initial prompt. Opens in background, doesn't steal
#   focus. Not in cmux (remote/not installed) = safe no-op.
# Called automatically by cc-hooks.sh worktree, and reused by wt-claude above (gwt-claude).
# Usage: cc-dispatch.sh surface <path> [prompt]
# Related env: CC_WT_PERMISSION_MODE (default auto; set plan for a plan-first sub-task),
#   CC_WT_PRETRUST (default 1), CC_WT_COPY (files to copy into the worktree)
surface)
shift
path="${1:-}"; prompt="${2:-}"
[ -n "$path" ] || { echo "usage: cc-dispatch.sh surface <path> [prompt]" >&2; exit 2; }
[ -d "$path" ] || { echo "directory does not exist: $path" >&2; exit 2; }
abspath="$(cd "$path" 2>/dev/null && pwd -P)" || exit 2

# Failure breadcrumb: log + best-effort cmux desktop notification, so "built a worktree but no tab" is discoverable (gwt-status surfaces it)
_fail() {
  echo "[$(date '+%F %T')] $abspath — $1" >> "$HOME/.config/cc-stack/cc-failures.log" 2>/dev/null || true
  command -v cmux >/dev/null 2>&1 && cmux ping >/dev/null 2>&1 \
    && cmux notify --title "cc-stack: worktree tab failed" --body "$abspath — $1" >/dev/null 2>&1 || true
}

# Must be able to reach cmux; short retry to ride out cmux's transient hiccups/restart window (don't rely on CMUX_SOCKET — often empty in CC's Bash env)
command -v cmux >/dev/null 2>&1 || exit 0
ok=""; for _ in 1 2 3 4 5 6; do cmux ping >/dev/null 2>&1 && { ok=1; break; }; sleep 0.4; done
[ -n "$ok" ] || { _fail "cmux ping unreachable (likely restarting), no tab opened"; exit 0; }

# Dedup (best effort): if a tab was opened for this dir within 120s, don't repeat. Only CHECK here; write the marker after success (failures leave no blocking marker)
marker_dir="${TMPDIR:-/tmp}/cc-cmux-tabs"
mkdir -p "$marker_dir" 2>/dev/null || true
marker="$marker_dir/$(printf '%s' "$abspath" | shasum -a 1 2>/dev/null | cut -d' ' -f1)"
if [ -n "$marker" ] && [ -e "$marker" ]; then
  now=$(date +%s 2>/dev/null || echo 0); mt=$(stat -f %m "$marker" 2>/dev/null || echo 0)
  [ $((now - mt)) -lt 120 ] && exit 0
fi

# Copy gitignored-but-needed files (.env etc.) so hook-path sub-tasks also get their environment (matches gwt-new/gwt-claude)
root="$(git -C "$abspath" rev-parse --git-common-dir 2>/dev/null)" && root="$(cd "$root/.." 2>/dev/null && pwd -P)" || root=""
if [ -n "$root" ] && [ "$root" != "$abspath" ]; then
  for f in ${CC_WT_COPY:-.env .env.local .claude/settings.local.json}; do
    [ -f "$root/$f" ] || continue
    [ -e "$abspath/$f" ] && continue                 # don't overwrite if it already exists
    mkdir -p "$abspath/$(dirname "$f")" 2>/dev/null
    cp -p "$root/$f" "$abspath/$f" 2>/dev/null
  done
  # Seed the shared test corpus (CC_WT_SHARE; default + docs live in cc-worktree-shared.sh;
  # exported-empty disables). Idempotent — never overwrites files already in the worktree.
  "$HOME/.config/cc-stack/cc-worktree-shared.sh" seed "$root" "$abspath" 2>/dev/null
fi

# Record the merge target (parent = caller's branch) — HOOK PATH ONLY.
# On the gwt-claude path CC_CALLER_CWD is unset and wt-claude above already
# captured with the real caller cwd; skipping here avoids overwriting it.
if [ -n "${CC_CALLER_CWD:-}" ] && command -v git >/dev/null 2>&1; then
  _root="$(git -C "$abspath" rev-parse --git-common-dir 2>/dev/null)" && _root="$(cd "$_root/.." && pwd -P)"
  _br="$(git -C "$abspath" symbolic-ref --short HEAD 2>/dev/null)"
  [ -n "$_root" ] && [ -n "$_br" ] && \
    "$HOME/.config/cc-stack/cc-merge.sh" capture "$_root" "$_br" "$CC_CALLER_CWD" >/dev/null 2>&1
fi

# Pre-authorize trust for this worktree, skipping claude's "Do you trust this folder?" prompt (more robust than screen-scraping; CC_WT_PRETRUST=0 disables)
[ "${CC_WT_PRETRUST:-1}" != "0" ] && "$HOME/.config/cc-stack/cc-trust.sh" "$abspath" >/dev/null 2>&1

# Caller (main task) surface / workspace — backchannel + target workspace
ident="$(cmux identify 2>/dev/null)"
caller_surface="$(printf '%s' "$ident" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("caller") or {}).get("surface_ref",""))' 2>/dev/null)"
caller_ws="$(printf '%s' "$ident" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("caller") or {}).get("workspace_ref",""))' 2>/dev/null)"

# Open the new surface (tab): in the caller's workspace, background, no focus steal. Short retry to ride out hiccups.
ref=""
for _ in 1 2 3 4 5; do
  if [ -n "$caller_ws" ]; then
    ref="$(cmux new-surface --type terminal --working-directory "$abspath" --focus false --workspace "$caller_ws" 2>/dev/null | grep -oE 'surface:[0-9]+' | head -1)"
  else
    ref="$(cmux new-surface --type terminal --working-directory "$abspath" --focus false 2>/dev/null | grep -oE 'surface:[0-9]+' | head -1)"
  fi
  [ -n "$ref" ] && break
  sleep 0.4
done
[ -n "$ref" ] || { _fail "cmux new-surface failed to open a tab"; exit 1; }

# Opened successfully; write the dedup marker now
[ -n "$marker" ] && : > "$marker" 2>/dev/null || true

# Wait for the shell to be ready (only counts once the marker command's OUTPUT appears, avoiding the shell-init race)
ready=""
cmux send     --surface "$ref" 'echo RDY$((20+2))' >/dev/null 2>&1
cmux send-key --surface "$ref" Enter               >/dev/null 2>&1
for _ in $(seq 1 40); do
  if cmux read-screen --surface "$ref" --lines 20 2>/dev/null | grep -q 'RDY22'; then ready=1; break; fi
  sleep 0.25
done
[ -n "$ready" ] || echo "⚠ shell-ready probe timed out, sending anyway (may need one manual Enter)" >&2

# Permission mode for the sub-task claude. Default `auto` — it investigates and then implements without an
# approval round-trip, the same mode the main session runs in; `plan` was the old default and cost a human
# round-trip on every single dispatch.
# Per-dispatch override: CC_WT_PERMISSION_MODE=plan (env on the gwt-claude call, or as a prefix token on the
# `git worktree add` command line — cc-hooks.sh worktree parses it out of the command text and passes it through here).
# Whitelisted because the value is interpolated into the launch command below; anything else falls back to auto.
pm="${CC_WT_PERMISSION_MODE:-auto}"
case "$pm" in
  plan|auto|acceptEdits|bypassPermissions|manual|dontAsk) : ;;
  *) pm="auto" ;;
esac

# Assemble the final prompt: user prompt (multi-line preserved) + working agreement + backchannel note.
# Clause (1) MUST track $pm — telling an auto-mode sub-task it is "in plan mode" makes it plan anyway.
if [ "$pm" = "plan" ]; then
  way1="(1) You are in plan mode: present a plan first and wait for human approval before changing code; don't start editing right away."
else
  way1="(1) You are NOT in plan mode — no plan-approval round-trip. Investigate first (read the code and the relevant docs until the logic is actually clear), then implement without waiting for me; do not start typing code off a guess. Do still stop and ask before a structural or destructive decision (schema/migration, cross-module refactor, deleting or rewriting existing behaviour, anything outside this brief)."
fi
full="$prompt"
if [ -n "$prompt" ]; then
  full="$full
——[Working agreement] $way1 (2) Follow this project's own CLAUDE.md and .claude config (harness) throughout; don't drift toward your own defaults. (3) After making changes, commit / rebase / merge / push / removing the worktree or branch ALL require human authorization — even if the finishing-a-development-branch skill prompts you, just stop at 'keep the branch'. (4) When you finish implementing and have reported back, run \`gwt-done\` to mark this branch ready; your merge target is already recorded, so you never choose where to merge, and you never merge without my authorization."
  [ -n "$caller_surface" ] && full="$full (5) To report back / ask the main task: cmux send --surface $caller_surface \"message\" then cmux send-key --surface $caller_surface Enter."
fi

# Start the sub-task claude. Key point: don't type the prompt straight into the terminal (a very long line gets shredded,
# and newlines are treated as Enter). Instead write it to a temp file and type a short command "$(cat file)" — the shell reads
# the file and passes the whole content (newlines and all) to claude as a single argument.
# --permission-mode $pm: resolved above (default auto, CC_WT_PERMISSION_MODE=plan for the plan-first gate).
# Provider for NEW sub-tasks: `gwt-provider` writes a provider name to $CC_LAUNCH_FILE (default anthropic).
# anthropic/default → cmux claude-teams on the official/current-env provider; any other name → `cld <name>`,
# which sources ~/.config/claude/llm-provider/<name>.sh in the new tab (provider env is process-local, so
# existing sub-tasks keep their launch-time provider). Unknown/empty → safe default, never breaks the launch.
_provider="$(cat "${CC_LAUNCH_FILE:-$HOME/.config/cc-stack/launch}" 2>/dev/null)"
case "$_provider" in
  ""|anthropic|default) launch="ccteam" ;;
  */*|*..*)             launch="ccteam" ;;     # path-traversal guard → safe default
  *)                    launch="cld $_provider" ;;
esac
pf=""
if [ -n "$full" ]; then
  pf="${TMPDIR:-/tmp}/cc-wt-prompt.$$.txt"
  printf '%s' "$full" > "$pf"
  cmux send --surface "$ref" "$launch --permission-mode $pm \"\$(cat '$pf')\"" >/dev/null 2>&1
else
  cmux send --surface "$ref" "$launch --permission-mode $pm" >/dev/null 2>&1
fi
cmux send-key --surface "$ref" Enter >/dev/null 2>&1

# Fallback: in case pre-trust didn't take effect (concurrency / schema change), still screen-scrape to confirm "trust this folder".
# Early exit when the claude TUI is already up (its footer hint is visible) — pre-trust worked, no dialog is coming.
# Without that second exit the loop idles its full 24×0.25s on EVERY dispatch (hook path is synchronous = main-session latency).
for _ in $(seq 1 24); do
  scr="$(cmux read-screen --surface "$ref" --lines 30 2>/dev/null | tr 'A-Z' 'a-z')"
  case "$scr" in
    *trust*folder*|*trust*file*|*trust*director*|*"do you trust"*)
      cmux send-key --surface "$ref" Enter >/dev/null 2>&1   # highlighted default = "Yes, I trust"
      break ;;
    *"esc to interrupt"*|*"? for shortcuts"*|*"ctrl+c to exit"*)
      break ;;                                              # claude TUI is up → no trust dialog coming
  esac
  sleep 0.25
done

# claude is up and the prompt is already read into argv by the shell — the temp file can go
[ -n "$pf" ] && rm -f "$pf" 2>/dev/null

# ── Register into the task list (so gwt-status can show "which worktree is doing what") ──
# 5th arg = parent branch (the caller's branch at dispatch — CC_CALLER_CWD on the hook path,
# PWD on the gwt-claude path; empty when detached / not a repo): feeds the board's PARENT
# column and outlives the branch.<b>.ccMergeInto git config.
"$HOME/.config/cc-stack/cc-board.sh" log "$abspath" "$ref" "${caller_surface:-}" "$prompt" \
  "$(git -C "${CC_CALLER_CWD:-$PWD}" symbolic-ref --short HEAD 2>/dev/null)"

echo "✔ new tab : $ref  cwd=$abspath  $([ -n "$prompt" ] && echo '(initial prompt sent)' || echo '(idle ccteam)')"
[ -n "$caller_surface" ] && echo "✔ backchannel: the new claude can report back via cmux send --surface $caller_surface"
exit 0
;;

# ─────────────────────────────────────────────────────────────────────────────
# workspace — open a cmux workspace (empty shell) for a directory.
#   - Safe no-op when not inside cmux (no CMUX_SOCKET), so remote/bare-terminal callers have no side effects.
#   - Best-effort dedup: if a workspace already points at the same directory, don't open another.
# Usage: cc-dispatch.sh workspace <path> [name] [focus=false]
workspace)
shift
# Can we talk to cmux? (don't rely on CMUX_SOCKET — it's often empty in CC's Bash env; the cmux CLI uses its default socket)
command -v cmux >/dev/null 2>&1 || exit 0      # cmux not installed (remote): silently skip
cmux ping >/dev/null 2>&1 || exit 0            # can't reach cmux: silently skip

path="${1:-}"
[ -n "$path" ] || { echo "cc-dispatch.sh workspace: need <path>" >&2; exit 2; }
[ -d "$path" ] || { echo "cc-dispatch.sh workspace: directory does not exist: $path" >&2; exit 2; }

abspath="$(cd "$path" 2>/dev/null && pwd -P)" || exit 2
name="${2:-$(basename "$abspath")}"
focus="${3:-false}"

# Dedup (best effort): if this absolute path already shows up in the workspace list, don't open again
if cmux list-workspaces 2>/dev/null | grep -qF "$abspath"; then
  exit 0
fi

exec cmux new-workspace --name "$name" --cwd "$abspath" --focus "$focus"
;;

*)
  echo "usage: cc-dispatch.sh wt-claude <name> <prompt> [--prefix <p>] [--base <b>] | surface <path> [prompt] | workspace <path> [name] [focus]" >&2; exit 2 ;;
esac
