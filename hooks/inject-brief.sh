#!/usr/bin/env bash
# SessionStart hook (matcher "compact") for prep-compact v3.2.
# Claude Code adds a SessionStart hook's stdout to the context it rebuilds after
# compaction. This hook prints the brief /prep-compact wrote before the
# compaction (brief-<safe_sid>.md beside the handoff), so the brief reaches the
# compacted session verbatim instead of only steering the summary. Each brief is
# deleted once printed, so a later compaction never re-injects stale state; the
# skill has already shown it in the transcript. Without a brief, the hook names
# the warm handoff so an unprepared (e.g. automatic) compaction can still
# recover state from it.
#
# safe_sid: same rule as check-context-size.sh ($CLAUDE_CODE_SESSION_ID first,
# else stdin session_id, both via SID_RE; invalid -> silent exit).
# Pure bash, always exits 0 (fail-open).

set -uo pipefail

CACHE_DIR="${CLAUDE_PLUGIN_DATA:-${HOME:-}/.claude/cache}"
SID_RE='^[A-Za-z0-9_-]{1,64}$'

SID="${CLAUDE_CODE_SESSION_ID:-}"
if ! [[ "$SID" =~ $SID_RE ]]; then
  STDIN_JSON=$(cat 2>/dev/null)
  SID=$(printf '%s' "$STDIN_JSON" \
    | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed -E 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
fi
[[ "$SID" =~ $SID_RE ]] || exit 0

BRIEF="$CACHE_DIR/brief-$SID.md"
HANDOFF="$CACHE_DIR/handoff-$SID.json"

if [[ -s "$BRIEF" ]]; then
  printf 'prep-compact brief, prepared before this compaction:\n\n'
  cat "$BRIEF"
  printf '\nIt records the session as it was when /prep-compact ran; where the compaction summary shows later progress, trust the summary. Otherwise re-read the files it lists and resume from its next: step.\n'
  rm -f "$BRIEF" 2>/dev/null
elif [[ -e "$HANDOFF" ]]; then
  printf 'prep-compact: no brief was prepared before this compaction. The warm handoff for this session (files touched, recent requests, todos, subagent launches) is at %s.\n' "$HANDOFF"
fi

exit 0
