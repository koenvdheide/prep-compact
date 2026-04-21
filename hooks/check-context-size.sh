#!/usr/bin/env bash
# UserPromptSubmit hook for prep-compact v2.0.0.
# Tail-scans the session transcript (last 256 KB) for the newest main-chain
# assistant .message.usage block. When the sum of input_tokens +
# cache_creation_input_tokens + cache_read_input_tokens exceeds
# CLAUDE_CONTEXT_WARN_TOKENS, emits a one-shot reminder telling Claude to
# invoke the prep-compact skill. Always exits 0 (fail-open).
#
# Main-chain filter: role == 'assistant', isSidechain != true,
# isApiErrorMessage != true. input_tokens required; cache fields default to 0.
# No byte path, no baseline, no RESET.

set -uo pipefail

CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/cache}"
THRESHOLD="${CLAUDE_CONTEXT_WARN_TOKENS:-450000}"

# Validate threshold: non-negative integer, no leading zeros. Bash arithmetic
# under `set -u` on a non-numeric env var exits non-zero; `08` / `09` hit
# "value too great for base" (octal interpretation). Either breaks fail-open.
if ! [[ "$THRESHOLD" =~ ^(0|[1-9][0-9]*)$ ]]; then
  printf 'check-context-size: ignoring invalid CLAUDE_CONTEXT_WARN_TOKENS=%q; using 450000.\n' "$THRESHOLD" >&2
  THRESHOLD=450000
fi

if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
  printf 'check-context-size: cannot create %s; hook disabled this turn.\n' "$CACHE_DIR" >&2
  exit 0
fi

STDIN_JSON=$(cat 2>/dev/null)

# Python 3 required. If absent, fail open with a stderr warning.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
  PY=python
else
  printf 'check-context-size: Python 3 not found on PATH; hook disabled this turn.\n' >&2
  exit 0
fi

# Extract session_id and transcript_path from stdin JSON.
EXTRACTED=$(printf '%s' "$STDIN_JSON" | "$PY" -c "
import sys, json, hashlib, re
try:
    d = json.load(sys.stdin)
    sid = d.get('session_id', '') or ''
    tp = d.get('transcript_path', '') or ''
except Exception:
    sid = ''
    tp = ''

# session_id safety: regex-valid or SHA-1 hex fallback.
if sid and re.fullmatch(r'[A-Za-z0-9_-]{1,64}', sid):
    safe = sid
elif sid:
    safe = hashlib.sha1(sid.encode('utf-8')).hexdigest()
else:
    safe = ''
print(safe)
print(tp)
" 2>/dev/null || printf '\n\n')
SAFE_SID=$(printf '%s' "$EXTRACTED" | sed -n '1p')
TRANSCRIPT_PATH=$(printf '%s' "$EXTRACTED" | sed -n '2p')

if [[ -z "$SAFE_SID" ]]; then
  exit 0
fi

FLAG="$CACHE_DIR/compact-warned-$SAFE_SID"

if [[ -z "$TRANSCRIPT_PATH" || ! -r "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# Convert transcript_path to a format the native Python can open. Git Bash
# on Windows maps /tmp/ and /c/ to NTFS paths that are invisible to a
# Windows-native python.exe; cygpath -w bridges the gap. On Linux/macOS
# cygpath isn't present and the path is already native, so we fall through.
if command -v cygpath >/dev/null 2>&1; then
  TRANSCRIPT_NATIVE=$(cygpath -w "$TRANSCRIPT_PATH" 2>/dev/null || printf '%s' "$TRANSCRIPT_PATH")
else
  TRANSCRIPT_NATIVE="$TRANSCRIPT_PATH"
fi

# Tail-scan the transcript for the newest main-chain assistant .message.usage.
# Prints the summed token count or nothing. Defensive at every layer.
TOKENS=$(printf '%s' "$TRANSCRIPT_NATIVE" | "$PY" -c "
import sys, json, os

TAIL_BYTES = 262144  # 256 KB

path = sys.stdin.read().strip()
try:
    size = os.path.getsize(path)
except OSError:
    sys.exit(0)
try:
    with open(path, 'rb') as f:
        f.seek(max(0, size - TAIL_BYTES))
        tail = f.read().decode('utf-8', errors='replace')
except OSError:
    sys.exit(0)

for line in reversed(tail.splitlines()):
    try:
        d = json.loads(line)
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    if d.get('isSidechain') is True:
        continue
    if d.get('isApiErrorMessage') is True:
        continue
    msg = d.get('message')
    if not isinstance(msg, dict):
        continue
    if msg.get('role') != 'assistant':
        continue
    u = msg.get('usage')
    if not isinstance(u, dict):
        continue
    it = u.get('input_tokens')
    if not isinstance(it, int):
        continue
    cc = u.get('cache_creation_input_tokens') or 0
    cr = u.get('cache_read_input_tokens') or 0
    if not isinstance(cc, int) or not isinstance(cr, int):
        continue
    print(it + cc + cr)
    sys.exit(0)
" 2>/dev/null)

if [[ -z "$TOKENS" || ! "$TOKENS" =~ ^[0-9]+$ ]]; then
  # No usable usage in tail — silent no-op (pre-first-turn, parse errors,
  # schema drift, oversized-straddle, etc.).
  exit 0
fi

if (( TOKENS < THRESHOLD )); then
  # Below threshold — clear any stale flag so a future legitimate crossing fires.
  rm -f "$FLAG" 2>/dev/null || true
  exit 0
fi

if [[ -e "$FLAG" ]]; then
  # Flag already set — suppress re-fire within this delta-crossing.
  exit 0
fi

: >"$FLAG"

printf 'Session context is approximately %s tokens (above configured threshold of %s tokens). Invoke the prep-compact skill to generate a tailored /compact <instructions> command for the user.\n' "$TOKENS" "$THRESHOLD"

exit 0
