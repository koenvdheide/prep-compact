#!/usr/bin/env bash
# UserPromptSubmit + PostCompact hook.
# When session transcript delta since last compact crosses
# CLAUDE_CONTEXT_WARN_BYTES, emit a one-shot reminder telling Claude to invoke
# the prep-compact skill. RESET (PostCompact) records current transcript bytes
# as the per-session baseline and clears the warned flag so the next crossing
# re-arms. Always exits 0 (fail-open).

set -uo pipefail

MODE="${1:-}"
CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/cache}"
THRESHOLD="${CLAUDE_CONTEXT_WARN_BYTES:-4000000}"

# Validate threshold: non-negative integer, no leading zeros. Bash arithmetic
# under `set -u` on a non-numeric env var exits non-zero; `08` / `09` hit
# "value too great for base" (octal interpretation). Either breaks fail-open.
if ! [[ "$THRESHOLD" =~ ^(0|[1-9][0-9]*)$ ]]; then
  printf 'check-context-size: ignoring invalid CLAUDE_CONTEXT_WARN_BYTES=%q; using 4000000.\n' "$THRESHOLD" >&2
  THRESHOLD=4000000
fi

if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
  printf 'check-context-size: cannot create %s; hook disabled this turn.\n' "$CACHE_DIR" >&2
  exit 0
fi

STDIN_JSON=$(cat 2>/dev/null)

# Python 3 required. If absent, fail open silently.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
  PY=python
else
  printf 'check-context-size: Python 3 not found on PATH; hook disabled this turn.\n' >&2
  exit 0
fi

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
BASELINE_FILE="$CACHE_DIR/compact-baseline-$SAFE_SID"

BASELINE=0
if [[ -r "$BASELINE_FILE" ]]; then
  B_READ=$(cat "$BASELINE_FILE" 2>/dev/null | tr -d '[:space:]')
  if [[ "$B_READ" =~ ^[0-9]+$ ]]; then
    BASELINE=$B_READ
  fi
fi

# RESET (PostCompact): refresh baseline, clear the warned flag.
if [[ "$MODE" == "RESET" ]]; then
  if [[ -n "$TRANSCRIPT_PATH" && -r "$TRANSCRIPT_PATH" ]]; then
    CURRENT_BYTES=$(wc -c <"$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
    if [[ "$CURRENT_BYTES" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$CURRENT_BYTES" >"$BASELINE_FILE" 2>/dev/null || true
    fi
  fi
  rm -f "$FLAG" 2>/dev/null || true
  exit 0
fi

# UserPromptSubmit: stat transcript, compute delta, decide.
if [[ -z "$TRANSCRIPT_PATH" || ! -r "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

BYTES=$(wc -c <"$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
if [[ -z "$BYTES" || ! "$BYTES" =~ ^[0-9]+$ ]]; then
  exit 0
fi

if (( BYTES < BASELINE )); then
  # Transcript rotated; treat delta as absolute bytes.
  DELTA=$BYTES
else
  DELTA=$(( BYTES - BASELINE ))
fi

if (( DELTA < THRESHOLD )); then
  # Below threshold — clear any stale flag so a future legitimate crossing fires.
  rm -f "$FLAG" 2>/dev/null || true
  exit 0
fi

if [[ -e "$FLAG" ]]; then
  exit 0
fi

: >"$FLAG"

# The "~450K tokens on Opus 4.7" calibration is only accurate for the 4 MB
# default threshold. Drop it when the user has overridden the threshold.
if (( THRESHOLD == 4000000 )); then
  CALIBRATION=', ~450K tokens on Opus 4.7'
else
  CALIBRATION=''
fi

if (( BASELINE > 0 )); then
  printf 'Session transcript is approximately %s bytes, delta %s bytes since last compact (above the configured threshold of %s bytes%s). Invoke the prep-compact skill to generate a tailored /compact <instructions> command for the user.\n' "$BYTES" "$DELTA" "$THRESHOLD" "$CALIBRATION"
else
  printf 'Session transcript is approximately %s bytes (above the configured threshold of %s bytes%s). Invoke the prep-compact skill to generate a tailored /compact <instructions> command for the user.\n' "$BYTES" "$THRESHOLD" "$CALIBRATION"
fi

exit 0
