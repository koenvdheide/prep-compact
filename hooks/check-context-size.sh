#!/usr/bin/env bash
# UserPromptSubmit hook for prep-compact v3.1.
# Pure-bash reader of the context-warn flag written by the async Stop hook
# (update-handoff.sh). Token detection now lives in the Stop hook, which writes
# $CACHE_DIR/context-warn-<safe_sid> (content: "<tokens> <threshold>") when the
# newest main-chain assistant usage is at/above the threshold, and removes it
# below. This hook reads that flag and, on a fresh crossing, emits the existing
# informational reminder (handoff-present / handoff-missing variants), then sets
# a suppression flag so it warns once per crossing. No interpreter process, no
# transcript scan on the per-message path. Always exits 0 (fail-open).
#
# safe_sid (must match update-handoff.sh exactly): $CLAUDE_CODE_SESSION_ID first
# (verified present in the hook env, though undocumented), else session_id read
# from stdin JSON, both via the same regex. Invalid/absent -> silent exit 0. No
# SHA-1 fallback: real session ids are UUIDs, always regex-valid.
#
# Accepted tradeoff (v3.1): the warning now depends on the Stop hook having
# written the flag. If Stop is killed/disabled/errored, an above-threshold
# session gets no nudge until a later successful Stop. This extends the existing
# handoff-depends-on-Stop coupling to the warning; the user can also run
# /prep-compact:prep-compact directly.

set -uo pipefail

CACHE_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/cache}"

if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
  printf 'check-context-size: cannot create %s; hook disabled this turn.\n' "$CACHE_DIR" >&2
  exit 0
fi

SID_RE='^[A-Za-z0-9_-]{1,64}$'

# safe_sid: env-first, then stdin session_id, both via SID_RE.
SID="${CLAUDE_CODE_SESSION_ID:-}"
if ! [[ "$SID" =~ $SID_RE ]]; then
  STDIN_JSON=$(cat 2>/dev/null)
  SID=$(printf '%s' "$STDIN_JSON" \
    | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed -E 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
fi
[[ "$SID" =~ $SID_RE ]] || exit 0

WARN="$CACHE_DIR/context-warn-$SID"
FLAG="$CACHE_DIR/compact-warned-$SID"

# Flag present AND parses as two integers -> a real crossing. A malformed or
# partial flag (crash mid-write, etc.) is treated as absent so it never sticks
# the suppression on. Absent/malformed -> clear the suppression flag (re-arm).
# IFS includes \r so a CRLF-terminated flag still parses (defensive: the writer
# emits LF, but a text-mode write elsewhere must not silently break the parse).
if [[ -e "$WARN" ]] && IFS=$' \t\r' read -r TOKENS THRESHOLD _REST < "$WARN" 2>/dev/null \
     && [[ "$TOKENS" =~ ^[0-9]+$ && "$THRESHOLD" =~ ^[0-9]+$ ]]; then
  # Already warned this crossing -> suppress.
  [[ -e "$FLAG" ]] && exit 0
  : >"$FLAG"
  HANDOFF_PATH="$CACHE_DIR/handoff-$SID.json"
  if [[ -e "$HANDOFF_PATH" ]]; then
    printf 'Session context is approximately %s tokens (above configured threshold of %s tokens). The on-disk handoff at %s is current. When the user is ready to compact, run /prep-compact:prep-compact to add the analytical layer (decisions, constraints, blockers, verb-anchored next-step) and emit a tailored /compact <instructions> block. If you are at the very end of a todo list, you may finish the remaining items first.\n' "$TOKENS" "$THRESHOLD" "$HANDOFF_PATH"
  else
    printf 'Session context is approximately %s tokens (above configured threshold of %s tokens). Run /prep-compact:prep-compact to survey current state and emit a tailored /compact <instructions> block. If you are at the very end of a todo list, you may finish the remaining items first.\n' "$TOKENS" "$THRESHOLD"
  fi
else
  rm -f "$FLAG" 2>/dev/null || true
fi

exit 0
