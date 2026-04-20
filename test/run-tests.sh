#!/usr/bin/env bash
# Test harness for check-context-size.sh.
# Explicit PASS count: false-green is blocked by a final assertion on $PASS == expected.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/check-context-size.sh"
TEST_DIR="$(mktemp -d 2>/dev/null || printf '/tmp/prep-compact-test-%s' "$$")"
mkdir -p "$TEST_DIR/fixtures"
if [[ -f "$SCRIPT_DIR/fixtures/ups-real.json" ]]; then
  cp "$SCRIPT_DIR/fixtures/ups-real.json" "$TEST_DIR/fixtures/ups-real.json"
fi
FIX=$TEST_DIR/fixtures
# Sandboxed HOME so the hook's ~/.claude/cache expansion lands INSIDE the
# harness, not in the real live-sessions cache. Previous versions used
# ~/.claude/cache directly; the harness cleanup() then wiped flags belonging
# to real sessions and caused the production hook to re-fire reminders.
SANDBOX_HOME="$TEST_DIR/sandbox-home"
CACHE="$SANDBOX_HOME/.claude/cache"

mkdir -p "$FIX" "$CACHE"
FAIL=0
PASS=0
EXPECTED_PASS=43

# Harness Python resolution: mirror the hook. Prefer python3; fall back to
# python only if it is Python 3. Fail fast if neither is available.
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' 2>/dev/null; then
  PY=python
else
  printf 'run-tests: Python 3 not found on PATH (tried python3 and python).\n' >&2
  exit 1
fi

make_random_file() { head -c "$2" </dev/urandom >"$1"; }

run_hook() {
  local stdin=$1; shift
  printf '%s' "$stdin" | HOME="$SANDBOX_HOME" bash "$HOOK" "$@" 2>/dev/null
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

cleanup() { rm -f "$CACHE"/compact-warned-* 2>/dev/null || true; }

# --- 1: below threshold + flag absent -> no-op
cleanup
make_random_file "$FIX/small.jsonl" 500
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s1","transcript_path":"'"$FIX/small.jsonl"'"}')
assert_eq "below+absent -> silent" "" "$OUT"

# --- 2: above threshold + flag absent -> reminder + flag
cleanup
make_random_file "$FIX/big.jsonl" 2000
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s2","transcript_path":"'"$FIX/big.jsonl"'"}')
assert_true "above+absent -> reminder contains 'prep-compact'" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "above+absent -> flag created" '[[ -e "$CACHE/compact-warned-s2" ]]'

# --- 3: above threshold + flag present -> silent
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s2","transcript_path":"'"$FIX/big.jsonl"'"}')
assert_eq "above+present -> silent" "" "$OUT"

# --- 4: below threshold + flag present -> flag deleted (stale-flag cleanup)
cleanup
touch "$CACHE/compact-warned-s4"
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s4","transcript_path":"'"$FIX/small.jsonl"'"}')
assert_true "below+present -> stale flag cleared" '[[ ! -e "$CACHE/compact-warned-s4" ]]'

# --- 5: RESET scope — deletes only the target flag
cleanup
touch "$CACHE/compact-warned-target"
touch "$CACHE/compact-warned-bystander"
run_hook '{"session_id":"target"}' RESET >/dev/null
assert_true "RESET -> target deleted" '[[ ! -e "$CACHE/compact-warned-target" ]]'
assert_true "RESET -> bystander intact" '[[ -e "$CACHE/compact-warned-bystander" ]]'
rm -f "$CACHE/compact-warned-bystander"

# --- 6: missing transcript / empty stdin -> no-op, exit 0
OUT=$(run_hook '{"session_id":"s6","transcript_path":"/tmp/nope.jsonl"}')
assert_eq "missing transcript -> silent" "" "$OUT"
printf '' | bash "$HOOK" >/dev/null 2>&1; EMPTY_RC=$?
assert_eq "empty stdin -> exit 0" "0" "$EMPTY_RC"

# --- 7: malformed JSON -> no-op
OUT=$(run_hook 'not json'); assert_eq "malformed JSON -> silent" "" "$OUT"

# --- 8: exotic session_id (path traversal) -> no flag escapes cache dir
cleanup
make_random_file "$FIX/big.jsonl" 2000
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"../../../evil","transcript_path":"'"$FIX/big.jsonl"'"}' 2>/dev/null)
ESCAPED=$(find "$SANDBOX_HOME/.claude" -path "$CACHE" -prune -o -name 'compact-warned-*' -print 2>/dev/null | head -n 1)
assert_eq "path traversal -> no escaped flag" "" "$ESCAPED"

# --- 9: oversized session_id -> SHA-1 hash fallback, not raw name
cleanup
LONG=$(printf 'a%.0s' {1..200})
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook "{\"session_id\":\"$LONG\",\"transcript_path\":\"$FIX/big.jsonl\"}" 2>/dev/null)
assert_true "oversized sid -> not used raw" '[[ ! -e "$CACHE/compact-warned-$LONG" ]]'
SHA1=$("$PY" -c "import hashlib; print(hashlib.sha1(b'$LONG').hexdigest())")
assert_true "oversized sid -> hash flag created" '[[ -e "$CACHE/compact-warned-$SHA1" ]]'

# --- 10: env var override lowers threshold
cleanup
make_random_file "$FIX/medium.jsonl" 1500
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=2000 run_hook '{"session_id":"s10","transcript_path":"'"$FIX/medium.jsonl"'"}')
assert_eq "env override (threshold 2000, 1500b) -> silent" "" "$OUT"
cleanup
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s10b","transcript_path":"'"$FIX/medium.jsonl"'"}')
assert_true "env override (threshold 1000, 1500b) -> reminder" '[[ "$OUT" == *"prep-compact"* ]]'

# --- 11: real Task 0 payload parity
cleanup
if [[ -s "$FIX/ups-real.json" ]]; then
  REAL_TP=$("$PY" -c "import json,sys; print(json.load(sys.stdin).get('transcript_path',''))" <"$FIX/ups-real.json")
  if [[ -z "$REAL_TP" || ! -r "$REAL_TP" ]]; then
    cp "$FIX/big.jsonl" "$FIX/real-standin.jsonl"
    REAL_JSON=$("$PY" -c "import json,sys; d=json.load(sys.stdin); d['transcript_path']='$FIX/real-standin.jsonl'; print(json.dumps(d, separators=(',', ':')))" <"$FIX/ups-real.json")
  else
    REAL_JSON=$(cat "$FIX/ups-real.json")
  fi
  OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1 run_hook "$REAL_JSON")
  assert_true "real UPS payload -> reminder" '[[ "$OUT" == *"prep-compact"* ]]'
else
  printf 'FAIL: ups-real.json missing\n' >&2
  FAIL=$((FAIL+1))
fi

# --- 12: empty session_id -> no flag created
cleanup
printf '%s' '{"session_id":"","transcript_path":"'"$FIX/big.jsonl"'"}' | HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null >/dev/null
assert_true "empty session_id -> no flag created" '! ls "$CACHE"/compact-warned-* 2>/dev/null | grep -q .'
# Exit-0 fail-open sanity for empty SID.
printf '%s' '{"session_id":"","transcript_path":"'"$FIX/big.jsonl"'"}' | HOME="$SANDBOX_HOME" bash "$HOOK" >/dev/null 2>&1; EMPTY_SID_RC=$?
assert_eq "empty session_id -> hook exits 0" "0" "$EMPTY_SID_RC"

# --- 13: cache-dir mkdir failure logs stderr
cleanup
ERRFILE=$(mktemp)
printf '%s' '{"session_id":"s13","transcript_path":"'"$FIX/big.jsonl"'"}' | HOME=/dev/null/x bash "$HOOK" 2>"$ERRFILE" >/dev/null
assert_true "mkdir fail -> stderr 'cannot create'" 'grep -q "cannot create" "$ERRFILE"'
rm -f "$ERRFILE"

# --- 14: CLAUDE_PLUGIN_DATA overrides the cache-dir fallback
cleanup
PDATA="$TEST_DIR/plugin-data"
rm -rf "$PDATA" 2>/dev/null
mkdir -p "$PDATA"
make_random_file "$FIX/big.jsonl" 2000
printf '%s' '{"session_id":"s14","transcript_path":"'"$FIX/big.jsonl"'"}' \
  | CLAUDE_PLUGIN_DATA="$PDATA" CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null >/dev/null
assert_true "CLAUDE_PLUGIN_DATA -> flag in plugin data dir" '[[ -e "$PDATA/compact-warned-s14" ]]'
assert_true "CLAUDE_PLUGIN_DATA -> no flag in fallback cache" '[[ ! -e "$CACHE/compact-warned-s14" ]]'

# --- 15: threshold change — stale low-threshold flag clears when a higher
# threshold is applied.
cleanup
make_random_file "$FIX/medium.jsonl" 1500
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s15","transcript_path":"'"$FIX/medium.jsonl"'"}')
assert_true "low-threshold crossing creates flag" '[[ -e "$CACHE/compact-warned-s15" ]]'
OUT=$(CLAUDE_CONTEXT_WARN_BYTES=2000 run_hook '{"session_id":"s15","transcript_path":"'"$FIX/medium.jsonl"'"}')
assert_true "raised threshold > bytes -> stale flag cleared" '[[ ! -e "$CACHE/compact-warned-s15" ]]'

# --- 16: above -> RESET -> above rewarns. End-to-end re-arming check.
cleanup
make_random_file "$FIX/big.jsonl" 2000
OUT1=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s16","transcript_path":"'"$FIX/big.jsonl"'"}')
assert_true "first crossing emits reminder" '[[ "$OUT1" == *"prep-compact"* ]]'
run_hook '{"session_id":"s16"}' RESET >/dev/null
assert_true "RESET cleared flag" '[[ ! -e "$CACHE/compact-warned-s16" ]]'
OUT2=$(CLAUDE_CONTEXT_WARN_BYTES=1000 run_hook '{"session_id":"s16","transcript_path":"'"$FIX/big.jsonl"'"}')
assert_true "second crossing after RESET emits fresh reminder" '[[ "$OUT2" == *"prep-compact"* ]]'

# --- 20: delta-tracking — PostCompact with transcript_path writes baseline;
# UPS with bytes == baseline (delta 0) stays silent; bytes > baseline + threshold
# fires a reminder mentioning delta.
cleanup
make_random_file "$FIX/growing.jsonl" 2500
printf '%s' "{\"session_id\":\"s20\",\"transcript_path\":\"$FIX/growing.jsonl\"}" \
  | HOME="$SANDBOX_HOME" bash "$HOOK" RESET 2>/dev/null
assert_true "RESET writes baseline file" '[[ -e "$CACHE/compact-baseline-s20" ]]'
SAVED_BASELINE=$(cat "$CACHE/compact-baseline-s20" 2>/dev/null | tr -d '[:space:]')
assert_eq "baseline content matches transcript bytes at RESET" "2500" "$SAVED_BASELINE"
OUT=$(printf '%s' "{\"session_id\":\"s20\",\"transcript_path\":\"$FIX/growing.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null)
assert_eq "post-RESET, bytes==baseline (delta 0) -> silent" "" "$OUT"
head -c 4000 </dev/urandom >"$FIX/growing.jsonl"
OUT=$(printf '%s' "{\"session_id\":\"s20\",\"transcript_path\":\"$FIX/growing.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null)
assert_true "post-RESET, delta above threshold -> reminder fires" '[[ "$OUT" == *"prep-compact"* ]]'
assert_true "post-RESET reminder mentions delta vs baseline" '[[ "$OUT" == *"since last compact"* ]]'

# --- 21: pathless RESET preserves baseline and clears flag
cleanup
printf '%s\n' 2500 >"$CACHE/compact-baseline-s21"
touch "$CACHE/compact-warned-s21"
printf '%s' '{"session_id":"s21"}' | HOME="$SANDBOX_HOME" bash "$HOOK" RESET 2>/dev/null
assert_true "pathless RESET clears warned flag" '[[ ! -e "$CACHE/compact-warned-s21" ]]'
PRESERVED=$(cat "$CACHE/compact-baseline-s21" 2>/dev/null | tr -d '[:space:]')
assert_eq "pathless RESET preserves existing baseline" "2500" "$PRESERVED"

# --- 22: BYTES < BASELINE (transcript rotation) -> delta treated as bytes
cleanup
make_random_file "$FIX/small-after-baseline.jsonl" 500
printf '%s\n' 5000 >"$CACHE/compact-baseline-s22"
OUT=$(printf '%s' "{\"session_id\":\"s22\",\"transcript_path\":\"$FIX/small-after-baseline.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null)
assert_eq "bytes<baseline: delta=bytes, below threshold -> silent" "" "$OUT"

# --- 23: malformed baseline ignored (treated as 0)
cleanup
printf 'not-a-number\n' >"$CACHE/compact-baseline-s23"
make_random_file "$FIX/big.jsonl" 2000
OUT=$(printf '%s' "{\"session_id\":\"s23\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
  | CLAUDE_CONTEXT_WARN_BYTES=1000 HOME="$SANDBOX_HOME" bash "$HOOK" 2>/dev/null)
assert_true "malformed baseline -> ignored, absolute-threshold fires" '[[ "$OUT" == *"prep-compact"* ]]'

# --- 24: invalid CLAUDE_CONTEXT_WARN_BYTES doesn't crash (fail-open).
# Covers non-digit string, leading-zero (would be invalid octal under bash
# arithmetic), float, negative.
cleanup
make_random_file "$FIX/big.jsonl" 2000
for BAD in "not-a-number" "08" "3.14" "-1"; do
  ERRFILE=$(mktemp)
  printf '%s' "{\"session_id\":\"s24\",\"transcript_path\":\"$FIX/big.jsonl\"}" \
    | CLAUDE_CONTEXT_WARN_BYTES="$BAD" HOME="$SANDBOX_HOME" bash "$HOOK" 2>"$ERRFILE"
  EXIT_24=$?
  assert_eq "bad CLAUDE_CONTEXT_WARN_BYTES=$BAD -> hook exits 0" "0" "$EXIT_24"
  assert_true "bad CLAUDE_CONTEXT_WARN_BYTES=$BAD -> stderr warns 'ignoring invalid'" 'grep -q "ignoring invalid CLAUDE_CONTEXT_WARN_BYTES" "$ERRFILE"'
  rm -f "$ERRFILE"
done

cleanup
rm -f "$FIX/transcript-"*.jsonl "$FIX/real-standin.jsonl" "$FIX/growing.jsonl" "$FIX/small-after-baseline.jsonl" "$CACHE"/compact-baseline-* 2>/dev/null

printf '\n'
if [[ "$FAIL" -eq 0 && "$PASS" -eq "$EXPECTED_PASS" ]]; then
  printf 'All %d assertions passed\n' "$PASS"
  exit 0
elif [[ "$FAIL" -eq 0 ]]; then
  printf 'FALSE-GREEN GUARD: expected %d passes, got %d — likely a skipped test\n' "$EXPECTED_PASS" "$PASS" >&2
  exit 2
else
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi
