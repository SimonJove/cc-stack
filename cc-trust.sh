#!/usr/bin/env bash
# cc-stack · Pre-authorize trust for a directory: set projects[<abs-path>].hasTrustDialogAccepted=true
# in ~/.claude.json, so claude skips the "Do you trust this folder?" prompt on startup (more robust than screen-scraping).
#   - Atomic write (temp+rename); preserves existing key order and 2-space indent; only writes when missing/different.
#   - Any error → exit 0 safely without touching the file. Callers can disable via CC_WT_PRETRUST=0.
# Usage: cc-trust.sh <dir>            pre-trust (default)
#        cc-trust.sh --remove <dir>   remove the pre-trust entry (only if it's a "pure trust signature", never a real project)
set -u
mode="add"
if [ "${1:-}" = "--remove" ]; then mode="remove"; shift; fi
dir="${1:-}"; [ -n "$dir" ] || exit 0
# add needs the dir to exist for canonicalization; on remove the dir may be gone, fall back to the raw path
abs="$(cd "$dir" 2>/dev/null && pwd -P)" || abs="$dir"
cfg="${CC_TRUST_CFG_OVERRIDE:-$HOME/.claude.json}"   # override for tests only
[ -f "$cfg" ] || exit 0

CC_T_MODE="$mode" CC_T_DIR="$abs" CC_T_RAW="$dir" CC_T_CFG="$cfg" python3 - <<'PY' 2>/dev/null || exit 0
import json, os, sys, tempfile
cfg = os.environ["CC_T_CFG"]; d = os.environ["CC_T_DIR"]; raw = os.environ["CC_T_RAW"]; mode = os.environ["CC_T_MODE"]
try:
    with open(cfg, encoding="utf-8") as f:
        data = json.load(f)          # json.load preserves insertion order
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
projects = data.get("projects")
if projects is None:
    projects = data["projects"] = {}
if not isinstance(projects, dict):
    sys.exit(0)

SIG = {"hasTrustDialogAccepted", "hasCompletedProjectOnboarding", "projectOnboardingSeenCount"}
changed = False
if mode == "remove":
    # Only delete "pure trust signature" entries (key set == SIG exactly); never a project with real activity (lastCost, etc.)
    for key in (d, raw):
        v = projects.get(key)
        if isinstance(v, dict) and set(v.keys()) == SIG:
            del projects[key]; changed = True
else:
    ent = projects.get(d)
    if not isinstance(ent, dict):
        ent = projects[d] = {}
    for k, v in (("hasTrustDialogAccepted", True),
                 ("hasCompletedProjectOnboarding", True),
                 ("projectOnboardingSeenCount", 0)):
        if ent.get(k) != v:
            ent[k] = v; changed = True
if not changed:
    sys.exit(0)
# Atomic write: temp file in the same dir + os.replace, avoids half-written files; format matches claude (2-space indent, raw unicode)
dirn = os.path.dirname(cfg) or "."
fd, tmp = tempfile.mkstemp(dir=dirn, prefix=".claude.json.cc.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, cfg)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
    sys.exit(0)
PY
