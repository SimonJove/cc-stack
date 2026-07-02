#!/usr/bin/env bash
# cc-stack · Open a new surface (tab) in the CURRENT cmux workspace for an existing directory and start a ccteam claude,
#            optionally with an initial prompt. Opens in background, doesn't steal focus. Not in cmux (remote/Zellij/not installed) = safe no-op.
# Called automatically by cc-worktree-cmux-hook.sh, and reused by cc-worktree-claude.sh (gwt-claude).
# Usage: cc-cmux-surface-claude.sh <path> [prompt]
# Related env: CC_WT_PERMISSION_MODE (default plan), CC_WT_PRETRUST (default 1), CC_WT_COPY (files to copy into the worktree)
set -u

path="${1:-}"; prompt="${2:-}"
[ -n "$path" ] || { echo "usage: cc-cmux-surface-claude.sh <path> [prompt]" >&2; exit 2; }
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
fi

# Record the merge target (parent = caller's branch) — HOOK PATH ONLY.
# On the gwt-claude path CC_CALLER_CWD is unset and cc-worktree-claude.sh already
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

# Assemble the final prompt: user prompt (multi-line preserved) + working agreement + backchannel note
full="$prompt"
if [ -n "$prompt" ]; then
  full="$full
——[Working agreement] (1) You are in plan mode: present a plan first and wait for human approval before changing code; don't start editing right away. (2) Follow this project's own CLAUDE.md and .claude config (harness) throughout; don't drift toward your own defaults. (3) After making changes, commit / rebase / merge / push / removing the worktree or branch ALL require human authorization — even if the finishing-a-development-branch skill prompts you, just stop at 'keep the branch'. (4) When you finish implementing and have reported back, run \`gwt-done\` to mark this branch ready; your merge target is already recorded, so you never choose where to merge, and you never merge without my authorization."
  [ -n "$caller_surface" ] && full="$full (5) To report back / ask the main task: cmux send --surface $caller_surface \"message\" then cmux send-key --surface $caller_surface Enter."
fi

# Start the team-ready claude (ccteam). Key point: don't type the prompt straight into the terminal (a very long line gets shredded,
# and newlines are treated as Enter). Instead write it to a temp file and type a short command ccteam "$(cat file)" — the shell reads
# the file and passes the whole content (newlines and all) to claude as a single argument.
# --permission-mode plan: the sub-task presents a plan and waits at the approval gate before editing (override via CC_WT_PERMISSION_MODE).
pm="${CC_WT_PERMISSION_MODE:-plan}"
pf=""
if [ -n "$full" ]; then
  pf="${TMPDIR:-/tmp}/cc-wt-prompt.$$.txt"
  printf '%s' "$full" > "$pf"
  cmux send --surface "$ref" "ccteam --permission-mode $pm \"\$(cat '$pf')\"" >/dev/null 2>&1
else
  cmux send --surface "$ref" "ccteam --permission-mode $pm" >/dev/null 2>&1
fi
cmux send-key --surface "$ref" Enter >/dev/null 2>&1

# Fallback: in case pre-trust didn't take effect (concurrency / schema change), still screen-scrape to confirm "trust this folder"
for _ in $(seq 1 24); do
  scr="$(cmux read-screen --surface "$ref" --lines 30 2>/dev/null | tr 'A-Z' 'a-z')"
  case "$scr" in
    *trust*folder*|*trust*file*|*trust*director*|*"do you trust"*)
      cmux send-key --surface "$ref" Enter >/dev/null 2>&1   # highlighted default = "Yes, I trust"
      break ;;
  esac
  sleep 0.25
done

# claude is up and the prompt is already read into argv by the shell — the temp file can go
[ -n "$pf" ] && rm -f "$pf" 2>/dev/null

# ── Register into the task list (so gwt-status can show "which worktree is doing what") ──
"$HOME/.config/cc-stack/cc-tasks-log.sh" "$abspath" "$ref" "${caller_surface:-}" "$prompt"

echo "✔ new tab : $ref  cwd=$abspath  $([ -n "$prompt" ] && echo '(initial prompt sent)' || echo '(idle ccteam)')"
[ -n "$caller_surface" ] && echo "✔ backchannel: the new claude can report back via cmux send --surface $caller_surface"
exit 0
