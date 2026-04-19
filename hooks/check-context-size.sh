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

EXTRACTED=$(printf '%s' "$STDIN_JSON" | python -c "
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

if [[ -z "$SAFE_SID" ]]; then
  printf 'check-context-size: empty/unparseable session_id in %s stdin; skipping.\n' "${MODE:-UserPromptSubmit}" >&2
  printf 'stdin was: %s\n' "$STDIN_JSON" >&2
  exit 0
fi

FLAG="$CACHE_DIR/compact-warned-$SAFE_SID"

# RESET (PostCompact): scoped delete, done.
if [[ "$MODE" == "RESET" ]]; then
  rm -f "$FLAG" 2>/dev/null || true
  exit 0
fi

# Default (UserPromptSubmit): stat transcript, decide reminder.
if [[ -z "$TRANSCRIPT_PATH" || ! -r "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

BYTES=$(wc -c <"$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
if [[ -z "$BYTES" || ! "$BYTES" =~ ^[0-9]+$ ]]; then
  exit 0
fi

if (( BYTES < THRESHOLD )); then
  # Below threshold: clear any stale flag so the NEXT above-threshold crossing
  # gets a fresh reminder. This runs when the threshold is raised, not when
  # the transcript shrinks (the transcript is append-only on disk).
  rm -f "$FLAG" 2>/dev/null || true
  exit 0
fi

if [[ -e "$FLAG" ]]; then
  exit 0
fi

: >"$FLAG"

# Plain-sentence reminder. Phase 0 spike's wrapper A/B was inconclusive (env var
# did not propagate to launcher); plain is the default chosen by Codex rounds 1-2
# simplicity argument. Modify this printf if a future evaluation shows pseudo-XML
# wrapping reliably improves Claude invocation.
printf 'Session transcript is approximately %s bytes, above the configured threshold of %s bytes (~450K tokens on Opus 4.7, per Phase 0 calibration). Invoke the prep-compact skill to generate a tailored /compact <instructions> command for the user. If already done this turn, ignore this reminder.\n' "$BYTES" "$THRESHOLD"

exit 0
