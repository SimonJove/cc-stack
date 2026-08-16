#!/usr/bin/env bash
# cc-stack installer — one script, two modes; idempotent, backs up, interactive.
#
#   A) Remote one-liner (recommended):
#        curl -fsSL https://raw.githubusercontent.com/SimonJove/cc-stack/main/install.sh | bash
#      It auto git-clones into the target dir (default ~/.config/cc-stack) and installs.
#
#   B) Local (clone anywhere, e.g. ~/Desktop/cc-stack):
#        git clone https://github.com/SimonJove/cc-stack.git ~/Desktop/cc-stack && cd ~/Desktop/cc-stack && ./install.sh
#      Guides you interactively, installs the files into the target dir (default ~/.config/cc-stack), then configures the environment.
#
#   Options / env vars:
#     --dir <path> | CC_STACK_DIR    install target dir (default ~/.config/cc-stack)
#     --repo <url> | CC_STACK_REPO   git repo URL for remote mode
#     --yes                          non-interactive, take all defaults
#     --dry-run                      report only, change nothing
#     --cmux                         hint about recommended cmux.json settings
set -u

DEFAULT_REPO="https://github.com/SimonJove/cc-stack.git"
DEFAULT_DEST="$HOME/.config/cc-stack"

DEST=""; REPO=""; YES=""; DRY=""; CMUX=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DEST="${2:-}"; shift 2;;
    --repo) REPO="${2:-}"; shift 2;;
    --yes|-y) YES=1; shift;;
    --dry-run) DRY=1; shift;;
    --cmux) CMUX=1; shift;;
    *) shift;;
  esac
done
DEST="${DEST:-${CC_STACK_DIR:-}}"
REPO="${REPO:-${CC_STACK_REPO:-$DEFAULT_REPO}}"
ts="$(date +%Y%m%d-%H%M%S)"

say(){ printf '%s\n' "$*"; }
tilde(){ case "$1" in "$HOME"/*) printf '~%s' "${1#$HOME}";; *) printf '%s' "$1";; esac; }
# Interactive input (reads from /dev/tty even when stdin is a pipe, e.g. curl|bash); --yes or no tty → take default
ask(){ local __v="$1" __p="$2" __d="$3" __a=""
  if [ -z "$YES" ] && [ -e /dev/tty ]; then printf '%s [%s]: ' "$__p" "$__d" >/dev/tty; IFS= read -r __a </dev/tty || __a=""; fi
  [ -n "$__a" ] || __a="$__d"; printf -v "$__v" '%s' "$__a"; }
confirm(){ local __p="$1" __d="${2:-y}" __a=""
  [ -n "$YES" ] && return 0
  if [ -e /dev/tty ]; then printf '%s [%s]: ' "$__p" "$([ "$__d" = y ] && echo Y/n || echo y/N)" >/dev/tty; IFS= read -r __a </dev/tty || __a=""; fi
  __a="${__a:-$__d}"; case "$__a" in [yY]*) return 0;; *) return 1;; esac; }
bak(){ [ -f "$1" ] || return 0; [ -n "$DRY" ] && { say "  [dry-run] back up $(tilde "$1")"; return 0; }; cp -p "$1" "$1.bak.$ts" && say "  backed up → $(tilde "$1").bak.$ts"; }

# ── Decide source: local (cc-stack files next to this script) or remote (piped via curl, needs downloading) ──
SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)"
LOCAL_SRC=""
[ -n "$SELF" ] && [ -f "$SELF/worktree.zsh" ] && [ -f "$SELF/cc-dispatch.sh" ] && LOCAL_SRC="$SELF"

say "╭─ cc-stack installer ${DRY:+ [DRY-RUN]}"
say "│  source: $([ -n "$LOCAL_SRC" ] && echo "local $(tilde "$LOCAL_SRC")" || echo "remote git clone")"

# ── Target dir ──
if [ -z "$DEST" ]; then
  if [ -n "$LOCAL_SRC" ] && [ "$LOCAL_SRC" = "$DEFAULT_DEST" ]; then DEST="$DEFAULT_DEST"
  else ask DEST "│  install into which directory?" "$DEFAULT_DEST"; fi
fi
DEST="${DEST/#\~/$HOME}"
say "│  target: $(tilde "$DEST")"
say "╰─"

# ── Obtain the source into a staging area (remote: clone; local: use LOCAL_SRC) ──
TMP=""; SRC=""
cleanup(){ [ -n "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT
if [ -n "$LOCAL_SRC" ]; then
  SRC="$LOCAL_SRC"
else
  case "$REPO" in *CHANGE-ME*)
    if [ -e /dev/tty ] && [ -z "$YES" ]; then ask REPO "remote mode needs a git repo URL" ""; fi
    ;; esac
  case "$REPO" in ""|*CHANGE-ME*) say "✗ no repo URL. Use --repo <url> or CC_STACK_REPO=<url>, or edit DEFAULT_REPO at the top of this script."; exit 1;; esac
  command -v git >/dev/null 2>&1 || { say "✗ git is required for remote download"; exit 1; }
  say "▸ download: git clone $REPO"
  if [ -n "$DRY" ]; then say "  [dry-run] skip clone"; SRC="$LOCAL_SRC"
  else TMP="$(mktemp -d)"; git clone --depth 1 "$REPO" "$TMP/cc-stack" >/dev/null 2>&1 || { say "✗ git clone failed: $REPO"; exit 1; }; SRC="$TMP/cc-stack"; fi
fi

# ── Install (copy source into DEST, excluding .git / backups / runtime-generated files) ──
say "▸ install files → $(tilde "$DEST")"
if [ -n "$SRC" ] && [ "$SRC" != "$DEST" ]; then
  if [ -d "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
    confirm "  target already exists, overwrite (changed files are backed up first)?" y || { say "  cancelled."; exit 1; }
  fi
  if [ -n "$DRY" ]; then say "  [dry-run] copy $(tilde "$SRC")/* → $(tilde "$DEST")/ (excluding .git/*.bak/generated)"
  else
    mkdir -p "$DEST"
    ( cd "$SRC" && find . -type f ! -path './.git/*' ! -name '*.bak.*' \
        ! -name 'worktree-tasks.tsv' ! -name 'worktree-tasks-archive.tsv' ! -name 'worktree-status.tsv' ! -name 'cc-failures.log' ! -name '.DS_Store' -print0 ) \
      | while IFS= read -r -d '' f; do mkdir -p "$DEST/$(dirname "$f")"; cp -p "$SRC/$f" "$DEST/$f"; done
    say "  ✓ installed"
  fi
else
  say "  ✓ source is the target, configuring in place"
fi

CC="$DEST"; CCT="$(tilde "$CC")"

# ── 1. Executable bits ──
say "▸ 1. executable bits"
[ -n "$DRY" ] || chmod +x "$CC"/*.sh "$CC/cc-claude" "$CC"/hooks/*.sh 2>/dev/null || true
say "  ✓"

# ── 2. Dependency check ──
say "▸ 2. dependency check"
miss=""; for c in git python3 zsh shasum column; do command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done
ext=""; for c in cmux claude; do command -v "$c" >/dev/null 2>&1 || ext="$ext $c"; done
[ -z "$miss" ] && say "  ✓ base deps present" || say "  ✗ missing: $miss"
[ -z "$ext" ] && say "  ✓ cmux / claude present" || say "  ⚠ not found: $ext (fine on remote/no-GUI machines, scripts will no-op)"

# ── 3. zsh loading ──
say "▸ 3. zsh auto-source"
RC="$HOME/.zshrc"
if [ -f "$RC" ] && grep -qF "cc-stack/worktree.zsh" "$RC" 2>/dev/null; then say "  ✓ already configured, skipping"
elif [ -f "$RC" ] && grep -qF "$CCT/worktree.zsh" "$RC" 2>/dev/null; then say "  ✓ already configured, skipping"
else
  bak "$RC"
  if [ -z "$DRY" ]; then { printf '\n# cc-stack: cmux + git worktree dev stack\nfor f in %s/worktree.zsh %s/aliases.zsh; do\n  [ -r "$f" ] && source "$f"\ndone\n' "$CCT" "$CCT"; } >> "$RC"; fi
  say "  ✓ added to $(tilde "$RC")"
fi

# ── 4. Claude Code hooks ──
say "▸ 4. Claude Code hooks (settings.json)"
SET="$HOME/.claude/settings.json"; mkdir -p "$HOME/.claude"
[ -f "$SET" ] || { [ -n "$DRY" ] || echo '{}' > "$SET"; say "  (created settings.json)"; }
bak "$SET"
CC_SET="$SET" CC_HOOK="$CCT/cc-hooks.sh worktree" CC_STAT="$CCT/cc-hooks.sh status" \
CC_PRE_COMMIT="$CCT/hooks/block-worktree-commit.sh" CC_PRE_CLOSE="$CCT/hooks/block-unsafe-close.sh" \
CC_DRY="$DRY" python3 - <<'PY'
import json,os,sys,tempfile
p=os.environ["CC_SET"];hook=os.environ["CC_HOOK"];stat=os.environ["CC_STAT"];dry=os.environ.get("CC_DRY","")
pre=[os.environ["CC_PRE_COMMIT"],os.environ["CC_PRE_CLOSE"]]
try: d=json.load(open(p,encoding="utf-8"))
except Exception: d={}
if not isinstance(d,dict): d={}
hk=d.setdefault("hooks",{})
def has(ev,cmd):
    for g in hk.get(ev,[]) or []:
        for h in (g.get("hooks") or []):
            if h.get("command")==cmd: return True
    return False
added=[]
if not has("PostToolUse",hook): hk.setdefault("PostToolUse",[]).append({"matcher":"Bash|EnterWorktree","hooks":[{"type":"command","command":hook}]}); added.append("PostToolUse")
# cc-hooks.sh status: sub-task agent state (working/idle/blocked) for gwt-status's STATUS column.
# Lifecycle events, not tool events → no matcher key.
for ev in ("UserPromptSubmit","Stop","Notification"):
    if not has(ev,stat): hk.setdefault(ev,[]).append({"hooks":[{"type":"command","command":stat}]}); added.append(ev)
# PreToolUse gates (Bash): the commit gate (worktree sub-tasks may not commit without the human's
# sentinel) and the tab-close gate (only a parent may close its own sub-task tab). Both live in
# the repo under hooks/ and are installed with everything else — the commit gate used to sit
# UNVERSIONED in ~/.claude/hooks/, whose registration is swept below.
for cmd_ in pre:
    if not has("PreToolUse",cmd_):
        hk.setdefault("PreToolUse",[]).append({"matcher":"Bash","hooks":[{"type":"command","command":cmd_}]})
        added.append("PreToolUse:"+os.path.basename(cmd_))
# Migration: strip stale hook commands from older layouts, wherever they appear — cc-notify.sh
# (long gone), cc-worktree-cmux-hook.sh / cc-status-hook.sh (absorbed into cc-hooks.sh by the
# cc-* consolidation) and the pre-repo ~/.claude/hooks/ copy of the commit gate. Only matching
# commands are removed; every other hook is left untouched (the registrations above share these
# events and must survive the sweep — note the stale entry is matched on the OLD .claude/hooks/
# path, which the new <cc-stack>/hooks/ command never contains).
STALE=("cc-notify","cc-worktree-cmux-hook.sh","cc-status-hook.sh",".claude/hooks/block-worktree-commit.sh")
removed=[]
for ev in list(hk.keys()):
    groups=hk.get(ev,[]) or []
    if not groups: continue
    new_groups=[]; changed=False
    for g in groups:
        hs=g.get("hooks") or []
        keep=[h for h in hs if not any(s in (h.get("command","") or "") for s in STALE)]
        if len(keep)!=len(hs): changed=True
        if keep: gg=dict(g); gg["hooks"]=keep; new_groups.append(gg)
    if changed:
        removed.append(ev)
        if new_groups: hk[ev]=new_groups
        else: hk.pop(ev,None)            # event emptied → drop the key, keep settings.json tidy
if not added and not removed: print("  ✓ already in place (all hooks present, nothing stale)"); sys.exit(0)
if dry:
    msg=[]
    if added: msg.append("would add: "+", ".join(added))
    if removed: msg.append("would remove stale hooks on: "+", ".join(removed))
    print("  [dry-run] "+"; ".join(msg)); sys.exit(0)
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(p),prefix=".settings.cc.")
with os.fdopen(fd,"w",encoding="utf-8") as f: json.dump(d,f,ensure_ascii=False,indent=2)
os.replace(tmp,p)
msg=[]
if added: msg.append("added: "+", ".join(added))
if removed: msg.append("removed stale hooks on: "+", ".join(removed))
print("  ✓ "+"; ".join(msg))
PY

# ── 5. Global CLAUDE.md rules ──
say "▸ 5. global CLAUDE.md rules"
CMD="$HOME/.claude/CLAUDE.md"; RULES="$CC/claude-rules.md"
if [ ! -f "$RULES" ]; then say "  ✗ claude-rules.md missing, skipping"; else
  bak "$CMD"
  CC_CMD="$CMD" CC_RULES="$RULES" CC_DRY="$DRY" python3 - <<'PY'
import os,sys,re,tempfile
cmd=os.environ["CC_CMD"];rules=os.environ["CC_RULES"];dry=os.environ.get("CC_DRY","")
B="<!-- cc-stack:begin (managed by install.sh; content comes from ~/.config/cc-stack/claude-rules.md, don't edit this block by hand) -->"
E="<!-- cc-stack:end -->"
body=open(rules,encoding="utf-8").read().rstrip("\n"); block=B+"\n"+body+"\n"+E+"\n"
try: cur=open(cmd,encoding="utf-8").read()
except Exception: cur=""
if B in cur and E in cur: new=re.sub(re.escape(B)+r".*?"+re.escape(E)+r"\n?",block,cur,count=1,flags=re.S); act="updated managed block"
elif cur.strip(): new=cur.rstrip("\n")+"\n\n"+block; act="appended managed block (kept existing content)"
else: new=block; act="created CLAUDE.md"
if new==cur: print("  ✓ already up to date"); sys.exit(0)
if dry: print("  [dry-run]",act); sys.exit(0)
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(cmd) or ".",prefix=".CLAUDE.cc.")
with os.fdopen(fd,"w",encoding="utf-8") as f: f.write(new)
os.replace(tmp,cmd); print("  ✓",act)
PY
fi

# ── 6. cmux.json (optional, --cmux) ──
say "▸ 6. cmux.json (workflow config)"
if [ -z "$CMUX" ]; then
  say "  skipped (re-run with --cmux to deep-merge the workflow cmux.json — minimalMode, workspace/tab nav keys, etc.)"
elif [ ! -f "$CC/config/cmux.json" ]; then
  say "  ✗ config/cmux.json missing, skipping"
else
  CMUXDST="$HOME/.config/cmux/cmux.json"; mkdir -p "$HOME/.config/cmux"
  bak "$CMUXDST"
  CC_SRC="$CC/config/cmux.json" CC_DST="$CMUXDST" CC_DRY="$DRY" python3 - <<'PY'
import json,os,sys,tempfile
src=os.environ["CC_SRC"];dst=os.environ["CC_DST"];dry=os.environ.get("CC_DRY","")
def load(p):
    try:
        with open(p,encoding="utf-8") as f: return json.load(f)
    except Exception: return {}
def merge(a,b):  # deep-merge b into a (b wins on leaves); returns merged copy
    out=dict(a)
    for k,v in b.items():
        if isinstance(v,dict) and isinstance(out.get(k),dict): out[k]=merge(out[k],v)
        else: out[k]=v
    return out
cur=load(dst); add=load(src)
new=merge(cur,add)
if new==cur: print("  ✓ already up to date"); sys.exit(0)
if dry: print("  [dry-run] would deep-merge workflow cmux.json (yours is backed up)"); sys.exit(0)
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(dst),prefix=".cmux.cc.")
with os.fdopen(fd,"w",encoding="utf-8") as f: json.dump(new,f,ensure_ascii=False,indent=2)
os.replace(tmp,dst); print("  ✓ merged workflow settings into cmux.json (restart cmux, or run: cmux reload-config)")
PY
fi

say ""
say "✅ install complete: $(tilde "$DEST")"
say "   • new terminals load gwt-* automatically; for the current one: source $CCT/worktree.zsh"
say "   • hooks/CLAUDE.md take effect in NEWLY started claude sessions"
say "   • self-test: gwt-test    cheatsheet: gwt-help"
