#!/usr/bin/env bash
# Stop hook for prep-compact v3.0.
# Tail-reads the session transcript and writes a continuously-fresh handoff
# JSON at ${CLAUDE_PLUGIN_DATA}/handoff-<safe_sid>.json. Always exits 0
# (fail-open). Sister to check-context-size.sh.
#
# This task implements the skeleton: stdin parse, session_id safety, transcript
# path resolution, bounded tail-read with per-line cap. Extraction logic is
# added by Task 3; merge + atomic write by Task 4.

set -uo pipefail

CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/cache}"

if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
  printf 'update-handoff: cannot create %s; hook disabled this turn.\n' "$CACHE_DIR" >&2
  exit 0
fi

STDIN_JSON=$(cat 2>/dev/null)

# Python 3 required. If absent, fail open with a stderr warning.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
  PY=python
else
  printf 'update-handoff: Python 3 not found on PATH; hook disabled this turn.\n' >&2
  exit 0
fi

# Extract session_id, transcript_path, cwd from stdin JSON.
EXTRACTED=$(printf '%s' "$STDIN_JSON" | "$PY" -c "
import sys, json, hashlib, re
try:
    d = json.load(sys.stdin)
    sid = d.get('session_id', '') or ''
    tp = d.get('transcript_path', '') or ''
    cwd = d.get('cwd', '') or ''
except Exception:
    sid = ''; tp = ''; cwd = ''

if sid and re.fullmatch(r'[A-Za-z0-9_-]{1,64}', sid):
    safe = sid
elif sid:
    safe = hashlib.sha1(sid.encode('utf-8')).hexdigest()
else:
    safe = ''
print(safe)
print(tp)
print(cwd)
" 2>/dev/null || printf '\n\n\n')
SAFE_SID=$(printf '%s' "$EXTRACTED" | sed -n '1p')
TRANSCRIPT_PATH=$(printf '%s' "$EXTRACTED" | sed -n '2p')
CWD=$(printf '%s' "$EXTRACTED" | sed -n '3p')

if [[ -z "$SAFE_SID" ]]; then
  exit 0
fi

if [[ -z "$TRANSCRIPT_PATH" || ! -r "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# cygpath bridge for Git Bash on Windows.
if command -v cygpath >/dev/null 2>&1; then
  TRANSCRIPT_NATIVE=$(cygpath -w "$TRANSCRIPT_PATH" 2>/dev/null || printf '%s' "$TRANSCRIPT_PATH")
else
  TRANSCRIPT_NATIVE="$TRANSCRIPT_PATH"
fi

HANDOFF_PATH="$CACHE_DIR/handoff-$SAFE_SID.json"

# Tail-read transcript (bounded), iterate lines (per-line capped).
# Skeleton: just verify we can read without OOM. Extraction comes in Task 3.
"$PY" - "$TRANSCRIPT_NATIVE" "$HANDOFF_PATH" "$SAFE_SID" "$CWD" <<'PYEOF' 2>/dev/null || true
import sys, os, json

TAIL_BYTES = 1_048_576       # 1 MB
MAX_LINE_BYTES = 1_048_576   # 1 MB per-line cap (oversized-line guard)

transcript_path, handoff_path, safe_sid, cwd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

try:
    size = os.path.getsize(transcript_path)
except OSError:
    sys.exit(0)

try:
    with open(transcript_path, 'rb') as f:
        f.seek(max(0, size - TAIL_BYTES))
        tail = f.read()
except OSError:
    sys.exit(0)

text = tail.decode('utf-8', errors='replace')
lines = text.splitlines()

# Walk lines end -> start. Skip oversized lines. Skip parse failures.
parsed = []
for line in reversed(lines):
    if len(line.encode('utf-8', errors='replace')) > MAX_LINE_BYTES:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    parsed.append(d)

# Skeleton stops here. Task 3 will extract from `parsed`.
sys.exit(0)
PYEOF

exit 0
