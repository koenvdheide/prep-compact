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
FIX="$TEST_DIR/fixtures"

# Sandboxed HOME so the hook's ~/.claude/cache expansion lands INSIDE the
# harness, not in the real live-sessions cache.
SANDBOX_HOME="$TEST_DIR/sandbox-home"
CACHE="$SANDBOX_HOME/.claude/cache"
mkdir -p "$CACHE"

FAIL=0
PASS=0
# EXPECTED_PASS MUST equal the exact count of assert_eq + assert_true calls.
# Tally (T-1..T-19): 3+2+2+2+2+2+2+1+1+1+2+2+2+1+8+2+2+1+1 = 39
EXPECTED_PASS=39

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

# --- T-1: token count above threshold -> reminder fires with token message
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_TOKENS=200000 run_hook '{"session_id":"s1","transcript_path":"'"$FIX/transcript-usage.jsonl"'"}')
assert_true "T-1: above threshold -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "T-1: message names tokens not bytes" '[[ "$OUT" == *"tokens"* ]] && [[ "$OUT" != *"bytes"* ]]'
assert_true "T-1: flag file written" '[[ -e "$CACHE/compact-warned-s1" ]]'

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

# --- Final guard: false-green blocker
if (( PASS != EXPECTED_PASS )); then
  printf 'FAIL: expected %d assertions to pass, got %d (PASS) + %d (FAIL)\n' "$EXPECTED_PASS" "$PASS" "$FAIL" >&2
  exit 1
fi

if (( FAIL > 0 )); then
  printf '\nFAILED: %d assertion(s) failed\n' "$FAIL" >&2
  exit 1
fi

printf '\nAll %d assertions passed\n' "$PASS"
exit 0
