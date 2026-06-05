#!/usr/bin/env bash
# Helper for the prep-compact skill. Resolves the INVOKING session's own
# handoff JSON via $CLAUDE_CODE_SESSION_ID and validates the stored cwd against
# the current cwd ($1). Prints exactly one of:
#   HIT\n<abs-path>   |   MISS   |   NOSID
# Always exits 0 (fail-open), mirroring hooks/update-handoff.sh. Spec:
# docs/superpowers/specs/2026-06-05-prep-compact-session-binding-design.md
set -uo pipefail

CUR_CWD="${1:-$PWD}"

if command -v python3 >/dev/null 2>&1; then PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0]>=3 else 1)' 2>/dev/null; then PY=python
else
  # No Python 3: cannot sanitize sid / parse JSON. Fail open.
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then echo MISS; else echo NOSID; fi
  exit 0
fi

# Normalize filesystem roots to a Python-openable native form. Git Bash hands a
# native Windows Python MSYS paths (/c/..) it cannot stat; cygpath -m yields
# C:/Users/.. (forward slashes — safe in Python, no backslash-escape pitfalls).
# No-op off Windows (cygpath absent; paths already native).
_nrm() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; else printf '%s' "$1"; fi; }
PLUGIN_DATA_N=""; [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && PLUGIN_DATA_N="$(_nrm "$CLAUDE_PLUGIN_DATA")"

SID="${CLAUDE_CODE_SESSION_ID:-}" \
CUR_CWD="$CUR_CWD" \
PLUGIN_DATA="$PLUGIN_DATA_N" \
PLUGIN_ROOT="$(_nrm "${CLAUDE_CODE_PLUGIN_CACHE_DIR:-${HOME:-}/.claude/plugins}")" \
CACHE_FALLBACK="$(_nrm "${HOME:-}/.claude/cache")" \
"$PY" - <<'PYEOF'
import os, re, sys, glob, hashlib, json, subprocess

sid            = os.environ.get("SID", "")
cur_cwd        = os.environ.get("CUR_CWD", "")
plugin_data    = os.environ.get("PLUGIN_DATA", "")
plugin_root    = os.environ.get("PLUGIN_ROOT", "")
cache_fallback = os.environ.get("CACHE_FALLBACK", "")

# Fallback when cygpath is absent but Python is native Windows: map MSYS /c/.. ->
# C:/.. so roots are stat-able. (_nrm already handles the cygpath-present case,
# incl. /tmp.) No-op on POSIX (os.name != 'nt') and where paths are already native.
def _fs(path):
    if not path: return path
    m = re.match(r'^/(?:cygdrive/)?([A-Za-z])/(.*)$', path)
    if m and os.name == 'nt':
        return m.group(1).upper() + ":/" + m.group(2)
    return path
plugin_data    = _fs(plugin_data)
plugin_root    = _fs(plugin_root)
cache_fallback = _fs(cache_fallback)

# safe_sid — identical rule to the hooks.
if sid and re.fullmatch(r'[A-Za-z0-9_-]{1,64}', sid):
    safe = sid
elif sid:
    safe = hashlib.sha1(sid.encode('utf-8')).hexdigest()
else:
    safe = ''
if not safe:
    print("NOSID"); sys.exit(0)

fname = "handoff-%s.json" % safe

# Roots in priority order (list index = priority).
roots = []
if plugin_data:
    roots.append(plugin_data)
roots.extend(sorted(glob.glob(os.path.join(glob.escape(plugin_root), "data", "*"))))
if cache_fallback:
    roots.append(cache_fallback)

candidates = []  # (priority_index, path)
for i, root in enumerate(roots):
    p = os.path.join(root, fname)
    if os.path.isfile(p):
        candidates.append((i, p))
if not candidates:
    print("MISS"); sys.exit(0)

def _have_cygpath():
    try:
        subprocess.run(["cygpath", "--version"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True); return True
    except Exception:
        return False
_CYG = _have_cygpath()

def _to_win(path):
    if _CYG:
        try:
            o = subprocess.run(["cygpath", "-w", path], capture_output=True,
                               text=True, check=True).stdout.strip()
            if o: return o
        except Exception:
            pass
    m = re.match(r'^/(?:cygdrive/)?([A-Za-z])/(.*)$', path)
    if m:
        return m.group(1).upper() + ":\\" + m.group(2).replace('/', '\\')
    return path

def canon(path):
    if not path: return ""
    p = _to_win(path)
    if re.match(r'^[A-Za-z]:', p):                 # Windows drive path
        return p.replace('/', '\\').rstrip('\\').lower()
    return p.rstrip('/')                           # POSIX path, case-sensitive

target = canon(cur_cwd)

kept = []  # (priority_index, path)
for prio, path in candidates:
    try:
        with open(path, 'r', encoding='utf-8') as f:
            d = json.load(f)
        if not isinstance(d, dict):
            continue
        stored = d.get('cwd', '')
        if not isinstance(stored, str):
            continue
        if canon(stored) == target:
            kept.append((prio, path))
    except Exception:
        continue                                   # any malformed/odd candidate: skip, keep scanning
if not kept:
    print("MISS"); sys.exit(0)

kept.sort(key=lambda t: (t[0], t[1]))              # priority, then lexical
chosen = kept[0][1]
print("HIT")
print(_to_win(chosen))
sys.exit(0)
PYEOF
exit 0
