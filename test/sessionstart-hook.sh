# SessionStart (compact) hook suite (inject-brief.sh).
# Sourced by run-tests.sh after common.sh.

[[ -n "${TEST_DIR:-}" ]] || { printf '%s: source this from run-tests.sh, do not run it directly\n' "${BASH_SOURCE[0]}" >&2; exit 1; }

SS_HOOK="$SCRIPT_DIR/../hooks/inject-brief.sh"
HOOKS_JSON="$SCRIPT_DIR/../hooks/hooks.json"
SKILL_MD="$SCRIPT_DIR/../skills/prep-compact/SKILL.md"

run_ss_hook() {
  local stdin=$1; shift
  printf '%s' "$stdin" | CLAUDE_CODE_SESSION_ID= HOME="$SANDBOX_HOME" bash "$SS_HOOK" "$@" 2>/dev/null
}

ss_payload() {  # $1=sid
  printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"compact"}' "$1"
}

BRIEF_BODY=$'goal: finish the thing\nnext: run bash test/run-tests.sh'

# --- T-S1: brief present -> injected verbatim, then deleted so it is used once
cleanup
printf '%s\n' "$BRIEF_BODY" > "$CACHE/brief-ss1.md"
OUT=$(run_ss_hook "$(ss_payload ss1)")
assert_true "T-S1: brief body injected verbatim" '[[ "$OUT" == *"$BRIEF_BODY"* ]]'
assert_true "T-S1: injection is labelled as the prep-compact brief" '[[ "$OUT" == "prep-compact brief"* ]]'
assert_true "T-S1: brief deleted after injection" '[[ ! -e "$CACHE/brief-ss1.md" ]]'

# --- T-S3: no brief, handoff present -> one-line pointer naming the handoff
cleanup
echo '{"version":"3.0"}' > "$CACHE/handoff-ss3.json"
OUT=$(run_ss_hook "$(ss_payload ss3)")
EXPECTED_S3="prep-compact: no brief was prepared before this compaction. The warm handoff for this session (files touched, recent requests, todos, subagent launches) is at $CACHE/handoff-ss3.json."
assert_eq "T-S3: pointer names the handoff verbatim" "$EXPECTED_S3" "$OUT"

# --- T-S4: neither brief nor handoff -> silent
cleanup
OUT=$(run_ss_hook "$(ss_payload ss4)")
assert_eq "T-S4: nothing prepared -> silent" "" "$OUT"

# --- T-S5: empty brief file -> treated as absent (pointer), left alone
cleanup
: > "$CACHE/brief-ss5.md"
echo '{"version":"3.0"}' > "$CACHE/handoff-ss5.json"
OUT=$(run_ss_hook "$(ss_payload ss5)")
assert_true "T-S5: empty brief -> pointer, not an empty injection" '[[ "$OUT" == "prep-compact: no brief"* ]]'

# --- T-S6: sid failing the regex -> silent even though its brief file exists
cleanup
printf '%s\n' "$BRIEF_BODY" > "$CACHE/brief-ss6.x.md"
OUT=$(run_ss_hook "$(ss_payload ss6.x)")
assert_eq "T-S6: invalid sid -> silent" "" "$OUT"
assert_true "T-S6: invalid sid's brief left alone" '[[ -s "$CACHE/brief-ss6.x.md" ]]'

# --- T-S7: env sid first, even when stdin names another session
cleanup
printf '%s\n' "$BRIEF_BODY" > "$CACHE/brief-envS7.md"
printf '%s\n' "other" > "$CACHE/brief-stdinS7.md"
OUT=$(printf '%s' "$(ss_payload stdinS7)" | CLAUDE_CODE_SESSION_ID="envS7" HOME="$SANDBOX_HOME" bash "$SS_HOOK" 2>/dev/null)
assert_true "T-S7: env sid's brief injected" '[[ "$OUT" == *"$BRIEF_BODY"* ]]'
assert_true "T-S7: stdin sid's brief untouched" '[[ -s "$CACHE/brief-stdinS7.md" ]]'

# --- T-S8: CLAUDE_PLUGIN_DATA override -> brief read and deleted there
cleanup
ALT="$TEST_DIR/alt-cache-ss"
rm -rf "$ALT"; mkdir -p "$ALT"
printf '%s\n' "$BRIEF_BODY" > "$ALT/brief-ss8.md"
OUT=$(printf '%s' "$(ss_payload ss8)" | CLAUDE_PLUGIN_DATA="$ALT" CLAUDE_CODE_SESSION_ID= HOME="$SANDBOX_HOME" bash "$SS_HOOK" 2>/dev/null)
assert_true "T-S8: override dir brief injected" '[[ "$OUT" == *"$BRIEF_BODY"* ]]'
assert_true "T-S8: override dir brief deleted" '[[ ! -e "$ALT/brief-ss8.md" ]]'

# --- T-S9: registered for SessionStart with the compact matcher only
REG=$("$PY" -c "
import json, sys
d = json.load(sys.stdin)
ss = d.get('hooks', {}).get('SessionStart', [])
print(';'.join('%s=%s' % (e.get('matcher', ''), h.get('command', '')) for e in ss for h in e.get('hooks', [])))
" < "$HOOKS_JSON")
assert_true "T-S9: SessionStart registered with matcher compact" '[[ "$REG" == "compact="*"inject-brief.sh"* && "$REG" != *";"* ]]'

# --- T-S10: pure bash
assert_true "T-S10: no python invocation in SessionStart hook" '! grep -qE "\bpython3?\b" "$SS_HOOK"'

# --- T-S11: the skill writes the file name the hook reads
assert_true "T-S11: skill and hook agree on brief-<sid>.md" 'grep -qF "brief-<sid>.md" "$SKILL_MD" && grep -qF "brief-\$SID.md" "$SS_HOOK"'
