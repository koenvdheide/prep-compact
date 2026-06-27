#!/usr/bin/env bash
# Test harness for prep-compact v2.0.0 check-context-size.sh (token-only).
# Explicit PASS count: false-green blocked by final EXPECTED_PASS guard.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/check-context-size.sh"
TEST_DIR="$(mktemp -d 2>/dev/null || printf '/tmp/prep-compact-test-%s' "$$")"
mkdir -p "$TEST_DIR/fixtures"
# Copy static fixtures into a sandboxed working area
for fx in transcript-usage.jsonl transcript-malformed-tail.jsonl ups-real.json; do
  if [[ -f "$SCRIPT_DIR/fixtures/$fx" ]]; then
    cp "$SCRIPT_DIR/fixtures/$fx" "$TEST_DIR/fixtures/$fx"
  fi
done
# v3 fixtures
for fx in stop-real.json transcript-handoff-multi-turn.jsonl transcript-handoff-no-user-text.jsonl transcript-handoff-tool-blob.jsonl transcript-handoff-oversized-line.jsonl handoff-prior.json; do
  if [[ -f "$SCRIPT_DIR/fixtures/$fx" ]]; then
    cp "$SCRIPT_DIR/fixtures/$fx" "$TEST_DIR/fixtures/$fx"
  fi
done
FIX="$TEST_DIR/fixtures"

# Sandboxed HOME so the hook's ~/.claude/cache expansion lands INSIDE the
# harness, not in the real live-sessions cache.
SANDBOX_HOME="$TEST_DIR/sandbox-home"
CACHE="$SANDBOX_HOME/.claude/cache"
mkdir -p "$CACHE"

FAIL=0
PASS=0

# Python resolution: mirror the hook. Tests invoke python for fixture
# generation and SHA-1 hashing.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
  PY=python
else
  printf 'run-tests: Python 3 not found on PATH (tried python3 and python).\n' >&2
  exit 1
fi

# --- T-0: real-fixture gate. Codex r4 mandate.
# Stop-hook tests require a captured Stop event payload to ensure schema parity.
# - Missing fixture: skip Stop-hook tests with explicit message (local dev only).
# - Malformed fixture (parse fail OR missing required keys): hard-fail.
# - $CI set: any skip is treated as a failure.
# NOTE: stop-real.json shipped is synthetic (matches Claude Code hook schema).
# Replace with a real captured payload before claiming Stop-hook coverage in CI.
STOP_FIXTURE_OK=0
STOP_FIXTURE_REASON=""
if [[ -f "$FIX/stop-real.json" ]]; then
  # Pipe via stdin (not path arg) so MSYS paths don't reach Windows Python.
  if "$PY" -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print(f'parse-fail: {e}', file=sys.stderr); sys.exit(2)
required = {'session_id','transcript_path','cwd','permission_mode','hook_event_name'}
missing = required - set(d.keys())
if missing:
    print(f'missing-keys: {sorted(missing)}', file=sys.stderr); sys.exit(2)
if d.get('hook_event_name') != 'Stop':
    print(f'wrong-event: {d.get(\"hook_event_name\")!r}', file=sys.stderr); sys.exit(2)
" <"$FIX/stop-real.json" 2>/dev/null; then
    STOP_FIXTURE_OK=1
  else
    printf 'FAIL: T-0 stop-real.json present but malformed\n' >&2
    exit 2
  fi
else
  STOP_FIXTURE_REASON="missing test/fixtures/stop-real.json — capture from a live session before claiming Stop-hook coverage"
  if [[ -n "${CI:-}" ]]; then
    printf 'FAIL: T-0 in CI: %s\n' "$STOP_FIXTURE_REASON" >&2
    exit 2
  fi
  printf 'SKIP: T-0 gate: %s\n' "$STOP_FIXTURE_REASON" >&2
fi

# EXPECTED_PASS is the count of assertions expected to PASS for the harness as
# it currently stands. SKIPPED tracks Stop-dep assertions skipped due to missing
# fixture. False-green guard at end requires PASS + SKIPPED == EXPECTED_PASS.
# Per-task targets (advisory; Task 11 recounts authoritatively):
#   After T1: EXPECTED_PASS=45, SKIPPED=0    (this task — only adds the gate)
#   After T2: EXPECTED_PASS=52, SKIPPED=7    (when fixture missing)
#   After T3: EXPECTED_PASS=72, SKIPPED=27
#   After T4: EXPECTED_PASS=84, SKIPPED=39
#   After T6: EXPECTED_PASS=87, SKIPPED=39   (T6 tests not Stop-dep)
#   After T7: EXPECTED_PASS=88, SKIPPED=39   (T7 test not Stop-dep)
#   PR-comment fix: +3 Stop-dep (T-32cap +1 short-still-captured, T-32prior +2)
EXPECTED_PASS=131
SKIPPED=0

run_hook() {
  local stdin=$1; shift
  printf '%s' "$stdin" | HOME="$SANDBOX_HOME" bash "$HOOK" "$@" 2>/dev/null
}

# Variant that preserves stderr so tests can capture warn messages. T-14 and
# T-15 need this because run_hook above silences stderr by design to keep
# expected-silent tests clean.
run_hook_err() {
  local stdin=$1; shift
  printf '%s' "$stdin" | HOME="$SANDBOX_HOME" bash "$HOOK" "$@"
}

assert_eq() {
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    printf 'PASS: %s\n' "$name"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s\n  expected: <%s>\n  actual:   <%s>\n' "$name" "$expected" "$actual" >&2
    FAIL=$((FAIL+1))
  fi
}

assert_true() {
  local name=$1 cond=$2
  if eval "$cond"; then
    printf 'PASS: %s\n' "$name"; PASS=$((PASS+1))
  else
    printf 'FAIL: %s (cond: %s)\n' "$name" "$cond" >&2
    FAIL=$((FAIL+1))
  fi
}

cleanup() {
  rm -rf "$CACHE"
  mkdir -p "$CACHE"
}

# Helper: write a transcript fixture line-by-line to a temp path.
make_transcript() {
  local path=$1; shift
  : >"$path"
  for line in "$@"; do
    printf '%s\n' "$line" >>"$path"
  done
}

# Helper: convert MSYS path -> mixed-form Windows path (forward slashes,
# drive letter prefix) so the harness's Windows-native Python can open files
# written under sandbox $HOME, AND the resulting string is safe to embed in
# Python code (no backslash-escape pitfalls like "\U..."). cygpath -m yields
# e.g. "C:/Users/.../handoff.json". No-op on Linux/macOS.
to_native() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

# --- T-1: token count above threshold -> reminder fires with token message
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s1","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-1: above threshold -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-1: message names tokens not bytes" '[[ "$OUT" == *"tokens"* ]] && [[ "$OUT" != *"bytes"* ]]'
assert_true "T-1: flag file written" '[[ -e "$CACHE/compact-warned-s1" ]]'
# T-1 additional regression: reminder must NOT use the v2.x "Invoke the prep-compact skill" directive
assert_true "T-1: reminder NO longer says 'Invoke the prep-compact skill' (v3 informational)" '[[ "$OUT" != *"Invoke the prep-compact skill"* ]]'

# --- T-2: token count below threshold with stale flag -> silent + flag cleared
cleanup
: >"$CACHE/compact-warned-s2"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=300000 run_hook '{"session_id":"s2","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_eq "T-2: below threshold -> silent" "" "$OUT"
assert_true "T-2: stale flag cleared" '[[ ! -e "$CACHE/compact-warned-s2" ]]'

# --- T-3: isSidechain: true is newest usage line -> earlier main-chain line used
cleanup
MAIN_A='{"message":{"role":"assistant","usage":{"input_tokens":5,"cache_creation_input_tokens":99995,"cache_read_input_tokens":0}}}'
SIDECHAIN='{"isSidechain":true,"message":{"role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":888888,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t3.jsonl" "$MAIN_A" "$SIDECHAIN"
# MAIN_A sums to 100000; sidechain-skip means token path returns 100000.
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=50000 run_hook '{"session_id":"s3","transcript_path":"'"$FIX/t3.jsonl"'"}')
assert_true "T-3: sidechain skipped, earlier main-chain used, reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-3: reminder reports N=100000 not sidechain huge value" '[[ "$OUT" == *"100000"* ]]'

# --- T-4: isApiErrorMessage: true is newest usage line -> earlier main-chain line used
cleanup
API_ERR='{"isApiErrorMessage":true,"message":{"role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":999999,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t4.jsonl" "$MAIN_A" "$API_ERR"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=50000 run_hook '{"session_id":"s4","transcript_path":"'"$FIX/t4.jsonl"'"}')
assert_true "T-4: api-error skipped, earlier main-chain used, reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-4: reminder reports N=100000 not api-error huge value" '[[ "$OUT" == *"100000"* ]]'

# --- T-5: no .message.usage in file (pre-first-turn) -> silent, no flag
cleanup
USER_MSG='{"message":{"role":"user","content":"hello"}}'
make_transcript "$FIX/t5.jsonl" "$USER_MSG"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"s5","transcript_path":"'"$FIX/t5.jsonl"'"}')
assert_eq "T-5: pre-first-turn -> silent" "" "$OUT"
assert_true "T-5: no flag written" '[[ ! -e "$CACHE/compact-warned-s5" ]]'

# --- T-6: malformed last usage line -> earlier valid line used
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s6","transcript_path":"'"$FIX/transcript-malformed-tail.jsonl"'"}')
assert_true "T-6: malformed tail skipped, earlier valid line used" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-6: reminder reports N=250010" '[[ "$OUT" == *"250010"* ]]'

# --- T-7: missing transcript_path -> silent
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"s7","transcript_path":"/nonexistent/path/xyz.jsonl"}')
assert_eq "T-7: missing transcript_path -> silent" "" "$OUT"
assert_true "T-7: no flag written" '[[ ! -e "$CACHE/compact-warned-s7" ]]'

# --- T-8: empty stdin -> silent
cleanup
OUT=$(run_hook '' 2>/dev/null)
assert_eq "T-8: empty stdin -> silent" "" "$OUT"

# --- T-9: malformed stdin JSON -> silent
cleanup
OUT=$(run_hook '{not valid json' 2>/dev/null)
assert_eq "T-9: malformed stdin -> silent" "" "$OUT"

# --- T-10: path traversal session_id -> no flag escapes cache dir
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"../../../evil","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>/dev/null)
ESCAPED=$(find "$SANDBOX_HOME/.claude" -path "$CACHE" -prune -o -name 'compact-warned-*' -print 2>/dev/null | head -n 1)
assert_eq "T-10: path traversal -> no escaped flag" "" "$ESCAPED"

# --- T-11: oversized session_id -> SHA-1 hex fallback
cleanup
LONG=$(printf 'a%.0s' {1..200})
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook "{\"session_id\":\"$LONG\",\"transcript_path\":\"$FIX/transcript-usage.jsonl\"}" 2>/dev/null)
assert_true "T-11: oversized sid -> raw name NOT used" '[[ ! -e "$CACHE/compact-warned-$LONG" ]]'
SHA1=$("$PY" -c "import hashlib; print(hashlib.sha1(b'$LONG').hexdigest())")
assert_true "T-11: oversized sid -> hash flag created" '[[ -e "$CACHE/compact-warned-$SHA1" ]]'

# --- T-12: empty session_id -> silent, no flag
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>/dev/null)
assert_eq "T-12: empty sid -> silent" "" "$OUT"
ANY_FLAG=$(find "$CACHE" -name 'compact-warned-*' 2>/dev/null | head -n 1)
assert_eq "T-12: empty sid -> no flag created" "" "$ANY_FLAG"

# --- T-13: CLAUDE_PLUGIN_DATA override -> flag written there
cleanup
OVERRIDE_DIR="$TEST_DIR/alt-cache"
mkdir -p "$OVERRIDE_DIR"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 CLAUDE_PLUGIN_DATA="$OVERRIDE_DIR" run_hook '{"session_id":"s13","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>/dev/null)
assert_true "T-13: override dir -> flag written there" '[[ -e "$OVERRIDE_DIR/compact-warned-s13" ]]'
assert_true "T-13: override dir -> no flag in fallback cache" '[[ ! -e "$CACHE/compact-warned-s13" ]]'

# --- T-14: mkdir failure on cache dir -> stderr warn, hook disabled this turn
cleanup
# Point CLAUDE_PLUGIN_DATA at a path whose parent is a regular file,
# making mkdir -p fail. Create a file to serve as the obstruction.
OBSTRUCTION="$TEST_DIR/obstructed"
printf 'not a dir\n' >"$OBSTRUCTION"
# Use run_hook_err to preserve stderr for the warn-message assertion.
ERR=$(CLAUDE_CONTEXT_WARN_TOKENS=1 CLAUDE_PLUGIN_DATA="$OBSTRUCTION/nope" run_hook_err '{"session_id":"s14","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>&1 >/dev/null)
assert_true "T-14: mkdir failure -> stderr warn" '[[ "$ERR" == *"cannot create"* ]]'

# --- T-15: bad CLAUDE_CONTEXT_WARN_TOKENS -> default substituted, stderr warn
for BAD in "not-a-number" "08" "3.14" "-1"; do
  cleanup
  # Use run_hook_err to capture stderr for the warn-message assertion.
  ERR=$(CLAUDE_CONTEXT_WARN_TOKENS="$BAD" run_hook_err '{"session_id":"s15","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>&1 >/dev/null)
  assert_true "T-15[$BAD]: invalid env -> stderr warn 'ignoring invalid'" '[[ "$ERR" == *"ignoring invalid"* ]]'
  # Default 450000 > 250000 fixture -> silent (no reminder on stdout)
  OUT=$(CLAUDE_CONTEXT_WARN_TOKENS="$BAD" run_hook '{"session_id":"s15b","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}' 2>/dev/null)
  assert_eq "T-15[$BAD]: default 450000 substituted -> silent on 250000 fixture" "" "$OUT"
done

# --- T-16: raise threshold above current N -> stale flag cleared
cleanup
# First fire: TOKENS=100000 < N=250000 -> flag written
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=100000 run_hook '{"session_id":"s16","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-16: initial fire -> flag written" '[[ -e "$CACHE/compact-warned-s16" ]]'
# Raise threshold above N
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=500000 run_hook '{"session_id":"s16","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-16: raised threshold -> stale flag cleared" '[[ ! -e "$CACHE/compact-warned-s16" ]]'

# --- T-17: role != 'assistant' is newest -> earlier assistant line used
cleanup
USER_WITH_USAGE='{"message":{"role":"user","usage":{"input_tokens":10,"cache_creation_input_tokens":888888,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t17.jsonl" "$MAIN_A" "$USER_WITH_USAGE"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=50000 run_hook '{"session_id":"s17","transcript_path":"'"$FIX/t17.jsonl"'"}')
assert_true "T-17: non-assistant usage skipped, earlier assistant used" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-17: reminder reports main-chain N=100000" '[[ "$OUT" == *"100000"* ]]'

# --- T-18: oversized last line > tail cap -> silent no-op (not a rescue)
# Codex r2 flagged that a single JSONL record > 256 KB at the end of the
# transcript straddles the tail cap. Our tail window contains only a
# mid-string slice of that oversized record; prior lines are outside the
# window and NOT recoverable. Correct behavior: silent no-op. This test
# guards that we fail-open (not crash, not return garbage).
cleanup
EARLIER_VALID='{"message":{"role":"assistant","usage":{"input_tokens":10,"cache_creation_input_tokens":123446,"cache_read_input_tokens":0}}}'
PAD=$("$PY" -c "print('A' * 300000)")  # 300 KB of A pushes the record past the 256 KB tail cap
OVERSIZED="{\"message\":{\"role\":\"assistant\",\"content\":\"$PAD\",\"usage\":{\"input_tokens\":10,\"cache_creation_input_tokens\":50000,\"cache_read_input_tokens\":0}}}"
make_transcript "$FIX/t18.jsonl" "$EARLIER_VALID" "$OVERSIZED"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"s18","transcript_path":"'"$FIX/t18.jsonl"'"}')
assert_eq "T-18: oversized straddling last record -> silent no-op" "" "$OUT"

# --- T-19: real UserPromptSubmit payload shape parity
# Exercises the live-captured UPS stdin fixture so stdin-shape regressions are
# caught. Swaps the real transcript_path with a known token-bearing fixture
# so the test is deterministic across machines.
cleanup
if [[ -s "$FIX/ups-real.json" ]]; then
  cp "$FIX/transcript-usage.jsonl" "$FIX/real-standin.jsonl"
  REAL_JSON=$("$PY" -c "import json,sys; d=json.load(sys.stdin); d['transcript_path']='$FIX/real-standin.jsonl'; print(json.dumps(d, separators=(',', ':')))" <"$FIX/ups-real.json")
  OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook "$REAL_JSON")
  assert_true "T-19: real UPS payload -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
else
  printf 'FAIL: ups-real.json missing (T-19 cannot run)\n' >&2
  FAIL=$((FAIL+1))
fi

# --- T-20: end-to-end warn -> /compact (context drops) -> re-arm cycle
# Codex diff-review flagged that v2.0.0 removes PostCompact and claims the
# natural below-threshold branch handles re-arm, but the harness only tested
# threshold-change stale-flag cleanup (T-16), never the real post-compact
# flow: transcript shrinks because /compact rewrites it, usage drops, flag
# clears, then transcript grows again and we re-warn cleanly.
cleanup
# Step 1: big transcript -> reminder fires, flag set
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s20","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-20: step 1 big transcript -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-20: step 1 flag set" '[[ -e "$CACHE/compact-warned-s20" ]]'

# Step 2: /compact simulation — transcript rewritten to a smaller one
# whose newest main-chain usage is below threshold.
POSTCOMPACT='{"message":{"role":"assistant","usage":{"input_tokens":5,"cache_creation_input_tokens":50000,"cache_read_input_tokens":0}}}'
make_transcript "$FIX/t20-post-compact.jsonl" "$POSTCOMPACT"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s20","transcript_path":"'"$FIX/t20-post-compact.jsonl"'"}')
assert_eq "T-20: step 2 post-compact small transcript -> silent" "" "$OUT"
assert_true "T-20: step 2 flag cleared by below-threshold branch" '[[ ! -e "$CACHE/compact-warned-s20" ]]'

# Step 3: transcript grows again -> re-arm fires a fresh reminder
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s20","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-20: step 3 re-arm fires reminder" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-20: step 3 flag re-set" '[[ -e "$CACHE/compact-warned-s20" ]]'

# --- T-39: reminder when handoff exists -> verbatim full string equality
cleanup
HANDOFF_PATH_T39="$CACHE/handoff-s39.json"
echo '{"version":"3.0"}' > "$HANDOFF_PATH_T39"
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"s39","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
EXPECTED_T39="Session context is approximately 250000 tokens (above configured threshold of 1 tokens). The on-disk handoff at $HANDOFF_PATH_T39 is current. When the user is ready to compact, run /prep-compact:prep-compact to add the analytical layer (decisions, constraints, blockers, verb-anchored next-step) and emit a tailored /compact <instructions> block. If you are at the very end of a todo list, you may finish the remaining items first."
assert_eq "T-39: handoff-present reminder verbatim" "$EXPECTED_T39" "$OUT"

# --- T-40: reminder when handoff missing -> verbatim no-handoff variant
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=1 run_hook '{"session_id":"s40","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
EXPECTED_T40="Session context is approximately 250000 tokens (above configured threshold of 1 tokens). Run /prep-compact:prep-compact to survey current state and emit a tailored /compact <instructions> block. If you are at the very end of a todo list, you may finish the remaining items first."
assert_eq "T-40: handoff-missing reminder verbatim" "$EXPECTED_T40" "$OUT"

# --- T-41: SKILL.md documents session-id binding via the helper (not mtime)
SKILL="$SCRIPT_DIR/../skills/prep-compact/SKILL.md"
assert_true "T-41: SKILL.md documents resolve-handoff.sh binding" '[[ "$(cat "$SKILL")" == *"resolve-handoff.sh"* ]]'
assert_true "T-41: SKILL.md no longer documents mtime discovery"  '[[ "$(cat "$SKILL")" != *"mtime"* ]]'

# --- T-51: single-line /compact enforcement
assert_true "T-51: multi-line escape hatch removed"   '[[ "$(cat "$SKILL")" != *"Multi-line form is permitted"* ]]'
assert_true "T-51: verify gate present (single line)" '[[ "$(cat "$SKILL")" == *"single physical line"* ]]'
assert_true "T-51: verify gate present (goal literal)" '[[ "$(cat "$SKILL")" == *"begins with the literal characters"* ]]'

# Stop-hook tests below depend on the Task-1 T-0 gate. Skip if gate failed.
if (( STOP_FIXTURE_OK == 1 )); then

STOP_HOOK="$SCRIPT_DIR/../hooks/update-handoff.sh"

run_stop_hook() {
  local stdin=$1; shift
  printf '%s' "$stdin" | HOME="$SANDBOX_HOME" bash "$STOP_HOOK" "$@" 2>/dev/null
}
run_stop_hook_err() {
  local stdin=$1; shift
  printf '%s' "$stdin" | HOME="$SANDBOX_HOME" bash "$STOP_HOOK" "$@"
}

# --- T-21: missing transcript_path -> fail-open silent
cleanup
OUT=$(run_stop_hook '{"session_id":"s21","transcript_path":"/nonexistent/foo.jsonl","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}')
assert_eq "T-21: missing transcript -> silent" "" "$OUT"
EXIT=$(printf '%s' '{"session_id":"s21","transcript_path":"/nonexistent/foo.jsonl","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' | HOME="$SANDBOX_HOME" bash "$STOP_HOOK" 2>/dev/null; echo "exit=$?")
assert_true "T-21: missing transcript -> exit 0 (fail-open)" '[[ "$EXIT" == *"exit=0"* ]]'

# --- T-22: empty stdin -> fail-open silent
cleanup
OUT=$(run_stop_hook '' 2>/dev/null)
assert_eq "T-22: empty stdin -> silent" "" "$OUT"

# --- T-23: malformed stdin -> fail-open silent
cleanup
OUT=$(run_stop_hook '{not valid' 2>/dev/null)
assert_eq "T-23: malformed stdin -> silent" "" "$OUT"

# --- T-24: oversized session_id -> SHA-1 fallback (no escaped path)
cleanup
LONG=$(printf 'b%.0s' {1..200})
OUT=$(run_stop_hook "{\"session_id\":\"$LONG\",\"transcript_path\":\"$FIX/transcript-handoff-multi-turn.jsonl\",\"cwd\":\"/x\",\"permission_mode\":\"default\",\"hook_event_name\":\"Stop\"}")
assert_true "T-24: oversized sid -> raw name NOT used" '[[ ! -e "$CACHE/handoff-$LONG.json" ]]'

# --- T-25: path traversal session_id -> no escape
cleanup
OUT=$(run_stop_hook '{"session_id":"../../evil","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' 2>/dev/null)
ESCAPED=$(find "$SANDBOX_HOME/.claude" -path "$CACHE" -prune -o -name 'handoff-*.json' -print 2>/dev/null | head -n 1)
assert_eq "T-25: path traversal -> no escaped handoff" "" "$ESCAPED"

# --- T-26: oversized single line in transcript -> not OOM, fail-open silent
cleanup
OUT=$(run_stop_hook '{"session_id":"s26","transcript_path":"'"$FIX/transcript-handoff-oversized-line.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}')
EXIT=$(printf '%s' '{"session_id":"s26","transcript_path":"'"$FIX/transcript-handoff-oversized-line.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' | HOME="$SANDBOX_HOME" bash "$STOP_HOOK" 2>/dev/null; echo "exit=$?")
assert_true "T-26: oversized line -> exit 0 (skipped, fail-open)" '[[ "$EXIT" == *"exit=0"* ]]'

# --- T-26b: malformed JSONL line MID-transcript -> hook skips bad line, processes valid lines
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
good1 = json.dumps({'message':{'role':'user','content':[{'type':'text','text':'first valid'}]}})
bad = '{not-valid json line'
good2 = json.dumps({'message':{'role':'user','content':[{'type':'text','text':'second valid'}]}})
with open(os.environ['FIX_ENV']+'/t26b.jsonl','w') as f:
    f.write(good1+'\n'+bad+'\n'+good2+'\n')
"
run_stop_hook '{"session_id":"s26b","transcript_path":"'"$FIX/t26b.jsonl"'","cwd":"/x","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s26b.json")
HAS_BOTH=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); r=d.get('recent_user_requests',[]); print('yes' if any('first valid' in q for q in r) and any('second valid' in q for q in r) else 'no')")
assert_eq "T-26b: malformed mid-line skipped, good lines processed" "yes" "$HAS_BOTH"

# --- T-27: multi-turn fixture -> handoff written, parseable JSON, all keys present
cleanup
run_stop_hook '{"session_id":"s27","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s27.json")
assert_true "T-27: handoff file written" '[[ -e "$HANDOFF" ]]'
assert_true "T-27: handoff parses as JSON with required keys" "$PY -c 'import json,sys; d=json.load(open(\"$HANDOFF\")); req={\"version\",\"session_id\",\"cwd\",\"transcript_path\",\"transcript_mtime_at_write\",\"written_at\",\"cumulative_files\",\"recent_files\",\"in_progress_status\",\"in_progress\",\"recent_task_launches\",\"recent_user_requests\"}; missing = req - set(d.keys()); sys.exit(0 if not missing else 1)'"

# --- T-28: recent_files contains Tier-A paths from Read/Edit, NOT user-text mentions
cleanup
run_stop_hook '{"session_id":"s28","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s28.json")
HAS_AUTH=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/auth.ts' in d['recent_files'] else 'no')")
HAS_SESSION=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/session.ts' in d['recent_files'] else 'no')")
HAS_TESTS=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'tests/auth.test.ts' in d['recent_files'] else 'no')")
assert_eq "T-28: recent_files has src/auth.ts (Tier-A)" "yes" "$HAS_AUTH"
assert_eq "T-28: recent_files has src/session.ts (Tier-A)" "yes" "$HAS_SESSION"
assert_eq "T-28: recent_files does NOT have tests/auth.test.ts (only in user text, no tool call)" "no" "$HAS_TESTS"

# --- T-28b: Tier-B Glob result extraction — paths in tool_result of a Glob tool_use end up in recent_files
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
turns = [
    {'message':{'role':'assistant','content':[{'type':'tool_use','id':'g1','name':'Glob','input':{'pattern':'src/**/*.ts'}}],'usage':{'input_tokens':100,'cache_creation_input_tokens':1000,'cache_read_input_tokens':0}}},
    {'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'g1','content':'src/found/a.ts\nsrc/found/b.ts\nnot-a-path-line\n'}]}},
    {'message':{'role':'assistant','content':[{'type':'tool_use','id':'gr1','name':'Grep','input':{'pattern':'foo','output_mode':'content'}}],'usage':{'input_tokens':100,'cache_creation_input_tokens':1000,'cache_read_input_tokens':0}}},
    {'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'gr1','content':[{'type':'text','text':'src/match/c.ts:42:foo\nsrc/match/d.ts:13:foo\n'}]}]}},
]
with open(os.environ['FIX_ENV']+'/t28b.jsonl','w') as f:
    for t in turns: f.write(json.dumps(t)+'\n')
"
run_stop_hook '{"session_id":"s28b","transcript_path":"'"$FIX/t28b.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s28b.json")
HAS_GLOB_A=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/found/a.ts' in d['recent_files'] else 'no')")
HAS_GREP_C=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/match/c.ts' in d['recent_files'] else 'no')")
HAS_NOT_PATH=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'not-a-path-line' in d['recent_files'] else 'no')")
assert_eq "T-28b: Glob result path extracted (src/found/a.ts)" "yes" "$HAS_GLOB_A"
assert_eq "T-28b: Grep result path extracted (path:line:match -> path only)" "yes" "$HAS_GREP_C"
assert_eq "T-28b: non-path-shaped line dropped" "no" "$HAS_NOT_PATH"

# --- T-29: recent_user_requests skips tool_result blocks; includes text blocks
cleanup
run_stop_hook '{"session_id":"s29","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s29.json")
HAS_TR=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('Edit applied' in r for r in d['recent_user_requests']) else 'no')")
HAS_PUB=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('do NOT change the public signature' in r for r in d['recent_user_requests']) else 'no')")
assert_eq "T-29: recent_user_requests SKIPS tool_result content" "no" "$HAS_TR"
assert_eq "T-29: recent_user_requests INCLUDES text content" "yes" "$HAS_PUB"

# --- T-30: in_progress_status known + in_progress contains the active todo
cleanup
run_stop_hook '{"session_id":"s30","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s30.json")
STATUS=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(d['in_progress_status'])")
HAS_NPM=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('Run npm test' in t for t in d['in_progress']) else 'no')")
assert_eq "T-30: in_progress_status == known" "known" "$STATUS"
assert_eq "T-30: in_progress contains 'Run npm test'" "yes" "$HAS_NPM"

# --- T-31: recent_task_launches contains rendered subagent_type+description
cleanup
run_stop_hook '{"session_id":"s31","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s31.json")
HAS_TASK=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('Explore: Find all callers' in t for t in d['recent_task_launches']) else 'no')")
assert_eq "T-31: recent_task_launches has Explore launch" "yes" "$HAS_TASK"

# --- T-32: no-user-text fixture -> recent_user_requests empty, in_progress_status unknown
cleanup
run_stop_hook '{"session_id":"s32","transcript_path":"'"$FIX/transcript-handoff-no-user-text.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s32.json")
N_REQ=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(len(d['recent_user_requests']))")
STATUS=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(d['in_progress_status'])")
assert_eq "T-32: recent_user_requests empty" "0" "$N_REQ"
assert_eq "T-32: in_progress_status unknown when no TodoWrite" "unknown" "$STATUS"

# --- T-32cap: recent_user_requests cap-boundary (5-message AND char cap)
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
msgs = [
    {'message':{'role':'user','content':[{'type':'text','text':f'msg-{i:02d} short content here under 50 chars'}]}}
    for i in range(1, 8)
]
with open(os.environ['FIX_ENV']+'/t32cap.jsonl','w') as f:
    for m in msgs: f.write(json.dumps(m)+'\n')
"
run_stop_hook '{"session_id":"s32cap","transcript_path":"'"$FIX/t32cap.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s32cap.json")
N_MSG=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(len(d['recent_user_requests']))")
assert_eq "T-32cap: 5-message cap (7 in transcript -> 5 in handoff)" "5" "$N_MSG"

cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
huge = 'x' * 25000
msgs = [
    {'message':{'role':'user','content':[{'type':'text','text':'short first'}]}},
    {'message':{'role':'user','content':[{'type':'text','text':huge}]}},
]
with open(os.environ['FIX_ENV']+'/t32cap2.jsonl','w') as f:
    for m in msgs: f.write(json.dumps(m)+'\n')
"
run_stop_hook '{"session_id":"s32cap2","transcript_path":"'"$FIX/t32cap2.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s32cap2.json")
HAS_HUGE=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); r=d.get('recent_user_requests',[]); total = sum(len(q) for q in r); print('yes' if total > 20000 else 'no')")
assert_eq "T-32cap: char-cap respected (total chars NOT over 20000)" "no" "$HAS_HUGE"
# Codex PR-comment fix: oversized message should be SKIPPED, not abort the loop. Older shorter msg should still be captured.
HAS_SHORT=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); r=d.get('recent_user_requests',[]); print('yes' if any('short first' in q for q in r) else 'no')")
assert_eq "T-32cap: oversized newest skipped, older 'short first' still captured" "yes" "$HAS_SHORT"

# --- T-32prior: prior handoff user_requests preserved when current tail has no user text
# Codex PR-comment fix: prior_user_requests must be merged so a turn with no user text in tail
# does not drop captured intent.
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s32prior','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':['prior intent A','prior intent B']}
with open('$(to_native "$CACHE/handoff-s32prior.json")','w') as f: json.dump(prior, f)
"
# Run against the no-user-text fixture (only assistant + tool_result, no user-text blocks).
run_stop_hook '{"session_id":"s32prior","transcript_path":"'"$FIX/transcript-handoff-no-user-text.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s32prior.json")
HAS_PRIOR_A=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'prior intent A' in d.get('recent_user_requests',[]) else 'no')")
HAS_PRIOR_B=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'prior intent B' in d.get('recent_user_requests',[]) else 'no')")
assert_eq "T-32prior: prior user_requests A preserved when current tail has no user text" "yes" "$HAS_PRIOR_A"
assert_eq "T-32prior: prior user_requests B preserved when current tail has no user text" "yes" "$HAS_PRIOR_B"

# --- T-33: tool-blob fixture -> path-shaped strings inside huge tool_result NOT in recent_files
cleanup
run_stop_hook '{"session_id":"s33","transcript_path":"'"$FIX/transcript-handoff-tool-blob.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s33.json")
HAS_FOO=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if '/tmp/foo.log' in d['recent_files'] else 'no')")
HAS_BAR=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if '/tmp/bar.txt' in d['recent_files'] else 'no')")
assert_eq "T-33: Tier-C dropped — /tmp/foo.log NOT in recent_files" "no" "$HAS_FOO"
assert_eq "T-33: Tier-C dropped — /tmp/bar.txt NOT in recent_files" "no" "$HAS_BAR"

# --- T-34: cumulative_files monotonic across two runs against different transcripts
cleanup
mkdir -p "$CACHE"
cp "$FIX/handoff-prior.json" "$CACHE/handoff-s34.json"
"$PY" -c "
import json
with open('$(to_native "$CACHE/handoff-s34.json")','r') as f: d=json.load(f)
d['session_id']='s34'
with open('$(to_native "$CACHE/handoff-s34.json")','w') as f: json.dump(d,f)
"
run_stop_hook '{"session_id":"s34","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s34.json")
HAS_LEGACY=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/legacy/old.ts' in d['cumulative_files'] else 'no')")
HAS_AUTH=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/auth.ts' in d['cumulative_files'] else 'no')")
assert_eq "T-34: prior cumulative_files preserved (src/legacy/old.ts)" "yes" "$HAS_LEGACY"
assert_eq "T-34: new path added (src/auth.ts)" "yes" "$HAS_AUTH"

# --- T-34b: prior recent_task_launches preserved across runs
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s34b','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':['Explore: prior unique launch'],'recent_user_requests':[]}
with open('$(to_native "$CACHE/handoff-s34b.json")','w') as f: json.dump(prior, f)
"
run_stop_hook '{"session_id":"s34b","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s34b.json")
HAS_PRIOR_TASK=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('prior unique launch' in t for t in d['recent_task_launches']) else 'no')")
HAS_NEW_TASK=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if any('Explore: Find all callers' in t for t in d['recent_task_launches']) else 'no')")
assert_eq "T-34b: prior recent_task_launches preserved" "yes" "$HAS_PRIOR_TASK"
assert_eq "T-34b: new launches appended" "yes" "$HAS_NEW_TASK"

# --- T-35: FIFO cap at 200 — older entries dropped first
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s35','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':[f'/old/path/{i:03d}.ts' for i in range(200)],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':[]}
with open('$(to_native "$CACHE/handoff-s35.json")','w') as f: json.dump(prior, f)
"
run_stop_hook '{"session_id":"s35","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s35.json")
N=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(len(d['cumulative_files']))")
HAS_FIRST_OLD=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if '/old/path/000.ts' in d['cumulative_files'] else 'no')")
HAS_NEW=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'src/auth.ts' in d['cumulative_files'] else 'no')")
assert_eq "T-35: cumulative_files capped at 200" "200" "$N"
assert_eq "T-35: oldest entry evicted (/old/path/000.ts)" "no" "$HAS_FIRST_OLD"
assert_eq "T-35: new entry kept (src/auth.ts)" "yes" "$HAS_NEW"

# --- T-36: PREP_COMPACT_NO_USER_QUOTES=1 -> empty + eager-clear prior quotes
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s36','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':['old quote 1','old quote 2']}
with open('$(to_native "$CACHE/handoff-s36.json")','w') as f: json.dump(prior, f)
"
PREP_COMPACT_NO_USER_QUOTES=1 run_stop_hook '{"session_id":"s36","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s36.json")
N_REQ=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(len(d['recent_user_requests']))")
assert_eq "T-36: env var blanks recent_user_requests AND clears prior quotes" "0" "$N_REQ"

# --- T-37: round-trip backticks/quotes/newlines verbatim
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
tricky = 'Has \`\`\`fences\`\`\` and \"quotes\" and\nnewlines\nand\ttabs'
line = json.dumps({'message':{'role':'user','content':[{'type':'text','text':tricky}]}})
with open(os.environ['FIX_ENV']+'/t37.jsonl','w') as f: f.write(line + '\n')
"
run_stop_hook '{"session_id":"s37","transcript_path":"'"$FIX/t37.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s37.json")
ROUND_TRIP_OK=$("$PY" -c "
import json
d=json.load(open('$HANDOFF'))
expected = 'Has \`\`\`fences\`\`\` and \"quotes\" and\nnewlines\nand\ttabs'
print('yes' if d['recent_user_requests'][0] == expected else 'no')
")
assert_eq "T-37: backticks/quotes/newlines round-trip verbatim" "yes" "$ROUND_TRIP_OK"

# --- T-38: atomic write — corrupted prior handoff treated as no-prior, write succeeds
cleanup
echo "{not valid json" > "$CACHE/handoff-s38.json"
run_stop_hook '{"session_id":"s38","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s38.json")
PARSE_OK=$("$PY" -c "
import json
try:
    json.load(open('$HANDOFF'))
    print('yes')
except Exception:
    print('no')
")
assert_eq "T-38: corrupted prior -> new write succeeds, parses cleanly" "yes" "$PARSE_OK"

# --- T-38p: PermissionError simulation — prior file preserved, stderr warning
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s38p','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':['SENTINEL/prior.ts'],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':[]}
with open('$(to_native "$CACHE/handoff-s38p.json")','w') as f: json.dump(prior, f)
"
ERR=$(PREP_COMPACT_TEST_REPLACE_FAIL=1 run_stop_hook_err '{"session_id":"s38p","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' 2>&1 >/dev/null)
HANDOFF=$(to_native "$CACHE/handoff-s38p.json")
PRIOR_INTACT=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print('yes' if 'SENTINEL/prior.ts' in d.get('cumulative_files',[]) else 'no')")
assert_eq "T-38p: simulated replace fail -> prior preserved (sentinel intact)" "yes" "$PRIOR_INTACT"
assert_true "T-38p: stderr warning printed on simulated fail" '[[ "$ERR" == *"replace failed twice, prior preserved"* ]]'

# --- T-38g: async ordering guard — a newer on-disk handoff is NOT clobbered by an older run.
# Pre-write a handoff with a far-future transcript_mtime_at_write; the run (whose
# fixture transcript has a normal mtime) must SKIP the replace, leaving the
# sentinel written_at untouched. Distinguishes the guard from cumulative_files
# merge (which would preserve prior entries even on a write).
cleanup
"$PY" -c "
import json
prior = {'version':'3.0','session_id':'s38g','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':9999999999.0,'written_at':'2099-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':[]}
with open('$(to_native "$CACHE/handoff-s38g.json")','w') as f: json.dump(prior, f)
"
run_stop_hook '{"session_id":"s38g","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s38g.json")
WRITTEN_AT=$("$PY" -c "import json; d=json.load(open('$HANDOFF')); print(d.get('written_at',''))")
assert_eq "T-38g: newer on-disk handoff preserved (guard skips stale replace)" "2099-01-01T00:00:00Z" "$WRITTEN_AT"

# T-52: file noise filter — .git/temp/plugin-data excluded, real path kept
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
t=[{'message':{'role':'assistant','content':[
  {'type':'tool_use','id':'r1','name':'Read','input':{'file_path':'src/keep.ts'}},
  {'type':'tool_use','id':'r2','name':'Read','input':{'file_path':'.git/hooks/pre-commit.sample'}},
  {'type':'tool_use','id':'r3','name':'Read','input':{'file_path':'/tmp/codex-x.txt'}},
  {'type':'tool_use','id':'r4','name':'Read','input':{'file_path':'C:/Users/u/.claude/plugins/data/prep-compact-inline/handoff-z.json'}},
  {'type':'tool_use','id':'r5','name':'Read','input':{'file_path':'C:/Users/u/.claude/settings.json'}},
  {'type':'tool_use','id':'r6','name':'Read','input':{'file_path':'.claude/plugins/data/prep-compact-inline/handoff-rel.json'}}],
  'usage':{'input_tokens':1,'cache_creation_input_tokens':1,'cache_read_input_tokens':0}}}]
open(os.environ['FIX_ENV']+'/t52.jsonl','w').write('\n'.join(json.dumps(x) for x in t)+'\n')
"
run_stop_hook '{"session_id":"s52","transcript_path":"'"$FIX/t52.jsonl"'","cwd":"/sample","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s52.json")
assert_eq "T-52: real path kept"         "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if 'src/keep.ts' in d['recent_files'] else 'no')")"
assert_eq "T-52: .git filtered"          "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('.git' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-52: temp NOT filtered (kept)" "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('codex-x' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-52: plugin-data filtered"   "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('handoff-z' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-52: ~/.claude/settings.json kept" "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('settings.json' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-52: relative plugin-data filtered" "no" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('handoff-rel' in p for p in d['recent_files']) else 'no')")"

# T-53: prior cumulative_files noise purged on next write
cleanup
"$PY" -c "
import json
p={'version':'3.0','session_id':'s53','cwd':'/sample','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':['src/old.ts','.git/config','/tmp/noise.txt'],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':[]}
open('$(to_native "$CACHE/handoff-s53.json")','w').write(json.dumps(p))
"
run_stop_hook '{"session_id":"s53","transcript_path":"'"$FIX/transcript-handoff-multi-turn.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s53.json")
assert_eq "T-53: prior real path kept" "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if 'src/old.ts' in d['cumulative_files'] else 'no')")"
assert_eq "T-53: prior .git noise purged" "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('.git/config' in p for p in d['cumulative_files']) else 'no')")"

# T-54: injected user messages filtered from recent_user_requests
cleanup
FIX_ENV="$FIX" "$PY" -c "
import json, os
t=[{'message':{'role':'user','content':[{'type':'text','text':'real request: do the thing'}]}},
   {'message':{'role':'user','content':[{'type':'text','text':'<task-notification>\nbg done\n</task-notification>'}]}},
   {'message':{'role':'user','content':[{'type':'text','text':'Base directory for this skill: C:/x\n# Skill\nblah'}]}},
   {'message':{'role':'user','content':[{'type':'text','text':'[SYSTEM NOTIFICATION - NOT USER INPUT]\nbackground event'}]}}]
open(os.environ['FIX_ENV']+'/t54.jsonl','w').write('\n'.join(json.dumps(x) for x in t)+'\n')
"
run_stop_hook '{"session_id":"s54","transcript_path":"'"$FIX/t54.jsonl"'","cwd":"/sample","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s54.json")
assert_eq "T-54: real request kept"        "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('real request' in q for q in d['recent_user_requests']) else 'no')")"
assert_eq "T-54: task-notification filtered" "no" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('task-notification' in q for q in d['recent_user_requests']) else 'no')")"
assert_eq "T-54: skill-load filtered"      "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('Base directory for this skill' in q for q in d['recent_user_requests']) else 'no')")"
assert_eq "T-54: system-notification filtered" "no" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('SYSTEM NOTIFICATION' in q for q in d['recent_user_requests']) else 'no')")"

# T-55: prior recent_user_requests injected noise purged on merge (mirrors T-53 for requests)
cleanup
"$PY" -c "
import json
p={'version':'3.0','session_id':'s55','cwd':'/sample/cwd','transcript_path':'/x','transcript_mtime_at_write':0,'written_at':'2026-01-01T00:00:00Z','cumulative_files':[],'recent_files':[],'in_progress_status':'unknown','in_progress':[],'recent_task_launches':[],'recent_user_requests':['real prior intent','<task-notification>\nold bg event\n</task-notification>']}
open('$(to_native "$CACHE/handoff-s55.json")','w').write(json.dumps(p))
"
run_stop_hook '{"session_id":"s55","transcript_path":"'"$FIX/transcript-handoff-no-user-text.jsonl"'","cwd":"/sample/cwd","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s55.json")
assert_eq "T-55: prior real request kept" "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('real prior intent' in q for q in d['recent_user_requests']) else 'no')")"
assert_eq "T-55: prior injected purged"   "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('task-notification' in q for q in d['recent_user_requests']) else 'no')")"

# T-56: Tier-B grep-result extraction rejects shell/code lines. Regression: a grep
# CONTEXT line "357-SKILL=\"\$DIR/../skills/prep-compact/SKILL.md\"" was captured as a path.
cleanup
JUNK_LINE='357-SKILL="$SCRIPT_DIR/../skills/prep-compact/SKILL.md"' \
REAL_LINE='src/real/keep.ts:42:SKILL' \
LEGIT_LINE='fixtures/a=b.json:1:match' \
FIX_ENV="$FIX" "$PY" -c "
import json, os
content = os.environ['JUNK_LINE'] + '\n' + os.environ['REAL_LINE'] + '\n' + os.environ['LEGIT_LINE'] + '\n'
turns = [
  {'message':{'role':'assistant','content':[{'type':'tool_use','id':'gj1','name':'Grep','input':{'pattern':'SKILL','output_mode':'content'}}],'usage':{'input_tokens':100,'cache_creation_input_tokens':1000,'cache_read_input_tokens':0}}},
  {'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'gj1','content':content}]}},
]
with open(os.environ['FIX_ENV']+'/t56.jsonl','w') as f:
  for t in turns: f.write(json.dumps(t)+'\n')
"
run_stop_hook '{"session_id":"s56","transcript_path":"'"$FIX/t56.jsonl"'","cwd":"/sample","permission_mode":"default","hook_event_name":"Stop"}' >/dev/null
HANDOFF=$(to_native "$CACHE/handoff-s56.json")
assert_eq "T-56: real grep path kept"      "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('src/real/keep.ts' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-56: legit =-char path kept"   "yes" "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any('a=b.json' in p for p in d['recent_files']) else 'no')")"
assert_eq "T-56: shell-junk line rejected" "no"  "$("$PY" -c "import json;d=json.load(open('$HANDOFF'));print('yes' if any(('SCRIPT_DIR' in p) or ('SKILL=' in p) or ('prep-compact/SKILL.md' in p) for p in d['recent_files']) else 'no')")"

else
  SKIPPED=60
fi  # STOP_FIXTURE_OK

# ===================================================================
# resolve-handoff.sh — session-binding helper (T-42..T-50)
# ===================================================================
RESOLVE="$SCRIPT_DIR/../skills/prep-compact/resolve-handoff.sh"
PDATA="$SANDBOX_HOME/.claude/plugins/data"

# Write a handoff fixture at an arbitrary path, or under a named install dir.
write_handoff_at() {  # $1=abs json path  $2=cwd
  mkdir -p "$(dirname "$1")"
  "$PY" - "$1" "$2" <<'PYW'
import json,sys
json.dump({"version":"3.0","session_id":"x","cwd":sys.argv[2],"cumulative_files":[],
           "recent_user_requests":[],"in_progress":[],"in_progress_status":"unknown",
           "recent_task_launches":[]}, open(sys.argv[1],"w",encoding="utf-8"))
PYW
}
write_handoff() { write_handoff_at "$PDATA/$1/handoff-$2.json" "$3"; }   # $1=install $2=sid $3=cwd

# Run resolver, capture RAW stdout to a file; set RSTATUS / RPATH / RLINES.
# Extra env (e.g. CLAUDE_PLUGIN_DATA=...) may be prefixed before the call.
run_resolve_f() {  # $1=sid (may be empty)  $2=cwd
  local out="$TEST_DIR/resolve.out"
  CLAUDE_CODE_SESSION_ID="$1" \
  CLAUDE_CODE_PLUGIN_CACHE_DIR="$SANDBOX_HOME/.claude/plugins" \
  HOME="$SANDBOX_HOME" bash "$RESOLVE" "$2" >"$out" 2>/dev/null
  RLINES=$(wc -l < "$out" | tr -d ' ')
  RSTATUS=$(sed -n 1p "$out")
  RPATH=$(sed -n 2p "$out")
}
reset_pdata() { cleanup; rm -rf "$PDATA"; mkdir -p "$PDATA"; }

# T-42 HIT: own handoff, matching cwd, exactly two lines
reset_pdata
write_handoff "prep-compact-inline" "sidA" "C:/proj/one"
run_resolve_f "sidA" "C:/proj/one"
assert_eq   "T-42: HIT status"            "HIT" "$RSTATUS"
assert_true "T-42: HIT path is sidA file" '[[ "$RPATH" == *"handoff-sidA.json"* ]]'
assert_eq   "T-42: HIT is exactly 2 lines" "2"  "$RLINES"

# T-43 negative regression (THE bug): own absent, sibling same cwd -> MISS
reset_pdata
write_handoff "prep-compact-inline" "sidB" "C:/proj/one"
run_resolve_f "sidA" "C:/proj/one"
assert_eq "T-43: sibling not selected -> MISS" "MISS" "$RSTATUS"
assert_eq "T-43: MISS is exactly 1 line"        "1"    "$RLINES"

# T-44 cwd-mismatch (D5): own handoff exists, different cwd -> MISS
reset_pdata
write_handoff "prep-compact-inline" "sidA" "C:/proj/other"
run_resolve_f "sidA" "C:/proj/one"
assert_eq "T-44: cwd mismatch -> MISS" "MISS" "$RSTATUS"

# T-45 NOSID (D4): no session id -> NOSID even with siblings, exactly 1 line
reset_pdata
write_handoff "prep-compact-inline" "sidB" "C:/proj/one"
run_resolve_f "" "C:/proj/one"
assert_eq "T-45: empty sid -> NOSID"      "NOSID" "$RSTATUS"
assert_eq "T-45: NOSID is exactly 1 line" "1"     "$RLINES"

# T-46 malformed-skip: bad candidate in higher-priority root, valid in lower
reset_pdata
mkdir -p "$PDATA/aaa-inline"
echo "{not json" > "$PDATA/aaa-inline/handoff-sidA.json"        # sorts first (higher priority)
write_handoff "zzz-inline" "sidA" "C:/proj/one"                 # valid, lower priority
run_resolve_f "sidA" "C:/proj/one"
assert_eq   "T-46: malformed skipped -> HIT"        "HIT" "$RSTATUS"
assert_true "T-46: valid lower-root candidate chosen" '[[ "$RPATH" == *"zzz-inline"* ]]'

# T-46b semantic-malformed (cwd is a list, not a string) is skipped, not fatal
reset_pdata
mkdir -p "$PDATA/aaa-inline"
# to_native: the path is interpolated INTO the python -c code, so MSYS does not
# translate it (unlike an argv path); without this, Windows python resolves the
# /tmp/... MSYS path to a non-existent C:\tmp\... and the malformed fixture is
# never written, making this test pass for the wrong reason.
"$PY" -c "import json;json.dump({'cwd':['oops']},open(r'$(to_native "$PDATA/aaa-inline/handoff-sidA.json")','w'))"
write_handoff "zzz-inline" "sidA" "C:/proj/one"
run_resolve_f "sidA" "C:/proj/one"
assert_eq   "T-46b: non-string cwd skipped, scan continues -> HIT" "HIT" "$RSTATUS"
assert_true "T-46b: zzz-inline chosen (parallel to T-46)" '[[ "$RPATH" == *"zzz-inline"* ]]'

# T-47 collision: same sid+cwd in explicit $CLAUDE_PLUGIN_DATA and a glob root
#   -> explicit root (priority 0) wins; sibling root NOT chosen
reset_pdata
write_handoff "zzz-inline" "sidA" "C:/proj/one"
OVR="$SANDBOX_HOME/explicit"
write_handoff_at "$OVR/handoff-sidA.json" "C:/proj/one"
out="$TEST_DIR/resolve.out"
CLAUDE_CODE_SESSION_ID="sidA" CLAUDE_PLUGIN_DATA="$OVR" \
CLAUDE_CODE_PLUGIN_CACHE_DIR="$SANDBOX_HOME/.claude/plugins" \
HOME="$SANDBOX_HOME" bash "$RESOLVE" "C:/proj/one" >"$out" 2>/dev/null
assert_eq   "T-47: collision -> HIT"                 "HIT" "$(sed -n 1p "$out")"
assert_true "T-47: explicit priority-0 root chosen"  '[[ "$(sed -n 2p "$out")" == *"explicit"* ]]'
assert_true "T-47: sibling glob root NOT chosen"     '[[ "$(sed -n 2p "$out")" != *"zzz-inline"* ]]'

# T-48 oversized sid -> SHA-1 filename resolves
reset_pdata
LONGSID=$(printf 'a%.0s' {1..200})
SHA=$("$PY" -c "import hashlib,sys; print(hashlib.sha1(sys.argv[1].encode()).hexdigest())" "$LONGSID")
write_handoff "prep-compact-inline" "$SHA" "C:/proj/one"
run_resolve_f "$LONGSID" "C:/proj/one"
assert_eq "T-48: oversized sid -> SHA-1 HIT" "HIT" "$RSTATUS"

# T-49 traversal sid is sanitized to SHA-1 (resolves at the hashed name, no escape)
reset_pdata
EVILSHA=$("$PY" -c "import hashlib; print(hashlib.sha1('../../evil'.encode()).hexdigest())")
write_handoff "prep-compact-inline" "$EVILSHA" "C:/proj/one"
run_resolve_f "../../evil" "C:/proj/one"
assert_eq "T-49: traversal sid -> SHA-1 sanitized HIT (no raw-path escape)" "HIT" "$RSTATUS"

# T-50 canonicalization: stored backslash C:\.. vs current MSYS /c/.. -> HIT
# (cygpath when present; the /c<->C: regex fallback covers cygpath-absent CI.)
reset_pdata
write_handoff "prep-compact-inline" "sidA" 'C:\proj\one'
run_resolve_f "sidA" "/c/proj/one"
assert_eq "T-50: C:\\.. vs /c/.. canonicalize-equal -> HIT" "HIT" "$RSTATUS"

# --- Final guard: false-green blocker
if (( PASS + SKIPPED != EXPECTED_PASS )); then
  printf 'FAIL: expected %d (got PASS=%d + SKIPPED=%d, FAIL=%d)\n' "$EXPECTED_PASS" "$PASS" "$SKIPPED" "$FAIL" >&2
  exit 1
fi

if (( FAIL > 0 )); then
  printf '\nFAILED: %d assertion(s) failed\n' "$FAIL" >&2
  exit 1
fi

printf '\nAll %d assertions passed\n' "$PASS"
exit 0
