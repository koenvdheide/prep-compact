# UserPromptSubmit hook suite (check-context-size.sh).
# Sourced by run-tests.sh after common.sh.

# ============================================================
# v3.1: UserPromptSubmit hook is a pure-bash context-warn reader.
# Token detection now lives in the Stop hook (T-60.., T-70..); these tests
# pre-write the flag and assert reminder / suppression / re-arm. No transcript.
# ============================================================

write_warn() {  # $1=sid  $2=tokens  $3=threshold
  printf '%s %s\n' "$2" "$3" > "$CACHE/context-warn-$1"
}

# --- T-1: warn flag present -> reminder fires, names tokens, sets compact-warned
cleanup
write_warn s1 250000 200000
OUT=$(run_hook '{"session_id":"s1"}')
assert_true "T-1: flag present -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-1: message names tokens not bytes" '[[ "$OUT" == *"250000 tokens"* ]] && [[ "$OUT" != *"bytes"* ]]'
assert_true "T-1: compact-warned flag written" '[[ -e "$CACHE/compact-warned-s1" ]]'
assert_true "T-1: reminder NOT the v2.x 'Invoke the prep-compact skill' directive" '[[ "$OUT" != *"Invoke the prep-compact skill"* ]]'

# --- T-2: warn flag absent -> silent, stale compact-warned cleared (re-arm)
cleanup
: >"$CACHE/compact-warned-s2"
OUT=$(run_hook '{"session_id":"s2"}')
assert_eq "T-2: no warn flag -> silent" "" "$OUT"
assert_true "T-2: stale compact-warned cleared" '[[ ! -e "$CACHE/compact-warned-s2" ]]'

# --- T-86: Stop-state-absent -> UPS silent (the accepted v3.1 coupling regression)
cleanup
# Stop never ran: no context-warn flag at all. UPS stays silent and creates no
# compact-warned. The warning depends on Stop having written the flag.
OUT=$(run_hook '{"session_id":"s86"}')
assert_eq "T-86: Stop-state-absent -> UPS silent" "" "$OUT"
assert_true "T-86: Stop-state-absent -> no compact-warned created" '[[ ! -e "$CACHE/compact-warned-s86" ]]'

# --- T-80: warn flag present + already warned -> suppressed (silent)
cleanup
write_warn s80 300000 200000
: >"$CACHE/compact-warned-s80"
OUT=$(run_hook '{"session_id":"s80"}')
assert_eq "T-80: already warned -> silent" "" "$OUT"

# --- T-81: malformed flag (empty) -> treated as absent, re-arm, silent
cleanup
: >"$CACHE/context-warn-s81"
: >"$CACHE/compact-warned-s81"
OUT=$(run_hook '{"session_id":"s81"}')
assert_eq "T-81: empty flag -> silent" "" "$OUT"
assert_true "T-81: empty flag treated as absent -> compact-warned cleared" '[[ ! -e "$CACHE/compact-warned-s81" ]]'

# --- T-82: malformed flag (non-int field) -> treated as absent, silent
cleanup
printf 'garbage here\n' > "$CACHE/context-warn-s82"
OUT=$(run_hook '{"session_id":"s82"}')
assert_eq "T-82: non-int flag -> silent" "" "$OUT"

# --- T-83: malformed flag (single int, missing threshold) -> treated as absent, silent
cleanup
printf '300000\n' > "$CACHE/context-warn-s83"
OUT=$(run_hook '{"session_id":"s83"}')
assert_eq "T-83: partial flag -> silent" "" "$OUT"

# --- T-89: flag with trailing junk (not exactly two ints) -> malformed, re-arm
cleanup
printf '300000 200000 junk\n' > "$CACHE/context-warn-s89"
: >"$CACHE/compact-warned-s89"
OUT=$(run_hook '{"session_id":"s89"}')
assert_eq "T-89: three-field flag -> silent (malformed)" "" "$OUT"
assert_true "T-89: three-field flag -> compact-warned cleared (re-arm)" '[[ ! -e "$CACHE/compact-warned-s89" ]]'

# --- T-8: empty stdin + no env sid -> silent (fail-open)
cleanup
OUT=$(run_hook '' 2>/dev/null)
assert_eq "T-8: empty stdin -> silent" "" "$OUT"

# --- T-9: malformed stdin JSON + no env sid -> silent
cleanup
OUT=$(run_hook '{not valid json' 2>/dev/null)
assert_eq "T-9: malformed stdin -> silent" "" "$OUT"

# --- T-10: path traversal sid -> invalid regex -> skip, no escaped flag
cleanup
OUT=$(run_hook '{"session_id":"../../../evil"}' 2>/dev/null)
ESCAPED=$(find "$SANDBOX_HOME/.claude" -path "$CACHE" -prune -o -name 'compact-warned-*' -print 2>/dev/null | head -n 1)
assert_eq "T-10: path traversal -> no escaped flag" "" "$ESCAPED"

# --- T-11: oversized sid -> skip (v3.1 drops the SHA-1 fallback)
cleanup
LONG=$(printf 'a%.0s' {1..200})
OUT=$(run_hook "{\"session_id\":\"$LONG\"}" 2>/dev/null)
assert_eq "T-11: oversized sid -> silent" "" "$OUT"
ANY=$(find "$CACHE" -name 'compact-warned-*' 2>/dev/null | head -n 1)
assert_eq "T-11: oversized sid -> no compact-warned written" "" "$ANY"

# --- T-12: empty sid (env unset, stdin empty) -> silent, no flag
cleanup
OUT=$(run_hook '{"session_id":""}' 2>/dev/null)
assert_eq "T-12: empty sid -> silent" "" "$OUT"
ANY=$(find "$CACHE" -name 'compact-warned-*' 2>/dev/null | head -n 1)
assert_eq "T-12: empty sid -> no flag created" "" "$ANY"

# --- T-13: CLAUDE_PLUGIN_DATA override -> reads flag there, writes compact-warned there
cleanup
OVERRIDE_DIR="$TEST_DIR/alt-cache"
rm -rf "$OVERRIDE_DIR"; mkdir -p "$OVERRIDE_DIR"
printf '300000 1\n' > "$OVERRIDE_DIR/context-warn-s13"
OUT=$(CLAUDE_PLUGIN_DATA="$OVERRIDE_DIR" run_hook '{"session_id":"s13"}' 2>/dev/null)
assert_true "T-13: override dir -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-13: override dir -> compact-warned written there" '[[ -e "$OVERRIDE_DIR/compact-warned-s13" ]]'

# --- T-14: mkdir failure on cache dir -> stderr warn, hook disabled this turn
cleanup
OBSTRUCTION="$TEST_DIR/obstructed-ups"
printf 'not a dir\n' >"$OBSTRUCTION"
ERR=$(CLAUDE_PLUGIN_DATA="$OBSTRUCTION/nope" run_hook_err '{"session_id":"s14"}' 2>&1 >/dev/null)
assert_true "T-14: mkdir failure -> stderr warn" '[[ "$ERR" == *"cannot create"* ]]'

# --- T-16: re-arm via flag transitions (flag present -> gone -> compact-warned cleared)
cleanup
write_warn s16 250000 200000
OUT=$(run_hook '{"session_id":"s16"}')
assert_true "T-16: flag present -> compact-warned set" '[[ -e "$CACHE/compact-warned-s16" ]]'
rm -f "$CACHE/context-warn-s16"
OUT=$(run_hook '{"session_id":"s16"}')
assert_true "T-16: flag gone -> compact-warned cleared" '[[ ! -e "$CACHE/compact-warned-s16" ]]'

# --- T-19: real UserPromptSubmit payload shape -> stdin session_id parsed, reminder fires
cleanup
if [[ -s "$FIX/ups-real.json" ]]; then
  REAL_SID=$("$PY" -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" <"$FIX/ups-real.json")
  if [[ "$REAL_SID" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    write_warn "$REAL_SID" 300000 1
    OUT=$(run_hook "$(cat "$FIX/ups-real.json")")
    assert_true "T-19: real UPS payload -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
  else
    assert_true "T-19: real UPS payload sid regex-valid" 'false'
  fi
else
  printf 'FAIL: ups-real.json missing (T-19 cannot run)\n' >&2
  FAIL=$((FAIL+1))
fi

# --- T-20: end-to-end re-arm cycle (flag present -> gone -> present again)
cleanup
write_warn s20 250000 200000
OUT=$(run_hook '{"session_id":"s20"}')
assert_true "T-20: step 1 flag present -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-20: step 1 compact-warned set" '[[ -e "$CACHE/compact-warned-s20" ]]'
rm -f "$CACHE/context-warn-s20"
OUT=$(run_hook '{"session_id":"s20"}')
assert_eq "T-20: step 2 flag gone -> silent" "" "$OUT"
assert_true "T-20: step 2 compact-warned cleared" '[[ ! -e "$CACHE/compact-warned-s20" ]]'
write_warn s20 260000 200000
OUT=$(run_hook '{"session_id":"s20"}')
assert_true "T-20: step 3 re-arm fires reminder" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-20: step 3 compact-warned re-set" '[[ -e "$CACHE/compact-warned-s20" ]]'

# --- T-84: safe_sid env-first (env set -> used even when stdin differs)
cleanup
write_warn envU1 300000 1
printf '%s' '{"session_id":"stdinU1"}' | CLAUDE_CODE_SESSION_ID="envU1" HOME="$SANDBOX_HOME" bash "$HOOK" >/dev/null 2>&1
assert_true "T-84: env sid used -> compact-warned-envU1 set" '[[ -e "$CACHE/compact-warned-envU1" ]]'
assert_true "T-84: stdin sid NOT used" '[[ ! -e "$CACHE/compact-warned-stdinU1" ]]'

# --- T-85: env-invalid -> stdin sid used
cleanup
write_warn stdinU2 300000 1
printf '%s' '{"session_id":"stdinU2"}' | CLAUDE_CODE_SESSION_ID="bad/env" HOME="$SANDBOX_HOME" bash "$HOOK" >/dev/null 2>&1
assert_true "T-85: env invalid -> stdin sid used" '[[ -e "$CACHE/compact-warned-stdinU2" ]]'

# --- T-39: reminder when handoff exists -> verbatim full string equality
cleanup
write_warn s39 250000 1
HANDOFF_PATH_T39="$CACHE/handoff-s39.json"
echo '{"version":"3.0"}' > "$HANDOFF_PATH_T39"
OUT=$(run_hook '{"session_id":"s39"}')
EXPECTED_T39="Session context is approximately 250000 tokens (above configured threshold of 1 tokens). The on-disk handoff at $HANDOFF_PATH_T39 is current. When the user is ready to compact, run /prep-compact:prep-compact to add the analytical layer (decisions, constraints, blockers, verb-anchored next-step) and emit a tailored /compact <instructions> block. If you are at the very end of a todo list, you may finish the remaining items first."
assert_eq "T-39: handoff-present reminder verbatim" "$EXPECTED_T39" "$OUT"

# --- T-40: reminder when handoff missing -> verbatim no-handoff variant
cleanup
write_warn s40 250000 1
OUT=$(run_hook '{"session_id":"s40"}')
EXPECTED_T40="Session context is approximately 250000 tokens (above configured threshold of 1 tokens). Run /prep-compact:prep-compact to survey current state and emit a tailored /compact <instructions> block. If you are at the very end of a todo list, you may finish the remaining items first."
assert_eq "T-40: handoff-missing reminder verbatim" "$EXPECTED_T40" "$OUT"

# --- T-NP: UPS hook has no interpreter spawn and never reads the transcript
assert_true "T-NP: no python invocation in UPS hook" '! grep -qE "\bpython3?\b" "$HOOK"'
assert_true "T-NP: no transcript_path read in UPS hook" '! grep -q "transcript_path" "$HOOK"'

# --- T-41: SKILL.md documents session-id binding via the helper (not mtime)
SKILL="$SCRIPT_DIR/../skills/prep-compact/SKILL.md"
assert_true "T-41: SKILL.md documents resolve-handoff.sh binding" '[[ "$(cat "$SKILL")" == *"resolve-handoff.sh"* ]]'
assert_true "T-41: SKILL.md no longer documents mtime discovery"  '[[ "$(cat "$SKILL")" != *"mtime"* ]]'

# --- T-51: single-line /compact enforcement
assert_true "T-51: multi-line escape hatch removed"   '[[ "$(cat "$SKILL")" != *"Multi-line form is permitted"* ]]'
assert_true "T-51: verify gate present (single line)" '[[ "$(cat "$SKILL")" == *"single physical line"* ]]'
assert_true "T-51: verify gate present (goal literal)" '[[ "$(cat "$SKILL")" == *"begins with the literal characters"* ]]'
