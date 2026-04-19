#!/usr/bin/env bash
# UserPromptSubmit + PostCompact hook.
# Default mode: emit a prep-compact reminder once per "session-above-threshold" interval.
# RESET arg: delete ONLY the flag for the stdin session_id (scoped; never wildcards).
# Always exits 0 so a hook failure never blocks the user's prompt.

set -uo pipefail

MODE="${1:-}"
# Prefer the plugin's per-plugin persistent data dir (${CLAUDE_PLUGIN_DATA}),
# which survives updates and plugin uninstall/reinstall. Fall back to the
# user-global cache when the hook runs outside a plugin context (standalone
# install at ~/.claude/hooks/).
CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/cache}"
THRESHOLD="${CLAUDE_CONTEXT_WARN_BYTES:-4000000}"

if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
  printf 'check-context-size: cannot create %s; hook disabled this turn.\n' "$CACHE_DIR" >&2
  exit 0
fi

# cat exits 0 on empty pipe; STDIN_JSON may be empty. Python block below
# raises JSONDecodeError on empty input and the except branch handles it by
# returning empty safe_sid — no explicit '{}' fallback needed.
STDIN_JSON=$(cat 2>/dev/null)

# SHA-1 helper used by both the python-present and pure-bash extraction paths.
# Prefers sha1sum (ubiquitous on Linux and Git Bash), falls back to shasum
# (macOS default), and as a last-resort degrades to a sanitized truncation of
# the input so the flag filename is always safe even without any hash tool.
sha1_hex() {
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  else
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_' | head -c 64
  fi
}

# Python is preferred — its json.load handles arbitrary field orderings and
# embedded quotes robustly. When python is unavailable, we fall back to
# sed+grep extraction, which relies on Claude Code's observed JSON ordering
# (session_id and transcript_path always precede the user-controlled `prompt`
# field). PREP_COMPACT_DISABLE_PYTHON=1 forces the fallback path for tests.
if [[ -n "${PREP_COMPACT_DISABLE_PYTHON-}" ]]; then
  PY=""
elif command -v python3 >/dev/null 2>&1; then
  # python3 binary is always Python 3.x by convention.
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
  # python may be 2.x on older macOS / Linux systems; the inline parser uses
  # re.fullmatch which is Python 3.4+. Gate on an actual version check so a
  # Python 2 binary doesn't cause a silent parse failure.
  PY=python
else
  PY=""
fi

if [[ -n "$PY" ]]; then
  EXTRACTED=$(printf '%s' "$STDIN_JSON" | "$PY" -c "
import sys, json, hashlib, re
try:
    d = json.load(sys.stdin)
    sid = d.get('session_id', '') or ''
    tp = d.get('transcript_path', '') or ''
except Exception:
    sid = ''
    tp = ''

# session_id safety: ^[A-Za-z0-9_-]{1,64}$ else sha1 hex fallback.
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
else
  # Pure-bash extraction. Uses grep -oE first-match to get the session_id and
  # transcript_path values from the first occurrence in the JSON, avoiding the
  # user-controlled `prompt` field which follows them in CC's stdin shape.
  # Un-escapes JSON backslashes in transcript_path so Windows paths resolve.
  RAW_SID=$(printf '%s' "$STDIN_JSON" | grep -oE '"session_id":"[^"]*"' | head -n 1 | sed 's/^"session_id":"//;s/"$//')
  RAW_TP=$(printf '%s' "$STDIN_JSON" | grep -oE '"transcript_path":"[^"]*"' | head -n 1 | sed 's/^"transcript_path":"//;s/"$//;s|\\\\|\\|g')
  if [[ "$RAW_SID" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    SAFE_SID="$RAW_SID"
  elif [[ -n "$RAW_SID" ]]; then
    SAFE_SID=$(sha1_hex "$RAW_SID")
  else
    SAFE_SID=""
  fi
  TRANSCRIPT_PATH="$RAW_TP"
fi

if [[ -z "$SAFE_SID" ]]; then
  printf 'check-context-size: empty/unparseable session_id in %s stdin; skipping.\n' "${MODE:-UserPromptSubmit}" >&2
  printf 'stdin was: %s\n' "$STDIN_JSON" >&2
  exit 0
fi

FLAG="$CACHE_DIR/compact-warned-$SAFE_SID"
BASELINE_FILE="$CACHE_DIR/compact-baseline-$SAFE_SID"

# Read current baseline (bytes at last PostCompact). 0 = no compact yet this
# session, so the first reminder fires on absolute-threshold crossing.
BASELINE=0
if [[ -r "$BASELINE_FILE" ]]; then
  B_READ=$(cat "$BASELINE_FILE" 2>/dev/null | tr -d '[:space:]')
  if [[ "$B_READ" =~ ^[0-9]+$ ]]; then
    BASELINE=$B_READ
  fi
fi

# RESET (PostCompact): record current transcript size as new baseline, clear
# the warned flag so the NEXT (baseline + threshold) crossing can fire.
# Reminder cadence is now "per threshold bytes of NEW work since last compact",
# not "per threshold bytes total" — the transcript .jsonl is append-only on
# disk, so absolute thresholds would nag every turn after the first compact.
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

# Default (UserPromptSubmit): stat transcript, decide reminder based on delta
# since baseline.
if [[ -z "$TRANSCRIPT_PATH" || ! -r "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

BYTES=$(wc -c <"$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
if [[ -z "$BYTES" || ! "$BYTES" =~ ^[0-9]+$ ]]; then
  exit 0
fi

# Delta: bytes since last compact. If BYTES < BASELINE (file somehow shrank
# between hook calls, e.g. transcript rotation), fall back to delta=bytes.
if (( BYTES < BASELINE )); then
  DELTA=$BYTES
else
  DELTA=$(( BYTES - BASELINE ))
fi

if (( DELTA < THRESHOLD )); then
  # Below delta-threshold: clear any stale flag so the next legitimate
  # crossing gets a fresh reminder (covers the user-raised-threshold case
  # and the brief-post-compact-dip case where bytes hasn't exceeded baseline
  # by threshold yet).
  rm -f "$FLAG" 2>/dev/null || true
  exit 0
fi

if [[ -e "$FLAG" ]]; then
  exit 0
fi

: >"$FLAG"

# Plain-sentence reminder. Phase 0 spike's wrapper A/B was inconclusive (env var
# did not propagate to launcher); plain is the default chosen by Codex rounds 1-2
# simplicity argument. The reminder reports both total bytes and delta-since-
# last-compact so the user can judge how much "new work" triggered it.
if (( BASELINE > 0 )); then
  printf 'Session transcript is approximately %s bytes, delta %s bytes since last compact (above the configured threshold of %s bytes, ~450K tokens on Opus 4.7). Invoke the prep-compact skill to generate a tailored /compact <instructions> command for the user. If already done this turn, ignore this reminder.\n' "$BYTES" "$DELTA" "$THRESHOLD"
else
  printf 'Session transcript is approximately %s bytes, above the configured threshold of %s bytes (~450K tokens on Opus 4.7, per Phase 0 calibration). Invoke the prep-compact skill to generate a tailored /compact <instructions> command for the user. If already done this turn, ignore this reminder.\n' "$BYTES" "$THRESHOLD"
fi

exit 0
