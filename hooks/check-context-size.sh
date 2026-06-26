#!/usr/bin/env bash
# UserPromptSubmit hook for prep-compact v3.0.
# Tail-scans the session transcript (last 256 KB) for the newest main-chain
# assistant .message.usage block. When the sum of input_tokens +
# cache_creation_input_tokens + cache_read_input_tokens exceeds
# CLAUDE_CONTEXT_WARN_TOKENS, emits an informational reminder. If the warm
# handoff file exists at $CACHE_DIR/handoff-$SAFE_SID.json (maintained by the
# Stop hook in update-handoff.sh), the reminder names its path and tells the
# user to run /prep-compact:prep-compact when ready. Otherwise the reminder
# falls back to a shorter copy that just names the skill. Always exits 0
# (fail-open).
#
# A single Python process does both the stdin-JSON parse (session_id,
# transcript_path) and the transcript tail-scan, printing two lines:
#   line 1: safe session id (empty -> caller no-op)
#   line 2: summed token count (absent -> below-threshold/no-usable-usage no-op)
# Collapsing what were two separate python invocations into one removes a
# per-message interpreter cold-start (the dominant cost on Windows).
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

# Single Python process: parse stdin JSON for session_id + transcript_path,
# derive the safe session id, resolve the transcript to a path the interpreter
# can open, tail-scan the last 256 KB for the newest main-chain assistant
# .message.usage, and print safe_sid (line 1) and the summed token count
# (line 2, omitted when there is no usable usage). Defensive at every layer.
RESULT=$(printf '%s' "$STDIN_JSON" | "$PY" -c "
import sys, json, hashlib, re, os, subprocess

TAIL_BYTES = 262144  # 256 KB

try:
    d = json.load(sys.stdin)
    sid = d.get('session_id', '') or ''
    tp = d.get('transcript_path', '') or ''
except Exception:
    print('')
    sys.exit(0)

# session_id safety: regex-valid or SHA-1 hex fallback.
if sid and re.fullmatch(r'[A-Za-z0-9_-]{1,64}', sid):
    safe = sid
elif sid:
    safe = hashlib.sha1(sid.encode('utf-8')).hexdigest()
else:
    print('')
    sys.exit(0)

print(safe)  # line 1 — always emitted once sid is usable

# Resolve transcript to a path the interpreter can open. Native paths
# (Windows/Linux/macOS) open directly; Git Bash maps /tmp/ and /c/ to NTFS
# paths invisible to a Windows-native python.exe, so fall back to cygpath -w.
# cygpath is only spawned when the direct open fails, so the common
# native-path case stays a single process with no extra spawn.
def resolve(path):
    if not path:
        return None
    # Match the pre-merge behaviour: on Git Bash (cygpath present) convert the
    # path FIRST. Native python resolves a POSIX path like /tmp/x to a
    # drive-relative C:\tmp\x that can collide with an unrelated file, so a
    # direct os.path.exists() pre-check could scan the wrong file. cygpath -w is
    # one lightweight spawn (far cheaper than the second python it replaced).
    # When cygpath is absent (Linux/macOS) or errors, fall back to the raw path;
    # a wrong/missing path then fails the open() below and the hook stays silent.
    try:
        proc = subprocess.run(['cygpath', '-w', path],
                              capture_output=True, text=True, timeout=5)
        if proc.returncode == 0:
            c = proc.stdout.strip()
            if c:
                return c
    except Exception:
        pass
    return path

rp = resolve(tp)
if not rp:
    sys.exit(0)  # empty transcript_path -> no token line

try:
    size = os.path.getsize(rp)
    with open(rp, 'rb') as f:
        f.seek(max(0, size - TAIL_BYTES))
        tail = f.read().decode('utf-8', errors='replace')
except OSError:
    sys.exit(0)

for line in reversed(tail.splitlines()):
    try:
        e = json.loads(line)
    except Exception:
        continue
    if not isinstance(e, dict):
        continue
    if e.get('isSidechain') is True:
        continue
    if e.get('isApiErrorMessage') is True:
        continue
    msg = e.get('message')
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
    print(it + cc + cr)  # line 2 — summed token count
    break
" 2>/dev/null)

SAFE_SID=$(printf '%s' "$RESULT" | sed -n '1p')
TOKENS=$(printf '%s' "$RESULT" | sed -n '2p')

if [[ -z "$SAFE_SID" ]]; then
  exit 0
fi

FLAG="$CACHE_DIR/compact-warned-$SAFE_SID"

if [[ -z "$TOKENS" || ! "$TOKENS" =~ ^[0-9]+$ ]]; then
  # No usable usage in tail — silent no-op (pre-first-turn, parse errors,
  # schema drift, oversized-straddle, missing transcript, etc.).
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

HANDOFF_PATH="$CACHE_DIR/handoff-$SAFE_SID.json"
if [[ -e "$HANDOFF_PATH" ]]; then
  printf 'Session context is approximately %s tokens (above configured threshold of %s tokens). The on-disk handoff at %s is current. When the user is ready to compact, run /prep-compact:prep-compact to add the analytical layer (decisions, constraints, blockers, verb-anchored next-step) and emit a tailored /compact <instructions> block. If you are at the very end of a todo list, you may finish the remaining items first.\n' "$TOKENS" "$THRESHOLD" "$HANDOFF_PATH"
else
  printf 'Session context is approximately %s tokens (above configured threshold of %s tokens). Run /prep-compact:prep-compact to survey current state and emit a tailored /compact <instructions> block. If you are at the very end of a todo list, you may finish the remaining items first.\n' "$TOKENS" "$THRESHOLD"
fi

exit 0
