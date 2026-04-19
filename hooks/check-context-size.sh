#!/usr/bin/env bash
# UserPromptSubmit + PostCompact hook.
# Two-stage reminder cadence:
#   - soft  (CLAUDE_CONTEXT_WARN_BYTES, default 4000000) -> info-only reminder.
#   - critical (CLAUDE_CONTEXT_CRITICAL_BYTES, default 6000000) -> explicit
#     auto-invoke reminder. Auto-compact zone.
# Single state file ($CACHE_DIR/compact-level-<sid>) stores last-emitted level
# (soft|critical|absent=none). Emit only when upgrading (none->soft, soft->critical,
# none->critical). Downgrades (e.g. after a threshold raise) update the state
# file silently so the next upgrade fires a fresh reminder.
# RESET arg (PostCompact): record current transcript bytes as baseline, clear
# level state so next delta-threshold crossing re-arms cleanly.
# Always exits 0 so a hook failure never blocks the user's prompt.

set -uo pipefail

MODE="${1:-}"
CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/cache}"
SOFT_THRESHOLD="${CLAUDE_CONTEXT_WARN_BYTES:-4000000}"
HARD_THRESHOLD="${CLAUDE_CONTEXT_CRITICAL_BYTES:-6000000}"
HARD_DISABLED=0

# Validate thresholds: non-negative integer, no leading zeros. Bash arithmetic
# under `set -u` on a non-numeric env var exits non-zero; `08` / `09` hit
# "value too great for base" (octal interpretation). Either breaks fail-open.
if ! [[ "$SOFT_THRESHOLD" =~ ^(0|[1-9][0-9]*)$ ]]; then
  printf 'check-context-size: ignoring invalid CLAUDE_CONTEXT_WARN_BYTES=%q (expected non-negative integer without leading zeros); using 4000000.\n' "$SOFT_THRESHOLD" >&2
  SOFT_THRESHOLD=4000000
fi
if ! [[ "$HARD_THRESHOLD" =~ ^(0|[1-9][0-9]*)$ ]]; then
  printf 'check-context-size: ignoring invalid CLAUDE_CONTEXT_CRITICAL_BYTES=%q (expected non-negative integer without leading zeros); using 6000000.\n' "$HARD_THRESHOLD" >&2
  HARD_THRESHOLD=6000000
fi

# Invalid config: CRITICAL must exceed WARN. Disable critical level for this
# turn rather than swap silently -- swapping masks the config error and
# produces confusing state transitions.
if (( HARD_THRESHOLD <= SOFT_THRESHOLD )); then
  printf 'check-context-size: CLAUDE_CONTEXT_CRITICAL_BYTES (%s) must exceed CLAUDE_CONTEXT_WARN_BYTES (%s); disabling critical level for this turn.\n' "$HARD_THRESHOLD" "$SOFT_THRESHOLD" >&2
  HARD_DISABLED=1
fi

if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
  printf 'check-context-size: cannot create %s; hook disabled this turn.\n' "$CACHE_DIR" >&2
  exit 0
fi

STDIN_JSON=$(cat 2>/dev/null)

sha1_hex() {
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha1sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
  else
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_' | head -c 64
  fi
}

# Python-preferred (json.load handles arbitrary field orderings, embedded
# quotes). Fallback uses grep+sed which assumes CC's observed minified JSON
# shape with session_id/transcript_path before the user-controlled prompt.
if [[ -n "${PREP_COMPACT_DISABLE_PYTHON-}" ]]; then
  PY=""
elif command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
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
  # Terse diagnostic; never log raw STDIN_JSON (contains user prompt text).
  printf 'check-context-size: empty/unparseable session_id in %s stdin; skipping (stdin length=%d).\n' "${MODE:-UserPromptSubmit}" "${#STDIN_JSON}" >&2
  exit 0
fi

LEVEL_FILE="$CACHE_DIR/compact-level-$SAFE_SID"
BASELINE_FILE="$CACHE_DIR/compact-baseline-$SAFE_SID"

BASELINE=0
if [[ -r "$BASELINE_FILE" ]]; then
  B_READ=$(cat "$BASELINE_FILE" 2>/dev/null | tr -d '[:space:]')
  if [[ "$B_READ" =~ ^[0-9]+$ ]]; then
    BASELINE=$B_READ
  fi
fi

# RESET (PostCompact): refresh baseline, clear level state.
if [[ "$MODE" == "RESET" ]]; then
  if [[ -n "$TRANSCRIPT_PATH" && -r "$TRANSCRIPT_PATH" ]]; then
    CURRENT_BYTES=$(wc -c <"$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
    if [[ "$CURRENT_BYTES" =~ ^[0-9]+$ ]]; then
      # Symlink defense: refuse to write through a pre-existing symlink
      # (attacker could point BASELINE_FILE at arbitrary user-writable file).
      if [[ -L "$BASELINE_FILE" ]]; then
        printf 'check-context-size: refusing to write through symlink %s\n' "$BASELINE_FILE" >&2
      else
        printf '%s\n' "$CURRENT_BYTES" >"$BASELINE_FILE" 2>/dev/null || true
      fi
    fi
  fi
  # rm -f removes the link itself (does not follow); safe against level-file symlinks.
  rm -f "$LEVEL_FILE" 2>/dev/null || true
  exit 0
fi

# UserPromptSubmit: stat transcript, compute delta, compare levels.
if [[ -z "$TRANSCRIPT_PATH" || ! -r "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

BYTES=$(wc -c <"$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
if [[ -z "$BYTES" || ! "$BYTES" =~ ^[0-9]+$ ]]; then
  exit 0
fi

if (( BYTES < BASELINE )); then
  # Transcript rotated / rewritten; treat delta as absolute bytes.
  DELTA=$BYTES
else
  DELTA=$(( BYTES - BASELINE ))
fi

# Target level from delta. Critical takes precedence over soft when both are crossed.
if (( HARD_DISABLED == 0 )) && (( DELTA >= HARD_THRESHOLD )); then
  TARGET="critical"
elif (( DELTA >= SOFT_THRESHOLD )); then
  TARGET="soft"
else
  TARGET="none"
fi

# Read current level. Symlink on LEVEL_FILE => remove, treat as none (prevents
# attacker-controlled state from gating emissions).
CURRENT="none"
if [[ -L "$LEVEL_FILE" ]]; then
  printf 'check-context-size: refusing to read through symlink %s; removing\n' "$LEVEL_FILE" >&2
  rm -f "$LEVEL_FILE" 2>/dev/null || true
elif [[ -r "$LEVEL_FILE" ]]; then
  L_READ=$(cat "$LEVEL_FILE" 2>/dev/null | tr -d '[:space:]')
  if [[ "$L_READ" == "soft" || "$L_READ" == "critical" ]]; then
    CURRENT="$L_READ"
  fi
fi

level_rank() {
  case "$1" in
    none) printf '0' ;;
    soft) printf '1' ;;
    critical) printf '2' ;;
    *) printf '0' ;;
  esac
}
TARGET_RANK=$(level_rank "$TARGET")
CURRENT_RANK=$(level_rank "$CURRENT")

# Sync state file to target (tracks both upgrades and downgrades so a raised
# CRITICAL env var correctly re-arms a later crossing).
if [[ "$TARGET" == "none" ]]; then
  rm -f "$LEVEL_FILE" 2>/dev/null || true
else
  # Defensive re-check: reject a symlink planted between read and write. Skip
  # the persist, but fall through to the emit — suppressing the reminder would
  # hand the attacker "silence the critical warning" as a payoff. Next turn
  # re-evaluates from `none` (file absent) and re-emits the same level cleanly.
  if [[ -L "$LEVEL_FILE" ]]; then
    printf 'check-context-size: refusing to write through symlink %s\n' "$LEVEL_FILE" >&2
    rm -f "$LEVEL_FILE" 2>/dev/null || true
  else
    printf '%s\n' "$TARGET" >"$LEVEL_FILE" 2>/dev/null || true
  fi
fi

# Emit only on upgrade (none->soft, none->critical, soft->critical). Downgrades
# and same-level repeats are silent.
if (( TARGET_RANK <= CURRENT_RANK )); then
  exit 0
fi

# Build the optional "delta ... since last compact" clause. Pre-first-compact
# (BASELINE=0) we use absolute-size framing; after the first compact, we report
# delta so the user can judge how much new work triggered the reminder.
if (( BASELINE > 0 )); then
  DELTA_CLAUSE=", delta $DELTA bytes since last compact"
else
  DELTA_CLAUSE=""
fi

# Canonical marker prefix gives SKILL a reliable anchor (soft vs critical)
# instead of fuzzy prose classification.
case "$TARGET" in
  soft)
    printf '[prep-compact level=soft]\nSession transcript is approximately %s bytes%s (above the configured warn threshold of %s bytes, ~450K tokens on Opus 4.7). Informational only. Do not call any skill or tool from this reminder. Context window is filling; model performance may start to degrade. When ready to compact, run /prep-compact:prep-compact to generate tailored /compact instructions. Do not treat this reminder as the user'"'"'s request.\n' "$BYTES" "$DELTA_CLAUSE" "$SOFT_THRESHOLD"
    ;;
  critical)
    printf '[prep-compact level=critical]\nSession transcript is approximately %s bytes%s (above the critical threshold of %s bytes, ~670K tokens on Opus 4.7). Context is critically high; compact soon to avoid likely degradation. Invoke the prep-compact skill to generate tailored /compact instructions.\n' "$BYTES" "$DELTA_CLAUSE" "$HARD_THRESHOLD"
    ;;
esac

exit 0
